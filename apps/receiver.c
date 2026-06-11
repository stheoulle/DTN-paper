#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#define DEFAULT_PORT 4000
#define BUF_SIZE     1024

static void die(const char *msg) { perror(msg); exit(1); }

int main(int argc, char *argv[])
{
    if (argc > 2) {
        fprintf(stderr, "usage: %s [port]\n", argv[0]);
        return 1;
    }

    int port = (argc == 2) ? atoi(argv[1]) : DEFAULT_PORT;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) die("socket");

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) die("bind");

    printf("listening for UDP on port %d\n", port);
    fflush(stdout);

    for (;;) {
        char buf[BUF_SIZE];
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);

        ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0,
                             (struct sockaddr *)&peer, &plen);
        if (n < 0) die("recvfrom");
        buf[n] = '\0';

        char peer_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &peer.sin_addr, peer_ip, sizeof(peer_ip));

        printf("recv from %s:%d  %s",
               peer_ip, ntohs(peer.sin_port), buf);
        fflush(stdout);
    }

    close(fd);
    return 0;
}
