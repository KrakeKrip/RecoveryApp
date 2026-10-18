/* Synthetic-only test tools. NEVER ship these as recovery binaries. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef STREAM_DEFAULT_GATE
#define STREAM_DEFAULT_GATE ""
#endif
#ifndef STREAM_DEFAULT_SAVE_GATE
#define STREAM_DEFAULT_SAVE_GATE ""
#endif
#ifndef STREAM_GATE_TICKS
#define STREAM_GATE_TICKS 3000
#endif

static void marker(const char *name) {
    const char *value = getenv(name);
    if (!value || !*value) return;
    FILE *file = fopen(value, "w");
    if (file) { fputs("started\n", file); fclose(file); }
}

static int wait_gate(const char *name, const char *fallback) {
    const char *gate = getenv(name);
    if (!gate) gate = fallback;
    if (!gate || !*gate) return 0;
    for (int tick = 0; tick < STREAM_GATE_TICKS; ++tick) {
        if (access(gate, F_OK) == 0) return 0;
        usleep(10000);
    }
    return 88; /* A failed test must not leave a forever-running fixture. */
}

int main(int argc, char **argv) {
    if (strstr(argv[0], "icat")) {
        marker("RECOVERYAPP_STREAM_ICAT_STARTED");
        int status = wait_gate("RECOVERYAPP_STREAM_ICAT_GATE", STREAM_DEFAULT_SAVE_GATE);
        if (status) return status;
        if (getenv("RECOVERYAPP_STREAM_FAIL_SECOND") && argc > 1 &&
            strcmp(argv[argc - 1], "7") == 0) return 42;
        fputs("RECOVERED\n", stdout);
        return 0;
    }
    marker("RECOVERYAPP_STREAM_FLS_STARTED");
    /* This catches accidentally switching back to a pipe. No fflush: real
     * fls uses libc stdout and would otherwise hide short early listings. */
    if (!isatty(STDOUT_FILENO)) return 90;
    puts("r/r * 6:\tРанний_файл.JPG\t0\t0\t0\t0\t10\t0\t0");
    if (getenv("RECOVERYAPP_STREAM_STDERR_STRESS")) {
        for (int i = 0; i < 16000; ++i) fputs("synthetic diagnostic\n", stderr);
    }
    int status = wait_gate("RECOVERYAPP_STREAM_GATE", STREAM_DEFAULT_GATE);
    if (status) return status;
    puts("r/r * 7:\tLATE.MOV\t0\t0\t0\t0\t10\t0\t0");
    return 0;
}
