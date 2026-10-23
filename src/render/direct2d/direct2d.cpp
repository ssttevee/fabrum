// Windows SDK boundary. Zig owns command traversal, image placement, and text caching.
// Targets own COM objects and their premultiplied BGRA DIB; TextBackend owns DirectWrite.
#include <windows.h>
#include <d2d1.h>
#include <dwrite_1.h>
#include <wincodec.h>
#include <cstring>
#include <string>
#include <vector>
#include <new>
#include <cmath>
#include <climits>
namespace  {
    template<class T> struct Com {
        T* p=nullptr;
        ~Com(){if(p)p->Release();}
    };
    template<class T> void release(T*& p) {
        if(p) {
            p->Release();
            p=nullptr;
        }
    }
    // A host-owned draw target. Offscreen tests use the same target without an HWND.
    struct Target {
        ID2D1Factory* factory=nullptr;
        ID2D1DCRenderTarget* rt=nullptr;
        HWND hwnd=nullptr;
        HDC dc=nullptr;
        HBITMAP bitmap=nullptr;
        HGDIOBJ old=nullptr;
        void* bits=nullptr;
        unsigned width=0,height=0;
        unsigned clips=0;
        bool failed=false;
        D2D1_MATRIX_3X2_F transform=D2D1::Matrix3x2F::Identity();
        float dpi_x=96,dpi_y=96;
        HRESULT injected_end=S_OK;
        unsigned fail_creates=0;
        unsigned generation=0;
        std::vector<bool> layers;
        std::vector<unsigned> saves;
    };
    struct TextBackend { IDWriteFactory* factory=nullptr; std::wstring family=L"Segoe UI"; };
    // Only the render target is device dependent. The DIB, factory and text
    // backend survive loss; brushes and bitmaps are already scoped to a draw.
    bool ensure_target(Target*t) {
        if(t->rt)return true;
        if(t->fail_creates){--t->fail_creates;return false;}
        auto properties=D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED));
        if(FAILED(t->factory->CreateDCRenderTarget(&properties,&t->rt)))return false;
        ++t->generation;
        return true;
    }
    void discard_target(Target*t) {
        release(t->rt);
        t->clips=0;
        t->layers.clear();
        t->saves.clear();
    }
    bool bind_target(Target*t) {
        if(!ensure_target(t))return false;
        RECT bounds={0,0,(LONG)t->width,(LONG)t->height};
        HRESULT hr=t->rt->BindDC(t->dc,&bounds);
        if(FAILED(hr)){if(hr==D2DERR_RECREATE_TARGET)discard_target(t);return false;}
        t->rt->SetDpi(t->dpi_x,t->dpi_y);
        t->rt->SetTransform(t->transform);
        return true;
    }
    bool finish_target(Target*t) {
        HRESULT hr=t->rt->EndDraw();
        if(t->injected_end!=S_OK){hr=t->injected_end;t->injected_end=S_OK;}
        if(hr==D2DERR_RECREATE_TARGET)discard_target(t);
        return SUCCEEDED(hr);
    }
    std::wstring wide(const char* s,size_t n) {
        if(n>INT_MAX)return  {
        };
        int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,(int)n,nullptr,0);
        std::wstring w(count,0);
        if(count)MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,(int)n,w.data(),count);
        return w;
    }
    D2D1_RECT_F rect(double x,double y,double w,double h) {
        return D2D1::RectF((float)x,(float)y,(float)(x+w),(float)(y+h));
    }
    ID2D1SolidColorBrush* brush(Target* t,unsigned char r,unsigned char g,unsigned char b,unsigned char a) {
        ID2D1SolidColorBrush* p=nullptr;
        if(FAILED(t->rt->CreateSolidColorBrush(D2D1::ColorF(r/255.f,g/255.f,b/255.f,a/255.f),&p))) t->failed=true;
        return p;
    }
    IDWriteTextLayout* layout(TextBackend*backend,const char*s,size_t n,const char*f,size_t fn,double size,int weight,double spacing) {
        auto text=wide(s,n);
        auto name=fn?wide(f,fn):backend->family;
        IDWriteFactory* dw=backend->factory;
        IDWriteTextFormat* fmt=nullptr;
        IDWriteTextLayout* out=nullptr;
        if(SUCCEEDED(dw->CreateTextFormat(name.c_str(),nullptr,(DWRITE_FONT_WEIGHT)weight,DWRITE_FONT_STYLE_NORMAL,DWRITE_FONT_STRETCH_NORMAL,(float)size,L"",&fmt))) {
            fmt->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
            dw->CreateTextLayout(text.data(),(UINT32)text.size(),fmt,1000000,1000000,&out);
        }
        if(out&&spacing!=0) {
            IDWriteTextLayout1* l=nullptr;
            if(SUCCEEDED(out->QueryInterface(__uuidof(IDWriteTextLayout1),(void**)&l))) {
                l->SetCharacterSpacing(0,(float)spacing,0, {
                    0,(UINT32)text.size()
                });
                l->Release();
            }
        }
        release(fmt);
        return out;
    }
}
extern "C"  {
    TextBackend* fabrum_d2d_text_create() try { auto*b=new(std::nothrow) TextBackend; if(!b)return nullptr; if(FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,__uuidof(IDWriteFactory),(IUnknown**)&b->factory))){delete b;return nullptr;}return b;}catch(...){return nullptr;}
    void fabrum_d2d_text_destroy(TextBackend*b){if(b){release(b->factory);delete b;}}
    bool fabrum_d2d_prepare(Target*t,size_t commands) noexcept  {
        try {
            t->failed=false;
            t->layers.reserve(commands+2);
            t->saves.reserve(commands+2);
            return true;
        }
        catch(...) {
            return false;
        }
    }
    bool fabrum_d2d_status(Target*t) { return !t->failed; }
    bool fabrum_d2d_target_recoverable(Target*t) { return t->rt==nullptr; }
    void fabrum_d2d_target_destroy(Target*t) {
        if(!t)return;
        release(t->rt);
        release(t->factory);
        if(t->dc) {
            if(t->old)SelectObject(t->dc,t->old);
            if(t->bitmap)DeleteObject(t->bitmap);
            DeleteDC(t->dc);
        }
        delete t;
    }
    Target* fabrum_d2d_target_create(HWND hwnd) {
        auto*t=new(std::nothrow) Target;
        if(!t)return nullptr;
        t->hwnd=hwnd;
        if(FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,&t->factory))||!ensure_target(t)) {
            fabrum_d2d_target_destroy(t);
            return nullptr;
        }
        t->dc=CreateCompatibleDC(nullptr);
        if(!t->dc) {
            fabrum_d2d_target_destroy(t);
            return nullptr;
        }
        return t;
    }
    bool fabrum_d2d_target_resize(Target*t,unsigned w,unsigned h) {
        if(!w||!h)return false;
        if(t->width==w&&t->height==h)return true;
        BITMAPINFO bi= {
        };
        bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth=(LONG)w;
        bi.bmiHeader.biHeight=-(LONG)h;
        bi.bmiHeader.biPlanes=1;
        bi.bmiHeader.biBitCount=32;
        bi.bmiHeader.biCompression=BI_RGB;
        void*bits=nullptr;
        HBITMAP b=CreateDIBSection(t->dc,&bi,DIB_RGB_COLORS,&bits,nullptr,0);
        if(!b)return false;
        if(t->bitmap) {
            SelectObject(t->dc,t->old);
            DeleteObject(t->bitmap);
        }
        t->bits=bits;
        t->bitmap=b;
        t->old=SelectObject(t->dc,b);
        t->width=w;
        t->height=h;
        return true;
    }
    Target* fabrum_d2d_image_create(unsigned w,unsigned h,float scale,float x,float y) {
        Target*t=fabrum_d2d_target_create(nullptr);
        if(!t)return nullptr;
        if(!fabrum_d2d_target_resize(t,w,h)) {
            fabrum_d2d_target_destroy(t);
            return nullptr;
        }
        t->transform=D2D1::Matrix3x2F(scale,0,0,scale,x,y);
        if(!bind_target(t)) {
            fabrum_d2d_target_destroy(t);
            return nullptr;
        }
        t->rt->BeginDraw();
        t->rt->Clear(D2D1::ColorF(0,0));
        if(!finish_target(t)) {
            fabrum_d2d_target_destroy(t);
            return nullptr;
        }
        return t;
    }
    bool fabrum_d2d_image_begin(Target*t) {
        if(!bind_target(t))return false;
        t->rt->BeginDraw();
        return true;
    }
    bool fabrum_d2d_image_end(Target*t) {
        return finish_target(t);
    }
    const unsigned char* fabrum_d2d_image_data(Target*t) {
        return (const unsigned char*)t->bits;
    }
    // Only SDK painting crosses this boundary; Zig owns traversal, clipping,
    // retained canvas copies and source-over composition.
    bool fabrum_d2d_capture_native(Target*t,HWND hwnd,int x,int y,int left,int top,int right,int bottom,bool framed) {
        if(!IsWindow(hwnd)||!t->bits)return false;
        int saved=SaveDC(t->dc);
        if(!saved)return false;
        IntersectClipRect(t->dc,left,top,right,bottom);
        SetViewportOrgEx(t->dc,x,y,nullptr);
        SendMessageW(hwnd,framed?WM_PRINT:WM_PRINTCLIENT,(WPARAM)t->dc,PRF_CLIENT|PRF_ERASEBKGND|PRF_CHECKVISIBLE|(framed?PRF_NONCLIENT:0));
        RestoreDC(t->dc,saved);
        // Flush batched GDI writes before touching the shared DIB on the CPU.
        if(!GdiFlush())return false;
        // GDI doesn't supply alpha. Native controls paint opaque client areas.
        auto*bits=(unsigned char*)t->bits;
        for(int row=top;row<bottom;++row)for(int col=left;col<right;++col)
            bits[((size_t)row*t->width+col)*4+3]=255;
        return IsWindow(hwnd)!=FALSE;
    }
    bool fabrum_d2d_write_png(Target*t,const char*path,unsigned width,unsigned height) try {
        if(!path||!width||!height||!t->bits)return false;
        const HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
        struct Apartment { bool owned; ~Apartment(){if(owned)CoUninitialize();} } apartment{SUCCEEDED(initialized)};
        if(FAILED(initialized)&&initialized!=RPC_E_CHANGED_MODE)return false;
        auto filename=wide(path,std::strlen(path));
        bool created=false,ok=false;
        {
            Com<IWICImagingFactory> factory;
            Com<IWICStream> stream;
            Com<IWICBitmapEncoder> encoder;
            Com<IWICBitmapFrameEncode> frame;
            Com<IWICBitmap> bitmap;
            Com<IWICBitmapScaler> scaler;
            HRESULT hr=CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory.p));
            if(SUCCEEDED(hr))hr=factory.p->CreateStream(&stream.p);
            if(SUCCEEDED(hr)){hr=stream.p->InitializeFromFilename(filename.c_str(),GENERIC_WRITE);created=SUCCEEDED(hr);}
            if(SUCCEEDED(hr))hr=factory.p->CreateEncoder(GUID_ContainerFormatPng,nullptr,&encoder.p);
            if(SUCCEEDED(hr))hr=encoder.p->Initialize(stream.p,WICBitmapEncoderNoCache);
            if(SUCCEEDED(hr))hr=encoder.p->CreateNewFrame(&frame.p,nullptr);
            if(SUCCEEDED(hr))hr=frame.p->Initialize(nullptr);
            if(SUCCEEDED(hr))hr=frame.p->SetSize(width,height);
            WICPixelFormatGUID format=GUID_WICPixelFormat32bppBGRA;
            if(SUCCEEDED(hr))hr=frame.p->SetPixelFormat(&format);
            if(SUCCEEDED(hr))hr=factory.p->CreateBitmapFromMemory(t->width,t->height,GUID_WICPixelFormat32bppBGRA,t->width*4,t->width*t->height*4,(BYTE*)t->bits,&bitmap.p);
            IWICBitmapSource*source=bitmap.p;
            if(SUCCEEDED(hr)&&(width!=t->width||height!=t->height)) {
                hr=factory.p->CreateBitmapScaler(&scaler.p);
                if(SUCCEEDED(hr))hr=scaler.p->Initialize(bitmap.p,width,height,WICBitmapInterpolationModeFant);
                source=scaler.p;
            }
            if(SUCCEEDED(hr))hr=frame.p->WriteSource(source,nullptr);
            if(SUCCEEDED(hr))hr=frame.p->Commit();
            if(SUCCEEDED(hr))hr=encoder.p->Commit();
            ok=SUCCEEDED(hr);
        }
        if(!ok&&created)DeleteFileW(filename.c_str());
        return ok;
    } catch (...) { return false; }
    void fabrum_d2d_target_origin(Target*t,float x,float y) {
        t->transform=D2D1::Matrix3x2F::Translation(x,y);
    }
    // Every scheduled paint fully redraws the bounded visible slice. Unchanged
    // layers and damage outside that slice are skipped by the host.
    bool fabrum_d2d_target_begin(Target*t) {
        RECT r;
        GetClientRect(t->hwnd,&r);
        if(!fabrum_d2d_target_resize(t,r.right,r.bottom))return false;
        float dpi=(float)GetDpiForWindow(t->hwnd);
        t->dpi_x=t->dpi_y=dpi;
        if(!bind_target(t))return false;
        t->rt->BeginDraw();
        t->rt->Clear(D2D1::ColorF(0,0));
        return true;
    }
    bool fabrum_d2d_target_end(Target*t) {
        if(!finish_target(t))return false;
        SIZE size= {
            (LONG)t->width,(LONG)t->height
        };
        POINT src= {
            0,0
        };
        BLENDFUNCTION blend= {
            AC_SRC_OVER,0,255,AC_SRC_ALPHA
        };
        return UpdateLayeredWindow(t->hwnd,nullptr,nullptr,&size,t->dc,&src,0,&blend,ULW_ALPHA)!=0;
    }
    // Transparent hosts compose several canvas DIBs in Zig, then upload one
    // top-level surface. Keep SDK resource ownership at this boundary.
    bool fabrum_d2d_target_end_offscreen(Target*t) { return finish_target(t); }
    bool fabrum_d2d_target_upload(Target*t) {
        SIZE size={(LONG)t->width,(LONG)t->height};
        POINT src={0,0};
        BLENDFUNCTION blend={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
        return UpdateLayeredWindow(t->hwnd,nullptr,nullptr,&size,t->dc,&src,0,&blend,ULW_ALPHA)!=0;
    }
    // Deterministic regression hooks: use the real EndDraw and recovery paths.
    void fabrum_d2d_test_fail_end(Target*t,bool device_loss) { t->injected_end=device_loss?D2DERR_RECREATE_TARGET:E_FAIL; }
    void fabrum_d2d_test_fail_create(Target*t) { t->fail_creates=1; }
    void fabrum_d2d_test_fail_creates(Target*t,unsigned count) { t->fail_creates=count; }
    unsigned fabrum_d2d_test_generation(Target*t) { return t->generation; }
    bool fabrum_d2d_set_default_family(TextBackend* backend,const char*f,size_t n) try {
        auto family=wide(f,n);
        if(family==backend->family)return false;
        backend->family=family;
        return true;
    } catch (...) { return false; }
    bool fabrum_d2d_measure(TextBackend*backend,const char*s,size_t n,const char*f,size_t fn,double size,int weight,double spacing,double*w,double*h)try  {
        auto*l=layout(backend,s,n,f,fn,size,weight,spacing);
        if(!l)return false;
        DWRITE_TEXT_METRICS m= {
        };
        HRESULT hr=l->GetMetrics(&m);
        l->Release();
        *w=m.widthIncludingTrailingWhitespace;
        *h=m.height;
        return SUCCEEDED(hr);
    }
    catch (...)  {
        return false;
    }
    void fabrum_d2d_save(Target*t) {
        t->saves.push_back(t->clips);
    }
    void fabrum_d2d_restore(Target*t) {
        if(t->saves.empty())return;
        unsigned end=t->saves.back();
        t->saves.pop_back();
        while(t->clips>end) {
            if(t->layers.back())t->rt->PopLayer();
            else t->rt->PopAxisAlignedClip();
            t->layers.pop_back();
            --t->clips;
        }
    }
    size_t fabrum_d2d_scope(Target*t) { size_t depth=t->saves.size(); fabrum_d2d_save(t); return depth; }
    void fabrum_d2d_restore_scope(Target*t,size_t depth) { while(t->saves.size()>depth) fabrum_d2d_restore(t); }    void fabrum_d2d_clip_axes(Target*t,double x,double y,double w,double h,bool horizontal,bool vertical) {
        t->rt->PushAxisAlignedClip(rect(horizontal?x:-1e8,vertical?y:-1e8,horizontal?w:2e8,vertical?h:2e8),D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        ++t->clips;
        t->layers.push_back(false);
    }
    void fabrum_d2d_clip(Target*t,double x,double y,double w,double h) {
        fabrum_d2d_clip_axes(t,x,y,w,h,true,true);
    }
    // A winding geometry group represents the union, so overlapping damage draws once.
    void fabrum_d2d_clip_rects(Target*t,const double(*r)[4],size_t n) try {
        if (n == 0) { fabrum_d2d_clip(t, 0, 0, 0, 0); return; }
        std::vector<ID2D1Geometry*> shapes;
        shapes.reserve(n);
        for(size_t i=0;i<n;++i) {
            ID2D1RectangleGeometry*g=nullptr;
                        D2D1_RECT_F area = rect(r[i][0],r[i][1],r[i][2],r[i][3]);
            if(r[i][2] <= 0 || r[i][3] <= 0) continue;
            D2D1_MATRIX_3X2_F transform;
            t->rt->GetTransform(&transform);
            float dpi_x,dpi_y;
            t->rt->GetDpi(&dpi_x,&dpi_y);
            double sx=transform._11*dpi_x/96, sy=transform._22*dpi_y/96;
            double tx=transform._31*dpi_x/96, ty=transform._32*dpi_y/96;
            if(sx>0 && sy>0){
                area.left=(float)((floor(area.left*sx+tx)-tx)/sx);
                area.top=(float)((floor(area.top*sy+ty)-ty)/sy);
                area.right=(float)((ceil(area.right*sx+tx)-tx)/sx);
                area.bottom=(float)((ceil(area.bottom*sy+ty)-ty)/sy);
            }
            if(SUCCEEDED(t->factory->CreateRectangleGeometry(area,&g)))shapes.push_back(g);else t->failed=true;
        }
        if(shapes.empty()){fabrum_d2d_clip(t,0,0,0,0);return;}
        ID2D1GeometryGroup*group=nullptr;
        HRESULT hr=t->factory->CreateGeometryGroup(D2D1_FILL_MODE_WINDING,shapes.data(),(UINT32)shapes.size(),&group);
        for(auto*g:shapes)g->Release();
        if(FAILED(hr)) {
            t->failed=true;
            fabrum_d2d_clip(t,0,0,0,0);
            return;
        }
        t->rt->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(),group,D2D1_ANTIALIAS_MODE_ALIASED),nullptr);
        t->layers.push_back(true);
        ++t->clips;
        group->Release();
    } catch (...) { t->failed=true; fabrum_d2d_clip(t,0,0,0,0); }

    void fabrum_d2d_fill_rect(Target*t,double x,double y,double w,double h,double tl,double tr,double br,double bl,unsigned char r,unsigned char g,unsigned char b,unsigned char a) {
        auto*p=brush(t,r,g,b,a);
        if(!p)return;
        ID2D1PathGeometry* path=nullptr;
        ID2D1GeometrySink*s=nullptr;
        if(SUCCEEDED(t->factory->CreatePathGeometry(&path))&&SUCCEEDED(path->Open(&s))) {
            s->BeginFigure(D2D1::Point2F((float)(x+tl),(float)y),D2D1_FIGURE_BEGIN_FILLED);
            auto line=[&](double px,double py) {
                s->AddLine(D2D1::Point2F((float)px,(float)py));
            };
            auto arc=[&](double px,double py,double rad) {
                if(rad>0)s->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)px,(float)py),D2D1::SizeF((float)rad,(float)rad),0,D2D1_SWEEP_DIRECTION_CLOCKWISE,D2D1_ARC_SIZE_SMALL));
                else line(px,py);
            };
            line(x+w-tr,y);
            arc(x+w,y+tr,tr);
            line(x+w,y+h-br);
            arc(x+w-br,y+h,br);
            line(x+bl,y+h);
            arc(x,y+h-bl,bl);
            line(x,y+tl);
            arc(x+tl,y,tl);
            s->EndFigure(D2D1_FIGURE_END_CLOSED);
            if(SUCCEEDED(s->Close()))t->rt->FillGeometry(path,p);else t->failed=true;
        }
        if(!s)t->failed=true;
        release(s);
        release(path);
        release(p);
    }
    void fabrum_d2d_stroke_rect(Target*t,double x,double y,double w,double h,double tl,double tr,double br,double bl,double width,unsigned char r,unsigned char g,unsigned char b,unsigned char a) {
        x+=width/2; y+=width/2; w=fmax(0,w-width); h=fmax(0,h-width); tl=fmax(0,tl-width/2); tr=fmax(0,tr-width/2); br=fmax(0,br-width/2); bl=fmax(0,bl-width/2);
        auto*p=brush(t,r,g,b,a);
        if(!p)return;
        ID2D1PathGeometry* path=nullptr;
        ID2D1GeometrySink*s=nullptr;
        if(SUCCEEDED(t->factory->CreatePathGeometry(&path))&&SUCCEEDED(path->Open(&s))) {
            s->BeginFigure(D2D1::Point2F((float)(x+tl),(float)y),D2D1_FIGURE_BEGIN_FILLED);
            auto line=[&](double px,double py) {
                s->AddLine(D2D1::Point2F((float)px,(float)py));
            };
            auto arc=[&](double px,double py,double rad) {
                if(rad>0)s->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)px,(float)py),D2D1::SizeF((float)rad,(float)rad),0,D2D1_SWEEP_DIRECTION_CLOCKWISE,D2D1_ARC_SIZE_SMALL));
                else line(px,py);
            };
            line(x+w-tr,y);
            arc(x+w,y+tr,tr);
            line(x+w,y+h-br);
            arc(x+w-br,y+h,br);
            line(x+bl,y+h);
            arc(x,y+h-bl,bl);
            line(x,y+tl);
            arc(x+tl,y,tl);
            s->EndFigure(D2D1_FIGURE_END_CLOSED);
            if(SUCCEEDED(s->Close()))t->rt->DrawGeometry(path,p,(float)width);else t->failed=true;
        }
        if(!s)t->failed=true;
        release(s);
        release(path);
        release(p);
    }
    void fabrum_d2d_draw_text(Target*t,TextBackend*backend,const char*s,size_t n,const char*f,size_t fn,double size,int weight,double spacing,double x,double y,unsigned char r,unsigned char g,unsigned char b,unsigned char a)try  {
        auto*l=layout(backend,s,n,f,fn,size,weight,spacing);
        auto*p=brush(t,r,g,b,a);
        if(!l)t->failed=true;
        if(l&&p)t->rt->DrawTextLayout(D2D1::Point2F((float)x,(float)y),l,p);
        release(l);
        release(p);
    }
    catch (...) { t->failed=true; }
    bool fabrum_d2d_draw_bitmap(Target*t,const unsigned char*data,unsigned w,unsigned h,unsigned stride,unsigned char format,double bx,double by,double bw,double bh,double x,double y,double dw,double dh,bool smooth,bool snap)try  {
        std::vector<unsigned char> converted;
        if(format!=1) {
            converted.resize((size_t)w*h*4);
            for(unsigned j=0;j<h;++j)for(unsigned i=0;i<w;++i) {
                auto*d=&converted[((size_t)j*w+i)*4];
                auto*s=data+(size_t)j*stride+i*(format==2?1:4);
                if(format==2) {
                    d[0]=d[1]=d[2]=s[0];
                    d[3]=255;
                }
                else {
                    d[0]=s[2];
                    d[1]=s[1];
                    d[2]=s[0];
                    d[3]=s[3];
                }
            }
            data=converted.data();
            stride=w*4;
        }
        ID2D1Bitmap*bitmap=nullptr;
        HRESULT hr=t->rt->CreateBitmap(D2D1::SizeU(w,h),data,stride,D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED)),&bitmap);
        if(FAILED(hr))return false;
        if(snap) {
            D2D1_MATRIX_3X2_F m;
            t->rt->GetTransform(&m);
            float dx,dy;
            t->rt->GetDpi(&dx,&dy);
            double sx=m._11*dx/96,sy=m._22*dy/96,tx=m._31*dx/96,ty=m._32*dy/96;
            if(sx>0&&sy>0) {
                x=(round(x*sx+tx)-tx)/sx;
                y=(round(y*sy+ty)-ty)/sy;
            }
        }
        fabrum_d2d_clip(t,bx,by,bw,bh);
        t->rt->DrawBitmap(bitmap,rect(x,y,dw,dh),1,smooth?D2D1_BITMAP_INTERPOLATION_MODE_LINEAR:D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR);
        if(t->layers.back())t->rt->PopLayer();
        else t->rt->PopAxisAlignedClip();
        t->layers.pop_back();
        --t->clips;
        release(bitmap);
        return true;
    }
    catch (...)  {
        return false;
    }
}
