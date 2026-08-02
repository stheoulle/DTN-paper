/*
 * csp_raw_sender — Arm A baseline: raw CSP-to-CSP over CAN, no CSPCL/BP
 * framing at all. See bundle_overhead/README.md for the full rationale.
 *
 * Opens ONE CSP RDP connection at startup (typical legacy-CSP usage: a
 * persistent connection reused for many packets) and sends packets of
 * <unit_size> bytes back to back, either <count> of them or for
 * <duration_s> seconds (streaming mode). Each packet embeds a
 * bench_unit_hdr so the receiver can compute one-way latency.
 *
 * Usage: csp_raw_sender <local_addr> <dest_addr> <can_iface> <count>
 *                       <unit_size> [duration_s=0] [dest_port=20]
 *
 *   duration_s > 0 : streaming mode — ignore <count> as a target, send until
 *                    <duration_s> seconds have elapsed (report the actual
 *                    count sent).
 */
#include "bare_csp_stack.h"
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <csp/csp.h>

#define RAW_PORT_DEFAULT 20

static void die(const char *msg)
{
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr,
            "usage: %s <local_addr> <dest_addr> <can_iface> <count> <unit_size> "
            "[duration_s=0] [dest_port=%d]\n",
            argv[0], RAW_PORT_DEFAULT);
        return 1;
    }

    uint8_t     local_addr  = (uint8_t) atoi(argv[1]);
    uint8_t     dest_addr   = (uint8_t) atoi(argv[2]);
    const char *can_iface   = argv[3];
    int         count       = atoi(argv[4]);
    int         unit_size   = atoi(argv[5]);
    double      duration_s  = (argc >= 7) ? atof(argv[6]) : 0.0;
    uint8_t     dest_port   = (argc >= 8) ? (uint8_t) atoi(argv[7]) : RAW_PORT_DEFAULT;

    if (unit_size < BENCH_HDR_SIZE) {
        fprintf(stderr, "unit_size clamped to header size %d\n", BENCH_HDR_SIZE);
        unit_size = BENCH_HDR_SIZE;
    }

    if (bare_csp_stack_init(local_addr, can_iface) != 0)
        die("bare_csp_stack_init failed (check can_iface / CSP address clash)");

    csp_conn_t *conn = csp_connect(CSP_PRIO_NORM, dest_addr, dest_port, 1000, CSP_O_RDP);
    if (!conn)
        die("csp_connect failed — is the receiver listening?");

    fprintf(stderr,
        "[csp_raw_sender] %u -> %u:%u  unit_size=%d  count=%d  duration_s=%.1f\n",
        local_addr, dest_addr, dest_port, unit_size, count, duration_s);

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    int    sent = 0;
    double send_time_total_ms = 0.0;

    for (int seq = 1;; seq++) {
        if (duration_s > 0) {
            clock_gettime(CLOCK_MONOTONIC, &t_now);
            if (bench_elapsed_s(t_start, t_now) >= duration_s)
                break;
        } else if (seq > count) {
            break;
        }

        csp_packet_t *packet = csp_buffer_get(unit_size);
        if (!packet) {
            fprintf(stderr, "csp_buffer_get failed at seq=%d\n", seq);
            break;
        }

        struct bench_unit_hdr hdr;
        hdr.magic        = BENCH_MAGIC;
        hdr.seq          = (uint32_t) seq;
        hdr.bundle_seq   = 0;
        hdr.n_per_bundle = 1;
        int64_t send_sec, send_nsec;
        bench_now(&send_sec, &send_nsec);
        hdr.send_sec  = send_sec;
        hdr.send_nsec = send_nsec;
        hdr.unit_size = (uint32_t) unit_size;

        memcpy(packet->data, &hdr, BENCH_HDR_SIZE);
        memset(packet->data + BENCH_HDR_SIZE, 0xAA, unit_size - BENCH_HDR_SIZE);
        packet->length = unit_size;

        struct timespec ts0, ts1;
        clock_gettime(CLOCK_MONOTONIC, &ts0);
        int ok = csp_send(conn, packet, 1000);
        clock_gettime(CLOCK_MONOTONIC, &ts1);
        send_time_total_ms += (ts1.tv_sec - ts0.tv_sec) * 1e3 + (ts1.tv_nsec - ts0.tv_nsec) * 1e-6;

        if (!ok) {
            fprintf(stderr, "csp_send failed at seq=%d\n", seq);
            csp_buffer_free(packet);
            break;
        }
        /* On success csp_send() takes ownership of packet; do not free it. */

        sent++;
    }

    csp_close(conn);

    printf("SUMMARY sent=%d unit_size=%d mean_send_us=%.1f\n",
           sent, unit_size, sent > 0 ? (send_time_total_ms * 1000.0 / sent) : 0.0);
    fflush(stdout);

    return 0;
}
