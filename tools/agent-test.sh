#!/bin/bash
# tools/agent-test.sh — the quick test of agent/migrator-agent on THIS host (root,
# loop devices, no QEMU, about a minute): a filesystem on a loop device is
# written to all the time by a generator while "pull" copies it from a local
# "serve" (the --ssh command is just the agent itself), freezes it for the
# final delta and compares sha256 of the frozen volume with what it wrote.
# Cases: ext4 on a whole loop device, by bpf and by ftrace; ext4 on a
# PARTITION of a loop device (traced on the whole disk with the partition's
# start subtracted); a block device as the target (O_DIRECT writes, BLKZEROOUT);
# the cutover poller (pull --cutover, then ping/thaw through migrator-agent cutover);
# a vfat (no freeze) under a filesystem that must still be frozen.
# usage: tools/agent-test.sh [-k] [-s SIZE_MiB] [-g GENSLEEP]
# exit: 0 PASS · 1 a case failed · 2 environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
REPO=$(readlink -f "$(dirname "$0")/..")
AGENT=$REPO/agent/migrator-agent
KEEP=0; SIZE=2048; GENSLEEP=0.05
while getopts ks:g:h o; do case $o in k) KEEP=1;; s) SIZE=$OPTARG;; g) GENSLEEP=$OPTARG;; *) sed -n '2,/^export PATH/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 2;; esac; done
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
[ -x "$AGENT" ] || { echo "no $AGENT: make -C agent"; exit 2; }
for t in losetup mkfs.ext4 sfdisk; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
WORK=$(mktemp -d /var/tmp/xslive-agent-test.XXXXXX) || exit 2
MNT=$WORK/mnt; mkdir -p "$MNT"
LOOPS=(); GENPID=""; RESULT=0
# shellcheck disable=SC2317  # reached through the EXIT trap
cleanup() {
	[ -z "$GENPID" ] || { kill "$GENPID" 2>/dev/null; pkill -P "$GENPID" 2>/dev/null; wait "$GENPID" 2>/dev/null; GENPID=""; }
	mountpoint -q "$MNT" && { fsfreeze -u "$MNT" 2>/dev/null; umount "$MNT"; }
	local l; for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done; LOOPS=()
	[ "$KEEP" -eq 1 ] && { echo "  work dir kept: $WORK"; return; }
	rm -rf "$WORK"
}
trap cleanup EXIT

gen() { # MOUNT: the PoC's workload - a random-write "db", new files, a log, deletions
	local g=$1/gen i=0 n
	mkdir -p "$g"; dd if=/dev/urandom of="$g/db" bs=1M count=64 status=none
	while :; do
		n=$((1 + RANDOM % 3))
		dd if=/dev/urandom of="$g/f$((i % 64))" bs=1M count=$n status=none
		dd if=/dev/urandom of="$g/db" bs=4k count=1 seek=$((RANDOM % 16384)) conv=notrunc status=none
		echo "$i $(date +%s.%N)" >> "$g/log"
		[ $((i % 11)) -ne 0 ] || rm -f "$g/f$(( (i * 7) % 64 ))"
		i=$((i + 1)); sleep "$GENSLEEP"
	done
}
mkimg() { # NAME SIZE_MiB -> loop device
	local f=$WORK/$1.img l
	truncate -s "${2}M" "$f" || exit 2
	l=$(losetup --show -f "$f") || exit 2
	LOOPS+=("$l"); echo "$l"
}
fill() { # MOUNT: some content so the volume is not all zeros (a quarter of it)
	dd if=/dev/urandom of="$1/blob" bs=1M count=$((SIZE / 4)) status=none; cp -a /usr/bin "$1/bin" 2>/dev/null; sync
}
run_case() { # NAME DST EXTRA_PULL_ARGS... -> PASS/FAIL
	local name=$1 dst=$2; shift 2
	local out="$WORK/$name.out" rc
	gen "$MNT" & GENPID=$!
	sleep 2
	echo "-- $name"
	"$AGENT" pull --ssh "$AGENT serve" --vol "1=$MNT=$dst" --verify --thaw --quiet "$@" > "$out" 2>&1; rc=$?
	kill "$GENPID" 2>/dev/null; pkill -P "$GENPID" 2>/dev/null; wait "$GENPID" 2>/dev/null; GENPID=""
	grep -E "^pull: (tracking|pass|converged|not converging|final|vol 1: (sha256|MISMATCH))|^RESULT" "$out" | sed 's/^/  | /'
	if [ $rc -eq 0 ] && grep -q "^RESULT ok" "$out" && grep -q "sha256 .* equal" "$out"; then echo "  PASS $name"; else echo "  FAIL $name (rc $rc; $out)"; grep -v "^pull: donor stat" "$out" | tail -15 | sed 's/^/  | /'; RESULT=1; fi
	rm -rf "$MNT/gen"
}

# case 1 + 2: ext4 on the whole loop device, to a file, bpf then ftrace
SRC=$(mkimg src "$SIZE"); mkfs.ext4 -q -F "$SRC" && mount "$SRC" "$MNT" || exit 2
fill "$MNT"
run_case bpf-to-file "$WORK/dst1.img" --tracker bpf --converge 2
run_case ftrace-to-file "$WORK/dst2.img" --tracker ftrace --converge 2
# case 3: a block device as the target
DST=$(mkimg dst "$SIZE"); dd if=/dev/urandom of="$DST" bs=1M count=8 status=none   # not blank: zero frames must zero it
run_case bpf-to-blockdev "$DST" --tracker bpf --converge 2
umount "$MNT"; losetup -d "$SRC"; LOOPS=("$DST")
# case 4: ext4 on a partition (traced on the whole disk, offset)
truncate -s "${SIZE}M" "$WORK/part.img" || exit 2
echo "label: dos
start=2048, size=$(( (SIZE - 8) * 2048 )), type=83" | sfdisk -q "$WORK/part.img" >/dev/null || exit 2
PART=$(losetup --show -f -P "$WORK/part.img") || exit 2; LOOPS+=("$PART")
sleep 0.5; [ -b "${PART}p1" ] || { echo "no ${PART}p1"; exit 2; }
mkfs.ext4 -q -F "${PART}p1" && mount "${PART}p1" "$MNT" || exit 2
fill "$MNT"
run_case bpf-partition "$WORK/dst4.img" --tracker bpf --converge 2
run_case ftrace-partition "$WORK/dst5.img" --tracker ftrace --converge 2
# case 6: the cutover poller: pull leaves the volume frozen and the donor polling us;
# ping, then thaw through the poller, then a write must go through again
echo "-- cutover-poll"
PORT=$(( 20000 + RANDOM % 20000 ))
"$AGENT" pull --ssh "$AGENT serve" --vol "1=$MNT=$WORK/dst6.img" --quiet --tracker bpf --converge 2 --cutover "127.0.0.1:$PORT" > "$WORK/cutover.out" 2>&1; rc=$?
grep -E "^RESULT|^CUTOVER" "$WORK/cutover.out" | sed 's/^/  | /'
TOKEN=$(sed -n 's/^CUTOVER .*token=//p' "$WORK/cutover.out")
if [ $rc -ne 0 ] || [ -z "$TOKEN" ]; then echo "  FAIL cutover-poll (pull rc $rc, token '$TOKEN')"; RESULT=1
else
	# a write on a frozen filesystem blocks uninterruptibly (no timeout can kill it): probe in the background
	touch "$MNT/frozen-probe" 2>/dev/null & TP=$!
	sleep 3
	if kill -0 "$TP" 2>/dev/null; then echo "  ok   a write blocks: the volume is frozen"; else echo "  FAIL cutover-poll: a write went through, the volume is not frozen"; RESULT=1; fi
	if "$AGENT" cutover --port "$PORT" --token "$TOKEN" --timeout 30 ping | grep -q '^donor: ok ping'; then echo "  ok   ping answered by the donor's poller"; else echo "  FAIL cutover-poll: no ping answer"; RESULT=1; fi
	if "$AGENT" cutover --port "$PORT" --token wrong-token --timeout 8 ping >/dev/null 2>&1; then echo "  FAIL cutover-poll: a wrong token was accepted"; RESULT=1; else echo "  ok   a wrong token is ignored"; fi
	if "$AGENT" cutover --port "$PORT" --token "$TOKEN" --timeout 30 thaw | grep -q '^donor: ok thaw'; then echo "  ok   thaw through the poller"; else echo "  FAIL cutover-poll: thaw failed"; RESULT=1; fi
	wait "$TP" 2>/dev/null
	if timeout 5 touch "$MNT/thawed-probe" 2>/dev/null; then echo "  PASS cutover-poll"; else echo "  FAIL cutover-poll: still frozen after thaw"; RESULT=1; fsfreeze -u "$MNT" 2>/dev/null; fi
fi
# case 7: a filesystem that cannot be frozen (vfat, as an ESP) UNDER one that can.
# The freeze goes deepest first, so the vfat is skipped and the ext4 below it must
# still freeze: the regression of the double-ioctl bug, which froze a filesystem and
# then asked again, got EBUSY and left it frozen (Rocky's /boot, 2026-10-21).
echo "-- freeze-skips-vfat"
mkdir -p "$MNT/esp"
ESPDEV=$(mkimg esp 64)
if ! { mkfs.vfat -F32 "$ESPDEV" >/dev/null 2>&1 && mount "$ESPDEV" "$MNT/esp"; }; then echo "  FAIL freeze-skips-vfat: cannot mount the vfat"; RESULT=1; fi
if mountpoint -q "$MNT/esp"; then
	cp /usr/bin/true "$MNT/esp/" 2>/dev/null; sync
	"$AGENT" pull --ssh "$AGENT serve" --vol "1=$MNT=$WORK/dst7.img" --vol "2=$MNT/esp=$WORK/dst7esp.img" 		--quiet --tracker bpf --converge 2 --verify --thaw > "$WORK/vfat.out" 2>&1; rc=$?
	grep -E "^pull: (donor: (frozen|.*cannot be frozen)|vol [0-9]+ .*cannot be frozen|final)|^RESULT" "$WORK/vfat.out" | sed 's/^/  | /'
	ok=1
	grep -q "cannot be frozen" "$WORK/vfat.out" || { echo "  FAIL freeze-skips-vfat: the vfat was not reported as unfreezable"; ok=0; }
	grep -q "donor: frozen $MNT\$" "$WORK/vfat.out" || { echo "  FAIL freeze-skips-vfat: $MNT was not frozen after the skipped vfat"; ok=0; }
	grep -q "^RESULT ok" "$WORK/vfat.out" || { echo "  FAIL freeze-skips-vfat: pull did not finish (rc $rc)"; tail -5 "$WORK/vfat.out" | sed 's/^/  | /'; ok=0; }
	grep -q "vol 1: sha256 .* equal" "$WORK/vfat.out" || { echo "  FAIL freeze-skips-vfat: the frozen volume does not match"; ok=0; }
	if [ "$ok" = 1 ]; then echo "  PASS freeze-skips-vfat"; else RESULT=1; fi
	umount "$MNT/esp"
fi
rmdir "$MNT/esp" 2>/dev/null
[ $RESULT -eq 0 ] && echo "== PASS ==" || echo "== FAIL =="
exit $RESULT
