#!/bin/bash
# live-boot.sh：把本机送进迁移 Live。执行分三段，其间问三项设置、停两次确认。
#
#   1. 预检。只读检查，逐项打印结果。有未通过项时停止，此时本机没有改动。
#      通过后问三项设置：现有产物怎么处置，私钥是否重新生成，能不能用密码登录，
#      sshd 监听哪个端口。产物目录为空时只剩后两项。
#   2. 构建。取得确认后安装依赖、下载源码树、构建 Live，并打印私钥。选择直接使用
#      现有产物时跳过这一段。
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
# 因为写入引导项会改变下次开机的去处，而此时登录信息已经生成，需要先交到操作者手上。
#
# 现有产物（D69、D70）：产物目录中已有完整的上一次构建时，第一问给出三条路——直接
# 使用它并跳过构建，重新构建并替换，重新构建并把现有目录改名保留。私钥另有一问：
# 继续使用，或重新生成。重新生成后，之前打印的私钥对新的镜像无效。
#
# 登录方式（D66、D67）：能不能用密码登录，sshd 监听哪个端口。回车取方括号中的默认值，
# 命令行给了的取值不再追问，-y 则一律取默认值。密码只提供随机生成一项：在问答里手打
# 密码没有回显，敲错一个字符就进不去。
#
# 取值在构建时写入镜像。端口写在引导参数里，本机任何用户都能读到，它减少被扫描
# 命中的次数，不是访问控制；密码由同一份镜像构建出的每台机器共用，提供的是访问
# 而不是保密。
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
OLD_ART=; OLD_FULL=; WHAT=; USE_OLD=; KEEP_OLD=; NEW_KEY=
OUT_AVAIL=0; OUT_NEED=0; OUT_OLD_SIZE=0
SSH_PORT=22; SSH_PW=; PORT_WANT=; PW_WANT=; PORT_SET=
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
  构建不需要第二台机器：本机现有系统就是构建机。产物目录中已有完整的上一次
  构建时，可以选择直接使用它，跳过构建。

  执行分三段，其间问两到三项设置、停两次确认：
    1. 预检。只读检查，逐项打印结果。有未通过项时停止，本机没有改动。
    2. 构建。取得确认后安装依赖、下载源码树、构建 Live，并打印登录信息。
       选择直接使用现有产物时跳过这一段。
    3. 引导。取得确认后写入引导项并重启。

  预检通过后先问两项：能不能用密码登录，sshd 监听哪个端口。直接回车取方括号
  中的默认值。命令行给了的取值不再追问。产物目录中已有完整的上一次构建时，
  这两问之前还有一问：直接使用这份产物，还是重新构建。

  -i SPEC      Live 的静态地址，格式 IP/前缀,网关,DNS
               例：192.168.1.50/24,192.168.1.1,114.114.114.114
               省略时取本机当前的地址、默认网关与 DNS；取不到时问一次
  -p PORT      Live 的 sshd 端口。默认 22；已开启密码登录时默认随机。写
               random 则从 20000 至 60000 之间选取，并在登录信息中打印
  -P PASS      为 root 设置密码，允许密码登录。写 random 则随机生成并在登录
               信息中打印。省略时只接受私钥
  -m PROFILE   slim（默认，不含 qemu，体积小）或 full（含 qemu，可用于启动测试）
  -s DIR       使用 DIR 中已有的源码树，不从网络下载
  -b           重新构建，并替换产物目录中的现有产物
  -k           重新构建，并把现有产物的目录改名保留
  -r           重新构建时生成新的私钥，不再使用现有的私钥
  -y           不提问也不确认，取值全用默认，一直执行到重启
  -n           只做预检并打印后续步骤，不改动本机，也不提问
  -h           显示本说明

端口与密码在构建时写入镜像，改动需要重新构建。同一份产物构建出的每台机器共用
这个密码，因此它提供的是访问，不是保密。端口写在引导参数里，本机的任何用户都能
读到，它降低被扫描命中的概率，但不是访问控制。两者都不改变「私钥是进入 Live 的
凭据」这一条。

预检逐项检查：
  root 权限；本机未处于迁移 Live；Debian 或 Ubuntu 系；x86_64；内存至少 1536 MiB；
  存在可放置 Live 的非 LVM 分区且可用空间至少 3 GiB；构建依赖是否齐备；
  源码树是否可取；网络参数能否确定；本机是否已有迁移 Live 的引导项与产物。

产物目录中已有完整的上一次构建时，设置阶段的第一问可以选择直接使用它，跳过构建。
选择重新构建时，现有产物可以被替换，也可以改名保留；私钥可以继续使用，也可以
重新生成。-y 不问这些，按默认值处理：直接使用现有的产物；没有现存产物，或给了
-b、-k、-r、-P 时重新构建。

构建完成后本机会重启。重启后：
  ssh -i <私钥> -p <端口> root@<地址>   私钥、端口与密码在构建结束时打印
  cat /etc/migrator-live-release        确认已进入 Live

本脚本不做自己的事：构建交给 rig/build-live.sh，写引导项交给 tools/live-entry.sh。
放弃这次切换、回到原系统：bash <产物目录>/live-entry.sh -r

环境变量：
  LIVE_MIRROR    构建时使用的 Debian 镜像，默认 http://deb.debian.org/debian
  RIG_OUT        构建产物目录，默认 /var/tmp/migrator-live
  MIGRATOR_REF   读取的分支或标签，默认 master
EOF
}

while getopts "i:p:P:m:s:bkrRynh" o; do
	case $o in
		i) SPEC=$OPTARG ;;
		p) SSH_PORT=$OPTARG; PORT_SET=1 ;;
		P) SSH_PW=$OPTARG ;;
		m) PROFILE=$OPTARG ;;
		s) TREE=$OPTARG ;;
		b) WHAT=rebuild ;;
		k) WHAT=keep ;;
		r) NEW_KEY=1 ;;
		y) YES=1 ;;
		n) DRY=1 ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done
case $PROFILE in slim|full) ;; *) die 2 "未知的 PROFILE：$PROFILE（可选 slim 或 full）" ;; esac
TREE=${TREE%/}
# -k 是「重新构建并保留」的简写。没有现有产物时保留无从谈起，设置段会把它清掉。
case ${WHAT:-} in keep) KEEP_OLD=1 ;; esac

# 端口：数字或 random。-p slim 是上一版的 profile 写法，给出改法而不是只说错误。
case $SSH_PORT in
	random) PORT_WANT=random; SSH_PORT= ;;
	slim|full) die 2 "profile 改用 -m，例如 -m $SSH_PORT。-p 现在表示 sshd 端口" ;;
	''|*[!0-9]*) die 2 "端口 $SSH_PORT 不是数字。可写 1 到 65535 之间的数字，或写 random" ;;
	*) [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] ||
		die 2 "端口 $SSH_PORT 超出范围。可写 1 到 65535 之间的数字，或写 random" ;;
esac

# 密码：只能写 random 或给一个字面值。含换行的值无法通过命令行传入。
case $SSH_PW in
	random) PW_WANT=random; SSH_PW= ;;
	*'
'*) die 2 "密码不能包含换行" ;;
esac

rand_port() {
	local p=
	if have shuf; then p=$(shuf -i 20000-60000 -n 1 2>/dev/null); fi
	case $p in
		''|*[!0-9]*) p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40001 )) ;;
	esac
	printf '%s\n' "$p"
}
# 去掉容易混淆的字符，避免抄写时看错。
rand_pass() {
	local p=
	p=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom 2>/dev/null | head -c 20)
	[ -n "$p" ] || p="mig$(($RANDOM))$((RANDOM))x"
	printf '%s\n' "$p"
}

# =============================================================================
# 交互：只问预检给不出取值的地方。下面直到「交互结束」为止自成一体，只依赖
# can_ask、die 与 say，tests/cases/live-boot.sh 会把这一段单独取出执行。
#
# 三条通道各管一件事：提问与读回答都接回 /dev/tty；回答的值走标准输出，供
# $( ) 取得；提示与拒绝走标准错误，既能显示在终端，也不会混进那个值。
# =============================================================================
# 是否开启了密码登录。随机密码在构建时才生成，因此问答与预检阶段凭 PW_WANT 判断。
want_pw() { [ -n "$SSH_PW" ] || [ -n "$PW_WANT" ]; }

# 对端口的说法。随机端口在构建时才确定，因此问答阶段不给出数字。
port_text() {
	case $PORT_WANT in
		random) printf '%s' "随机端口，构建时选取" ;;
		*)      printf '%s' "$SSH_PORT" ;;
	esac
}

# 读一条回答。经管道运行时标准输入是脚本本身，提问与回答都必须接回终端，因此
# 提示写到 /dev/tty，标准输出只用来返回答案，免得被 $( ) 一起收走。
ask() {
	local a=
	printf '%s' "$1" > /dev/tty
	read -r a < /dev/tty 2>/dev/null || a=
	[ -n "$a" ] || a=$2
	printf '%s\n' "$a"
}

# 编号选择。空回答取默认编号；回答不在编号里就重问，三次仍不认识则放弃，
# 由调用方决定是报错还是取默认。
pick() {
	local p=$1 d=$2 ok=$3 a n=0
	while [ "$n" -lt 3 ]; do
		n=$((n + 1))
		a=$(ask "$p" "$d")
		case " $ok " in
			*" $a "*) printf '%s\n' "$a"; return 0 ;;
		esac
		printf '  只能填 %s\n' "$(printf '%s' "$ok" | sed 's/ / 或 /g')" >&2
	done
	return 1
}

need_tty() {
	can_ask && return 0
	die 2 "没有可交互的终端，无法询问$1。请用 -i、-p、-P、-b、-k 指定取值，并加 -y 重新运行"
}

# 端口号本身。空回答表示放弃指定、改回随机；范围之外的回答重问，三次后放弃。
ask_num() {
	local n=0 p
	while [ "$n" -lt 3 ]; do
		n=$((n + 1))
		p=$(ask "  端口号（1 至 65535，回车取随机）：" "")
		case $p in
			'') printf '\n'; return 0 ;;
			*[!0-9]*) ;;
			*) [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && printf '%s\n' "$p" && return 0 ;;
		esac
		printf '  端口是 1 至 65535 之间的数字\n' >&2
	done
	die 2 "没有取得端口。可用 -p PORT 指定"
}

# 地址：预检探测不到时补问。这一项没有默认值可给，因此空回答只重问。
ask_spec() {
	local n=0
	while [ -z "$SPEC" ]; do
		n=$((n + 1))
		[ "$n" -le 3 ] || die 2 "没有取得网络参数。请用 -i 指定，格式为 IP/前缀,网关,DNS"
		SPEC=$(ask "  地址,网关,DNS：" "")
		case $SPEC in
			*,*,*) ;;
			*)
				say "  格式为 IP/前缀,网关,DNS，例如 192.168.1.50/24,192.168.1.1,114.114.114.114"
				SPEC=
				;;
		esac
	done
}

# 现有产物缺什么。可用的判据不是「目录里有文件」，而是引导需要的五样都在：
# 三份产物、写引导项的脚本、能登录的私钥。缺一样就不能直接使用。预检与设置
# 都用这一个判据，免得表格说完整、问答说不完整。
old_missing() {
	local f m=
	for f in live/filesystem.squashfs vmlinuz-live initrd-live.img live-entry.sh rig_ed25519; do
		[ -s "${OUT:-}/$f" ] || m="$m $f"
	done
	printf '%s' "${m# }"
}
old_full() { [ -z "$(old_missing)" ]; }

# 能否在保留现有产物的前提下重新构建：两个目录同时占空间，因此按两份算。
# 预检把可用空间与两份的需求都算好放在 OUT_AVAIL、OUT_NEED、OUT_OLD_SIZE 里。
can_keep() {
	[ "${OUT_AVAIL:-0}" -ge $(( ${OUT_NEED:-0} + ${OUT_OLD_SIZE:-0} )) ]
}

# 保留现有产物：目录改名，在原位置新建。改名本身不占空间，但两个目录随后同时
# 占盘，因此能不能这样做由 can_keep 判断。私钥随目录一起移走，选择继续使用时
# 复制回来，rig/build-live.sh 会直接使用它。
stash_old() {
	local prev
	prev=$OUT.$(date +%Y%m%d-%H%M%S)
	say "现有产物的目录改名为 $prev"
	mv "$OUT" "$prev" || die "无法移动现有产物的目录：$OUT"
	mkdir -p "$OUT" || die "无法创建产物目录：$OUT"
	if [ -z "${NEW_KEY:-}" ] && [ -s "$prev/rig_ed25519" ] && [ -s "$prev/rig_ed25519.pub" ]; then
		cp -p "$prev/rig_ed25519" "$prev/rig_ed25519.pub" "$OUT/" || die "无法复制私钥：$prev"
	fi
}

# 现有产物的处置。三选一：直接使用，重新构建并保留，重新构建并替换。
# 空间不够时不给「保留」，产物不完整时不给「直接使用」。默认值随可用项变化：
# 能直接使用时它是第一项，也是默认项。
ask_old() {
	local c=
	[ -n "${OLD_ART:-}" ] || return 0
	case ${WHAT:-} in rebuild|keep) return 0 ;; esac

	if old_full; then
		if can_keep; then
			c=$(pick "  上一次的产物  1 直接使用  2 重新构建，保留现有产物  3 重新构建，替换现有产物   [1]：" 1 "1 2 3") ||
				die 2 "没有取得选择。可以直接使用，或用 -b 重新构建并替换、用 -k 重新构建并保留"
			case $c in
				1) USE_OLD=1 ;;
				2) KEEP_OLD=1 ;;
			esac
		else
			c=$(pick "  上一次的产物  1 直接使用  2 重新构建，替换现有产物（可用空间不足以同时保留）   [1]：" 1 "1 2") ||
				die 2 "没有取得选择。可以直接使用，或用 -b 重新构建并替换"
			[ "$c" = 1 ] && USE_OLD=1
		fi
	elif can_keep; then
		c=$(pick "  上一次的产物  内容不完整，不能直接使用。1 重新构建，保留现有产物  2 重新构建，替换现有产物   [2]：" 2 "1 2") ||
			die 2 "没有取得选择。可用 -k 重新构建并保留，或用 -b 重新构建并替换"
		[ "$c" = 1 ] && KEEP_OLD=1
	else
		say "  上一次的产物  内容不完整，不能直接使用。可用空间不足以同时保留，本次重新构建并替换"
	fi
	return 0
}

# 私钥：重建时才有选择。继续使用现有的私钥，上一次打印的那份对新镜像仍然有效；
# 重新生成后，之前打印的私钥不能用于新镜像。直接使用现有产物时不必问。
ask_key() {
	local c=
	[ -n "${USE_OLD:-}" ] && return 0
	[ -n "${NEW_KEY:-}" ] && return 0
	[ -s "${OUT:-}/rig_ed25519" ] || return 0
	c=$(pick "  私钥          1 继续使用现有私钥  2 重新生成私钥   [1]：" 1 "1 2") ||
		die 2 "没有取得选择。可以继续使用现有私钥，或用 -r 重新生成"
	[ "$c" = 2 ] && NEW_KEY=1
	return 0
}


# 登录凭据：-P 给了就不问。只提供随机密码：这里手打没有回显，敲错一个字符就
# 进不去，而随机值由脚本生成、随登录信息一起打印。使用现有产物时不问这一项：
# 密码在构建时写入镜像，没有重新构建就没有地方可写。
ask_login() {
	local c=
	[ -n "${USE_OLD:-}" ] && return 0
	if [ -n "$SSH_PW" ] || [ -n "$PW_WANT" ]; then return 0; fi
	c=$(pick "  登录方式  1 只用私钥  2 私钥加密码   [1]：" 1 "1 2") ||
		die 2 "没有取得登录方式。可用 -P random 直接指定密码登录"
	[ "$c" = 2 ] && PW_WANT=random
	return 0
}

# 端口：-p 给了就不问。已经开启密码登录时默认随机，22 是常规扫描的第一站。
ask_port() {
	local c= d= p=
	if [ -n "$PORT_SET" ]; then return 0; fi
	if want_pw; then d=1; else d=2; fi
	c=$(pick "  端口      1 随机选取  2 22  3 指定   [$d]：" "$d" "1 2 3") ||
		die 2 "没有取得端口。可用 -p PORT 指定"
	case $c in
		1) PORT_WANT=random; SSH_PORT= ;;
		2) PORT_WANT=; SSH_PORT=22 ;;
		3)
			p=$(ask_num)
			if [ -n "$p" ]; then
				PORT_WANT=; SSH_PORT=$p
			else
				PORT_WANT=random; SSH_PORT=
			fi
			;;
	esac
	return 0
}

# 本次采用的取值。问答之后打印，是操作者改动本机之前最后一次核对的机会。
print_settings() {
	local lead=${1:-本次}
	if [ -n "${USE_OLD:-}" ]; then
		say "  $lead：直接使用 ${OUT:-} 中现有的产物，不重新构建"
		say "        登录方式为私钥，sshd 监听 $(port_text)"
		say "        密码在构建时写入镜像。上一次构建如果设置过密码，以当时打印的那份为准"
		return 0
	fi
	if want_pw; then
		say "  $lead：私钥与密码均可登录，sshd 监听 $(port_text)"
		if [ "$SSH_PORT" = 22 ]; then
			say "        密码登录会出现在常规扫描中。改用非 22 端口可以减少这类尝试"
		fi
		say "        密码在构建时随机生成，随登录信息一起打印"
	else
		say "  $lead：只接受私钥，sshd 监听 $(port_text)"
	fi
	if [ -n "${OLD_ART:-}" ]; then
		if [ -n "${KEEP_OLD:-}" ]; then
			say "        现有产物：目录改名保留，重新构建的产物写入 ${OUT:-}"
		else
			say "        现有产物：重新构建完成后替换，旧文件不再保留"
		fi
	fi
	if [ -s "${OUT:-}/rig_ed25519" ]; then
		if [ -n "${NEW_KEY:-}" ]; then
			say "        私钥：重新生成，之前打印的私钥不能用于新的镜像"
		else
			say "        私钥：继续使用，之前打印的私钥对新的镜像有效"
		fi
	fi
}

ask_settings() {
	need_tty "现有产物、私钥、登录方式与端口"
	say ""
	rule
	say "  设置（直接回车取方括号中的默认值）"
	say ""
	if [ -z "$SPEC" ]; then
		say "  地址      无法自动确定，需要手工指定"
		ask_spec
	fi
	ask_old
	ask_key
	ask_login
	ask_port
	print_settings
}
# ================================ 交互结束 ===================================

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

# 已有产物。判据是「引导要用的五样都在」：三份产物、写引导项的脚本、能登录的私钥。
# 齐全时本次可以直接使用它并跳过构建，因此放在构建依赖与源码树之前判断。
old_size=0
miss=
if [ -f "$OUT/live/filesystem.squashfs" ]; then
	OLD_ART=1
	miss=$(old_missing)
	[ -z "$miss" ] && OLD_FULL=1
	old_size=$(du -sb "$OUT" 2>/dev/null | awk '{ print $1 }')
	case ${old_size:-} in ''|*[!0-9]*) old_size=0 ;; esac
fi
OUT_AVAIL=$avail; OUT_NEED=$need; OUT_OLD_SIZE=$old_size
if [ -n "$OLD_ART" ] && [ -z "$OLD_FULL" ]; then
	warn "已有产物" "$OUT 中有上一次构建的产物，但内容不完整（缺少 $(cn_list "$miss")）。不能直接使用"
elif [ -n "$OLD_FULL" ]; then
	warn "已有产物" "$OUT 中有上一次构建的完整产物。设置阶段可以直接使用它，跳过构建"
else
	pass "已有产物" "$OUT 尚无产物。本次需要重新构建"
fi

if [ "$avail" -ge "$need" ]; then
	if [ -n "$OLD_ART" ]; then
		pass "产物空间" "$out_at 有 $(iec "$avail") 可用。替换现有产物需要 $(iec "$need")，保留现有产物需要 $(iec $((need + old_size)))"
	else
		pass "产物空间" "$out_at 有 $(iec "$avail") 可用，需要 $(iec "$need")"
	fi
else
	fail "产物空间" "$out_at 只有 $(iec "$avail") 可用，需要 $(iec "$need")。可用 RIG_OUT 指定其他目录"
fi

# --- 构建依赖 ----------------------------------------------------------------
# 依赖与源码树只在重新构建时用得上。已经有一份完整产物时，这两项降为提醒：否则
# 只想使用现有产物的人会被与本次无关的条件挡在预检之外。选定了重新构建，两项在
# 执行阶段仍然会被挡住，报错的地方是 apt 与下载。
gate() {
	if [ -n "$OLD_FULL" ]; then
		warn "$1" "$2（选择重新构建时才需要）"
	else
		fail "$1" "$2"
	fi
}
# 后端决定装哪个包：有 mmdebstrap 就用它（快，无特权也能跑），没有就装 debootstrap。
# mmdebstrap 只存在于 Ubuntu 的 universe 源里，精简镜像常常没有；两者在真 root 下
# 产出同一个 minbase 树，rig/build-live.sh 自带这条回退（D68）。debootstrap 在
# Debian 与 Ubuntu 的主源里都有，因此是「装一个一定能装上」的那条路。
pkgs=
if have mmdebstrap; then
	BACKEND=mmdebstrap; BACKEND_NOTE=
else
	BACKEND=debootstrap; BACKEND_NOTE="（本机没有 mmdebstrap，两者产物相同）"
	have debootstrap || pkgs="$pkgs debootstrap"
fi
have mksquashfs || pkgs="$pkgs squashfs-tools"
have make || pkgs="$pkgs make"
have gcc || pkgs="$pkgs build-essential"
have ssh-keygen || pkgs="$pkgs openssh-client"
have tar || pkgs="$pkgs tar"
# 开启密码登录时 rig/build-live.sh 用 openssl 生成 sha512 口令
have openssl || pkgs="$pkgs openssl"
[ -e /usr/include/zstd.h ] || pkgs="$pkgs libzstd-dev"
if [ -n "$pkgs" ]; then
	warn "构建依赖" "缺少 $(cn_list "${pkgs# }")，确认后自动安装。构建后端 $BACKEND$BACKEND_NOTE"
else
	pass "构建依赖" "所需软件包均已安装。构建后端 $BACKEND$BACKEND_NOTE"
fi

# --- 源码树 ------------------------------------------------------------------
if [ -n "$TREE" ]; then
	if [ -f "$TREE/rig/build-live.sh" ]; then
		pass "源码树" "使用本机已有的源码树 $TREE"
	else
		gate "源码树" "$TREE 不是 migrator 的源码树：找不到 rig/build-live.sh"
	fi
elif ! have curl && ! have wget; then
	gate "源码树" "本机既没有 curl 也没有 wget，无法下载源码树。可用 -s 指定已有的源码树"
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
		gate "源码树" "$unreach 均不可访问。请先解决网络，或用 -s 指定已有的源码树"
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
	# 这一项预检给不出取值，但操作者知道，所以不拦下整次执行：设置段补问一次。
	warn "网络参数" "无法自动确定本机的地址与网关，稍后手工输入。用 -i 可跳过这一问"
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

# --- 设置 --------------------------------------------------------------------
# 预检只判「能不能做」，具体取值由这一段定。每一问都可能来自命令行，给了的
# 就不再追问；-y 不提问，一律取默认值。
#
# -k 要求两个目录同时占用空间。没有现有产物时，-k 无保留的对象，按没有给处理。
[ -n "$OLD_ART" ] || KEEP_OLD=
if [ -n "$KEEP_OLD" ] && ! can_keep; then
	die 2 "可用空间不足以同时保留现有产物：$out_at 有 $(iec "$OUT_AVAIL") 可用，需要 $(iec $((OUT_NEED + OUT_OLD_SIZE)))。去掉 -k，或用 RIG_OUT 指定其他目录"
fi

if [ -n "$DRY" ]; then
	say ""
	rule
	say "  设置"
	say ""
	say "  执行时会询问登录方式与端口，直接回车即取下面这一行。用 -p、-P 可以直接指定，跳过问答。"
	if [ -n "$OLD_ART" ]; then
		say "  现有产物的处置另有一问：直接使用、重新构建并保留、重新构建并替换。用 -b 或 -k 可以跳过。"
	fi
	if [ -z "$SPEC" ]; then
		say "  地址无法自动确定，执行时会要求输入，或用 -i 指定。"
	fi
	print_settings 取值
elif [ -n "$YES" ]; then
	[ -n "$SPEC" ] || die 2 "无法确定 Live 的网络参数。-y 不提问，请用 -i 指定，格式为 IP/前缀,网关,DNS"
	# -y 取默认值：有完整产物时默认直接使用。给了 -b、-k、-r 或 -P 时改为重新构建：
	# 前三者要求重新构建才成立，密码则只能在构建时写入镜像。
	if [ -n "$OLD_FULL" ] && [ -z "$PW_WANT" ] && [ -z "$SSH_PW" ] &&
		[ -z "$KEEP_OLD" ] && [ -z "$NEW_KEY" ] && [ -z "${WHAT:-}" ]; then
		USE_OLD=1
	fi
	say ""
	rule
	say "  设置（-y 不提问，取默认值）"
	say ""
	print_settings 本次
else
	ask_settings
fi

if [ -n "$USE_OLD" ] && want_pw; then
	die 2 "使用现有产物时不能设置密码：密码在构建时写入镜像。去掉 -P，或用 -b 重新构建"
fi

# --- 后续步骤 ----------------------------------------------------------------
n=0
step() { n=$((n + 1)); printf '  %d. %s\n' "$n" "$*"; }
say ""
say "预检通过。接下来依次执行："
if [ -n "$USE_OLD" ]; then
	step "使用 $OUT 中现有的产物，不重新构建"
	step "打印登录信息，写入 GRUB 引导项并设为默认，然后重启"
	say ""
	say "重启后本机从迁移 Live 启动，当前系统不再运行。引导文件取自 $OUT，复制到 $LIVE_MP 供引导使用。"
else
	if [ -n "$pkgs" ]; then step "安装构建依赖：$(cn_list "${pkgs# }")"; fi
	if [ -n "$TREE" ]; then step "使用本机已有的源码树"; else step "从镜像下载源码树"; fi
	step "编译在线迁移所需的 agent"
	step "构建迁移 Live（profile=$PROFILE，后端 $BACKEND），耗时约十几分钟"
	step "打印登录信息，写入 GRUB 引导项并设为默认，然后重启"
	say ""
	say "重启后本机从迁移 Live 启动，当前系统不再运行。产物写入 $OUT，占用约 2 GiB。"
	if [ -n "$OLD_ART" ]; then
		if [ -n "$KEEP_OLD" ]; then
			say "现有产物的目录加时间戳改名保留，两个目录同时占用空间。"
		else
			say "$OUT 中的现有产物在构建完成后被替换，旧文件不再保留。"
		fi
	fi
	if [ -n "$NEW_KEY" ]; then
		say "私钥重新生成。之前打印的私钥不能用于本次构建的镜像。"
	elif [ -f "$OUT/rig_ed25519" ]; then
		say "私钥继续使用。上一次构建时打印的私钥对本次构建的镜像有效。"
	fi
fi
say ""

if [ -n "$DRY" ]; then
	say "演练结束，未做任何改动。去掉 -n 后先确认设置，再按上面的步骤执行。"
	exit 0
fi

# 替换发生在确认之后，回答 N 是唯一一次机会，因此把替换写进这一句，而不是只在
# 预检表里提一句。用了 -y 的人已经明确表示不问。
if [ -n "$OLD_ART" ] && [ -z "$KEEP_OLD" ] && [ -z "$USE_OLD" ]; then
	text="开始执行，替换 $OUT 中的现有产物"
else
	text="开始执行"
fi
if ! confirm "$text"; then
	if [ -n "$OLD_ART" ]; then
		say "已取消，未做任何改动。$OUT 中的产物保持原样。"
	else
		say "已取消，未做任何改动。"
	fi
	exit 0
fi

# =============================================================================
# 第二段：构建。到这里才开始改动本机。
# =============================================================================
# 随机值在这里确定：预检是只读的，演练也不应给出一个最终不会被使用的密码。
if [ -n "$PORT_WANT" ]; then
	SSH_PORT=$(rand_port)
	[ -n "$SSH_PORT" ] || die 2 "无法生成随机端口"
fi
if [ -n "$PW_WANT" ]; then
	SSH_PW=$(rand_pass)
	[ -n "$SSH_PW" ] || die 2 "无法生成随机密码"
fi

if [ -n "$USE_OLD" ]; then
	say ""
	say "使用 $OUT 中现有的产物，跳过安装依赖、下载源码树与构建"
else
	if [ -n "$pkgs" ]; then
		say ""
		say "安装构建依赖：$(cn_list "${pkgs# }")"
		apt-get update -qq || die "apt-get update 失败。请先解决软件源"
		# shellcheck disable=SC2086  # pkgs is a deliberate word list
		if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs; then
			# apt 的原话在上面。最常见的是软件源里缺这个包或 apt 锁被占用，替它猜
			# 没有意义，但把这两种可能说出来能省掉一次排查。
			say ""
			say "apt 的说明见上。两种常见原因："
			say "  软件源里没有该包。Ubuntu 的 universe 源可以用 add-apt-repository universe 启用"
			say "  另一个 apt 进程占着锁。等它结束再重试"
			die "安装构建依赖失败：$(cn_list "${pkgs# }")"
		fi
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
	# 现有产物的处置在这里落地：依赖与源码树都已就绪，此前的失败不会改动它们。
	if [ -n "$KEEP_OLD" ]; then
		stash_old
	elif [ -n "$NEW_KEY" ]; then
		rm -f "$OUT/rig_ed25519" "$OUT/rig_ed25519.pub"
	fi

	say "构建迁移 Live（profile=$PROFILE，后端 $BACKEND），这一步需要十几分钟"
	# 密码可能含空格与标点，经环境变量传递，不放进命令行参数。
	if [ -n "$SSH_PW" ]; then export LIVE_SSH_PASSWORD="$SSH_PW"; fi
	LIVE_PROFILE=$PROFILE LIVE_NO_ISO=1 RIG_OUT=$OUT LIVE_SSH_PORT=$SSH_PORT \
		bash "$TREE/rig/build-live.sh" ||
		die "构建失败。上一次的输出在上面"
	unset LIVE_SSH_PASSWORD

	# live-entry.sh 是单文件脚本，复制一份到产物目录，撤销时不必回到源码树。
	if [ -f "$TREE/tools/live-entry.sh" ] && [ "$TREE/tools/live-entry.sh" != "$OUT/live-entry.sh" ]; then
		cp -f "$TREE/tools/live-entry.sh" "$OUT/live-entry.sh" 2>/dev/null
		chmod 0755 "$OUT/live-entry.sh" 2>/dev/null
	fi
fi

# =============================================================================
# 第三段：引导。写入引导项会改变下次开机的去处，因此先交出私钥，再问一次。
# =============================================================================
KEY=$OUT/rig_ed25519
live_addr=${SPEC%%,*}
live_addr=${live_addr%%/*}
say ""
rule
say "进入迁移 Live 的登录信息"
say ""
say "  地址  $live_addr"
say "  端口  $SSH_PORT"
if [ -n "$SSH_PW" ]; then
	say "  密码  $SSH_PW（用户 root。这份镜像构建出的每台机器共用该密码）"
elif [ -n "$USE_OLD" ]; then
	say "  密码  取决于上一次构建的设置。设置过的话，以当时打印的为准"
else
	say "  密码  没有。只接受私钥"
fi
say ""
say "私钥是进入迁移 Live 的凭据。目标盘随后会被整体替换，保存在本机上的副本不会"
say "留下，请现在复制到其他设备："
say ""
say "  $KEY"
say ""
if [ -f "$KEY" ]; then
	# shellcheck disable=SC2002
	cat "$KEY"
fi
say ""
say "登录命令："
say "  ssh -i <保存后的文件> -p $SSH_PORT root@$live_addr"
if [ -n "$SSH_PW" ]; then
	say "用密码登录：ssh -p $SSH_PORT root@$live_addr"
fi
rule
say ""

if ! confirm "写入引导项并重启（下次开机进入迁移 Live）"; then
	say ""
	say "未写入引导项，本机仍从当前系统启动，磁盘上的分区与数据都没有改动。"
	say "产物保留在 $OUT。日后要继续，执行："
	say "  bash $OUT/live-entry.sh -s -f $OUT -i $SPEC -p $SSH_PORT"
	say "不再需要这份产物时，删除 $OUT 即可释放空间"
	exit 0
fi

# 端口一并写进引导参数。重新构建时它已经写进镜像，放进引导参数只是让两处一致；
# 直接使用现有产物时，这是唯一能改端口的地方。
if [ -n "$USE_OLD" ]; then
	entry=$OUT/live-entry.sh
else
	entry=$TREE/tools/live-entry.sh
fi
say "写入 GRUB 引导项"
bash "$entry" -s -f "$OUT" -i "$SPEC" -p "$SSH_PORT" || die "写入引导项失败"

say "重启"
reboot
