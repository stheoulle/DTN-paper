#include "bare_csp_stack.h"

#include <stdio.h>

#include <csp/csp.h>
#include <csp/csp_rtable.h>
#include <csp/drivers/can_socketcan.h>
#include <csp/interfaces/csp_if_can.h>

int bare_csp_stack_init(uint8_t local_addr, const char *can_iface)
{
    csp_conf_t csp_conf;
    csp_conf_get_defaults(&csp_conf);
    csp_conf.address           = local_addr;
    csp_conf.hostname          = "bench";
    csp_conf.model             = "csp-raw";
    csp_conf.revision          = "1.0";
    /* Mirrors cspcl_init()'s tuning (CSPCL_CONN_POOL_SIZE(16) * 4) so both
     * arms get an identical CSP connection table size, even though Arm A
     * has no pool concept of its own. */
    csp_conf.conn_max          = 64;
    csp_conf.conn_queue_length = 100;
    csp_conf.fifo_length       = 25;
    csp_conf.port_max_bind     = 31;
    csp_conf.rdp_max_window    = 20;
    csp_conf.buffers           = 100;
    csp_conf.buffer_data_size  = 256;

    if (csp_init(&csp_conf) != CSP_ERR_NONE) {
        fprintf(stderr, "bare_csp_stack_init: csp_init failed\n");
        return -1;
    }

    csp_iface_t *iface = NULL;
    int ret = csp_can_socketcan_open_and_add_interface(can_iface, can_iface, 0, true, &iface);
    if (ret != CSP_ERR_NONE) {
        fprintf(stderr, "bare_csp_stack_init: CAN interface '%s' open failed (%d)\n",
                can_iface, ret);
        return -1;
    }

    csp_rtable_set(CSP_DEFAULT_ROUTE, 0, iface, CSP_NODE_MAC);

    if (csp_route_start_task(500, 0) != CSP_ERR_NONE) {
        fprintf(stderr, "bare_csp_stack_init: csp_route_start_task failed\n");
        return -1;
    }

    return 0;
}
