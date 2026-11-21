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
#   MK_OPTS    extra mksquashfs flags (default empty). On a build host that
#              shares RAM with other guests, `-processors 1 -mem 700M` keeps
#              xz from ballooning: the compressor is the one step whose RSS
#              the host OOM killer notices, and a dead guest leaves no log.
#   KEY        ssh key pair baked into the Live as /root/rig-key (default
#              $BUILD_DIR/rig_ed25519; its .pub goes to authorized_keys)
#
# What comes out, in BUILD_DIR:
#   migrator-live.iso     bootable BIOS ISO (isolinux, `toram` = whole ISO in RAM)
#   vmlinuz-live          the kernel, for tools/live-entry.sh
#   initrd-live.img       the initrd, for tools/live-entry.sh
#   live/live/filesystem.squashfs   the same squashfs the ISO carries
#
# The Live carries: migrator + libs + the static agent, zram swap sized to
# half the RAM (D23), a static-network unit driven by migrator.ip= on the boot
# line (no DHCP bet), virtio/squashfs/overlay in the initramfs, and
# /etc/migrator-live-release (E1: our own marker instead of XServer's).
set -ex
export DEBIAN_FRONTEND=noninteractive

PROFILE=${PROFILE:-${LIVE_PROFILE:-slim}}
BUILD_DIR=${BUILD_DIR:-/root}
TARBALL=${TARBALL:-$BUILD_DIR/migrator2.tar.gz}
REPO=${REPO:-$BUILD_DIR/migrator}
MIRROR=${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/debian}
KEY=${KEY:-$BUILD_DIR/rig_ed25519}
MK_OPTS=${MK_OPTS:-}
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
# 登录方式（D66），与 rig/build-live.sh 相同：默认只接受私钥，端口与 root 密码
# 由 LIVE_SSH_PORT 与 LIVE_SSH_PASSWORD 决定。
SSH_PORT=${LIVE_SSH_PORT:-22}
SSH_PW=${LIVE_SSH_PASSWORD:-}
# sshd 只读取主配置里 Include 进来的片段。Debian 12 默认包含这一行，缺少时补在
# 文件顶部：sshd 对同一指令取第一次出现的值，放在末尾会让主配置里的值先生效。
if ! grep -q '^Include /etc/ssh/sshd_config.d/' "$CH/etc/ssh/sshd_config" 2>/dev/null; then
	if [ -f "$CH/etc/ssh/sshd_config" ]; then
		{ printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat "$CH/etc/ssh/sshd_config"; } \
			> "$CH/etc/ssh/sshd_config.new"
		mv -f "$CH/etc/ssh/sshd_config.new" "$CH/etc/ssh/sshd_config"
	else
		printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$CH/etc/ssh/sshd_config"
	fi
fi
install -d -m755 "$CH/etc/ssh/sshd_config.d"
printf 'Port %s\n' "$SSH_PORT" > "$CH/etc/ssh/sshd_config.d/00-migrator-port.conf"
if [ -n "$SSH_PW" ]; then
	cat > "$CH/etc/ssh/sshd_config.d/10-migrator-auth.conf" <<'AUTH'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 20
AUTH
	HASH=$(openssl passwd -6 "$SSH_PW")
	sed -i "s|^root:[^:]*:|root:$HASH:|" "$CH/etc/shadow"
fi
chmod 644 "$CH/etc/ssh/sshd_config.d/"*.conf
cat > "$CH/usr/local/sbin/migrator-live-ssh" <<'SSHPORT'
#!/bin/sh
port=
for w in $(cat /proc/cmdline); do case $w in migrator.ssh_port=*) port=${w#migrator.ssh_port=} ;; esac; done
[ -n "$port" ] || exit 0
case $port in *[!0-9]*) exit 0 ;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || exit 0
f=/etc/ssh/sshd_config.d/00-migrator-port.conf
cp -f "$f" "$f.orig" 2>/dev/null
printf 'Port %s\n' "$port" > "$f"
if ! /usr/sbin/sshd -t 2>/dev/null; then
	mv -f "$f.orig" "$f" 2>/dev/null
	echo "migrator: sshd 拒绝端口 $port，恢复构建时的端口" >&2
fi
exit 0
SSHPORT
cat > "$CH/etc/systemd/system/migrator-live-ssh.service" <<'UNIT'
[Unit]
Description=migrator live ssh port (migrator.ssh_port=)
After=local-fs.target
Before=ssh.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/migrator-live-ssh
[Install]
WantedBy=multi-user.target
UNIT
chmod 755 "$CH/usr/local/sbin/migrator-live-ssh"
install -d "$CH/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/migrator-live-ssh.service \
	"$CH/etc/systemd/system/multi-user.target.wants/migrator-live-ssh.service"
rm -f "$CH/etc/systemd/system/sockets.target.wants/ssh.socket"
cat > "$CH/etc/network/interfaces" <<'IF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IF
printf 'nameserver 192.168.8.1\nnameserver 114.114.114.114\n' > "$CH/etc/resolv.conf"
echo migrator-live > "$CH/etc/hostname"
cat > "$CH/etc/migrator-live-release" <<REL
BUILD_ID=migrator-dev-$PROFILE-$(date +%Y%m%d)
CODENAME=bookworm
MIRROR=$MIRROR
REL

install -D -m0755 bin/migrator "$CH/usr/local/sbin/migrator"
sed -i 's/\r$//' "$CH/usr/local/sbin/migrator"
install -d -m0755 "$CH/usr/local/lib/migrator"
install -m0644 lib/*.sh "$CH/usr/local/lib/migrator/"
sed -i 's/\r$//' "$CH/usr/local/lib/migrator/"*.sh
install -m0755 agent/migrator-agent "$CH/usr/local/sbin/migrator-agent"
[ -f lib/VERSION ] && install -m0644 lib/VERSION "$CH/usr/local/lib/migrator/VERSION"
install -d -m0755 "$CH/usr/local/share/doc/migrator"
for f in LICENSE LICENSE-UPSTREAM NOTICE TRADEMARK.md; do
	install -m0644 "$f" "$CH/usr/local/share/doc/migrator/$f"
done

# zram: half the RAM as zstd swap, so a 1 GiB recipient can still run (D23)
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

# static network from the boot line: migrator.ip=IP/PREFIX,GW,DNS1[,DNS2]
cat > "$CH/usr/local/sbin/migrator-live-net" <<'NET'
#!/bin/sh
spec=
for w in $(cat /proc/cmdline); do case $w in migrator.ip=*) spec=${w#migrator.ip=} ;; esac; done
[ -n "$spec" ] || exit 0
addr=${spec%%,*}; rest=${spec#*,}; gw=${rest%%,*}; dns=${rest#*,}
# eth0 only when net.ifnames=0 is on the boot line; a kernel that did not get it
# calls the same NIC ens3/enp0s3, and then this unit silently did nothing while
# live-cycle.sh waited for an address that never came (D34)
dev=eth0
[ -e "/sys/class/net/$dev" ] || for d in /sys/class/net/*; do d=${d##*/}
	case $d in lo) continue;; *) dev=$d; break;; esac
done
ip link set "$dev" up 2>/dev/null || exit 0
ip addr flush dev "$dev" 2>/dev/null
ip addr add "$addr" dev "$dev" || exit 0
[ -n "$gw" ] && ip route replace default via "$gw" dev "$dev"
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
mksquashfs "$CH" "$OUT/live/filesystem.squashfs" -noappend -no-progress $SQ $MK_OPTS

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
