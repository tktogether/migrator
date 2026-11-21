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
# LIVE_PROFILE=slim: no qemu, xz squashfs, zram + static-ip support — for 1 GiB
# recipients; full keeps qemu for the E4 boot test (D23).
PROFILE=${LIVE_PROFILE:-full}
BASE_PKGS="systemd-sysv,linux-image-amd64,live-boot,live-config,initramfs-tools,openssh-server,rsync,partclone,xfsprogs,e2fsprogs,dosfstools,mdadm,lvm2,fdisk,parted,gdisk,efibootmgr,grub-common,grub2-common,grub-pc-bin,grub-efi-amd64-bin,lz4,zstd,pv,tmux,iproute2,iputils-ping,netbase,ifupdown,isc-dhcp-client,curl,ca-certificates,nano,less,bsdextrautils"
case $PROFILE in
	slim) PKGS=$BASE_PKGS ;;
	full) PKGS="$BASE_PKGS,qemu-system-x86,qemu-utils" ;;
	*) echo "LIVE_PROFILE=$PROFILE: want slim|full" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
rm -rf "$CH" "$ISODIR"

# rig ssh keypair: generated once, pubkey injected as root's authorized_keys (D10)
KEY=$OUT/rig_ed25519
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C migrator-rig -f "$KEY"

echo "[live] mmdebstrap $SUITE ($PROFILE profile, D7: baked in)..."
mmdebstrap --variant=minbase \
	--include="$PKGS" \
	"$SUITE" "$CH" "$MIRROR"

echo "[live] install the tool + marker + network config..."
SHORT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)
cat > "$CH/etc/migrator-live-release" <<EOF
BUILD_ID=migrator-$SHORT-$(date +%Y%m%d)
CODENAME=$SUITE
MIRROR=$MIRROR
EOF
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > "$CH/etc/network/interfaces"
echo migrator-live > "$CH/etc/hostname"
# zram: half the RAM as zstd compressed swap, so a 1 GiB recipient survives the
# postfix/initramfs peak (D23)
install -d -m0755 "$CH/usr/local/sbin"
cat > "$CH/usr/local/sbin/migrator-zram" <<'ZRAM'
#!/bin/sh
command -v zramctl >/dev/null 2>&1 || exit 0
[ -e /dev/zram0 ] || modprobe zram 2>/dev/null || exit 0
sz=$(awk '/^MemTotal:/ { print int($2 / 2) }' /proc/meminfo)
dev=$(zramctl --find --size "${sz}K" --algorithm zstd 2>/dev/null) || exit 0
mkswap "$dev" >/dev/null 2>&1 || exit 0
swapon -p 100 "$dev" 2>/dev/null || true
ZRAM
cat > "$CH/etc/systemd/system/migrator-zram.service" <<'UNIT'
[Unit]
Description=migrator zram swap (half the RAM, zstd)
After=local-fs.target
Before=swap.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/migrator-zram
[Install]
WantedBy=swap.target
UNIT
printf 'vm.swappiness=100\n' > "$CH/etc/sysctl.d/99-migrator-zram.conf"
# static network for providers that do not run DHCP: migrator.ip=IP/PREFIX,GW,DNS1[,DNS2]
cat > "$CH/usr/local/sbin/migrator-live-net" <<'NET'
#!/bin/sh
spec=
for w in $(cat /proc/cmdline); do case $w in migrator.ip=*) spec=${w#migrator.ip=} ;; esac; done
[ -n "$spec" ] || exit 0
addr=${spec%%,*}; rest=${spec#*,}; gw=${rest%%,*}; dns=${rest#*,}
ip link set eth0 up 2>/dev/null || exit 0
ip addr flush dev eth0 2>/dev/null
ip addr add "$addr" dev eth0 || exit 0
[ -n "$gw" ] && ip route replace default via "$gw" dev eth0
: > /etc/resolv.conf
[ -z "$dns" ] || for d in $(echo "$dns" | tr ',' ' '); do echo "nameserver $d" >> /etc/resolv.conf; done
exit 0
NET
cat > "$CH/etc/systemd/system/migrator-live-net.service" <<'UNIT'
[Unit]
Description=migrator live static network (migrator.ip=)
After=local-fs.target
Before=network.target ssh.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/migrator-live-net
[Install]
WantedBy=multi-user.target
UNIT
chmod 0755 "$CH/usr/local/sbin/migrator-zram" "$CH/usr/local/sbin/migrator-live-net"
install -d "$CH/etc/systemd/system/swap.target.wants" "$CH/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/migrator-zram.service "$CH/etc/systemd/system/swap.target.wants/migrator-zram.service"
ln -sf /etc/systemd/system/migrator-live-net.service "$CH/etc/systemd/system/multi-user.target.wants/migrator-live-net.service"
install -d -m0700 "$CH/root/.ssh"
install -m0600 "$KEY.pub" "$CH/root/.ssh/authorized_keys"
install -d -m0755 "$CH/usr/local/sbin" "$CH/usr/local/lib/migrator"
install -m0755 "$REPO/bin/migrator" "$CH/usr/local/sbin/migrator"
if [ -x "$REPO/agent/migrator-agent" ]; then
	install -m0755 "$REPO/agent/migrator-agent" "$CH/usr/local/sbin/migrator-agent"
else
	echo "WARN: agent/migrator-agent missing (make agent first); on-line mode will lack the agent" >&2
fi
install -m0644 "$REPO"/lib/*.sh "$CH/usr/local/lib/migrator/"
[ -f "$REPO/lib/VERSION" ] && install -m0644 "$REPO/lib/VERSION" "$CH/usr/local/lib/migrator/" || true
install -d -m0755 "$CH/usr/local/share/doc/migrator"
for f in LICENSE LICENSE-UPSTREAM NOTICE TRADEMARK.md; do
	install -m0644 "$REPO/$f" "$CH/usr/local/share/doc/migrator/$f"
done

echo "[live] squashfs ($PROFILE)..."
mkdir -p "$ISODIR/live" "$ISODIR/isolinux"
case $PROFILE in slim) SQ="-comp xz" ;; *) SQ="-comp zstd -Xcompression-level 9" ;; esac
# shellcheck disable=SC2086  # SQ is a deliberate word list
mksquashfs "$CH" "$ISODIR/live/filesystem.squashfs" -noappend -no-progress $SQ > /dev/null

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
APPEND initrd=/live/initrd.img boot=live components toram net.ifnames=0 biosdevname=0 systemd.default_timeout_start_sec=600 console=tty0 console=ttyS0,115200n8
CFG

echo "[live] xorriso..."
xorriso -as mkisofs -quiet -o "$ISO" -J -V MIGRATOR_LIVE \
	-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
	"$ISODIR"
[ -s "$ISO" ] || { echo "FAIL: no ISO" >&2; exit 1; }
echo "OK: $ISO ($(du -h "$ISO" | cut -f1))"
