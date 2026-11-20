# migrator — build and test from source.
#
#   make help        this list (default)
#   make test        shellcheck + the table tests (seconds, no root)
#   make agent       build bin/migrator-agent, the on-line migration agent
#   make agent-test  run the agent against loop devices of this host (needs root)
#   make install     install the tool into /usr/local (PREFIX=... to change it)
#   make clean       remove what the build wrote
#
# There is no vendor download: the tree is the source of truth. Host the
# artefacts yourself and point tools/install.sh at them with MIGRATOR_URL
# (see that script), or run 'make install' where the tree already is.

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

# one static binary for both ends of an on-line migration; it needs a C
# compiler and libzstd's static library, nothing else at run time
agent:
	@$(MAKE) -s -C agent VERSION=$(VER)

agent-test: agent
	@bash tools/agent-test.sh

install: agent
	@install -d $(PREFIX)/bin $(PREFIX)/lib/migrator
	install -m 0755 bin/migrator $(PREFIX)/bin/migrator
	install -m 0755 agent/migrator-agent $(PREFIX)/bin/migrator-agent
	install -m 0644 lib/*.sh $(PREFIX)/lib/migrator/
	echo "$(VER)" > $(PREFIX)/lib/migrator/VERSION
	echo "installed migrator $(VER) into $(PREFIX)"

clean:
	@$(MAKE) -s -C agent clean
	rm -rf dist
