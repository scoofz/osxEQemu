// Minimal Direct3D 9 client for testing d3d9trace under Wine: window, device, textures,
// a dynamic vertex buffer (Lock DISCARD), FF + shader draws, 200 frames.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <cstdio>
#include <cstdlib>
static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }
struct V { float x, y, z, rhw; DWORD c; };
int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 200;
    WNDCLASSA wc = {}; wc.lpfnWndProc = wp; wc.hInstance = GetModuleHandleA(0); wc.lpszClassName = "t";
    RegisterClassA(&wc);
    HWND w = CreateWindowA("t", "t", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 320, 240, 0, 0, wc.hInstance, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("Direct3DCreate9 failed\n"); return 1; }
    HRESULT dxt = d3d->CheckDeviceFormat(0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, D3DFMT_DXT1);
    D3DPRESENT_PARAMETERS pp = {}; pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8; pp.EnableAutoDepthStencil = TRUE; pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev = nullptr;
    HRESULT hr = d3d->CreateDevice(0, D3DDEVTYPE_HAL, w, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) { printf("CreateDevice failed 0x%lx\n", hr); return 2; }
    IDirect3DTexture9 *t1 = nullptr, *t2 = nullptr;
    dev->CreateTexture(256, 256, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &t1, 0);
    if (SUCCEEDED(dxt)) dev->CreateTexture(128, 64, 0, 0, D3DFMT_DXT1, D3DPOOL_MANAGED, &t2, 0);
    D3DLOCKED_RECT lr; if (t1 && SUCCEEDED(t1->LockRect(0, &lr, 0, 0))) t1->UnlockRect(0);
    IDirect3DVertexBuffer9 *vb = nullptr;
    dev->CreateVertexBuffer(3 * sizeof(V), D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY, 0, D3DPOOL_DEFAULT, &vb, 0);
    static const DWORD ps[] = {0xFFFF0200, 0x02000001, 0x800F0800, 0xA0E40000, 0x0000FFFF};          // ps_2_0: mov oC0, c0
    static const DWORD vs[] = {0xFFFE0200, 0x0200001F, 0x80000000, 0x900F0000,                        // vs_2_0: dcl_position v0
                               0x02000001, 0xC00F0000, 0x90E40000, 0x0000FFFF};                        //         mov oPos, v0
    IDirect3DPixelShader9 *p = nullptr; IDirect3DVertexShader9 *s = nullptr;
    printf("ps 0x%lx vs 0x%lx dxt1 %s\n", dev->CreatePixelShader(ps, &p), dev->CreateVertexShader(vs, &s), SUCCEEDED(dxt) ? "yes" : "no");
    D3DVERTEXELEMENT9 el[] = {{0, 0, D3DDECLTYPE_FLOAT4, 0, D3DDECLUSAGE_POSITION, 0}, D3DDECL_END()};
    IDirect3DVertexDeclaration9 *decl = nullptr; dev->CreateVertexDeclaration(el, &decl);
    for (int f = 0; f < frames; f++) {
        dev->Clear(0, 0, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0xff203040, 1.0f, 0);
        dev->BeginScene();
        V *v; vb->Lock(0, 0, (void **)&v, D3DLOCK_DISCARD);
        V tri[3] = {{10, 10, 0.5f, 1, 0xffff0000}, {300, 10, 0.5f, 1, 0xff00ff00}, {150, 200, 0.5f, 1, 0xff0000ff}};
        memcpy(v, tri, sizeof tri); vb->Unlock();
        dev->SetRenderState(D3DRS_ZENABLE, TRUE); dev->SetRenderState(D3DRS_LIGHTING, FALSE);
        dev->SetRenderState(D3DRS_FOGENABLE, f & 1); dev->SetRenderState(D3DRS_ALPHATESTENABLE, TRUE);
        dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE); dev->SetSamplerState(0, D3DSAMP_MINFILTER, D3DTEXF_LINEAR);
        dev->SetTexture(0, t1);
        dev->SetVertexShader(nullptr); dev->SetPixelShader(nullptr);
        dev->SetFVF(D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
        dev->SetStreamSource(0, vb, 0, sizeof(V));
        dev->DrawPrimitive(D3DPT_TRIANGLELIST, 0, 1);
        dev->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 1, tri, sizeof(V));
        if (s && p) {
            dev->SetVertexDeclaration(decl); dev->SetVertexShader(s); dev->SetPixelShader(p);
            float c[4] = {1, 1, 0, 1}; dev->SetPixelShaderConstantF(0, c, 1);
            dev->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 1, tri, sizeof(V));
        }
        dev->EndScene();
        dev->Present(0, 0, 0, 0);
    }
    printf("done %d frames\n", frames);
    if (decl) decl->Release(); if (s) s->Release(); if (p) p->Release();
    vb->Release(); if (t2) t2->Release(); if (t1) t1->Release(); dev->Release(); d3d->Release();
    return 0;
}
