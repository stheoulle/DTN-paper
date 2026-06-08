#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define DEFAULT_PORT 4000
#define BUF_SIZE     1024

static void die(const char *msg) {
    perror(msg);
    exit(1);
}

int main(int argc, char *argv[]) {
    if (argc > 2) {
        fprintf(stderr, "usage: %s [port]\n", argv[0]);
        return 1;
    }

    int port = (argc == 2) ? atoi(argv[1]) : DEFAULT_PORT;

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) die("socket");

    int yes = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) die("bind");
    if (listen(srv, 1) < 0) die("listen");

    printf("listening on port %d\n", port);

    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int conn = accept(srv, (struct sockaddr *)&peer, &plen);
        if (conn < 0) die("accept");

        char peer_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &peer.sin_addr, peer_ip, sizeof(peer_ip));
        printf("connection from %s:%d\n", peer_ip, ntohs(peer.sin_port));

        char buf[BUF_SIZE];
        ssize_t n;
        while ((n = read(conn, buf, sizeof(buf) - 1)) > 0) {
            buf[n] = '\0';

            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);

            printf("recv t=%ld.%03ld  %s",
                   (long)ts.tv_sec, ts.tv_nsec / 1000000L, buf);
            fflush(stdout);
        }

        printf("connection closed\n");
        close(conn);
    }

    close(srv);
    return 0;
}
