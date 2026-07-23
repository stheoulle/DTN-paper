/*
 * bare_csp_stack.h — CSP/CAN stack bring-up for Arm A (raw CSP) that never
 * includes cspcl.h and never calls a single CSPCL function.
 *
 * This exists so "raw CSP" is not just "the benchmarked send/receive calls
 * don't use cspcl_send_bundle()" but "this binary has zero CSPCL code paths
 * initialized or linked in" — csp_raw_sender/csp_raw_receiver link neither
 * cspcl.c nor libcspcl.a. The CSP-core tuning values (conn_max, buffers,
 * etc.) mirror exactly what cspcl_init() sets in cspcl/src/cspcl.c, so the
 * only difference between Arm A and Arm B remains whether csp_send()/
 * csp_read() or cspcl_send_bundle()/cspcl_recv_bundle() move the data —
 * not incidental differences in CSP-level configuration.
 */
#ifndef BENCH_BARE_CSP_STACK_H
#define BENCH_BARE_CSP_STACK_H

#include <stdint.h>

/* Returns 0 on success, -1 on failure (message printed to stderr). */
int bare_csp_stack_init(uint8_t local_addr, const char *can_iface);

#endif /* BENCH_BARE_CSP_STACK_H */
