// The COM ABI bridge only; request ownership and dispatch live in Zig.
#include <windows.h>
#include <shobjidl.h>
#include <new>

struct FabrumFileDialog {
    IFileOpenDialog *dialog;
};

// Shell views can leave asynchronous work on the UI thread after Show returns.
// Keep its apartment alive with the dispatcher, rather than dismantling COM
// between dialogs while the outer message loop is still dispatching that work.
static thread_local bool apartment_initialized = false;

extern "C" void *fabrum_file_dialog_create(const wchar_t *title, const wchar_t *pattern, bool directory) {
    if (!apartment_initialized) {
        const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        if (FAILED(init)) return nullptr;
        apartment_initialized = true;
    }
    IFileOpenDialog *dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) return nullptr;
    DWORD options = 0;
    hr = dialog->GetOptions(&options);
    if (SUCCEEDED(hr)) hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR |
        (directory ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST));
    if (SUCCEEDED(hr) && title && *title) hr = dialog->SetTitle(title);
    if (SUCCEEDED(hr) && !directory && pattern && *pattern) {
        const COMDLG_FILTERSPEC filter = {pattern, pattern};
        hr = dialog->SetFileTypes(1, &filter);
    }
    auto *result = SUCCEEDED(hr) ? new (std::nothrow) FabrumFileDialog{dialog} : nullptr;
    if (!result) dialog->Release();
    return result;
}

extern "C" wchar_t *fabrum_file_dialog_show(void *handle, HWND owner) {
    auto *state = static_cast<FabrumFileDialog *>(handle);
    if (FAILED(state->dialog->Show(owner))) return nullptr;
    IShellItem *item = nullptr;
    if (FAILED(state->dialog->GetResult(&item))) return nullptr;
    PWSTR path = nullptr;
    const HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
    item->Release();
    if (FAILED(hr)) { CoTaskMemFree(path); return nullptr; }
    return path;
}

extern "C" long fabrum_file_dialog_cancel(void *handle) {
    auto *state = static_cast<FabrumFileDialog *>(handle);
    HWND hwnd = nullptr;
    IOleWindow *window = nullptr;
    if (SUCCEEDED(state->dialog->QueryInterface(IID_PPV_ARGS(&window)))) {
        window->GetWindow(&hwnd);
        window->Release();
    }
    const HRESULT hr = state->dialog->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
    // Close can report success from a reentrant dispatcher callback while
    // Show is still initializing. Also enqueue the dialog's normal cancel
    // command so cancellation is observed after that callback unwinds.
    if (hwnd && IsWindow(hwnd)) PostMessageW(hwnd, WM_COMMAND, IDCANCEL, 0);
    return hr;
}

extern "C" void fabrum_file_dialog_destroy(void *handle) {
    auto *state = static_cast<FabrumFileDialog *>(handle);
    state->dialog->Release();
    delete state;
}

extern "C" void fabrum_file_dialog_free_path(wchar_t *path) { CoTaskMemFree(path); }

// Called on the UI thread only after the outer message loop has stopped.
extern "C" void fabrum_file_dialog_shutdown() {
    if (apartment_initialized) {
        apartment_initialized = false;
        CoUninitialize();
    }
}
