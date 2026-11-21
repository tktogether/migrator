# migrator — build and test from source.
#
#   make help        this list (default)
#   make test        shellcheck + the table tests (seconds, no root)
#   make agent       build bin/migrator-agent, the on-line migration agent
#   make agent-test  run the agent against loop devices of this host (needs root)
#   make install     install the tool into /usr/local (PREFIX=... to change it)
#   make dist        source tarball for the distribution package (dist/)
#   make deb         build the two Debian packages from this tree (dpkg-dev)
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
RELVER  := $(shell cat VERSION 2>/dev/null || echo 0)

.PHONY: help test agent agent-test install dist deb clean

help:
	@sed -n '2,14p' $(firstword $(MAKEFILE_LIST))

test: agent
	@bash tests/run.sh

# one static binary for both ends of an on-line migration; it needs a C
# compiler and libzstd's static library, nothing else at run time
agent:
	@$(MAKE) -s -C agent VERSION=$(VER)

agent-test: agent
	@bash tools/agent-test.sh

install: agent
	@install -d $(PREFIX)/sbin $(PREFIX)/lib/migrator
	install -m 0755 bin/migrator $(PREFIX)/sbin/migrator
	install -m 0755 agent/migrator-agent $(PREFIX)/sbin/migrator-agent
	install -m 0755 tools/relay-tunnel.sh $(PREFIX)/sbin/relay-tunnel.sh
	install -m 0644 lib/*.sh $(PREFIX)/lib/migrator/
	install -d $(PREFIX)/share/doc/migrator
	install -m 0644 LICENSE LICENSE-UPSTREAM NOTICE TRADEMARK.md $(PREFIX)/share/doc/migrator/
	echo "$(VER)" > $(PREFIX)/lib/migrator/VERSION
	echo "installed migrator $(VER) into $(PREFIX)"

# the upstream tarball the Debian source package is built against: the tree as
# committed, without debian/ (which .gitattributes marks export-ignore)
dist:
	@mkdir -p dist
	git archive --format=tar.gz --prefix=migrator-$(RELVER)/ \
		-o dist/migrator_$(RELVER).orig.tar.gz HEAD
	@echo "dist/migrator_$(RELVER).orig.tar.gz"

# the packages themselves; the source tree is the source package, so this is a
# binary build only (use 'make dist' first when uploading a source package)
deb:
	dpkg-buildpackage -us -uc -b

clean:
	@$(MAKE) -s -C agent clean
	rm -rf dist
