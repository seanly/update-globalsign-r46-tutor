#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

extern const unsigned char payload[];
extern const unsigned int payload_len;

static int write_all(int fd, const unsigned char *buf, unsigned int len)
{
    unsigned int off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            return -1;
        }
        off += (unsigned int)n;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int data_to_gzip[2];
    int gzip_to_bash[2];
    pid_t gzip_pid;
    pid_t bash_pid;
    int status;
    char **args;
    int i;

    if (pipe(data_to_gzip) != 0 || pipe(gzip_to_bash) != 0) {
        perror("pipe");
        return 127;
    }

    gzip_pid = fork();
    if (gzip_pid < 0) {
        perror("fork");
        return 127;
    }
    if (gzip_pid == 0) {
        dup2(data_to_gzip[0], STDIN_FILENO);
        dup2(gzip_to_bash[1], STDOUT_FILENO);
        close(data_to_gzip[0]);
        close(data_to_gzip[1]);
        close(gzip_to_bash[0]);
        close(gzip_to_bash[1]);
        execl("/bin/gzip", "gzip", "-dc", (char *)NULL);
        perror("gzip");
        _exit(127);
    }

    bash_pid = fork();
    if (bash_pid < 0) {
        perror("fork");
        return 127;
    }
    if (bash_pid == 0) {
        dup2(gzip_to_bash[0], STDIN_FILENO);
        close(data_to_gzip[0]);
        close(data_to_gzip[1]);
        close(gzip_to_bash[0]);
        close(gzip_to_bash[1]);
        args = malloc((size_t)(argc + 3) * sizeof(char *));
        if (args == NULL) {
            _exit(127);
        }
        args[0] = "/bin/bash";
        args[1] = "-s";
        args[2] = "--";
        for (i = 1; i < argc; i++) {
            args[i + 2] = argv[i];
        }
        args[argc + 2] = NULL;
        execv("/bin/bash", args);
        perror("bash");
        _exit(127);
    }

    close(data_to_gzip[0]);
    close(gzip_to_bash[0]);
    close(gzip_to_bash[1]);
    if (write_all(data_to_gzip[1], payload, payload_len) != 0) {
        perror("write");
        return 127;
    }
    close(data_to_gzip[1]);

    if (waitpid(bash_pid, &status, 0) < 0) {
        perror("waitpid");
        return 127;
    }
    waitpid(gzip_pid, NULL, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 127;
}
