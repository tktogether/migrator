#!/bin/bash
# tests/cases/bootstrap.sh — lib/bootstrap.sh defines the functions the driver
# calls, sources without side effects, and bootstrap_missing SET reports what
# is absent, one name per line, without trying to fix anything. apt and sshd
# are never touched here: that is the stand's job.
# Skips (not fails) while the lib does not exist yet.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
LIB=$REPO/lib/bootstrap.sh; export LIB
CONTRACT="bootstrap_local bootstrap_donor bootstrap_missing"; export CONTRACT

[ -r "$LIB" ] || { skip "lib/bootstrap.sh" "not written yet"; t_end; }

# lib_sh 'snippet': a fresh bash with common.sh and the lib sourced, so the
# lib is seen exactly as the driver sees it, with nothing of this case around
lib_sh() { bash -c '. "$REPO/lib/common.sh"; . "$LIB"; eval "$1"' _ "$1"; }
# lib_missing: the CONTRACT names the lib does not define, space-separated
lib_missing() { bash -c '. "$REPO/lib/common.sh"; . "$LIB"; for f in $CONTRACT; do declare -F "$f" >/dev/null || printf "%s " "$f"; done' _; }

lib_sh 'true' > "$RUN/src.out" 2>&1; rc=$?
assert_eq "bootstrap.sh sources cleanly"     0  "$rc"
assert_eq "bootstrap.sh is silent on source" "" "$(cat "$RUN/src.out")"

lib_missing > "$RUN/missing" 2>/dev/null
assert_eq "bootstrap.sh defines the driver's contract functions" "" "$(sed 's/ $//' "$RUN/missing")"

# what the build host lacks is not fixed, but the output shape is: one plain
# name (or directory) per line, nothing else on stdout, no apt/dpkg run
for set in base grub donor; do
	lib_sh "DRY=y bootstrap_missing $set" > "$RUN/bm.$set" 2> "$RUN/bm.$set.err"; rc=$?
	assert_eq   "bootstrap_missing $set exits 0"            0 "$rc"
	assert_fail "bootstrap_missing $set: one name per line" grep -qvE '^[A-Za-z0-9._/+-]+$' "$RUN/bm.$set"
	assert_fail "bootstrap_missing $set: stderr is empty"   test -s "$RUN/bm.$set.err"
	assert_fail "bootstrap_missing $set: no apt/dpkg run"   grep -qE '^\+ (apt|apt-get|dpkg) ' "$RUN/bm.$set" "$RUN/bm.$set.err"
done
lib_sh 'bootstrap_missing bogus' >/dev/null 2>&1; rc=$?
assert_eq "bootstrap_missing with an unknown set exits 2" 2 "$rc"

# with an empty PATH every tool of the donor set is missing; stub them all in
# a fake bin dir and the same call must come back empty
lib_sh 'PATH=/nonexistent bootstrap_missing donor' > "$RUN/bm.none" 2>/dev/null
assert_has "donor set names tar"  "tar"  "$(cat "$RUN/bm.none")"
assert_has "donor set names lz4"  "lz4"  "$(cat "$RUN/bm.none")"
assert_has "donor set names partclone.extfs" "partclone.extfs" "$(cat "$RUN/bm.none")"
mkdir -p "$RUN/fakebin"
while read -r t; do [ -n "$t" ] && printf '#!/bin/sh\nexit 0\n' > "$RUN/fakebin/$t" && chmod 0755 "$RUN/fakebin/$t"; done < "$RUN/bm.none"
lib_sh "PATH=$RUN/fakebin bootstrap_missing donor" > "$RUN/bm.all" 2>/dev/null
assert_eq "bootstrap_missing donor: nothing missing when every tool exists" "" "$(cat "$RUN/bm.all")"

t_end
