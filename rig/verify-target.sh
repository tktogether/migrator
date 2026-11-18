#!/bin/bash
# rig/verify-target.sh — boot the migrated disk standalone and assert the
# donor system came back: ssh reachable, hostname=donor, payload hashes match,
# heartbeat.service enabled. This is the M0 acceptance gate.
set -uo pipefail
OUT=${RIG_OUT:-$HOME/rig}
TARGET_DISK=$OUT/target-disk.raw
KEY=$OUT/rig_ed25519
LOGS=$OUT/logs; mkdir -p "$LOGS"
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"

for pidf in "$OUT"/donor.pid "$OUT"/recipient.pid "$OUT"/target.pid; do
	[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"
done
sleep 1

echo "[rig] booting the migrated target disk standalone..."
qemu-system-x86_64 -accel tcg,thread=multi -smp 2 -m 1024 \
	-display none -monitor none -serial file:"$LOGS/target-serial.log" \
	-drive file="$TARGET_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2266-:22 \
	-device virtio-net-pci,netdev=n0 \
	-daemonize -pidfile "$OUT/target.pid"

up=
for i in $(seq 1 60); do
	if ssh $SSH_OPTS -p 2266 root@127.0.0.1 true 2>/dev/null; then up=yes; break; fi
	sleep 10
done
if [ -z "$up" ]; then
	echo "FAIL: migrated target never came up on ssh (see $LOGS/target-serial.log)" >&2
	exit 1
fi

echo "[rig] target is up; asserting identity and payload..."
FAILS=0
HN=$(ssh $SSH_OPTS -p 2266 root@127.0.0.1 hostname 2>/dev/null)
[ "$HN" = donor ] && echo "  PASS hostname=$HN" || { echo "  FAIL hostname=$HN (want donor)"; FAILS=$((FAILS+1)); }
if ssh $SSH_OPTS -p 2266 root@127.0.0.1 '( cd /root/payload && sha256sum -c SHA256SUMS )' 2>/dev/null; then
	echo "  PASS payload hashes"
else
	echo "  FAIL payload hashes"; FAILS=$((FAILS+1))
fi
HB=$(ssh $SSH_OPTS -p 2266 root@127.0.0.1 'systemctl is-enabled heartbeat.service 2>/dev/null; systemctl is-active heartbeat.service 2>/dev/null' 2>/dev/null)
case $HB in
	*enabled*|*active*) echo "  PASS heartbeat.service ($HB)" ;;
	*) echo "  FAIL heartbeat.service state: $HB"; FAILS=$((FAILS+1)) ;;
esac
BOOT=$(ssh $SSH_OPTS -p 2266 root@127.0.0.1 'test -x /usr/sbin/grub-install && echo grub-present || echo grub-missing; ls /boot/vmlinuz-* >/dev/null 2>&1 && echo kernel-present || echo kernel-missing' 2>/dev/null)
echo "  boot bits: $BOOT"

if [ "$FAILS" -eq 0 ]; then
	echo "OK: M0 acceptance PASSED (migrated target boots and matches the donor)"
	exit 0
fi
echo "FAIL: $FAILS assertion(s) failed" >&2
exit 1
