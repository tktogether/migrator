#!/bin/bash
# live-boot.sh：把本机送进迁移 Live。执行分三段，中间停两次。
#
#   1. 预检。只读检查，逐项打印结果。有未通过项时停止，此时本机没有改动。
#   2. 构建。取得确认后安装依赖、下载源码树、构建 Live，并打印私钥。
#   3. 引导。取得确认后写入 GRUB 引导项并重启。
#
# 为什么构建放在这里：迁移要在目标盘空闲时执行，所以必须从迁移 Live 运行；而 Live
# 目前没有可下载的镜像，只能就地构建。构建只需要 apt 与十几分钟，目标机自身就是
# 一台合适的构建机。Live 从内存运行，构建它的系统随后被替换不影响结果。
#
# 用法：
#   curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/live-boot.sh | bash
#   只看预检、不改动任何东西：在末尾加 -s -- -n
#
# 为什么停两次：预检之后停一次，让操作者在改动发生前读到结果；构建之后停一次，
# 因为写入引导项会改变下次开机的去处，而此时私钥已经生成，需要先交到操作者手上。
#
# 退出码：0 完成或演练通过 · 1 执行失败 · 2 本机条件不满足或未取得确认
set -u
# 系统目录放在前面：同名命令以系统自带的为准，调用方 PATH 里的内容只作补充。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}

OWNER=${MIGRATOR_OWNER:-tktogether/migrator}
GITEE=${MIGRATOR_GITEE:-$OWNER}
REF=${MIGRATOR_REF:-master}
OUT=${RIG_OUT:-/var/tmp/migrator-live}
PROFILE=slim
SPEC=; YES=; DRY=; TREE=
LIVE_MP=
n_pass=0; n_warn=0; n_fail=0
pkgs=

say() { printf '%s\n' "$*"; }
# exit 2 means "cannot run here": the machine, not the run, is the problem.
die() { local c=1; case ${1:-} in [0-9]) c=$1; shift ;; esac; printf 'ERROR: %s\n' "$*" >&2; exit "$c"; }
have() { command -v "$1" >/dev/null 2>&1; }
iec() { numfmt --to=iec "$1" 2>/dev/null || printf '%s' "$1"; }
cn_list() { printf '%s' "$1" | sed 's/ /、/g'; }

# --- 输出样式 ----------------------------------------------------------------
# 颜色只在终端上出现。通过管道运行时标准输出仍是终端，标准输入不是，因此判断
# 标准输出即可。NO_COLOR 与 MIGRATOR_COLOR 优先于判断结果。
ui_color() {
	case ${MIGRATOR_COLOR:-auto} in
		never) return 1 ;;
		always) return 0 ;;
	esac
	[ -z "${NO_COLOR:-}" ] || return 1
	[ -t 1 ] || return 1
	case ${TERM:-} in ''|dumb) return 1 ;; esac
	return 0
}
C_PASS=; C_WARN=; C_FAIL=; C_KEY=; C_DIM=; C_RESET=
if ui_color; then
	C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
	C_KEY=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
fi

RULE=
_i=0
while [ "$_i" -lt 72 ]; do RULE="$RULE─"; _i=$((_i + 1)); done
rule() { printf '%s%s%s\n' "$C_DIM" "$RULE" "$C_RESET"; }

# 与 tools/preflight.sh 的表格同一形态：结果列固定四列宽，说明用全角冒号接在项目后。
row() {
	if [ -n "$C_RESET" ]; then
		case $2 in
			PASS) c=$C_PASS ;;
			WARN) c=$C_WARN ;;
			*)    c=$C_FAIL ;;
		esac
		printf '  %s%-4s%s  %s%s%s：%s\n' "$c" "$2" "$C_RESET" "$C_KEY" "$1" "$C_RESET" "$3"
	else
		printf '  %-4s  %s：%s\n' "$2" "$1" "$3"
	fi
}
pass() { n_pass=$((n_pass + 1)); row "$1" PASS "$2"; }
warn() { n_warn=$((n_warn + 1)); row "$1" WARN "$2"; }
fail() { n_fail=$((n_fail + 1)); row "$1" FAIL "$2"; }

# 通过管道运行时标准输入是脚本自身且已读到末尾，交互必须接回终端。
# 判断放在子 shell 中试探：重定向失败在 dash 中会结束整个脚本。
can_ask() { [ -t 0 ] || ( : < /dev/tty ) 2>/dev/null; }

# 取得确认。没有可交互的终端时不猜测答案为是：写引导项与重启不能靠默认值发生。
confirm() {
	local a=
	[ -n "$YES" ] && return 0
	if [ -t 0 ]; then
		printf '%s [y/N] ' "$1"
		read -r a || a=
	elif can_ask; then
		printf '%s [y/N] ' "$1" >/dev/tty
		read -r a < /dev/tty || a=
	else
		printf '\n' >&2
		die 2 "没有可交互的终端，无法取得确认。确认无误后加 -y 重新运行"
	fi
	case $a in y|Y|yes|YES) return 0 ;; esac
	return 1
}

usage() {
	cat <<'EOF'
用法：live-boot.sh [选项]

  在本机构建迁移 Live，写入本机的 GRUB 引导项，然后重启进入它。
  构建不需要第二台机器：本机现有系统就是构建机。

  执行分三段，中间停两次：
    1. 预检。只读检查，逐项打印结果。有未通过项时停止，本机没有改动。
    2. 构建。取得确认后安装依赖、下载源码树、构建 Live，并打印私钥。
    3. 引导。取得确认后写入引导项并重启。

  -i SPEC      Live 的静态地址，格式 IP/前缀,网关,DNS
               例：192.168.1.50/24,192.168.1.1,114.114.114.114
               省略时取本机当前的地址、默认网关与 DNS
  -p PROFILE   slim（默认，不含 qemu，体积小）或 full（含 qemu，可用于启动测试）
  -s DIR       使用 DIR 中已有的源码树，不从网络下载
  -y           跳过两处确认，一直执行到重启
  -n           只做预检并打印后续步骤，不改动本机
  -h           显示本说明

预检逐项检查：
  root 权限；本机未处于迁移 Live；Debian 或 Ubuntu 系；x86_64；内存至少 1536 MiB；
  存在可放置 Live 的非 LVM 分区且可用空间至少 3 GiB；构建依赖是否齐备；
  源码树是否可取；网络参数能否确定；本机是否已有迁移 Live 的引导项与产物。

构建完成后本机会重启。重启后：
  ssh -i <私钥> root@<地址>      私钥在构建结束时打印，重启前请先保存
  cat /etc/migrator-live-release  确认已进入 Live

本脚本不做自己的事：构建交给 rig/build-live.sh，写引导项交给 tools/live-entry.sh。
放弃这次切换、回到原系统：bash <产物目录>/live-entry.sh -r

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
TREE=${TREE%/}

# =============================================================================
# 第一段：预检。只读：不创建目录、不安装软件包、不写引导项。
# =============================================================================
host=$(hostname 2>/dev/null || uname -n 2>/dev/null)
say ""
printf '  整机迁移 · 进入迁移 Live  │  本机 %s\n' "${host:-未知}"
rule
say ""
if [ -n "$C_RESET" ]; then
	printf '  %s%-4s  %s%s\n' "$C_DIM" "结果" "检查项与说明" "$C_RESET"
else
	printf '  %-4s  %s\n' "结果" "检查项与说明"
fi

# --- 身份与位置 --------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
	pass "运行身份" "当前用户为 root"
else
	fail "运行身份" "当前用户不是 root。安装软件包、写入引导项与重启都需要 root 权限"
fi

if [ -r /etc/migrator-live-release ] || [ -r /etc/xserver-live-release ]; then
	fail "当前系统" "本机已从迁移 Live 启动，不需要再构建。迁移命令直接在 Live 中执行"
else
	pass "当前系统" "本机运行自身系统，可在此构建迁移 Live"
fi

# --- 本机条件 ----------------------------------------------------------------
osid=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
oslike=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")
pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
if ! have apt-get; then
	fail "发行版" "本机没有 apt-get。构建需要 Debian 或 Ubuntu 及其衍生发行版"
elif printf '%s %s' "$osid" "$oslike" | grep -qw debian ||
	printf '%s %s' "$osid" "$oslike" | grep -qw ubuntu; then
	pass "发行版" "${pretty:-$osid}"
elif [ -n "$pretty" ]; then
	warn "发行版" "$pretty 不在支持范围内。构建脚本面向 Debian 与 Ubuntu，可能失败"
else
	warn "发行版" "无法读取发行版名称。构建脚本面向 Debian 与 Ubuntu，可能失败"
fi

case $(uname -m) in
	x86_64) pass "架构" "x86_64" ;;
	*)      fail "架构" "本机是 $(uname -m)。迁移 Live 只提供 x86_64 的内核" ;;
esac

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)
case ${mem_kb:-} in ''|*[!0-9]*) mem_kb=0 ;; esac
mem_mib=$((mem_kb / 1024))
if [ "$mem_mib" -ge 2048 ]; then
	pass "内存" "${mem_mib} MiB，构建与从内存运行 Live 都有余量"
elif [ "$mem_mib" -ge 1536 ]; then
	warn "内存" "${mem_mib} MiB，刚够把 Live 解压到内存。切换前不要运行其他占用内存的程序"
else
	fail "内存" "${mem_mib} MiB 不足。Live 从内存运行，至少需要 1536 MiB"
fi

# live-boot 扫描块设备寻找 <fs>/live/filesystem.squashfs，不进入 LVM（D30 ①），
# 因此产物要放在普通分区上。空间判断放在选分区时做：独立的 /boot 放不下时改用根
# 分区，比分到半途失败要好。
LIVE_NEED=3221225472
pick_fs() {
	local cand mnt fs dev avail
	for cand in /boot /; do
		mnt=$(findmnt -no TARGET -T "$cand" 2>/dev/null) || continue
		[ "$mnt" = "$cand" ] || continue
		fs=$(findmnt -no FSTYPE -T "$mnt" 2>/dev/null)
		dev=$(findmnt -no SOURCE -T "$mnt" 2>/dev/null)
		case $dev in /dev/mapper/*|/dev/dm-*) continue ;; esac
		case $fs in ext2|ext3|ext4|xfs|btrfs|vfat) ;; *) continue ;; esac
		[ -n "$dev" ] || continue
		avail=$(df -B1 --output=avail "$mnt" 2>/dev/null | tail -1 | tr -d ' ')
		case ${avail:-} in ''|*[!0-9]*) continue ;; esac
		[ "$avail" -ge "$LIVE_NEED" ] || continue
		LIVE_MP=$mnt
		return 0
	done
	return 1
}
if pick_fs; then
	pass "放置位置" "$LIVE_MP 位于非 LVM 分区，引导文件放在这里"
else
	fail "放置位置" "找不到可用的非 LVM 分区。引导文件需要放在非 LVM 的 ext4、xfs 或 btrfs 上，并有 3 GiB 可用空间"
fi

# 构建产物先写入 OUT，再由 live-entry.sh 复制到 LIVE_MP，两处各需一份空间；
# 两者位于同一分区时按两份计算。
existing_parent() {
	local p=$1
	while [ ! -d "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
	printf '%s' "$p"
}
out_at=$(existing_parent "$OUT")
avail=$(df -B1 --output=avail "$out_at" 2>/dev/null | tail -1 | tr -d ' ')
case ${avail:-} in ''|*[!0-9]*) avail=0 ;; esac
need=$LIVE_NEED
out_mnt=$(findmnt -no TARGET -T "$out_at" 2>/dev/null)
[ -n "${out_mnt:-}" ] && [ "$out_mnt" = "$LIVE_MP" ] && need=$((LIVE_NEED * 2))
if [ "$avail" -ge "$need" ]; then
	pass "产物空间" "$out_at 有 $(iec "$avail") 可用，需要 $(iec "$need")"
else
	fail "产物空间" "$out_at 只有 $(iec "$avail") 可用，需要 $(iec "$need")。可用 RIG_OUT 指定其他目录"
fi

# --- 构建依赖 ----------------------------------------------------------------
pkgs=
have mmdebstrap || pkgs="$pkgs mmdebstrap"
have mksquashfs || pkgs="$pkgs squashfs-tools"
have make || pkgs="$pkgs make"
have gcc || pkgs="$pkgs build-essential"
have ssh-keygen || pkgs="$pkgs openssh-client"
have tar || pkgs="$pkgs tar"
[ -e /usr/include/zstd.h ] || pkgs="$pkgs libzstd-dev"
if [ -z "$pkgs" ]; then
	pass "构建依赖" "所需软件包均已安装"
else
	warn "构建依赖" "缺少 $(cn_list "${pkgs# }")，确认后自动安装"
fi

# --- 源码树 ------------------------------------------------------------------
if [ -n "$TREE" ]; then
	if [ -f "$TREE/rig/build-live.sh" ]; then
		pass "源码树" "使用本机已有的源码树 $TREE"
	else
		fail "源码树" "$TREE 不是 migrator 的源码树：找不到 rig/build-live.sh"
	fi
elif ! have curl && ! have wget; then
	fail "源码树" "本机既没有 curl 也没有 wget，无法下载源码树。可用 -s 指定已有的源码树"
else
	reach=; unreach=
	for u in "https://gitee.com/$GITEE/repository/archive/$REF.tar.gz" \
		"https://github.com/$OWNER/archive/$REF.tar.gz"; do
		h=${u#https://}; h=${h%%/*}
		if have curl; then
			curl -fsSL -o /dev/null -m 10 -r 0-0 "$u" 2>/dev/null && ok=1 || ok=
		else
			wget -q --spider -T 10 "$u" 2>/dev/null && ok=1 || ok=
		fi
		if [ -n "$ok" ]; then reach="${reach:+$reach、}$h"; else unreach="${unreach:+$unreach、}$h"; fi
	done
	if [ -n "$reach" ]; then
		if [ -n "$unreach" ]; then
			warn "源码树" "可从 $reach 取得。$unreach 不可访问，构建时只用前者"
		else
			pass "源码树" "可从 $reach 取得"
		fi
	else
		fail "源码树" "$unreach 均不可访问。请先解决网络，或用 -s 指定已有的源码树"
	fi
fi

# --- 网络参数 ----------------------------------------------------------------
detect_spec() {
	local r src gw dev pfx dns
	have ip || return 1
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
if [ -n "$SPEC" ]; then
	pass "网络参数" "Live 使用指定地址 ${SPEC%%,*}"
elif detect_spec; then
	pass "网络参数" "沿用本机地址 ${SPEC%%,*}"
else
	fail "网络参数" "无法确定本机的地址与网关。请用 -i 指定，格式为 IP/前缀,网关,DNS"
fi

# --- 会改变什么 --------------------------------------------------------------
grubcfg=
for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do [ -r "$f" ] && grubcfg=$f && break; done
if ! have update-grub; then
	fail "引导" "本机没有 update-grub。写入引导项依赖 GRUB，本脚本不支持其他引导程序"
elif [ -n "$grubcfg" ] && grep -q "migrator-live" "$grubcfg" 2>/dev/null; then
	warn "引导" "本机已有迁移 Live 的引导项，本次会覆盖它并设为默认"
else
	pass "引导" "将新增一条 GRUB 引导项并设为默认"
fi

if [ -f "$OUT/live/filesystem.squashfs" ]; then
	warn "已有产物" "$OUT 中有上一次构建的产物，本次会覆盖。其中的私钥会被替换"
else
	pass "已有产物" "$OUT 尚无产物，本次新建"
fi

# --- 结论 --------------------------------------------------------------------
say ""
rule
if [ -n "$C_RESET" ]; then
	printf '  共 %d 项检查：%s%d 项通过%s，%s%d 项提醒%s，%s%d 项未通过%s\n' \
		$((n_pass + n_warn + n_fail)) \
		"$C_PASS" "$n_pass" "$C_RESET" \
		"$C_WARN" "$n_warn" "$C_RESET" \
		"$C_FAIL" "$n_fail" "$C_RESET"
else
	printf '  共 %d 项检查：%d 项通过，%d 项提醒，%d 项未通过\n' \
		$((n_pass + n_warn + n_fail)) "$n_pass" "$n_warn" "$n_fail"
fi
say ""

if [ "$n_fail" -gt 0 ]; then
	say "预检有 $n_fail 项未通过，未做任何改动。处理上面的问题后重新运行本脚本。"
	exit 2
fi

# --- 后续步骤 ----------------------------------------------------------------
n=0
step() { n=$((n + 1)); printf '  %d. %s\n' "$n" "$*"; }
say "预检通过。接下来依次执行："
if [ -n "$pkgs" ]; then step "安装构建依赖：$(cn_list "${pkgs# }")"; fi
if [ -n "$TREE" ]; then step "使用本机已有的源码树"; else step "从镜像下载源码树"; fi
step "编译在线迁移所需的 agent"
step "构建迁移 Live（profile=$PROFILE），耗时约十几分钟"
step "写入 GRUB 引导项并设为默认，然后重启"
say ""
say "重启后本机从迁移 Live 启动，当前系统不再运行。产物写入 $OUT，占用约 2 GiB。"
say ""

if [ -n "$DRY" ]; then
	say "演练结束，未做任何改动。去掉 -n 即按上面的步骤执行。"
	exit 0
fi

if ! confirm "开始执行"; then
	say "已取消，未做任何改动。"
	exit 0
fi

# =============================================================================
# 第二段：构建。到这里才开始改动本机。
# =============================================================================
if [ -n "$pkgs" ]; then
	say ""
	say "安装构建依赖：$(cn_list "${pkgs# }")"
	apt-get update -qq || die "apt-get update 失败。请先解决软件源"
	# shellcheck disable=SC2086  # pkgs is a deliberate word list
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs ||
		die "安装构建依赖失败：$(cn_list "${pkgs# }")"
fi

TMP=
if [ -z "$TREE" ]; then
	TMP=$(mktemp -d "${TMPDIR:-/var/tmp}/migrator-live.XXXXXX") || die 2 "无法创建临时目录"
	trap 'rm -rf "$TMP"' EXIT INT TERM
	say ""
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
	[ -n "$got" ] || die "源码树未能从任何地址取到。请先解决网络，或用 -s 指定已有的源码树"
	TREE=${TREE%/}
fi
[ -f "$TREE/rig/build-live.sh" ] || die "$TREE 不是 migrator 的源码树：找不到 rig/build-live.sh"

# 在线迁移需要 agent 跟踪源端的写入；离线（两端都在 Live 中）不需要。
# 这一步失败只是警告：离线迁移仍可继续。
say ""
say "编译 agent"
if ( cd "$TREE" && make agent ) >/dev/null 2>&1; then
	say "  agent 已编译"
else
	say "  WARN：agent 编译失败。本次只能做离线迁移（两端都进入 Live）；在线迁移需要 agent"
fi

say ""
say "构建迁移 Live（profile=$PROFILE），这一步需要十几分钟"
LIVE_PROFILE=$PROFILE LIVE_NO_ISO=1 RIG_OUT=$OUT bash "$TREE/rig/build-live.sh" ||
	die "构建失败。上一次的输出在上面"

# live-entry.sh 是单文件脚本，复制一份到产物目录，撤销时不必回到源码树。
if [ -f "$TREE/tools/live-entry.sh" ] && [ "$TREE/tools/live-entry.sh" != "$OUT/live-entry.sh" ]; then
	cp -f "$TREE/tools/live-entry.sh" "$OUT/live-entry.sh" 2>/dev/null
	chmod 0755 "$OUT/live-entry.sh" 2>/dev/null
fi

# =============================================================================
# 第三段：引导。写入引导项会改变下次开机的去处，因此先交出私钥，再问一次。
# =============================================================================
KEY=$OUT/rig_ed25519
say ""
rule
say "进入迁移 Live 只接受这把私钥，没有可在控制台键入的密码。"
say "目标盘随后会被整体替换，保存在本机上的副本不会留下，请现在保存到其他设备："
say ""
say "  $KEY"
say ""
if [ -f "$KEY" ]; then
	# shellcheck disable=SC2002
	cat "$KEY"
fi
live_addr=${SPEC%%,*}
live_addr=${live_addr%%/*}
say ""
say "登录命令：ssh -i <保存后的文件> root@$live_addr"
rule
say ""

if ! confirm "写入引导项并重启（下次开机进入迁移 Live）"; then
	say ""
	say "未写入引导项，本机仍从当前系统启动，磁盘上的分区与数据都没有改动。"
	say "产物保留在 $OUT。日后要继续，执行："
	say "  bash $OUT/live-entry.sh -s -f $OUT -i $SPEC"
	say "放弃这次构建、释放空间：删除 $OUT 即可"
	exit 0
fi

say "写入 GRUB 引导项"
bash "$TREE/tools/live-entry.sh" -s -f "$OUT" -i "$SPEC" || die "写入引导项失败"

say "重启"
reboot
