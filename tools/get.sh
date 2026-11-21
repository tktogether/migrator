#!/bin/sh
# get.sh — put migrator on this box with one command, from whichever mirror
# answers first. The point is not to host anything: the code is already in a
# git repository, and three services mirror that repository for free. This
# script tries them in order and uses the first one that answers.
#
#   curl -fsSL https://cdn.jsdelivr.net/gh/tktogether/migrator@master/tools/get.sh | sh
#   curl -fsSL .../tools/get.sh | sh -s -- --check        # 只体检，不装任何东西
#   curl -fsSL .../tools/get.sh | sh -s -- -s plan root@192.168.1.111    # install, then run
#
# --check fetches tools/preflight.sh from the same mirror and runs it, so the
# question "can this machine do it" costs one command and installs nothing.
# That script is a single file: it also runs on its own, without this one.
#
# Sources, in the order tried (the first that serves VERSION wins):
#   jsDelivr      cdn.jsdelivr.net/gh/tktogether/migrator@master    a global CDN
#   Gitee         gitee.com/<owner>/migrator/raw/master             fast inside
#                 mainland China, and only there: cross-border paths to it are
#                 congested and routinely reset, so it is not the primary
#                 source for an audience outside China
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

  --check            只体检，不安装：取 tools/preflight.sh 来跑，参数原样传给它
  --prefix DIR       装到这里（默认 /usr/local）
  --ref REF          取哪个 ref（默认 master。jsDelivr 对分支内容有缓存，
                     需要立即生效或可复现时，钉提交号或 tag，例如 --ref 1.2）
  --proxy URL        所有请求前面加这个前缀（ghproxy 类服务）
  --base URL         只用这一个源，不走三镜像回落
  -h, --help         这一段

环境变量同名覆盖：MIGRATOR_PREFIX / MIGRATOR_REF / MIGRATOR_PROXY / MIGRATOR_BASE /
MIGRATOR_GITEE / MIGRATOR_SHA256。不给 --check 时，装完会把剩下的参数交给 migrator，
所以 "curl ... | sh -s -- -s plan root@IP" 一步到位。
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
	CODE=2 die "neither curl nor wget is here: install one, or copy the tree over and run 'make install'"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/migrator-get.XXXXXX") || die "cannot create a scratch dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- pick a source -----------------------------------------------------------
# VERSION is one short line: cheap to ask for, and its absence means the
# mirror is not serving this repository at this ref (a wrong owner, a repo
# that is still private, a tag that was not pushed).
if [ -n "${MIGRATOR_BASE:-}" ]; then
	BASES=$MIGRATOR_BASE
else
	BASES="https://cdn.jsdelivr.net/gh/$OWNER@$REF
https://gitee.com/$GITEE/raw/$REF
https://raw.githubusercontent.com/$OWNER/$REF"
fi

BASE=
for b in $BASES; do
	say "trying $b"
	if fetch "$b/VERSION" "$TMP/VERSION" && [ -s "$TMP/VERSION" ]; then
		BASE=$b
		break
	fi
done
[ -n "$BASE" ] || { CODE=2 die "no source answered. Try again with MIGRATOR_PROXY=https://a.proxy/ or -base URL (sources tried: $(echo $BASES | tr '\n' ' '))"; }

# --- --check: run the preflight, install nothing ------------------------------
# The question "can this box do the migration" should cost one command and
# leave nothing behind. preflight.sh is a single file, so it is fetched from
# the same mirror and handed the arguments verbatim.
if [ -n "$CHECK" ]; then
	say "只体检，不安装（$BASE）"
	fetch "$BASE/tools/preflight.sh" "$TMP/preflight.sh" || die "cannot download $BASE/tools/preflight.sh"
	[ -s "$TMP/preflight.sh" ] || die "$BASE/tools/preflight.sh is empty"
	# 管道进来时 stdin 是上面的脚本，已经读完：把键盘接回终端，--go 才问得动人。
	# 试探放在子 shell 里：Git Bash 与容器里 /dev/tty 存在却打不开。
	if [ -t 0 ] || ! ( : < /dev/tty ) 2>/dev/null; then
		sh "$TMP/preflight.sh" "$@"; rc=$?
	else
		sh "$TMP/preflight.sh" "$@" </dev/tty; rc=$?
	fi
	exit "$rc"
fi

command -v tar >/dev/null 2>&1 || die "tar is missing"
command -v gzip >/dev/null 2>&1 || die "gzip is missing"

VER=$(tr -d ' \t\r\n' < "$TMP/VERSION")
[ -n "$VER" ] || die "$BASE/VERSION is empty"
say "installing $VER from $BASE"

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
mkdir -p "$SRC/bin" "$SRC/lib" || die "cannot create $SRC"
for f in $FILES; do
	mkdir -p "$SRC/$(dirname "$f")" || die "cannot create $SRC/$(dirname "$f")"
	[ "$f" = lib/VERSION ] || fetch "$BASE/$f" "$SRC/$f" || die "cannot download $BASE/$f"
done
printf '%s\n' "$VER" > "$SRC/lib/VERSION"
chmod 0755 "$SRC/bin/migrator" || die "cannot set modes on the driver"

if [ -n "$PIN" ]; then
	got=$(sha256sum "$SRC/bin/migrator" | cut -d' ' -f1)
	[ "$got" = "$PIN" ] || die "the driver's sha256 is $got, not the pinned $PIN (a mirror serving something else?)"
	say "driver sha256 matches the pinned value"
fi

# --- let tools/install.sh do the install -------------------------------------
# It wants a directory holding SHA256SUMS and one migrator-<ver>.tar.gz, which
# is exactly what a release publish produces; making that here means the
# download path and the offline path run the same installer.
fetch "$BASE/tools/install.sh" "$TMP/install.sh" || die "cannot download $BASE/tools/install.sh"
( cd "$TMP/tree" && tar -czf "$TMP/migrator-$VER.tar.gz" "migrator-$VER" ) || die "cannot pack the tree"
( cd "$TMP" && sha256sum "migrator-$VER.tar.gz" > SHA256SUMS ) || die "cannot write SHA256SUMS"

say "installing into $PREFIX"
MIGRATOR_URL="file://$TMP" MIGRATOR_PREFIX="$PREFIX" sh "$TMP/install.sh" "$@"
