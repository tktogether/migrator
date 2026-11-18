#!/bin/bash
# rig/build-live.sh — build the migrator rescue Live ISO (D4/D7; D12: no live-build;
# D13: mmdebstrap instead of debootstrap — unprivileged containers cannot mknod).
# debootstrap-equivalent chroot (mmdebstrap) + live-boot initramfs + squashfs +
# xorriso (BIOS). Produces $HOME/rig/migrator-live.iso.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${RIG_OUT:-$HOME/rig}
SUITE=bookworm
MIRROR=http://deb.debian.org/debian
CH=$OUT/live-rootfs
ISODIR=$OUT/live-iso
ISO=$OUT/migrator-live.iso

mkdir -p "$OUT"
rm -rf "$CH" "$ISODIR"

# rig ssh keypair: generated once, pubkey injected as root's authorized_keys (D10)
KEY=$OUT/rig_ed25519
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C migrator-rig -f "$KEY"

echo "[live] mmdebstrap $SUITE (minbase + full toolset, D7: baked in)..."
mmdebstrap --variant=minbase \
	--include="systemd-sysv,linux-image-amd64,live-boot,live-config,initramfs-tools,openssh-server,rsync,partclone,xfsprogs,e2fsprogs,dosfstools,mdadm,lvm2,fdisk,parted,gdisk,efibootmgr,grub-common,grub2-common,grub-pc-bin,grub-efi-amd64-bin,lz4,zstd,pv,tmux,qemu-system-x86,qemu-utils,iproute2,iputils-ping,netbase,ifupdown,isc-dhcp-client,curl,ca-certificates,nano,less,bsdextrautils" \
	"$SUITE" "$CH" "$MIRROR"

echo "[live] install the tool + marker + network config..."
SHORT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)
cat > "$CH/etc/reloca-live-release" <<EOF
BUILD_ID=migrator-$SHORT-$(date +%Y%m%d)
CODENAME=$SUITE
MIRROR=$MIRROR
EOF
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > "$CH/etc/network/interfaces"
echo migrator-live > "$CH/etc/hostname"
install -d -m0700 "$CH/root/.ssh"
install -m0600 "$KEY.pub" "$CH/root/.ssh/authorized_keys"
install -d -m0755 "$CH/usr/local/sbin" "$CH/usr/local/lib/reloca.to"
install -m0755 "$REPO/bin/reloca.to" "$CH/usr/local/sbin/reloca.to"
if [ -x "$REPO/agent/reloca-agent" ]; then
	install -m0755 "$REPO/agent/reloca-agent" "$CH/usr/local/sbin/reloca-agent"
else
	echo "WARN: agent/reloca-agent missing (make agent first); on-line mode will lack the agent" >&2
fi
install -m0644 "$REPO"/lib/*.sh "$CH/usr/local/lib/reloca.to/"
[ -f "$REPO/lib/VERSION" ] && install -m0644 "$REPO/lib/VERSION" "$CH/usr/local/lib/reloca.to/" || true

echo "[live] squashfs..."
mkdir -p "$ISODIR/live" "$ISODIR/isolinux"
mksquashfs "$CH" "$ISODIR/live/filesystem.squashfs" -noappend -no-progress -comp zstd -Xcompression-level 9 > /dev/null

KVER=$(basename "$(ls "$CH"/boot/vmlinuz-* | head -1)"); KVER=${KVER#vmlinuz-}
echo "[live] kernel $KVER"
cp "$CH/boot/vmlinuz-$KVER" "$ISODIR/live/vmlinuz"
cp "$CH/boot/initrd.img-$KVER" "$ISODIR/live/initrd.img"
cp /usr/lib/ISOLINUX/isolinux.bin "$ISODIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISODIR/isolinux/"
cat > "$ISODIR/isolinux/isolinux.cfg" <<'CFG'
DEFAULT linux
TIMEOUT 20
LABEL linux
KERNEL /live/vmlinuz
APPEND initrd=/live/initrd.img boot=live components net.ifnames=0 biosdevname=0 systemd.default_timeout_start_sec=600 console=tty0 console=ttyS0,115200n8
CFG

echo "[live] xorriso..."
xorriso -as mkisofs -quiet -o "$ISO" -J -V MIGRATOR_LIVE \
	-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
	"$ISODIR"
[ -s "$ISO" ] || { echo "FAIL: no ISO" >&2; exit 1; }
echo "OK: $ISO ($(du -h "$ISO" | cut -f1))"
