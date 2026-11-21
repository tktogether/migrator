#!/bin/bash
# rig/build-live.sh — build the migrator rescue Live ISO (D4/D7; D12: no live-build;
# D13: mmdebstrap instead of debootstrap — unprivileged containers cannot mknod).
# debootstrap-equivalent chroot (mmdebstrap) + live-boot initramfs + squashfs +
# xorriso (BIOS). Produces $HOME/rig/migrator-live.iso.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${RIG_OUT:-$HOME/rig}
SUITE=bookworm
# LIVE_MIRROR: a mirror other than the public one, for a build host that cannot
# reach deb.debian.org. tools/live-boot.sh passes it through.
MIRROR=${LIVE_MIRROR:-http://deb.debian.org/debian}
CH=$OUT/live-rootfs
ISODIR=$OUT/live-iso
ISO=$OUT/migrator-live.iso
# LIVE_PROFILE=slim: no qemu, xz squashfs, zram + static-ip support — for 1 GiB
# recipients; full keeps qemu for the E4 boot test (D23).
PROFILE=${LIVE_PROFILE:-full}
# LIVE_NO_ISO=1 stops before isolinux/xorriso and leaves the three artefacts in
# $OUT, named the way tools/live-entry.sh reads them. It is the path used by
# tools/live-boot.sh, where the machine boots the Live from its own disk and
# there is no ISO to write.
NO_ISO=${LIVE_NO_ISO:-}
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
# 端口服务要在 sshd 之前跑，因此挂在 multi-user 上并声明 Before=ssh.service。
ln -sf /etc/systemd/system/migrator-live-ssh.service "$CH/etc/systemd/system/multi-user.target.wants/migrator-live-ssh.service"
# socket 激活的 ssh 只监听 ssh.socket 里的端口，会忽略 sshd_config 的 Port。镜像里
# 只保留 ssh.service，使端口文件是唯一来源。
rm -f "$CH/etc/systemd/system/sockets.target.wants/ssh.socket"
if [ ! -e "$CH/etc/systemd/system/multi-user.target.wants/ssh.service" ] &&
	[ -e "$CH/usr/lib/systemd/system/ssh.service" ]; then
	ln -sf /usr/lib/systemd/system/ssh.service \
		"$CH/etc/systemd/system/multi-user.target.wants/ssh.service"
fi
# 登录方式（D66）。默认只接受私钥：密钥是进入 Live 的唯一凭据。端口与 root 密码
# 是可选参数，不作为默认值，因为端口写在引导参数里，任何本地用户都能读到，它降低
# 被扫描命中的概率，但不是访问控制；而写进镜像的密码由该镜像构建出的每台机器共用。
SSH_PORT=${LIVE_SSH_PORT:-22}
SSH_PW=${LIVE_SSH_PASSWORD:-}
case $SSH_PORT in
	''|*[!0-9]*) echo "LIVE_SSH_PORT=$SSH_PORT: want a number 1-65535" >&2; exit 2 ;;
esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] ||
	{ echo "LIVE_SSH_PORT=$SSH_PORT: want a number 1-65535" >&2; exit 2; }
case $SSH_PW in
	*:*|*'
'*) echo "LIVE_SSH_PASSWORD: 不能包含冒号或换行" >&2; exit 2 ;;
esac

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
install -d -m0755 "$CH/etc/ssh/sshd_config.d"
# 端口只放在这一个文件里。tools/live-boot.sh 在引导时用 migrator.ssh_port= 覆盖同一
# 个文件，因此两者不会同时生效，一个产物可以用不同端口进入。
printf 'Port %s\n' "$SSH_PORT" > "$CH/etc/ssh/sshd_config.d/00-migrator-port.conf"

if [ -n "$SSH_PW" ]; then
	cat > "$CH/etc/ssh/sshd_config.d/10-migrator-auth.conf" <<'AUTH'
# root 的密码登录，由 LIVE_SSH_PASSWORD 在构建时设定。镜像构建出的每台机器
# 共用这一个密码，因此它提供的是访问，不是保密。
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 20
AUTH
	# 直接改 /etc/shadow：构建可以无特权运行，chroot 不行。
	hash=$(openssl passwd -6 "$SSH_PW" 2>/dev/null) || hash=
	[ -n "$hash" ] || { echo "ERROR: 设置密码需要一个可用的 openssl" >&2; exit 2; }
	sed -i "s|^root:[^:]*:|root:$hash:|" "$CH/etc/shadow"
fi
chmod 0644 "$CH/etc/ssh/sshd_config.d/"*.conf

# 引导参数 migrator.ssh_port= 在 sshd 启动前覆盖端口。同一目录下只保留一个 Port
# 指令，重复的 Port 会让 sshd 同时监听两个端口。
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
chmod 0755 "$CH/usr/local/sbin/migrator-live-ssh"

install -d -m0700 "$CH/root/.ssh"
install -m0600 "$KEY.pub" "$CH/root/.ssh/authorized_keys"
# The pair also travels inside the Live, as build-live-debootstrap.sh does: the
# key that the outside uses to ssh in is the same one the Live uses for the
# donor, so a migration needs one key and not two.
install -m0600 "$KEY" "$CH/root/rig-key"
install -m0644 "$KEY.pub" "$CH/root/rig-key.pub"
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
if [ -n "$NO_ISO" ]; then
	ARDIR=$OUT
else
	ARDIR=$ISODIR/live
	mkdir -p "$ISODIR/isolinux"
fi
mkdir -p "$ARDIR/live"
case $PROFILE in slim) SQ="-comp xz" ;; *) SQ="-comp zstd -Xcompression-level 9" ;; esac
# shellcheck disable=SC2086  # SQ is a deliberate word list
mksquashfs "$CH" "$ARDIR/live/filesystem.squashfs" -noappend -no-progress $SQ > /dev/null

KVER=$(basename "$(ls "$CH"/boot/vmlinuz-* | head -1)"); KVER=${KVER#vmlinuz-}
echo "[live] kernel $KVER"
if [ -n "$NO_ISO" ]; then
	# the layout tools/live-entry.sh reads: one directory, three names
	cp "$CH/boot/vmlinuz-$KVER" "$ARDIR/vmlinuz-live"
	cp "$CH/boot/initrd.img-$KVER" "$ARDIR/initrd-live.img"
	rm -rf "$CH"
	ls -lh "$ARDIR/live/filesystem.squashfs" "$ARDIR/vmlinuz-live" "$ARDIR/initrd-live.img"
	echo "OK: $ARDIR (squashfs, kernel, initrd; no ISO)"
	exit 0
fi
cp "$CH/boot/vmlinuz-$KVER" "$ARDIR/live/vmlinuz"
cp "$CH/boot/initrd.img-$KVER" "$ARDIR/live/initrd.img"
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
