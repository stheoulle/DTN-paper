/*
 * bundle_sender — Arm B: the same fixed-size units as csp_raw_sender, but
 * N of them are batched into a single buffer and handed to the real
 * cspcl_send_bundle() (SFP fragmentation + RDP connection-pool logic,
 * exactly what a BPA calls to transmit a BP7 bundle over CSPCL). N is the
 * bundle-granularity sweep variable requested in Section 3 of
 * paper_comments.md, not the payload byte size.
 *
 * Each cspcl_send_bundle() call is timed with clock_gettime() around it —
 * that wall-clock delta is the real, measured cost of CSPCL's SFP
 * fragmentation loop + connection-pool lookup/eviction/invalidation +
 * underlying CSP sends, which is the "compute time" overhead the paper
 * needs, not a synthetic estimate.
 *
 * Usage: bundle_sender <local_addr> <dest_addr> <can_iface> <n_per_bundle>
 *                      <unit_size> <bundle_count> [duration_s=0]
 *
 *   duration_s > 0 : streaming mode — send bundles back to back until
 *                    <duration_s> seconds have elapsed (bundle_count is
 *                    ignored as a target and only used to cap huge runs).
 */
#include "common.h"
#include "csp_stack.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void die(const char *msg)
{
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

int main(int argc, char **argv)
{
    if (argc < 7) {
        fprintf(stderr,
            "usage: %s <local_addr> <dest_addr> <can_iface> <n_per_bundle> "
            "<unit_size> <bundle_count> [duration_s=0]\n",
            argv[0]);
        return 1;
    }

    uint8_t     local_addr   = (uint8_t) atoi(argv[1]);
    uint8_t     dest_addr    = (uint8_t) atoi(argv[2]);
    const char *can_iface    = argv[3];
    int         n            = atoi(argv[4]);
    int         unit_size    = atoi(argv[5]);
    int         bundle_count = atoi(argv[6]);
    double      duration_s   = (argc >= 8) ? atof(argv[7]) : 0.0;

    if (unit_size < BENCH_HDR_SIZE) {
        fprintf(stderr, "unit_size clamped to header size %d\n", BENCH_HDR_SIZE);
        unit_size = BENCH_HDR_SIZE;
    }
    if (n < 1) n = 1;

    size_t bundle_len = (size_t) n * (size_t) unit_size;
    if (bundle_len > CSPCL_MAX_BUNDLE_SIZE) {
        fprintf(stderr, "bundle too large: %zu > %d (reduce n_per_bundle or unit_size)\n",
                bundle_len, CSPCL_MAX_BUNDLE_SIZE);
        return 1;
    }

    cspcl_t cspcl;
    if (bench_stack_init(&cspcl, local_addr, can_iface, CSPCL_PORT_BP) != CSPCL_OK)
        die("bench_stack_init failed (check can_iface / CSP address clash)");

    uint8_t *bundle = malloc(bundle_len);
    if (!bundle) die("malloc failed");

    fprintf(stderr,
        "[bundle_sender] %u -> %u  N=%d  unit_size=%d  bundle_len=%zu  "
        "bundle_count=%d  duration_s=%.1f\n",
        local_addr, dest_addr, n, unit_size, bundle_len, bundle_count, duration_s);

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    int      sent = 0;
    uint32_t global_seq = 0;
    double   send_time_total_ms = 0.0;

    for (int b = 1;; b++) {
        if (duration_s > 0) {
            clock_gettime(CLOCK_MONOTONIC, &t_now);
            if (bench_elapsed_s(t_start, t_now) >= duration_s)
                break;
        } else if (b > bundle_count) {
            break;
        }

        for (int u = 0; u < n; u++) {
            struct bench_unit_hdr hdr;
            hdr.magic        = BENCH_MAGIC;
            hdr.seq          = ++global_seq;
            hdr.bundle_seq   = (uint32_t) b;
            hdr.n_per_bundle = (uint32_t) n;
            int64_t send_sec, send_nsec;
            bench_now(&send_sec, &send_nsec);
            hdr.send_sec  = send_sec;
            hdr.send_nsec = send_nsec;
            hdr.unit_size = (uint32_t) unit_size;

            uint8_t *slot = bundle + (size_t) u * (size_t) unit_size;
            memcpy(slot, &hdr, BENCH_HDR_SIZE);
            memset(slot + BENCH_HDR_SIZE, 0xAA, unit_size - BENCH_HDR_SIZE);
        }

        struct timespec ts0, ts1;
        clock_gettime(CLOCK_MONOTONIC, &ts0);
        cspcl_error_t err = cspcl_send_bundle(&cspcl, bundle, bundle_len, dest_addr, CSPCL_PORT_BP);
        clock_gettime(CLOCK_MONOTONIC, &ts1);
        double send_ms = (ts1.tv_sec - ts0.tv_sec) * 1e3 + (ts1.tv_nsec - ts0.tv_nsec) * 1e-6;

        if (err != CSPCL_OK) {
            fprintf(stderr, "cspcl_send_bundle failed at bundle=%d: %s\n", b, cspcl_strerror(err));
            break;
        }

        send_time_total_ms += send_ms;
        sent++;

        printf("SENT bundle=%d n=%d bytes=%zu send_time_ms=%.3f\n", b, n, bundle_len, send_ms);
        fflush(stdout);

        if (duration_s > 0 && bundle_count > 0 && sent >= bundle_count)
            break;
    }

    free(bundle);

    printf("SUMMARY bundles_sent=%d n_per_bundle=%d unit_size=%d bundle_len=%zu mean_send_ms=%.3f\n",
           sent, n, unit_size, bundle_len, sent > 0 ? send_time_total_ms / sent : 0.0);
    fflush(stdout);

    return 0;
}
