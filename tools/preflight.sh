#!/bin/sh
# preflight.sh — 一条命令回答「现在能不能开始」，然后给出（或直接执行）下一步。
#
# 一个文件，不装任何东西，也不需要仓库：直接取来就职。
#
#   sh -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/tktogether/migrator@master/tools/preflight.sh)"
#   sh preflight.sh --go            没有 FAIL 就直接进迁移向导
#   sh preflight.sh --fix           顺手把缺的包装上（apt-get install）
#   sh preflight.sh --check         同默认，但明确不装任何东西（给 get.sh --check 用）
#
# 三种取法，哪个通用哪个（国内常用 Gitee）：
#   curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/preflight.sh | sh
#   curl -fsSL https://cdn.jsdelivr.net/gh/tktogether/migrator@master/tools/preflight.sh | sh
#   或者 sh tools/preflight.sh（仓库已在手边）
#
# 注意管道：<url> | sh 时 stdin 是脚本本身，向导读不到你的键盘。要 --go 就用
# 上面 sh -c "$(curl ...)" 那种写法，或者先落盘再跑。
#
# 源机地址按这个顺序取，取到就用，取不到就只查本机：
#   MIGRATOR_DONOR 环境变量 → 参数 → /run/migrator/state 里上次连过的那台
# 不猜：源机地址是操作者唯一确定的信息，扫描网段既不靠谱（第一次跑时收端
# 还没有源机的密钥）又会在别人的机房里发出噪声。
#
# 结果三档：
#   PASS  已满足
#   WARN  不挡路，但会让某一步变慢或不可用（例如不在 Live 里：能出计划，不能执行）
#   FAIL  这样跑下去会失败，先处理
# exit: 0 没有 FAIL · 1 有 FAIL · 2 探测本身跑不起来
#
# 默认只读：不挂载、不写盘、不改网络、不装东西。--fix 与 --go 是仅有的两个
# 会动手的开关，而且都在全部检查之后才生效。查源机只用 ssh 跑只读命令。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

usage() {
	cat <<'EOF'
用法：preflight.sh [--go] [--fix] [--donor HOST] [root@]HOST[:PORT]

  默认只查，什么都不装、不写、不动网络；一个文件就能跑，不需要安装工具。
  --go          检查通过后直接进迁移向导（源机已填好，其余照问）
  --fix         把缺的包装上（apt-get install -y），然后重跑本脚本
  --check       明确「只检查」：装了 migrator 也不进向导（默认行为，给脚本用）
  --donor HOST  指定源机，跳过自动查找
  -h, --help    这一段

不给源机也行：先看 /run/migrator/state 里上次连过的那台；没有就只查本机。
PATH 里没有 migrator 时，会打印装它的那一行。
EOF
}

GO=; FIX=; DONOR=${MIGRATOR_DONOR:-}
while [ $# -gt 0 ]; do
	case $1 in
		--go|-g)      GO=1 ;;
		--fix|-f)     FIX=1 ;;
		--check|-c)   GO= ;;                       # 默认已经是只查；写出来让调用方放心
		--donor)      DONOR=${2:-}; [ -n "$DONOR" ] || { echo "--donor 需要一个地址" >&2; exit 2; }; shift ;;
		--donor=*)    DONOR=${1#*=} ;;
		-h|--help)    usage; exit 0 ;;
		--)           shift; continue ;;
		-*)           echo "不认识的选项：$1" >&2; usage >&2; exit 2 ;;
		*)            DONOR=$1 ;;
	esac
	shift
done

n_pass=0; n_warn=0; n_fail=0; fix_pkgs=
# 列不按宽度对齐：中文一个字占两个显示列、三个字节，printf 的 %-28s 会把它排歪。
# 结果放最前（纯 ASCII），检查项与说明跟在后面，读起来自然对齐。
row()  { printf '  %-4s %s  %s\n' "$2" "$1" "$3"; }
pass() { n_pass=$((n_pass + 1)); row "$1" PASS "$2"; }
warn() { n_warn=$((n_warn + 1)); row "$1" WARN "$2"; }
fail() { n_fail=$((n_fail + 1)); row "$1" FAIL "$2"; }
need() { fix_pkgs="$fix_pkgs $2"; }   # 记下补这个命令要装的包

have() { command -v "$1" >/dev/null 2>&1; }
say()  { echo "[migrator-preflight] $*"; }

# 用管道跑时 stdin 就是脚本本身，而且已经读完：问话会立刻读到 EOF。有终端
# 就从 /dev/tty 接回来，这样 "curl ... | sh -s -- --go" 也能回答问题。
# 判断放在子 shell 里试探：redirection 失败在 dash 里会让 exec 直接退出整个
# 脚本，[ -r /dev/tty ] 又会在容器与 Git Bash 里给出假的「有」。
can_ask()   { [ -t 0 ] || ( : < /dev/tty ) 2>/dev/null; }
tty_stdin() { [ -t 0 ] && return 0; can_ask && exec 0</dev/tty; return 0; }

echo "[migrator-preflight] 收端 $(hostname 2>/dev/null || echo '?')"
printf '  %-4s %s\n' "结果" "检查项 — 说明"
printf '  %s\n' "----------------------------------------------------------------------------"

# --- 身份与运行环境 ----------------------------------------------------------
if [ "$(id -u)" = 0 ]; then pass "运行身份" "root"
else fail "运行身份" "不是 root：分区、挂载、chroot 都需要它，请用 sudo 或 root 重跑"; fi

if [ -r /etc/migrator-live-release ] || [ -r /etc/xserver-live-release ]; then
	pass "迁移 Live" "已在本项目的 Live 里"
else
	warn "迁移 Live" "不在 Live 里：可以出计划（-s plan）并审阅，执行要进 Live"
fi

mem=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem:-0}" -ge 3072 ]; then pass "内存" "${mem} MiB：够 precheck 与 boottest"
elif [ "${mem:-0}" -ge 1536 ]; then warn "内存" "${mem} MiB：precheck 会被自动关掉（-o precheck=1 可强开）"
else fail "内存" "${mem:-?} MiB：低于 1.5G，收尾的 chroot 与拆包都容易失败"; fi

cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
if [ "${cpus:-1}" -ge 2 ]; then pass "CPU" "$cpus 核：压缩与校验有余量"
else warn "CPU" "$cpus 核：在线迁移的压缩级别会被压低，冻结窗口会变长"; fi

# --- 工具本身 ----------------------------------------------------------------
if have migrator; then
	v=$(migrator -V 2>/dev/null | head -1)
	pass "工具" "${v:-migrator 已在 PATH 里}"
elif [ -r "$(dirname "$0")/../bin/migrator" ] && [ -n "$0" ] && [ -r "$0" ]; then
	pass "工具" "在源码树里：$0"
else
	warn "工具" "PATH 里没有 migrator：先装（本脚本末尾会打印那一行）"
fi

# --- 目标磁盘 ----------------------------------------------------------------
if have lsblk; then
	disks=$(lsblk -dnpo NAME,SIZE,TYPE 2>/dev/null | awk '$3 == "disk" { printf "%s(%s) ", $1, $2 }')
	if [ -z "$disks" ]; then fail "目标磁盘" "lsblk 看不到任何整盘"; need lsblk util-linux
	else pass "目标磁盘" "$disks"; fi
else
	fail "目标磁盘" "没有 lsblk：装 util-linux，否则无法判定目标盘"; need lsblk util-linux
fi

# a disk that is in use cannot be the target, and finding that out now is the
# whole point of this script
busy=
if have pvs; then busy=$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | tr '\n' ' '); fi
if have swapon; then busy="$busy $(swapon --noheadings -o NAME 2>/dev/null | tr -d ' ' | tr '\n' ' ')"; fi
if [ -n "$(echo "$busy" | tr -d ' ')" ]; then
	warn "被占用的设备" "$(echo "$busy" | tr -s ' ')：这些是 LVM/swap 成员，不能当目标盘（工具会拒绝，这里先提示）"
else
	pass "被占用的设备" "没有 LVM/swap 占着待选盘"
fi

# --- 依赖 --------------------------------------------------------------------
miss=
for t in tar gzip sha256sum awk sed findmnt lsblk blkid; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "基础工具" "都在"
else
	fail "基础工具" "缺：${miss# }"
	case $miss in *tar*) need tar tar ;; esac
	case $miss in *gzip*) need gzip gzip ;; esac
	case $miss in *sha256sum*) need sha256sum coreutils ;; esac
	case $miss in *awk*) need awk gawk ;; esac
	case $miss in *findmnt*|*lsblk*|*blkid*) need util-linux util-linux ;; esac
fi

miss=
for t in partclone.ext4 mkfs.ext4 e2fsck tune2fs; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "ext4 工具链" "都在"
else
	fail "ext4 工具链" "缺：${miss# }（--fix 会装上 partclone 与 e2fsprogs）"
	case $miss in *partclone*) need partclone partclone ;; esac
	case $miss in *mkfs*|*e2fsck*|*tune2fs*) need e2fsprogs e2fsprogs ;; esac
fi

miss=
for t in zstd lz4; do have "$t" || miss="$miss $t"; done
if [ -z "$miss" ]; then pass "压缩" "zstd 与 lz4 都在"
else
	warn "压缩" "缺：${miss# }（离线默认用 lz4，在线默认 zstd；--fix 会装上）"
	case $miss in *zstd*) need zstd zstd ;; esac
	case $miss in *lz4*) need lz4 lz4 ;; esac
fi

if have qemu-system-x86_64 || have qemu-system-x86; then pass "boottest" "qemu 在：切换前可以先试启动新系统"
else warn "boottest" "没有 qemu：无法在切换前验证新系统能否引导（-o boottest=0 跳过）"; need qemu qemu-system-x86; fi

# --- 网络 --------------------------------------------------------------------
gw=$(ip route show default 2>/dev/null | awk '/default/ { print $3; exit }')
if [ -n "$gw" ]; then pass "默认路由" "网关 $gw"
else fail "默认路由" "没有默认路由：两机之间怎么走？先配好网络"; fi

# the mirrors a one-line install depends on; a Chinese network usually reaches
# gitee and often not github, which is exactly why the list has three entries
if have curl || have wget; then
	reach=
	for b in "https://gitee.com" "https://cdn.jsdelivr.net" "https://raw.githubusercontent.com"; do
		h=${b#https://}
		if have curl; then
			curl -s -o /dev/null -m 6 -w '' "$b" 2>/dev/null && reach="$reach $h=通" || reach="$reach $h=不通"
		else
			wget -q -T 6 -O /dev/null "$b" 2>/dev/null && reach="$reach $h=通" || reach="$reach $h=不通"
		fi
	done
	case $reach in *不通*) warn "下载源" "$reach（不通的那个会被自动跳过）" ;; *) pass "下载源" "$reach" ;; esac
else
	warn "下载源" "没有 curl 也没有 wget：无法在线取工具包"
fi

# --- 源机：有地址才查 --------------------------------------------------------
# 地址只从这三处来：环境变量、参数、这台机器上次连过的那台。不做网段扫描——
# 第一次跑的时候收端还没有源机的密钥，扫也扫不出来；而源机地址是操作者手上
# 本来就有的东西，猜它只会让人怀疑工具到底连上了谁。
if [ -z "$DONOR" ]; then
	for f in /run/migrator/state /run/migrator/dry/state; do
		[ -r "$f" ] || continue
		d=$(sed -n 's/^donor\.target=//p' "$f" 2>/dev/null | tail -1)
		[ -n "$d" ] && { DONOR=$d; say "源机：用上次连过的 $DONOR（$f 记着）"; break; }
	done
fi

if [ -n "$DONOR" ]; then
	host=${DONOR#*@}; host=${host%%:*}
	port=22
	case $DONOR in *:*) port=${DONOR##*:} ;; esac
	if have ssh; then
		if ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
			-p "$port" "$DONOR" true 2>/dev/null; then
			pass "源机 ssh" "$host:$port 可登录（免密或已装密钥）"
			os=$(ssh -o BatchMode=yes -o ConnectTimeout=6 -p "$port" "$DONOR" \
				'. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"' 2>/dev/null | tail -1)
			[ -n "$os" ] && pass "源机系统" "$os" || warn "源机系统" "读不到 /etc/os-release"
			if ssh -o BatchMode=yes -o ConnectTimeout=6 -p "$port" "$DONOR" \
				'test -r /etc/migrator-live-release -o -r /etc/xserver-live-release' 2>/dev/null; then
				pass "源机状态" "已在 Live 里：离线迁移"
			else
				pass "源机状态" "在跑自己的系统：在线迁移（可在业务不停的情况下复制）"
			fi
		else
			fail "源机 ssh" "$host:$port 连不上或没有免密：ssh-copy-id root@$host，或用 -i 指定密钥"
		fi
	else
		fail "源机 ssh" "本机没有 ssh 客户端"
	fi
else
	warn "源机" "没找到：只查了本机。给地址即可（preflight.sh root@10.0.0.9），或用 --donor"
fi

# --- 结论 --------------------------------------------------------------------
echo "----------------------------------------------------------------------------"
printf '[migrator-preflight] %d 项：%d PASS · %d WARN · %d FAIL\n' \
	$((n_pass + n_warn + n_fail)) "$n_pass" "$n_warn" "$n_fail"

# 缺包时只打印一条能直接粘的命令；--fix 才真装，装完让人重跑，不藏在脚本里
pkgs=$(echo "$fix_pkgs" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
if [ -n "$pkgs" ] && [ "$n_fail" -gt 0 ]; then
	if [ -n "$FIX" ]; then
		if have apt-get; then
			say "--fix：apt-get install -y ${pkgs}"
			if apt-get install -y $pkgs >/dev/null 2>&1; then
				say "装好了，重跑一次本脚本确认"
			else
				say "apt 没装成：多半是网络或源的问题，手工装：apt-get install -y ${pkgs}"
			fi
		else
			say "--fix 只会用 apt-get，这台机器没有：请手工装 ${pkgs}"
		fi
		exit 1
	fi
	say "缺的包一条命令装：apt-get install -y ${pkgs}（或重跑本脚本加 --fix）"
fi

if [ "$n_fail" -gt 0 ]; then
	echo "[migrator-preflight] 有 $n_fail 项会直接导致失败，先处理上面的 FAIL 再开始。"
	exit 1
fi

# --- 下一步：一个命令 --------------------------------------------------------
if ! have migrator && [ ! -x "$(dirname "$0")/../bin/migrator" ]; then
	echo "[migrator-preflight] 工具还没装，一条命令装好（三个镜像自动回落）："
	echo "    curl -fsSL https://cdn.jsdelivr.net/gh/tktogether/migrator@master/get.sh | sh"
fi

if [ -n "$GO" ]; then
	tty_stdin   # 向导要读键盘；管道进来时把 stdin 接回终端
	if have migrator; then
		say "--go：进迁移向导（源机已填好，其余照问）"
		WZ_DONOR=$DONOR exec migrator -w
	elif [ -n "$0" ] && [ -r "$0" ] && [ -x "$(dirname "$0")/../bin/migrator" ]; then
		say "--go：用源码树里的驱动器进向导"
		WZ_DONOR=$DONOR exec sh "$(dirname "$0")/../bin/migrator" -w
	else
		say "--go 需要先装好工具：跑上面那条安装命令，再 preflight.sh --go"
		exit 2
	fi
fi

if [ -n "$DONOR" ]; then
	echo "[migrator-preflight] 可以继续：migrator -w（向导，源机填 $DONOR），或 migrator -d /dev/sdX $DONOR"
else
	echo "[migrator-preflight] 收端看起来可用；把源机地址也给它（--donor root@IP），才能判断整条链路。"
fi
exit 0
