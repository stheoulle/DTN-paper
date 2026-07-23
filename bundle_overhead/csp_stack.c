#include "csp_stack.h"

#include <string.h>

cspcl_error_t bench_stack_init(cspcl_t *cspcl, uint8_t local_addr, const char *can_iface,
                                uint8_t bp_port)
{
    memset(cspcl, 0, sizeof(*cspcl));
    cspcl->local_addr = local_addr;
    cspcl->iface_type = CSP_IFACE_CAN;
    cspcl->csp_port   = bp_port;
    strncpy(cspcl->can_iface, can_iface, sizeof(cspcl->can_iface) - 1);
    cspcl->can_iface[sizeof(cspcl->can_iface) - 1] = '\0';

    return cspcl_init(cspcl);
}
