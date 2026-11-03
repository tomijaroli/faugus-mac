// Creates a D3D11 device + swap chain, clears and presents 30 frames, and reports which
// d3d11.dll implementation was loaded ("DXVK" when the file contains the DXVK marker).
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcA(h, m, w, l);
}

static int file_contains(const char *path, const char *needle) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(n + 1);
    if (!buf) { fclose(f); return -1; }
    fread(buf, 1, n, f); fclose(f); buf[n] = 0;
    int found = 0;
    size_t len = strlen(needle);
    for (long i = 0; i + (long)len <= n; i++) if (memcmp(buf + i, needle, len) == 0) { found = 1; break; }
    free(buf);
    return found;
}

int main(void) {
    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "faugus_d3d11";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("faugus_d3d11", "faugus d3d11tri", WS_OVERLAPPEDWINDOW, 100, 100, 640, 360, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(hwnd, SW_SHOW);

    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 360;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    if (FAILED(hr)) { printf("D3D11CreateDeviceAndSwapChain failed: 0x%08lx\n", (unsigned long)hr); return 2; }
    printf("feature level: 0x%x\n", (unsigned)fl);

    HMODULE m = GetModuleHandleA("d3d11.dll");
    char path[MAX_PATH] = { 0 };
    if (m) GetModuleFileNameA(m, path, MAX_PATH);
    // Map C:\windows\... to the path Wine can open.
    int dxvk = file_contains(path, "DXVK");
    printf("d3d11.dll=%s\n", dxvk == 1 ? "DXVK" : "builtin");

    ID3D11Texture2D *bb = NULL; ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);

    int frames = 0;
    MSG msg;
    for (int i = 0; i < 30; i++) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        float c[4] = { (i % 10) / 10.0f, 0.2f, 0.6f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        if (FAILED(IDXGISwapChain_Present(sc, 1, 0))) { printf("Present failed at frame %d\n", i); return 3; }
        frames++;
        Sleep(16);
    }
    printf("rendered %d frames OK\n", frames);
    fflush(stdout);
    return 0;
}
