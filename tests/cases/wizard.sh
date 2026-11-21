#!/bin/bash
# tests/cases/wizard.sh — the two ways in that do not need the full command
# line: -f (a run written down as a file) and the wizard (the same answers,
# asked). Both end up as arguments to the same driver, so what is asserted
# here is the argument surface, not a migration: no Live, no disk, no root.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
M=$REPO/bin/migrator

# --- -f: a parameter file ----------------------------------------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/wizard.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

cat > "$T/good.conf" <<'EOF'
# a run that worked, written down
donor=root@10.0.0.9
disk=/dev/sdz
yes=1
mode=online
compress=zstd:3
EOF
out=$(bash "$M" -f "$T/good.conf" -V 2>&1); rc=$?
assert_eq  "-f with a good file exits 0"          0 "$rc"
assert_has "-f loads the driver anyway"           "lib=" "$out"

printf 'donor=root@10.0.0.9\ndisk\n' > "$T/bad.conf"
out=$(bash "$M" -f "$T/bad.conf" -V 2>&1); rc=$?
assert_eq  "a line without '=' exits 2"           2 "$rc"
assert_has "a bad line names its line number"     "bad.conf:2:" "$out"

printf 'maxest=600\n' > "$T/typo.conf"
out=$(bash "$M" -f "$T/typo.conf" -V 2>&1); rc=$?
assert_eq  "an unknown key in the file exits 2"   2 "$rc"
assert_has "an unknown key suggests the near miss" "did you mean max-est" "$out"

out=$(bash "$M" -f "$T/nosuch.conf" -V 2>&1); rc=$?
assert_eq  "a missing file exits 2"               2 "$rc"
assert_has "a missing file says so"               "cannot read the parameter file" "$out"

# an argument on the command line wins over the file, which is what makes
# "same run, one disk changed" a one-word edit
out=$(bash "$M" -f "$T/good.conf" -d /dev/sdq -V 2>&1); rc=$?
assert_eq  "a flag after -f is still accepted"    0 "$rc"

# --- the wizard --------------------------------------------------------------
# WZ_PRINT_ONLY stops before the confirm/exec: the answers below are the ones a
# person would type (source, on-line, auto disk, auto compression, netdown, no
# boottest), and what comes back is the command they add up to.
out=$(printf 'root@10.0.0.9\n2\n1\n1\n1\n2\n' | WZ_PRINT_ONLY=1 bash "$M" -w 2>&1); rc=$?
assert_eq  "the wizard prints and stops"          0 "$rc"
assert_has "the wizard asks the questions"        "迁移方式" "$out"
assert_has "the wizard prints the command"        "将执行" "$out"
assert_has "the answers become -o"                "-o mode=online" "$out"
assert_has "the source is the last argument"      "root@10.0.0.9" "$out"
assert_has "the wizard offers a parameter file"   "donor=root@10.0.0.9" "$out"
assert_has "and says how to use it"               "migrator -f" "$out"

# a wizard that answers with a bad number must not guess
out=$(printf 'root@10.0.0.9\n9\n' | WZ_PRINT_ONLY=1 bash "$M" -w 2>&1); rc=$?
assert_eq  "an out-of-range answer exits 2"       2 "$rc"
assert_has "and says the range"                   "超出范围" "$out"

# no terminal, no -w, no source: still the plain refusal, not a hang
out=$(bash "$M" </dev/null 2>&1); rc=$?
assert_eq  "no args off a terminal still exits 2" 2 "$rc"
assert_has "no args off a terminal says DONOR"    "DONOR is required" "$out"

# --- get.sh: the file list must be the tree -----------------------------------
# The installer fetches file by file from a mirror, so its list is a
# second copy of lib/. This keeps the copies equal: a lib added without the
# list is a package that installs and then cannot start. Only lib/ entries are
# compared here; tools/ entries are checked separately below.
listing=$(sed -n '/^FILES="/,/"/p' "$REPO/tools/get.sh" | sed '1s/^FILES="//; $s/"$//')
listed=$(printf '%s\n' "$listing" | grep '^lib/.*\.sh$' | sed 's|^lib/||' | LC_ALL=C sort)
actual=$(cd "$REPO/lib" && ls *.sh | LC_ALL=C sort)
assert_eq "get.sh fetches exactly lib/*.sh" "$actual" "$listed"
if printf '%s\n' "$listing" | grep -qx 'bin/migrator'; then
	_pass "get.sh fetches the driver"
else
	_fail "get.sh fetches the driver" "bin/migrator is not in FILES"
fi
if printf '%s\n' "$listing" | grep -qx 'tools/relay-tunnel.sh'; then
	_pass "get.sh fetches the relay helper"
else
	_fail "get.sh fetches the relay helper" "tools/relay-tunnel.sh is not in FILES"
fi
for f in lib/VERSION; do
	if printf '%s\n' "$listing" | grep -qx "$f"; then _pass "get.sh fetches $f"
	else _fail "get.sh fetches $f" "$f is not in FILES"; fi
done

# --- preflight: one file, nothing installed ----------------------------------
# 本脚本用于在未安装任何软件的情况下给出检查结论，因此这里在没有任何安装的
# 环境中运行它。帮助、汇总、拒绝错误参数三项都必须成立。
out=$(sh "$REPO/tools/preflight.sh" -h 2>&1)
assert_has "preflight documents --check" "--check" "$out"
assert_has "preflight documents --go"    "--go"    "$out"
assert_has "preflight documents --fix"   "--fix"   "$out"

# 用不可达的代理让三个下载源的探测立即失败，避免这条用例等待 raw.githubusercontent
out=$(https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
	sh "$REPO/tools/preflight.sh" 2>&1 || true)
assert_has "preflight prints a summary" "项检查" "$out"
# 下载地址只在探测到可用的源时才输出：早期的写法固定打印 jsDelivr，在大陆网络的
# 机器上那条命令必然失败。本用例让三个源都不可达，因此不应出现任何下载地址。
case $out in
	*/gh/tktogether/*|*/tktogether/migrator/raw/*) _fail "preflight prints no unusable address" "printed a download URL" ;;
	*) _pass "preflight prints no unusable address" ;;
esac
# 有源端地址时输出可以继续，没有源端地址时输出了解目标端，有 FAIL 时要求先处理。
# 三句话都在说明下一步做什么，运行测试的机器是否为 root、缺少哪些软件包都不改变这一点。
case $out in
	*"可以继续"*|*"本机检查完成"*|*"请先处理"*) _pass "preflight says what is next" ;;
	*) _fail "preflight says what is next" "no actionable line at the end" ;;
esac

rc=0; sh "$REPO/tools/preflight.sh" --nope >/dev/null 2>&1 || rc=$?
assert_eq "preflight refuses an unknown option" 2 "$rc"

# --- preflight: the display layer must be invisible in a pipe -----------------
# 输出不是终端时，颜色、标志块与动画都不应出现，否则写入日志的内容会带上转义
# 序列。--color 用于显式打开颜色，此时也不应出现标志块与动画。
esc=$(printf '\033')
out=$(https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
	sh "$REPO/tools/preflight.sh" --plain 2>&1 || true)
case $out in
	*"$esc"*) _fail "preflight --plain emits no escape sequences" "found ESC" ;;
	*)        _pass "preflight --plain emits no escape sequences" ;;
esac
case $out in
	*"M I G R A T O R"*) _fail "preflight --plain omits the logo" "printed the logo block" ;;
	*)                   _pass "preflight --plain omits the logo" ;;
esac

out=$(https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
	sh "$REPO/tools/preflight.sh" --color 2>&1 || true)
case $out in
	*"$esc"*) _pass "preflight --color emits escape sequences" ;;
	*)        _fail "preflight --color emits escape sequences" "no ESC in output" ;;
esac
case $out in
	*"M I G R A T O R"*) _fail "preflight --color keeps the logo off a pipe" "printed the logo block" ;;
	*)                   _pass "preflight --color keeps the logo off a pipe" ;;
esac

assert_has "preflight documents --plain" "--plain" "$(sh "$REPO/tools/preflight.sh" -h 2>&1)"
assert_has "preflight documents --no-color" "--no-color" "$(sh "$REPO/tools/preflight.sh" -h 2>&1)"

out=$(sh "$REPO/tools/get.sh" -h 2>&1)
assert_has "get.sh documents --check" "只检查，不安装" "$out"

t_end

