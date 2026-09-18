#include <errno.h>
#include <ctype.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
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

static int sibling_photorec(const char *argv0, char *result, size_t size) {
    char helper[PATH_MAX];
    char *slash;
    if (realpath(argv0, helper) == NULL) {
        return -1;
    }
    slash = strrchr(helper, '/');
    if (slash == NULL) {
        return -1;
    }
    *slash = '\0';
    if (snprintf(result, size, "%s/photorec", helper) >= (int)size ||
        access(result, X_OK) != 0) {
        return -1;
    }
    return 0;
}

static int prepare_session(const char *path, char *resolved, size_t size) {
    struct stat info;
    if (path[0] != '/' || realpath(path, resolved) == NULL ||
        lstat(resolved, &info) != 0 || !S_ISDIR(info.st_mode) ||
        S_ISLNK(info.st_mode) || access(resolved, W_OK) != 0 ||
        strlen(resolved) + 32 >= size) {
        return -1;
    }
    return 0;
}

static void signal_group(pid_t child, int signal_number) {
    if (kill(-child, signal_number) != 0) {
        kill(child, signal_number);
    }
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

static void write_progress(const char *path, off_t processed, off_t total) {
    char temporary[PATH_MAX];
    char contents[160];
    int fd;
    int length;

    if (processed < 0 || total <= 0 || processed > total ||
        snprintf(temporary, sizeof(temporary), "%s.tmp", path) >=
            (int)sizeof(temporary)) {
        return;
    }
    length = snprintf(contents, sizeof(contents),
                      "version=1\nprocessed=%lld\ntotal=%lld\n",
                      (long long)processed, (long long)total);
    if (length <= 0 || length >= (int)sizeof(contents)) {
        return;
    }
    fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) {
        return;
    }
    if (write(fd, contents, (size_t)length) == length) {
        close(fd);
        (void)rename(temporary, path);
    } else {
        close(fd);
        (void)unlink(temporary);
    }
}

static void forward_output_and_update_progress(
    int fd, char *history, size_t *history_length, off_t total,
    off_t *maximum_processed, const char *progress_path) {
    char chunk[4096];
    ssize_t count;

    while ((count = read(fd, chunk, sizeof(chunk))) > 0) {
        size_t writable = (size_t)count;
        const char *cursor = chunk;
        while (writable > 0) {
            ssize_t written = write(STDOUT_FILENO, cursor, writable);
            if (written < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            cursor += written;
            writable -= (size_t)written;
        }

        if ((size_t)count >= 8191) {
            memcpy(history, chunk + count - 8191, 8191);
            *history_length = 8191;
        } else {
            size_t incoming = (size_t)count;
            if (*history_length + incoming > 8191) {
                size_t remove = *history_length + incoming - 8191;
                memmove(history, history + remove, *history_length - remove);
                *history_length -= remove;
            }
            memcpy(history + *history_length, chunk, incoming);
            *history_length += incoming;
        }
        history[*history_length] = '\0';

        char *match = history;
        char *latest = NULL;
        while ((match = strstr(match, "Reading sector")) != NULL) {
            latest = match;
            match += strlen("Reading sector");
        }
        if (latest != NULL && total > 0) {
            char *number = latest + strlen("Reading sector");
            char *end = NULL;
            unsigned long long current_sector;
            unsigned long long total_sectors;
            while (*number != '\0' && !isdigit((unsigned char)*number)) {
                number++;
            }
            current_sector = strtoull(number, &end, 10);
            if (end != number && *end == '/') {
                total_sectors = strtoull(end + 1, &end, 10);
                if (total_sectors > 0 && current_sector <= total_sectors) {
                    off_t processed = (off_t)((long double)total * current_sector /
                                              total_sectors);
                    if (processed > *maximum_processed) {
                        *maximum_processed = processed;
                        write_progress(progress_path, processed, total);
                    }
                }
            }
        }
    }
}

static void update_disk_io_progress(pid_t child, off_t total,
                                    off_t *maximum_processed,
                                    const char *progress_path) {
    struct rusage_info_v2 usage;
    uint64_t bytes;

    memset(&usage, 0, sizeof(usage));
    if (total <= 0 || proc_pid_rusage(child, RUSAGE_INFO_V2,
                                     (rusage_info_t *)&usage) != 0) {
        return;
    }
    bytes = usage.ri_diskio_bytesread;
    if (bytes > (uint64_t)total) {
        bytes = (uint64_t)total;
    }
    if ((off_t)bytes > *maximum_processed) {
        *maximum_processed = (off_t)bytes;
        write_progress(progress_path, *maximum_processed, total);
    }
}

int main(int argc, char **argv) {
    char photorec[PATH_MAX];
    char session[PATH_MAX];
    char output_base[PATH_MAX];
    char log_path[PATH_MAX];
    char stop_path[PATH_MAX];
    char progress_path[PATH_MAX];
    char fd_path[64];
    char output_history[8192];
    struct stat stop_info;
    struct timespec pause_time = {.tv_sec = 0, .tv_nsec = 100000000};
    int source_fd;
    int flags;
    int status = 0;
    int cancel_ticks = 0;
    int cancellation_requested = 0;
    int progress_ticks = 0;
    off_t total_bytes;
    off_t expected_bytes;
    off_t maximum_processed = 0;
    int output_pipe[2];
    size_t output_history_length = 0;
    pid_t child;

    if (argc != 4) {
        fprintf(stderr, "usage: recoveryapp-readonly-helper SOURCE SESSION_DIRECTORY EXPECTED_BYTES\n");
        return 64;
    }
    {
        char *end = NULL;
        long long value = strtoll(argv[3], &end, 10);
        if (end == argv[3] || *end != '\0' || value <= 0) {
            fprintf(stderr, "Invalid expected source size.\n");
            return 64;
        }
        expected_bytes = (off_t)value;
    }
    if (sibling_photorec(argv[0], photorec, sizeof(photorec)) != 0) {
        fprintf(stderr, "Bundled PhotoRec is unavailable.\n");
        return 66;
    }
    if (prepare_session(argv[2], session, sizeof(session)) != 0) {
        fprintf(stderr, "Invalid result directory.\n");
        return 72;
    }
    if (valid_raw_device(argv[1]) && destination_is_on_device(argv[1], session)) {
        fprintf(stderr, "The result directory is on the source device.\n");
        return 73;
    }

    source_fd = valid_raw_device(argv[1])
                    ? authorized_read_fd(argv[1])
                    : local_read_fd(argv[1]);
    if (source_fd < 0) {
        fprintf(stderr, "Could not obtain read-only access to %s: %s\n", argv[1],
                strerror(errno));
        return 77;
    }
    flags = fcntl(source_fd, F_GETFD);
    if (flags < 0 || fcntl(source_fd, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
        close(source_fd);
        return 71;
    }

    snprintf(fd_path, sizeof(fd_path), "/dev/fd/%d", source_fd);
    snprintf(output_base, sizeof(output_base), "%s/Recovered", session);
    snprintf(log_path, sizeof(log_path), "%s/photorec.log", session);
    snprintf(stop_path, sizeof(stop_path), "%s/.recoveryapp-stop", session);
    snprintf(progress_path, sizeof(progress_path), "%s/.recoveryapp-progress", session);
    unlink(stop_path);
    unlink(progress_path);
    total_bytes = source_size(source_fd);
    if (total_bytes <= 0 || total_bytes != expected_bytes) {
        fprintf(stderr, "The selected source device has changed.\n");
        close(source_fd);
        return 74;
    }
    if (total_bytes > 0) {
        write_progress(progress_path, 0, total_bytes);
    }

    if (pipe(output_pipe) != 0) {
        close(source_fd);
        unlink(progress_path);
        return 71;
    }

    child = fork();
    if (child == 0) {
        close(output_pipe[0]);
        if (dup2(output_pipe[1], STDOUT_FILENO) < 0 ||
            dup2(output_pipe[1], STDERR_FILENO) < 0) {
            _exit(126);
        }
        close(output_pipe[1]);
        if (setsid() < 0 || chdir(session) != 0) {
            _exit(126);
        }
        execl(photorec, photorec, "/log", "/logname", log_path, "/d",
              output_base, "/cmd", fd_path,
              "partition_none,fileopt,everything,disable,jpg,enable,png,enable,mov,enable,search",
              (char *)NULL);
        _exit(126);
    }
    close(output_pipe[1]);
    if (child < 0) {
        close(output_pipe[0]);
        close(source_fd);
        unlink(progress_path);
        return 71;
    }
    flags = fcntl(output_pipe[0], F_GETFL);
    if (flags >= 0) {
        (void)fcntl(output_pipe[0], F_SETFL, flags | O_NONBLOCK);
    }

    while (waitpid(child, &status, WNOHANG) == 0) {
        progress_ticks++;
        forward_output_and_update_progress(
            output_pipe[0], output_history, &output_history_length, total_bytes,
            &maximum_processed, progress_path);
        if (progress_ticks == 1 || progress_ticks % 10 == 0) {
            update_disk_io_progress(child, total_bytes, &maximum_processed,
                                    progress_path);
        }
        if (lstat(stop_path, &stop_info) == 0) {
            cancellation_requested = 1;
            cancel_ticks++;
            if (cancel_ticks == 1) {
                signal_group(child, SIGINT);
            } else if (cancel_ticks == 31) {
                signal_group(child, SIGTERM);
            } else if (cancel_ticks == 51) {
                signal_group(child, SIGKILL);
            }
        }
        nanosleep(&pause_time, NULL);
    }
    forward_output_and_update_progress(
        output_pipe[0], output_history, &output_history_length, total_bytes,
        &maximum_processed, progress_path);
    close(output_pipe[0]);
    close(source_fd);
    unlink(stop_path);
    unlink(progress_path);
    if (cancellation_requested) {
        return 130;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 125;
}
