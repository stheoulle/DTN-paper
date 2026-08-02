/*
 * common.h — shared packet header and timing helpers for the bundle-overhead
 * benchmark (Section 3 of paper_comments.md: raw CSP vs CSP/BP via CSPCL).
 *
 * Every unit (a fixed-size chunk representing "one CSP packet's worth" of
 * application data) embeds this header so the receiver can compute one-way
 * latency from a single shared monotonic clock, exactly like apps/sender.c
 * and apps/receiver.c do for the IP-level measurements.
 */
#ifndef BENCH_COMMON_H
#define BENCH_COMMON_H

#include <stdint.h>
#include <time.h>

#define BENCH_MAGIC 0xC5BC0001U

struct __attribute__((packed)) bench_unit_hdr {
    uint32_t magic;
    uint32_t seq;          /* global unit sequence number */
    uint32_t bundle_seq;   /* which bundle this unit belongs to (0 for Arm A) */
    uint32_t n_per_bundle; /* bundle granularity N in effect when sent */
    int64_t  send_sec;
    int64_t  send_nsec;
    uint32_t unit_size;    /* per-unit size in bytes, header included */
};

#define BENCH_HDR_SIZE ((int)sizeof(struct bench_unit_hdr))

static inline void bench_now(int64_t *sec, int64_t *nsec)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    *sec  = (int64_t) ts.tv_sec;
    *nsec = (int64_t) ts.tv_nsec;
}

static inline double bench_latency_ms(int64_t send_sec, int64_t send_nsec,
                                       int64_t recv_sec, int64_t recv_nsec)
{
    return (double) (recv_sec - send_sec) * 1e3 + (double) (recv_nsec - send_nsec) * 1e-6;
}

static inline double bench_elapsed_s(struct timespec start, struct timespec now)
{
    return (double) (now.tv_sec - start.tv_sec) + (double) (now.tv_nsec - start.tv_nsec) * 1e-9;
}

#endif /* BENCH_COMMON_H */
