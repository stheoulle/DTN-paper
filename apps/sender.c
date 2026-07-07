/*
 * sender — measurement-capable UDP sender for the DTN/CSPCL experiment.
 *
 * Embeds a monotonic timestamp and sequence number in every datagram so the
 * receiver can compute one-way end-to-end latency without clock synchronisation
 * (both sides run on the same machine).
 *
 * Usage: sender <remote_ip> [port=4000] [count=100] [size=256] [interval_ms=0]
 *   size        total datagram size in bytes (minimum 28, the header size)
 *   interval_ms 0 = burst (no sleep between sends)
 */

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>

#define DEFAULT_PORT        4000
#define DEFAULT_COUNT       100
#define DEFAULT_SIZE        256
#define DEFAULT_INTERVAL_MS 0

#define PKT_MAGIC 0xD3CA0000U

/* Packed header embedded at the start of every datagram. */
struct __attribute__((packed)) pkt_hdr {
    uint32_t magic;
    uint32_t seq;
    int64_t  send_sec;
    int64_t  send_nsec;
    uint32_t size;
};

#define HDR_SIZE ((int)sizeof(struct pkt_hdr))

static void die(const char *msg) { perror(msg); exit(1); }

int main(int argc, char *argv[])
{
    if (argc < 2 || argc > 6) {
        fprintf(stderr,
            "usage: %s <remote_ip> [port=%d] [count=%d] [size=%d] [interval_ms=%d]\n",
            argv[0], DEFAULT_PORT, DEFAULT_COUNT, DEFAULT_SIZE, DEFAULT_INTERVAL_MS);
        return 1;
    }

    const char *remote_ip   = argv[1];
    int port        = (argc >= 3) ? atoi(argv[2]) : DEFAULT_PORT;
    int count       = (argc >= 4) ? atoi(argv[3]) : DEFAULT_COUNT;
    int size        = (argc >= 5) ? atoi(argv[4]) : DEFAULT_SIZE;
    int interval_ms = (argc >= 6) ? atoi(argv[5]) : DEFAULT_INTERVAL_MS;

    if (size < HDR_SIZE) {
        fprintf(stderr, "size clamped to minimum %d (header size)\n", HDR_SIZE);
        size = HDR_SIZE;
    }

    char *buf = malloc(size);
    if (!buf) die("malloc");
    memset(buf + HDR_SIZE, 0xAA, size - HDR_SIZE);   /* deterministic padding */

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

    fprintf(stderr,
        "sending %d packet(s) to %s:%d  size=%d bytes  interval=%d ms\n",
        count, remote_ip, port, size, interval_ms);

    for (int seq = 1; seq <= count; seq++) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);

        struct pkt_hdr hdr = {
            .magic     = PKT_MAGIC,
            .seq       = (uint32_t)seq,
            .send_sec  = (int64_t)ts.tv_sec,
            .send_nsec = (int64_t)ts.tv_nsec,
            .size      = (uint32_t)size,
        };
        memcpy(buf, &hdr, HDR_SIZE);

        if (sendto(fd, buf, size, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
            perror("sendto");
            break;
        }

        printf("SEND seq=%d ts=%ld.%09ld size=%d\n",
               seq, ts.tv_sec, ts.tv_nsec, size);
        fflush(stdout);

        if (interval_ms > 0 && seq < count)
            usleep((useconds_t)interval_ms * 1000);
    }

    free(buf);
    close(fd);
    return 0;
}
