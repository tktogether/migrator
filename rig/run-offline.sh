#!/bin/bash
# rig/run-offline.sh — the E2E offline migration run (D6/D8):
#   donor VM     : boots the Live ISO, carries donor-disk.raw as vda
#                  hostfwd 2233->22 (control ssh), 2222->2222 (data sshd)
#   recipient VM : boots the Live ISO, carries target-disk.raw (blank) as vda
#                  hostfwd 2255->22 (we drive reloca.to over it)
# reloca.to runs INSIDE the recipient VM (under tmux), donor = 10.0.2.2:2233
# (slirp gateway loops back to the host's forwarded ports).
set -uo pipefail
OUT=${RIG_OUT:-$HOME/rig}
ISO=$OUT/migrator-live.iso
DONOR_DISK=$OUT/donor-disk.raw
TARGET_DISK=$OUT/target-disk.raw
KEY=$OUT/rig_ed25519
LOGS=$OUT/logs; mkdir -p "$LOGS"
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"

# kill leftovers from a previous run
for pidf in "$OUT"/donor.pid "$OUT"/recipient.pid; do
	[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"
done
sleep 1

[ -s "$ISO" ] || { echo "no ISO at $ISO (rig/build-live.sh)" >&2; exit 1; }
[ -s "$DONOR_DISK" ] || { echo "no donor disk at $DONOR_DISK (rig/build-donor.sh)" >&2; exit 1; }
: > "$TARGET_DISK"; truncate -s 2G "$TARGET_DISK"

echo "[rig] starting donor VM..."
qemu-system-x86_64 -accel tcg,thread=multi -smp 2 -m 1024 \
	-display none -monitor none -serial file:"$LOGS/donor-serial.log" \
	-cdrom "$ISO" -boot order=d \
	-drive file="$DONOR_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2233-:22,hostfwd=tcp:127.0.0.1:2222-:2222 \
	-device virtio-net-pci,netdev=n0 \
	-daemonize -pidfile "$OUT/donor.pid"

echo "[rig] starting recipient VM..."
qemu-system-x86_64 -accel tcg,thread=multi -smp 2 -m 1024 \
	-display none -monitor none -serial file:"$LOGS/recipient-serial.log" \
	-cdrom "$ISO" -boot order=d \
	-drive file="$TARGET_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2255-:22 \
	-device virtio-net-pci,netdev=n0 \
	-daemonize -pidfile "$OUT/recipient.pid"

wait_ssh() { # port label
	local port=$1 label=$2 i
	for i in $(seq 1 90); do
		if ssh $SSH_OPTS -p "$port" root@127.0.0.1 true 2>/dev/null; then
			echo "[rig] $label is up (attempt $i)"; return 0
		fi
		sleep 10
	done
	echo "FAIL: $label did not come up (see $LOGS)" >&2; return 1
}
wait_ssh 2233 donor || exit 1
wait_ssh 2255 recipient || exit 1

echo "[rig] pushing the rig key into the recipient VM and starting the migration under tmux..."
scp $SSH_OPTS -P 2255 "$KEY" root@127.0.0.1:/root/rig-key >/dev/null
ssh $SSH_OPTS -p 2255 root@127.0.0.1 \
	"tmux new-session -d -s mig 'reloca.to -y -i /root/rig-key -d /dev/vda 10.0.2.2:2233 >>/root/reloca-run.log 2>&1' \
	 && echo migration started"

# follow the run until reloca.to exits (the tmux wrapper records the rc)
for i in $(seq 1 240); do
	RC=$(ssh $SSH_OPTS -p 2255 root@127.0.0.1 \
		"tmux list-sessions 2>/dev/null | grep -q '^mig:' || cat /run/reloca.to/tmux.rc 2>/dev/null || echo waiting" 2>/dev/null)
	if [ "$RC" != "waiting" ]; then
		echo "[rig] reloca.to finished with rc=$RC"
		ssh $SSH_OPTS -p 2255 root@127.0.0.1 "tail -25 /root/reloca-run.log" || true
		exit "$([ "$RC" = 0 ] && echo 0 || echo 1)"
	fi
	sleep 15
done
echo "FAIL: migration timed out; logs in $LOGS and recipient /root/reloca-run.log" >&2
exit 1
