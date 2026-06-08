CC      = gcc
CFLAGS  = -Wall -Wextra -O2
LDFLAGS =

BINS = sender receiver

.PHONY: all clean

all: $(BINS)

sender: sender.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

receiver: receiver.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(BINS)
