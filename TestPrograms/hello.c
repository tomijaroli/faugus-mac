// Prints a line and exits 0. Built as 64-bit (hello.exe) and 32-bit (hello32.exe).
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    printf("hello from faugus (%d-bit)\n", (int)(sizeof(void *) * 8));
    for (int i = 1; i < argc; i++) printf("arg%d=%s\n", i, argv[i]);
    const char *id = getenv("FAUGUSID");
    if (id) printf("FAUGUSID=%s\n", id);
    fflush(stdout);
    return 0;
}
