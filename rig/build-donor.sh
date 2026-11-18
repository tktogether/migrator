#!/bin/bash
# rig/build-donor.sh — build the donor machine's disk: a minimal Debian bookworm
# system (partition table + ext4 root with kernel/initramfs/services/payload).
# D13: mmdebstrap (unprivileged containers cannot mknod, debootstrap fails).
# Pure userspace: mkfs.ext4 -d populates the filesystem, the image is dd'd into
# the partition; no loop mounts. GRUB is NOT installed here — reloca.to's
# postfix installs it on the target from the migrated rootfs.
# Output: $HOME/rig/donor-disk.raw (2 GiB, sparse)
set -euo pipefail
OUT=${RIG_OUT:-$HOME/rig}
MIRROR=http://deb.debian.org/debian
SUITE=bookworm
DISKMIB=2048; PARTMIB=2046
UUID=$(cat /proc/sys/kernel/random/uuid)
ROOT=$OUT/donor-rootfs
FSIMG=$OUT/donor-fs.img
IMG=$OUT/donor-disk.raw

rm -rf "$ROOT" "$FSIMG" "$IMG"

echo "[donor] mmdebstrap $SUITE (minbase + kernel/ssh/payload tools)..."
mmdebstrap --variant=minbase \
	--include="systemd-sysv,linux-image-amd64,initramfs-tools,openssh-server,iproute2,iputils-ping,netbase,ifupdown,isc-dhcp-client,rsync,vim-tiny" \
	"$SUITE" "$ROOT" "$MIRROR"

# configure the guest system (plain file ops + systemctl enable; no /dev needed)
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > "$ROOT/etc/network/interfaces"
mount -t proc proc "$ROOT/proc" 2>/dev/null || mount --bind /proc "$ROOT/proc"
mount --bind /dev "$ROOT/dev" 2>/dev/null || true

chroot "$ROOT" /bin/bash -es <<CHROOT
	echo "root:rigpass" | chpasswd
	echo donor > /etc/hostname
	printf '127.0.0.1\tlocalhost donor\n' > /etc/hosts
	printf 'UUID=%s / ext4 defaults 0 1\n' "$UUID" > /etc/fstab
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
	# grub preferences so postfix's grub2-mkconfig emits a serial console (E4 asserts on it)
	mkdir -p /etc/default
	printf 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 console=ttyS0,115200n8 console=tty0"\nGRUB_DISABLE_OS_PROBER=true\n' > /etc/default/grub
CHROOT
: > "$ROOT/etc/machine-id"
umount "$ROOT/proc" "$ROOT/dev" 2>/dev/null || true

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
