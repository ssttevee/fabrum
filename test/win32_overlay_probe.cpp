// Real input routing, rather than a synthetic WM_NCHITTEST result.
#include <windows.h>
#include <cstdio>
static POINT previous;
static bool moved;
struct Shared { volatile LONG ready, clicks; HWND hwnd; int x, y; };
static Shared* shared;
static HANDLE mapping, child;
static LRESULT CALLBACK target_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_LBUTTONDOWN) InterlockedIncrement(&shared->clicks);
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
    wchar_t exe[32768], command[33000];
    if (!GetModuleFileNameW(nullptr, exe, 32768)) return nullptr;
    swprintf(command, 33000, L"\"%ls\" --overlay-input-target %llu", exe, (unsigned long long)(UINT_PTR)mapping);
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process = {};
    if (!CreateProcessW(exe, command, nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) return nullptr;
    child = process.hProcess;
    CloseHandle(process.hThread);
    for (int i = 0; i < 200; ++i) {
        if (InterlockedCompareExchange(&shared->ready, 0, 0)) return shared->hwnd;
        if (WaitForSingleObject(child, 10) == WAIT_OBJECT_0) break;
    }
    return nullptr;
}
extern "C" void overlay_stop_target() {
    if (shared && shared->hwnd) PostMessageW(shared->hwnd, WM_CLOSE, 0, 0);
    if (child) { WaitForSingleObject(child, 2000); CloseHandle(child); child = nullptr; }
    if (shared) { UnmapViewOfFile(shared); shared = nullptr; }
    if (mapping) { CloseHandle(mapping); mapping = nullptr; }
}
extern "C" unsigned overlay_clicks() { return shared ? (unsigned)InterlockedCompareExchange(&shared->clicks, 0, 0) : 0; }
extern "C" bool overlay_click_at(int x, int y) {
    if (!GetCursorPos(&previous) || !SetCursorPos(x, y)) return false;
    moved = true;
    INPUT input[2] = {};
    input[0].type = input[1].type = INPUT_MOUSE;
    input[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    input[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    const bool sent = SendInput(2, input, sizeof(INPUT)) == 2;
    // Input processing is asynchronous; restore position on the next test turn.
    return sent;
}
extern "C" void overlay_restore_cursor() {
    if (moved) SetCursorPos(previous.x, previous.y);
    moved = false;
}
