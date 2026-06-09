#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define DEFAULT_PORT 4000
#define INTERVAL_MS 1000

static void die(const char *msg)
{
    perror(msg);
    exit(1);
}

int main(int argc, char *argv[])
{
    if (argc < 2 || argc > 3)
    {
        fprintf(stderr, "usage: %s <remote_ip> [port]\n", argv[0]);
        return 1;
    }

    const char *remote_ip = argv[1];
    int port = (argc == 3) ? atoi(argv[2]) : DEFAULT_PORT;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        die("socket");

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
    };
    if (inet_pton(AF_INET, remote_ip, &addr.sin_addr) != 1)
    {
        fprintf(stderr, "invalid address: %s\n", remote_ip);
        return 1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        die("connect");

    printf("connected to %s:%d\n", remote_ip, port);

    for (int seq = 1; seq < 1000; seq++)
    {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);

        char buf[256];
        int n = snprintf(buf, sizeof(buf),
                         "msg #%d  t=%ld.%03ld\n",
                         seq, (long)ts.tv_sec, ts.tv_nsec / 1000000L);

        if (write(fd, buf, n) != n)
        {
            fprintf(stderr, "write failed at msg #%d\n", seq);
            break;
        }

        printf("sent: %.*s", n, buf);
        fflush(stdout);

        struct timespec delay = {.tv_sec = 0, .tv_nsec = INTERVAL_MS * 1000000L};
        nanosleep(&delay, NULL);
    }

    close(fd);
    return 0;
}
