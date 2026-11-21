#!/bin/bash
# tests/cases/live-boot.sh — the one-command entry. The build itself needs root,
# apt and twenty minutes, so what is checked here is the part that has to be
# right before that: the refusals, and the promise that a dry run changes
# nothing. The one thing this case cannot prove is that
# rig/build-live.sh + tools/live-entry.sh agree on the artefact names — that is
# asserted against the two scripts directly, below.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
L=$REPO/tools/live-boot.sh

out=$(bash "$L" -h 2>&1); rc=$?
assert_eq "the help exits 0" 0 "$rc"
assert_has "the help says no second machine is needed" "构建不需要第二台机器" "$out"
assert_has "the help names the two scripts it drives" "rig/build-live.sh" "$out"
assert_has "the help says how to get back out" "live-entry.sh -r" "$out"
assert_has "the help says the run stops twice" "中间停两次" "$out"
assert_has "the help says -n changes nothing" "不改动本机" "$out"

out=$(bash "$L" -p nope 2>&1); rc=$?
assert_eq "an unknown profile is refused" 1 "$rc"
assert_has "the refusal names the two allowed profiles" "slim 或 full" "$out"

out=$(bash "$L" -z 2>&1); rc=$?
assert_eq "an unknown option is refused" 2 "$rc"

if [ "$(id -u)" != 0 ]; then
	out=$(bash "$L" -n 2>&1); rc=$?
	assert_eq "without root it says so instead of half-running" 2 "$rc"
	assert_has "the refusal says why root is needed" "需要 root" "$out"
	assert_has "the refusal is a table row like preflight's" "FAIL  运行身份" "$out"
else
	skip "the root refusal" "running as root"
fi

# 预检是一张表，与 tools/preflight.sh 同一形态：每项一行结果，末尾一行合计。
# 这里用桩命令让其余检查通过，以便看到合计与后续步骤，而不是被本机环境挡住。
TMPD=$(mktemp -d) || exit 1
# msys 的 mktemp 返回 C:\... 形式。直接写进 PATH 会被盘符后的冒号切断，
# 于是桩目录一项也匹配不到。换成 POSIX 形式；Linux 上没有 cygpath，不做转换。
command -v cygpath >/dev/null 2>&1 && TMPD=$(cygpath -u "$TMPD")
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/stub"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$TMPD/stub/$1"; chmod +x "$TMPD/stub/$1"; }
for c in apt-get update-grub mmdebstrap mksquashfs make gcc wget curl; do stub "$c" 'exit 0'; done
stub id 'echo 0'
stub df 'echo 99999999999'
stub findmnt 'case "$*" in *TARGET*) case "$*" in *"/boot"*) echo /boot ;; *) echo / ;; esac ;; *FSTYPE*) echo ext4 ;; *SOURCE*) echo /dev/sda2 ;; esac'
stub ip 'case "$*" in "route get"*) echo "1.1.1.1 via 192.168.22.1 dev eth0 src 192.168.22.50 uid 0" ;; "-o -4 addr show"*) echo "2: eth0    inet 192.168.22.50/24 brd 192.168.22.255 scope global eth0" ;; esac'
# 脚本自己设定 PATH。测试副本把桩目录插到那一行最前面，系统目录仍在后面，
# 因此只有被桩替换的命令受影响。经环境变量传 PATH 会被路径转换改写，故用 sed。
sed "s|^export PATH=|export PATH=$TMPD/stub:|" "$L" > "$TMPD/lb.sh"
grep -q "$TMPD/stub" "$TMPD/lb.sh" || _fail "the stub dir reaches the script's PATH" "sed did not rewrite PATH"

out=$(bash "$TMPD/lb.sh" -n 2>&1); rc=$?
assert_eq "a precheck that passes exits 0 in a dry run" 0 "$rc"
assert_has "the precheck prints the table header" "结果  检查项与说明" "$out"
assert_has "the table counts every item" "共 12 项检查" "$out"
assert_has "the table ends with zero failures" "0 项未通过" "$out"
assert_has "the dry run lists the following steps" "接下来依次执行" "$out"
assert_has "the dry run says nothing was changed" "未做任何改动" "$out"

# 有未通过项时停在预检，不进入确认，也不打印演练结束的说明
mv "$TMPD/stub/update-grub" "$TMPD/stub/update-grub.off"
out=$(bash "$TMPD/lb.sh" -n 2>&1); rc=$?
assert_eq "a failed item stops the run with exit 2" 2 "$rc"
assert_has "the stop says how many items failed" "项未通过，未做任何改动" "$out"
case $out in
	*"演练结束"*) _fail "no dry-run message after a failed precheck" "printed 演练结束" ;;
	*) _pass "no dry-run message after a failed precheck" ;;
esac
mv "$TMPD/stub/update-grub.off" "$TMPD/stub/update-grub"

# 没有可交互的终端时不猜答案为是：写引导项与重启不能靠默认值发生。
# setsid 给出一个没有控制终端的会话，/dev/tty 因此打不开。
if command -v setsid >/dev/null 2>&1; then
	out=$(setsid bash "$TMPD/lb.sh" </dev/null 2>&1); rc=$?
	assert_eq "no terminal and no -y refuses with exit 2" 2 "$rc"
	assert_has "the refusal says to add -y" "加 -y 重新运行" "$out"
else
	skip "the no-terminal refusal" "needs setsid, absent here"
fi

# The names have to agree: build-live.sh writes them, live-entry.sh reads them.
bl=$(cat "$REPO/rig/build-live.sh")
le=$(cat "$REPO/tools/live-entry.sh")
case $bl in
	*'vmlinuz-live'*) _pass "build-live.sh writes the kernel under the name live-entry.sh reads" ;;
	*) _fail "build-live.sh writes the kernel under the name live-entry.sh reads" "no vmlinuz-live" ;;
esac
case $bl in
	*'initrd-live.img'*) _pass "build-live.sh writes the initrd under the name live-entry.sh reads" ;;
	*) _fail "build-live.sh writes the initrd under the name live-entry.sh reads" "no initrd-live.img" ;;
esac
case $le in
	*'live/filesystem.squashfs'*) _pass "live-entry.sh reads live/filesystem.squashfs" ;;
	*) _fail "live-entry.sh reads live/filesystem.squashfs" "missing" ;;
esac

t_end
