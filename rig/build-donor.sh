#!/bin/bash
# rig/build-donor.sh — build the donor machine's disk: a minimal Debian bookworm
# system (partition table + ext4 root with kernel/initramfs/services/payload).
# D13: mmdebstrap (unprivileged containers cannot mknod, debootstrap fails).
# Where mmdebstrap is missing but we have real root (a VM, not a container)
# debootstrap does the same job; the two backends produce the same minbase tree.
# Pure userspace: mkfs.ext4 -d populates the filesystem, the image is dd'd into
# the partition; no loop mounts. GRUB is NOT *installed to a disk* here — that
# is postfix's job on the recipient — but the donor must still SHIP the
# bootloader: postfix runs grub-install from inside the migrated tree, so a
# donor without grub-pc-bin fails at the very last step with "grub-install: No
# such file or directory". grub-pc (the metapackage) is deliberately absent: its
# postinst wants a target device and hangs/aborts in a chroot.
# Output: $HOME/rig/donor-disk.raw (2 GiB, sparse)
set -euo pipefail
OUT=${RIG_OUT:-$HOME/rig}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-bookworm}
INC="systemd-sysv,linux-image-amd64,initramfs-tools,openssh-server,iproute2,iputils-ping,netbase,ifupdown,isc-dhcp-client,rsync,vim-tiny,grub-pc-bin,grub2-common"
# grub2-common is the one that ships /usr/sbin/grub-install; grub-pc-bin only
# brings the i386-pc platform modules and pulls grub-common. Listing both is
# what makes "postfix runs grub-install inside the migrated tree" possible.
# DBCACHE keeps the .deb set between runs: the same ~165 packages every time,
# and a warm cache turns a 20-minute bootstrap into a couple of minutes.
DBCACHE=${DBCACHE:-}
CACHEOPT=""
if [ -n "$DBCACHE" ]; then
	mkdir -p "$DBCACHE"
	CACHEOPT="--cache-dir=$DBCACHE"
fi
DISKMIB=2048; PARTMIB=2046
UUID=$(cat /proc/sys/kernel/random/uuid)
ROOT=$OUT/donor-rootfs
FSIMG=$OUT/donor-fs.img
IMG=$OUT/donor-disk.raw

rm -rf "$ROOT" "$FSIMG" "$IMG"

echo "[donor] bootstrap $SUITE (minbase + kernel/ssh/payload tools)..."
if command -v mmdebstrap >/dev/null 2>&1; then
	mmdebstrap --variant=minbase --include="$INC" "$SUITE" "$ROOT" "$MIRROR"
else
	# no mmdebstrap: fine with real root and mknod rights, which a container
	# does not have (D13). Older debootstrap releases ship no bookworm script;
	# sid's is the same suite logic — rig/build-live-debootstrap.sh does the
	# same dance for the Live.
	[ "$(id -u)" = 0 ] || { echo "no mmdebstrap and not root: bootstrap the donor on a VM, not in a container" >&2; exit 2; }
	command -v debootstrap >/dev/null 2>&1 || { echo "neither mmdebstrap nor debootstrap installed" >&2; exit 2; }
	[ -e "/usr/share/debootstrap/scripts/$SUITE" ] || ln -sfn sid "/usr/share/debootstrap/scripts/$SUITE"
	debootstrap --variant=minbase --no-check-gpg $CACHEOPT --include="$INC" "$SUITE" "$ROOT" "$MIRROR"
fi

# a donor without grub looks fine for 30 minutes and fails at postfix's last
# step; assert it here where the fix is one word in INC
for g in usr/sbin/grub-install usr/lib/grub/i386-pc; do
	[ -e "$ROOT/$g" ] || { echo "[donor] FATAL: $g missing from the bootstrap (grub-pc-bin in INC?)" >&2; exit 3; }
done

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
