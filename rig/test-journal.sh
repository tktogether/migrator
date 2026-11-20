#!/bin/bash
# rig/test-journal.sh — the resume journal, end to end, on one host and no network.
#
#   donor     a real ext4 on a loop device, served by `migrator-agent serve`
#             (the pull reaches it with --ssh, which here is just `attach` on a
#             unix socket: the ssh hop is the one part of D41 that is already
#             covered, and a killed pull leaves an orphaned ssh either way)
#   recipient a plain file, written by `migrator-agent pull`
#   a writer  keeps rewriting the same 8 MiB of the source every 200 ms, so the
#             window in which the pull is dead really does have writes in it.
#             Without it this test proves nothing about D41's gap: a resume that
#             only repeats what it already had looks perfect against a quiet
#             source (that is exactly what D41 tested).
#
# What it proves, in order:
#   1  a pull that is kill -9'd leaves a journal that says how far it got;
#   2  the next pull adopts the donor's session and carries pass 1 on from that
#      offset -- "pass 1 resumed", not a second full pass -- and the copy still
#      hashes to the source after a freeze, with the writer stopped by it;
#   3  a donor whose daemon is gone has no session to offer: the journal is
#      dropped and the run says so, instead of trusting a stale offset.
#
# Not covered here, on purpose: two real machines, and the ssh hop. See
# rig/run-online.sh for the VM version and docs/HANDOFF.md §6.10.
set -uo pipefail
AG=${AG:-/root/migw/agent/migrator-agent}
W=${W:-/var/tmp/jt}
SRC_SZ=${SRC_SZ:-2G}
KILL_AT=${KILL_AT:-$((128 * 1024 * 1024))}   # one checkpoint's worth: the copy is well under way by then

say() { echo "[test] $*"; }
fail() {
	echo "FAIL: $*" >&2
	for f in "$W"/run*.log; do [ -f "$f" ] && { echo "---- $f"; tail -20 "$f"; }; done
	exit 1
}
cleanup() {
	if [ -f "$W/writer.pid" ]; then kill -- -"$(cat "$W/writer.pid")" 2>/dev/null || kill "$(cat "$W/writer.pid")" 2>/dev/null; fi
	pkill -9 -f "attach $W/donor.sock" 2>/dev/null
	pkill -9 -f "serve --listen $W/donor.sock" 2>/dev/null
	mountpoint -q "$W/mnt" 2>/dev/null && umount "$W/mnt" 2>/dev/null
	true
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || fail "needs root (loop device, mount, block tracing)"
[ -x "$AG" ] || fail "no agent at $AG"

# ---- the source -----------------------------------------------------------
say "building the source: $SRC_SZ on a loop device"
rm -rf "$W"; mkdir -p "$W/mnt"
truncate -s "$SRC_SZ" "$W/src.img" || fail "truncate"
mkfs.ext4 -q -F "$W/src.img" || fail "mkfs.ext4"
mount -o loop "$W/src.img" "$W/mnt" || fail "mount the loop"
head -c 8M /dev/urandom > "$W/mnt/blob" || fail "write the blob"
sync
# something outside the writer's 8 MiB, so pass 1 has real work past the hotspot
head -c 32M /dev/urandom > "$W/mnt/rest" || fail "write rest"
sync

say "starting a writer that keeps dirtying the source (so the gap has writes in it)"
setsid sh -c "while :; do dd if=/dev/urandom of='$W/mnt/blob' bs=1M count=8 conv=fsync 2>/dev/null; sleep 0.2; done" \
	>/dev/null 2>&1 &
echo $! > "$W/writer.pid"

# ---- one pull, written out once so all three runs are literally the same ----
# An array and not a function: `f &` backgrounds a subshell, and kill -9 on that
# would leave the pull running -- the test would then "prove" resuming against a
# process that never died.
# --thaw: the frozen source has to come back, or the umount in cleanup hangs on
# a filesystem nobody will ever thaw.
PULL=("$AG" pull --ssh "$AG attach $W/donor.sock" --vol "1=$W/mnt=$W/dst.raw"
	--chunk 64K --journal "$W/j.resume" --freeze auto --settle 200
	--passes 4 --stall 120 --thaw --verify)

# ---- 1: kill the pull in the middle of pass 1 ------------------------------
say "run 1: pull, then kill -9 once the journal says $KILL_AT bytes are down"
"${PULL[@]}" >"$W/run1.log" 2>&1 &
P=$!
killed=0
for _ in $(seq 1 4000); do
	h=$(awk '$1 == "v1" { print $5 }' "$W/j.resume" 2>/dev/null | sort -n | tail -1)
	if [ -n "${h:-}" ] && [ "$h" -ge "$KILL_AT" ]; then
		kill -9 "$P" 2>/dev/null && killed=1
		break
	fi
	kill -0 "$P" 2>/dev/null || break
	sleep 0.05
done
wait "$P" 2>/dev/null
[ "$killed" = 1 ] || fail "never got to kill the pull (journal: $(cat "$W/j.resume" 2>/dev/null || echo none))"
say "killed. journal now: $(tr '\n' ' ' < "$W/j.resume")"
say "the source was being written the whole time; the gap is not a quiet one"

# ---- 2: the same command again, which should carry on ---------------------
say "run 2: the same command, so pass 1 should resume instead of starting over"
"${PULL[@]}" >"$W/run2.log" 2>&1; rc=$?
grep -q 'an earlier run left' "$W/run2.log" || fail "run 2 did not find the journal"
grep -q 'carrying on there' "$W/run2.log" || fail "run 2 did not resume the pass"
grep -q 'pass 1 resumed' "$W/run2.log" || fail "run 2 ran a second FULL pass: the offset was not used"
grep -q 'journal=resumed' "$W/run2.log" || fail "RESULT does not report journal=resumed"
grep -q 'sha256 .* equal' "$W/run2.log" || fail "the resumed copy does not hash to the source (a gap chunk was lost)"
[ "$rc" = 0 ] || fail "run 2 exited $rc"
say "run 2: $(grep -E 'pass 1 resumed|sha256|^RESULT' "$W/run2.log" | tr '\n' ' ')"
# the journal must not outlive a finished copy
[ ! -f "$W/j.resume" ] || fail "the journal survived a successful run"

# ---- 3: a donor with no session is not a donor to resume from -------------
say "run 3: kill the donor's daemon (what a reboot looks like to the pull), then run"
pkill -9 -f "serve --listen $W/donor.sock" 2>/dev/null
rm -f "$W/donor.sock" "$W/donor.sock.lock" "$W/donor.sock.log"
# put a journal back, as a run that died before its donor did would have left
printf 'v1 %032d 1 %s %s 0 0 %s\n' 0 "$(stat -c %s "$W/dst.raw")" "$((100 * 1024 * 1024))" "$W/dst.raw" > "$W/j.resume"
"${PULL[@]}" >"$W/run3.log" 2>&1 &
P3=$!
said=0
for _ in $(seq 1 600); do
	if grep -q 'no longer holds that session' "$W/run3.log" 2>/dev/null; then said=1; break; fi
	kill -0 "$P3" 2>/dev/null || break
	sleep 0.05
done
kill -9 "$P3" 2>/dev/null
wait "$P3" 2>/dev/null
[ "$said" = 1 ] || fail "run 3 trusted a journal whose session is gone (no warning, no drop)"
[ ! -f "$W/j.resume" ] || fail "the journal survived a session that no longer exists"
say "run 3 said so and dropped the journal instead of resuming onto it"

echo "JOURNAL_TEST_OK"
