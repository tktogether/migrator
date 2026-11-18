#!/bin/bash
# tests/cases/common.sh — lib/common.sh: formatting, options, state, run/-n,
# die and the failure record, confirm, lock, cleanup order. No root, no network.
# Anything that exits (die, confirm, lock, the EXIT trap) runs in a subshell or
# in a fresh bash, never in this process.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# fresh_sh 'snippet': a new bash that sources common.sh and runs the snippet,
# for tests of what sourcing itself sets up (the EXIT trap)
fresh_sh() { bash -c '. "$REPO/lib/common.sh"; eval "$1"' _ "$1"; }

# --- which awk (the Live has only mawk) ---------------------------------------
case "$(awk -W version 2>&1 | head -1)" in
	mawk*) _pass "awk is mawk";;
	*) skip "awk is mawk" "running with $(awk -W version 2>&1 | head -1)";;
esac

# --- human / bytes ------------------------------------------------------------
assert_eq "human 0"       "0B"    "$(human 0)"
assert_eq "human 1023"    "1023B" "$(human 1023)"
assert_eq "human 1024"    "1.0K"  "$(human 1024)"
assert_eq "human 1536"    "1.5K"  "$(human 1536)"
assert_eq "human 1 GiB"   "1.0G"  "$(human 1073741824)"
assert_eq "human 2 TiB"   "2.0T"  "$(human 2199023255552)"
assert_eq "human 1.5 TiB" "1.5T"  "$(human 1649267441664)"
assert_eq "bytes 4096" 4096          "$(bytes 4096)"
assert_eq "bytes 1G"   1073741824    "$(bytes 1G)"
assert_eq "bytes 512M" 536870912     "$(bytes 512M)"
assert_eq "bytes 2T"   2199023255552 "$(bytes 2T)"
assert_eq "bytes 8K"   8192          "$(bytes 8K)"
assert_eq "bytes 1.5G" 1610612736    "$(bytes 1.5G)"
assert_eq "human(bytes()) round trip" "1.5G" "$(human "$(bytes 1.5G)")"

# --- opt ----------------------------------------------------------------------
OPT[compress]=zstd
OPT[empty]=
assert_eq "opt set"                      zstd "$(opt compress lz4)"
assert_eq "opt unset -> default"         lz4  "$(opt data lz4)"
assert_eq "opt unset, no default"        ""   "$(opt nothing)"
assert_eq "opt empty value -> default"   ssh  "$(opt empty ssh)"

# --- say / warn / log ---------------------------------------------------------
assert_eq "say prefix"    "[reloca.to] hello" "$(say hello)"
assert_eq "say with role" "[reloca.to destination] hello" "$(ROLE_TAG='destination' say hello)"
assert_ok "say logs to \$RUN/log" grep -q ' hello$' "$RUN/log"
assert_eq "warn prefix"   "[reloca.to] WARN: careful" "$(warn careful 2>/dev/null)"
warn counted >/dev/null 2>&1
assert_eq "warn counts"   1 "$WARNINGS"

# --- state --------------------------------------------------------------------
rm -f "$RUN/state"
assert_eq "state_get without a state file" "" "$(state_get a)"
state_set a 1; state_set b 2; state_set a 3
assert_eq "state_set: last write wins"        3 "$(state_get a)"
assert_eq "state_set: other keys untouched"   2 "$(state_get b)"
assert_eq "state file: one line per key"      1 "$(grep -c '^a=' "$RUN/state")"
state_set ab 9
assert_eq "state key matched whole (a vs ab)" 3 "$(state_get a)"
state_set fp "sda 894"
assert_eq "state value with spaces"           "sda 894" "$(state_get fp)"
state_set eq "x=y"
assert_eq "state value with ="                "x=y" "$(state_get eq)"
assert_fail "phase_is_done before phase_done" phase_is_done apply
phase_done apply
assert_ok   "phase_is_done after phase_done"  phase_is_done apply
assert_fail "phase_is_done for another phase" phase_is_done transfer
vol_state_set 3 pending; vol_state_set 3 running
assert_eq "vol_state_set/get (last wins)" running "$(vol_state_get 3)"
assert_eq "vol_state_get unknown volume"  ""      "$(vol_state_get 4)"
assert_eq "vol/phase keys do not collide" 3       "$(state_get a)"

# --- run / run_sh / must ------------------------------------------------------
rm -f "$RUN/marker"
out=$(DRY=y run touch "$RUN/marker")
assert_eq   "run -n prints (dry) prefix"  "(dry) touch $RUN/marker" "$out"
assert_fail "run -n does not execute"     test -e "$RUN/marker"
out=$(DRY='' run touch "$RUN/marker")
assert_eq   "run prints + prefix"         "+ touch $RUN/marker" "$out"
assert_ok   "run executes"                test -e "$RUN/marker"
DRY='' run sh -c 'exit 3' >/dev/null; rc=$?
assert_eq   "run returns the command status" 3 "$rc"
# the echoed line must be replayable by hand: quoting has to survive
out=$(DRY=y run printf '%s|' 'a b' "c'd")
assert_eq   "run quotes arguments (printf %q)" "(dry) printf %s\\| a\\ b c\\'d" "$out"
assert_eq   "run's echo replays to the same call" "a b|c'd|" "$(eval "${out#(dry) }")"
out=$(DRY=y run_sh "echo hi | tr a-z A-Z")
assert_eq   "run_sh -n prints the pipeline" "(dry) echo hi | tr a-z A-Z" "$out"
out=$(DRY='' run_sh "echo hi | tr a-z A-Z" | tail -1)
assert_eq   "run_sh executes the pipeline"  "HI" "$out"
( DRY='' run_sh "false | true" ) >/dev/null 2>&1; rc=$?
assert_eq   "run_sh has pipefail"           1 "$rc"
( DRY='' must sh -c 'exit 7' ) >/dev/null 2>&1; rc=$?
assert_eq   "must dies (exit 1) on failure" 1 "$rc"
( DRY=y must false ) >/dev/null 2>&1; rc=$?
assert_eq   "must -n never fails"           0 "$rc"

# --- die ----------------------------------------------------------------------
rm -f "$RUN/failure"
( PHASE=apply VOLUME=3 die 3 "boom" ) >"$RUN/die.out" 2>"$RUN/die.err"; rc=$?
assert_eq  "die exits with the given code"     3 "$rc"
assert_ok  "die writes \$RUN/failure"          test -s "$RUN/failure"
failure=$(cat "$RUN/failure")
assert_has "failure: exit="                    "exit=3 "        "$failure"
assert_has "failure: phase="                   "phase=apply "   "$failure"
assert_has "failure: volume="                  "volume=3 "      "$failure"
assert_has "failure: reason="                  "reason=boom "   "$failure"
assert_has "failure: log="                     "log=$RUN/log"   "$failure"
assert_eq  "die: last stdout line is the reason" "[reloca.to] ERROR: boom" "$(tail -1 "$RUN/die.out")"
assert_has "die: reason also on stderr"        "ERROR: boom"    "$(cat "$RUN/die.err")"
assert_ok  "die: reason in the log"            grep -q 'ERROR(exit 3): boom$' "$RUN/log"
( die "plain" ) >/dev/null 2>&1; rc=$?
assert_eq  "die without code exits 1"          1 "$rc"
( die 4 "no plan" ) >/dev/null 2>&1; rc=$?
assert_eq  "die 4 (EX_PLAN)"                   4 "$rc"
assert_eq  "exit code table" "0 1 2 3 4" "$EX_OK $EX_FAIL $EX_ENV $EX_VERIFY $EX_PLAN"

# --- confirm ------------------------------------------------------------------
( YES=y confirm "wipe sda?" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "confirm with -y returns 0"                    0 "$rc"
( YES=y confirm "wipe sda?" "sda 894" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "confirm with -y skips the typed check too"    0 "$rc"
( YES='' confirm "wipe sda?" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "confirm without tty and without -y exits 2"   2 "$rc"
( YES='' confirm "wipe sda?" ) </dev/null 2>/dev/null | grep -q "no terminal to confirm"
assert_eq "confirm without tty says why"                 0 "${PIPESTATUS[1]}"

# --- lock ---------------------------------------------------------------------
( lock ) >/dev/null 2>&1; rc=$?
assert_eq "lock when free"                        0 "$rc"
( lock ) >/dev/null 2>&1; rc=$?
assert_eq "lock is released on exit"              0 "$rc"
( lock; ( lock ) >/dev/null 2>&1; echo "inner=$?" ) > "$RUN/lock.out" 2>/dev/null
assert_eq "second instance is refused (exit 2)"   "inner=2" "$(cat "$RUN/lock.out")"

# --- cleanup: installed by sourcing, LIFO, survives a failing snippet, on die too
rm -f "$RUN/order"
fresh_sh "cleanup_add 'echo first >> $RUN/order'; cleanup_add false; cleanup_add 'echo second >> $RUN/order'; exit 0"
assert_eq "cleanup_add runs LIFO on exit" "second first" "$(tr '\n' ' ' < "$RUN/order" | sed 's/ $//')"
rm -f "$RUN/order"
fresh_sh "cleanup_add 'echo died >> $RUN/order'; die 1 x" >/dev/null 2>&1
assert_eq "cleanup runs on die"           "died" "$(cat "$RUN/order")"
fresh_sh "cleanup_add false; exit 0"; rc=$?
assert_eq "a failing snippet does not change the exit code" 0 "$rc"

# --- environment ----------------------------------------------------------------
if [ -r /etc/xserver-live-release ]; then
	skip "require_full_live off-Live" "this host is a Live"
else
	( require_full_live ) >"$RUN/rfl.out" 2>/dev/null; rc=$?
	assert_eq  "require_full_live off-Live exits 2" 2 "$rc"
	assert_has "require_full_live off-Live says why" "not an XServer Live OS" "$(cat "$RUN/rfl.out")"
fi
mkdir -p "$RUN/lib"; echo 1.2.3 > "$RUN/lib/VERSION"
assert_eq "reloca_version without lib/VERSION" dev   "$(RELOCA_LIB=$RUN/nolib reloca_version)"
assert_eq "reloca_version from lib/VERSION"    1.2.3 "$(RELOCA_LIB=$RUN/lib reloca_version)"

t_end
