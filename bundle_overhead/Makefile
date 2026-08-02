# Makefile — bundle_overhead benchmark tools (Section 3 of paper_comments.md)
#
# Builds four standalone binaries comparing raw CSP (Arm A) against BP
# bundles carried over CSP via the real CSPCL library (Arm B), sweeping the
# number of CSP-packet-equivalents batched per bundle.
#
# Requires libcsp and cspcl already built per DEMO.md / README.md Step 4
# (this repo's libcsp/build/libcsp.a and cspcl/build/libcspcl.a).

DTN_ROOT     := $(shell git rev-parse --show-toplevel)
LIBCSP_DIR   := $(DTN_ROOT)/libcsp
LIBCSP_BUILD := $(LIBCSP_DIR)/build
CSPCL_DIR    := $(DTN_ROOT)/cspcl

CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -std=gnu11 \
          -I$(LIBCSP_DIR)/include \
          -I$(LIBCSP_BUILD)/include \
          -I$(CSPCL_DIR)/src
LDFLAGS = -L$(LIBCSP_BUILD) -L$(CSPCL_DIR)/build

# Arm A (raw CSP) links ONLY libcsp — no libcspcl, no cspcl.h anywhere in its
# object files, so "raw CSP" is not just an unexercised code path but a
# binary that structurally cannot touch CSPCL.
ARM_A_LDLIBS = -lcsp -lsocketcan -lzmq -lpthread -lm -lrt

# Arm B (CSP/BP via CSPCL) links the real cspcl library.
ARM_B_LDLIBS = -lcspcl -lcsp -lsocketcan -lzmq -lpthread -lm -lrt

BINS = csp_raw_sender csp_raw_receiver bundle_sender bundle_receiver

.PHONY: all clean
all: $(BINS)

csp_raw_sender: csp_raw_sender.c bare_csp_stack.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(ARM_A_LDLIBS)

csp_raw_receiver: csp_raw_receiver.c bare_csp_stack.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(ARM_A_LDLIBS)

bundle_sender: bundle_sender.c csp_stack.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(ARM_B_LDLIBS)

bundle_receiver: bundle_receiver.c csp_stack.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(ARM_B_LDLIBS)

clean:
	rm -f $(BINS)
