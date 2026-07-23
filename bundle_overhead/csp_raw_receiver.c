/*
 * csp_raw_receiver — Arm A baseline receiver: accepts the single persistent
 * CSP RDP connection opened by csp_raw_sender and reads packets off it,
 * computing one-way latency and throughput exactly like apps/receiver.c
 * does at the IP layer.
 *
 * Usage: csp_raw_receiver <local_addr> <can_iface> [expected_count=0]
 *                         [dest_port=20] [accept_timeout_ms=10000]
 *                         [read_timeout_ms=5000]
 *
 *   expected_count=0 : run until <read_timeout_ms> passes with no packet
 *                      (used for the streaming test, where the sender runs
 *                      for a fixed duration and stops).
 */
#include "bare_csp_stack.h"
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include <csp/csp.h>

#define RAW_PORT_DEFAULT 20
#define MAX_SAMPLES 400000

static double samples[MAX_SAMPLES];
static int    n_samples = 0;

static void die(const char *msg)
{
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

static void print_stats(int expected, long total_bytes, double elapsed_s)
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

    printf("\n--- csp_raw measurement summary ---\n");
    if (expected > 0)
        printf("received : %d / %d  (%.1f%% delivery rate)\n",
               n_samples, expected, 100.0 * n_samples / expected);
    else
        printf("received : %d\n", n_samples);
    printf("latency  : min=%.3f ms  mean=%.3f ms  max=%.3f ms  stddev=%.3f ms\n",
           vmin, mean, vmax, stddev);
    if (elapsed_s > 0.0)
        printf("throughput: %.1f packets/sec  %.1f kB/s\n",
               n_samples / elapsed_s, (total_bytes / 1000.0) / elapsed_s);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
            "usage: %s <local_addr> <can_iface> [expected_count=0] [dest_port=%d] "
            "[accept_timeout_ms=10000] [read_timeout_ms=5000]\n",
            argv[0], RAW_PORT_DEFAULT);
        return 1;
    }

    uint8_t     local_addr        = (uint8_t) atoi(argv[1]);
    const char *can_iface         = argv[2];
    int         expected          = (argc >= 4) ? atoi(argv[3]) : 0;
    uint8_t     port               = (argc >= 5) ? (uint8_t) atoi(argv[4]) : RAW_PORT_DEFAULT;
    uint32_t    accept_timeout_ms = (argc >= 6) ? (uint32_t) atoi(argv[5]) : 10000;
    uint32_t    read_timeout_ms   = (argc >= 7) ? (uint32_t) atoi(argv[6]) : 5000;

    if (bare_csp_stack_init(local_addr, can_iface) != 0)
        die("bare_csp_stack_init failed (check can_iface / CSP address clash)");

    csp_socket_t *sock = csp_socket(CSP_SO_RDPREQ);
    if (!sock) die("csp_socket failed");
    if (csp_bind(sock, port) != CSP_ERR_NONE) die("csp_bind failed");
    if (csp_listen(sock, 5) != CSP_ERR_NONE) die("csp_listen failed");

    fprintf(stderr, "[csp_raw_receiver] listening on addr %u port %u\n", local_addr, port);

    csp_conn_t *conn = csp_accept(sock, accept_timeout_ms);
    if (!conn) die("csp_accept timed out — is csp_raw_sender running?");

    struct timespec t_first, t_now;
    int  got_first = 0;
    long total_bytes = 0;

    for (;;) {
        csp_packet_t *packet = csp_read(conn, read_timeout_ms);
        if (!packet)
            break; /* timeout: sender finished (or streaming window elapsed) */

        if (!got_first) {
            clock_gettime(CLOCK_MONOTONIC, &t_first);
            got_first = 1;
        }

        if (packet->length >= (uint16_t) BENCH_HDR_SIZE) {
            struct bench_unit_hdr hdr;
            memcpy(&hdr, packet->data, BENCH_HDR_SIZE);

            if (hdr.magic == BENCH_MAGIC) {
                int64_t rsec, rnsec;
                bench_now(&rsec, &rnsec);
                double lat = bench_latency_ms(hdr.send_sec, hdr.send_nsec, rsec, rnsec);

                if (n_samples < MAX_SAMPLES)
                    samples[n_samples++] = lat;
                total_bytes += packet->length;

                printf("RECV seq=%u latency=%.3fms size=%u\n", hdr.seq, lat, hdr.unit_size);
                fflush(stdout);
            }
        }

        csp_buffer_free(packet);

        if (expected > 0 && n_samples >= expected)
            break;
    }

    clock_gettime(CLOCK_MONOTONIC, &t_now);
    double elapsed = got_first ? bench_elapsed_s(t_first, t_now) : 0.0;

    print_stats(expected, total_bytes, elapsed);
    csp_close(conn);

    return 0;
}
