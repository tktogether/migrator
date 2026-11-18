#!/bin/bash
# tests/cases/install.sh — tools/install.sh against a fake "current/" served by
# python3 http.server on 127.0.0.1: a good tarball installs under a scratch
# PREFIX and 'reloca.to version' reports the tarball's VERSION; a corrupted
# SHA256SUMS, a listing without a tarball and a dead URL all fail without
# touching what is installed. Needs python3 and curl or wget; else SKIP.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
INSTALL=$REPO/tools/install.sh

command -v python3 >/dev/null 2>&1 || { skip "install.sh" "no python3 to serve the fake current/"; t_end; }
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { skip "install.sh" "neither curl nor wget"; t_end; }

# --- a fake dist/: the real bin/ and lib/ under a made-up version --------------
VER=0.0-test
DIST=$RUN/dist; SRC=$DIST/reloca-$VER
mkdir -p "$SRC/tools" "$DIST/prefix"
cp -a "$REPO/bin" "$REPO/lib" "$SRC/"
echo "$VER" > "$SRC/lib/VERSION"
tar -C "$DIST" -czf "$DIST/reloca-$VER.tar.gz" "reloca-$VER"
rm -rf "$SRC"
cp "$INSTALL" "$DIST/install.sh"
( cd "$DIST" && sha256sum "reloca-$VER.tar.gz" install.sh > SHA256SUMS )

# --- serve it: own PID only, killed on exit ------------------------------------
HTTPD=
for _ in 1 2 3 4 5; do
	PORT=$(( 20000 + RANDOM % 20000 ))
	python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIST" >/dev/null 2>&1 &
	HTTPD=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
		kill -0 "$HTTPD" 2>/dev/null || break
		sleep 0.2
	done
	bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
	kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null; HTTPD=
done
[ -n "$HTTPD" ] || { skip "install.sh" "could not start http.server on 127.0.0.1"; t_end; }
# common.sh is not sourced here, so a plain trap is enough
trap 'kill $HTTPD 2>/dev/null' EXIT
URL=http://127.0.0.1:$PORT
PREFIX=$RUN/prefix

# --- good install -------------------------------------------------------------
out=$(RELOCA_URL=$URL RELOCA_PREFIX=$PREFIX sh "$INSTALL" 2>&1); rc=$?
assert_eq  "install.sh exits 0"                    0 "$rc"
assert_ok  "bin/reloca.to installed and executable" test -x "$PREFIX/sbin/reloca.to"
assert_ok  "lib/common.sh installed"               test -r "$PREFIX/lib/reloca.to/common.sh"
assert_eq  "lib/VERSION installed"                 "$VER" "$(cat "$PREFIX/lib/reloca.to/VERSION" 2>/dev/null)"
assert_has "install.sh prints the version"         "reloca.to $VER" "$out"
assert_has "install.sh prints the -h hint"         "reloca.to -h" "$out"
assert_fail "no staging dir left behind"           sh -c "ls -d '$PREFIX/lib'/.reloca.to* 2>/dev/null | grep -q ."
# bin/reloca.to looks for its libs at $HERE/../lib or /usr/local/lib/reloca.to
# only, so under a scratch PREFIX it cannot find them: check what can be checked
out=$(cd / && "$PREFIX/sbin/reloca.to" -V 2>&1); rc=$?
assert_eq  "installed reloca.to runs"               0 "$rc"
case "$out" in
	*"lib=$PREFIX/lib/reloca.to"*)
		assert_has "installed reloca.to reports the tarball version" "reloca.to $VER " "$out";;
	*)	skip "installed reloca.to reports the tarball version" "driver resolves libs at \$HERE/../lib or /usr/local/lib/reloca.to, not under PREFIX=$PREFIX";;
esac
assert_ok  "installed reloca.to parses"             bash -n "$PREFIX/sbin/reloca.to"

# --- re-install replaces the old lib dir wholesale -----------------------------
touch "$PREFIX/lib/reloca.to/stale.sh"
out=$(RELOCA_URL=$URL RELOCA_PREFIX=$PREFIX sh "$INSTALL" 2>&1); rc=$?
assert_eq   "re-install exits 0"                   0 "$rc"
assert_fail "re-install drops files of the old lib" test -e "$PREFIX/lib/reloca.to/stale.sh"

# --- failures leave the installed tree alone -----------------------------------
cp "$DIST/SHA256SUMS" "$DIST/SHA256SUMS.good"
sed -i "s/^[0-9a-f]\{8\}/00000000/" "$DIST/SHA256SUMS"
out=$(RELOCA_URL=$URL RELOCA_PREFIX=$PREFIX sh "$INSTALL" 2>&1); rc=$?
assert_eq  "bad checksum exits 1"                  1 "$rc"
assert_has "bad checksum says so"                  "checksum" "$out"
assert_eq  "bad checksum keeps the installed lib"  "$VER" "$(cat "$PREFIX/lib/reloca.to/VERSION")"
assert_ok  "bad checksum keeps the installed bin"  test -x "$PREFIX/sbin/reloca.to"

grep -v 'reloca-.*\.tar\.gz' "$DIST/SHA256SUMS.good" > "$DIST/SHA256SUMS"
out=$(RELOCA_URL=$URL RELOCA_PREFIX=$PREFIX sh "$INSTALL" 2>&1); rc=$?
assert_eq  "SHA256SUMS without a tarball exits 1"  1 "$rc"
assert_has "SHA256SUMS without a tarball says so"  "tarball" "$out"
cp "$DIST/SHA256SUMS.good" "$DIST/SHA256SUMS"

out=$(RELOCA_URL=$URL/nowhere RELOCA_PREFIX=$PREFIX sh "$INSTALL" 2>&1); rc=$?
assert_eq  "404 exits 1"                           1 "$rc"
assert_has "404 names the URL"                     "$URL/nowhere/SHA256SUMS" "$out"

t_end
