#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int valid_raw_device(const char *path) {
    const char *cursor;
    if (strncmp(path, "/dev/rdisk", 10) != 0) {
        return 0;
    }
    cursor = path + 10;
    if (*cursor < '0' || *cursor > '9') {
        return 0;
    }
    while (*cursor >= '0' && *cursor <= '9') {
        cursor++;
    }
    while (*cursor != '\0') {
        if (*cursor++ != 's' || *cursor < '0' || *cursor > '9') {
            return 0;
        }
        while (*cursor >= '0' && *cursor <= '9') {
            cursor++;
        }
    }
    return 1;
}

static int receive_fd(int socket_fd) {
    char byte = 0;
    char control[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {.iov_base = &byte, .iov_len = sizeof(byte)};
    struct msghdr message;
    struct cmsghdr *header;
    int received = -1;

    memset(&message, 0, sizeof(message));
    memset(control, 0, sizeof(control));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    if (recvmsg(socket_fd, &message, 0) < 0) {
        return -1;
    }
    for (header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS &&
            header->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(&received, CMSG_DATA(header), sizeof(received));
            break;
        }
    }
    return received;
}

static int authorized_read_fd(const char *device) {
    int sockets[2];
    int received;
    int status = 0;
    pid_t child;

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        return -1;
    }
    child = fork();
    if (child == 0) {
        close(sockets[0]);
        if (dup2(sockets[1], STDOUT_FILENO) < 0) {
            _exit(126);
        }
        close(sockets[1]);
        execl("/usr/libexec/authopen", "authopen", "-stdoutpipe", "-extauth",
              device, (char *)NULL);
        _exit(127);
    }
    close(sockets[1]);
    if (child < 0) {
        close(sockets[0]);
        return -1;
    }
    received = receive_fd(sockets[0]);
    close(sockets[0]);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || received < 0) {
        if (received >= 0) {
            close(received);
        }
        return -1;
    }
    return received;
}

static int local_read_fd(const char *path) {
    char resolved[PATH_MAX];
    struct stat info;
    if (path[0] != '/' || realpath(path, resolved) == NULL ||
        stat(resolved, &info) != 0 || !S_ISREG(info.st_mode)) {
        errno = EINVAL;
        return -1;
    }
    return open(resolved, O_RDONLY | O_CLOEXEC);
}

static off_t source_size(int fd) {
    uint64_t block_count = 0;
    uint32_t block_size = 0;
    struct stat info;
    if (ioctl(fd, DKIOCGETBLOCKCOUNT, &block_count) == 0 &&
        ioctl(fd, DKIOCGETBLOCKSIZE, &block_size) == 0 && block_size > 0 &&
        block_count <= (uint64_t)LLONG_MAX / block_size) {
        return (off_t)(block_count * block_size);
    }
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode)) {
        return info.st_size;
    }
    return -1;
}

static int sibling_tool(const char *argv0, const char *name, char *result,
                        size_t size) {
    char helper[PATH_MAX];
    char *slash;
    if (realpath(argv0, helper) == NULL || (slash = strrchr(helper, '/')) == NULL) {
        return -1;
    }
    *slash = '\0';
    if (snprintf(result, size, "%s/%s", helper, name) >= (int)size ||
        access(result, X_OK) != 0) {
        return -1;
    }
    return 0;
}

static int destination_is_on_device(const char *device, const char *directory) {
    struct statfs info;
    const char *digits = device + strlen("/dev/rdisk");
    char prefix[32];
    size_t digit_count = 0;
    if (!valid_raw_device(device) || statfs(directory, &info) != 0) {
        return 0;
    }
    while (digits[digit_count] >= '0' && digits[digit_count] <= '9') {
        digit_count++;
    }
    if (digit_count == 0 || digit_count > 12) {
        return 0;
    }
    snprintf(prefix, sizeof(prefix), "/dev/disk%.*s", (int)digit_count, digits);
    return strncmp(info.f_mntfromname, prefix, strlen(prefix)) == 0;
}

static int valid_destination_directory(const char *path) {
    char resolved[PATH_MAX];
    struct stat info;
    return path[0] == '/' && realpath(path, resolved) != NULL &&
           lstat(resolved, &info) == 0 && S_ISDIR(info.st_mode) &&
           !S_ISLNK(info.st_mode) && access(resolved, W_OK) == 0;
}

static int nonnegative_number(const char *value) {
    const unsigned char *cursor = (const unsigned char *)value;
    if (*cursor == '\0') {
        return 0;
    }
    while (*cursor != '\0') {
        if (*cursor < '0' || *cursor > '9') {
            return 0;
        }
        cursor++;
    }
    return 1;
}

static int valid_filesystem_type(const char *value) {
    return strcmp(value, "fat32") == 0 || strcmp(value, "exfat") == 0;
}

int main(int argc, char **argv) {
    char tool[PATH_MAX];
    char fd_path[64];
    char *end = NULL;
    long long expected_value;
    int source_fd;
    int flags;

    if (argc < 4 || argc > 8 ||
        (strcmp(argv[1], "mmls") != 0 && strcmp(argv[1], "fls") != 0 &&
         strcmp(argv[1], "icat") != 0)) {
        fprintf(stderr, "usage: recoveryapp-metadata-helper TOOL SOURCE EXPECTED_BYTES [OUTPUT_DIRECTORY] [OFFSET] [INODE] [FSTYPE]\n");
        return 64;
    }
    if ((strcmp(argv[1], "mmls") == 0 && argc != 4) ||
        (strcmp(argv[1], "fls") == 0 && argc != 6) ||
        (strcmp(argv[1], "icat") == 0 && argc != 8)) {
        fprintf(stderr, "Invalid arguments.\n");
        return 64;
    }
    expected_value = strtoll(argv[3], &end, 10);
    if (end == argv[3] || *end != '\0' || expected_value <= 0) {
        fprintf(stderr, "Invalid expected source size.\n");
        return 64;
    }
    if ((argc == 6 && !nonnegative_number(argv[4])) ||
        (argc == 8 && (!nonnegative_number(argv[5]) || !nonnegative_number(argv[6])))) {
        fprintf(stderr, "Invalid metadata identifier.\n");
        return 64;
    }
    if ((argc == 6 && !valid_filesystem_type(argv[5])) ||
        (argc == 8 && !valid_filesystem_type(argv[7]))) {
        fprintf(stderr, "Unsupported filesystem type.\n");
        return 64;
    }
    if (argc == 8 && !valid_destination_directory(argv[4])) {
        fprintf(stderr, "Invalid result directory.\n");
        return 72;
    }
    if (argc == 8 && valid_raw_device(argv[2]) &&
        destination_is_on_device(argv[2], argv[4])) {
        fprintf(stderr, "The result directory is on the source device.\n");
        return 73;
    }
    if (sibling_tool(argv[0], argv[1], tool, sizeof(tool)) != 0) {
        fprintf(stderr, "Bundled metadata tool is unavailable.\n");
        return 66;
    }

    source_fd = valid_raw_device(argv[2]) ? authorized_read_fd(argv[2])
                                          : local_read_fd(argv[2]);
    if (source_fd < 0) {
        fprintf(stderr, "Could not obtain read-only access to %s: %s\n", argv[2],
                strerror(errno));
        return 77;
    }
    if (source_size(source_fd) != (off_t)expected_value) {
        fprintf(stderr, "The selected source device has changed.\n");
        close(source_fd);
        return 74;
    }
    flags = fcntl(source_fd, F_GETFL);
    if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY) {
        fprintf(stderr, "The source descriptor is not read-only.\n");
        close(source_fd);
        return 75;
    }
    /* Keep the authorized descriptor on stdin across exec. Some hardened
     * macOS processes do not preserve arbitrary inherited descriptors even
     * after FD_CLOEXEC is cleared, while stdin is stable. The Sleuth Kit tools
     * used here are non-interactive and never consume stdin. */
    if (source_fd != STDIN_FILENO) {
        if (dup2(source_fd, STDIN_FILENO) < 0) {
            close(source_fd);
            return 71;
        }
        close(source_fd);
        source_fd = STDIN_FILENO;
    }
    flags = fcntl(source_fd, F_GETFD);
    if (flags < 0 || fcntl(source_fd, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
        close(source_fd);
        return 71;
    }
    snprintf(fd_path, sizeof(fd_path), "/dev/fd/%d", source_fd);

    if (strcmp(argv[1], "mmls") == 0) {
        execl(tool, tool, fd_path, (char *)NULL);
    } else if (strcmp(argv[1], "fls") == 0) {
        if (strcmp(argv[4], "0") == 0) {
            execl(tool, tool, "-f", argv[5], "-r", "-d", "-p", fd_path,
                  (char *)NULL);
        } else {
            execl(tool, tool, "-f", argv[5], "-o", argv[4], "-r", "-d", "-p",
                  fd_path, (char *)NULL);
        }
    } else if (strcmp(argv[5], "0") == 0) {
        execl(tool, tool, "-f", argv[7], "-r", fd_path, argv[6], (char *)NULL);
    } else {
        execl(tool, tool, "-f", argv[7], "-r", "-o", argv[5], fd_path, argv[6],
              (char *)NULL);
    }
    fprintf(stderr, "Could not launch metadata tool: %s\n", strerror(errno));
    close(source_fd);
    return 126;
}
