#include "csp_stack.h"

#include <string.h>

#include <csp/csp.h>

cspcl_error_t bench_stack_init(cspcl_t *cspcl, uint8_t local_addr, const char *can_iface,
                                uint8_t bp_port)
{
    memset(cspcl, 0, sizeof(*cspcl));
    cspcl->local_addr = local_addr;
    cspcl->iface_type = CSP_IFACE_CAN;
    cspcl->csp_port   = bp_port;
    strncpy(cspcl->can_iface, can_iface, sizeof(cspcl->can_iface) - 1);
    cspcl->can_iface[sizeof(cspcl->can_iface) - 1] = '\0';

    cspcl_error_t err = cspcl_init(cspcl);
    if (err != CSPCL_OK) {
        return err;
    }

    csp_debug_set_level(CSP_PROTOCOL, true); // TEMP DEBUGGING
    csp_debug_set_level(CSP_INFO, true); // TEMP DEBUGGING

    /* fix/connection-handling's csp_conf.conn_max is
     * CSPCL_CONN_POOL_SIZE + CSPCL_RX_CONN_TABLE_SIZE + 4 = 28 slots. The
     * happy path (connection reuse, cspcl.c) no longer churns through
     * this table, but cspcl_send_bundle()'s retry-once-on-failure path
     * still calls csp_close() on a failed connection, and a closed RDP
     * connection holds its table slot through RDP_CLOSE_WAIT for
     * conn_timeout (10s default, libcsp/src/transport/csp_rdp.c) before
     * being reclaimed. Under sustained load at larger N (more SFP
     * fragments per bundle -> more chances for an occasional timing
     * hiccup), enough of these failure-triggered closes accumulate within
     * one conn_timeout window to exhaust all 28 slots ("No free
     * connections, max 28"), even though the vast majority of sends never
     * hit this path at all. Shrinking conn_timeout only affects how long
     * a *closed* connection's slot is held, not the happy path's reused,
     * still-open connection -- see bundle_overhead/results/result.md.
     *
     * conn_timeout is a dual-purpose knob, though: csp_rdp_connect()
     * (libcsp/src/transport/csp_rdp.c:905) also uses this SAME value as
     * how long a brand-new connection waits for the peer's SYN/ACK before
     * giving up -- 300ms was found to be too tight for that under load
     * (silent CSP_ERR_TIMEDOUT, no log output, since csp_rdp_connect()'s
     * own timeout path only logs at CSP_LOG_LEVEL_PROTOCOL). 1000ms keeps
     * most of the CLOSE_WAIT-reclaim benefit while giving the initial
     * handshake realistic headroom. */
    csp_rdp_set_opt(4, 1000, 1000, 1, 250, 2);

    return CSPCL_OK;
}
