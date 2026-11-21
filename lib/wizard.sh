#!/bin/bash
# lib/wizard.sh — the handful of answers a migration needs, asked in order.
#
# Started by "migrator" with no arguments on a terminal, or by "-w" when the
# operator wants to be asked even though some arguments are already there.
#
# The wizard migrates nothing: it fills in what was left out, prints the
# command those answers add up to (so the same run can be repeated, or saved
# as a parameter file for -f), and execs the driver with those arguments.
# Every safety check stays where it was — the plan is still printed for review
# and the target disk still has to be typed out before anything is written.
#
# Prompts are Chinese because the operator manual is; the code around them is
# not, and every message the driver prints stays as it was.
#
# WZ_PRINT_ONLY=1 stops after printing instead of running: that is how the
# test suite answers the questions, without a terminal and without a disk.

wz_ask() {   # wz_ask VAR QUESTION [DEFAULT] — put the answer in VAR
	local __v=$1 q=$2 d=${3-} a
	if [ -n "$d" ]; then
		read -rp "$(_tag) $q [$d] " a || die "$EX_ENV" "no answer to '$q'"
	else
		read -rp "$(_tag) $q " a || die "$EX_ENV" "no answer to '$q'"
	fi
	[ -n "$a" ] || a=$d
	printf -v "$__v" '%s' "$a"
}

wz_menu() {   # wz_menu VAR QUESTION DEFAULT_INDEX -- CHOICE...
	# A CHOICE is "token" or "token|what it means". The result is the token, so
	# the caller never parses prose. A typed /dev/... path is accepted as is,
	# which is how a disk lsblk cannot see gets named.
	local __v=$1 q=$2 d=$3; shift 3
	[ "${1-}" = "--" ] && shift
	local opts=("$@") i=1 a o
	[ ${#opts[@]} -gt 0 ] || die "$EX_ENV" "wz_menu: no choices for '$q'"
	say "$q"
	for o in "${opts[@]}"; do
		if [ "${o#*|}" = "$o" ]; then printf '    %d) %s\n' "$i" "$o"
		else printf '    %d) %s — %s\n' "$i" "${o%%|*}" "${o#*|}"; fi
		i=$((i + 1))
	done
	read -rp "$(_tag) 选 1-${#opts[@]}  [$d] " a || die "$EX_ENV" "no answer to '$q'"
	a=${a:-$d}
	case $a in /dev/*) printf -v "$__v" '%s' "$a"; return 0 ;; esac
	case $a in ''|*[!0-9]*) die "$EX_ENV" "'$a' 不是编号：输 1-${#opts[@]}，或直接写磁盘路径" ;; esac
	[ "$a" -ge 1 ] && [ "$a" -le ${#opts[@]} ] || die "$EX_ENV" "编号 $a 超出范围 1-${#opts[@]}"
	printf -v "$__v" '%s' "${opts[$((a - 1))]%%|*}"
}

wz_index_of() {   # wz_index_of TOKEN CHOICE... — its 1-based index, else 1
	local t=$1 i=1 o; shift
	for o in "$@"; do
		[ "${o%%|*}" = "$t" ] && { echo "$i"; return 0; }
		i=$((i + 1))
	done
	echo 1
}

wz_disks() {   # one line per disk: device|size and model
	local dev size type model
	have lsblk || return 0
	while read -r dev size type model; do
		[ "$type" = disk ] || continue
		case $dev in /dev/*) ;; *) continue ;; esac
		printf '%s|%s %s\n' "$dev" "$size" "$model"
	done < <(lsblk -dnpo NAME,SIZE,TYPE,MODEL 2>/dev/null)
}

wz_root_disk() {   # the disk this box booted from: /dev/sda for /dev/sda1
	local src pk
	src=$(findmnt -no SOURCE / 2>/dev/null) || return 0
	[ -n "$src" ] || return 0
	pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
	if [ -n "$pk" ]; then echo "/dev/$pk"; else echo "$src"; fi
}

wz_run() {
	local self donor mode disk= comp= cut= bt= args=() d root_disk mt def_bt=1 k
	local c_mode c_comp c_cut c_bt c_disk
	self=$(readlink -f "$0")
	donor=${WZ_DONOR:-${PA_DONOR:-}}

	say "交互式设置：直接回车接受方括号里的默认值，Ctrl-C 随时退出。"
	say "这里只回答问题；真正迁移时计划照样打印，目标盘照样要你亲手打一遍。"

	# --- the source ---------------------------------------------------------
	while [ -z "$donor" ]; do
		wz_ask donor "源机地址（例 root@192.168.1.111，只写 IP 也行）" ""
		[ -n "$donor" ] || warn "源机地址不能为空"
	done
	case $donor in *" "*) die "$EX_ENV" "源机地址里不能有空格：'$donor'" ;; esac

	# --- on-line or off-line ------------------------------------------------
	c_mode=("auto|自动：源机在跑系统就按在线处理，已在 Live 里就按离线处理"
		"online|在线：源机继续运行，只在最后冻结一小段时间"
		"offline|离线：源机也已经启动到 Live")
	wz_menu mode "迁移方式" \
		"$(wz_index_of "${OPT[mode]:-auto}" "${c_mode[@]}")" -- "${c_mode[@]}"
	if [ "$mode" = auto ]; then unset 'OPT[mode]'; else OPT[mode]=$mode; fi

	# --- the target disk ----------------------------------------------------
	root_disk=$(wz_root_disk)
	c_disk=("auto|自动：只有一块合适的盘就用它，否则停下并列出所有盘")
	case ${DISK:-auto} in
		auto) ;;
		*,*) disk=$DISK ;;                        # -d a,b is a RAID1 pair: pass it through
		*) disk=$DISK; c_disk+=("$disk|命令行指定的目标盘") ;;
	esac
	if [ -z "$disk" ]; then
		while read -r d; do
			[ -n "$d" ] || continue
			if [ -n "$root_disk" ] && [ "${d%%|*}" = "$root_disk" ]; then
				c_disk+=("${d%%|*}|${d#*|}（本机正在运行的系统，不能选）")
			else
				c_disk+=("${d%%|*}|${d#*|}")
			fi
		done < <(wz_disks)
		wz_menu disk "目标磁盘（会被整盘覆盖）" \
			"$(wz_index_of "${DISK:-auto}" "${c_disk[@]}")" -- "${c_disk[@]}"
	fi
	DISK=$disk

	# --- how much cpu to spend on the wire ----------------------------------
	c_comp=("auto|auto：在线按源机 CPU 与链路速度自动定级别，离线用 lz4"
		"zstd|zstd：压得更狠，CPU 有富余时用"
		"lz4|lz4：最快，链路快于 CPU 时用"
		"none|none：不压，省 CPU")
	wz_menu comp "压缩" \
		"$(wz_index_of "${OPT[compress]:-auto}" "${c_comp[@]}")" -- "${c_comp[@]}"
	if [ "$comp" = auto ]; then unset 'OPT[compress]'; else OPT[compress]=$comp; fi

	# --- what the donor does once the copy is confirmed ----------------------
	c_cut=("netdown|断网停住（默认）：源机不再对外服务，人工确认后再关机"
		"poweroff|直接关机"
		"kexec|直接重启进新系统（要求 kexec 可用）"
		"none|什么都不做")
	wz_menu cut "迁移完成后，源机做什么" \
		"$(wz_index_of "${OPT[cutover]:-netdown}" "${c_cut[@]}")" -- "${c_cut[@]}"
	OPT[cutover]=$cut

	# --- prove the copy boots before cutting over ----------------------------
	mt=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
	[ -n "$mt" ] && [ "$mt" -lt 3072 ] && def_bt=0
	c_bt=("要|多花十几分钟，但能在切换前发现引导问题（约需 3G 空闲内存）"
		"不要|直接进入验收")
	local bt_def=1
	[ "${OPT[boottest]:-$def_bt}" = 0 ] && bt_def=2
	wz_menu bt "切换前要不要在本机用 qemu 试启动一次新系统" "$bt_def" -- "${c_bt[@]}"
	if [ "$bt" = 要 ]; then OPT[boottest]=1; else OPT[boottest]=0; fi

	# --- what those answers add up to ---------------------------------------
	PA_DONOR=$donor
	args=(-d "$DISK")
	[ -n "$DRY" ] && args+=(-n)
	[ -n "$YES" ] && args+=(-y)
	[ -n "$SSH_KEYFILE" ] && args+=(-i "$SSH_KEYFILE")
	for k in $(printf '%s\n' "${!OPT[@]}" | LC_ALL=C sort); do
		args+=(-o "$k=${OPT[$k]}")
	done

	say "将执行："
	printf '    %q' "$self"
	printf ' %q' "${args[@]}"
	printf ' %q\n' "$donor"
	if declare -f pa_dump >/dev/null; then
		say "同样的设置存成文件，下次不用再答："
		pa_dump | sed 's/^/    /'
		say "存好后：migrator -f <那个文件>"
	fi
	[ -n "${WZ_PRINT_ONLY:-}" ] && return 0
	confirm "就这样开始？"
	exec bash "$self" "${args[@]}"
}
