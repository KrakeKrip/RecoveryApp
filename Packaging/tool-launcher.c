#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: tool-launcher <executable> [arguments...]\n");
        return 64;
    }

    if (setpgid(0, 0) != 0) {
        fprintf(stderr, "setpgid failed: %d\n", errno);
        return 70;
    }

    execv(argv[1], &argv[1]);
    fprintf(stderr, "execv failed: %d\n", errno);
    return 71;
}
