/*
 * csp_stack.h — shared CSP/CAN stack bring-up for both benchmark arms.
 *
 * Both Arm A (raw CSP) and Arm B (CSP/BP via CSPCL) call the same
 * bench_stack_init(), which just populates a cspcl_t and calls the real
 * cspcl_init(). This brings up an identical CSP stack + CAN interface + RDP
 * connection pool + router task for both arms, so the only difference
 * between the two tools is whether csp_send() or cspcl_send_bundle() is
 * used to move data — exactly the comparison Section 3 needs to isolate
 * CSPCL/BP framing cost from CSP/CAN transport cost.
 */
#ifndef BENCH_CSP_STACK_H
#define BENCH_CSP_STACK_H

#include "cspcl.h"

/*
 * local_addr: this node's CSP address
 * can_iface:  SocketCAN interface name (e.g. "vcan0")
 * bp_port:    CSP port CSPCL's own rx socket binds to (CSPCL_PORT_BP);
 *             Arm A uses a *different* port for its raw socket so the two
 *             don't collide if ever run in the same process (they aren't,
 *             but keeping this explicit avoids surprises).
 */
cspcl_error_t bench_stack_init(cspcl_t *cspcl, uint8_t local_addr, const char *can_iface,
                                uint8_t bp_port);

#endif /* BENCH_CSP_STACK_H */
