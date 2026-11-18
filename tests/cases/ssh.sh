#!/bin/bash
# tests/cases/ssh.sh — lib/ssh.sh defines the functions bin/reloca.to calls and
# sources without side effects. Nothing here opens a connection: the control
# channel is exercised on the two-VM stand (M1), not on the build host.
# Skips (not fails) while the lib does not exist yet.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
LIB=$REPO/lib/ssh.sh; export LIB
CONTRACT="ssh_connect rsh rsh_sh rpull rpush ssh_require_full_live_donor ssh_guard_same_box ssh_donor_serial ssh_start_data_sshd ssh_data_cmd ssh_disconnect"; export CONTRACT

[ -r "$LIB" ] || { skip "lib/ssh.sh" "not written yet"; t_end; }

# lib_sh 'snippet': a fresh bash with common.sh and the lib sourced, so the
# lib is seen exactly as the driver sees it, with nothing of this case around
lib_sh() { bash -c '. "$REPO/lib/common.sh"; . "$LIB"; eval "$1"' _ "$1"; }
# lib_missing: the CONTRACT names the lib does not define, space-separated
lib_missing() { bash -c '. "$REPO/lib/common.sh"; . "$LIB"; for f in $CONTRACT; do declare -F "$f" >/dev/null || printf "%s " "$f"; done' _; }

# sourcing must only define things: any output or non-zero status would leak
# into every reloca.to run
lib_sh 'true' > "$RUN/src.out" 2>&1; rc=$?
assert_eq "ssh.sh sources cleanly"     0  "$rc"
assert_eq "ssh.sh is silent on source" "" "$(cat "$RUN/src.out")"

lib_missing > "$RUN/missing" 2>/dev/null
assert_eq "ssh.sh defines the driver's contract functions" "" "$(sed 's/ $//' "$RUN/missing")"

# nothing may talk to a donor before ssh_connect
lib_sh 'rsh true' >/dev/null 2>&1; rc=$?
assert_eq "rsh before ssh_connect dies with exit 2" 2 "$rc"

t_end
