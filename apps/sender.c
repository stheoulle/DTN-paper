#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#define DEFAULT_PORT  4000
#define DEFAULT_COUNT 5

static void die(const char *msg) { perror(msg); exit(1); }

int main(int argc, char *argv[])
{
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: %s <remote_ip> [port] [count]\n", argv[0]);
        return 1;
    }

    const char *remote_ip = argv[1];
    int port  = (argc >= 3) ? atoi(argv[2]) : DEFAULT_PORT;
    int count = (argc >= 4) ? atoi(argv[3]) : DEFAULT_COUNT;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) die("socket");

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port   = htons(port);
    if (inet_pton(AF_INET, remote_ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "invalid address: %s\n", remote_ip);
        return 1;
    }

    printf("sending %d UDP datagram(s) to %s:%d\n", count, remote_ip, port);

    for (int seq = 1; seq <= count; seq++) {
        char buf[256];
        int n = snprintf(buf, sizeof(buf), "hello from alice, msg #%d\n", seq);

        if (sendto(fd, buf, n, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
            perror("sendto");
            break;
        }

        printf("sent: %s", buf);
        fflush(stdout);

        if (seq < count)
            sleep(1);
    }

    close(fd);
    return 0;
}
