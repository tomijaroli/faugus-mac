// `spawner.exe`            : starts a detached child (`spawner.exe --child`) and exits at once.
// `spawner.exe --child`    : sleeps for 120 seconds, writing a heartbeat file every second.
// The launcher must keep the game "running" while the child lives, and Stop must kill both.
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--child") == 0) {
        for (int i = 0; i < 120; i++) {
            FILE *f = fopen("spawner-heartbeat.txt", "w");
            if (f) { fprintf(f, "%d\n", i); fclose(f); }
            Sleep(1000);
        }
        return 0;
    }
    char path[MAX_PATH];
    GetModuleFileNameA(NULL, path, MAX_PATH);
    char cmd[MAX_PATH + 16];
    snprintf(cmd, sizeof cmd, "\"%s\" --child", path);
    STARTUPINFOA si = { sizeof si };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        printf("spawn failed: %lu\n", GetLastError());
        return 1;
    }
    printf("spawned child pid %lu\n", pi.dwProcessId);
    fflush(stdout);
    return 0;
}
