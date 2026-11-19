// Command-line runner for FluxaFF.c, used by CI to test every conversion without a simulator.
// Usage: fxrun probe <file>      prints the probe JSON
//        fxrun run <ffmpeg-style options...>
#include <stdio.h>
#include <string.h>
#include "FluxaFF.h"

static void progress(double seconds, double speed, void *ctx) {
    (void)ctx;
    fprintf(stderr, "progress %.2fs speed %.2fx\n", seconds, speed);
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "probe") == 0) {
        char *json = fx_probe_json(argv[2]);
        if (!json) { fprintf(stderr, "probe failed\n"); return 2; }
        puts(json);
        fx_free(json);
        return 0;
    }
    if (argc >= 3 && strcmp(argv[1], "run") == 0) {
        volatile int cancel = 0;
        int code = fx_execute(argc - 2, (const char *const *)(argv + 2), progress, NULL, &cancel);
        if (code != 0) fprintf(stderr, "failed (%d): %s\n", code, fx_last_error());
        return code == 0 ? 0 : 1;
    }
    fprintf(stderr, "usage: fxrun probe <file> | fxrun run <options>\n");
    return 64;
}
