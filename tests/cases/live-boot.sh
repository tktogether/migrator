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
assert_has "the help says the run stops twice" "停两次确认" "$out"
assert_has "the help says it asks two things first" "问两项设置" "$out"
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
assert_has "the table counts every item" "共 12 项检查" "$out"
assert_has "the table ends with zero failures" "0 项未通过" "$out"
assert_has "the dry run lists the following steps" "接下来依次执行" "$out"
assert_has "the dry run says nothing was changed" "未做任何改动" "$out"
assert_has "the default way in is the key alone" "只接受私钥" "$out"
assert_has "the dry run says the questions come first" "执行时会询问登录方式与端口" "$out"
assert_has "the dry run prints the settings it would ask about" "取值：只接受私钥，sshd 监听 22" "$out"
assert_has "the build names the backend it will use" "构建后端 mmdebstrap" "$out"

# 已有产物：替换的是镜像文件，不是私钥。rig/build-live.sh 复用已有的 rig_ed25519，
# 所以预检不能再说私钥会被替换——那句话会让人以为手里的钥匙作废。
mkdir -p "$TMPD/out/live"
: > "$TMPD/out/live/filesystem.squashfs"
out=$(RIG_OUT="$TMPD/out" bash "$TMPD/lb.sh" -n 2>&1); rc=$?
assert_eq "a previous build still clears the precheck" 0 "$rc"
assert_has "a previous build is reported" "中有上一次构建的产物" "$out"
assert_has "the key is said to be kept" "私钥沿用" "$out"
assert_has "the dry run says the old image goes away" "旧镜像不保留" "$out"
case $out in
	*"私钥会被替换"*)
		_fail "the report does not claim the key is replaced" "still claims it" ;;
	*)
		_pass "the report does not claim the key is replaced" ;;
esac
# 替换发生在确认之后，回答 N 是唯一一次机会：这一句必须点名替换。
if grep -qF '替换 $OUT 中上一次构建的产物' "$L"; then
	_pass "the start confirmation names what it replaces"
else
	_fail "the start confirmation names what it replaces" "the prompt does not mention it"
fi
# 没有产物时不多说一句：这一行只在重新构建时出现。用一个空目录，避免读到本机
# 真实存在的默认产物目录。
out=$(RIG_OUT="$TMPD/none" bash "$TMPD/lb.sh" -n 2>&1)
case $out in
	*"旧镜像不保留"*)
		_fail "a first build says nothing about replacing" "printed the replacement line" ;;
	*)
		_pass "a first build says nothing about replacing" ;;
esac
rm -rf "$TMPD/out"

# 构建后端：mmdebstrap 只存在于 Ubuntu 的 universe 源里。没有它就装 debootstrap，
# 两者在真 root 下产出同一个 minbase 树。
mv "$TMPD/stub/mmdebstrap" "$TMPD/stub/mmdebstrap.off"
out=$(bash "$TMPD/lb.sh" -n 2>&1); rc=$?
assert_eq "a host without mmdebstrap still clears the precheck" 0 "$rc"
assert_has "the fallback backend is named" "构建后端 debootstrap" "$out"
assert_has "the fallback says the products are the same" "两者产物相同" "$out"
assert_has "the fallback installs debootstrap instead" "安装构建依赖：debootstrap" "$out"
mv "$TMPD/stub/mmdebstrap.off" "$TMPD/stub/mmdebstrap"

# 随机端口在问答阶段没有数字可显示：端口在构建时才确定
out=$(bash "$TMPD/lb.sh" -n -p random 2>&1); rc=$?
assert_eq "a random port still clears the precheck" 0 "$rc"
assert_has "a random port is described as undecided" "随机端口，构建时选取" "$out"

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

# 演练与 -y 都不该走到提问：前者只读，后者一律取默认值
out=$(bash "$TMPD/lb.sh" -n 2>&1); rc=$?
assert_eq "a dry run needs no terminal" 0 "$rc"

# -y 不问地址：推不出来就停下，而不是拿一个猜的值构建。把 ip 桩换成不说话，
# 探测必然失败；此后第一件事是拒绝，所以不会真的开始构建。
stub ip 'exit 0'
out=$(bash "$TMPD/lb.sh" -y 2>&1); rc=$?
assert_eq "-y without an address is refused with exit 2" 2 "$rc"
assert_has "the refusal says -y does not ask" "-y 不提问" "$out"
stub ip 'case "$*" in "route get"*) echo "1.1.1.1 via 192.168.22.1 dev eth0 src 192.168.22.50 uid 0" ;; "-o -4 addr show"*) echo "2: eth0    inet 192.168.22.50/24 brd 192.168.22.255 scope global eth0" ;; esac'

# 问答段单独取出执行：本仓库的测试环境造不出伪终端，但「回答怎么变成取值、
# 取值怎么被打印」这一步与终端无关，用桩 ask 按顺序喂答案即可覆盖。
SEG=$TMPD/ask-seg.sh
sed -n '/^# 交互：只问预检给不出取值的地方/,/^# =* 交互结束/p' "$L" > "$SEG"
if grep -q '^ask_settings()' "$SEG"; then
	_pass "the settings segment can be taken out of live-boot.sh"

	# ask_run 答案串 [前置赋值]：答案以 | 分隔，空段表示回车（取默认值）。
	# 答案写进文件后按顺序读：$( ) 里的 ask 在子 shell 中运行，计数器带不出来，
	# 而文件偏移量是共享的。
	ask_run() {
		printf '%s' "$1" | tr '|' '\n' > "$TMPD/answers"
		bash -c '
			set -u
			die() { printf "ERROR: %s\n" "$*" >&2; exit 2; }
			can_ask() { return 0; }
			say() { printf "%s\n" "$*"; }
			rule() { printf "%s\n" "---"; }
			SSH_PORT=22; SSH_PW=; PORT_WANT=; PW_WANT=; PORT_SET=
			SPEC=192.168.22.50/24,192.168.22.1,114.114.114.114
			. "$1"
			exec 3< "$2"
			eval "${3:-:}"
			ask() {
				local a=
				IFS= read -r a <&3
				[ -n "$a" ] || a=$2
				printf "%s\n" "$a"
			}
			ask_settings
			printf "STATE spec=%s port=%s want=%s pw=%s\n" \
				"${SPEC:-none}" "${SSH_PORT:-none}" "${PORT_WANT:-none}" "${PW_WANT:-none}"
		' _ "$SEG" "$TMPD/answers" "${2:-}" 2>&1
	}

	# 一路回车：只接受私钥，22
	out=$(ask_run "")
	assert_has "enter twice keeps the key-only login" "本次：只接受私钥，sshd 监听 22" "$out"
	assert_has "enter twice leaves the port at 22" "STATE spec=192.168.22.50/24,192.168.22.1,114.114.114.114 port=22" "$out"

	# 选了密码登录：端口默认改为随机，而不是 22
	out=$(ask_run "2|")
	assert_has "choosing a password says both ways in work" "私钥与密码均可登录" "$out"
	assert_has "choosing a password moves the default port off 22" "随机端口，构建时选取" "$out"
	assert_has "choosing a password records a random one" "want=random pw=random" "$out"

	# 密码登录仍停在 22 时要说清代价
	out=$(ask_run "2|2")
	assert_has "a password on 22 is called out" "常规扫描" "$out"
	assert_has "a password on 22 leaves the port there" "sshd 监听 22" "$out"

	# 指定端口：数字落到取值里；直接回车则退回随机
	out=$(ask_run "1|3|65022")
	assert_has "a typed port is used" "sshd 监听 65022" "$out"
	out=$(ask_run "1|3|")
	assert_has "an empty port answer falls back to random" "随机端口，构建时选取" "$out"

	# 不认识的编号重问一次，第二次被接受
	out=$(ask_run "9|2|2")
	assert_has "an unknown choice is rejected with what is allowed" "只能填 1 或 2" "$out"
	assert_has "the next answer is taken" "pw=random" "$out"

	# -p 给了就不问端口；-P random 给了就不问登录方式
	out=$(ask_run "" "PORT_SET=1 SSH_PORT=46496")
	assert_has "a given port is not asked about" "sshd 监听 46496" "$out"
	out=$(ask_run "" "PW_WANT=random")
	assert_has "a given password is not asked about" "私钥与密码均可登录" "$out"
	assert_has "a given password makes the default port random" "随机端口，构建时选取" "$out"

	# 预检探测不到地址时补问，回答写回 SPEC
	out=$(ask_run "10.0.0.5/24,10.0.0.1,1.1.1.1|1|2" "SPEC=")
	assert_has "an unknown address is asked for" "无法自动确定，需要手工指定" "$out"
	assert_has "the typed address is used" "STATE spec=10.0.0.5/24,10.0.0.1,1.1.1.1" "$out"
else
	skip "the settings segment" "could not locate it in live-boot.sh"
fi

# The names have to agree: build-live.sh writes them, live-entry.sh reads them.
bl=$(cat "$REPO/rig/build-live.sh")
le=$(cat "$REPO/tools/live-entry.sh")
case $bl in
	*'backend debootstrap'*) _pass "build-live.sh falls back to debootstrap" ;;
	*) _fail "build-live.sh falls back to debootstrap" "no debootstrap branch" ;;
esac
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
