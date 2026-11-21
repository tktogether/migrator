#!/bin/bash
# tests/cases/get.sh — tools/get.sh: the file list it fetches, and one install
# end to end against a fake tree served on 127.0.0.1. The second half needs
# python3 and curl (get.sh hands the tarball to install.sh over file://, which
# wget does not read); without both, only the list checks run.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
GET=$REPO/tools/get.sh

# --- the list ----------------------------------------------------------------
# A mirror serves files out of a repository; it does not list a directory. The
# names are therefore written by hand in get.sh, and this is what keeps that
# list equal to the tree. A missing lib here installs a driver that cannot
# start; a missing helper here is a feature that exists only in the Debian
# package.
list=$(sed -n '/^FILES="/,/^TRADEMARK.md"$/p' "$GET" | sed '1s/^FILES="//; $s/"$//')
for f in "$REPO"/lib/*.sh; do
	name=lib/$(basename "$f")
	assert_eq "FILES carries $name" "$name" "$(printf '%s\n' "$list" | grep -x "$name")"
done
for f in bin/migrator tools/relay-tunnel.sh LICENSE LICENSE-UPSTREAM NOTICE TRADEMARK.md; do
	assert_eq "FILES carries $f" "$f" "$(printf '%s\n' "$list" | grep -x "$f")"
done

# --- the install -------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { skip "get.sh install" "no python3 to serve the fake tree"; t_end; }
# get.sh sets PATH itself, so a tool that is only on the caller's PATH (Git
# Bash puts curl in /mingw64/bin) is not there for it. Test what it will see.
for t in curl tar gzip sha256sum; do
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v "$t" >/dev/null 2>&1 \
		|| { skip "get.sh install" "$t is not in the PATH get.sh sets"; t_end; }
done

# a tree shaped like the repository, minus everything get.sh does not fetch
TREE=$RUN/tree
mkdir -p "$TREE/bin" "$TREE/lib" "$TREE/tools"
cp -a "$REPO/bin/." "$TREE/bin/"
cp -a "$REPO/lib/." "$TREE/lib/"
cp "$REPO/tools/install.sh" "$REPO/tools/relay-tunnel.sh" "$TREE/tools/"
cp "$REPO/LICENSE" "$REPO/LICENSE-UPSTREAM" "$REPO/NOTICE" "$REPO/TRADEMARK.md" "$TREE/"
printf '0.0-get\n' > "$TREE/VERSION"

PORT=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TREE" >/dev/null 2>&1 &
HTTPD=$!
trap 'kill $HTTPD 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
	bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
	sleep 0.2
done

PREFIX=$RUN/prefix
out=$(MIGRATOR_BASE=http://127.0.0.1:$PORT MIGRATOR_PREFIX=$PREFIX sh "$GET" 2>&1); rc=$?
assert_eq  "get.sh exits 0"                        0 "$rc"
assert_has "get.sh reports the version it fetched" "0.0-get" "$out"
assert_ok  "driver installed and executable"       test -x "$PREFIX/sbin/migrator"
for f in "$REPO"/lib/*.sh; do
	assert_ok "lib/$(basename "$f") installed"      test -r "$PREFIX/lib/migrator/$(basename "$f")"
done
assert_ok  "relay-tunnel.sh installed"             test -x "$PREFIX/sbin/relay-tunnel.sh"
assert_eq  "lib/VERSION carries the tree's VERSION" "0.0-get" "$(cat "$PREFIX/lib/migrator/VERSION" 2>/dev/null)"
assert_ok  "licence and attribution installed"     test -r "$PREFIX/share/doc/migrator/LICENSE-UPSTREAM"
assert_fail "no staging dir left behind"           sh -c "ls -d '$PREFIX/lib'/.migrator* 2>/dev/null | grep -q ."

# a source that answers VERSION but has no tarball is a broken publish: the
# install must fail rather than leave a half tree behind
rm -f "$TREE/bin/migrator"
out=$(MIGRATOR_BASE=http://127.0.0.1:$PORT MIGRATOR_PREFIX=$RUN/prefix2 sh "$GET" 2>&1); rc=$?
assert_eq "a missing file fails the install" 1 "$rc"
assert_has "the failure names the file" "bin/migrator" "$out"

t_end
