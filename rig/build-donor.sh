#!/bin/bash
# rig/build-donor.sh — build the donor machine's disk: a minimal Debian bookworm
# system (partition table + ext4 root with kernel/initramfs/services/payload).
# Pure userspace on the build host: mkfs.ext4 -d populates the filesystem, the
# image is dd'd into the partition; no loop mounts. GRUB is NOT installed here —
# reloca.to's postfix installs it on the target from the migrated rootfs.
# Output: $HOME/rig/donor-disk.raw (2 GiB, sparse)
set -euo pipefail
OUT=${RIG_OUT:-$HOME/rig}
MIRROR=http://deb.debian.org/debian
SUITE=bookworm
DISKMIB=2048; PARTMIB=2046
UUID=$(uuidgen || python3 -c 'import uuid; print(uuid.uuid4())')
ROOT=$OUT/donor-rootfs
FSIMG=$OUT/donor-fs.img
IMG=$OUT/donor-disk.raw

rm -rf "$ROOT" "$FSIMG" "$IMG"

echo "[donor] debootstrap $SUITE (minbase + kernel/ssh)..."
debootstrap --variant=minbase \
	--include="systemd-sysv,linux-image-amd64,initramfs-tools,openssh-server,iproute2,iputils-ping,netbase,rsync,vim-tiny" \
	"$SUITE" "$ROOT" "$MIRROR"

# stop services starting inside the chroot; then configure the guest system
echo exit 101 > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"
mount -t proc proc "$ROOT/proc" 2>/dev/null || mount --bind /proc "$ROOT/proc"
mount --bind /sys "$ROOT/sys" 2>/dev/null || true
mount --bind /dev "$ROOT/dev" 2>/dev/null || true
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

chroot "$ROOT" /bin/bash -es <<CHROOT
	echo "root:rigpass" | chpasswd
	hostname donor
	echo donor > /etc/hostname
	printf '127.0.0.1\tlocalhost donor\n' > /etc/hosts
	install -d -m0700 /root/.ssh
	cat > /root/.ssh/authorized_keys <<'KEYS'
$(cat "$OUT/rig_ed25519.pub")
KEYS
	install -d -m0700 /root/payload
	dd if=/dev/urandom of=/root/payload/data.bin bs=1M count=8 status=none
	( cd /root/payload && sha256sum data.bin > SHA256SUMS )
	install -m0755 /dev/null /usr/local/bin/heartbeat.sh
	printf '#!/bin/sh\ndate -Ins >> /var/log/heartbeat.log\n' > /usr/local/bin/heartbeat.sh
	cat > /etc/systemd/system/heartbeat.service <<'UNIT'
[Unit]
Description=migrator rig heartbeat
[Service]
Type=oneshot
ExecStart=/usr/local/bin/heartbeat.sh
[Install]
WantedBy=multi-user.target
UNIT
	systemctl enable ssh heartbeat.service 2>/dev/null || true
	systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
CHROOT
# network: DHCP via dhcpd-style config for common setups (recipient/donor NIC is virtio/eth0)
rm -f "$ROOT/etc/network/interfaces.d/"* 2>/dev/null || true
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > "$ROOT/etc/network/interfaces"
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/usr/sbin/policy-rc.d"
umount "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" 2>/dev/null || true

echo "[donor] mkfs.ext4 -d -> fs image ($PARTMIB MiB)..."
truncate -s "$PARTMIB"M "$FSIMG"
mkfs.ext4 -F -q -U "$UUID" -L donor-root -d "$ROOT" "$FSIMG"

echo "[donor] partition table + embed fs into disk image (${DISKMIB} MiB)..."
truncate -s "$DISKMIB"M "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
unit: sectors
start=2048, size=$((PARTMIB * 2048)), type=83, bootable
EOF
dd if="$FSIMG" of="$IMG" bs=1M seek=1 conv=notrunc status=none
rm -f "$FSIMG"
rm -rf "$ROOT"
echo "OK: $IMG (rootfs UUID $UUID)"
