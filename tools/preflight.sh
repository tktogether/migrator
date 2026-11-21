#!/bin/sh
# preflight.sh — 检查本机能否执行一次迁移，输出检查结果与下一步命令。
#
# 单文件脚本，不安装任何软件，也不依赖仓库，取到即可运行。
#
#   curl -fsSL <地址> | sh -s --              只检查（默认）
#   curl -fsSL <地址> | sh -s -- --fix        安装缺失的软件包，然后重新检查
#   curl -fsSL <地址> | sh -s -- --go         没有 FAIL 项时进入迁移向导
#   或者先保存到本地：curl -fsSL -o /tmp/pf.sh <地址> && sh /tmp/pf.sh --go
#
# 三个可用的下载地址，选择可访问的一个（中国大陆境内通常使用 Gitee）：
#   https://gitee.com/tktogether/migrator/raw/master/tools/preflight.sh
#   https://cdn.jsdelivr.net/gh/tktogether/migrator@master/tools/preflight.sh
#   或者 sh tools/preflight.sh（仓库已在本地）
#
# 选项写在 `sh -s --` 之后。写成 sh -c "$(curl …)" --fix 时，第一个参数会落到
# $0 而不是参数表；脚本把 $0 取回当作第一个参数，两种写法等价。
#
# 源端地址按以下顺序读取，任一处取到即停止；全部未取到时只检查本机：
#   MIGRATOR_DONOR 环境变量 → 命令行参数 → /run/migrator/state 中上次连接的主机
# 脚本不扫描网段。首次运行时目标端尚未持有源端的密钥，扫描无法得到可用地址；
# 源端地址由操作者提供，脚本不推测。
#
# 结果分三档：
#   PASS  已满足要求
#   WARN  不阻止继续，但相关步骤会变慢或不可用。例如不在 Live 中：可以生成计划，
#         不能执行迁移
#   FAIL  按当前条件执行会失败，需要先处理
# exit: 0 没有 FAIL · 1 有 FAIL · 2 探测本身无法完成
#
# 默认只读：不挂载、不写入磁盘、不修改网络、不安装软件。--fix 与 --go 是仅有的
# 两个产生改动的选项，且都在全部检查完成后才生效。检查源端时只通过 ssh 执行
# 只读命令。
#
# 显示：交互终端上输出标志块、颜色与进度动画。以下任一情况只输出纯文本，便于
# 写入日志与比对：标准输出或标准错误不是终端、TERM 为 dumb 或未设置、
# 设置了 NO_COLOR、指定了 --plain。纯文本模式下边框使用 ASCII，宽度固定 78 列。
# --color 强制输出颜色，但不启用标志块与动画。环境变量 MIGRATOR_COLOR 取
# always / never / auto，效果与对应的开关相同。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

# --- 显示层 ------------------------------------------------------------------
# 颜色、标志块与进度动画都只影响显示。关闭时每一行仍是完整的中文句子，脚本的判断
# 与退出码不受影响。颜色使用 ANSI SGR 序列，不依赖 tput：终端不识别的序列会被
# 忽略，而下面先判断是否应当输出。
ui_mode=${MIGRATOR_COLOR:-auto}   # auto | always | never
ui_plain=; ui_force=
ui_tty=; ui_utf8=
ui_anim=; ui_logo=
spin_pid=
ESC=$(printf '\033_'); ESC=${ESC%_}
C_RESET=; C_DIM=; C_PASS=; C_WARN=; C_FAIL=; C_HEAD=; C_KEY=
RULE_CH=-; FRAME_H='='; BAR_CH='#'; VT='|'; SEP='|'; TL='+'; TR='+'; BL='+'; BR='+'
SPIN_FRAMES='- \ | /'
ui_w=72

ui_init() {
	# 显式指定的 --color / --no-color 优先于环境变量；NO_COLOR 只在 auto 下生效
	[ -n "$ui_force" ] && ui_mode=$ui_force
	if [ -z "$ui_force" ] && [ -n "${NO_COLOR:-}" ] && [ "$ui_mode" = auto ]; then
		ui_mode=never
	fi
	[ -n "$ui_plain" ] && ui_mode=never
	# 动画与标志块要求标准输出与标准错误都是终端：只写入其中一路时，回车符与
	# 转义序列会留在文件里
	if [ -t 1 ] && [ -t 2 ]; then ui_tty=1; fi
	case ${TERM:-} in ''|dumb) ui_tty= ;; esac
	case $ui_mode in
		always|never) ;;
		*) if [ -n "$ui_tty" ]; then ui_mode=always; else ui_mode=never; fi ;;
	esac
	# --color 只强制颜色。标志块与动画仍然要求终端：写入文件时那一行会变成
	# 一串回车符，读起来比纯文本更差
	if [ -n "$ui_tty" ]; then ui_anim=1; ui_logo=1; fi
	# 非 UTF-8 环境使用 ASCII 边框与填充字符，避免出现无法显示的方块
	case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
		*UTF-8*|*utf-8*|*UTF8*|*utf8*) ui_utf8=1 ;;
	esac
	# 制表字符只在交互终端上使用。写入日志或交给其他程序处理时保持 ASCII，
	# 以免按字节比较的工具把边框当成数据
	if [ -n "$ui_tty" ] && [ -n "$ui_utf8" ]; then
		RULE_CH='─'; FRAME_H='═'; BAR_CH='█'; VT='║'; SEP='│'
		TL='╔'; TR='╗'; BL='╚'; BR='╝'
		SPIN_FRAMES='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
	fi
	if [ "$ui_mode" = always ]; then
		C_RESET="$ESC[0m"; C_DIM="$ESC[2m"
		C_PASS="$ESC[1;32m"; C_WARN="$ESC[1;33m"; C_FAIL="$ESC[1;31m"
		C_HEAD="$ESC[1;36m"; C_KEY="$ESC[1;37m"
	fi
	# 分数秒的 sleep 并非所有系统都支持。不支持时退到整秒，避免动画占满 CPU
	SPIN_T=1
	sleep 0.05 2>/dev/null && SPIN_T=0.12
}

ui_str() {   # ui_str 次数 字符：把字符重复若干次写到标准输出
	i=0
	while [ "$i" -lt "$1" ]; do printf '%s' "$2"; i=$((i + 1)); done
}

# 内容宽度：写入日志时固定，便于比对；交互终端上随窗口变化，两侧各留两列
ui_width() {
	[ -n "$ui_tty" ] || return 0
	n=${COLUMNS:-80}
	case $n in ''|*[!0-9]*) n=80 ;; esac
	n=$((n - 4))
	[ "$n" -gt 76 ] && n=76
	[ "$n" -lt 56 ] && n=56
	ui_w=$n
}

ui_rule() {
	printf '  %s%s%s\n' "$C_DIM" "$(ui_str "$ui_w" "$RULE_CH")" "$C_RESET"
}

ui_clear() {
	if [ "$ui_mode" = always ]; then printf '\r%s[K' "$ESC" >&2
	else printf '\r%78s\r' '' >&2; fi
}

# 进度动画：只在交互终端上运行，写入标准错误，因此不会进入管道与重定向。
# 每帧回车回到行首，结束时由 ui_clear 擦除整行。
spin_start() {
	[ -n "$ui_anim" ] || return 0
	spin_label=$1
	( while :; do
		for f in $SPIN_FRAMES; do
			printf '\r  %s%s%s %s' "$C_DIM" "$f" "$C_RESET" "$spin_label" >&2
			sleep "$SPIN_T" 2>/dev/null
		done
	  done ) &
	spin_pid=$!
}

spin_stop() {
	[ -n "${spin_pid:-}" ] || return 0
	kill "$spin_pid" 2>/dev/null
	wait "$spin_pid" 2>/dev/null
	spin_pid=
	ui_clear
}

# 框内只放 ASCII：中文字符的显示宽度因字体而异，按字节补空格必然错位。字标
# 与副题均为 ASCII，宽度可以直接用 ${#} 计算。
ui_frame_gap() {
	printf '  %s%s%s%s%s\n' "$C_DIM" "$VT" "$C_RESET" \
		"$(ui_str $((ui_w - 2)) ' ')" "$C_DIM$VT$C_RESET"
}

ui_frame_line() {   # ui_frame_line 文本 颜色
	w=$((ui_w - 2 - ${#1}))
	[ "$w" -lt 0 ] && w=0
	l=$((w / 2))
	printf '  %s%s%s%s%s%s%s%s%s%s%s\n' \
		"$C_DIM" "$VT" "$C_RESET" "$(ui_str "$l" ' ')" \
		"$2" "$1" "$C_RESET" "$(ui_str $((w - l)) ' ')" "$C_DIM" "$VT" "$C_RESET"
}

ui_banner() {
	host=$(hostname 2>/dev/null || echo '?')
	ui_width
	if [ -n "$ui_logo" ]; then
		printf '\n'
		printf '  %s%s%s%s%s\n' "$C_DIM" "$TL" "$(ui_str $((ui_w - 2)) "$FRAME_H")" "$TR" "$C_RESET"
		ui_frame_gap
		ui_frame_line "M I G R A T O R" "$C_HEAD"
		ui_frame_line "PREFLIGHT" "$C_DIM"
		ui_frame_gap
		printf '  %s%s%s%s%s\n' "$C_DIM" "$BL" "$(ui_str $((ui_w - 2)) "$FRAME_H")" "$BR" "$C_RESET"
		printf '\n'
		printf '  整机迁移 · 预检  %s%s%s  目标端 %s\n' "$C_DIM" "$SEP" "$C_RESET" "$host"
		printf '\n'
	else
		printf '[migrator-preflight] 目标端 %s\n' "$host"
	fi
	ui_rule
	printf '\n'
}

ui_table_head() {
	printf '  %s%-4s  %s%s\n' "$C_DIM" "结果" "检查项与说明" "$C_RESET"
}

# 通过、提醒、未通过三段的条形图，只在终端上出现
ui_bar() {
	[ -n "$ui_tty" ] || return 0
	total=$((n_pass + n_warn + n_fail))
	[ "$total" -gt 0 ] || return 0
	w=24
	g=$((n_pass * w / total))
	y=$((n_warn * w / total))
	r=$((n_fail * w / total))
	# 整除的余数给数量最多的一段。若按减法把余数留给未通过段，0 项未通过时
	# 也会画出红色
	left=$((w - g - y - r))
	if [ "$n_pass" -ge "$n_warn" ] && [ "$n_pass" -ge "$n_fail" ]; then g=$((g + left))
	elif [ "$n_warn" -ge "$n_fail" ]; then y=$((y + left))
	else r=$((r + left)); fi
	printf '  %s' "$C_DIM"
	[ "$ui_mode" = always ] && printf '%s' "$C_PASS"
	ui_str "$g" "$BAR_CH"
	[ "$ui_mode" = always ] && printf '%s' "$C_WARN"
	ui_str "$y" "$BAR_CH"
	[ "$ui_mode" = always ] && printf '%s' "$C_FAIL"
	ui_str "$r" "$BAR_CH"
	printf '%s  %d 项通过 · %d 项提醒 · %d 项未通过\n' \
		"$C_RESET" "$n_pass" "$n_warn" "$n_fail"
}

usage() {
	cat <<'EOF'
用法：preflight.sh [--go] [--fix] [--donor HOST] [root@]HOST[:PORT]

  默认只检查，不安装软件、不写入磁盘、不修改网络。脚本为单文件，无需安装即可运行。
  从网络直接运行时，选项写在 sh -s -- 之后：curl -fsSL <地址> | sh -s -- [选项]
  --go          检查通过后进入迁移向导。源端地址已填入，其余项目照常询问
  --fix         安装缺失的软件包。安装后本脚本退出，由操作者重新运行以确认结果
  --check       只检查。即使已安装 migrator 也不进入向导，供脚本调用
  --donor HOST  指定源端地址，不读取上次连接的记录
  --plain       纯文本输出。不输出颜色、标志块与进度动画
  --color       输出颜色。输出不是终端时默认关闭，该选项将其打开
  --no-color    不输出颜色。与设置环境变量 NO_COLOR 效果相同
  -h, --help    显示本说明

未指定源端地址时，脚本读取 /run/migrator/state 中上次连接的主机。
该文件不存在时只检查本机。
使用 --go 且需要交互时，SSH 连接必须分配终端（ssh -t），脚本会把标准输入接回终端。
PATH 中没有 migrator 时，脚本在末尾打印安装命令。
EOF
}

# sh -c "$(curl …)" --fix 时，--fix 会进入 $0 而不是参数表。这里把它取回来当作
# 第一个参数，使该写法与 sh -s -- --fix 等价。$0 只在含斜杠时视为脚本路径，
# 否则（管道运行时的 sh）置空，后续不再用它拼目录。
case ${0:-} in
	-*) [ $# -eq 0 ] && set -- "$0" ;;
esac
SELF=${0:-}
case $SELF in
	*/*) ;;
	*)   SELF= ;;
esac

GO=; FIX=; DONOR=${MIGRATOR_DONOR:-}
while [ $# -gt 0 ]; do
	case $1 in
		--go|-g)      GO=1 ;;
		--fix|-f)     FIX=1 ;;
		--check|-c)   GO= ;;                       # 默认即只检查；显式写出便于调用方确认
		--donor)      DONOR=${2:-}; [ -n "$DONOR" ] || { echo "--donor 需要一个地址" >&2; exit 2; }; shift ;;
		--donor=*)    DONOR=${1#*=} ;;
		--color)      ui_force=always ;;
		--no-color)   ui_force=never ;;
		--plain)      ui_plain=1; ui_force=never ;;
		-h|--help)    usage; exit 0 ;;
		--)           shift; continue ;;
		-*)           echo "无法识别的选项：$1" >&2; usage >&2; exit 2 ;;
		*)            DONOR=$1 ;;
	esac
	shift
done

ui_init

n_pass=0; n_warn=0; n_fail=0; fix_pkgs=
# 结果列固定为 4 个字符，均为 ASCII，对齐可靠。中文按显示宽度占两列、按字节占
# 三字节，printf 的 %-28s 会把中文列排歪。因此检查项与说明连续排在同一列。
row() {
	if [ "$ui_mode" = always ]; then
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
need() { fix_pkgs="$fix_pkgs $2"; }   # 记录补齐该项需要安装的软件包

have() { command -v "$1" >/dev/null 2>&1; }
say()  { echo "[migrator-preflight] $*"; }
# 空格分隔的命令名转为顿号分隔，便于接在中文句子中
cn_list() { printf '%s' "$1" | sed 's/ /、/g'; }

# 通过管道运行时，标准输入指向脚本内容且已读到末尾，交互会立即读到 EOF。
# 存在终端时把标准输入接回 /dev/tty，"curl ... | sh -s -- --go" 因此可以回答问题。
# 判断在子 shell 中试探：在 dash 中重定向失败会使 exec 直接结束整个脚本；
# [ -r /dev/tty ] 在容器与 Git Bash 中会给出错误结果。
can_ask()   { [ -t 0 ] || ( : < /dev/tty ) 2>/dev/null; }
tty_stdin() { [ -t 0 ] && return 0; can_ask && exec 0</dev/tty; return 0; }

ui_banner
ui_table_head

# --- 身份与运行环境 ----------------------------------------------------------
if [ "$(id -u)" = 0 ]; then pass "运行身份" "当前用户为 root"
else fail "运行身份" "当前用户不是 root，分区与挂载需要 root 权限。请用 sudo 重新运行"; fi

if [ -r /etc/migrator-live-release ] || [ -r /etc/xserver-live-release ]; then
	pass "迁移 Live" "本机从迁移 Live 启动"
else
	warn "迁移 Live" "本机不是迁移 Live。本次只能完成本机检查；生成计划与执行迁移需要从迁移 Live 启动"
fi

mem=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem:-0}" -ge 3072 ]; then pass "内存" "${mem} MiB，满足预检与启动测试的需要"
elif [ "${mem:-0}" -ge 1536 ]; then warn "内存" "${mem} MiB，预检阶段将自动关闭。可用 -o precheck=1 强制开启"
else fail "内存" "低于 1536 MiB，收尾阶段的 chroot 与解包可能失败"; fi

cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
if [ "${cpus:-1}" -ge 2 ]; then pass "CPU" "$cpus 核，压缩与校验可使用多核"
else warn "CPU" "$cpus 核，在线迁移将降低压缩级别，冻结窗口会变长"; fi

# --- 工具本身 ----------------------------------------------------------------
if have migrator; then
	# -V 的同一行还带有库目录与 Live 字段，这里只取名称与版本
	v=$(migrator -V 2>/dev/null | head -1 | awk '{ print $1, $2 }')
	pass "工具" "PATH 中存在 ${v:-migrator}"
elif [ -n "$SELF" ] && [ -r "$SELF" ] && [ -x "$(dirname "$SELF")/../bin/migrator" ]; then
	pass "工具" "使用源码树中的驱动器 $SELF"
else
	warn "工具" "PATH 中没有 migrator。安装命令见本脚本末尾"
fi

# --- 目标磁盘 ----------------------------------------------------------------
# 迁移会整盘覆盖目标盘，而正在运行的系统占着的那块盘本次不能覆盖：内核还挂载着它。
# 这里标注的是「此刻被占用」，与厂商定义的系统盘位无关。盘的角色由硬件布局、RAID
# 成员与引导顺序决定，脚本无法判定，也不需要判定。进入迁移 Live 后根位于内存或
# 启动介质，那块盘即释放；它通常就是迁移的目标盘。
root_dev=
if have findmnt && have lsblk; then
	src=$(findmnt -no SOURCE / 2>/dev/null) || src=
	# 反向查询会依次给出 LVM 卷、分区与整盘，取最后的 disk；根文件系统直接位于
	# 整盘时（无分区表）该层就是它本身。lsblk 在非 raw 模式下给名称加树形字符，
	# 因此先去掉非名称字符再比较
	[ -n "$src" ] && root_dev=$(lsblk -sno NAME,TYPE "$src" 2>/dev/null |
		awk '{ n = $1; gsub(/[^A-Za-z0-9._-]/, "", n); if ($2 == "disk") { print "/dev/" n; exit } }')
	[ -n "${root_dev:-}" ] || root_dev=$src
fi

if have lsblk; then
	# 可用盘与被占用的盘分开记录：两者并列在同一句里，会被读成后者也可选
	disks=; sysd=; usable=0; listed=0
	for d in $(lsblk -dnpo NAME,SIZE,TYPE 2>/dev/null | awk '$3 == "disk" { print $1"|"$2 }'); do
		dev=${d%%|*}; size=${d#*|}
		listed=$((listed + 1))
		if [ -n "$root_dev" ] && [ "$dev" = "$root_dev" ]; then
			sysd="$sysd$dev（$size） "
		else
			disks="$disks$dev（$size） "; usable=$((usable + 1))
		fi
	done
	disks=${disks% }; sysd=${sysd% }
	if [ "$listed" -eq 0 ]; then fail "目标磁盘" "lsblk 未列出任何磁盘"; need lsblk util-linux
	elif [ "$usable" -eq 0 ]; then
		warn "目标磁盘" "唯一的磁盘 $sysd正被当前运行的系统占用。进入迁移 Live 后，该磁盘可作为目标盘"
	elif [ -z "$sysd" ]; then
		pass "目标磁盘" "$disks"
	else
		pass "目标磁盘" "可用磁盘 $disks。$sysd正被当前运行的系统占用，进入迁移 Live 后可选"
	fi
else
	fail "目标磁盘" "本机没有 lsblk，无法列出磁盘。该命令由 util-linux 提供"; need lsblk util-linux
fi

# 已投入使用的磁盘不能作为目标盘。尽早发现该情况是本脚本的目的之一。
busy=
if have pvs; then busy=$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | tr '\n' ' '); fi
if have swapon; then busy="$busy $(swapon --noheadings -o NAME 2>/dev/null | tr -d ' ' | tr '\n' ' ')"; fi
busy=$(echo "$busy" | tr -s ' ' | sed 's/^ //; s/ $//')
if [ -n "$busy" ]; then
	warn "被占用的设备" "以下设备是 LVM 或 swap 成员，其所在磁盘不能作为目标盘：$busy"
else
	pass "被占用的设备" "没有 LVM 或 swap 占用磁盘"
fi

# --- 依赖 --------------------------------------------------------------------
miss=
for t in tar gzip sha256sum awk sed findmnt lsblk blkid; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "基础工具" "所需命令均已安装"
else
	fail "基础工具" "缺少 $(cn_list "${miss# }")。这些是迁移过程必需的命令"
	case $miss in *tar*) need tar tar ;; esac
	case $miss in *gzip*) need gzip gzip ;; esac
	case $miss in *sha256sum*) need sha256sum coreutils ;; esac
	case $miss in *awk*) need awk gawk ;; esac
	case $miss in *findmnt*|*lsblk*|*blkid*) need util-linux util-linux ;; esac
fi

miss=
for t in partclone.ext4 mkfs.ext4 e2fsck tune2fs; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "ext4 工具链" "所需命令均已安装"
else
	fail "ext4 工具链" "缺少 $(cn_list "${miss# }")。可用 --fix 安装 partclone 与 e2fsprogs"
	case $miss in *partclone*) need partclone partclone ;; esac
	case $miss in *mkfs*|*e2fsck*|*tune2fs*) need e2fsprogs e2fsprogs ;; esac
fi

miss=
for t in zstd lz4; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "压缩" "zstd 与 lz4 均已安装"
else
	warn "压缩" "缺少 $(cn_list "${miss# }")。离线迁移默认使用 lz4，在线迁移默认使用 zstd。可用 --fix 安装"
	case $miss in *zstd*) need zstd zstd ;; esac
	case $miss in *lz4*) need lz4 lz4 ;; esac
fi

if have qemu-system-x86_64 || have qemu-system-x86; then pass "启动测试" "qemu 已安装，可在切换前验证新系统能否启动"
else warn "启动测试" "缺少 qemu，无法在切换前验证新系统能否启动。可用 -o boottest=0 跳过该步骤"; need qemu qemu-system-x86; fi

# --- 网络 --------------------------------------------------------------------
gw=$(ip route show default 2>/dev/null | awk '/default/ { print $3; exit }')
if [ -n "$gw" ]; then pass "默认路由" "网关 $gw"
else fail "默认路由" "本机没有默认路由，两台主机之间无法通信。请先配置网络"; fi

# 在线安装依赖的三个源。中国大陆境内的网络通常可以访问 Gitee，通常不能访问
# GitHub，因此列表中有三个地址。
# 末尾给出的安装命令使用第一个可访问的地址。管道传入的脚本无法得知自己从哪个
# 地址取到，所以出处不作为依据，只按本机此刻能否连通来选。
src=
if have curl || have wget; then
	reach=; unreach=; i=0
	for b in "https://gitee.com" "https://cdn.jsdelivr.net" "https://raw.githubusercontent.com"; do
		h=${b#https://}
		i=$((i + 1))
		spin_start "检查下载源 $h（$i/3）"
		if have curl; then
			curl -s -o /dev/null -m 6 -w '' "$b" 2>/dev/null && ok=1 || ok=
		else
			wget -q -T 6 -O /dev/null "$b" 2>/dev/null && ok=1 || ok=
		fi
		spin_stop
		if [ -n "$ok" ]; then
			reach="${reach:+$reach、}$h"
			# 只记录第一条，用作安装命令的地址
			if [ -z "$src" ]; then
				case $b in
					https://gitee.com)         src=https://gitee.com/tktogether/migrator/raw/master/tools/get.sh ;;
					https://cdn.jsdelivr.net)  src=https://cdn.jsdelivr.net/gh/tktogether/migrator@master/tools/get.sh ;;
					*)                         src=https://raw.githubusercontent.com/tktogether/migrator/master/tools/get.sh ;;
				esac
			fi
		else
			unreach="${unreach:+$unreach、}$h"
		fi
	done
	if [ -n "$unreach" ] && [ -n "$reach" ]; then
		warn "下载源" "以下地址不可访问：$unreach。安装时使用其余地址"
	elif [ -n "$unreach" ]; then
		warn "下载源" "三个地址均不可访问：$unreach。在线安装无法进行"
	else
		pass "下载源" "$reach 均可访问"
	fi
else
	warn "下载源" "本机既没有 curl 也没有 wget，无法在线获取安装包"
fi

# --- 源端：取得地址后才检查 --------------------------------------------------
# 地址只从三处读取：环境变量、命令行参数、本机上次连接的主机。脚本不扫描网段。
# 首次运行时目标端尚未持有源端的密钥，扫描无法得到可用地址；源端地址是操作者
# 已有的信息，推测该地址会使连接对象不明确。
if [ -z "$DONOR" ]; then
	for f in /run/migrator/state /run/migrator/dry/state; do
		[ -r "$f" ] || continue
		d=$(sed -n 's/^donor\.target=//p' "$f" 2>/dev/null | tail -1)
		[ -n "$d" ] && { DONOR=$d; say "源端地址取自 $f 中上次连接的主机：$DONOR"; break; }
	done
fi

if [ -n "$DONOR" ]; then
	host=${DONOR#*@}; host=${host%%:*}
	port=22
	case $DONOR in *:*) port=${DONOR##*:} ;; esac
	if have ssh; then
		spin_start "连接源端 $host:$port"
		ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
			-p "$port" "$DONOR" true 2>/dev/null && ok=1 || ok=
		spin_stop
		if [ -n "$ok" ]; then
			pass "源端 SSH" "可免密登录 $host:$port"
			os=$(ssh -o BatchMode=yes -o ConnectTimeout=6 -p "$port" "$DONOR" \
				'. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"' 2>/dev/null | tail -1)
			[ -n "$os" ] && pass "源端系统" "$os" || warn "源端系统" "无法读取 /etc/os-release"
			if ssh -o BatchMode=yes -o ConnectTimeout=6 -p "$port" "$DONOR" \
				'test -r /etc/migrator-live-release -o -r /etc/xserver-live-release' 2>/dev/null; then
				pass "源端状态" "已启动到 Live，将按离线迁移处理"
			else
				pass "源端状态" "运行自身系统，将按在线迁移处理，业务可继续运行"
			fi
		else
			fail "源端 SSH" "无法登录 $host:$port。请确认地址与密钥，或执行 ssh-copy-id root@$host"
		fi
	else
		fail "源端 SSH" "本机没有 ssh 客户端"
	fi
else
	warn "源端" "未提供地址，本次只检查了本机。可用 --donor root@10.0.0.9 检查两端"
fi

# --- 结论 --------------------------------------------------------------------
printf '\n'
ui_rule
printf '[migrator-preflight] 共 %d 项检查：%d 项通过，%d 项提醒，%d 项未通过\n' \
	$((n_pass + n_warn + n_fail)) "$n_pass" "$n_warn" "$n_fail"
ui_bar
printf '\n'

# 缺少软件包时只输出一条可直接执行的命令；--fix 才会实际安装，安装后由操作者
# 重新运行本脚本，脚本不隐藏该过程。
# 命令名与软件包名不一定相同：bionic 没有 lz4 包，对应包名为 liblz4-tool；旧发行版
# 的 qemu 包名为 qemu。因此安装前先用 apt-cache 查询候选版本，并保留 apt 的原话。
# 此前该输出被丢弃，只提示网络问题，而实际原因是软件包名不存在。
apt_cand() {   # 给定若干等价包名，输出本机软件源中可安装的那个
	for p in "$@"; do
		apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^(]' && { printf '%s' "$p"; return 0; }
	done
	return 1
}

pkgs=$(echo "$fix_pkgs" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
pkgs=${pkgs% }
# --fix 同时安装 WARN 项对应的软件包（例如仅缺少 qemu），否则只报告 FAIL 项。
if [ -n "$pkgs" ] && { [ "$n_fail" -gt 0 ] || [ -n "$FIX" ]; }; then
	resolved=; missing=; cand=
	if have apt-cache; then
		for p in $pkgs; do
			case $p in
				lz4)             cand=$(apt_cand lz4 liblz4-tool) ;;
				qemu-system-x86) cand=$(apt_cand qemu-system-x86 qemu) ;;
				*)               cand=$(apt_cand "$p") ;;
			esac
			if [ -n "$cand" ]; then resolved="$resolved $cand"; else missing="$missing $p"; fi
		done
		resolved=${resolved# }; missing=${missing# }
	else
		resolved=$pkgs
	fi

	if [ -n "$FIX" ]; then
		[ -n "$missing" ] && say "本机软件源中没有以下软件包，已跳过：$missing"
		if ! have apt-get; then
			say "--fix 只使用 apt-get，本机没有该命令。请手工安装：${resolved:-无}"
			exit 1
		fi
		[ -n "$resolved" ] || { say "没有可自动安装的软件包，其余项目需要手工处理"; exit 1; }
		say "--fix：apt-get install -y $resolved"
		spin_start "安装软件包（apt-get install）"
		log=$(apt-get install -y $resolved 2>&1) && ok=1 || ok=
		spin_stop
		if [ -n "$ok" ]; then
			say "安装完成。请重新运行本脚本确认结果"
		else
			say "apt-get 未完成安装，最后三行输出如下："
			printf '%s\n' "$log" | tail -3 | sed 's/^/    /'
			say "请手工重试：apt-get install -y $resolved"
		fi
		exit 1
	fi

	say "缺失的软件包可用一条命令安装："
	printf '    apt-get install -y %s\n' "${resolved:-$pkgs}"
	say "也可重新运行本脚本并加 --fix，由脚本完成安装"
	[ -n "$missing" ] && say "以下软件包在本机软件源中没有同名包，需要另行处理：$missing"
fi

if [ "$n_fail" -gt 0 ]; then
	say "有 $n_fail 项未通过。这些问题会使迁移失败，请先处理，然后重新运行本脚本"
	exit 1
fi

# --- 下一步 ------------------------------------------------------------------
if ! have migrator && { [ -z "$SELF" ] || [ ! -x "$(dirname "$SELF")/../bin/migrator" ]; }; then
	if [ -n "$src" ]; then
		say "本机尚未安装 migrator。下面的命令使用本机可访问的下载地址："
		printf '    %s\n' "curl -fsSL $src | sh"
	elif have curl || have wget; then
		say "本机尚未安装 migrator，三个下载地址在当前网络下均不可访问。请先解决网络，或把源码树复制到本机后执行 make install"
	else
		say "本机尚未安装 migrator。本机没有 curl 也没有 wget，无法在线安装。可把源码树复制到本机后执行 make install"
	fi
fi

if [ -n "$GO" ]; then
	tty_stdin   # 向导需要读取键盘输入；通过管道运行时把标准输入接回终端
	if have migrator; then
		say "--go：进入迁移向导，源端地址已填入，其余项目照常询问"
		WZ_DONOR=$DONOR exec migrator -w
	elif [ -n "$SELF" ] && [ -r "$SELF" ] && [ -x "$(dirname "$SELF")/../bin/migrator" ]; then
		say "--go：使用源码树中的驱动器进入向导"
		WZ_DONOR=$DONOR exec sh "$(dirname "$SELF")/../bin/migrator" -w
	else
		say "使用 --go 需要先安装 migrator。请执行上面的安装命令，然后重新运行本脚本"
		exit 2
	fi
fi

if [ -n "$DONOR" ]; then
	say "两端检查完成，可以继续。下一步命令："
	printf '    交互式运行：migrator -w\n'
	printf '    指定目标磁盘运行：migrator -d /dev/sdX %s\n' "$DONOR"
else
	say "本机检查完成。指定源端地址（--donor root@IP）后可检查完整链路"
fi
exit 0
