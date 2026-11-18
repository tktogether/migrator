# agent/Makefile — reloca-agent, one static binary for both ends (see agent.h).
# make -C agent         builds agent/reloca-agent (gcc, -static; libzstd linked in
#                       for the per-frame compression, so the donor needs nothing)
# VERSION comes from the tree (git describe) unless given.
VERSION ?= $(shell git -C .. describe --always --dirty 2>/dev/null || echo dev)
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -Wno-format-truncation -std=gnu11
LDFLAGS ?= -static -pthread -lzstd
SRC     := main.c tracker.c sha256.c
reloca-agent: $(SRC) agent.h
	$(CC) $(CFLAGS) -DAGENT_VERSION='"$(VERSION)"' -o $@ $(SRC) $(LDFLAGS)
clean:
	rm -f reloca-agent
.PHONY: clean
