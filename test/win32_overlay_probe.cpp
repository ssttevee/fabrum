// Real input routing, rather than a synthetic WM_NCHITTEST result.
#include <windows.h>
#include <cstdio>
static POINT previous;
static bool moved;
struct Shared { volatile LONG ready, clicks; HWND hwnd; int x, y; bool ignore_close; };
static Shared* shared;
static HANDLE mapping, child, job;
static bool stubborn_next;
static LRESULT CALLBACK target_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_LBUTTONDOWN) InterlockedIncrement(&shared->clicks);
    if (m == WM_CLOSE && shared->ignore_close) return 0;
    if (m == WM_CLOSE || m == WM_TIMER) { DestroyWindow(h); return 0; }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}
extern "C" void overlay_target_main(size_t value) {
    mapping = (HANDLE)value;
    shared = (Shared*)MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    if (!shared) return;
    WNDCLASSW wc = {};
    wc.lpfnWndProc = target_proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"FabrumOverlayInputTarget";
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    if (!RegisterClassW(&wc)) return;
    HWND h = CreateWindowW(wc.lpszClassName, L"Cross-process overlay input target", WS_POPUP | WS_VISIBLE,
        shared->x, shared->y, 300, 220, nullptr, nullptr, wc.hInstance, nullptr);
    if (!h) return;
    SetTimer(h, 1, 10000, nullptr); // Self-clean even when the parent assertion exits.
    shared->hwnd = h;
    InterlockedExchange(&shared->ready, 1);
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    UnmapViewOfFile(shared);
    CloseHandle(mapping);
}
extern "C" HWND overlay_start_target(int x, int y) {
    SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
    mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, sizeof(Shared), nullptr);
    if (!mapping) return nullptr;
    shared = (Shared*)MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    if (!shared) return nullptr;
    *shared = {};
    shared->x = x; shared->y = y;
    shared->ignore_close = stubborn_next;
    stubborn_next = false;
    wchar_t exe[32768], command[33000];
    if (!GetModuleFileNameW(nullptr, exe, 32768)) return nullptr;
    swprintf(command, 33000, L"\"%ls\" --overlay-input-target %llu", exe, (unsigned long long)(UINT_PTR)mapping);
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process = {};
    job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) return nullptr;
    if (!CreateProcessW(exe, command, nullptr, nullptr, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &process)) return nullptr;
    child = process.hProcess;
    if (!AssignProcessToJobObject(job, child)) {
        TerminateProcess(child, 1);
        WaitForSingleObject(child, 2000);
        CloseHandle(process.hThread);
        return nullptr;
    }
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    for (int i = 0; i < 200; ++i) {
        if (InterlockedCompareExchange(&shared->ready, 0, 0)) return shared->hwnd;
        if (WaitForSingleObject(child, 10) == WAIT_OBJECT_0) break;
    }
    return nullptr;
}
extern "C" bool overlay_stop_target() {
    if (shared && shared->hwnd) PostMessageW(shared->hwnd, WM_CLOSE, 0, 0);
    bool reaped = true;
    if (child) {
        auto status = WaitForSingleObject(child, 2000);
        if (job) { CloseHandle(job); job = nullptr; } // Kill on close covers timeout and failed parent assertions.
        if (status != WAIT_OBJECT_0) status = WaitForSingleObject(child, 2000);
        reaped = status == WAIT_OBJECT_0;
        CloseHandle(child); child = nullptr;
    }
    if (job) { CloseHandle(job); job = nullptr; }
    if (shared) { UnmapViewOfFile(shared); shared = nullptr; }
    if (mapping) { CloseHandle(mapping); mapping = nullptr; }
    return reaped;
}
extern "C" bool overlay_verify_timeout_cleanup(int x, int y) {
    stubborn_next = true;
    HWND target = overlay_start_target(x, y);
    if (!target) { overlay_stop_target(); return false; }
    const ULONGLONG start = GetTickCount64();
    const bool reaped = overlay_stop_target();
    // This child ignores WM_CLOSE; passing requires the timeout/Job path.
    return reaped && GetTickCount64() - start >= 1900 && !IsWindow(target);
}
extern "C" unsigned overlay_clicks() { return shared ? (unsigned)InterlockedCompareExchange(&shared->clicks, 0, 0) : 0; }
extern "C" bool overlay_click_at(int x, int y) {
    if (!GetCursorPos(&previous)) return false;
    moved = true;
    INPUT input[3] = {};
    input[0].type = input[1].type = input[2].type = INPUT_MOUSE;
    // Queue movement and buttons together, so queued mouse input cannot
    // observe a position preceding a separate SetCursorPos operation.
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (width <= 1 || height <= 1) return false;
    input[0].mi.dx = (LONG)(((long long)x - left) * 65535 / (width - 1));
    input[0].mi.dy = (LONG)(((long long)y - top) * 65535 / (height - 1));
    input[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    input[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    input[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    const bool sent = SendInput(3, input, sizeof(INPUT)) == 3;
    // Input processing is asynchronous; restore position on the next test turn.
    return sent;
}
extern "C" void overlay_restore_cursor() {
    if (moved) SetCursorPos(previous.x, previous.y);
    moved = false;
}
