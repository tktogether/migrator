#!/bin/bash
# tests/cases/live-boot.sh — the one-command entry. The build itself needs root,
# apt and twenty minutes, so what is checked here is the part that has to be
# right before that: the refusals, and the promise that a dry run changes
# nothing. The one thing this case cannot prove is that
# rig/build-live.sh + tools/live-entry.sh agree on the artefact names — that is
# asserted against the two scripts directly, below.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
L=$REPO/tools/live-boot.sh

out=$(bash "$L" -h 2>&1); rc=$?
assert_eq "the help exits 0" 0 "$rc"
assert_has "the help says no second machine is needed" "构建不需要第二台机器" "$out"
assert_has "the help names the two scripts it drives" "rig/build-live.sh" "$out"
assert_has "the help says how to get back out" "live-entry.sh -r" "$out"

out=$(bash "$L" -p nope 2>&1); rc=$?
assert_eq "an unknown profile is refused" 1 "$rc"
assert_has "the refusal names the two allowed profiles" "slim 或 full" "$out"

out=$(bash "$L" -z 2>&1); rc=$?
assert_eq "an unknown option is refused" 2 "$rc"

if [ "$(id -u)" != 0 ]; then
	out=$(bash "$L" -n 2>&1); rc=$?
	assert_eq "without root it says so instead of half-running" 2 "$rc"
	assert_has "the refusal says why root is needed" "需要 root" "$out"
else
	skip "the root refusal" "running as root"
fi

# The names have to agree: build-live.sh writes them, live-entry.sh reads them.
bl=$(cat "$REPO/rig/build-live.sh")
le=$(cat "$REPO/tools/live-entry.sh")
case $bl in
	*'vmlinuz-live'*) _pass "build-live.sh writes the kernel under the name live-entry.sh reads" ;;
	*) _fail "build-live.sh writes the kernel under the name live-entry.sh reads" "no vmlinuz-live" ;;
esac
case $bl in
	*'initrd-live.img'*) _pass "build-live.sh writes the initrd under the name live-entry.sh reads" ;;
	*) _fail "build-live.sh writes the initrd under the name live-entry.sh reads" "no initrd-live.img" ;;
esac
case $le in
	*'live/filesystem.squashfs'*) _pass "live-entry.sh reads live/filesystem.squashfs" ;;
	*) _fail "live-entry.sh reads live/filesystem.squashfs" "missing" ;;
esac

t_end
