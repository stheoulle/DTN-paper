/*
 * receiver — measurement-capable UDP receiver for the DTN/CSPCL experiment.
 *
 * Decodes the header written by sender, computes one-way latency using the
 * embedded monotonic timestamp, and prints per-packet lines plus a final
 * summary (min/mean/max/stddev, delivery rate).
 *
 * Usage: receiver [port=4000] [expected_count=0]
 *   expected_count  exit automatically after this many packets (0 = run forever,
 *                   stop with Ctrl-C to print stats)
 *
 * Send SIGINT or SIGTERM at any time to print stats and exit.
 */

#include <arpa/inet.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>

#define DEFAULT_PORT  4000
#define BUF_SIZE      65536
#define PKT_MAGIC     0xD3CA0000U
#define MAX_SAMPLES   100000

struct __attribute__((packed)) pkt_hdr {
    uint32_t magic;
    uint32_t seq;
    int64_t  send_sec;
    int64_t  send_nsec;
    uint32_t size;
};

static double samples[MAX_SAMPLES];
static int    n_samples  = 0;
static int    expected   = 0;

static void print_stats(void)
{
    if (n_samples == 0) {
        printf("\n--- no packets received ---\n");
        return;
    }

    double sum = 0.0, vmin = samples[0], vmax = samples[0];
    for (int i = 0; i < n_samples; i++) {
        sum += samples[i];
        if (samples[i] < vmin) vmin = samples[i];
        if (samples[i] > vmax) vmax = samples[i];
    }
    double mean = sum / n_samples;

    double var = 0.0;
    for (int i = 0; i < n_samples; i++) {
        double d = samples[i] - mean;
        var += d * d;
    }
    double stddev = (n_samples > 1) ? sqrt(var / n_samples) : 0.0;

    printf("\n--- measurement summary ---\n");
    if (expected > 0)
        printf("received : %d / %d  (%.1f%% delivery rate)\n",
               n_samples, expected, 100.0 * n_samples / expected);
    else
        printf("received : %d\n", n_samples);
    printf("latency  : min=%.3f ms  mean=%.3f ms  max=%.3f ms  stddev=%.3f ms\n",
           vmin, mean, vmax, stddev);
}

static void sig_handler(int sig)
{
    (void)sig;
    print_stats();
    _exit(0);
}

static void die(const char *msg) { perror(msg); exit(1); }

int main(int argc, char *argv[])
{
    if (argc > 3) {
        fprintf(stderr, "usage: %s [port=%d] [expected_count=0]\n",
                argv[0], DEFAULT_PORT);
        return 1;
    }

    int port = (argc >= 2) ? atoi(argv[1]) : DEFAULT_PORT;
    expected = (argc >= 3) ? atoi(argv[2]) : 0;

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);

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

    fprintf(stderr, "listening on :%d", port);
    if (expected > 0)
        fprintf(stderr, "  (will print stats after %d packets)", expected);
    fprintf(stderr, "\n");

    static char buf[BUF_SIZE];

    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0,
                             (struct sockaddr *)&peer, &plen);
        if (n < 0) die("recvfrom");

        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);

        if ((size_t)n < sizeof(struct pkt_hdr)) {
            fprintf(stderr, "short packet (%zd bytes), skipping\n", n);
            continue;
        }

        struct pkt_hdr hdr;
        memcpy(&hdr, buf, sizeof(hdr));

        if (hdr.magic != PKT_MAGIC) {
            fprintf(stderr, "bad magic 0x%08X, skipping\n", hdr.magic);
            continue;
        }

        double lat_ms = (double)(ts.tv_sec  - hdr.send_sec ) * 1e3
                      + (double)(ts.tv_nsec - hdr.send_nsec) * 1e-6;

        printf("RECV seq=%u latency=%.3fms size=%u\n",
               hdr.seq, lat_ms, hdr.size);
        fflush(stdout);

        if (n_samples < MAX_SAMPLES)
            samples[n_samples++] = lat_ms;

        if (expected > 0 && n_samples >= expected) {
            print_stats();
            close(fd);
            return 0;
        }
    }
}
