// Regression-only decoding through the OS codec, independent of the writer.
#include <windows.h>
#include <wincodec.h>
#include <commctrl.h>
struct Reentry { void(*call)(void*); void*ctx; };
static LRESULT CALLBACK capture_reentry(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR data) {
    auto*entry=(Reentry*)data;
    if(msg==WM_PRINT||msg==WM_PRINTCLIENT) {
        auto copy=*entry;
        RemoveWindowSubclass(hwnd,capture_reentry,id);
        delete entry;
        copy.call(copy.ctx);
        return 0;
    }
    return DefSubclassProc(hwnd,msg,wp,lp);
}
extern "C" bool destroy_on_capture(HWND hwnd,void(*call)(void*),void*ctx) {
    auto*entry=new Reentry{call,ctx};
    if(SetWindowSubclass(hwnd,capture_reentry,42,(DWORD_PTR)entry))return true;
    delete entry;
    return false;
}
extern "C" bool png_probe(const wchar_t*path,unsigned x,unsigned y,unsigned*w,unsigned*h,unsigned char*pixel) {
    HRESULT init=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    IWICImagingFactory*f=nullptr; IWICBitmapDecoder*d=nullptr;
    IWICBitmapFrameDecode*b=nullptr; IWICFormatConverter*c=nullptr;
    HRESULT hr=CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&f));
    if(SUCCEEDED(hr))hr=f->CreateDecoderFromFilename(path,nullptr,GENERIC_READ,WICDecodeMetadataCacheOnLoad,&d);
    if(SUCCEEDED(hr))hr=d->GetFrame(0,&b);
    if(SUCCEEDED(hr))hr=b->GetSize(w,h);
    if(SUCCEEDED(hr))hr=f->CreateFormatConverter(&c);
    if(SUCCEEDED(hr))hr=c->Initialize(b,GUID_WICPixelFormat32bppBGRA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom);
    WICRect r={(INT)x,(INT)y,1,1};
    if(SUCCEEDED(hr))hr=c->CopyPixels(&r,4,4,pixel);
    if(c)c->Release();if(b)b->Release();if(d)d->Release();if(f)f->Release();
    if(SUCCEEDED(init))CoUninitialize();
    return SUCCEEDED(hr);
}
