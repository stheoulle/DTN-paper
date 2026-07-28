/* pool_bench_recv.c -- persistent peer for contact_rate/pool_bench.c.
 *
 * Accepts CSP/RDP connections over CSPCL's zmqhub interface and, for each
 * one, keeps it open across multiple bundles (SFP-receiving and
 * CSPCL_ACK_MAGIC-acking each), matching how the real cspcl inbound path
 * behaves ("accepted connections must stay open and be polled for
 * further bundles", cspcl.h) -- unlike a close-after-one-bundle discard
 * server, which would make a sender's pooled-connection reuse ("hit")
 * time out because the peer already hung up.
 *
 * Not a unit test; run as a standalone background process. Exits on
 * SIGINT/SIGTERM. See pool_bench.c and contact_rate/pool_hitrate_draft.md.
 *
 * Usage: pool_bench_recv <local_addr>
 */

#include "cspcl.h"
#include "cspcl_config.h"

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <csp/arch/csp_malloc.h>
#include <csp/csp.h>

#ifndef CSP_ANY
#define CSP_ANY 255
#endif

static volatile sig_atomic_t g_running = 1;

static void handle_sig(int sig)
{
  (void) sig;
  g_running = 0;
}

static void *conn_handler(void *arg)
{
  csp_conn_t *conn = (csp_conn_t *) arg;

  while (g_running) {
    /* A long per-call timeout matters here: csp_sfp_recv() reassembles a
     * whole SFP message inside ONE blocking call, so a short timeout that
     * fires mid-reassembly (fragments 1..k arrived, k+1 hasn't yet) does
     * not "resume" on the next call -- it silently restarts reassembly
     * state, permanently stranding a transfer that only ever gets a
     * partial delivery each time. Long timeout, few iterations. */
    void *data = NULL;
    int datasize = 0;
    int ret = csp_sfp_recv(conn, &data, &datasize, 20000);

    if (data != NULL) {
      csp_free(data);
    }

    if (ret == CSP_ERR_NONE) {
      csp_packet_t *ack = csp_buffer_get(1);
      if (ack != NULL) {
        ack->data[0] = CSPCL_ACK_MAGIC;
        ack->length = 1;
        if (!csp_send(conn, ack, CSPCL_CSP_TIMEOUT_MS)) {
          csp_buffer_free(ack);
        }
      }
    }
    /* On a poll timeout, loop back and keep waiting on this same
     * connection -- the peer may simply be pacing its sends. */
  }

  csp_close(conn);
  return NULL;
}

int main(int argc, char **argv)
{
  if (argc < 2) {
    fprintf(stderr, "usage: %s <local_addr>\n", argv[0]);
    return 2;
  }

  signal(SIGINT, handle_sig);
  signal(SIGTERM, handle_sig);

  cspcl_t cspcl;
  memset(&cspcl, 0, sizeof(cspcl));
  cspcl.local_addr = (uint8_t) strtoul(argv[1], NULL, 10);
  cspcl.iface_type = CSP_IFACE_ZMQHUB;
  cspcl.csp_port = CSPCL_PORT_BP;
  strncpy(cspcl.zmqhub_addr, "localhost", sizeof(cspcl.zmqhub_addr) - 1);

  cspcl_error_t err = cspcl_init(&cspcl);
  if (err != CSPCL_OK) {
    fprintf(stderr, "cspcl_init failed: %s\n", cspcl_strerror(err));
    return 1;
  }

  csp_socket_t *sock = csp_socket(CSPCL_CSP_SOCKET_OPTIONS);
  if (sock == NULL || csp_bind(sock, CSP_ANY) != CSP_ERR_NONE ||
      csp_listen(sock, 8) != CSP_ERR_NONE) {
    fprintf(stderr, "failed to start listener\n");
    cspcl_cleanup(&cspcl);
    return 1;
  }

  fprintf(stderr, "[pool_bench_recv] listening as csp addr=%u (zmqhub)\n", cspcl.local_addr);

  while (g_running) {
    csp_conn_t *conn = csp_accept(sock, 200);
    if (conn == NULL) {
      continue;
    }

    pthread_t tid;
    if (pthread_create(&tid, NULL, conn_handler, conn) != 0) {
      csp_close(conn);
      continue;
    }
    pthread_detach(tid);
  }

  cspcl_cleanup(&cspcl);
  return 0;
}
