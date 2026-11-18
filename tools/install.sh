#!/bin/sh
# install.sh — put reloca.to onto a running XServer Live OS (full Live). The
# domain root serves this very script, so on the Live:
#
#   curl -fsSL reloca.to | bash                      # install, print the hint
#   curl -fsSL reloca.to | bash -s -- -s plan DONOR    # install, then run reloca.to with these args
#
# Downloads SHA256SUMS and the one reloca-<ver>.tar.gz it lists from
# RELOCA_URL (default https://reloca.to/current), checks
# the tarball's sha256, unpacks it in a scratch dir and installs
#   $PREFIX/sbin/reloca.to        the driver
#   $PREFIX/sbin/reloca-agent     the on-line relocation agent (static binary, when the tarball has it)
#   $PREFIX/lib/reloca.to/       the libs + VERSION (the previous dir is replaced)
# with PREFIX = RELOCA_PREFIX or /usr/local. Everything is staged and moved
# into place last, so a failed download, a bad checksum or a broken tarball
# never leaves a half-installed tree. Uses curl or wget, whichever exists
# (busybox wget is enough). The Live is tmpfs: run this again after a reboot.
# exit: 0 installed · 1 download, checksum, unpack or install failure · 2 no curl/wget
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
BASE=${RELOCA_URL:-https://reloca.to/current}
PREFIX=${RELOCA_PREFIX:-/usr/local}

say() { echo "[reloca-install] $*"; }
die() { echo "[reloca-install] ERROR: $*" >&2; exit "${CODE:-1}"; }

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -q -O "$2" "$1"; }
else
	CODE=2 die "neither curl nor wget found"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/reloca-install.XXXXXX") || die "cannot create a scratch dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "fetching $BASE/SHA256SUMS"
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || die "cannot download $BASE/SHA256SUMS"
# the listing names exactly one tarball; anything else means a broken publish
TARBALL=$(awk '$2 ~ /^reloca-.*\.tar\.gz$/ { print $2 }' "$TMP/SHA256SUMS")
COUNT=$(printf '%s\n' "$TARBALL" | grep -c .)
[ "$COUNT" -eq 1 ] || die "SHA256SUMS at $BASE lists $COUNT tarballs, expected one reloca-<ver>.tar.gz"
VER=${TARBALL#reloca-}; VER=${VER%.tar.gz}

say "fetching $BASE/$TARBALL"
fetch "$BASE/$TARBALL" "$TMP/$TARBALL" || die "cannot download $BASE/$TARBALL"
awk -v t="$TARBALL" '$2 == t' "$TMP/SHA256SUMS" > "$TMP/SHA256SUMS.tarball"
( cd "$TMP" && sha256sum -c SHA256SUMS.tarball >/dev/null 2>&1 ) || die "checksum mismatch for $TARBALL (a publish in progress? retry in a minute)"

mkdir "$TMP/x" || die "cannot create $TMP/x"
tar -xzf "$TMP/$TARBALL" -C "$TMP/x" || die "cannot unpack $TARBALL"
SRC=$TMP/x/reloca-$VER
for f in bin/reloca.to lib/common.sh lib/VERSION; do
	[ -s "$SRC/$f" ] || die "unexpected tarball layout: no reloca-$VER/$f"
done

# stage next to the final paths so the last step is a rename, never a copy
BIN=$PREFIX/sbin; LIB=$PREFIX/lib/reloca.to; STAGE=$PREFIX/lib/.reloca.to.new.$$
mkdir -p "$BIN" "$PREFIX/lib" || die "cannot create $BIN / $PREFIX/lib"
rm -rf "$STAGE"
cp -R "$SRC/lib" "$STAGE" || die "cannot stage the libs under $PREFIX/lib"
chmod 0755 "$STAGE" || die "cannot set modes under $STAGE"
chmod 0644 "$STAGE"/* || die "cannot set modes under $STAGE"
cp "$SRC/bin/reloca.to" "$BIN/.reloca.to.new" || die "cannot stage $BIN/reloca.to"
chmod 0755 "$BIN/.reloca.to.new" || die "cannot set modes on $BIN/reloca.to"
# the on-line relocation agent (static binary, both ends; absent in older tarballs)
if [ -s "$SRC/bin/reloca-agent" ]; then
	cp "$SRC/bin/reloca-agent" "$BIN/.reloca-agent.new" || die "cannot stage $BIN/reloca-agent"
	chmod 0755 "$BIN/.reloca-agent.new" || die "cannot set modes on $BIN/reloca-agent"
fi
rm -rf "$LIB" || die "cannot remove the previous $LIB"
mv "$STAGE" "$LIB" || die "cannot move the libs into place at $LIB"
mv -f "$BIN/.reloca.to.new" "$BIN/reloca.to" || die "cannot replace $BIN/reloca.to"
[ ! -s "$BIN/.reloca-agent.new" ] || mv -f "$BIN/.reloca-agent.new" "$BIN/reloca-agent" || die "cannot replace $BIN/reloca-agent"

say "installed reloca.to $VER -> $BIN/reloca.to (libs in $LIB)"
# the driver finds its libs at /usr/local/lib/reloca.to on its own; any other
# prefix (tests) is on the caller to wire up, so only the default is smoked
if [ "$PREFIX" = /usr/local ]; then
	"$BIN/reloca.to" -V | grep -q "^reloca.to $VER " \
		|| die "installed, but '$BIN/reloca.to -V' does not report $VER: another copy of the libs is in the way ($("$BIN/reloca.to" version 2>&1))"
fi
# "curl -fsSL reloca.to | bash -s -- ARGS": install, then hand over to reloca.to
# with those arguments (a bare install only prints the hint). The scratch dir
# goes first: exec skips the EXIT trap.
if [ $# -gt 0 ]; then
	rm -rf "$TMP"; trap - EXIT INT TERM
	say "running: reloca.to $*"
	exec "$BIN/reloca.to" "$@"
fi
say "run 'reloca.to -h' for usage, or: curl -fsSL reloca.to | bash -s -- -s plan DONOR"
