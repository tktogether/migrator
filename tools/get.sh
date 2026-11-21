#!/bin/sh
# get.sh — put migrator on this box with one command, from whichever mirror
# answers first. The point is not to host anything: the code is already in a
# git repository, and three services mirror that repository for free. This
# script tries them in order and uses the first one that answers.
#
#   curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/get.sh | sh
#   curl -fsSL .../tools/get.sh | sh -s -- --check        # check only, install nothing
#   curl -fsSL .../tools/get.sh | sh -s -- -s plan root@192.168.1.111    # install, then run
#
# --check fetches tools/preflight.sh from the same mirror and runs it, so the
# question "can this machine do it" costs one command and installs nothing.
# That script is a single file: it also runs on its own, without this one.
#
# Sources, in the order tried (the first that serves VERSION wins):
#   Gitee         gitee.com/<owner>/migrator/raw/master             fast inside
#                 mainland China; cross-border paths to it are congested and
#                 routinely reset, so from outside China pass --base jsDelivr
#   jsDelivr      cdn.jsdelivr.net/gh/tktogether/migrator@master    a global CDN
#   GitHub raw    raw.githubusercontent.com/tktogether/migrator/master
#
# All three follow master, so there is no tag to cut and no release to
# publish. They do not refresh at the same moment: GitHub raw serves a new
# commit at once, the Gitee mirror follows its workflow, and jsDelivr caches a
# branch for up to 12 h. Pass MIGRATOR_REF=<sha|tag> (or --ref) for a
# reproducible install, or when a change has to be in place now; a commit URL
# is never a cache hit.
#
# Overrides, one environment variable each, no code change needed:
#   MIGRATOR_BASE=https://your.host/migrator   use exactly this, no fallback
#   MIGRATOR_PROXY=https://your.proxy/         prefix every URL (ghproxy style)
#   MIGRATOR_REF=1.2                           pin what is fetched (default master)
#   MIGRATOR_GITEE=owner/repo                  where the Gitee mirror lives
#   MIGRATOR_PREFIX=/opt/migrator              install here instead of /usr/local
#
# What it does: fetches the tree file by file from that mirror, packs it the
# way tools/install.sh expects, and hands over — so a download and a tarball
# you already hold run the same install code (staging, the last-step rename,
# the -V smoke test). Where things land is a separate question, and there are
# two answers, not one: this and 'make install' both use $PREFIX/sbin +
# $PREFIX/lib/migrator, while the Debian packages follow policy — /usr/sbin,
# /usr/share/migrator, /usr/lib/migrator.
#
# Integrity: every file comes over TLS from the mirror. That trusts the
# mirror, as every "curl | sh" does. MIGRATOR_SHA256=<hash> pins the driver
# itself when that trust is not enough.
# exit: 0 installed (or handed over to migrator) · 1 download/install failure
#       2 nothing to fetch with, or no source answered
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
OWNER=${MIGRATOR_OWNER:-tktogether/migrator}
GITEE=${MIGRATOR_GITEE:-$OWNER}
REF=${MIGRATOR_REF:-master}
PROXY=${MIGRATOR_PROXY:-}
PREFIX=${MIGRATOR_PREFIX:-/usr/local}
PIN=${MIGRATOR_SHA256:-}
CHECK=

say() { echo "[migrator-get] $*"; }
die() { echo "[migrator-get] ERROR: $*" >&2; exit "${CODE:-1}"; }

usage() {
	cat <<'EOF'
用法：get.sh [选项] [-- migrator 的参数...]

  从镜像读取源码并安装 migrator，默认安装到 /usr/local。
  --check        只检查，不安装。脚本读取 tools/preflight.sh 并运行，选项原样传给该脚本
  --prefix DIR   安装目录（默认 /usr/local）
  --ref REF      读取的分支或标签（默认 master）。jsDelivr 对分支内容有缓存。
                 需要立即生效或可复现的安装时，指定提交号或标签，例如 --ref 1.2
  --proxy URL    为每个请求添加该前缀，适用于 ghproxy 类服务
  --base SRC     只使用该源，不依次尝试三个镜像。SRC 可以是完整地址，
                 也可以是源名 gitee、jsdelivr、github
  -h, --help     显示本说明

环境变量与选项同名时覆盖选项：MIGRATOR_PREFIX、MIGRATOR_REF、MIGRATOR_PROXY、
MIGRATOR_BASE、MIGRATOR_GITEE、MIGRATOR_SHA256。
不使用 --check 时，安装完成后其余参数传给 migrator。
因此「curl ... | sh -s -- -s plan root@IP」可以在一条命令中完成安装与运行。
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
		--check|--preflight) CHECK=1 ;;
		--prefix) PREFIX=${2:?--prefix needs a value}; shift ;;
		--ref)    REF=${2:?--ref needs a value}; shift ;;
		--proxy)  PROXY=${2:?--proxy needs a value}; shift ;;
		--base)   MIGRATOR_BASE=${2:?--base needs a value}; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		*) break ;;   # not one of ours: "-s plan HOST" is for migrator, after the install
	esac
	shift
done

# Timeouts are the point of a fallback list: a mirror that hangs must cost
# seconds, not the kernel's TCP timeout, or the second source is never reached.
# Every file here is a script of a few KB, so 30 s is generous.
if command -v curl >/dev/null 2>&1; then
	fetch() {
		if [ -n "$PROXY" ]; then set -- "$PROXY$1" "$2"; fi
		curl -fsSL --connect-timeout 5 --max-time 30 -o "$2" "$1"
	}
elif command -v wget >/dev/null 2>&1; then
	fetch() {
		if [ -n "$PROXY" ]; then set -- "$PROXY$1" "$2"; fi
		wget -q -T 30 -t 1 -O "$2" "$1"
	}
else
	CODE=2 die "本机既没有 curl 也没有 wget。请先安装其中一个，或把源码树复制到本机后执行 make install"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/migrator-get.XXXXXX") || die "无法创建临时目录"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- pick a source -----------------------------------------------------------
# VERSION is one short line: cheap to ask for, and its absence means the
# mirror is not serving this repository at this ref (a wrong owner, a repo
# that is still private, a tag that was not pushed).
if [ -n "${MIGRATOR_BASE:-}" ]; then
	# 源名是完整地址的简写：读者不必记住三种镜像的路径形式
	case $MIGRATOR_BASE in
		gitee)     MIGRATOR_BASE=https://gitee.com/$GITEE/raw/$REF ;;
		jsdelivr)  MIGRATOR_BASE=https://cdn.jsdelivr.net/gh/$OWNER@$REF ;;
		github)    MIGRATOR_BASE=https://raw.githubusercontent.com/$OWNER/$REF ;;
	esac
	BASES=$MIGRATOR_BASE
else
	BASES="https://gitee.com/$GITEE/raw/$REF
https://cdn.jsdelivr.net/gh/$OWNER@$REF
https://raw.githubusercontent.com/$OWNER/$REF"
fi

BASE=
for b in $BASES; do
	say "尝试下载源 $b"
	if fetch "$b/VERSION" "$TMP/VERSION" && [ -s "$TMP/VERSION" ]; then
		BASE=$b
		break
	fi
done
[ -n "$BASE" ] || { CODE=2 die "安装所需的文件没有从任何下载地址取到。可设置 MIGRATOR_PROXY 指向代理后重试，或用 --base 指定地址。已尝试：$(echo $BASES | tr '\n' ' ')"; }

# --- --check: run the preflight, install nothing ------------------------------
# The question "can this box do the migration" should cost one command and
# leave nothing behind. preflight.sh is a single file, so it is fetched from
# the same mirror and handed the arguments verbatim.
if [ -n "$CHECK" ]; then
	say "只检查，不安装。下载源：$BASE"
	fetch "$BASE/tools/preflight.sh" "$TMP/preflight.sh" || die "无法下载 $BASE/tools/preflight.sh"
	[ -s "$TMP/preflight.sh" ] || die "$BASE/tools/preflight.sh 的内容为空"
	# 管道进来时 stdin 是上面的脚本，已经读完：把键盘接回终端，--go 才问得动人。
	# 试探放在子 shell 里：Git Bash 与容器里 /dev/tty 存在却打不开。
	if [ -t 0 ] || ! ( : < /dev/tty ) 2>/dev/null; then
		sh "$TMP/preflight.sh" "$@"; rc=$?
	else
		sh "$TMP/preflight.sh" "$@" </dev/tty; rc=$?
	fi
	exit "$rc"
fi

command -v tar >/dev/null 2>&1 || die "本机缺少 tar"
command -v gzip >/dev/null 2>&1 || die "本机缺少 gzip"

VER=$(tr -d ' \t\r\n' < "$TMP/VERSION")
[ -n "$VER" ] || die "$BASE/VERSION 的内容为空"
say "从 $BASE 安装 $VER"

# --- fetch the tree ----------------------------------------------------------
# The list is the tree, not the tarball: the mirrors serve files out of a
# repository and do not list directories, so the file names are written here.
# tests/cases/get.sh fails when this list and lib/*.sh disagree, and when a
# file the Debian package installs is missing from it.
FILES="bin/migrator
lib/VERSION
lib/apply.sh
lib/bootstrap.sh
lib/common.sh
lib/inventory.sh
lib/netfix.sh
lib/params.sh
lib/plan.sh
lib/postfix.sh
lib/ssh.sh
lib/target.sh
lib/transfer.sh
lib/verify.sh
lib/wizard.sh
tools/relay-tunnel.sh
LICENSE
LICENSE-UPSTREAM
NOTICE
TRADEMARK.md"

SRC=$TMP/tree/migrator-$VER
mkdir -p "$SRC/bin" "$SRC/lib" || die "无法创建 $SRC"
for f in $FILES; do
	mkdir -p "$SRC/$(dirname "$f")" || die "无法创建 $SRC/$(dirname "$f")"
	[ "$f" = lib/VERSION ] || fetch "$BASE/$f" "$SRC/$f" || die "无法下载 $BASE/$f"
done
printf '%s\n' "$VER" > "$SRC/lib/VERSION"
chmod 0755 "$SRC/bin/migrator" || die "无法设置驱动器的文件权限"

if [ -n "$PIN" ]; then
	got=$(sha256sum "$SRC/bin/migrator" | cut -d' ' -f1)
	[ "$got" = "$PIN" ] || die "驱动器的 sha256 为 $got，与指定的 $PIN 不一致。该地址可能提供的是另一份代码"
	say "驱动器的 sha256 与指定值一致"
fi

# --- let tools/install.sh do the install -------------------------------------
# It wants a directory holding SHA256SUMS and one migrator-<ver>.tar.gz, which
# is exactly what a release publish produces; making that here means the
# download path and the offline path run the same installer.
fetch "$BASE/tools/install.sh" "$TMP/install.sh" || die "无法下载 $BASE/tools/install.sh"
( cd "$TMP/tree" && tar -czf "$TMP/migrator-$VER.tar.gz" "migrator-$VER" ) || die "无法打包源码树"
( cd "$TMP" && sha256sum "migrator-$VER.tar.gz" > SHA256SUMS ) || die "无法写入 SHA256SUMS"

say "安装到 $PREFIX"
MIGRATOR_URL="file://$TMP" MIGRATOR_PREFIX="$PREFIX" sh "$TMP/install.sh" "$@"
