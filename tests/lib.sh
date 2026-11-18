#!/bin/bash
# tests/lib.sh — assertion helpers for tests/cases/*.sh; every case sources it.
#
# A case is a plain bash script. The harness (tests/run.sh) runs it in its own
# process with RUN pointing at a throwaway state dir and awk = mawk; run by
# hand (bash tests/cases/x.sh) it creates and removes such a dir itself. The
# case sources this file, then lib/common.sh and whatever lib it exercises:
#   assert_eq   NAME EXPECTED ACTUAL      strings equal
#   assert_has  NAME NEEDLE HAYSTACK      HAYSTACK contains the substring NEEDLE
#   assert_ok   NAME CMD...               CMD exits 0
#   assert_fail NAME CMD...               CMD exits non-zero
#   assert_exit NAME CODE CMD...          CMD exits with exactly CODE
#   skip        NAME REASON               counted apart, never a failure
#   t_end                                 print the case total; exit 1 on any FAIL
# Every helper prints one line the harness counts by its prefix:
#   "  PASS name" / "  FAIL name (expected X got Y)" / "  SKIP name (reason)"
# Anything that must observe an exit (die, confirm, lock, cleanup) is run in
# a subshell by the case: die calls exit, and the EXIT trap common.sh installs
# would otherwise end the case early.
# exit (of a case): 0 all assertions passed · 1 at least one FAIL

T_PASS=0; T_FAIL=0; T_SKIP=0
REPO=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")
export REPO

# common.sh replaces the EXIT trap, so a self-made RUN is removed in t_end
# rather than by a trap of our own.
T_OWN_RUN=
if [ -z "${RUN:-}" ]; then
	RUN=$(mktemp -d /var/tmp/xslive-reloca-case.XXXXXX) || exit 1
	T_OWN_RUN=y
fi
export RUN

_pass() { echo "  PASS $1"; T_PASS=$((T_PASS+1)); }
_fail() { echo "  FAIL $1 ($2)"; T_FAIL=$((T_FAIL+1)); }

assert_eq()  { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "expected '$2' got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) _pass "$1";; *) _fail "$1" "expected to contain '$2' got '$3'";; esac; }
assert_ok() {
	local name=$1 rc=0; shift
	"$@" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then _pass "$name"; else _fail "$name" "expected exit 0 got $rc: $*"; fi
}
assert_fail() {
	local name=$1 rc=0; shift
	"$@" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then _pass "$name"; else _fail "$name" "expected a non-zero exit got 0: $*"; fi
}
assert_exit() {
	local name=$1 want=$2 rc=0; shift 2
	"$@" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq "$want" ]; then _pass "$name"; else _fail "$name" "expected exit $want got $rc: $*"; fi
}
skip() { echo "  SKIP $1 ($2)"; T_SKIP=$((T_SKIP+1)); }

t_end() {
	echo "  -- $(basename "$0" .sh): $T_PASS passed, $T_FAIL failed, $T_SKIP skipped"
	[ -n "$T_OWN_RUN" ] && rm -rf "$RUN"
	[ "$T_FAIL" -eq 0 ] || exit 1
	exit 0
}
