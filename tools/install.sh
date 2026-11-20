#!/bin/sh
# install.sh — put migrator onto a running Live system of yours. There is no
# vendor download here: the artefacts come from wherever you publish them, so
# MIGRATOR_URL must point at a directory that holds SHA256SUMS and the one
# migrator-<ver>.tar.gz it lists:
#
#   from a checkout: make install                 # no download at all
#   MIGRATOR_URL=file://$PWD/dist sh tools/install.sh      # straight from a built tarball
#   MIGRATOR_URL=https://your.host/migrator sh tools/install.sh
#
# On a Live that has neither the tree nor the tarball, fetch this script and
# run it: it needs nothing but a shell, curl or wget, tar and sha256sum.
#
# Downloads SHA256SUMS and the one migrator-<ver>.tar.gz it lists, checks
# the tarball's sha256, unpacks it in a scratch dir and installs
#   $PREFIX/sbin/migrator        the driver
#   $PREFIX/sbin/migrator-agent     the on-line migration agent (static binary, when the tarball has it)
#   $PREFIX/lib/migrator/       the libs + VERSION (the previous dir is replaced)
# with PREFIX = MIGRATOR_PREFIX or /usr/local. Everything is staged and moved
# into place last, so a failed download, a bad checksum or a broken tarball
# never leaves a half-installed tree. Uses curl or wget, whichever exists
# (busybox wget is enough; file:// needs curl). The Live is tmpfs: run this
# again after a reboot.
# exit: 0 installed · 1 download, checksum, unpack or install failure · 2 no curl/wget
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
BASE=${MIGRATOR_URL:-}
PREFIX=${MIGRATOR_PREFIX:-/usr/local}

say() { echo "[migrator-install] $*"; }
die() { echo "[migrator-install] ERROR: $*" >&2; exit "${CODE:-1}"; }

# there is no default place to download from: the artefacts are yours to host
[ -n "$BASE" ] || die "no artefact source: set MIGRATOR_URL to the directory holding SHA256SUMS and migrator-<ver>.tar.gz (a file:// URL is enough), or run 'make install' from a checkout"

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -q -O "$2" "$1"; }
else
	CODE=2 die "neither curl nor wget found"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/migrator-install.XXXXXX") || die "cannot create a scratch dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "fetching $BASE/SHA256SUMS"
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || die "cannot download $BASE/SHA256SUMS"
# the listing names exactly one tarball; anything else means a broken publish
TARBALL=$(awk '$2 ~ /^migrator-.*\.tar\.gz$/ { print $2 }' "$TMP/SHA256SUMS")
COUNT=$(printf '%s\n' "$TARBALL" | grep -c .)
[ "$COUNT" -eq 1 ] || die "SHA256SUMS at $BASE lists $COUNT tarballs, expected one migrator-<ver>.tar.gz"
VER=${TARBALL#migrator-}; VER=${VER%.tar.gz}

say "fetching $BASE/$TARBALL"
fetch "$BASE/$TARBALL" "$TMP/$TARBALL" || die "cannot download $BASE/$TARBALL"
awk -v t="$TARBALL" '$2 == t' "$TMP/SHA256SUMS" > "$TMP/SHA256SUMS.tarball"
( cd "$TMP" && sha256sum -c SHA256SUMS.tarball >/dev/null 2>&1 ) || die "checksum mismatch for $TARBALL (a publish in progress? retry in a minute)"

mkdir "$TMP/x" || die "cannot create $TMP/x"
tar -xzf "$TMP/$TARBALL" -C "$TMP/x" || die "cannot unpack $TARBALL"
SRC=$TMP/x/migrator-$VER
for f in bin/migrator lib/common.sh lib/VERSION; do
	[ -s "$SRC/$f" ] || die "unexpected tarball layout: no migrator-$VER/$f"
done

# stage next to the final paths so the last step is a rename, never a copy
BIN=$PREFIX/sbin; LIB=$PREFIX/lib/migrator; STAGE=$PREFIX/lib/.migrator.new.$$
mkdir -p "$BIN" "$PREFIX/lib" || die "cannot create $BIN / $PREFIX/lib"
rm -rf "$STAGE"
cp -R "$SRC/lib" "$STAGE" || die "cannot stage the libs under $PREFIX/lib"
chmod 0755 "$STAGE" || die "cannot set modes under $STAGE"
chmod 0644 "$STAGE"/* || die "cannot set modes under $STAGE"
cp "$SRC/bin/migrator" "$BIN/.migrator.new" || die "cannot stage $BIN/migrator"
chmod 0755 "$BIN/.migrator.new" || die "cannot set modes on $BIN/migrator"
# the on-line migration agent (static binary, both ends; absent in older tarballs)
if [ -s "$SRC/bin/migrator-agent" ]; then
	cp "$SRC/bin/migrator-agent" "$BIN/.migrator-agent.new" || die "cannot stage $BIN/migrator-agent"
	chmod 0755 "$BIN/.migrator-agent.new" || die "cannot set modes on $BIN/migrator-agent"
fi
rm -rf "$LIB" || die "cannot remove the previous $LIB"
mv "$STAGE" "$LIB" || die "cannot move the libs into place at $LIB"
mv -f "$BIN/.migrator.new" "$BIN/migrator" || die "cannot replace $BIN/migrator"
[ ! -s "$BIN/.migrator-agent.new" ] || mv -f "$BIN/.migrator-agent.new" "$BIN/migrator-agent" || die "cannot replace $BIN/migrator-agent"

say "installed migrator $VER -> $BIN/migrator (libs in $LIB)"
# the driver finds its libs at /usr/local/lib/migrator on its own; any other
# prefix (tests) is on the caller to wire up, so only the default is smoked
if [ "$PREFIX" = /usr/local ]; then
	"$BIN/migrator" -V | grep -q "^migrator $VER " \
		|| die "installed, but '$BIN/migrator -V' does not report $VER: another copy of the libs is in the way ($("$BIN/migrator" version 2>&1))"
fi
# "curl -fsSL migrator | bash -s -- ARGS": install, then hand over to migrator
# with those arguments (a bare install only prints the hint). The scratch dir
# goes first: exec skips the EXIT trap.
if [ $# -gt 0 ]; then
	rm -rf "$TMP"; trap - EXIT INT TERM
	say "running: migrator $*"
	exec "$BIN/migrator" "$@"
fi
say "run 'migrator -h' for usage, or: sh tools/install.sh -s plan DONOR"
