// Real input routing, rather than a synthetic WM_NCHITTEST result.
#include <windows.h>
#include <commctrl.h>
static unsigned clicks;
static POINT previous;
static bool moved;
static LRESULT CALLBACK count_click(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR) {
    if (m == WM_LBUTTONDOWN) ++clicks;
    return DefSubclassProc(h, m, w, l);
}
extern "C" bool overlay_watch_clicks(HWND hwnd) {
    clicks = 0;
    return SetWindowSubclass(hwnd, count_click, 71, 0) != FALSE;
}
extern "C" unsigned overlay_clicks() { return clicks; }
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
