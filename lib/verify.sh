#!/bin/bash
# lib/verify.sh — the gate before the first boot of the migrated system, and the
# cutover. verify reads the target tree (mounted read-only, no journal replay) and
# the recipient's disk and answers one question: will this box boot, find its
# root and come up on eth0? Everything it expects comes from the plan ([target]
# [postfix] [network] [verify]); nothing here writes to the target. A single FAIL
# is exit 3: the disk is written and must NOT be rebooted until it is fixed.
# cutover takes the donor off the network (two hosts must never answer on one
# IP), proves it is gone, and only then boots this box.
# Needs common.sh, inventory.sh (parse_fstab, kvget, inv_*), plan.sh, apply.sh
# (masks_*, ap_dec, apply_partnode), target.sh and, for cutover, ssh.sh — all
# sourced before this file by the driver. Defines functions and defaults only.
#
#   verify_run [ROOT]        driver entry. Without ROOT: needs phase postfix done, mounts the
#                            target read-only (target_mount ro), runs the checks, unmounts.
#                            With ROOT: checks that tree as it is (tests, an operator's chroot).
#                            Green: phase.verify=done, verify.{warnings,kernel,initrd,cmdline},
#                            $RUN/summary, postfix_record (when declared, mounted mode only).
#                            Any FAIL: phase.verify=failed, exit 3.
#   verify_summary           the MAC -> name table of [network] pins, the BMC-console line and
#                            the manual follow-ups postfix left in state postfix.followups
#   cutover_run MODE         netdown|poweroff|kexec|none (needs phase verify done, or force=1)
#
# The checks (vf_check_<name>, each reports through vf_ok / vf_warn / vf_fail):
#   boot         the entry grub boots by default resolves, its kernel and initrd exist
#   initramfs    every initramfs carries the recipient's drivers, none carries the donor's
#                LVM devices file, the udev pin is inside (best-effort)
#   fstab        every entry without nofail resolves on this box now; swap UUIDs; RESUME=
#   cmdline      no md leftovers in any cmdline source; root= resolves; net.ifnames=0 biosdevname=0
#   filesystems  raw feature masks equal the donor's ([verify] features=)
#   bootloader   bios: boot code in the MBR (+ bios_grub on gpt) and grub's modules;
#                uefi: loaders on the ESP, the removable path, NVRAM entry, BootOrder
#   network      the primary config is on eth0, the donor's MAC is gone from the configs
#   md           raid=1: every [md] array is running with both members (resync may be on),
#                its UUID is the plan's, mdadm.conf lists exactly these arrays, the default
#                initramfs carries mdadm + its conf + the raid1 module; bootloader checks
#                disk2 / the second ESP as well
#   misc         mdadm.conf without ARRAY (raid=1: with ours), /.autorelabel, machine-id, free space
#
# Pure parsers (a tree in, text out; tests drive them directly):
#   vf_boot_entry ROOT [BLS] "kernel<TAB>initrd<TAB>cmdline<TAB>source" of the DEFAULT entry.
#                            kernel/initrd are paths inside the tree ("/boot/vmlinuz-…") when
#                            the file exists, else the path as grub has it; "-" = no initrd /
#                            empty cmdline. Status 1 + the reason on stderr when there is no
#                            entry at all. BLS=1 forces loader/entries (plan [postfix] bls=).
#   vf_grubcfg ROOT          the grub.cfg grub really reads (a "configfile" stub is followed)
#   vf_grub_default CFG ENV  what "set default" evaluates to (next_entry/saved_entry via grubenv)
#   vf_grubenv_get FILE KEY  a value of the 1024-byte grubenv block
#   vf_cmdline_sources ROOT  "source<TAB>value" for every cmdline source in the tree
#   vf_efi_parse PARTUUID    efibootmgr -v on stdin -> "esp=<BootNNNN|-> pxe=<N> first=<NNNN|-> firstpxe=0|1"
#   co_in_cidr IP CIDR       0 when IP lies in CIDR
#
# Seams (plain functions a test, or an operator's wrapper, redefines after sourcing):
#   vf_initrd_list FILE      list an initramfs (lsinitramfs, else the tree's lsinitrd); 2 = no lister
#   vf_resolve_spec SPEC     fstab/cmdline spec -> block device on this box; 1 = does not resolve
#   vf_masks_of DEV TYPE     canonical feature masks of DEV (masks_of_fs); 2 = device absent
#   vf_disk_head DISK        the first 440 bytes of DISK on stdout; 2 = disk absent
#   vf_part_head PART        the first sector of PART on stdout; 2 = partition absent
#   vf_partuuid DEV          PARTUUID of DEV (blkid)
#   vf_efibootmgr            efibootmgr -v; 2 = this Live did not boot through UEFI
#   vf_mdstat                /proc/mdstat; 2 = none on this box
#   vf_md_uuid DEV           the UUID of a running array (mdadm --detail); 2 = not running here
#   vf_esp_files DEV         loader files on an ESP that is not mounted (the mirror's second ESP); 2 = absent
#   vf_root_usage ROOT       use% of the filesystem holding ROOT (df)
#   co_ping ADDR             one ping, 1 s timeout; 0 = ADDR answers
#   co_boot CMD...           the commands that leave this Live (kexec -l, systemctl kexec/reboot)
#   co_local_cidrs           this Live's IPv4 addresses as CIDR, one per line
#
# Why our own grub.cfg parser: local-boot (the Live's kexec helper) is not patched
# for this tool; its awk is vendored below and extended with submenu paths ("1>2"),
# exact title/id matching and BLS (loader/entries + grubenv saved_entry/kernelopts),
# without which a RHEL 8/9 would be verified against a menu entry that does not exist.
# Dry run (-n): the target is only ever mounted read-only, so the checks run for
# real when there is a target to look at; no state, no summary, no record. cutover
# under -n prints every step and calls none of them.

VF_CHECKS="boot initramfs fstab cmdline filesystems bootloader network md misc"
VF_OK=0; VF_WARN=0; VF_FAIL=0
VF_ROOT=; VF_PLAN=
VF_KERNEL=; VF_INITRD=; VF_CMDLINE=; VF_SOURCE=; VF_KVER=
VF_BOOTTEST_K=; VF_BOOTTEST_I=; VF_BOOTTEST_CMD=; VF_BOOTTEST_DISK=; VF_BOOTTEST_WAIT=600
# cutover timing, seconds (tests shorten them)
: "${MIGRATOR_CUTOVER_WAIT_S:=5}"       # after the donor command, before the first ping
: "${MIGRATOR_CUTOVER_TIMEOUT_S:=30}"   # pings per address before "still answers"
: "${MIGRATOR_CUTOVER_POLL_S:=1}"       # pause after a ping that was answered
: "${MIGRATOR_CUTOVER_AGENT_S:=180}"    # on-line: how long to wait for the donor's poller to come for the cutover command

# --- reporting ---------------------------------------------------------------------
vf_section() { echo "=== $1 ==="; log "verify: === $1 ==="; }
vf_ok()   { VF_OK=$((VF_OK+1)); echo "  [ OK ] $*"; log "verify: [ OK ] $*"; }
# vf_warn TEXT [HINT]: HINT is the command or place to check by hand
vf_warn() {
	VF_WARN=$((VF_WARN+1)); echo "  [WARN] $1"; log "verify: [WARN] $1"
	[ -z "${2:-}" ] || { echo "         check: $2"; log "verify:        check: $2"; }
}
vf_fail() { VF_FAIL=$((VF_FAIL+1)); echo "  [FAIL] $*"; log "verify: [FAIL] $*"; }
vf_info() { echo "  [INFO] $*"; log "verify: [INFO] $*"; }
vf_plan() { plan_get "$VF_PLAN" "$1" "$2"; }

# --- seams ---------------------------------------------------------------------------
vf_initrd_list() {
	if have lsinitramfs; then lsinitramfs "$1" 2>/dev/null; return; fi
	# a dracut image on a Live without lsinitramfs: the tree's own lister, inside the tree
	if [ -x "$TARGET_MNT/usr/bin/lsinitrd" ] || [ -x "$TARGET_MNT/bin/lsinitrd" ]; then
		target_chroot_q lsinitrd "${1#"$TARGET_MNT"}" 2>/dev/null; return
	fi
	return 2
}
vf_resolve_spec() {
	local s=${1//\"/} d
	case $s in
		UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
			d=$(findfs "$s" 2>/dev/null) || d=/dev/disk/by-$(printf '%s' "${s%%=*}" | tr '[:upper:]' '[:lower:]')/${s#*=};;
		/dev/*) d=$s;;
		*) return 1;;
	esac
	[ -b "$d" ] || return 1
	printf '%s\n' "$d"
}
vf_masks_of()   { [ -b "$1" ] || return 2; masks_of_fs "$1" "$2"; }
vf_disk_head()  { [ -b "$1" ] || return 2; dd if="$1" bs=440 count=1 status=none 2>/dev/null; }
vf_part_head()  { [ -b "$1" ] || return 2; dd if="$1" bs=512 count=1 status=none 2>/dev/null; }
vf_partuuid()   { blkid -c /dev/null -o value -s PARTUUID "$1" 2>/dev/null; }
vf_efibootmgr() { [ -d /sys/firmware/efi ] || return 2; efibootmgr -v 2>/dev/null; }
vf_mdstat()     { [ -r /proc/mdstat ] || return 2; cat /proc/mdstat; }
vf_md_uuid()    { grep -q "^${1#/dev/} " /proc/mdstat 2>/dev/null || return 2; mdadm --detail "$1" 2>/dev/null | sed -n 's/^[[:space:]]*UUID : //p' | head -1; }
# vf_esp_files DEV: "EFI/x/y.efi" per loader on the vfat DEV, mounted read-only for the look
vf_esp_files() {
	local m rc=0
	[ -b "$1" ] || return 2
	m=$(mktemp -d /run/migrator-esp.XXXXXX) || return 1
	if mount -t vfat -o ro "$1" "$m" 2>/dev/null; then
		(cd "$m" && find . -type f -iname '*.efi' | sed 's|^\./||' | sort)
		umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
	else rc=1; fi
	rmdir "$m" 2>/dev/null
	return $rc
}
vf_raid() { [ "$(vf_plan target raid)" = 1 ]; }
vf_root_usage() { df -P "$1" 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $5 }'; }

# ==============================================================================
# grub: which entry boots by default (pure)
# ==============================================================================
# a path as grub writes it -> "/path": quotes and a "(device)" prefix dropped
vf_grub_path() {
	local p=$1
	p=${p//\'/}; p=${p//\"/}
	case $p in \(*\)*) p=${p#*\)};; esac
	case $p in ''|/*) ;; *) p=/$p;; esac
	printf '%s\n' "$p"
}
# grubenv: "key=value" lines, then "#" padding up to 1024 bytes
vf_grubenv_get() { [ -f "$1" ] || return 0; LC_ALL=C sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# vf_grubenv ROOT: the first grubenv there is (grub2/grubenv is often a symlink into the ESP)
vf_grubenv() {
	local f
	for f in "$1/boot/grub2/grubenv" "$1/boot/grub/grubenv" "$1"/boot/efi/EFI/*/grubenv; do
		if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
	done
	return 1
}
# the ESP's grub.cfg of a distro-signed grub is three lines ending in "configfile …"
vf_grubcfg_is_stub() {
	local n; n=$(wc -c < "$1" 2>/dev/null) || return 1
	[ "$n" -lt 1024 ] && grep -q configfile "$1"
}
vf_grubcfg() {
	local root=$1 c stub="" prefix arg
	for c in "$root/boot/grub/grub.cfg" "$root/boot/grub2/grub.cfg" "$root"/boot/efi/EFI/*/grub.cfg; do
		[ -f "$c" ] || continue
		if vf_grubcfg_is_stub "$c"; then [ -n "$stub" ] || stub=$c; continue; fi
		printf '%s\n' "$c"; return 0
	done
	[ -n "$stub" ] || return 1
	# only a stub: read where it points ("set prefix=($root)'/grub2'" + "configfile $prefix/grub.cfg");
	# grub's root there is the /boot partition or the root filesystem
	prefix=$(vf_grub_path "$(sed -n 's/^[[:space:]]*set[[:space:]]\{1,\}prefix=//p' "$stub" | tail -1)")
	arg=$(sed -n 's/^[[:space:]]*configfile[[:space:]]\{1,\}//p' "$stub" | tail -1)
	arg=${arg//\$\{prefix\}/$prefix}; arg=${arg//\$prefix/$prefix}
	arg=$(vf_grub_path "$arg")
	[ -n "$arg" ] || return 1
	for c in "$root/boot$arg" "$root$arg"; do
		if [ -f "$c" ] && ! vf_grubcfg_is_stub "$c"; then printf '%s\n' "$c"; return 0; fi
	done
	return 1
}
# vf_grub_default CFG ENV: the last "set default" wins (the one in the else branch of
# the next_entry test); ${saved_entry} and a pending next_entry come from grubenv
vf_grub_default() {
	local cfg=$1 env=$2 def v
	def=$(sed -n 's/^[[:space:]]*set default="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$cfg" | tail -1)
	if grep -q 'set default="\{0,1\}\$[{]\{0,1\}next_entry' "$cfg"; then
		v=$(vf_grubenv_get "$env" next_entry)
		if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
	fi
	case $def in *saved_entry*) def=$(vf_grubenv_get "$env" saved_entry);; esac
	printf '%s\n' "${def:-0}"
}
# vf_menuentry CFG DEFAULT [loose] -> "kernel \001 cmdline \001 initrd" of the entry DEFAULT
# names, or nothing. local-boot's awk, extended: top-level entries (menuentry AND
# submenu, column 0) are counted the way grub counts them; "a>b" walks into a submenu;
# a component is an index or an exact title / --id; "loose" is local-boot's substring
# match on the whole line. \001 cannot appear in a cmdline and is not IFS whitespace,
# so an empty field does not shift the others. mawk: no gensub, no [[:classes:]].
vf_menuentry() {
	awk -v def="$2" -v loose="${3:+1}" -v sep="$(printf '\001')" '
	function unq(s,   q, i) {
		q = substr(s, 1, 1)
		if (q == "\047" || q == "\"") { s = substr(s, 2); i = index(s, q); return i ? substr(s, 1, i - 1) : s }
		i = match(s, /[ \t{]/); return i ? substr(s, 1, i - 1) : s
	}
	function title_of(line,   s) { s = line; sub(/^[ \t]*(menuentry|submenu)[ \t]+/, "", s); return unq(s) }
	function id_of(line) {
		if (!match(line, /(--id|menuentry_id_option[}]?)[ \t]+/)) return ""
		return unq(substr(line, RSTART + RLENGTH))
	}
	function hit(c, idx, line) {
		if (c ~ /^[0-9]+$/) return idx == c + 0
		if (loose) return index(line, c) > 0
		return title_of(line) == c || id_of(line) == c
	}
	function flush() { if (active && kpath != "" && !done) { print kpath sep cmd sep ipath; done = 1 } }
	function setactive(m) { flush(); active = m; kpath = ""; ipath = ""; cmd = "" }
	BEGIN { n = split(def, D, ">"); top = -1; submatch = 0 }
	done { exit }
	/^(menuentry|submenu)[ \t]/ {
		top++; subidx = -1
		m = hit(D[1], top, $0)
		if ($1 == "submenu") { setactive(0); submatch = m; next }
		submatch = 0; setactive(n == 1 && m); next
	}
	/^[ \t]+menuentry[ \t]/ {
		subidx++
		if (n >= 2) m = submatch && hit(D[n], subidx, $0)
		else if (D[1] ~ /^[0-9]+$/) m = submatch && subidx == 0
		else m = hit(D[1], -1, $0)
		setactive(m); next
	}
	active && $1 ~ /^linux(16|efi)?$/ { kpath = $2; $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); cmd = $0; next }
	active && $1 ~ /^initrd(16|efi)?$/ {
		# several images (microcode first): the last one is the initramfs
		for (i = NF; i >= 2; i--) if ($i !~ /^\$/) { ipath = $i; break }
		flush()
	}
	END { flush() }' "$1"
}
# unexpanded grub variables ($vt_handoff, $tuned_params) are not kernel arguments;
# $kernelopts is the one that matters: grubenv, else grub.cfg's own fallback
vf_expand_opts() {   # OPTIONS ENVFILE CFG
	local -a w; local t out="" ko
	read -ra w <<< "$1"
	for t in "${w[@]}"; do
		case $t in
			"\$kernelopts"|"\${kernelopts}")
				ko=$(vf_grubenv_get "$2" kernelopts)
				if [ -z "$ko" ] && [ -f "${3:-}" ]; then ko=$(sed -n 's/^[[:space:]]*set kernelopts="\(.*\)"[[:space:]]*$/\1/p' "$3" | tail -1); fi
				t=$(vf_expand_opts "$ko" "" "");;
			"\$"*) continue;;
		esac
		[ -z "$t" ] || out="${out:+$out }$t"
	done
	printf '%s\n' "$out"
}
# vf_boot_path ROOT GRUBPATH: grub paths are relative to grub's root, the /boot
# partition ("/vmlinuz-…") or the root filesystem ("/boot/vmlinuz-…"): try both.
# -> the path inside the tree (status 0), or the grub path as it is (status 1)
vf_boot_path() {
	local root=$1 p; p=$(vf_grub_path "$2")
	[ -n "$p" ] || { echo -; return 1; }
	if [ -f "$root/boot$p" ]; then printf '%s\n' "/boot$p"; return 0; fi
	if [ -f "$root$p" ]; then printf '%s\n' "$p"; return 0; fi
	printf '%s\n' "$p"; return 1
}
# vf_bls_entry ROOT ENV CFG: the default among boot/loader/entries/*.conf. saved_entry
# names an entry id (the file name without .conf), a title or an index into blscfg's
# list (newest first); without it, or when it names nothing, the newest non-rescue one.
vf_bls_entry() {
	local root=$1 env=$2 cfg=$3 dir=$1/boot/loader/entries saved f id t pick="" why k i o
	saved=$(vf_grubenv_get "$env" saved_entry)
	if [[ $saved =~ ^[0-9]+$ ]]; then
		pick=$(printf '%s\n' "$dir"/*.conf | sort -rV | sed -n "$((saved + 1))p"); why="saved_entry=$saved"
	elif [ -n "$saved" ]; then
		for f in "$dir"/*.conf; do
			id=${f##*/}; id=${id%.conf}
			t=$(sed -n 's/^title[[:space:]]\{1,\}//p' "$f" | head -1)
			if [ "$id" = "$saved" ] || [ "$t" = "$saved" ]; then pick=$f; why=saved_entry; break; fi
		done
	fi
	if [ -z "$pick" ]; then
		pick=$(printf '%s\n' "$dir"/*.conf | grep -v rescue | sort -V | tail -1)
		if [ -n "$saved" ]; then why="saved_entry=$saved not found, grub falls back to the first entry"; else why=latest; fi
	fi
	if [ -z "$pick" ] || [ ! -f "$pick" ]; then echo "no usable entry in ${dir#"$root"} (only rescue entries?)" >&2; return 1; fi
	k=$(awk '$1 == "linux" { print $2; exit }' "$pick")
	i=$(awk '$1 == "initrd" { for (j = NF; j >= 2; j--) if ($j !~ /^\$/) { print $j; exit } exit }' "$pick")
	o=$(awk '$1 == "options" { $1 = ""; sub(/^[ \t]+/, ""); printf "%s%s", s, $0; s = " " } END { print "" }' "$pick")
	[ -n "$k" ] || { echo "${pick#"$root"} has no linux line" >&2; return 1; }
	o=$(vf_expand_opts "$o" "$env" "$cfg")
	k=$(vf_boot_path "$root" "$k")
	if [ -n "$i" ]; then i=$(vf_boot_path "$root" "$i"); else i=-; fi
	id=${pick##*/}
	printf '%s\t%s\t%s\t%s\n' "$k" "$i" "${o:--}" "bls ${id%.conf} ($why)"
}
vf_boot_entry() {
	local root=${1%/} bls=${2:-} cfg env f have_bls="" def note out last k c i
	cfg=$(vf_grubcfg "$root") || cfg=""
	# the grubenv next to the real grub.cfg is the one grub loads
	if [ -n "$cfg" ] && [ -f "${cfg%/*}/grubenv" ]; then env=${cfg%/*}/grubenv; else env=$(vf_grubenv "$root") || env=""; fi
	for f in "$root"/boot/loader/entries/*.conf; do if [ -f "$f" ]; then have_bls=y; break; fi; done
	if [ -n "$have_bls" ] && { [ "$bls" = 1 ] || { [ -n "$cfg" ] && grep -q blscfg "$cfg"; }; }; then
		vf_bls_entry "$root" "$env" "$cfg"; return
	fi
	[ -n "$cfg" ] || { echo "no grub.cfg in the tree (boot/grub, boot/grub2, boot/efi/EFI/*)" >&2; return 1; }
	def=$(vf_grub_default "$cfg" "$env"); note="default=$def"; last=${def##*>}
	out=$(vf_menuentry "$cfg" "$def")
	if [ -z "$out" ] && ! [[ $last =~ ^[0-9]+$ ]]; then
		# "a>b" whose submenu part does not match: the last component as a title/id anywhere,
		# then local-boot's substring match
		[ "$last" = "$def" ] || out=$(vf_menuentry "$cfg" "$last")
		[ -n "$out" ] || out=$(vf_menuentry "$cfg" "$last" loose)
	fi
	if [ -z "$out" ] && [ "$def" != 0 ]; then
		out=$(vf_menuentry "$cfg" 0); note="default=$def not found, grub falls back to the first entry"
	fi
	[ -n "$out" ] || { echo "no bootable menuentry in ${cfg#"$root"} (default=$def)" >&2; return 1; }
	IFS=$'\001' read -r k c i <<< "$out"
	c=$(vf_expand_opts "$c" "$env" "$cfg")
	k=$(vf_boot_path "$root" "$k")
	if [ -n "$i" ]; then i=$(vf_boot_path "$root" "$i"); else i=-; fi
	printf '%s\t%s\t%s\t%s\n' "$k" "$i" "${c:--}" "menuentry ${cfg#"$root"} $note"
}

# ==============================================================================
# the checks
# ==============================================================================
# --- 1. boot entry ---------------------------------------------------------------------
vf_check_boot() {
	local root=$VF_ROOT line k i c s ver err=$RUN/verify.err
	vf_section "boot entry"
	VF_KERNEL=; VF_INITRD=; VF_CMDLINE=; VF_SOURCE=; VF_KVER=
	mkdir -p "$RUN"
	if ! line=$(vf_boot_entry "$root" "$(vf_plan postfix bls)" 2> "$err"); then
		vf_fail "no default boot entry: $(head -1 "$err" 2>/dev/null)"
		rm -f "$err"; vf_boot_state; return 0
	fi
	rm -f "$err"
	IFS=$'\t' read -r k i c s <<< "$line"
	[ "$c" != - ] || c=
	VF_SOURCE=$s; VF_CMDLINE=$c
	case $s in *"not found"*) vf_warn "the saved default names no entry ($s)" "grub-editenv list / grub-set-default in the target";; esac
	if [ -f "$root$k" ]; then
		ver=${k##*/}; case $ver in *-*) ver=${ver#*-};; *) ver='?';; esac
		VF_KERNEL=$k; VF_KVER=$ver
		vf_ok "default entry: kernel $ver ($k) [$s]"
	else
		vf_fail "kernel $k of the default entry is not in the tree, looked under /boot and / ($s)"
	fi
	if [ "$i" = - ]; then vf_fail "the default entry has no initrd line ($s)"
	elif [ -f "$root$i" ]; then VF_INITRD=$i; vf_ok "initrd $i"
	else vf_fail "initrd $i of the default entry is not in the tree, looked under /boot and / ($s)"; fi
	vf_info "cmdline: $c"
	vf_boot_state
}
# what cutover kexec boots: exactly what was verified (paths inside the target root)
vf_boot_state() {
	[ -z "$DRY" ] || return 0
	state_set verify.kernel "$VF_KERNEL"; state_set verify.initrd "$VF_INITRD"
	state_set verify.cmdline "$VF_CMDLINE"; state_set verify.source "$VF_SOURCE"
}

# --- 2. initramfs ------------------------------------------------------------------------
# module file names use either "-" or "_"; the kernel treats them as the same name
vf_has_module() { tr '-' '_' <<< "$1" | grep -Eq "(^|/)${2//-/_}\.ko(\.[a-z0-9]+)?\$"; }
vf_builtin() {   # ROOT KVER MODULE
	local f
	for f in "$1/lib/modules/$2/modules.builtin" "$1/usr/lib/modules/$2/modules.builtin"; do
		[ -f "$f" ] || continue
		tr '-' '_' < "$f" | grep -Eq "(^|/)${3//-/_}\.ko\$"; return
	done
	return 1
}
vf_check_initramfs() {
	local root=$VF_ROOT drivers pin f rel base ver list rc d miss bi isdef found="" raid=0 mdmiss
	local -a files=() drv=()
	vf_section "initramfs"
	drivers=$(vf_plan verify drivers); [ "$drivers" != - ] || drivers=
	pin=$(vf_plan network pin)
	! vf_raid || raid=1
	IFS=, read -ra drv <<< "$drivers"
	for f in "$root"/boot/initrd.img-* "$root"/boot/initramfs-*.img; do
		[ -f "$f" ] || continue
		case ${f##*/} in *kdump*|*rescue*|*.bak|*.old|*.dpkg-*|*.orig) continue;; esac
		files+=("$f"); [ "$f" != "$root$VF_INITRD" ] || found=y
	done
	# a default initrd under a name the patterns do not know is still the one that boots
	if [ -n "$VF_INITRD" ] && [ -z "$found" ]; then files+=("$root$VF_INITRD"); fi
	if [ ${#files[@]} -eq 0 ]; then vf_fail "no initramfs under /boot (initrd.img-*, initramfs-*.img)"; return 0; fi
	for f in "${files[@]}"; do
		rel=${f#"$root"}; base=${f##*/}
		case $base in
			initrd.img-*) ver=${base#initrd.img-};;
			initramfs-*.img) ver=${base#initramfs-}; ver=${ver%.img};;
			*) ver=$VF_KVER;;
		esac
		isdef=; [ "$rel" != "$VF_INITRD" ] || isdef=y
		list=$(vf_initrd_list "$f"); rc=$?
		if [ "$rc" -ne 0 ] || [ -z "$list" ]; then
			vf_warn "cannot inspect initramfs $rel (no lsinitramfs here and no lsinitrd in the tree, or the image is unreadable)" \
				"lsinitramfs $f | grep -E '(${drivers//,/|})\\.ko'"
			continue
		fi
		miss=; bi=
		for d in "${drv[@]}"; do
			[ -n "$d" ] || continue
			if vf_has_module "$list" "$d"; then continue; fi
			if vf_builtin "$root" "$ver" "$d"; then bi="${bi:+$bi,}$d"; continue; fi
			miss="${miss:+$miss,}$d"
		done
		if [ -z "$miss" ]; then
			vf_ok "$rel: driver(s) ${drivers:-none required} present${bi:+ ($bi built into the kernel)}"
		elif [ -n "$isdef" ]; then
			vf_fail "$rel (default entry) lacks driver(s) $miss: the kernel would not find this recipient's disk/NIC"
		else
			vf_warn "$rel lacks driver(s) $miss: kernel $ver would not boot on this recipient" "in the target: update-initramfs -u -k $ver  |  dracut -f --kver $ver"
		fi
		if grep -Eq '(^|[[:space:]/])etc/lvm/devices/system\.devices$' <<< "$list"; then
			vf_fail "$rel contains etc/lvm/devices/system.devices (the donor's PV ids: LVM would not activate the root here)"
		fi
		if [ "$raid" = 1 ]; then
			# the root (or its VG) is on an md array: the initramfs must be able to assemble it
			mdmiss=
			grep -Eq '(^|/)s?bin/mdadm$' <<< "$list" || mdmiss="mdadm"
			grep -Eq '(^|[[:space:]/])etc/mdadm/mdadm\.conf$' <<< "$list" || mdmiss="${mdmiss:+$mdmiss, }etc/mdadm/mdadm.conf"
			vf_has_module "$list" raid1 || vf_builtin "$root" "$ver" raid1 || mdmiss="${mdmiss:+$mdmiss, }raid1.ko"
			if [ -z "$mdmiss" ]; then vf_ok "$rel: mdadm, its mdadm.conf and raid1 are in (the arrays can be assembled at boot)"
			elif [ -n "$isdef" ]; then vf_fail "$rel (default entry) lacks $mdmiss: the md arrays would not be assembled, no root"
			else vf_warn "$rel lacks $mdmiss: kernel $ver could not assemble the md arrays" "in the target: update-initramfs -u -k $ver"; fi
		fi
		if [ "$pin" = 1 ]; then
			if grep -Eq '(^|[[:space:]/])etc/udev/rules\.d/70-persistent-net\.rules$' <<< "$list"; then
				vf_ok "$rel carries the udev pin (70-persistent-net.rules)"
			else
				vf_warn "$rel has no etc/udev/rules.d/70-persistent-net.rules: the eth0 pin is best-effort and applies only after the initramfs" \
					"lsinitramfs $f | grep persistent-net"
			fi
		fi
	done
}

# --- 3. fstab, swap, resume ------------------------------------------------------------------
vf_check_fstab() {
	local root=$VF_ROOT fstab=$VF_ROOT/etc/fstab l spec mp type nofail dev n=0 swapset uuid want removed added exp f v
	vf_section "fstab/swap"
	if [ ! -f "$fstab" ]; then vf_fail "no etc/fstab in the tree"; return 0; fi
	swapset=$(vf_plan verify swap); [ "$swapset" != - ] || swapset=
	while IFS= read -r l; do
		[ -n "$l" ] || continue
		n=$((n+1))
		spec=$(kvget "$l" spec); spec=${spec//\"/}; mp=$(kvget "$l" mount); type=$(kvget "$l" type); nofail=$(kvget "$l" nofail)
		case $spec in
			UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*|/dev/*)
				if dev=$(vf_resolve_spec "$spec"); then
					vf_ok "fstab: $spec ($mp) -> $dev"
					if [ "$type" = swap ] && [ "${spec%%=*}" = UUID ]; then
						uuid=${spec#UUID=}
						case ",${swapset,,}," in
							*",${uuid,,},"*) ;;
							*) vf_fail "fstab swap $spec is not a swap area the plan made ([verify] swap=${swapset:--})";;
						esac
					fi
				elif [ "$nofail" = 1 ]; then
					vf_info "fstab: $spec ($mp) does not resolve here; it has nofail, the boot goes on without it"
				else
					vf_fail "fstab: $spec ($mp) does not resolve to a block device on this recipient (the boot would stop in emergency mode)"
				fi;;
			/*)
				[ "$type" = swap ] || continue
				f=$root$spec
				if [ -f "$f" ] && [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ]; then vf_ok "swapfile $spec is there (mode 600)"
				elif [ "${VF_PRECHECK:-0}" = 1 ]; then vf_info "swapfile $spec: left to the post-freeze pass (in the pre-check the target is a snapshot whose COW is a tmpfs, D38)"
				else vf_warn "swapfile $spec is missing or not mode 600: swapon fails at boot, the system still comes up" \
					"in the target: dd if=/dev/zero of=$spec bs=1M count=<MiB> conv=fsync && chmod 600 $spec && mkswap $spec"; fi;;
		esac
	done < <(parse_fstab < "$fstab")
	f=$root/etc/initramfs-tools/conf.d/resume
	if [ -f "$f" ]; then
		v=$(inv_shvar RESUME "$f") || v=
		case $v in
			''|none|auto) ;;
			*)	if dev=$(vf_resolve_spec "$v"); then vf_ok "RESUME=$v -> $dev"
				else vf_warn "RESUME=$v (etc/initramfs-tools/conf.d/resume) does not resolve: the initramfs waits for it on every boot" \
					"set RESUME= to a swap of this box (or none), then update-initramfs -u"; fi;;
		esac
	fi
	want=$(vf_plan verify fstab)
	if [[ $want =~ ^[0-9]+$ ]]; then
		# what postfix did to the donor's N entries: [identity] "remove" on an fstab spec, "+ line" added
		removed=$(plan_section "$VF_PLAN" identity | awk -F'\t' '$2 == "remove" && $1 ~ /^(UUID=|LABEL=|PARTUUID=|PARTLABEL=|\/dev\/)/' | wc -l)
		added=$(plan_section "$VF_PLAN" identity | awk -F'\t' 'index($2, "+ ") == 1' | wc -l)
		exp=$((want - removed + added))
		if [ "$n" -eq "$exp" ]; then vf_ok "fstab has $n entries, as planned"
		else vf_warn "fstab has $n entries, the plan expects $exp (donor $want, $removed removed, $added added)" "compare $fstab with the donor's fstab"; fi
	fi
}

# --- 4. kernel cmdline ------------------------------------------------------------------------
vf_cmdline_sources() {
	local root=$1 f k v env
	for f in "$root/etc/default/grub" "$root"/etc/default/grub.d/*.cfg; do
		[ -f "$f" ] || continue
		for k in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
			v=$(inv_shvar "$k" "$f") || continue
			printf '%s\t%s\n' "${f#"$root"}:$k" "$v"
		done
	done
	if [ -f "$root/etc/kernel/cmdline" ]; then printf '%s\t%s\n' /etc/kernel/cmdline "$(head -1 "$root/etc/kernel/cmdline")"; fi
	for f in "$root"/boot/loader/entries/*.conf; do
		[ -f "$f" ] || continue
		printf '%s\t%s\n' "${f#"$root"}" "$(awk '$1 == "options" { $1 = ""; sub(/^[ \t]+/, ""); printf "%s%s", s, $0; s = " " } END { print "" }' "$f")"
	done
	if env=$(vf_grubenv "$root"); then
		v=$(vf_grubenv_get "$env" kernelopts)
		[ -z "$v" ] || printf '%s\t%s\n' "${env#"$root"}:kernelopts" "$v"
	fi
	return 0
}
# vf_missing_tokens WANT HAVE: the words of WANT that are not words of HAVE
vf_missing_tokens() {
	local -a w; local t out=""
	read -ra w <<< "$1"
	for t in "${w[@]}"; do case " $2 " in *" $t "*) ;; *) out="${out:+$out }$t";; esac; done
	printf '%s\n' "$out"
}
vf_check_cmdline() {
	local root=$VF_ROOT forbid src val tok p hits=0 nsrc=0 want miss grubdef="" have_grub="" kcmd="" have_kcmd="" rootspec="" dev
	local -a pats=() toks=()
	vf_section "kernel cmdline"
	forbid=$(vf_plan verify cmdline_forbid); [ "$forbid" != - ] || forbid=
	IFS=, read -ra pats <<< "$forbid"
	while IFS=$'\t' read -r src val; do
		[ -n "$src" ] || continue
		nsrc=$((nsrc+1))
		case $src in
			/etc/default/grub*) have_grub=y; grubdef="$grubdef $val";;
			/etc/kernel/cmdline) have_kcmd=y; kcmd=$val;;
		esac
		read -ra toks <<< "$val"
		for tok in "${toks[@]}"; do
			for p in "${pats[@]}"; do
				[ -n "$p" ] || continue
				case $tok in *"$p"*) vf_fail "$src: forbidden token '$tok' (matches $p): it names the donor's md arrays, which are not here$(vf_raid && echo " (this recipient's arrays are found by UUID through mdadm.conf)")"; hits=$((hits+1)); break;; esac
			done
		done
	done < <(vf_cmdline_sources "$root"; [ -z "$VF_SOURCE" ] || printf '%s\t%s\n' "default entry" "$VF_CMDLINE")
	[ "$hits" -gt 0 ] || vf_ok "no forbidden token (${forbid//,/ }) in $nsrc cmdline source(s)"
	if [ -n "$VF_SOURCE" ]; then
		read -ra toks <<< "$VF_CMDLINE"
		for tok in "${toks[@]}"; do case $tok in root=*) rootspec=${tok#root=};; esac; done
		if [ -z "$rootspec" ]; then vf_fail "the default entry's cmdline has no root="
		elif dev=$(vf_resolve_spec "$rootspec"); then vf_ok "root=$rootspec -> $dev"
		else vf_fail "root=$rootspec of the default entry does not resolve on this recipient"; fi
	fi
	want=$(ap_dec "$(vf_plan network cmdline)"); [ "$want" != - ] || want=
	[ -n "$want" ] || return 0
	if [ -n "$VF_SOURCE" ]; then
		miss=$(vf_missing_tokens "$want" "$VF_CMDLINE")
		if [ -z "$miss" ]; then vf_ok "default entry carries $want"
		else vf_fail "default entry lacks $miss: the NIC would not be named $(vf_plan network target), where the config is"; fi
	fi
	if [ -n "$have_grub" ]; then
		miss=$(vf_missing_tokens "$want" "$grubdef")
		if [ -z "$miss" ]; then vf_ok "/etc/default/grub carries $want"
		else vf_fail "/etc/default/grub (GRUB_CMDLINE_LINUX) lacks $miss: the next grub-mkconfig would drop it from every entry"; fi
	else
		vf_info "no etc/default/grub in the tree: only the boot entry itself was checked for $want"
	fi
	if [ -n "$have_kcmd" ]; then
		miss=$(vf_missing_tokens "$want" "$kcmd")
		[ -z "$miss" ] || vf_warn "/etc/kernel/cmdline lacks $miss: entries of kernels installed later would miss it" "add it to $root/etc/kernel/cmdline"
	fi
}

# --- 6. filesystems: the feature masks once more -------------------------------------------------
vf_check_filesystems() {
	local features e dev rest fstype raw names src donor mine rc
	local -a list=()
	vf_section "filesystems"
	features=$(vf_plan verify features)
	if [ -z "$features" ] || [ "$features" = - ]; then vf_info "the plan lists no feature masks ([verify] features=-)"; return 0; fi
	IFS=, read -ra list <<< "$features"
	for e in "${list[@]}"; do
		[ -n "$e" ] || continue
		dev=${e%%:*}; rest=${e#*:}; fstype=${rest%%:*}; raw=$(ap_dec "${rest#*:}"); names='?'
		# xfs: the plan holds the numeric masks; the donor's feature names are in its inventory
		if [ "$fstype" = xfs ] && [ -r "$RUN/donor.inv" ]; then
			src=$(plan_section "$VF_PLAN" volumes | awk -F'\t' -v t="target=$dev" '{ for (i = 1; i <= NF; i++) if ($i == t) { print substr($1, 5); exit } }')
			[ -z "$src" ] || names=$(pl_lookup "$RUN/donor.inv" fs dev "$src" features)
		fi
		donor=$(masks_norm "$fstype" "$raw" "${names:-?}") || { vf_warn "$dev: cannot compare $fstype feature masks (unknown type)" "-"; continue; }
		mine=$(vf_masks_of "$dev" "$fstype"); rc=$?
		if [ "$rc" -eq 2 ]; then
			vf_warn "$dev is not on this box: its $fstype feature masks were not compared" "dumpe2fs -h $dev | grep -i features  /  xfs_db -r -c version $dev"
		elif [ "$rc" -ne 0 ] || [ -z "$mine" ]; then
			vf_fail "$dev: cannot read the $fstype feature masks"
		elif masks_equal "$donor" "$mine"; then
			vf_ok "$dev: $fstype feature masks equal the donor's"
		else
			vf_fail "$dev: $fstype feature masks differ from the donor's: $(masks_diff "$donor" "$mine" | paste -sd';' -)"
		fi
	done
}

# --- 7. bootloader ----------------------------------------------------------------------------------
# vf_efi_parse PARTUUID < "efibootmgr -v": the entry whose loader sits on that partition,
# how many network entries there are, and whether BootOrder starts with one
vf_efi_parse() {
	awk -v pu="$1" '
	/^BootOrder:/ { order = $2 }
	/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
		id = toupper(substr($1, 5, 4)); line = tolower($0)
		if (pu != "" && pu != "-" && esp == "" && index(line, "hd(") && index(line, tolower(pu))) esp = id
		if (line ~ /mac\(|ipv4\(|ipv6\(|pxe|network/) { pxe[id] = 1; npxe++ }
	}
	END {
		split(order, o, ","); first = toupper(o[1])
		printf "esp=%s pxe=%d first=%s firstpxe=%d\n", (esp == "" ? "-" : "Boot" esp), npxe, (first == "" ? "-" : first), ((first in pxe) ? 1 : 0)
	}'
}
# vf_bios_disk DISK LABEL: the MBR boot code (and the bios_grub partition on gpt) of one disk
vf_bios_disk() {
	local disk=$1 label=$2 out n rc bg part
	out=$(vf_disk_head "$disk" | LC_ALL=C grep -a -c GRUB; echo "${PIPESTATUS[0]}")
	n=${out%%$'\n'*}; rc=${out##*$'\n'}
	if [ "$rc" = 2 ]; then vf_warn "$disk is not on this box: the MBR boot code was not checked" "dd if=$disk bs=440 count=1 | grep -c GRUB"
	elif [ "${n:-0}" -ge 1 ]; then vf_ok "$disk: GRUB boot code in the MBR"
	else vf_fail "$disk: no GRUB boot code in the first 440 bytes (grub-install did not run on the target disk)"; fi
	if [ "$label" = gpt ]; then
		bg=$(vf_plan target bios_grub)
		if [ -z "$bg" ] || [ "$bg" = - ]; then
			vf_fail "gpt + bios without a bios_grub partition in the plan: grub has nowhere to put core.img"
		else
			part=$(apply_partnode "$disk" "$bg")
			out=$(vf_part_head "$part" | tr -d '\0' | wc -c; echo "${PIPESTATUS[0]}")
			n=${out%%$'\n'*}; rc=${out##*$'\n'}
			if [ "$rc" = 2 ]; then vf_fail "bios_grub partition $part does not exist"
			elif [ "${n:-0}" -gt 0 ]; then vf_ok "$part (bios_grub) carries grub's core image"
			else vf_fail "$part (bios_grub) is empty: grub-install did not write core.img"; fi
		fi
	fi
}
vf_check_bootloader() {
	local root=$VF_ROOT fw label disk out n rc espmp espdir loaders removable espdev pu efi res disk2='' esp2='' list
	vf_section "bootloader"
	fw=$(vf_plan target firmware); label=$(vf_plan target label); disk=$(vf_plan target disk)
	if vf_raid; then disk2=$(vf_plan target disk2); esp2=$(vf_plan verify esp2); [ "$esp2" != - ] || esp2=; fi
	case $fw in
	bios)
		vf_bios_disk "$disk" "$label"
		[ -z "$disk2" ] || vf_bios_disk "$disk2" "$label"
		if [ -f "$root/boot/grub/i386-pc/normal.mod" ] || [ -d "$root/boot/grub2/i386-pc" ]; then vf_ok "grub's i386-pc modules are under /boot"
		else vf_fail "no boot/grub/i386-pc/normal.mod (or boot/grub2/i386-pc) in the tree: grub would drop to its rescue prompt"; fi;;
	uefi)
		espmp=; [ ! -f "$root/etc/fstab" ] || espmp=$(parse_fstab < "$root/etc/fstab" | awk -F'\t' '
			{ m = ""; t = ""; for (i = 1; i <= NF; i++) { if (index($i, "mount=") == 1) m = substr($i, 7); if (index($i, "type=") == 1) t = substr($i, 6) }
			  if (t == "vfat" && (m == "/boot/efi" || m == "/efi" || m == "/boot")) { print m; exit } }')
		if [ -z "$espmp" ]; then vf_fail "uefi: no vfat entry for the ESP (/boot/efi) in etc/fstab"; return 0; fi
		espdir=$root$espmp
		# vfat is case-blind; a test tree on ext4 is not: match names without regard to case
		loaders=$(find "$espdir" -mindepth 3 -maxdepth 3 -type f \( -iname grubx64.efi -o -iname shimx64.efi \) -ipath "$espdir/EFI/*" ! -ipath "$espdir/EFI/BOOT/*" 2>/dev/null | sort)
		removable=$(find "$espdir" -mindepth 3 -maxdepth 3 -type f -ipath "$espdir/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | head -1)
		if [ -n "$loaders" ]; then
			vf_ok "ESP ($espmp): $(paste -sd' ' - <<< "${loaders//"$espdir/"/}")"
			if [ -n "$removable" ]; then vf_ok "ESP: removable path EFI/BOOT/BOOTX64.EFI is there"
			else vf_warn "ESP has no EFI/BOOT/BOOTX64.EFI: a firmware that lost its NVRAM entry finds nothing to boot" "in the target: grub-install --target=x86_64-efi --removable --no-nvram"; fi
		elif [ -n "$removable" ] && [ "$(vf_plan target grub_from_live)" = 1 ]; then
			# a firmware change installs grub from the Live with --removable only
			vf_ok "ESP ($espmp): EFI/BOOT/BOOTX64.EFI (removable install from the Live, no EFI/<id>/ by design)"
		else
			vf_fail "ESP ($espmp) has no EFI/<id>/grubx64.efi or shimx64.efi: nothing for the firmware to load"
			[ -n "$removable" ] || vf_warn "ESP has no EFI/BOOT/BOOTX64.EFI either" "ls -R $espdir"
		fi
		if [ -n "$disk2" ]; then
			if [ -z "$esp2" ]; then vf_fail "raid=1 on uefi without a second ESP in the plan: $disk2 could not boot on its own"
			else
				list=$(vf_esp_files "$esp2"); rc=$?
				if [ "$rc" = 2 ]; then vf_warn "second ESP $esp2 is not on this box: not checked" "mount $esp2 and look for EFI/*/grubx64.efi"
				elif [ "$rc" -ne 0 ]; then vf_fail "second ESP $esp2 cannot be mounted (no vfat on it?)"
				elif grep -Eiq '^EFI/[^/]+/(grubx64|shimx64|bootx64)\.efi$' <<< "$list"; then vf_ok "second ESP $esp2: $(paste -sd' ' - <<< "$list")"
				else vf_fail "second ESP $esp2 carries no EFI loader: $disk2 could not boot on its own"; fi
			fi
		fi
		espdev=$(vf_plan verify esp); pu=
		if [ -n "$espdev" ] && [ "$espdev" != - ]; then pu=$(vf_partuuid "$espdev"); fi
		efi=$(vf_efibootmgr); rc=$?
		if [ "$rc" -ne 0 ] || [ -z "$efi" ]; then
			vf_info "this Live did not boot through UEFI (or efibootmgr is silent): NVRAM entries not inspected, the firmware will use the removable path"
			return 0
		fi
		res=$(vf_efi_parse "$pu" <<< "$efi")
		case $res in
			*"esp=-"*) vf_warn "no NVRAM boot entry points at the ESP ${espdev:-?} (PARTUUID ${pu:-unknown}): the firmware will use the removable path" "efibootmgr -v";;
			*) res=${res#esp=}; vf_ok "NVRAM: ${res%% *} loads from the ESP (PARTUUID $pu)"; res="esp=$res";;
		esac
		if [ -n "$esp2" ]; then
			pu=$(vf_partuuid "$esp2")
			case $(vf_efi_parse "$pu" <<< "$efi") in
				*"esp=-"*) vf_warn "no NVRAM boot entry points at the second ESP $esp2 (PARTUUID ${pu:-unknown}): with disk 1 gone the firmware must find the removable path on disk 2" "efibootmgr -v";;
				*) vf_ok "NVRAM: an entry loads from the second ESP $esp2 too";;
			esac
		fi
		case $res in
			*"pxe=0 "*) vf_info "no network boot entry in NVRAM: BootOrder not judged";;
			*"firstpxe=1"*) vf_ok "BootOrder starts with a network entry (the panel keeps control)";;
			*)	if [ "$(opt bootorder pxe)" = local ]; then vf_info "BootOrder starts with a local entry, as asked (bootorder=local)"
				else vf_warn "BootOrder does not start with a network (PXE) entry: the panel cannot netboot this box" "efibootmgr -o <pxe>,<others>   (or -o bootorder=local)"; fi;;
		esac;;
	*) vf_warn "unknown firmware '$fw' in the plan: bootloader not checked" "[target] firmware= in $VF_PLAN";;
	esac
}

# --- 8. network ---------------------------------------------------------------------------------------
# the files the network passes of postfix own (every supported config format + the udev pin)
vf_netcfg_files() {
	local root=$1 f
	for f in "$root/etc/network/interfaces" "$root"/etc/network/interfaces.d/* "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml \
	         "$root"/etc/systemd/network/*.network "$root"/etc/systemd/network/*.link "$root"/etc/systemd/network/*.netdev \
	         "$root"/etc/sysconfig/network-scripts/ifcfg-* "$root"/etc/sysconfig/network-scripts/route-* "$root"/etc/sysconfig/network-scripts/rule-* \
	         "$root"/etc/NetworkManager/system-connections/* "$root/etc/udev/rules.d/70-persistent-net.rules"; do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
	return 0
}
# vf_net_primary ROOT KIND IFACE MAC: 0 the config of KIND names IFACE (or binds to MAC), 1 it does not, 2 unknown KIND
vf_net_primary() {
	local root=$1 kind=$2 iface=$3 mac=$4 alt="" rc
	# grep -s on a glob that matched nothing still exits 2: only "found" (0) counts
	case $kind in
		interfaces) grep -Eqs "^[[:space:]]*iface[[:space:]]+$iface([[:space:]]|\$)" "$root/etc/network/interfaces" "$root"/etc/network/interfaces.d/*; rc=$?;;
		netplan)    grep -Eqs "^[[:space:]]+$iface:[[:space:]]*(#.*)?\$" "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml; rc=$?;;
		networkd)   [ -z "$mac" ] || alt="|MACAddress=$mac"
		            grep -Eiqs "^[[:space:]]*(Name=$iface$alt)[[:space:]]*\$" "$root"/etc/systemd/network/*.network; rc=$?;;
		ifcfg)      [ -f "$root/etc/sysconfig/network-scripts/ifcfg-$iface" ]; rc=$?;;
		nm-keyfile|keyfile)
		            [ -z "$mac" ] || alt="|mac-address=$mac"
		            grep -Eiqs "^[[:space:]]*(interface-name=$iface$alt)[[:space:]]*\$" "$root"/etc/NetworkManager/system-connections/*; rc=$?;;
		*) return 2;;
	esac
	[ "$rc" -eq 0 ] || return 1
	return 0
}
# vf_netplan_nm_auto ROOT: 0 when netplan names no interface at all and delegates to
# NetworkManager (stock Ubuntu desktop: NM creates the wired DHCP connection at boot for
# whatever the NIC is called; net.ifnames=0 makes that the target name). Any ethernets:
# section, any other renderer, or a NetworkManager that does not start means "checked".
vf_netplan_nm_auto() {
	local root=$1 f found=
	[ -e "$root/usr/sbin/NetworkManager" ] || return 1
	compgen -G "$root/etc/systemd/system/*.wants/NetworkManager.service" >/dev/null 2>&1 || return 1
	for f in "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml; do
		[ -f "$f" ] || continue
		grep -Eq '^[[:space:]]*ethernets:[[:space:]]*(#.*)?$' "$f" && return 1
		grep -Eq '^[[:space:]]*renderer:[[:space:]]*NetworkManager[[:space:]]*(#.*)?$' "$f" && found=1
	done
	[ -n "$found" ]
}
# the line to type on the BMC console when the boot NIC did not become TARGET
vf_bmc_fix() {   # TARGET MAC [CURRENT NAME]
	local t=$1 mac=$2 cur=${3:-}
	if [ -n "$cur" ]; then echo "ip link set $t down; ip link set $t name ${t}x; ip link set $cur down; ip link set $cur name $t; ip link set $t up"
	else echo "n=\$(grep -il $mac /sys/class/net/*/address | cut -d/ -f5); [ \"\$n\" = $t ] || { ip link set $t down; ip link set $t name ${t}x; ip link set \$n down; ip link set \$n name $t; ip link set $t up; }"; fi
}
vf_check_network() {
	local root=$VF_ROOT donor oldnic oldmac kind target mac rc f hits others inv=$RUN/recipient.inv r pci i=0 bootidx="" first=""
	local -a managed=() nics=()
	vf_section "network"
	donor=$(vf_plan network donor); target=$(vf_plan network target); mac=$(vf_plan network mac)
	oldnic=${donor%%/*}; kind=${donor##*/}; oldmac=${donor#*/}; oldmac=${oldmac%/*}
	[ "$mac" != - ] || mac=
	[ "$oldmac" != - ] || oldmac=
	if [ -z "$target" ] || [ "$target" = - ]; then vf_warn "the plan names no target interface: network config not checked" "[network] in $VF_PLAN"; return 0; fi
	vf_net_primary "$root" "$kind" "$target" "$mac"; rc=$?
	case $rc in
		0) vf_ok "primary network config ($kind) is on $target (donor: $oldnic)";;
		2) vf_warn "the donor's network config format is '$kind': not checked, $target may have no config" "look for $oldnic under $root/etc";;
		*)	if [ "$kind" = netplan ] && vf_netplan_nm_auto "$root"; then
				vf_warn "netplan names no interface and delegates to NetworkManager: NM auto-connects $target with DHCP, as it did on the donor"
			else
				vf_fail "primary network config ($kind) does not name $target (the donor's $oldnic was not renamed): no network after the boot"
			fi;;
	esac
	mapfile -t managed < <(vf_netcfg_files "$root")
	if [ -n "$oldmac" ] && [ "${oldmac,,}" != "${mac,,}" ]; then
		hits=
		for f in "${managed[@]}"; do if grep -qiF -- "$oldmac" "$f" 2>/dev/null; then hits="${hits:+$hits }${f#"$root"}"; fi; done
		if [ -z "$hits" ]; then vf_ok "the donor's MAC $oldmac is in no network config"
		else vf_fail "the donor's MAC $oldmac is still in: $hits (the config would bind to a NIC this box does not have)"; fi
		others=$(grep -rIilF -- "$oldmac" "$root/etc" 2>/dev/null | while IFS= read -r f; do
			for r in "${managed[@]}"; do [ "$r" != "$f" ] || continue 2; done
			printf '%s\n' "${f#"$root"}"
		done | head -20 | paste -sd' ' -)
		[ -z "$others" ] || vf_warn "the donor's MAC $oldmac also appears in: $others" "firewall rules, rc.local, dispatcher scripts: replace it with ${mac:-the new MAC} where it matters"
	fi
	# several NICs: the kernel hands out eth0 in probe (PCI) order, the udev pin only tries to fix that
	[ -r "$inv" ] || return 0
	mapfile -t nics < <(inv_records "$inv" nic | while IFS= read -r r; do
		pci=$(inv_field "$r" pci)
		if [ -z "$pci" ] || [ "$pci" = - ]; then continue; fi
		printf '%s\t%s\n' "$pci" "$(inv_field "$r" mac)"
	done | LC_ALL=C sort)
	[ ${#nics[@]} -gt 1 ] || return 0
	for r in "${nics[@]}"; do
		[ -n "$first" ] || first=${r#*$'\t'}
		if [ "${r#*$'\t'}" = "${mac,,}" ] || [ "${r#*$'\t'}" = "$mac" ]; then bootidx=$i; fi
		i=$((i+1))
	done
	if [ "$bootidx" = 0 ]; then vf_ok "${#nics[@]} NICs, the boot NIC $mac is first in PCI order: the kernel names it $target by itself"
	else
		vf_warn "${#nics[@]} NICs and the boot NIC $mac is not the first in PCI order ($first is): $target may land on another NIC; the udev pin is best-effort" \
			"BMC console fix: $(vf_bmc_fix "$target" "$mac" "${bootidx:+eth$bootidx}")"
	fi
}

# --- 5 + 9. md arrays, mdadm.conf, selinux, machine-id, free space -------------------------------------------
# raid=1: every array of the plan runs here with both members, under the plan's UUID
vf_check_md() {
	local md stat line members up sync uuid want rc
	vf_raid || return 0
	vf_section "md arrays"
	stat=$(vf_mdstat); rc=$?
	if [ "$rc" = 2 ] || [ -z "$stat" ]; then vf_warn "no /proc/mdstat on this box: the arrays were not checked" "cat /proc/mdstat; mdadm --detail /dev/mdN"; return 0; fi
	for md in $(vf_plan target md | tr ',' ' '); do
		if [ -z "$md" ] || [ "$md" = - ]; then continue; fi
		line=$(grep "^${md#/dev/} " <<< "$stat")
		if [ -z "$line" ]; then vf_fail "$md is not running (apply made it, something stopped it): mdadm --assemble $md --uuid=<the plan's>"; continue; fi
		members=$(grep -o '[[:alnum:]_/-]*\[[0-9]*\]' <<< "$line" | grep -vc '(F)')
		up=$(awk -v m="${md#/dev/} " 'index($0, m) == 1 { on = 1; next } on && /\[[U_]+\]/ { if (match($0, /\[[U_]+\]/)) print substr($0, RSTART + 1, RLENGTH - 2); exit } /^md/ { on = 0 }' <<< "$stat")
		sync=$(awk -v m="${md#/dev/} " 'index($0, m) == 1 { on = 1; next } on && /(resync|recovery) *=/ { sub(/^[ \t]*\[[=>.]*\][ \t]*/, ""); sub(/^[ \t]+/, ""); print; exit } /^md/ { on = 0 }' <<< "$stat")
		case $line in *"(F)"*) vf_fail "$md has a failed member: $line"; continue;; esac
		if [ "$members" -lt 2 ] || [ "$up" != UU ]; then vf_fail "$md is degraded ([${up:-?}], $members member(s)): both disks must be in before the first boot: $line"
		elif [ -n "$sync" ]; then vf_ok "$md: both members in, $sync (continues in the background, also after the boot)"
		else vf_ok "$md: both members in sync"; fi
		want=$(plan_section "$VF_PLAN" md | awk -v d="$md" '$3 == d { for (i = 4; i <= NF; i++) if (index($i, "--uuid=") == 1) print substr($i, 8) }')
		uuid=$(vf_md_uuid "$md"); rc=$?
		if [ "$rc" = 2 ] || [ -z "$uuid" ]; then vf_warn "$md: its UUID could not be read (mdadm --detail)" "mdadm --detail $md"
		elif [ "$uuid" = "$want" ]; then vf_ok "$md: UUID $uuid is the plan's (mdadm.conf and the initramfs find it)"
		else vf_fail "$md: UUID $uuid is not the plan's $want: mdadm.conf names an array that does not exist"; fi
	done
}
vf_check_mdadm() {
	local root=$VF_ROOT f n found="" line missing="" extra
	if vf_raid; then
		for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do
			[ -f "$root$f" ] || continue
			found=y
			while IFS= read -r line; do
				grep -qxF -- "$line" "$root$f" || missing="${missing:+$missing; }$line"
			done < <(plan_md_arrays "$VF_PLAN")
			extra=$(grep -E '^[[:space:]]*ARRAY[[:space:]]' "$root$f" | grep -vxF -f <(plan_md_arrays "$VF_PLAN") | head -3 | paste -sd';' -)
			if [ -z "$missing" ] && [ -z "$extra" ]; then vf_ok "$f lists exactly this recipient's $(plan_md_arrays "$VF_PLAN" | wc -l) array(s)"
			else
				[ -z "$missing" ] || vf_fail "$f lacks: $missing (the initramfs assembles what mdadm.conf names)"
				[ -z "$extra" ] || vf_fail "$f has ARRAY line(s) of arrays that are not here: $extra"
			fi
		done
		[ -n "$found" ] || vf_fail "no mdadm.conf in the tree: the initramfs would not know the arrays (postfix writes /etc/mdadm/mdadm.conf)"
		return 0
	fi
	for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do
		[ -f "$root$f" ] || continue
		found=y
		n=$(grep -cE '^[[:space:]]*ARRAY[[:space:]]' "$root$f")
		if [ "$n" -eq 0 ]; then vf_ok "$f has no active ARRAY line"
		else vf_fail "$f still has $n active ARRAY line(s): the initramfs would wait for the donor's md arrays"; fi
	done
	[ -n "$found" ] || vf_ok "no mdadm.conf in the tree"
}
vf_check_misc() {
	local root=$VF_ROOT use
	vf_section "misc"
	vf_check_mdadm
	if [ "$(vf_plan postfix selinux)" = autorelabel ]; then
		if [ -e "$root/.autorelabel" ]; then vf_ok "/.autorelabel is there (SELinux relabels on the first boot: it takes two boots)"
		else vf_fail "/.autorelabel is missing: with SELinux enforcing the copied files carry wrong labels and logins fail"; fi
	fi
	if [ -s "$root/etc/machine-id" ]; then vf_ok "/etc/machine-id is set"
	else vf_warn "/etc/machine-id is empty or missing: systemd generates a new one at boot (DHCP client id, journal change)" "cat $root/etc/machine-id"; fi
	use=$(vf_root_usage "$root")
	if [[ $use =~ ^[0-9]+$ ]]; then
		if [ "$use" -le 95 ]; then vf_ok "target root is $use% used"
		else vf_warn "target root is $use% used (less than 5% free): the first boot may fail to write logs/relabel" "df -h $root"; fi
	fi
}

# ==============================================================================
# verify_run, verify_summary
# ==============================================================================
vf_list_checks() {
	say "(dry) no target to look at yet; verify would check, read-only, after postfix:"
	cat <<-'EOF'
	    boot entry    the default grub entry (menuentry or BLS) resolves; kernel and initrd exist
	    initramfs     every initramfs has the recipient's drivers, no LVM devices file, the udev pin
	    fstab/swap    every fstab entry without nofail resolves on this box; swap UUIDs; RESUME=
	    kernel cmdline  no rd.md.*//dev/md anywhere; root= resolves; net.ifnames=0 biosdevname=0
	    filesystems   feature masks equal the donor's
	    bootloader    bios: GRUB in the MBR (+ bios_grub), i386-pc modules; uefi: ESP loaders, NVRAM
	                  (raid=1: on both disks / both ESPs)
	    network       primary config on eth0, the donor's MAC gone, multi-NIC order
	    md arrays     raid=1: every array running with both members, the plan's UUID; initramfs with mdadm
	    misc          mdadm.conf without ARRAY (raid=1: exactly ours), /.autorelabel, machine-id, free space
	EOF
}
vf_run_checks() {
	local c
	VF_OK=0; VF_WARN=0; VF_FAIL=0
	for c in $VF_CHECKS; do "vf_check_$c"; done
}
# --- boottest (E4, -o boottest=1): boot a qcow2 overlay of the target disk in ---
# qemu with direct kernel boot and a serial console; the target disk itself is
# never written (the overlay absorbs every write). Asserts the migrated system
# reaches multi-user, or fails verify with the serial log as evidence. qemu is
# installed on demand (bootstrap set boottest) and a missing qemu degrades the
# check to a warning, never a failure.
verify_boottest_capture() {   # the tree is mounted read-only: copy the boot bits out
	[ -n "$VF_KERNEL" ] && [ "$VF_KERNEL" != "-" ] && [ -f "$VF_ROOT$VF_KERNEL" ] \
		|| { vf_warn "boottest: the boot check found no kernel; skipping the boot test"; return 0; }
	[ -n "$VF_INITRD" ] && [ "$VF_INITRD" != "-" ] && [ -f "$VF_ROOT$VF_INITRD" ] \
		|| { vf_warn "boottest: the boot check found no initrd; skipping the boot test"; return 0; }
	mkdir -p "$RUN/boottest"
	cp "$VF_ROOT$VF_KERNEL" "$RUN/boottest/vmlinuz" 2>/dev/null \
		|| { vf_warn "boottest: cannot copy the kernel out of the tree; skipping the boot test"; return 0; }
	cp "$VF_ROOT$VF_INITRD" "$RUN/boottest/initrd.img" 2>/dev/null \
		|| { vf_warn "boottest: cannot copy the initrd out of the tree; skipping the boot test"; return 0; }
	VF_BOOTTEST_DISK=$(vf_boottest_disk) || { vf_warn "boottest: cannot resolve the target disk; skipping the boot test"; return 0; }
	VF_BOOTTEST_K=$RUN/boottest/vmlinuz; VF_BOOTTEST_I=$RUN/boottest/initrd.img
	VF_BOOTTEST_CMD=$VF_CMDLINE
	say "boottest: captured kernel+initrd of $VF_BOOTTEST_DISK, $(du -sh "$RUN/boottest" | cut -f1)"
}
vf_boottest_disk() {          # seam: the disk the plan wrote (apply_target_disk)
	local disk
	disk=$(apply_target_disk 2>/dev/null) || return 2
	[ -n "$disk" ] && [ -b "$disk" ] && { echo "$disk"; return 0; }
	return 2
}
vf_boottest_run() {           # seam: DISK KERNEL INITRD CMDLINE -> 0 = reached multi-user
	local disk=$1 k=$2 i=$3 cmdline=$4
	local dir=$RUN/boottest overlay serial pid marker= rc=1 wait=${VF_BOOTTEST_WAIT}
	serial=$dir/serial.log
	if ! { [ -x /usr/bin/qemu-system-x86_64 ] && [ -x /usr/bin/qemu-img ]; }; then
		vf_warn "boottest: qemu is not installed; skipping the boot test"; return 0
	fi
	# the trial guest takes its RAM out of the Live's own: on a small recipient the
	# OOM killer would take the Live down mid-migration (seen on a 2 GiB Live; the
	# availability figure alone lies there, because reclaimable page cache is counted)
	local memtotal memav
	memtotal=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
	memav=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
	if [ -n "$memtotal" ] && [ "$memtotal" -lt 3072 ]; then
		vf_warn "boottest: ${memtotal} MiB RAM in this Live cannot also host a 1 GiB trial guest: skipped" \
			"run the migration with -o boottest=0, or verify later on a box with more RAM"
		return 0
	fi
	if [ -n "$memav" ] && [ "$memav" -lt 1536 ]; then
		vf_warn "boottest: only ${memav} MiB available (a 1 GiB trial guest and this Live): skipped" \
			"run the migration with -o boottest=0, or verify later on a box with more RAM"
		return 0
	fi
	rm -rf "$dir/overlay.qcow2" "$dir/serial.log"
	qemu-img create -q -f qcow2 -F raw -b "$disk" "$dir/overlay.qcow2" \
		|| { vf_warn "boottest: cannot create the overlay of $disk; skipping the boot test"; return 0; }
	: > "$serial"
	[ "$cmdline" = "-" ] && cmdline=
	qemu-system-x86_64 -machine accel=kvm:tcg -m 1024 -smp 1 \
		-display none -monitor none -serial file:"$serial" -pidfile "$dir/qemu.pid" \
		-drive file="$dir/overlay.qcow2",if=virtio,format=qcow2 \
		-kernel "$k" -initrd "$i" -append "$cmdline console=ttyS0,115200n8" \
		-no-reboot &
	pid=$!
	while [ "$wait" -gt 0 ]; do
		grep -q "Kernel panic" "$serial" 2>/dev/null && { marker=panic; break; }
		# systemd colours the target name on a serial console (ESC[0;1;39mBasic System): strip ANSI before matching
		sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$serial" 2>/dev/null | grep -Eq "Reached target (Basic|Multi-User) System|systemd\[1\]: Startup finished" && { marker=up; break; }
		kill -0 "$pid" 2>/dev/null || { marker=exited; break; }
		sleep 5; wait=$((wait - 5))
	done
	kill "$pid" 2>/dev/null || true
	pkill -P "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null; rc=$?
	case $marker in
		up)     vf_ok "boottest: the migrated system reached multi-user (qemu overlay of $disk, serial: $serial)"; return 0 ;;
		panic)  vf_fail "boottest: kernel panic on boot (serial log: $serial)"; return 1 ;;
		exited) vf_fail "boottest: qemu exited before multi-user (rc=$rc; serial log: $serial)"; return 1 ;;
		*)      vf_fail "boottest: no multi-user within ${VF_BOOTTEST_WAIT}s (serial log: $serial)"; return 1 ;;
	esac
}
verify_boottest_run() {       # runs after the target was unmounted; never writes it
	local missing pkgs
	missing=$(bootstrap_missing boottest)
	if [ -n "$missing" ]; then
		if [ "$(opt offline)" = 1 ]; then
			vf_warn "boottest: qemu missing and offline=1; skipping the boot test"; return 0
		fi
		pkgs=$(_bootstrap_pkgs_for $missing)
		say "boottest: installing $pkgs"
		_bootstrap_apt_local "$pkgs"
		missing=$(bootstrap_missing boottest)
		[ -z "$missing" ] || { vf_warn "boottest: qemu still missing after apt ($missing); skipping the boot test"; return 0; }
	fi
	vf_boottest_run "$VF_BOOTTEST_DISK" "$VF_BOOTTEST_K" "$VF_BOOTTEST_I" "$VF_BOOTTEST_CMD"
}

verify_summary() {
	local plan=${VF_PLAN:-$RUN/plan} inv=$RUN/recipient.inv pins p name mac live fu item target
	[ -r "$plan" ] || return 0
	pins=$(plan_get "$plan" network pins); target=$(plan_get "$plan" network target)
	if [ -n "$pins" ] && [ "$pins" != - ]; then
		say "NIC names after the boot ($(ap_dec "$(plan_get "$plan" network cmdline)"); udev pin $([ "$(plan_get "$plan" network pin)" = 1 ] && echo on || echo off), best-effort):"
		printf '    %-19s %-10s %s\n' MAC "in Live" "after boot"
		for p in ${pins//,/ }; do
			name=${p%%:*}; mac=${p#*:}; live=
			[ ! -r "$inv" ] || live=$(inv_lookup "$inv" nic mac "$mac" name)
			printf '    %-19s %-10s %s\n' "$mac" "${live:--}" "$name"
		done
		mac=$(plan_get "$plan" network mac)
		say "no network after the boot? on the BMC console: $(vf_bmc_fix "${target:-eth0}" "$mac")"
	fi
	fu=$(state_get postfix.followups)
	if [ -n "$fu" ] && [ "$fu" != - ]; then
		say "manual follow-ups on the migrated system:"
		# postfix joins them with "; " (state is one line per key)
		while IFS= read -r item; do item=$(ap_trim "$item"); [ -z "$item" ] || echo "    - $(ap_dec "$item")"; done < <(tr ';' '\n' <<< "$fu")
	fi
	return 0
}
verify_run() {
	local root=${1:-} mounted="" d
	VF_PLAN=$RUN/plan
	if [ ! -r "$VF_PLAN" ]; then
		if [ -n "$DRY" ] && [ -z "$root" ]; then vf_list_checks; return 0; fi
		die "$EX_ENV" "no plan at $VF_PLAN: verify takes what to expect from it (run 'migrator -s plan DONOR' first)"
	fi
	if [ -n "$root" ]; then
		root=${root%/}
		[ -d "$root/etc" ] || die "$EX_ENV" "verify: $root is not a system tree (no etc/)"
		TARGET_MNT=$root
		say "verifying the tree at $root as it is (not mounted by migrator)"
	else
		if ! phase_is_done postfix; then
			[ -n "$DRY" ] || die "$EX_ENV" "postfix has not finished (phase.postfix is not done in $RUN/state): run 'migrator -s postfix' first"
			d=$(target_dev_of /)
			if [ -n "$d" ] && [ -b "$d" ] && [ -n "$(target_fstype "$d")" ]; then
				say "(dry) postfix is not marked done here: verifying what is on $d now, read-only"
			else
				vf_list_checks; return 0
			fi
		fi
		target_mount ro; mounted=y; root=$TARGET_MNT
	fi
	VF_ROOT=$root
	vf_run_checks
	if [ "$VF_FAIL" -eq 0 ] && [ "$(opt boottest 0)" = 1 ]; then verify_boottest_capture; fi
	[ -z "$mounted" ] || target_umount
	if [ "$VF_FAIL" -eq 0 ] && [ -n "${VF_BOOTTEST_K:-}" ]; then verify_boottest_run; fi
	say "verify: $VF_OK ok, $VF_WARN warnings, $VF_FAIL failures"
	if [ "$VF_FAIL" -gt 0 ]; then
		[ -n "$DRY" ] || state_set phase.verify failed
		die "$EX_VERIFY" "verify failed: $VF_FAIL check(s); the recipient disk is written, do NOT reboot it: fix and re-run 'migrator -s verify'"
	fi
	if [ -n "$DRY" ]; then
		say "(dry) verify is green; a real run would mark phase verify done and write $RUN/summary"
		verify_summary; return 0
	fi
	phase_done verify; state_set verify.warnings "$VF_WARN"; state_set verify.time "$(date +%s)"
	printf '%s\n' "verified: $VF_OK ok, $VF_WARN warnings; next: migrator -s cutover" > "$RUN/summary"
	# the record inside the target (plan, log, state, the migrated stamp) is postfix's to
	# write; only for a target this run mounted itself, never into an operator's tree
	if [ -n "$mounted" ] && declare -F postfix_record >/dev/null; then
		postfix_record || warn "postfix_record failed ($?): the copy of plan/log/state inside the target may be incomplete"
	fi
	verify_summary
	say "verified: $VF_OK ok, $VF_WARN warnings; next: migrator -s cutover"
}

# ==============================================================================
# cutover
# ==============================================================================
co_ping()  { ping -c1 -W1 "$1" >/dev/null 2>&1; }
co_boot()  { run "$@"; }
co_local_cidrs() { ip -o -4 addr show 2>/dev/null | awk '{ print $4 }'; }
co_ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
co_in_cidr() {
	local ip=$1 net=${2%/*} len=32 mask re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
	if ! [[ $ip =~ $re ]] || ! [[ $net =~ $re ]]; then return 1; fi
	case $2 in */*) len=${2#*/};; esac
	if ! [[ $len =~ ^[0-9]+$ ]] || [ "$len" -gt 32 ]; then return 1; fi
	if [ "$len" -eq 0 ]; then mask=0; else mask=$(( (0xffffffff << (32 - len)) & 0xffffffff )); fi
	[ $(( $(co_ip2int "$ip") & mask )) -eq $(( $(co_ip2int "$net") & mask )) ]
}
# co_visible IP: 0 when IP is in a subnet this Live has an address in (loopback aside)
co_visible() {
	local c
	while IFS= read -r c; do
		case $c in ''|127.*) continue;; esac
		if co_in_cidr "$1" "$c"; then return 0; fi
	done < <(co_local_cidrs)
	return 1
}
# co_do CMD...: the seam is never reached in a dry run
co_do() {
	local q
	if [ -n "$DRY" ]; then q=$(printf '%q ' "$@"); echo "(dry) ${q% }"; log "(dry) ${q% }"; return 0; fi
	co_boot "$@"
}
co_instructions() {
	local host=$1
	say "cutover mode 'none': nothing is switched by migrator. By hand, in this order:"
	echo "    1. take the donor ${host:+$host }off the network: on its console, every NIC but lo: ip link set <nic> down   (or: poweroff)"
	echo "    2. make sure it is gone:  ping -c3 ${host:-<donor address>}   must get no answer (two hosts must never share one IP)"
	echo "    3. boot this recipient into the migrated system:  systemctl reboot   (or: migrator -o cutover=kexec -s cutover)"
}
# co_wait_gone ADDR: 0 once three pings in a row go unanswered, 1 when it still answers
# after MIGRATOR_CUTOVER_TIMEOUT_S pings (an unanswered ping costs its own 1 s timeout)
co_wait_gone() {
	local addr=$1 misses=0 t
	for ((t = 0; t < MIGRATOR_CUTOVER_TIMEOUT_S; t++)); do
		if co_ping "$addr"; then
			misses=0; [ "$MIGRATOR_CUTOVER_POLL_S" = 0 ] || sleep "$MIGRATOR_CUTOVER_POLL_S"
		else
			misses=$((misses+1)); [ "$misses" -lt 3 ] || return 0
		fi
	done
	return 1
}
# co_kexec_prepare: kernel + initrd of the verified entry out of the target into tmpfs,
# while the donor is still up: whatever can fail here fails before anything is switched
CO_KERNEL=; CO_INITRD=; CO_CMDLINE=
co_kexec_prepare() {
	local k i c
	k=$(state_get verify.kernel); i=$(state_get verify.initrd); c=$(state_get verify.cmdline)
	if [ -n "$DRY" ]; then
		k=${k:-<verify.kernel>}; i=${i:-<verify.initrd>}; c=${c:-<verify.cmdline>}
		echo "(dry) would mount the target read-only and copy $k and $i to $RUN/kexec/"
		CO_KERNEL=$RUN/kexec/${k##*/}; CO_INITRD=$RUN/kexec/${i##*/}; CO_CMDLINE=$c
		return 0
	fi
	if [ -z "$k" ] || [ -z "$i" ]; then die "$EX_ENV" "no verified boot entry in $RUN/state (verify.kernel, verify.initrd): run 'migrator verify' first"; fi
	have kexec || die "$EX_ENV" "kexec is not installed on this Live: use '-o cutover=netdown' (firmware boot)"
	target_mount ro
	mkdir -p "$RUN/kexec"
	if [ ! -f "$TARGET_MNT$k" ] || [ ! -f "$TARGET_MNT$i" ]; then
		target_umount
		die "$EX_FAIL" "the verified kernel $k or initrd $i is not on the target any more: re-run 'migrator -s verify'"
	fi
	CO_KERNEL=$RUN/kexec/${k##*/}; CO_INITRD=$RUN/kexec/${i##*/}; CO_CMDLINE=$c
	if ! { run cp -L -- "$TARGET_MNT$k" "$CO_KERNEL" && run cp -L -- "$TARGET_MNT$i" "$CO_INITRD"; }; then
		target_umount
		die "$EX_FAIL" "cannot copy kernel/initrd to $RUN/kexec (tmpfs full?): nothing was switched, the donor is untouched"
	fi
	target_umount
}
# co_online_donor MODE: the on-line donor's part of the cutover, through its
# poller (migrator-agent poll on the donor, migrator-agent cutover here): netdown
# (also kexec's donor part), poweroff, rollback (thaw: the donor goes on as if
# nothing happened, this box boots nothing). State: online.cutover_{host,port,token}.
co_online_donor() {
	local mode=$1 port token agent action host
	[ "$(state_get online.frozen)" = 1 ] || die "$EX_ENV" "the donor is not frozen (transfer did not finish on-line?): nothing to cut over"
	port=$(state_get online.cutover_port); token=$(state_get online.cutover_token); host=$(state_get online.cutover_host)
	agent=${MIGRATOR_AGENT:-$(state_get agent.path)}
	if [ -z "$port" ] || [ -z "$token" ] || [ ! -x "$agent" ]; then die "$EX_ENV" "no cutover token/port/agent in $RUN/state: the on-line transfer did not leave a poller behind"; fi
	case $mode in rollback) action=thaw;; poweroff) action=poweroff;; *) action=netdown;; esac
	if [ -n "$DRY" ]; then echo "(dry) would hand the donor's poller (port $port on $host) the command: $action"; return 0; fi
	if [ -z "$YES" ]; then
		case $action in
			thaw) confirm "Roll back: thaw the donor's filesystems and leave it running (this box boots nothing)?";;
			*)    confirm "Take the donor off the network now ($action; its filesystems stay frozen)?";;
		esac
	fi
	say "waiting for the donor's poller on port $port (it connects every 3 s)"
	run "$agent" cutover --port "$port" --token "$token" --timeout "$MIGRATOR_CUTOVER_AGENT_S" "$action" \
		|| die "$EX_FAIL" "the donor did not take '$action' (no poll on port $port within $MIGRATOR_CUTOVER_AGENT_S s: is migrator-agent still running there, can it reach $host:$port?); by hand on the donor's console: fsfreeze -u / (rollback) or ip link set DEV down"
	if [ "$action" = thaw ]; then
		state_set online.frozen 0; state_set cutover.mode rollback; state_set cutover.time "$(date +%s)"
		say "rolled back: the donor runs on, unfrozen; the copy on this box stays as it is (migrator -s transfer starts over)"
		return 0
	fi
	if declare -F ssh_disconnect >/dev/null; then ssh_disconnect >/dev/null 2>&1 || true; fi
	[ "$MIGRATOR_CUTOVER_WAIT_S" = 0 ] || sleep "$MIGRATOR_CUTOVER_WAIT_S"
}
cutover_run() {
	local mode=${1:-netdown} host addr pip vg rc
	local -a addrs=()
	case $mode in
		netdown|poweroff|kexec|none) ;;
		rollback) [ "$(state_get mode)" = online ] || die "$EX_ENV" "cutover=rollback is for the on-line mode (the donor is frozen there); an off-line donor was never touched";;
		*) die "$EX_ENV" "cutover: unknown mode '$mode' (netdown|poweroff|kexec|none; on-line also rollback)";;
	esac
	# on-line: the donor is frozen since transfer and polls this box; nothing goes over ssh
	# (a new login would hang on its frozen root), verify is not required for a rollback
	if [ "$mode" = rollback ]; then co_online_donor rollback; return $?; fi
	if ! phase_is_done verify; then
		if [ "$(opt force 0)" = 1 ]; then warn "verify is not marked done: cutting over anyway (force=1)"
		elif [ -n "$DRY" ]; then say "(dry) verify is not marked done here: a real cutover refuses at this point (run verify first)"
		else die "$EX_ENV" "run verify first: the migrated system is not verified ('migrator -s verify'; force=1 overrides)"; fi
	fi
	host=${DONOR_HOST:-}
	if [ -z "$host" ]; then host=$(state_get donor.target); host=${host#*@}; host=${host%:*}; fi
	if [ "$mode" = none ]; then
		co_instructions "$host"
		[ -n "$DRY" ] || { state_set cutover.mode none; state_set cutover.time "$(date +%s)"; }
		return 0
	fi
	[ "$mode" != kexec ] || co_kexec_prepare

	# --- the donor goes off the network ---
	if [ "$(state_get mode)" = online ]; then
		co_online_donor "$mode"
	else
	if [ -z "${DONOR_HOST:-}" ]; then
		if [ -n "$DRY" ]; then say "(dry) would reconnect to the donor ${host:-recorded in state donor.target}"
		elif declare -F reconnect_donor >/dev/null; then
			reconnect_donor; host=$DONOR_HOST
			# shellcheck disable=SC2034  # PHASE is what die() records; connect_donor changed it
			PHASE=cutover
		else die "$EX_ENV" "no connection to the donor (DONOR_HOST is empty): take it off the network by hand and use '-o cutover=none'"; fi
	fi
	[ -n "$host" ] || host="<donor>"
	if [ -n "$DRY" ]; then echo "(dry) would ask: Take the donor $host off the network now?"
	elif [ -z "$YES" ]; then confirm "Take the donor $host off the network now?"; fi
	# the command travels over the NIC it takes down: detached, delayed, its output nowhere,
	# so ssh returns before the link goes; the master dying with it is expected
	rc=0
	# shellcheck disable=SC2016  # $i and $n expand in the donor's detached shell, not here
	case $mode in
		poweroff) rrun_sh 'setsid nohup sh -c "sleep 2; poweroff" >/dev/null 2>&1 </dev/null &' || rc=$?;;
		*)        rrun_sh 'setsid nohup sh -c "sleep 2; for i in /sys/class/net/*; do n=\${i##*/}; [ \$n = lo ] || ip link set \$n down; done" >/dev/null 2>&1 </dev/null &' || rc=$?;;
	esac
	[ "$rc" -eq 0 ] || warn "the donor command returned $rc (the connection may have dropped first): the ping check below decides"
	if [ -z "$DRY" ]; then
		[ "$MIGRATOR_CUTOVER_WAIT_S" = 0 ] || sleep "$MIGRATOR_CUTOVER_WAIT_S"
		if declare -F ssh_disconnect >/dev/null; then ssh_disconnect >/dev/null 2>&1 || true; fi
	fi
	fi

	# --- proof that it is gone ---
	[ "$host" = "<donor>" ] || addrs+=("$host")
	pip=; [ ! -r "$RUN/donor.inv" ] || pip=$(inv_field "$(inv_records "$RUN/donor.inv" os | head -1)" primary_ip)
	pip=${pip%%/*}
	if [ -n "$pip" ] && [ "$pip" != - ] && [ "$pip" != "$host" ]; then
		if co_visible "$pip"; then addrs+=("$pip")
		else say "the donor OS address $pip is in no subnet of this Live: it cannot be seen from here, not checked"; fi
	fi
	for addr in "${addrs[@]}"; do
		if [ -n "$DRY" ]; then echo "(dry) would ping $addr until 3 pings in a row go unanswered (up to ${MIGRATOR_CUTOVER_TIMEOUT_S} s), and refuse to boot while it answers"; continue; fi
		if co_wait_gone "$addr"; then say "donor is gone: $addr does not answer"
		else die "$EX_FAIL" "donor still answers on $addr: not rebooting (two hosts with one IP)"; fi
	done

	# --- this box boots the migrated system ---
	if [ "$mode" = kexec ]; then
		say "donor $host is off the network; kexec into the verified entry: $CO_KERNEL"
		if [ -n "$DRY" ]; then echo "(dry) would ask: Boot this recipient into the migrated system now (kexec)?"
		elif [ -z "$YES" ]; then confirm "Boot this recipient into the migrated system now (kexec)?"; fi
		while IFS= read -r vg; do
			[ -n "$vg" ] || continue
			run vgchange -an "$vg" || warn "vgchange -an $vg failed ($?): kexec goes on, the new kernel re-activates it"
		done < <(plan_section "$RUN/plan" lvm 2>/dev/null | awk '$1 == "vgcreate" { print $2 }')
		# raid=1: stopped cleanly, so the new kernel assembles them in sync (a resync that was
		# under way resumes from its checkpoint); a running array would look unclean after kexec
		if [ "$(plan_get "$RUN/plan" target raid 2>/dev/null)" = 1 ] && declare -F apply_md_devs >/dev/null; then
			for vg in $(apply_md_devs "$RUN/plan"); do
				if [ -n "$DRY" ]; then echo "(dry) mdadm --stop $vg"; else md_is_running "$vg" && { run mdadm --stop "$vg" || warn "mdadm --stop $vg failed ($?): kexec goes on, the arrays resync after the boot"; }; fi
			done
		fi
		co_do kexec -s -l "$CO_KERNEL" --initrd="$CO_INITRD" --command-line="$CO_CMDLINE" \
			|| co_do kexec -c -l "$CO_KERNEL" --initrd="$CO_INITRD" --command-line="$CO_CMDLINE" \
			|| die "$EX_FAIL" "kexec could not load $CO_KERNEL; the donor is already off the network: boot this box through the firmware instead (systemctl reboot)"
	else
		say "donor $host is off the network; this recipient boots the migrated system from its disk (firmware boot)"
		if [ -n "$DRY" ]; then echo "(dry) would ask: Reboot this recipient into the migrated system now?"
		elif [ -z "$YES" ]; then confirm "Reboot this recipient into the migrated system now?"; fi
	fi
	if [ -z "$DRY" ]; then state_set cutover.mode "$mode"; state_set cutover.time "$(date +%s)"; fi
	if [ "$mode" = kexec ]; then co_do systemctl kexec || co_do kexec -e
	else co_do systemctl reboot || co_do reboot; fi
}
