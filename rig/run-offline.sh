#!/bin/bash
# rig/run-offline.sh — the E2E offline migration run (D6/D8/D11 + D17 lessons):
#   donor VM     : Live ISO, donor-disk.raw as vda, 512M RAM   (hostfwd 2233->22 control, 2222->2222 data)
#   recipient VM : Live ISO, target-disk.raw (blank) as vda, 768M RAM (hostfwd 2255->22)
# VM RAM is small on purpose: the build container has 4G and two 1G guests with
# full TCG translation caches put the host into constant reclaim (memory.events
# max=50k) which freezes the guests mid-run. tb-size caps the JIT cache.
# migrator runs detached INSIDE the recipient VM (no tmux); its exit code lands
# in /root/migrator.rc, which the poller below reads — an ssh hiccup must never be
# mistaken for completion (that was the "rc=" bug).
set -uo pipefail
OUT=${RIG_OUT:-$HOME/rig}
ISO=$OUT/migrator-live.iso
DONOR_DISK=$OUT/donor-disk.raw
TARGET_DISK=$OUT/target-disk.raw
KEY=$OUT/rig_ed25519
LOGS=$OUT/logs; mkdir -p "$LOGS"
exec 9>"$OUT/.run.lock"; flock -n 9 || { echo "another run-offline.sh is already active" >&2; exit 1; }
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
# TCG is the lowest common denominator: it works inside a container with no
# /dev/kvm, at the price of a slow run. A VM with nested virt has /dev/kvm and
# ACCEL=kvm turns a 40-minute run into a few minutes (tb-size is TCG only).
ACCEL=${ACCEL:-tcg}
# guest RAM: 512/768 is what a 4 GiB rig host affords. On a tighter host the
# Live's `toram` still needs the whole ISO in RAM, so do not go below 512 for
# the donor -- shrink the recipient first, it only has to run migrator.
DONOR_MEM=${DONOR_MEM:-512}
RECIP_MEM=${RECIP_MEM:-768}
[ "$ACCEL" = tcg ] && ACCEL="tcg,thread=multi,tb-size=128"
[ "$ACCEL" = kvm ] && ACCEL="kvm"

# kill leftovers from a previous run
for pidf in "$OUT"/donor.pid "$OUT"/recipient.pid; do
	[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"
done
sleep 1

[ -s "$ISO" ] || { echo "no ISO at $ISO (rig/build-live.sh)" >&2; exit 1; }
[ -s "$DONOR_DISK" ] || { echo "no donor disk at $DONOR_DISK (rig/build-donor.sh)" >&2; exit 1; }
: > "$TARGET_DISK"; truncate -s 20G "$TARGET_DISK"   # sparse; migrator's plan rule R1 wants >= 20 GiB

echo "[rig] starting donor VM..."
qemu-system-x86_64 -accel "$ACCEL" -smp 2 -m "$DONOR_MEM" \
	-display none -monitor none -serial file:"$LOGS/donor-serial.log" \
	-cdrom "$ISO" -boot order=d \
	-drive file="$DONOR_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2233-:22,hostfwd=tcp:127.0.0.1:2222-:2222 \
	-device virtio-net-pci,netdev=n0,mac=52:54:00:aa:00:22 \
	-smbios type=1,serial=RIG-DONOR-0001 \
	-daemonize -pidfile "$OUT/donor.pid"

echo "[rig] starting recipient VM..."
qemu-system-x86_64 -accel "$ACCEL" -smp 2 -m "$RECIP_MEM" \
	-display none -monitor none -serial file:"$LOGS/recipient-serial.log" \
	-cdrom "$ISO" -boot order=d \
	-drive file="$TARGET_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2255-:22 \
	-device virtio-net-pci,netdev=n0,mac=52:54:00:aa:00:33 \
	-smbios type=1,serial=RIG-RECIP-0002 \
	-daemonize -pidfile "$OUT/recipient.pid"

wait_ssh() { # port label
	local port=$1 label=$2 i
	for i in $(seq 1 60); do
		if ssh $SSH_OPTS -p "$port" root@127.0.0.1 true 2>/dev/null; then
			echo "[rig] $label is up (attempt $i)"; return 0
		fi
		sleep 10
	done
	echo "FAIL: $label did not come up (see $LOGS)" >&2; return 1
}
wait_ssh 2233 donor || exit 1
wait_ssh 2255 recipient || exit 1

echo "[rig] pushing the rig key into the recipient VM and starting the migration detached..."
scp $SSH_OPTS -P 2255 "$KEY" root@127.0.0.1:/root/rig-key >/dev/null
# MIGRATOR_EXTRA_OPTS: extra -o flags (e.g. "-o boottest=1" once the Live bakes qemu)
ssh $SSH_OPTS -p 2255 root@127.0.0.1 "
	rm -f /root/migrator.rc /root/migrator-run.log
	setsid nohup sh -c 'migrator -y ${MIGRATOR_EXTRA_OPTS:-} -i /root/rig-key -d /dev/vda 10.0.2.2:2233 >>/root/migrator-run.log 2>&1; echo \$? > /root/migrator.rc' >/dev/null 2>&1 &
	sleep 2
	echo migration started"

# poll: the rc file is the only completion signal; an unreachable VM is NOT one
for i in $(seq 1 120); do
	RC=$(ssh $SSH_OPTS -p 2255 root@127.0.0.1 "cat /root/migrator.rc 2>/dev/null" 2>/dev/null)
	if [ -n "$RC" ]; then
		echo "[rig] migrator finished with rc=$RC"
		ssh $SSH_OPTS -p 2255 root@127.0.0.1 "tail -25 /root/migrator-run.log" || true
		exit "$([ "$RC" = 0 ] && echo 0 || echo 1)"
	fi
	sleep 15
done
echo "FAIL: migration timed out; logs in $LOGS and recipient /root/migrator-run.log" >&2
exit 1
