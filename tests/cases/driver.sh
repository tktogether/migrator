#!/bin/bash
# tests/cases/driver.sh — bin/migrator's CLI surface that needs no Live:
# usage, -h, version, unknown command, bad -o, the full-Live gate, and the
# "not implemented yet" stop of a phase whose lib is still a placeholder.
# Everything runs with -n or stops before set_roles, so the build host's
# transient hostname is never touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
M=$REPO/bin/migrator

out=$(bash "$M" 2>&1); rc=$?
assert_eq  "no args exits 2"           2 "$rc"
assert_has "no args says DONOR is required" "DONOR is required" "$out"

out=$(bash "$M" -h 2>&1); rc=$?
assert_eq  "-h exits 0"                0 "$rc"
assert_has "-h prints usage"           "usage: migrator" "$out"
assert_has "usage lists the exit codes" "exit: 0 ok" "$out"
assert_has "usage is the header block, not a comment dump" "  -s STEP" "$out"
case "$out" in *"export PATH"*) _fail "usage stops at the first code line" "contains export PATH";; *) _pass "usage stops at the first code line";; esac
out=$(bash "$M" --help 2>&1); rc=$?
assert_eq  "--help exits 0"            0 "$rc"

out=$(bash "$M" -V 2>&1); rc=$?
assert_eq  "version exits 0"           0 "$rc"
if [ -e "$REPO/lib/VERSION" ]; then
	skip "version prints 'migrator dev'" "lib/VERSION exists in the tree: $(cat "$REPO/lib/VERSION")"
else
	assert_has "version prints 'migrator dev' without lib/VERSION" "migrator dev" "$out"
fi
assert_has "version names the lib dir" "lib=$REPO/lib" "$out"
out=$(bash "$M" -n -y -i /dev/null -d /dev/sdz -o data=raw -o compress=none --option cutover=none -V 2>&1); rc=$?
assert_eq  "all flags parse"           0 "$rc"

out=$(bash "$M" -s bogus 2>&1); rc=$?
assert_eq  "unknown step exits 2"      2 "$rc"
assert_has "unknown step says so"      "unknown step: bogus" "$out"
out=$(bash "$M" -o badopt -V 2>&1); rc=$?
assert_eq  "-o without = exits 2"      2 "$rc"
assert_has "-o without = says so"      "bad -o badopt" "$out"
out=$(bash "$M" -z -V 2>&1); rc=$?
assert_eq  "unknown flag exits 2"      2 "$rc"

if [ -r /etc/migrator-live-release ] || [ -r /etc/xserver-live-release ]; then
	skip "all off-Live" "this host is a Live"
else
	rm -f "$RUN/failure" "$RUN/lock"
	out=$(bash "$M" 10.0.0.12 2>&1); rc=$?
	assert_eq   "all on a non-Live host exits 2"     2 "$rc"
	assert_has  "all on a non-Live host says why"    "不是迁移 Live" "$out"
	assert_ok   "the gate recorded \$RUN/failure"    grep -q '^exit=2 ' "$RUN/failure"
	assert_fail "the gate fires before the lock"     test -e "$RUN/lock"
	out=$(bash "$M" --step plan 10.0.0.12 2>&1); rc=$?
	assert_eq   "plan on a non-Live host exits 2"    2 "$rc"
fi

# the lock must not survive an exec (tmux re-launch): unlock releases it so a
# child can take it again; without unlock the child must be refused
out=$(RUN=$RUN bash -c '. "'"$REPO"'/lib/common.sh"; lock; unlock; exec bash -c ". \"'"$REPO"'/lib/common.sh\"; lock; echo relocked"' 2>&1); rc=$?
assert_eq  "lock released by unlock before exec" 0 "$rc"
assert_has "child re-took the lock"               "relocked" "$out"
out=$(RUN=$RUN bash -c '. "'"$REPO"'/lib/common.sh"; lock; exec bash -c ". \"'"$REPO"'/lib/common.sh\"; lock"' 2>&1); rc=$?
assert_eq  "lock held across exec is refused"     2 "$rc"

out=$(bash "$M" -s plan 2>&1); rc=$?
assert_eq  "-s plan without DONOR exits 2"   2 "$rc"
assert_has "-s plan without DONOR says so"   "DONOR is required" "$out"

# the machines are named by role (destination/source), never by serial; there
# is no -l flag any more
out=$(bash "$M" -n -l 1:2 -V 2>&1); rc=$?
assert_eq  "-l is gone (usage error)"   2 "$rc"
out=$(bash "$M" -n -o force=1 -s check /nonexistent 2>&1); rc=$?
assert_has "role tag is 'destination'"  "[migrator destination]" "$out"

# check needs no Live; its lib is a placeholder until M1, and the driver has to
# say so instead of pretending. Under -n set_roles never calls hostnamectl.
if grep -q '^plan_check()' "$REPO/lib/plan.sh" 2>/dev/null; then
	skip "check without plan.sh" "plan_check exists now: replace this with a plan test"
else
	out=$(bash "$M" -n -s check 2>&1); rc=$?
	assert_eq  "unimplemented phase exits 1" 1 "$rc"
	assert_has "unimplemented phase says so" "phase 'check' is not implemented yet (M1)" "$out"
fi

t_end
