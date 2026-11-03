// Creates a D3D9 device, clears and presents 30 frames. Under Wine this always goes through
// WineD3D (DXVK-macOS has no d3d9), so it checks the OpenGL/Vulkan WineD3D path.
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcA(h, m, w, l);
}

int main(void) {
    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "faugus_d3d9";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("faugus_d3d9", "faugus d3d9tri", WS_OVERLAPPEDWINDOW, 100, 100, 640, 360, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(hwnd, SW_SHOW);

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("Direct3DCreate9 failed\n"); return 2; }
    D3DADAPTER_IDENTIFIER9 id;
    IDirect3D9_GetAdapterIdentifier(d3d, 0, 0, &id);
    printf("adapter: %s\n", id.Description);

    D3DPRESENT_PARAMETERS pp = { 0 };
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = hwnd;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) { printf("CreateDevice failed: 0x%08lx\n", (unsigned long)hr); return 3; }

    int frames = 0;
    MSG msg;
    for (int i = 0; i < 30; i++) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB((i * 8) % 256, 40, 120), 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_EndScene(dev);
        if (FAILED(IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL))) { printf("Present failed\n"); return 4; }
        frames++;
        Sleep(16);
    }
    printf("rendered %d frames OK\n", frames);
    fflush(stdout);
    return 0;
}
