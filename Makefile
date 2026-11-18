# reloca.to — build and test from source.
#
#   make help        this list (default)
#   make test        shellcheck + the table tests (seconds, no root)
#   make agent       build bin/reloca-agent, the on-line relocation agent
#   make agent-test  run the agent against loop devices of this host (needs root)
#   make install     install the tool into /usr/local (PREFIX=... to change it)
#   make clean       remove what the build wrote
#
# The published builds at https://reloca.to come from the same sources; the
# installer there (curl -fsSL reloca.to | bash) fetches a signed tarball, which
# is what most people want. Build from source when you would rather read it
# first, or when you are changing something.

SHELL       := /bin/bash
.SHELLFLAGS := -ec
.ONESHELL:
.DEFAULT_GOAL := help

PREFIX  := /usr/local
VER     := $(shell git describe --always --dirty 2>/dev/null || cat VERSION 2>/dev/null || echo dev)

.PHONY: help test agent agent-test install clean

help:
	@sed -n '2,12p' $(firstword $(MAKEFILE_LIST))

test: agent
	@bash tests/run.sh

# one static binary for both ends of an on-line relocation; it needs a C
# compiler and libzstd's static library, nothing else at run time
agent:
	@$(MAKE) -s -C agent VERSION=$(VER)

agent-test: agent
	@bash tools/agent-test.sh

install: agent
	@install -d $(PREFIX)/bin $(PREFIX)/lib/reloca.to
	install -m 0755 bin/reloca.to $(PREFIX)/bin/reloca.to
	install -m 0755 agent/reloca-agent $(PREFIX)/bin/reloca-agent
	install -m 0644 lib/*.sh $(PREFIX)/lib/reloca.to/
	echo "$(VER)" > $(PREFIX)/lib/reloca.to/VERSION
	echo "installed reloca.to $(VER) into $(PREFIX)"

clean:
	@$(MAKE) -s -C agent clean
	rm -rf dist
