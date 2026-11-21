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

assert_has "the help documents the port" "-p PORT" "$out"
assert_has "the help documents the password" "-P PASS" "$out"
assert_has "the help says the port can be random" "random" "$out"

out=$(bash "$L" -m nope 2>&1); rc=$?
assert_eq "an unknown profile is refused" 2 "$rc"
assert_has "the refusal names the two allowed profiles" "slim 或 full" "$out"

# -p 曾经是 profile，现在表示端口：旧写法要给出改法，而不是只说「不是数字」
out=$(bash "$L" -p slim 2>&1); rc=$?
assert_eq "the old -p PROFILE spelling is refused" 2 "$rc"
assert_has "the refusal points at -m" "-m slim" "$out"

out=$(bash "$L" -p nope 2>&1); rc=$?
assert_eq "a non-numeric port is refused" 2 "$rc"
assert_has "the port refusal says what a port looks like" "不是数字" "$out"

out=$(bash "$L" -p 99999 2>&1); rc=$?
assert_eq "an out-of-range port is refused" 2 "$rc"
assert_has "the range refusal says the range" "超出范围" "$out"

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
assert_has "the table counts every item" "共 13 项检查" "$out"
assert_has "the table ends with zero failures" "0 项未通过" "$out"
assert_has "the dry run lists the following steps" "接下来依次执行" "$out"
assert_has "the dry run says nothing was changed" "未做任何改动" "$out"
assert_has "the default way in is the key alone" "只接受私钥" "$out"
assert_has "the table has a row for how one logs in" "登录方式" "$out"

# 随机端口在预检阶段没有数字可显示：预检只读，端口在执行时才确定
out=$(bash "$TMPD/lb.sh" -n -p random 2>&1); rc=$?
assert_eq "a random port still clears the precheck" 0 "$rc"
assert_has "a random port is described as undecided" "随机端口，执行时选取" "$out"

# 演练不打印密码：真跑时会重新生成一个，演练给出的那个永远不会被使用
out=$(bash "$TMPD/lb.sh" -n -P random 2>&1)
assert_has "a password is planned, not printed, in a dry run" "私钥与密码" "$out"
case $out in
	*"密码  "*)
		_fail "no password is printed in a dry run" "printed one" ;;
	*)
		_pass "no password is printed in a dry run" ;;
esac

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

# 端口与密码写在镜像里，引导脚本只能改端口：密码不能放在引导参数里，本机任何
# 用户都能读到那一行。
case $bl in
	*'sshd_config.d/00-migrator-port.conf'*) _pass "build-live.sh puts the port in one file" ;;
	*) _fail "build-live.sh puts the port in one file" "no 00-migrator-port.conf" ;;
esac
case $bl in
	*'LIVE_SSH_PASSWORD'*) _pass "build-live.sh takes a password at build time" ;;
	*) _fail "build-live.sh takes a password at build time" "no LIVE_SSH_PASSWORD" ;;
esac
case $le in
	*'migrator.ssh_port='*) _pass "live-entry.sh can move the port on the boot line" ;;
	*) _fail "live-entry.sh can move the port on the boot line" "no migrator.ssh_port=" ;;
esac

# 把 build-live.sh 里落地端口与密码的那一段抽出来，在一个假的根目录上执行：
# 只有这样才能证明「传了参数就真的写进镜像」，而不是只证明参数被解析。
SEG=$TMPD/ssh-seg.sh
b=$(grep -nF 'SSH_PORT=${LIVE_SSH_PORT:-22}' "$REPO/rig/build-live.sh" | head -1 | cut -d: -f1)
e=$(grep -nF 'chmod 0644 "$CH/etc/ssh/sshd_config.d/"*.conf' "$REPO/rig/build-live.sh" | head -1 | cut -d: -f1)
if [ -n "$b" ] && [ -n "$e" ] && [ "$e" -gt "$b" ]; then
	sed -n "${b},${e}p" "$REPO/rig/build-live.sh" > "$SEG"
	mkch() {
		CH=$TMPD/ch
		rm -rf "$CH"; mkdir -p "$CH/etc/ssh"
		printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$CH/etc/ssh/sshd_config"
		printf 'root:*:19000:0:99999:7:::\n' > "$CH/etc/shadow"
	}
	mkch
	LIVE_SSH_PORT=46496 LIVE_SSH_PASSWORD=secretpass CH=$TMPD/ch bash -c '. "$1"' _ "$SEG" >/dev/null 2>&1
	if grep -qx 'Port 46496' "$TMPD/ch/etc/ssh/sshd_config.d/00-migrator-port.conf" 2>/dev/null; then
		_pass "the port lands in the image"
	else
		_fail "the port lands in the image" "00-migrator-port.conf does not say 46496"
	fi
	if grep -q '^root:[^:*]' "$TMPD/ch/etc/shadow" 2>/dev/null; then
		_pass "the password lands in the image as a sha512 hash"
	else
		_fail "the password lands in the image as a sha512 hash" "shadow still has the locked root"
	fi
	if grep -q '^PermitRootLogin yes' "$TMPD/ch/etc/ssh/sshd_config.d/10-migrator-auth.conf" 2>/dev/null; then
		_pass "password logins are enabled when a password is given"
	else
		_fail "password logins are enabled when a password is given" "no PermitRootLogin yes"
	fi

	# 不给密码时不留下任何允许密码登录的片段：默认只接受私钥
	mkch
	LIVE_SSH_PORT=46496 CH=$TMPD/ch bash -c '. "$1"' _ "$SEG" >/dev/null 2>&1
	case "$(ls "$TMPD/ch/etc/ssh/sshd_config.d/" 2>/dev/null)" in
		*10-migrator-auth.conf*) _fail "no password fragment without a password" "one was written" ;;
		*) _pass "no password fragment without a password" ;;
	esac
	if grep -q '^root:[*]:' "$TMPD/ch/etc/shadow" 2>/dev/null; then
		_pass "root stays locked without a password"
	else
		_fail "root stays locked without a password" "shadow changed"
	fi

	# 同一目录里只能有一个 Port：两个 Port 指令会让 sshd 同时监听两个端口
	if [ "$(cat "$TMPD/ch/etc/ssh/sshd_config.d/"*.conf 2>/dev/null | grep -c '^Port ')" = 1 ]; then
		_pass "exactly one Port directive reaches sshd"
	else
		_fail "exactly one Port directive reaches sshd" "count is not 1"
	fi
else
	skip "the ssh segment test" "could not locate the segment in build-live.sh"
fi

t_end
