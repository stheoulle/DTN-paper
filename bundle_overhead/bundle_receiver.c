/*
 * bundle_receiver — Arm B receiver: pulls whole bundles off CSP via the real
 * cspcl_recv_bundle() (SFP reassembly), then unpacks the N embedded
 * bench_unit_hdr entries to compute per-unit one-way latency exactly like
 * csp_raw_receiver does for Arm A, so results are directly comparable.
 *
 * Usage: bundle_receiver <local_addr> <can_iface> [expected_bundles=0]
 *                        [timeout_ms=5000]
 *
 *   expected_bundles=0 : run until <timeout_ms> passes with no bundle
 *                        (used for the streaming test).
 */
#include "common.h"
#include "csp_stack.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#define MAX_SAMPLES 400000

static double samples[MAX_SAMPLES];
static int    n_samples = 0;

static void die(const char *msg)
{
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

static void print_stats(int bundles, int expected_bundles, long total_bytes, double elapsed_s)
{
    if (n_samples == 0) {
        printf("\n--- no bundles received ---\n");
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

    printf("\n--- bundle measurement summary ---\n");
    if (expected_bundles > 0)
        printf("bundles received: %d / %d  (%.1f%%)\n",
               bundles, expected_bundles, 100.0 * bundles / expected_bundles);
    else
        printf("bundles received: %d\n", bundles);
    printf("unit latency: min=%.3f ms  mean=%.3f ms  max=%.3f ms  stddev=%.3f ms  (n=%d units)\n",
           vmin, mean, vmax, stddev, n_samples);
    if (elapsed_s > 0.0)
        printf("throughput: %.2f bundles/sec  %.1f units/sec-equivalent  %.1f kB/s\n",
               bundles / elapsed_s, n_samples / elapsed_s, (total_bytes / 1000.0) / elapsed_s);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
            "usage: %s <local_addr> <can_iface> [expected_bundles=0] [timeout_ms=5000]\n",
            argv[0]);
        return 1;
    }

    uint8_t     local_addr       = (uint8_t) atoi(argv[1]);
    const char *can_iface        = argv[2];
    int         expected_bundles = (argc >= 4) ? atoi(argv[3]) : 0;
    uint32_t    timeout_ms       = (argc >= 5) ? (uint32_t) atoi(argv[4]) : 5000;

    cspcl_t cspcl;
    if (bench_stack_init(&cspcl, local_addr, can_iface, CSPCL_PORT_BP) != CSPCL_OK)
        die("bench_stack_init failed (check can_iface / CSP address clash)");

    static uint8_t bundle_buf[CSPCL_MAX_BUNDLE_SIZE];

    fprintf(stderr, "[bundle_receiver] listening on addr %u  (timeout=%u ms per bundle)\n",
            local_addr, timeout_ms);

    int  bundles = 0;
    long total_bytes = 0;
    struct timespec t_first, t_now;
    int  got_first = 0;

    for (;;) {
        size_t  len = sizeof(bundle_buf);
        uint8_t src_addr = 0, src_port = 0;

        cspcl_error_t err = cspcl_recv_bundle(&cspcl, bundle_buf, &len, &src_addr, &src_port,
                                              timeout_ms);
        if (err != CSPCL_OK) {
            fprintf(stderr, "cspcl_recv_bundle: %s -- stopping\n", cspcl_strerror(err));
            break;
        }

        if (!got_first) {
            clock_gettime(CLOCK_MONOTONIC, &t_first);
            got_first = 1;
        }

        int n = 0;
        if (len >= (size_t) BENCH_HDR_SIZE) {
            struct bench_unit_hdr first_hdr;
            memcpy(&first_hdr, bundle_buf, BENCH_HDR_SIZE);
            if (first_hdr.magic == BENCH_MAGIC && first_hdr.unit_size > 0)
                n = (int) (len / first_hdr.unit_size);
        }

        int64_t rsec, rnsec;
        bench_now(&rsec, &rnsec);

        if (n > 0) {
            struct bench_unit_hdr first_hdr;
            memcpy(&first_hdr, bundle_buf, BENCH_HDR_SIZE);
            size_t unit_size = first_hdr.unit_size;

            for (int u = 0; u < n; u++) {
                struct bench_unit_hdr hdr;
                memcpy(&hdr, bundle_buf + (size_t) u * unit_size, BENCH_HDR_SIZE);
                if (hdr.magic != BENCH_MAGIC)
                    continue;

                double lat = bench_latency_ms(hdr.send_sec, hdr.send_nsec, rsec, rnsec);
                if (n_samples < MAX_SAMPLES)
                    samples[n_samples++] = lat;
            }
        }

        total_bytes += (long) len;
        bundles++;

        printf("RECV_BUNDLE bundle_seq=%d n=%d bytes=%zu\n", bundles, n, len);
        fflush(stdout);

        if (expected_bundles > 0 && bundles >= expected_bundles)
            break;
    }

    clock_gettime(CLOCK_MONOTONIC, &t_now);
    double elapsed = got_first ? bench_elapsed_s(t_first, t_now) : 0.0;

    print_stats(bundles, expected_bundles, total_bytes, elapsed);

    return 0;
}
