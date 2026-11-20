#!/bin/bash
# rig/run-online.sh — the on-line E2E run, all on one host:
#   donor VM     : its OWN installed disk (donor-disk.raw via a qcow2 overlay, so
#                  the base image is never written), direct kernel boot, 768M
#   recipient VM : the Live ISO, a blank 20G target disk, 1024M
# Why direct kernel boot: build-donor.sh deliberately does not install GRUB (on a
# real migration postfix does that on the TARGET). The donor disk is a real
# installed system in every other respect, so -kernel/-initrd get it running
# without inventing a bootloader for it.
# Why an overlay: the on-line run freezes the donor and this script ends by
# killing it, which leaves the base image dirty; the overlay means every run
# starts from the same clean donor.
# The cutover is the rig's job here too (cutover=none): a frozen donor that in
# the rig has no way of reaching the recipient (two separate user-mode networks)
# cannot be handed a thaw command, and the rig can do the physical part better --
# kill both VMs and boot the target on its own.
set -uo pipefail
OUT=${RIG_OUT:-$HOME/rig}
ISO=$OUT/migrator-live.iso
DONOR_BASE=$OUT/donor-disk.raw
DONOR_RUN=$OUT/donor-run.qcow2
TARGET_DISK=$OUT/target-disk.raw
KEY=$OUT/rig_ed25519
LOGS=$OUT/logs; mkdir -p "$LOGS"
exec 9>"$OUT/.run-online.lock"; flock -n 9 || { echo "another run-online.sh is already active" >&2; exit 1; }
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
ACCEL=${ACCEL:-tcg}
DONOR_MEM=${DONOR_MEM:-768}
RECIP_MEM=${RECIP_MEM:-1024}
TARGET_MEM=${TARGET_MEM:-768}
[ "$ACCEL" = tcg ] && ACCEL="tcg,thread=multi,tb-size=128"

for pidf in "$OUT"/donor.pid "$OUT"/recipient.pid "$OUT"/target.pid; do
	[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"
done
sleep 1

[ -s "$ISO" ] || { echo "no ISO at $ISO (rig/build-live-debootstrap.sh)" >&2; exit 1; }
[ -s "$DONOR_BASE" ] || { echo "no donor disk at $DONOR_BASE (rig/build-donor.sh)" >&2; exit 1; }

# --- the donor's kernel/initrd and its root UUID, read out of the base image --
if [ ! -s "$OUT/donor-vmlinuz" ] || [ ! -s "$OUT/donor-initrd" ] || [ ! -s "$OUT/donor-cmdline" ]; then
	echo "[rig] reading kernel/initrd out of $DONOR_BASE (once)..."
	LOOP=$(losetup -f --show -o 1048576 "$DONOR_BASE") || exit 1
	mkdir -p /mnt/donorboot
	mount -o ro "$LOOP" /mnt/donorboot || { losetup -d "$LOOP"; exit 1; }
	cp -f "$(ls /mnt/donorboot/boot/vmlinuz-* | tail -1)" "$OUT/donor-vmlinuz"
	cp -f "$(ls /mnt/donorboot/boot/initrd.img-* | tail -1)" "$OUT/donor-initrd"
	UUID=$(blkid -o value -s UUID "$LOOP" 2>/dev/null)
	KREL=$(basename "$(ls /mnt/donorboot/boot/vmlinuz-* | tail -1)" | sed 's/^vmlinuz-//')
	umount /mnt/donorboot; rmdir /mnt/donorboot 2>/dev/null; losetup -d "$LOOP"
	[ -n "$UUID" ] || { echo "cannot read the donor root UUID" >&2; exit 1; }
	printf 'root=UUID=%s ro net.ifnames=0 biosdevname=0 console=ttyS0 console=tty0 systemd.default_timeout_start_sec=600' "$UUID" > "$OUT/donor-cmdline"
	echo "[rig] donor kernel $KREL, root UUID $UUID"
fi

# --- fresh overlay: the run must not touch the base image --------------------
rm -f "$DONOR_RUN"
qemu-img create -q -f qcow2 -b "$DONOR_BASE" -F raw "$DONOR_RUN" || exit 1
: > "$TARGET_DISK"; truncate -s 20G "$TARGET_DISK"

echo "[rig] starting the donor VM (its own installed system)..."
qemu-system-x86_64 -accel "$ACCEL" -smp 2 -m "$DONOR_MEM" \
	-display none -monitor none -serial file:"$LOGS/donor-serial.log" \
	-kernel "$OUT/donor-vmlinuz" -initrd "$OUT/donor-initrd" \
	-append "$(cat "$OUT/donor-cmdline")" \
	-drive file="$DONOR_RUN",if=virtio,format=qcow2 \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2233-:22 \
	-device virtio-net-pci,netdev=n0,mac=52:54:00:aa:00:22 \
	-smbios type=1,serial=RIG-DONOR-0001 \
	-daemonize -pidfile "$OUT/donor.pid" || exit 1

echo "[rig] starting the recipient VM (Live)..."
qemu-system-x86_64 -accel "$ACCEL" -smp 2 -m "$RECIP_MEM" \
	-display none -monitor none -serial file:"$LOGS/recipient-serial.log" \
	-cdrom "$ISO" -boot order=d \
	-drive file="$TARGET_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2255-:22 \
	-device virtio-net-pci,netdev=n0,mac=52:54:00:aa:00:33 \
	-smbios type=1,serial=RIG-RECIP-0002 \
	-daemonize -pidfile "$OUT/recipient.pid" || exit 1

wait_ssh() { # port label tries
	local port=$1 label=$2 tries=$3 i
	for i in $(seq 1 "$tries"); do
		if ssh $SSH_OPTS -p "$port" root@127.0.0.1 true 2>/dev/null; then
			echo "[rig] $label is up (attempt $i)"; return 0
		fi
		sleep 10
	done
	echo "FAIL: $label did not come up (see $LOGS)" >&2; return 1
}
wait_ssh 2233 donor 30 || { tail -25 "$LOGS/donor-serial.log"; exit 1; }
wait_ssh 2255 recipient 60 || { tail -25 "$LOGS/recipient-serial.log"; exit 1; }

# a donor that writes nothing makes every on-line pass a no-op: give it a load
echo "[rig] starting a write load on the donor (so the passes have something to converge on)"
ssh $SSH_OPTS -p 2233 root@127.0.0.1 \
	"mkdir -p /var/tmp/load; setsid nohup sh -c 'while :; do dd if=/dev/urandom of=/var/tmp/load/blob bs=1M count=8 conv=fsync 2>/dev/null; sleep 2; done' >/dev/null 2>&1 </dev/null & echo load started"

echo "[rig] pushing the rig key into the recipient VM and starting the migration detached..."
scp $SSH_OPTS -P 2255 "$KEY" root@127.0.0.1:/root/rig-key >/dev/null
ssh $SSH_OPTS -p 2255 root@127.0.0.1 "
	rm -f /root/migrator.rc /root/migrator-run.log
	setsid nohup sh -c 'migrator -y ${MIGRATOR_EXTRA_OPTS:-} -o mode=online -o cutover=none -i /root/rig-key -d /dev/vda 10.0.2.2:2233 >>/root/migrator-run.log 2>&1; echo \$? > /root/migrator.rc' >/dev/null 2>&1 &
	sleep 2
	echo migration started"

RC=
for i in $(seq 1 160); do
	RC=$(ssh $SSH_OPTS -p 2255 root@127.0.0.1 "cat /root/migrator.rc 2>/dev/null" 2>/dev/null)
	[ -z "$RC" ] || break
	sleep 15
done
if [ -z "$RC" ]; then
	echo "FAIL: the on-line run timed out; logs in $LOGS" >&2
	scp $SSH_OPTS -P 2255 root@127.0.0.1:/root/migrator-run.log "$LOGS/recipient-migrator.log" >/dev/null 2>&1 || true
	exit 1
fi
echo "[rig] migrator finished with rc=$RC"
scp $SSH_OPTS -P 2255 root@127.0.0.1:/root/migrator-run.log "$LOGS/recipient-migrator.log" >/dev/null 2>&1 \
	&& echo "[rig] full log: $LOGS/recipient-migrator.log" || true
ssh $SSH_OPTS -p 2255 root@127.0.0.1 "tail -25 /root/migrator-run.log" || true
[ "$RC" = 0 ] || exit 1

# --- the rig's own cutover: the frozen donor goes away, the target boots ------
echo "[rig] stopping both VMs (the donor is frozen; killing it is the rig's thaw)"
for pidf in "$OUT"/donor.pid "$OUT"/recipient.pid; do
	[ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"
done
sleep 3

echo "[rig] booting the migrated disk on its own..."
rm -f "$LOGS/target-serial.log" "$OUT/target.pid"
qemu-system-x86_64 -accel "$ACCEL" -smp 2 -m "$TARGET_MEM" \
	-display none -monitor none -serial file:"$LOGS/target-serial.log" \
	-drive file="$TARGET_DISK",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2277-:22 \
	-device virtio-net-pci,netdev=n0,mac=52:54:00:aa:00:33 \
	-smbios type=1,serial=RIG-RECIP-0002 \
	-daemonize -pidfile "$OUT/target.pid"

booted=
for i in $(seq 1 40); do
	if ssh $SSH_OPTS -p 2277 root@127.0.0.1 true 2>/dev/null; then booted=$i; break; fi
	sleep 5
done
if [ -z "$booted" ]; then
	echo "FAIL: the migrated disk did not come up (see $LOGS/target-serial.log)" >&2
	tail -25 "$LOGS/target-serial.log" >&2 || true
	exit 1
fi
say_target() { ssh $SSH_OPTS -p 2277 root@127.0.0.1 "$@" 2>/dev/null; }
echo "[rig] target booted, ssh up after ~$((booted * 5))s"
echo "---- migrated system ----"
say_target 'echo "hostname : $(hostname)"'
say_target 'echo "os       : $(grep PRETTY /etc/os-release | cut -d= -f2- | tr -d \")"'
say_target 'echo "kernel   : $(uname -r)"'
say_target 'echo "systemd  : $(systemctl is-system-running 2>&1), failed units: $(systemctl --failed --no-legend --no-pager | wc -l)"'
say_target 'echo "root     : $(findmnt -n -o SOURCE,FSTYPE,SIZE,USED /)"'
say_target 'echo "firmware : $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS)"'
say_target 'echo "migrated : $(head -1 /etc/migrator-migrated 2>/dev/null)"'
say_target 'echo "load data: $(ls -l /var/tmp/load/blob 2>/dev/null | awk "{print \$5}")"'
echo "RIG_OK"
