/* pool_bench.c -- live connection-pool hit-rate benchmark for CSPCL.
 *
 * NOT a unit test (no asserts). Exercises the *real* cspcl_send_bundle() /
 * connection-pool code in cspcl.c -- the same code path unibo-bp-cspcl
 * (cspcl_daemon.c) calls for every outbound bundle -- under a burst or
 * paced send pattern against a real peer process, then prints the pool's
 * real cspcl_conn_pool_get_stats() counters.
 *
 * Why ZMQ hub instead of the real 4-hop demo chain's CAN link: this
 * benchmark was written in a sandboxed session with no root/sudo
 * available, so vcan0, network namespaces, and Charon's TUN devices (all
 * required by contact_rate/test_paced_delivery.sh) could not be created.
 * CSPCL's "zmqhub" interface (cspcl_daemon.c's own `-i zmqhub` option,
 * documented there as "for testing/ground segment") is a real,
 * production-supported CSPCL transport that needs only unprivileged TCP
 * loopback sockets and a `zmqproxy` broker -- it exercises the identical
 * cspcl_send_bundle() -> cspcl_pool_get_or_create_locked() code as the
 * CAN path, just over a different csp_iface_t. A first attempt at this
 * benchmark used CSP's self-addressed loopback interface (csp_if_lo) to
 * avoid even needing a second process, but real send+ACK round trips
 * over it were unreliable in this environment (RDP handshakes that
 * report success but never deliver) -- notably, CSPCL's own
 * test_cspcl_pool_integration.c tolerates exactly this ("the send may
 * also fail" in its comments) because its assertions only check pool
 * bookkeeping, never actual delivery. This benchmark needs delivery to
 * be real, so it uses ZMQ hub with a genuine second process instead.
 *
 * STATUS: switching to zmqhub avoided the loopback-specific failure mode
 * above, but a *different* one showed up in its place -- csp_connect()
 * over zmqhub between two independent processes on this machine falls
 * into a live RDP retransmission loop (see zmqproxy's own traffic log:
 * a stream of small control packets bouncing back and forth with no
 * SFP data fragments ever going out) that doesn't resolve even with
 * CSPCL_CSP_TIMEOUT_MS/ACK_TIMEOUT_MS/SFP_TIMEOUT_MS raised to 15000ms
 * (the same bump DEMO.md's "contact range" build uses for the real
 * shaped link). Root cause not isolated -- candidates include an RDP
 * retransmit-timer/RTT mismatch specific to two same-host processes, or
 * something zmqproxy/PUB-SUB-specific -- and not pursued further given
 * this was already a fallback for a blocked *root* requirement, not the
 * primary deliverable. Compiles and links cleanly and is a faithful,
 * real exercise of cspcl_send_bundle() up to that point; treat any
 * numbers it prints as unverified until the retransmission issue is
 * root-caused. contact_rate/pool_hitrate_draft.md has the details and
 * what to do with a rooted environment instead (measure_pool_hitrate.sh
 * against the real chain, which does work end-to-end conceptually and
 * only needs root to actually run).
 *
 * Usage: pool_bench <local_addr> <dest_addr> <dest_port> <size_bytes>
 *                    <count> <interval_ms>
 * Prints one line: POOL_STATS size=.. interval_ms=.. count=.. sent=..
 * failed=.. hits=.. misses=.. evictions=.. invalidations=..
 * connect_failures=.. hit_rate=.. elapsed_ms=..
 */

#include "cspcl.h"
#include "cspcl_config.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
  if (argc < 7) {
    fprintf(stderr,
            "usage: %s <local_addr> <dest_addr> <dest_port> <size_bytes> <count> "
            "<interval_ms>\n",
            argv[0]);
    return 2;
  }

  uint8_t local_addr = (uint8_t) strtoul(argv[1], NULL, 10);
  uint8_t dest_addr = (uint8_t) strtoul(argv[2], NULL, 10);
  uint8_t dest_port = (uint8_t) strtoul(argv[3], NULL, 10);
  size_t size = (size_t) strtoul(argv[4], NULL, 10);
  int count = atoi(argv[5]);
  int interval_ms = atoi(argv[6]);

  if (size == 0 || count <= 0) {
    fprintf(stderr, "size and count must be positive\n");
    return 2;
  }

  cspcl_t cspcl;
  memset(&cspcl, 0, sizeof(cspcl));
  cspcl.local_addr = local_addr;
  cspcl.iface_type = CSP_IFACE_ZMQHUB;
  cspcl.csp_port = CSPCL_PORT_BP;
  strncpy(cspcl.zmqhub_addr, "localhost", sizeof(cspcl.zmqhub_addr) - 1);

  cspcl_error_t err = cspcl_init(&cspcl);
  if (err != CSPCL_OK) {
    fprintf(stderr, "cspcl_init failed: %s\n", cspcl_strerror(err));
    return 1;
  }

  /* Give the zmqhub PUB/SUB sockets time to finish connecting to the
   * broker before the first send -- ZMQ_PUB messages sent before the
   * SUB side's connection handshake completes are silently dropped
   * ("slow joiner" problem), which would show up as a spurious
   * first-send failure unrelated to the connection pool. */
  usleep(300 * 1000);

  uint8_t *bundle = malloc(size);
  if (bundle == NULL) {
    fprintf(stderr, "oom allocating %zu-byte payload\n", size);
    return 1;
  }
  for (size_t i = 0; i < size; i++) {
    bundle[i] = (uint8_t) (i & 0xFF);
  }

  int sent = 0, failed = 0;
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);

  for (int i = 0; i < count; i++) {
    cspcl_error_t serr = cspcl_send_bundle(&cspcl, bundle, size, dest_addr, dest_port);
    if (serr == CSPCL_OK) {
      sent++;
    } else {
      failed++;
      fprintf(stderr, "send %d/%d failed: %s\n", i + 1, count, cspcl_strerror(serr));
    }
    if (interval_ms > 0 && i + 1 < count) {
      usleep((useconds_t) interval_ms * 1000);
    }
  }

  clock_gettime(CLOCK_MONOTONIC, &t1);
  double elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;

  cspcl_conn_pool_stats_t stats;
  memset(&stats, 0, sizeof(stats));
  cspcl_conn_pool_get_stats(&cspcl.conn_pool, &stats);

  const uint32_t total = stats.hits + stats.misses;
  const double hit_rate = (total > 0) ? ((double) stats.hits / (double) total) : 0.0;

  printf("POOL_STATS size=%zu interval_ms=%d count=%d sent=%d failed=%d hits=%u misses=%u "
         "evictions=%u invalidations=%u connect_failures=%u hit_rate=%.4f elapsed_ms=%.1f\n",
         size, interval_ms, count, sent, failed, stats.hits, stats.misses, stats.evictions,
         stats.invalidations, stats.connect_failures, hit_rate, elapsed_ms);

  free(bundle);
  cspcl_cleanup(&cspcl);

  return (failed > 0) ? 1 : 0;
}
