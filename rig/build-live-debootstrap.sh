#!/bin/bash
# build-live-debootstrap.sh — build the migration Live on a Debian/Ubuntu host
# that has no mmdebstrap (Ubuntu 20.04's apt does not carry 0.8+, which
# rig/build-live.sh needs). This is the debootstrap transcription of the
# script that built the ISOs used from D27 on; only the paths became
# variables, so a build can live on a separate filesystem from / (a 30 GiB
# root with 20 GiB on /data, for instance).
#
#   BUILD_DIR=/data/live-build TARBALL=/root/head.tar.gz bash rig/build-live-debootstrap.sh
#
# env:
#   BUILD_DIR  scratch and output directory (default /root); needs ~6 GiB
#   TARBALL    snapshot of the source tree, `git archive HEAD` (default
#              $BUILD_DIR/migrator2.tar.gz — the name the D27-D31 builds used)
#   REPO       where TARBALL is unpacked (default $BUILD_DIR/migrator)
#   PROFILE    slim (default: no qemu, xz squashfs) | full (qemu, zstd)
#   MIRROR     Debian mirror (default Tsinghua; the bookworm d-i needs one
#              reachable from the build host)
#   KEY        ssh key pair baked into the Live as /root/rig-key (default
#              $BUILD_DIR/rig_ed25519; its .pub goes to authorized_keys)
#
# What comes out, in BUILD_DIR:
#   migrator-live.iso     bootable BIOS ISO (isolinux, `toram` = whole ISO in RAM)
#   vmlinuz-live          the kernel, for tools/live-entry.sh
#   initrd-live.img       the initrd, for tools/live-entry.sh
#   live/live/filesystem.squashfs   the same squashfs the ISO carries
#
# The Live carries: reloca.to + libs + the static agent, zram swap sized to
# half the RAM (D23), a static-network unit driven by reloca.ip= on the boot
# line (no DHCP bet), virtio/squashfs/overlay in the initramfs, and
# /etc/reloca-live-release (E1: our own marker instead of XServer's).
set -ex
export DEBIAN_FRONTEND=noninteractive

PROFILE=${PROFILE:-${LIVE_PROFILE:-slim}}
BUILD_DIR=${BUILD_DIR:-/root}
TARBALL=${TARBALL:-$BUILD_DIR/migrator2.tar.gz}
REPO=${REPO:-$BUILD_DIR/migrator}
MIRROR=${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/debian}
KEY=${KEY:-$BUILD_DIR/rig_ed25519}
CH=$BUILD_DIR/live-rootfs
OUT=$BUILD_DIR/live

BASE_PKGS="systemd-sysv,linux-image-amd64,live-boot,live-config,initramfs-tools,openssh-server,rsync,partclone,xfsprogs,e2fsprogs,dosfstools,mdadm,lvm2,fdisk,parted,gdisk,efibootmgr,grub-common,grub2-common,grub-pc-bin,grub-efi-amd64-bin,lz4,zstd,pv,tmux,iproute2,iputils-ping,netbase,ifupdown,isc-dhcp-client,curl,ca-certificates,nano,less,bsdextrautils"
case $PROFILE in
	slim) PKGS=$BASE_PKGS ;;
	full) PKGS="$BASE_PKGS,qemu-system-x86,qemu-utils" ;;
	*) echo "PROFILE=$PROFILE: want slim|full" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }
[ -f "$TARBALL" ] || { echo "$TARBALL: no such snapshot (git archive HEAD > $TARBALL)" >&2; exit 2; }
[ -f "$KEY" ] && [ -f "$KEY.pub" ] || { echo "$KEY(.pub): the Live needs a key pair to bake in" >&2; exit 2; }
mkdir -p "$BUILD_DIR"

apt-get install -y -qq debootstrap squashfs-tools xorriso isolinux syslinux-common \
	gcc make libzstd-dev rsync

rm -rf "$REPO" && mkdir -p "$REPO"
tar -xzf "$TARBALL" -C "$REPO"
cd "$REPO"
make -C agent VERSION=dev

rm -rf "$CH" "$OUT" "$BUILD_DIR/migrator-live.iso"
# debootstrap on bionic has no bookworm script; sid's is the same suite logic
[ -e /usr/share/debootstrap/scripts/bookworm ] || ln -sfn sid /usr/share/debootstrap/scripts/bookworm
debootstrap --variant=minbase --no-check-gpg --include="$PKGS" \
	bookworm "$CH" "$MIRROR"

install -d -m700 "$CH/root/.ssh"
install -m600 "$KEY" "$CH/root/rig-key"
install -m600 "$KEY.pub" "$CH/root/.ssh/authorized_keys"
cat > "$CH/etc/network/interfaces" <<'IF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IF
printf 'nameserver 192.168.8.1\nnameserver 114.114.114.114\n' > "$CH/etc/resolv.conf"
echo migrator-live > "$CH/etc/hostname"
cat > "$CH/etc/reloca-live-release" <<REL
BUILD_ID=migrator-dev-$PROFILE-$(date +%Y%m%d)
CODENAME=bookworm
MIRROR=$MIRROR
REL

install -D -m0755 bin/reloca.to "$CH/usr/local/sbin/reloca.to"
sed -i 's/\r$//' "$CH/usr/local/sbin/reloca.to"
install -d -m0755 "$CH/usr/local/lib/reloca.to"
install -m0644 lib/*.sh "$CH/usr/local/lib/reloca.to/"
sed -i 's/\r$//' "$CH/usr/local/lib/reloca.to/"*.sh
install -m0755 agent/reloca-agent "$CH/usr/local/sbin/reloca-agent"
[ -f lib/VERSION ] && install -m0644 lib/VERSION "$CH/usr/local/lib/reloca.to/VERSION"

# zram: half the RAM as zstd swap, so a 1 GiB recipient can still run (D23)
cat > "$CH/usr/local/sbin/reloca-zram" <<'ZRAM'
#!/bin/sh
command -v zramctl >/dev/null 2>&1 || exit 0
[ -e /dev/zram0 ] || modprobe zram 2>/dev/null || exit 0
sz=$(awk '/^MemTotal:/ { print int($2 / 2) }' /proc/meminfo)
dev=$(zramctl --find --size "${sz}K" --algorithm zstd 2>/dev/null) || exit 0
mkswap "$dev" >/dev/null 2>&1 || exit 0
swapon -p 100 "$dev" 2>/dev/null || true
ZRAM
cat > "$CH/etc/systemd/system/reloca-zram.service" <<'UNIT'
[Unit]
Description=reloca zram swap (half the RAM, zstd)
After=local-fs.target
Before=swap.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/reloca-zram
[Install]
WantedBy=swap.target
UNIT
printf 'vm.swappiness=100\n' > "$CH/etc/sysctl.d/99-reloca-zram.conf"

# static network from the boot line: reloca.ip=IP/PREFIX,GW,DNS1[,DNS2]
cat > "$CH/usr/local/sbin/reloca-live-net" <<'NET'
#!/bin/sh
spec=
for w in $(cat /proc/cmdline); do case $w in reloca.ip=*) spec=${w#reloca.ip=} ;; esac; done
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
cat > "$CH/etc/systemd/system/reloca-live-net.service" <<'UNIT'
[Unit]
Description=reloca live static network (reloca.ip=)
After=local-fs.target
Before=network.target ssh.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/reloca-live-net
[Install]
WantedBy=multi-user.target
UNIT
chmod 0755 "$CH/usr/local/sbin/reloca-zram" "$CH/usr/local/sbin/reloca-live-net"
install -d "$CH/etc/systemd/system/swap.target.wants" "$CH/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/reloca-zram.service "$CH/etc/systemd/system/swap.target.wants/reloca-zram.service"
ln -sf /etc/systemd/system/reloca-live-net.service "$CH/etc/systemd/system/multi-user.target.wants/reloca-live-net.service"

# the Live is often the first thing a virtio/NVMe host has to boot from
grep -q '^squashfs' "$CH/etc/initramfs-tools/modules" 2>/dev/null || cat >> "$CH/etc/initramfs-tools/modules" <<'MOD'
virtio_pci
virtio_net
virtio_blk
virtio_scsi
ext4
squashfs
loop
isofs
overlay
MOD

mount --bind /proc "$CH/proc"
mount --bind /sys "$CH/sys"
mount --bind /dev "$CH/dev"
mount --bind /dev/pts "$CH/dev/pts"
chroot "$CH" update-initramfs -u -k all
chroot "$CH" ssh-keygen -A || true
umount "$CH/dev/pts" "$CH/dev" "$CH/sys" "$CH/proc"

K=$(ls "$CH"/boot/vmlinuz-* | sort -V | tail -1)
I=$(ls "$CH"/boot/initrd.img-* | sort -V | tail -1)
mkdir -p "$OUT/live" "$OUT/isolinux"
cp "$K" "$OUT/live/vmlinuz"
cp "$I" "$OUT/live/initrd.img"
case $PROFILE in slim) SQ="-comp xz" ;; *) SQ="-comp zstd -Xcompression-level 9" ;; esac
mksquashfs "$CH" "$OUT/live/filesystem.squashfs" -noappend -no-progress $SQ

cp /usr/lib/ISOLINUX/isolinux.bin "$OUT/isolinux/" 2>/dev/null || \
	cp /usr/lib/syslinux/isolinux.bin "$OUT/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$OUT/isolinux/"
cat > "$OUT/isolinux/isolinux.cfg" <<'CFG'
DEFAULT linux
LABEL linux
KERNEL /live/vmlinuz
APPEND initrd=/live/initrd.img boot=live components toram net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
CFG
# `toram` on an ISO copies the whole image into RAM and releases the medium,
# which is what makes the target disk wipeable; on a partition medium it is
# the wrong tool (D25 — tools/live-entry.sh uses toram=filesystem.squashfs)
xorriso -as mkisofs -quiet -o "$BUILD_DIR/migrator-live.iso" -J -V MIGRATOR_LIVE \
	-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot \
	-boot-load-size 4 -boot-info-table "$OUT"

cp "$OUT/live/vmlinuz" "$BUILD_DIR/vmlinuz-live"
cp "$OUT/live/initrd.img" "$BUILD_DIR/initrd-live.img"
ls -lh "$BUILD_DIR/migrator-live.iso" "$BUILD_DIR/vmlinuz-live" "$BUILD_DIR/initrd-live.img"
echo LIVE_BUILD_OK
