#!/bin/bash
# live-boot.sh — put THIS machine into the migrator Live with one command: build
# the Live here, place it on a filesystem of this machine, write a grub entry,
# reboot.
#
# Why building is part of it: a migration has to run while the target disk is
# free, so it runs inside a Live, and the Live has to exist before that. There
# is no published image to download, so the only path that works today is to
# build one — and building needs no second machine. Any Debian or Ubuntu box
# can do it; the target host is one, and at this point its own system is still
# running, used only as a build host and as the place the Live sleeps on disk.
# The Live that comes out runs entirely from RAM, so it does not matter that it
# was built by the system it is about to replace.
#
#   curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/live-boot.sh | bash
#   curl -fsSL .../tools/live-boot.sh | bash -s -- -n     # say what it would do
#
# The two halves already existed: rig/build-live.sh builds, tools/live-entry.sh
# writes the boot entry. This script is the glue, plus the checks that make it
# safe to run on an unknown machine, plus the one thing neither half can do:
# hand the reader the ssh key before the disk gets replaced.
#
# exit: 0 done, or dry run ok · 1 failure · 2 cannot run here
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

OWNER=${MIGRATOR_OWNER:-tktogether/migrator}
GITEE=${MIGRATOR_GITEE:-$OWNER}
REF=${MIGRATOR_REF:-master}
OUT=${RIG_OUT:-/var/tmp/migrator-live}
PROFILE=slim
SPEC=; YES=; DRY=; TREE=; LIVE_MP=

say() { printf '%s\n' "$*"; }
# exit 2 means "cannot run here": the machine, not the run, is the problem.
die() { local c=1; case ${1:-} in [0-9]) c=$1; shift ;; esac; printf 'ERROR: %s\n' "$*" >&2; exit "$c"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { if [ -n "$DRY" ]; then printf '  将执行：%s\n' "$*"; else "$@"; fi; }
iec() { numfmt --to=iec "$1" 2>/dev/null || printf '%s' "$1"; }

usage() {
	cat <<'EOF'
用法：live-boot.sh [选项]

  在本机构建迁移 Live，写入本机的 GRUB 引导项，然后重启进入它。
  构建不需要第二台机器：本机现有系统就是构建机。

  -i SPEC      Live 的静态地址，格式 IP/前缀,网关,DNS
               例：192.168.1.50/24,192.168.1.1,114.114.114.114
               省略时取本机当前的地址、默认网关与 DNS
  -p PROFILE   slim（默认，不含 qemu，体积小）或 full（含 qemu，可用于启动测试）
  -s DIR       使用 DIR 中已有的源码树，不从网络下载
  -y           不再询问，构建完成后直接重启
  -n           演练：只检查并打印将要做的事，不安装、不下载、不重启
  -h           显示本说明

前置条件（脚本逐项检查，不满足时说明原因后退出）：
  root 权限；Debian 或 Ubuntu；x86_64；内存至少 1536 MiB；
  根文件系统或独立的 /boot 位于非 LVM 分区，可用空间至少 3 GiB；可访问网络。

构建完成后本机会重启。重启后：
  ssh -i <私钥> root@<地址>      私钥路径在脚本末尾打印，重启前请先保存
  cat /etc/migrator-live-release  确认已进入 Live

本脚本不做自己的事：构建交给 rig/build-live.sh，写引导项交给 tools/live-entry.sh。
放弃这次切换、回到原系统：tools/live-entry.sh -r

环境变量：
  LIVE_MIRROR    构建时使用的 Debian 镜像，默认 http://deb.debian.org/debian
  RIG_OUT        构建产物目录，默认 /var/tmp/migrator-live
  MIGRATOR_REF   读取的分支或标签，默认 master
EOF
}

while getopts "i:p:s:ynh" o; do
	case $o in
		i) SPEC=$OPTARG ;;
		p) PROFILE=$OPTARG ;;
		s) TREE=$OPTARG ;;
		y) YES=1 ;;
		n) DRY=1 ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done
case $PROFILE in slim|full) ;; *) die "未知的 PROFILE：$PROFILE（可选 slim 或 full）" ;; esac

# --- can this machine hold the Live at all -----------------------------------
[ "$(id -u)" = 0 ] || die 2 "需要 root：脚本会安装软件包、写 GRUB 引导项并重启"
have apt-get || die 2 "本脚本需要 apt-get：只支持 Debian 与 Ubuntu"
[ "$(uname -m)" = x86_64 ] || die 2 "只支持 x86_64，本机是 $(uname -m)"

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
case $mem_kb in ''|*[!0-9]*) mem_kb=0 ;; esac
if [ "$mem_kb" -lt 1572864 ]; then
	die 2 "内存 $((mem_kb / 1024)) MiB 不足：Live 解压到内存需要至少 1536 MiB"
fi

# live-boot scans block devices for <fs>/live/filesystem.squashfs and does not
# enter LVM (D30 ①), so the tree needs a plain filesystem. The same choice
# rules as tools/live-entry.sh, made here so the failure comes before the
# twenty-minute build rather than after it.
pick_fs() {
	local cand mnt fs dev
	for cand in /boot /; do
		mnt=$(findmnt -no TARGET -T "$cand" 2>/dev/null) || continue
		[ "$mnt" = "$cand" ] || continue
		fs=$(findmnt -no FSTYPE -T "$mnt" 2>/dev/null)
		dev=$(findmnt -no SOURCE -T "$mnt" 2>/dev/null)
		case $dev in /dev/mapper/*|/dev/dm-*) continue ;; esac
		case $fs in ext2|ext3|ext4|xfs|btrfs|vfat) ;; *) continue ;; esac
		[ -n "$dev" ] || continue
		LIVE_MP=$mnt
		return 0
	done
	return 1
}
pick_fs || die 2 "找不到可用于放置 Live 的非 LVM 文件系统。live-boot 无法读取 LVM 内部，需要一块普通的 ext4 /boot"

mkdir -p "$OUT" 2>/dev/null || die 2 "无法创建 $OUT，请用 RIG_OUT 指定其他目录"
avail=$(df -B1 --output=avail "$OUT" | tail -1 | tr -d ' ')
[ "${avail:-0}" -ge 3221225472 ] ||
	die 2 "$OUT 所在分区只有 $(iec "${avail:-0}") 可用，构建需要至少 3 GiB"

# --- the address the Live will have ------------------------------------------
detect_spec() {
	local r src gw dev pfx dns
	r=$(ip route get 1.1.1.1 2>/dev/null) || return 1
	src=$(printf '%s\n' "$r" | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }')
	gw=$(printf '%s\n' "$r" | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1) }')
	dev=$(printf '%s\n' "$r" | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }')
	[ -n "$src" ] && [ -n "$gw" ] || return 1
	pfx=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{ print $4 }' | head -1)
	case $pfx in */*) ;; *) pfx=$src/24 ;; esac
	dns=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null)
	[ -n "$dns" ] || dns=114.114.114.114
	SPEC="$pfx,$gw,$dns"
}
if [ -z "$SPEC" ]; then
	detect_spec || die 2 "无法自动确定本机的地址与网关。请用 -i 指定，格式 IP/前缀,网关,DNS"
fi

pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
say "本机：${pretty:-未知发行版}  内核 $(uname -r)"
say "Live 放在：$LIVE_MP（非 LVM 分区）"
say "地址：$SPEC"
say "产物目录：$OUT"

if [ -n "$DRY" ]; then
	say ""
	say "演练结束，未做任何改动。将依次执行："
	say "  1. 安装构建依赖（mmdebstrap、squashfs-tools、build-essential、libzstd-dev，缺什么装什么）"
	if [ -n "$TREE" ]; then
		say "  2. 使用现有源码树 $TREE"
	else
		say "  2. 从镜像下载源码树"
	fi
	say "  3. make agent（在线迁移需要）"
	say "  4. rig/build-live.sh，profile=$PROFILE，产出 squashfs、内核与 initrd"
	say "  5. tools/live-entry.sh -s，写入持久默认引导项"
	say "  6. 重启进入 Live"
	exit 0
fi

# --- build dependencies -------------------------------------------------------
pkgs=
have mmdebstrap || pkgs="$pkgs mmdebstrap"
have mksquashfs || pkgs="$pkgs squashfs-tools"
have make || pkgs="$pkgs make"
have ssh-keygen || pkgs="$pkgs openssh-client"
have gcc || pkgs="$pkgs build-essential"
[ -e /usr/include/zstd.h ] || pkgs="$pkgs libzstd-dev"
if [ -n "$pkgs" ]; then
	say "安装构建依赖：$pkgs"
	run apt-get update -qq || die "apt-get update 失败：请先解决软件源"
	# shellcheck disable=SC2086  # pkgs is a deliberate word list
	DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends $pkgs ||
		die "安装构建依赖失败：$pkgs"
fi

# --- the tree -----------------------------------------------------------------
TMP=
if [ -z "$TREE" ]; then
	have curl || have wget || die 2 "本机既没有 curl 也没有 wget，无法下载源码树。可用 -s 指定已有的源码树"
	have tar || die 2 "本机缺少 tar"
	TMP=$(mktemp -d "${TMPDIR:-/var/tmp}/migrator-live.XXXXXX") || die 2 "无法创建临时目录"
	trap 'rm -rf "$TMP"' EXIT INT TERM
	say "下载源码树"
	got=
	for u in "https://gitee.com/$GITEE/repository/archive/$REF.tar.gz" \
		"https://github.com/$OWNER/archive/$REF.tar.gz"; do
		say "  尝试 $u"
		if have curl; then
			curl -fsSL --connect-timeout 5 --max-time 300 -o "$TMP/tree.tar.gz" "$u" 2>/dev/null
		else
			wget -q -T 30 -t 1 -O "$TMP/tree.tar.gz" "$u" 2>/dev/null
		fi || continue
		mkdir -p "$TMP/x"
		tar -xzf "$TMP/tree.tar.gz" -C "$TMP/x" 2>/dev/null || continue
		TREE=$(ls -d "$TMP"/x/*/ 2>/dev/null | head -1)
		[ -n "$TREE" ] && got=1 && break
	done
	[ -n "$got" ] || die "源码树未能从任何地址取到。可设置 MIGRATOR_BASE 指向代理，或用 -s 指定已有源码树"
	TREE=${TREE%/}
fi
[ -f "$TREE/rig/build-live.sh" ] || die "$TREE 不是 migrator 的源码树：找不到 rig/build-live.sh"

# --- the agent ----------------------------------------------------------------
# Online migration needs it to follow the donor's writes; offline (both ends in
# a Live) does not. A failure here is a warning, not the end.
say "构建 agent"
if ( cd "$TREE" && make agent ) >/dev/null 2>&1; then
	say "  agent 已构建"
else
	say "  WARN: agent 构建失败。本次只能做离线迁移（两端都进入 Live）；在线迁移需要 agent"
fi

# --- build --------------------------------------------------------------------
say "构建 Live（profile=$PROFILE），这一步需要十几分钟"
LIVE_PROFILE=$PROFILE LIVE_NO_ISO=1 RIG_OUT=$OUT bash "$TREE/rig/build-live.sh" ||
	die "构建失败。上一次的输出在上面"

# --- boot entry ---------------------------------------------------------------
say "写入 GRUB 引导项"
bash "$TREE/tools/live-entry.sh" -s -f "$OUT" -i "$SPEC" ||
	die "写入引导项失败"

# --- the key ------------------------------------------------------------------
# The Live accepts root only through this key (there is no console password), so
# losing it means losing the way in. The disk is replaced later in the run, so
# the copy on this machine does not survive either: print it now.
KEY=$OUT/rig_ed25519
say ""
say "──────────────────────────────────────────────────────────────────────"
say "进入 Live 使用这把私钥。请现在保存到你的机器上，之后这块磁盘会被整体替换："
say ""
say "  $KEY"
say ""
if [ -f "$KEY" ]; then
	# shellcheck disable=SC2002
	cat "$KEY"
fi
say ""
say "保存方法：ssh -i <保存后的文件> root@${SPEC%%,*}"
say "──────────────────────────────────────────────────────────────────────"
say ""

if [ -n "$YES" ]; then
	say "重启进入 Live"
	run reboot
	exit 0
fi

ans=
if [ -t 0 ]; then
	printf '现在重启进入 Live？[y/N] '
	read -r ans || ans=
elif ( : < /dev/tty ) 2>/dev/null; then
	printf '现在重启进入 Live？[y/N] ' >/dev/tty
	read -r ans < /dev/tty || ans=
fi
case $ans in
	y|Y) say "重启"; reboot ;;
	*) say "未重启。准备好后执行 reboot 即可进入 Live；若要放弃这次切换，执行 $TREE/tools/live-entry.sh -r" ;;
esac
