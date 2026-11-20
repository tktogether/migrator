#!/bin/bash
# lib/postfix.sh — fix the migrated system up so it boots on the recipient:
# fstab and kernel command line follow the plan's [identity], the donor's md
# arrays and LVM filters are dropped, the network moves to eth0 (lib/netfix.sh),
# the initramfs gets the recipient's drivers, grub is installed for the
# recipient's firmware. Sourced after common.sh, plan.sh and target.sh; defines
# functions and defaults only. Both families: deb (initramfs-tools, grub-install
# + update-grub, debconf) and rhel (dracut per kernel, BLS entries + grubenv
# kernelopts, grub2-install for BIOS only, grub2-mkconfig into the real grub.cfg,
# shim in NVRAM, /.autorelabel for SELinux).
#
#   postfix_run [ROOT]      the phase. Without ROOT: target_mount rw binds, the steps,
#                           target_umount, phase.postfix=done. With ROOT (a tree somebody
#                           else mounted: 'rescue', a test directory): the steps only.
#                           Under -n: diffs and "(dry)" commands, nothing is written.
#   postfix_record [ROOT]   after a green verify: plan, log, state and inventories into
#                           <root>/root/migrator-<date>/ and the stamp /etc/migrator-migrated
#
# How a file is changed (one way only, so a run is a reviewable patch):
#   a PURE rewriter (stdin -> stdout, parameters as arguments) computes the new
#   content; pf_apply compares, prints a unified diff (stdout + $RUN/log), keeps
#   the original ONCE under <root>/var/lib/migrator/orig/<path> and writes by
#   truncating in place (same inode: owner, mode and SELinux label stay).
#   pf_apply PATH < content     change an existing file (creates it 0644 when absent)
#   pf_new PATH MODE < content  the same with the mode of a new file
#   pf_remove PATH              back up, then remove
# PATH is the path INSIDE the target (/etc/fstab). Every step is idempotent: a
# second run prints no diff. Never "... | pf_new": the pipe would run it in a
# subshell and lose its counters and warnings; feed it with < file or < <(cmd).
#
# Pure rewriters (tests/cases/postfix.sh drives them on recorded files):
#   pf_fstab_rewrite IDENT            fstab by the [identity] table (IDENT = file "spec<TAB>action")
#   pf_resume_rewrite IDENT           initramfs-tools conf.d/resume (RESUME=<spec>)
#   pf_mdadm_conf_rewrite [ARRAYS]    ARRAY lines commented out; with ARRAYS (a file of ARRAY
#                                     lines, raid=1) those are kept/added instead
#   pf_md_conf_new ARRAYS             a minimal mdadm.conf around the ARRAY lines (no donor file)
#   pf_lvm_conf_rewrite               active filter/global_filter commented out
#   pf_cmdline_rewrite STRING [full|strip [IDENT [ADD [CONSOLE]]]]   one kernel command line
#   pf_grub_default_rewrite [main|dropin [keep|comment [PARTUUIDS]]] /etc/default/grub, grub.d/*.cfg
#   pf_kernel_cmdline_rewrite         /etc/kernel/cmdline
#   pf_bls_rewrite                    a BLS entry (boot/loader/entries/*.conf): its options line
#                                     (a line built from $kernelopts is only stripped; the values live in grubenv)
#   pf_grubenv_rewrite                grubenv (the 1024-byte block): kernelopts=, re-padded
#   pf_dracut_conf DRIVERS [PIN]      /etc/dracut.conf.d/90-migrator.conf
#   pf_modules_rewrite DRIVERS        /etc/initramfs-tools/modules
#   pf_initramfs_conf_rewrite         MODULES=dep -> most
#   pf_efi_labelled LABEL, pf_efi_order_new NEW [DELETED...]   efibootmgr output parsers
#
# Read from the driver: RUN DRY OPT[console] OPT[bootorder]; state written:
# phase.postfix, postfix.followups, netfix.done. Exit codes: EX_ENV (no plan,
# transfer not done, ROOT without binds), EX_PLAN (a plan value postfix cannot
# act on), EX_FAIL (rhel/dracut until M4, update-initramfs or grub failed).
#
# raid=1 ([postfix] raid=1 disk2= esp2=): mdadm is apt-installed into the target
# when the donor OS has none, mdadm.conf gets OUR ARRAY lines (the plan's [md]:
# the initramfs assembles exactly these), grub is installed on both disks (bios)
# or into both ESPs (uefi: the second ESP is a copy of the first, loaders
# installed into it, its own NVRAM entry), debconf is told about both devices,
# and the resync paused by apply is resumed before the chroot work.

# shellcheck disable=SC2015  # "A && B || die" guards are used on purpose throughout
PF_FOLLOWUPS=()      # manual actions for the operator, printed at the end and kept in state
PF_WARNS=()          # warnings of this phase, repeated at the end
PF_CHANGED=0         # files changed (or that would change under -n)
PF_DIR=              # where the plan and the inventories are ($RUN)
PF_PLAN=
PF_IDENT=            # the [identity] section as a file: spec<TAB>action
PF_ADD=              # tokens every kernel command line must carry ([network] cmdline=)
PF_CONSOLE=          # -o console=VALUE
PF_OSPROBER_CFG=/etc/default/grub.d/99-migrator-osprober.cfg
PF_RESOLV_SAVED=      # the target's resolv.conf symlink set aside during an apt run

# --- small helpers -----------------------------------------------------------------
pf_dec() { local s=$1; s=${s//%20/ }; s=${s//%2C/,}; printf '%s\n' "$s"; }     # the plan's %20/%2C encoding
pf_warn() { warn "$@"; PF_WARNS+=("$*"); }
pf_followup() {
	local x
	for x in "${PF_FOLLOWUPS[@]}"; do [ "$x" != "$1" ] || return 0; done
	PF_FOLLOWUPS+=("$1")
}
# overridable probes (tests replace them)
pf_is_uefi_live() { [ -d /sys/firmware/efi ]; }
pf_chroot_ready() { [ -n "${TARGET_BINDS:-}" ] || mountpoint -q "$TARGET_MNT/proc" 2>/dev/null; }
pf_live_grub_ready() { have grub-install && [ -d "/usr/lib/grub/$1" ]; }     # PLATFORM

# _pf_real PATH: where PATH of the target lives on this box. A symlink is followed
# INSIDE the target: an absolute link (/etc/x -> /usr/lib/x) read from the Live
# would otherwise name the Live's own file.
_pf_real() {
	local rel=${1#"$TARGET_MNT"} l n=0
	while [ -L "$TARGET_MNT$rel" ] && [ $n -lt 8 ]; do
		l=$(readlink "$TARGET_MNT$rel")
		case $l in /*) rel=$l;; *) rel=$(dirname "$rel")/$l;; esac
		n=$((n + 1))
	done
	printf '%s\n' "$TARGET_MNT$rel"
}
# the last line of defence of the same rule: nothing is ever written outside the target
_pf_inside() {
	local top real
	top=$(realpath -m "$TARGET_MNT") && real=$(realpath -m "$1") || return 1
	case $real in "$top"/*) return 0;; esac
	return 1
}
pf_has() { [ -f "$(_pf_real "$1")" ]; }
pf_cat() { cat "$(_pf_real "$1")" 2>/dev/null; }

# --- the one way files change ----------------------------------------------------------
_pf_created() { grep -qxF -- "$1" "$TARGET_MNT/var/lib/migrator/created" 2>/dev/null; }
# _pf_backup REL FILE: keep the ORIGINAL once; a file we created ourselves has no original
_pf_backup() {
	local o=$TARGET_MNT/var/lib/migrator/orig$1
	if [ -e "$o" ] || [ -L "$o" ] || _pf_created "$1"; then return 0; fi
	mkdir -p "$(dirname "$o")" && cp -a "$2" "$o" || die "$EX_FAIL" "cannot back up $2 to $o"
}
pf_new() {   # PATH [MODE]  (new content on stdin)
	local rel=${1#"$TARGET_MNT"} mode=${2:-0644} f tmp
	f=$(_pf_real "$rel"); rel=${f#"$TARGET_MNT"}
	mkdir -p "$RUN"
	tmp=$(mktemp "$RUN/pf.XXXXXX") || die "$EX_FAIL" "cannot create a temporary file in $RUN"
	cat > "$tmp"
	if ! _pf_inside "$f"; then
		rm -f "$tmp"; pf_warn "$rel resolves outside the target ($f): not touched"; return 0
	fi
	if [ -f "$f" ]; then
		if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi
		diff -u --label "a$rel" --label "b$rel" "$f" "$tmp" | tee -a "$RUN/log"
	else
		if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 0; fi
		diff -u --label /dev/null --label "b$rel" /dev/null "$tmp" | tee -a "$RUN/log"
	fi
	PF_CHANGED=$((PF_CHANGED + 1))
	if [ -n "$DRY" ]; then rm -f "$tmp"; return 0; fi
	if [ -f "$f" ]; then
		_pf_backup "$rel" "$f"
		cat "$tmp" > "$f" || die "$EX_FAIL" "cannot write $f"
	else
		mkdir -p "$(dirname "$f")" "$TARGET_MNT/var/lib/migrator" || die "$EX_FAIL" "cannot create the directory of $f"
		( umask 077; : > "$f" ) && chmod "$mode" "$f" && cat "$tmp" > "$f" || die "$EX_FAIL" "cannot create $f"
		chown 0:0 "$f" 2>/dev/null || true
		_pf_created "$rel" || printf '%s\n' "$rel" >> "$TARGET_MNT/var/lib/migrator/created"
	fi
	rm -f "$tmp"
	log "wrote $rel"
}
pf_apply() { pf_new "$1" 0644; }
pf_remove() {   # PATH
	local rel=${1#"$TARGET_MNT"} f
	f=$(_pf_real "$rel"); rel=${f#"$TARGET_MNT"}
	[ -f "$f" ] || [ -L "$f" ] || return 0
	_pf_inside "$f" || { pf_warn "$rel resolves outside the target ($f): not removed"; return 0; }
	PF_CHANGED=$((PF_CHANGED + 1))
	if [ -n "$DRY" ]; then say "(dry) would remove $rel (kept as /var/lib/migrator/orig$rel)"; return 0; fi
	_pf_backup "$rel" "$f"
	rm -f "$f" || die "$EX_FAIL" "cannot remove $f"
	say "removed $rel (kept as /var/lib/migrator/orig$rel)"
}
# _pf_edit PATH REWRITER ARGS...: PATH through a pure rewriter. A rewriter that
# fails, or returns nothing for a file that had content, changes nothing: an
# awk that died must not truncate /etc/fstab.
_pf_edit() {
	local rel=$1 f tmp; shift
	f=$(_pf_real "$rel"); [ -f "$f" ] || return 0
	mkdir -p "$RUN"
	tmp=$(mktemp "$RUN/pfe.XXXXXX") || die "$EX_FAIL" "cannot create a temporary file in $RUN"
	if "$@" < "$f" > "$tmp" && { [ -s "$tmp" ] || [ ! -s "$f" ]; }; then
		pf_apply "$rel" < "$tmp"
	else
		pf_warn "rewriting $rel failed ($1): the file is left untouched"
	fi
	rm -f "$tmp"
}

# ==============================================================================
# pure rewriters: stdin -> stdout, mawk-safe
# ==============================================================================
# the [identity] table for awk: act[spec] = keep | "-> NEW" | remove; "+ rest" rows apart
_PF_AWK_IDENT='
function ident_load(file,   l, t, s, a) {
	if (file == "") return
	while ((getline l < file) > 0) {
		if (l ~ /^[ \t]*(#|$)/) continue
		t = index(l, "\t"); if (!t) continue
		s = substr(l, 1, t - 1); a = substr(l, t + 1)
		sub(/^[ \t]+/, "", a); sub(/[ \t]+$/, "", a)
		if (a ~ /^\+ /) { nadd++; addspec[nadd] = s; addrest[nadd] = substr(a, 3) }
		else act[s] = a
	}
	close(file)
}'

# pf_fstab_rewrite IDENT: field 1 by the table. keep and unknown specs are left
# alone, "-> NEW" replaces the first field only (the rest of the line keeps its
# spacing), remove comments the line out, "+ rest" rows are appended unless
# something is mounted there already.
pf_fstab_rewrite() {
	awk -v identfile="${1:-}" "$_PF_AWK_IDENT"'
	BEGIN { ident_load(identfile) }
	/^[ \t]*(#|$)/ { print; next }
	{
		line = $0; spec = $1
		lead = line; sub(/[^ \t].*$/, "", lead)
		rest = substr(line, length(lead) + length(spec) + 1)
		a = (spec in act) ? act[spec] : "keep"
		if (a == "remove") { print "# migrator: removed (no target): " line; next }
		if (a ~ /^-> /) line = lead substr(a, 4) rest
		if (NF >= 2) mounted[$2] = 1
		print line
	}
	END {
		for (i = 1; i <= nadd; i++) {
			split(addrest[i], f, /[ \t]+/)
			if (f[1] in mounted) continue
			print addspec[i] " " addrest[i]; mounted[f[1]] = 1
		}
	}'
}
# pf_resume_rewrite IDENT: RESUME=<spec> of initramfs-tools follows the table the way
# resume= on the command line does; a swap that did not move is RESUME=none (the
# initramfs would otherwise wait for a device that never comes)
pf_resume_rewrite() {
	awk -v identfile="${1:-}" -v sq="'" "$_PF_AWK_IDENT"'
	BEGIN { ident_load(identfile) }
	/^[ \t]*RESUME=/ {
		v = $0; sub(/^[ \t]*RESUME=/, "", v); sub(/[ \t]+$/, "", v)
		c = substr(v, 1, 1); if (c == "\"" || c == sq) v = substr(v, 2, length(v) - 2)
		a = ""
		if (("resume=" v) in act) { a = act["resume=" v]; if (a ~ /^-> resume=/) a = "-> " substr(a, 11) }
		else if (v in act) a = act[v]
		if (a ~ /^-> /) { print "RESUME=" substr(a, 4); next }
		if (a == "remove") { print "RESUME=none"; next }
	}
	{ print }'
}
# pf_mdadm_conf_rewrite [ARRAYS]: without ARRAYS every ARRAY line is commented out (the
# donor's arrays are not on the recipient); with ARRAYS (one "ARRAY /dev/mdN …" per line)
# those are kept where they already stand and appended where missing, every other ARRAY
# line is commented out. Idempotent.
pf_mdadm_conf_rewrite() {
	awk -v arrays="${1:-}" '
	BEGIN { n = 0; if (arrays != "") while ((getline l < arrays) > 0) { if (l ~ /^ARRAY[ \t]/) { n++; want[n] = l } } }
	{
		line = $0
		if (line ~ /^[ \t]*ARRAY([ \t]|$)/) {
			s = line; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
			hit = 0; for (i = 1; i <= n; i++) if (s == want[i]) { hit = 1; seen[i] = 1 }
			if (hit) print line; else print "# migrator: " s
			next
		}
		print line
	}
	END { for (i = 1; i <= n; i++) if (!seen[i]) print want[i] }'
}
# pf_md_conf_new ARRAYS: the file for a donor that had none (Debian layout, HOMEHOST <system>)
pf_md_conf_new() {
	printf '%s\n' '# mdadm.conf written by migrator: the md RAID1 arrays of this (migrated) system' \
		'# instruct the monitoring daemon where to send mail alerts' 'MAILADDR root' \
		'# automatically tag new arrays as belonging to the local system' 'HOMEHOST <system>' ''
	grep '^ARRAY ' "$1"
}
# an lvm.conf filter names the donor's devices (a|^/dev/md.*|, r|.*|): on the
# recipient it would hide the PV. A value spanning lines goes as a whole.
pf_lvm_conf_rewrite() {
	awk '
	function off(s,   lead) { lead = s; sub(/[^ \t].*$/, "", lead); return lead "# migrator: " substr(s, length(lead) + 1) }
	cont { print off($0); if ($0 ~ /\]/) cont = 0; next }
	/^[ \t]*(global_)?filter[ \t]*=/ { print off($0); if ($0 !~ /\]/) cont = 1; next }
	{ print }'
}

# pf_cmdline_rewrite STRING [MODE [IDENT [ADD [CONSOLE]]]] -> the new command line
#   table first (exact token: keep | "-> NEW" | remove); then rd.md.uuid= / rd.md= /
#   rd.md.conf= always go (there is no md on the recipient), root=/resume=<spec>
#   follow the spec's fstab row. MODE full: every token of ADD (k=v) is present
#   once, a different value of the same key is dropped, console=CONSOLE is
#   appended when absent. MODE strip: the same removals, nothing is added
#   (GRUB_CMDLINE_LINUX_DEFAULT: a net.ifnames=1 there would win, being last).
#   IDENT/ADD/CONSOLE default to PF_IDENT/PF_ADD/PF_CONSOLE. An untouched line
#   comes back byte for byte.
pf_cmdline_rewrite() {
	local s=$1 mode=${2:-full} ident=${3-${PF_IDENT:-}} add=${4-${PF_ADD:-}} console=${5-${PF_CONSOLE:-}}
	printf '%s\n' "$s" | awk -v mode="$mode" -v identfile="$ident" -v add="$add" -v console="$console" "$_PF_AWK_IDENT"'
	function action(tok,   k, spec, a) {
		if (tok in act) return act[tok]
		if (tok ~ /^rd\.md\.uuid=/ || tok ~ /^rd\.md=/ || tok ~ /^rd\.md\.conf=/) return "remove"
		if (tok ~ /^(root|resume)=/) {
			k = substr(tok, 1, index(tok, "=") - 1); spec = substr(tok, index(tok, "=") + 1)
			if (spec in act) {
				a = act[spec]
				if (a ~ /^-> /) return "-> " k "=" substr(a, 4)
				if (a == "remove" && k == "resume") return "remove"
			}
		}
		return "keep"
	}
	BEGIN { ident_load(identfile); na = split(add, addtok, /[ \t]+/) }
	{
		orig = $0; rest = $0; out = ""; changed = 0; n = 0
		while (match(rest, /[^ \t]+/)) {
			sep = substr(rest, 1, RSTART - 1); tok = substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
			a = action(tok)
			if (a == "remove") { changed = 1; continue }
			if (a ~ /^-> /) { tok = substr(a, 4); changed = 1 }
			drop = 0
			for (i = 1; i <= na; i++) {
				if (addtok[i] == "" || tok == addtok[i]) continue
				k = addtok[i]; e = index(k, "="); if (!e) continue
				if (substr(tok, 1, e) == substr(k, 1, e)) drop = 1
			}
			if (drop) { changed = 1; continue }
			n++; t[n] = tok
			out = out (n == 1 ? "" : (sep == "" ? " " : sep)) tok
		}
		if (mode == "full") {
			for (i = 1; i <= na; i++) {
				if (addtok[i] == "") continue
				found = 0; for (j = 1; j <= n; j++) if (t[j] == addtok[i]) found = 1
				if (!found) { n++; t[n] = addtok[i]; out = out (out == "" ? "" : " ") addtok[i]; changed = 1 }
			}
			if (console != "") {
				c = "console=" console
				found = 0; for (j = 1; j <= n; j++) if (t[j] == c) found = 1
				if (!found) { n++; t[n] = c; out = out (out == "" ? "" : " ") c; changed = 1 }
			}
		}
		print (changed ? out : orig)
	}'
}
# pf_grub_default_rewrite [main|dropin [keep|comment [PARTUUIDS]]]
#   /etc/default/grub (main) or a /etc/default/grub.d/*.cfg (dropin). Only the
#   VALUES of GRUB_CMDLINE_LINUX and GRUB_CMDLINE_LINUX_DEFAULT are edited, the
#   quoting style stays. GRUB_CMDLINE_LINUX gets the full rewrite (a dropin that
#   appends to $GRUB_CMDLINE_LINUX inherits the tokens and is only stripped),
#   _DEFAULT is stripped; main gains GRUB_CMDLINE_LINUX when it has none.
#   GRUB_FORCE_PARTUUID is commented out with "comment", or when its value is
#   not one of PARTUUIDS (the target's, space separated, lower case).
pf_grub_default_rewrite() {
	local kind=${1:-main} fpu=${2:-keep} valid=${3:-} line pre var val q body rest mode new seen='' v
	local re='^([[:space:]]*(export[[:space:]]+)?)(GRUB_CMDLINE_LINUX(_DEFAULT)?)=(.*)$'
	local re_dq='^"(([^"\\]|\\.)*)"(.*)$' re_sq="^'([^']*)'(.*)\$" re_bare='^([^[:space:]#]*)(.*)$'
	local re_fpu='^[[:space:]]*(export[[:space:]]+)?GRUB_FORCE_PARTUUID=(.*)$'
	while IFS= read -r line || [ -n "$line" ]; do
		if [[ $line =~ $re ]]; then
			pre=${BASH_REMATCH[1]}; var=${BASH_REMATCH[3]}; val=${BASH_REMATCH[5]}
			if [[ $val =~ $re_dq ]]; then q='"'; body=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[3]}
			elif [[ $val =~ $re_sq ]]; then q="'"; body=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}
			elif [[ $val != [\"\']* && $val =~ $re_bare ]]; then q=; body=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}
			else printf '%s\n' "$line"; continue      # a value that does not end on its line: not ours to guess
			fi
			mode='strip'
			if [ "$var" = GRUB_CMDLINE_LINUX ]; then
				seen=y; mode=full
				# shellcheck disable=SC2016  # the literal text "$GRUB_CMDLINE_LINUX" inside the value
				if [ "$kind" = dropin ]; then case "$body " in *'$GRUB_CMDLINE_LINUX '*|*'${GRUB_CMDLINE_LINUX}'*) mode='strip';; esac; fi
			fi
			new=$(pf_cmdline_rewrite "$body" "$mode")
			if [ "$new" = "$body" ]; then printf '%s\n' "$line"; continue; fi
			if [ -z "$q" ]; then case $new in *[[:space:]]*) q='"';; esac; fi
			printf '%s%s=%s%s%s%s\n' "$pre" "$var" "$q" "$new" "$q" "$rest"
		elif [[ $line =~ $re_fpu ]]; then
			v=${BASH_REMATCH[2]}; v=${v%%[[:space:]]*}; v=${v//[\"\']/}; v=${v,,}
			if [ "$fpu" = comment ] || { [ -n "$valid" ] && [[ " $valid " != *" $v "* ]]; }; then
				printf '# migrator: %s\n' "$line"
			else printf '%s\n' "$line"; fi
		else
			printf '%s\n' "$line"
		fi
	done
	if [ "$kind" = main ] && [ -z "$seen" ]; then
		new=$(pf_cmdline_rewrite "" full)
		[ -z "$new" ] || printf 'GRUB_CMDLINE_LINUX="%s"\n' "$new"
	fi
	return 0
}
# BLS entries (RHEL 8/9, Fedora): "options …" is a kernel command line. RHEL 8 writes
# "options $kernelopts $tuned_params" and keeps the values in grubenv: such a line is only
# stripped (rd.md.*, root=/resume= by the table), nothing is added to it; RHEL 9 writes
# the literal line, which gets the full rewrite.
pf_bls_rewrite() {
	local line body
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
			options[[:space:]]*)
				body=${line#options}; body=${body#"${body%%[![:space:]]*}"}
				# shellcheck disable=SC2016  # the literal grub variable names in the entry
				case " $body " in
					*' $kernelopts '*|*' ${kernelopts} '*) printf 'options %s\n' "$(pf_cmdline_rewrite "$body" strip)";;
					*) printf 'options %s\n' "$(pf_cmdline_rewrite "$body" full)";;
				esac;;
			*) printf '%s\n' "$line";;
		esac
	done
}
# grubenv: "key=value" lines inside a 1024-byte block padded with "#". kernelopts= is
# rewritten like any command line; the block is re-padded. Status 1 (the file is left
# alone) when the result would not fit the block.
pf_grubenv_rewrite() {
	local out n
	out=$(awk 'BEGIN { RS = "\n" } /^#+$/ && NR > 1 { next } { print }' | while IFS= read -r line || [ -n "$line" ]; do
		case $line in
			kernelopts=*) printf 'kernelopts=%s\n' "$(pf_cmdline_rewrite "${line#kernelopts=}" full)";;
			*) printf '%s\n' "$line";;
		esac
	done)
	n=$(printf '%s\n' "$out" | wc -c)
	[ "$n" -le 1024 ] || { echo "grubenv would be $n bytes, the block holds 1024" >&2; return 1; }
	printf '%s\n' "$out"
	head -c $((1024 - n)) /dev/zero | tr '\0' '#'
}
# pf_dracut_conf DRIVERS(csv) [PIN]: the drop-in that makes every dracut image fit this recipient
pf_dracut_conf() {
	printf '%s\n' '# migrator: this system was migrated; the recipient needs these drivers in every initramfs'
	printf 'add_drivers+=" %s "\n' "$(printf '%s' "${1:-}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
	printf '%s\n' '# the command line comes from the boot entry, never baked into the image' 'hostonly_cmdline="no"'
	[ "${2:-0}" != 1 ] || printf '%s\n' '# the udev pin of eth0 (netfix) must act before the network comes up in the initramfs' 'install_items+=" /etc/udev/rules.d/70-persistent-net.rules "'
}
# /etc/kernel/cmdline (kernel-install, systemd-boot): the file is the command line
pf_kernel_cmdline_rewrite() {
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in ''|'#'*) printf '%s\n' "$line";; *) pf_cmdline_rewrite "$line" full;; esac
	done
}
# pf_modules_rewrite DRIVERS(csv): one line per driver that is not listed yet
# (virtio-blk and virtio_blk are the same module)
pf_modules_rewrite() {
	awk -v drv="${1:-}" -v hdr="# migrator: storage/network drivers of the recipient" '
	{ print }
	/^[ \t]*#/ { if (index($0, hdr)) hashdr = 1; next }
	NF { m = $1; gsub(/-/, "_", m); have[m] = 1 }
	END {
		n = split(drv, d, /[, \t]+/)
		for (i = 1; i <= n; i++) {
			m = d[i]; if (m == "" || m == "-") continue
			k = m; gsub(/-/, "_", k); if (k in have) continue
			if (!hashdr) { print hdr; hashdr = 1 }
			print m; have[k] = 1
		}
	}'
}
# MODULES=dep built the image for the donor's hardware only
pf_initramfs_conf_rewrite() { sed -E "s/^([[:space:]]*MODULES=[\"']?)dep([\"']?[[:space:]]*(#.*)?)\$/\\1most\\2/"; }

# efibootmgr output -> the boot numbers whose label is exactly LABEL
pf_efi_labelled() {
	awk -v label="$1" '
	BEGIN { h = "[0-9A-Fa-f]"; re = "^Boot" h h h h "[* ] " }
	$0 ~ re {
		l = substr($0, 11); t = index(l, "\t"); if (t) l = substr(l, 1, t - 1)
		sub(/[ \t]+$/, "", l)
		if (l == label) print toupper(substr($0, 5, 4))
	}'
}
# pf_efi_order_new NEW [DELETED...]: efibootmgr output from BEFORE the new entry
# was created -> the BootOrder that keeps the leading network (PXE) entries
# first and puts NEW right after them. Empty when there was no BootOrder.
pf_efi_order_new() {
	local new=$1; shift
	awk -v new="$new" -v deleted="$*" '
	BEGIN { h = "[0-9A-Fa-f]"; re = "^Boot" h h h h "[* ] "; nd = split(toupper(deleted), d, " "); for (i = 1; i <= nd; i++) gone[d[i]] = 1; new = toupper(new) }
	/^BootOrder:/ { order = toupper($2) }
	$0 ~ re { if (tolower(substr($0, 11)) ~ /pxe|network|ipv4|ipv6|ip4|ip6|mac\(|nic|ethernet|lom/) net[toupper(substr($0, 5, 4))] = 1 }
	END {
		if (order == "") exit
		n = split(order, o, ","); out = ""; lead = 1; placed = 0
		for (i = 1; i <= n; i++) {
			x = o[i]; if (x == "" || x == new || (x in gone)) continue
			if (lead && !(x in net)) { out = out (out == "" ? "" : ",") new; placed = 1; lead = 0 }
			out = out (out == "" ? "" : ",") x
		}
		if (!placed) out = out (out == "" ? "" : ",") new
		print out
	}'
}

# ==============================================================================
# what the plan says
# ==============================================================================
_pf_context() {
	PF_DIR=$RUN; PF_PLAN=$RUN/plan
	PF_IDENT=$RUN/postfix.identity
	mkdir -p "$RUN"
	plan_section "$PF_PLAN" identity > "$PF_IDENT"
	PF_ADD=$(pf_dec "$(plan_get "$PF_PLAN" network cmdline)")
	PF_CONSOLE=$(opt console)
}
_pf_donor_os() { pl_records "$PF_DIR/donor.inv" os 2>/dev/null | head -1; }
# a PARTUUID= the plan rewrote means the label changed or partitions were renumbered
pf_partuuid_changed() { awk -F'\t' 'index($1, "PARTUUID=") && $2 ~ /^->/ { hit = 1 } END { exit !hit }' "$PF_IDENT" 2>/dev/null; }
# the PARTUUIDs the target's partitions carry, from [sfdisk] (gpt: uuid=; dos: <label-id>-NN)
pf_target_partuuids() {
	plan_section "$PF_PLAN" sfdisk | awk '
	$1 == "label:" { label = $2 }
	$1 == "label-id:" { id = tolower($2); sub(/^0x/, "", id) }
	/^\/dev\// {
		if (label == "gpt") { if (match($0, /uuid=[0-9A-Fa-f-]+/)) printf "%s ", tolower(substr($0, RSTART + 5, RLENGTH - 5)) }
		else { n = $1; sub(/^.*[^0-9]/, "", n); printf "%s-%02x ", id, n + 0 }
	}'
}
# pf_method_of_path PATH: the transfer method of the volume PATH lives on (longest mount prefix)
pf_method_of_path() {
	local row m best='' method=''
	while IFS= read -r row; do
		m=$(pl_field "$row" mount)
		case $m in /*) ;; *) continue;; esac
		case $1 in "$m"/*|"$m") ;; *) [ "$m" = / ] || continue;; esac
		if [ ${#m} -gt ${#best} ]; then best=$m; method=$(pl_field "$row" method); fi
	done < <(plan_section "$PF_PLAN" volumes)
	printf '%s\n' "$method"
}
# where the ESP is mounted inside the target: the [volumes] row of [postfix] esp=
pf_efi_dir() {
	local esp row m
	esp=$(plan_get "$PF_PLAN" postfix esp)
	while IFS= read -r row; do
		m=$(pl_field "$row" mount)
		if [ "$(pl_field "$row" target)" = "$esp" ] || [ "$(pl_field "$row" method)" = esp ]; then
			case $m in /*) printf '%s\n' "$m"; return 0;; esac
		fi
	done < <(plan_section "$PF_PLAN" volumes)
	m=$(pl_field "$(_pf_donor_os)" efidir)
	case $m in /*) printf '%s\n' "$m";; *) echo /boot/efi;; esac
}
# the bootloader id: the directory grub/shim already live in on the ESP, else os-release ID
pf_efi_id() {   # EFIDIR
	local top=$TARGET_MNT$1/EFI osid d id
	osid=$(sed -n 's/^ID=//p' "$(_pf_real /etc/os-release)" 2>/dev/null | tr -d "\"'" | head -1)
	[ -n "$osid" ] || osid=$(pl_field "$(_pf_donor_os)" id)
	if [ -n "$osid" ] && [ -d "$top/$osid" ]; then printf '%s\n' "$osid"; return 0; fi
	for d in "$top"/*/; do
		[ -d "$d" ] || continue
		id=$(basename "$d"); case ${id,,} in boot) continue;; esac
		printf '%s\n' "$id"; return 0
	done
	printf '%s\n' "${osid:-debian}"
}

# ==============================================================================
# the steps (deb family)
# ==============================================================================
# the file copy prunes the trees it must not descend into (TX_EXCL_DIRS: they are
# live mounts on the donor); on the target they have to exist as plain directories,
# because services mount onto them -- lxcfs refused to start without /var/lib/lxcfs
# and left a failed unit on .111 (D27). The ESP is mounted by apply/target_mount.
pf_step_mountpoints() {
	say "--- excluded mountpoints"
	local d
	for d in $TX_EXCL_DIRS; do
		[ -d "$TARGET_MNT/$d" ] && continue
		say "creating /$d (a mountpoint on the donor, missing in the copy)"
		[ -n "$DRY" ] || mkdir -p "$TARGET_MNT/$d"
		PF_CHANGED=$((PF_CHANGED + 1))
	done
}
pf_step_fstab() {
	say "--- fstab"
	local swaps v
	if pf_has /etc/fstab; then _pf_edit /etc/fstab pf_fstab_rewrite "$PF_IDENT"
	else pf_warn "the target has no /etc/fstab"; fi
	if pf_has /etc/initramfs-tools/conf.d/resume; then
		_pf_edit /etc/initramfs-tools/conf.d/resume pf_resume_rewrite "$PF_IDENT"
		# a RESUME=UUID= the table does not know and no swap of the target carries
		v=$(pf_cat /etc/initramfs-tools/conf.d/resume | sed -n 's/^[[:space:]]*RESUME=UUID=//p' | tr -d "\"'" | head -1)
		swaps=$(plan_get "$PF_PLAN" verify swap)
		if [ -n "$v" ] && [ -n "$swaps" ] && [ -z "$DRY" ]; then
			case ",$swaps," in *",$v,"*) ;; *) pf_warn "/etc/initramfs-tools/conf.d/resume names UUID=$v, which is no swap of the target: the boot may wait for it (set RESUME=none)";; esac
		fi
	fi
}
pf_raid() { [ "$(plan_get "$PF_PLAN" postfix raid)" = 1 ]; }
# the target's resolv.conf during an apt run in the chroot: a regular file is bound over by
# target_mount; a symlink (systemd-resolved) points nowhere inside a chroot, so it is set
# aside for the duration and put back afterwards
_pf_resolv_begin() {
	local f=$TARGET_MNT/etc/resolv.conf
	PF_RESOLV_SAVED=
	[ -n "$DRY" ] && return 0
	[ -L "$f" ] || return 0
	mv "$f" "$f.migrator-tmp" && cp /etc/resolv.conf "$f" || { mv -f "$f.migrator-tmp" "$f" 2>/dev/null; return 0; }
	PF_RESOLV_SAVED=y
	cleanup_add "[ -L $(printf '%q' "$f.migrator-tmp") ] && mv -f $(printf '%q' "$f.migrator-tmp") $(printf '%q' "$f")"
}
_pf_resolv_end() {
	local f=$TARGET_MNT/etc/resolv.conf
	[ -n "$PF_RESOLV_SAVED" ] || return 0
	rm -f "$f"; mv -f "$f.migrator-tmp" "$f"; PF_RESOLV_SAVED=
}
# _pf_apt_install PKG: apt in the chroot with the target's own sources, services kept
# from starting (policy-rc.d); the package is what the migrated system boots with
_pf_apt_install() {
	local pkg=$1 prc=$TARGET_MNT/usr/sbin/policy-rc.d rc=0
	if [ -n "$DRY" ]; then say "(dry) chroot apt-get update && apt-get install -y --no-install-recommends $pkg"; return 0; fi
	_pf_resolv_begin
	[ -e "$prc" ] || { printf '#!/bin/sh\nexit 101\n' > "$prc" && chmod 755 "$prc" && cleanup_add "rm -f $(printf '%q' "$prc")"; }
	# A donor frozen in the middle of a dpkg run — an unattended-upgrade is the
	# usual way to be in one — leaves the copy half-configured, and then every
	# apt call refuses with "dpkg was interrupted" instead of installing (D34).
	# Finish that first: dpkg --audit names the packages, --configure -a fixes them.
	local audit; audit=$(target_chroot_q dpkg --audit 2>/dev/null)
	if [ -n "$audit" ]; then
		warn "the copy's dpkg is half-configured (the donor was frozen mid-upgrade?): dpkg --configure -a before installing $pkg"
		target_chroot dpkg --configure -a || warn "dpkg --configure -a returned $? in the target (continuing)"
	fi
	target_chroot apt-get -o Acquire::Retries=2 update || warn "apt-get update in the target returned $? (continuing: the lists may be good enough)"
	target_chroot apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends "$pkg" || rc=$?
	rm -f "$prc"
	_pf_resolv_end
	return $rc
}
pf_step_mdadm() {
	say "--- mdadm"
	local f arrays=$RUN/postfix.arrays
	if pf_raid; then
		# 1. mdadm itself: the initramfs hook, the assembly at boot, the monitor
		if pf_has /usr/sbin/mdadm || pf_has /sbin/mdadm; then say "mdadm is in the target"
		else
			say "the donor OS has no mdadm: installing it into the target (apt, the target's own sources)"
			_pf_apt_install mdadm || die "$EX_FAIL" "apt-get install mdadm failed in the target: the arrays cannot be assembled at boot. By hand: 'rescue', chroot <root>, apt-get install mdadm (check /etc/resolv.conf and the sources), then repeat 'migrator -s postfix'"
			{ pf_has /usr/sbin/mdadm || pf_has /sbin/mdadm; } || [ -n "$DRY" ] || die "$EX_FAIL" "mdadm is still missing in the target after apt-get install"
		fi
		# 2. mdadm.conf: exactly our arrays (the donor's, if any, are commented out)
		plan_md_arrays "$PF_PLAN" > "$arrays"
		if pf_has /etc/mdadm/mdadm.conf; then _pf_edit /etc/mdadm/mdadm.conf pf_mdadm_conf_rewrite "$arrays"
		elif pf_has /etc/mdadm.conf; then _pf_edit /etc/mdadm.conf pf_mdadm_conf_rewrite "$arrays"
		else pf_new /etc/mdadm/mdadm.conf 0644 < <(pf_md_conf_new "$arrays"); fi
		say "mdadm.conf: $(grep -c . "$arrays") ARRAY line(s) of this recipient's arrays"
	else
		for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do _pf_edit "$f" pf_mdadm_conf_rewrite; done
	fi
	# device.map names the donor's BIOS disks; grub-install --recheck no longer rewrites it
	for f in /boot/grub/device.map /boot/grub2/device.map; do pf_remove "$f"; done
}
pf_step_cmdline() {
	say "--- kernel cmdline"
	local fpu=keep valid f
	pf_partuuid_changed && fpu=comment
	! pf_raid || fpu=comment      # root is on an md array: GRUB_FORCE_PARTUUID (a direct partition boot) cannot hold
	valid=$(pf_target_partuuids)
	if pf_has /etc/default/grub; then _pf_edit /etc/default/grub pf_grub_default_rewrite main "$fpu" "$valid"
	else pf_warn "the target has no /etc/default/grub: its kernel command line is not managed there"; fi
	for f in "$TARGET_MNT"/etc/default/grub.d/*.cfg; do
		[ -f "$f" ] || continue
		[ "${f#"$TARGET_MNT"}" != "$PF_OSPROBER_CFG" ] || continue
		_pf_edit "${f#"$TARGET_MNT"}" pf_grub_default_rewrite dropin "$fpu" "$valid"
	done
	if pf_has /etc/kernel/cmdline; then _pf_edit /etc/kernel/cmdline pf_kernel_cmdline_rewrite; fi
	# BLS entries and grubenv (rhel 8/9; harmless where absent)
	for f in "$TARGET_MNT"/boot/loader/entries/*.conf; do
		[ -f "$f" ] || continue
		_pf_edit "${f#"$TARGET_MNT"}" pf_bls_rewrite
	done
	for f in /boot/grub2/grubenv /boot/grub/grubenv; do
		pf_has "$f" || continue
		grep -q '^kernelopts=' "$(_pf_real "$f")" 2>/dev/null || continue
		_pf_edit "$f" pf_grubenv_rewrite
		break
	done
}
pf_step_lvm() {
	say "--- lvm"
	# system.devices lists the donor's PVs by WWID: LVM would see no PV at all
	case $(plan_get "$PF_PLAN" postfix lvm_devices_file) in delete) pf_remove /etc/lvm/devices/system.devices;; esac
	case $(plan_get "$PF_PLAN" postfix lvm_filter) in neutralise) _pf_edit /etc/lvm/lvm.conf pf_lvm_conf_rewrite;; esac
}
pf_step_network() {
	say "--- network"
	declare -F netfix_run >/dev/null || die "$EX_FAIL" "lib/netfix.sh is not loaded: the network step cannot run"
	netfix_run
}
# dracut: a drop-in with the recipient's drivers, then every kernel of the donor's
# inventory that still has its modules in the tree gets its image rebuilt in the chroot
# (the running system there is the target: hostonly images fit THIS hardware)
pf_step_initramfs_dracut() {
	local drv pin rec ver initrd n=0
	drv=$(plan_get "$PF_PLAN" target driver); [ "$drv" != - ] || drv=
	pin=$(plan_get "$PF_PLAN" network pin)
	pf_new /etc/dracut.conf.d/90-migrator.conf 0644 < <(pf_dracut_conf "$drv" "$pin")
	while IFS= read -r rec; do
		ver=$(pl_field "$rec" version); initrd=$(pl_field "$rec" initrd)
		[ -n "$ver" ] || continue
		case $initrd in /*) ;; *) initrd=/boot/initramfs-$ver.img;; esac
		if [ ! -f "$TARGET_MNT/lib/modules/$ver/modules.dep" ] && [ ! -f "$TARGET_MNT/usr/lib/modules/$ver/modules.dep" ]; then
			pf_warn "kernel $ver: no modules in the tree, its initramfs is not rebuilt"; continue
		fi
		n=$((n + 1))
		target_chroot dracut --force "$initrd" "$ver" \
			|| die "$EX_FAIL" "dracut failed for kernel $ver in the target: run 'rescue', then 'chroot <root> dracut --force $initrd $ver' by hand, fix what it reports and repeat 'migrator -s postfix'"
	done < <(pl_records "$PF_DIR/donor.inv" kernel 2>/dev/null)
	[ "$n" -gt 0 ] || pf_warn "no kernel of the donor inventory has modules in the tree: no initramfs was rebuilt"
}
pf_step_initramfs() {
	say "--- initramfs"
	local drv f
	if [ "$(plan_get "$PF_PLAN" postfix initramfs)" = dracut ]; then pf_step_initramfs_dracut; return 0; fi
	drv=$(plan_get "$PF_PLAN" target driver)
	if pf_has /etc/initramfs-tools/modules; then _pf_edit /etc/initramfs-tools/modules pf_modules_rewrite "$drv"
	else pf_new /etc/initramfs-tools/modules 0644 < <(pf_modules_rewrite "$drv" < /dev/null); fi
	_pf_edit /etc/initramfs-tools/initramfs.conf pf_initramfs_conf_rewrite
	for f in "$TARGET_MNT"/etc/initramfs-tools/conf.d/*; do
		[ -f "$f" ] || continue
		_pf_edit "${f#"$TARGET_MNT"}" pf_initramfs_conf_rewrite
	done
	target_chroot update-initramfs -u -k all \
		|| die "$EX_FAIL" "update-initramfs failed in the target: run 'rescue', then 'chroot <root> update-initramfs -u -k all' by hand, fix what it reports and repeat 'migrator postfix'"
}

# os-prober mounts every foreign filesystem it finds (the other disks of this
# box): off for our update-grub only, through a drop-in that does not stay
_pf_osprober_off() {
	local f=$TARGET_MNT$PF_OSPROBER_CFG
	if [ -n "$DRY" ]; then say "(dry) would write $PF_OSPROBER_CFG (GRUB_DISABLE_OS_PROBER=true) for the update-grub run only"; return 0; fi
	_pf_inside "$f" || die "$EX_FAIL" "$PF_OSPROBER_CFG resolves outside the target"
	mkdir -p "$(dirname "$f")" || die "$EX_FAIL" "cannot create $(dirname "$f")"
	cleanup_add "rm -f $(printf '%q' "$f")"
	printf '%s\n' '# migrator: temporary, removed when postfix ends' 'GRUB_DISABLE_OS_PROBER=true' > "$f" || die "$EX_FAIL" "cannot write $f"
	log "wrote $PF_OSPROBER_CFG (temporary)"
}
_pf_osprober_restore() {
	[ -n "$DRY" ] && return 0
	rm -f "$TARGET_MNT$PF_OSPROBER_CFG"
	log "removed $PF_OSPROBER_CFG"
}
_pf_update_grub() {
	target_chroot update-grub \
		|| die "$EX_FAIL" "update-grub failed in the target: run 'rescue', then 'chroot <root> update-grub' by hand, fix what it reports and repeat 'migrator postfix'"
}
# debconf keeps the disk grub-pc reinstalls itself to on every upgrade: left at
# the donor's disk the next 'apt upgrade' fails or writes the wrong device
_pf_debconf_ready() {
	[ -n "$DRY" ] && return 0
	target_chroot_q sh -c 'command -v debconf-set-selections' >/dev/null 2>&1 && target_chroot_q dpkg-query -W grub-pc >/dev/null 2>&1
}
_pf_live_grub() {   # PLATFORM: grub of the Live for a firmware the donor OS carries no grub for
	pf_live_grub_ready "$1" && return 0
	[ -n "$DRY" ] && { say "(dry) grub for $1 is not in this Live yet (bootstrap installs it)"; return 0; }
	if declare -F bootstrap_local >/dev/null; then bootstrap_local grub; fi
	pf_live_grub_ready "$1" || die "$EX_ENV" "no grub for $1 in this Live (grub-install, /usr/lib/grub/$1): apt-get install grub2-common grub-pc-bin grub-efi-amd64-bin grub-common"
}
# _pf_byid DEV [PARTNUM]: the stable name of a recipient disk (or a partition of it) for debconf
_pf_byid() {
	local byid; byid=$(pl_lookup "$PF_DIR/recipient.inv" disk dev "$1" byid 2>/dev/null)
	case $byid in ''|-) if [ -n "${2:-}" ]; then apply_partnode "$1" "$2"; else printf '%s\n' "$1"; fi;;
		*) printf '/dev/disk/by-id/%s%s\n' "$byid" "${2:+-part$2}";; esac
}
_pf_grub_bios() {   # DISK FROM_LIVE [DISK2]: the boot code on every disk, the config once
	local disk=$1 live=$2 disk2=${3:-} d devs=''
	for d in $disk $disk2; do
		if [ -z "$live" ]; then
			target_chroot grub-install --target=i386-pc --recheck "$d" \
				|| die "$EX_FAIL" "grub-install failed in the target: run 'rescue', then 'chroot <root> grub-install --target=i386-pc --recheck $d' by hand and repeat 'migrator postfix'"
		else
			# uefi -> bios: the donor OS has no grub-pc; the Live's grub writes the boot
			# code and its modules into the target's /boot/grub
			_pf_live_grub i386-pc
			must grub-install --target=i386-pc "--boot-directory=$TARGET_MNT/boot" --recheck "$d"
		fi
		devs="${devs:+$devs, }$(_pf_byid "$d")"
	done
	if [ -n "$live" ]; then
		pf_warn "grub for BIOS was installed from the Live: the migrated OS still carries grub-efi and will not update this boot code"
		pf_followup "apt install grub-pc && apt purge grub-efi-amd64 in the migrated OS (grub for BIOS came from the Live)"
	fi
	_pf_update_grub
	_pf_debconf_ready || return 0
	target_chroot_sh "echo 'grub-pc grub-pc/install_devices multiselect $devs' | debconf-set-selections" \
		|| pf_warn "debconf: grub-pc/install_devices could not be set to $devs (the next grub-pc upgrade will ask)"
}
_pf_efi_nvram() {   # DISK ESPNUM ID EFIDIR [LABELSUFFIX]
	local disk=$1 num=$2 id=$3 esp=$TARGET_MNT$4 sfx=${5:-} label loader before after new order cur n
	local -a deleted=()
	if ! pf_is_uefi_live; then
		say "this Live was not booted through UEFI: no NVRAM entry is written (the firmware finds \\EFI\\BOOT\\BOOTX64.EFI)"
		return 0
	fi
	if [ -n "$DRY" ]; then say "(dry) would register the boot entry with efibootmgr (-c -d $disk -p $num) and keep the network entries first"; return 0; fi
	have efibootmgr || { pf_warn "efibootmgr is not in this Live: no NVRAM entry was written"; return 0; }
	case $num in ''|-|*[!0-9]*) pf_warn "[target] esp= is not a partition number: no NVRAM entry was written"; return 0;; esac
	label=$(pl_field "$(_pf_donor_os)" pretty); [ -n "$label" ] || label=$id
	label="$label$sfx"
	if [ -f "$esp/EFI/$id/shimx64.efi" ]; then loader="\\EFI\\$id\\shimx64.efi"
	elif [ -f "$esp/EFI/$id/grubx64.efi" ]; then loader="\\EFI\\$id\\grubx64.efi"
	elif [ -f "$esp/EFI/BOOT/BOOTX64.EFI" ]; then loader='\EFI\BOOT\BOOTX64.EFI'
	else pf_warn "no shimx64.efi, grubx64.efi or BOOTX64.EFI on the ESP: no NVRAM entry was written"; return 0; fi
	before=$(efibootmgr 2>/dev/null) || { pf_warn "efibootmgr cannot read the boot entries: no NVRAM entry was written"; return 0; }
	for n in $(pf_efi_labelled "$label" <<< "$before"); do
		if run efibootmgr -b "$n" -B; then deleted+=("$n"); else pf_warn "efibootmgr could not delete the old entry Boot$n ($label)"; fi
	done
	run efibootmgr -c -d "$disk" -p "$num" -L "$label" -l "$loader" \
		|| { pf_warn "efibootmgr could not create the boot entry '$label' (verify reports the NVRAM state)"; return 0; }
	if [ "$(opt bootorder pxe)" = local ]; then say "bootorder=local: '$label' stays first in BootOrder"; return 0; fi
	after=$(efibootmgr 2>/dev/null)
	new=$(pf_efi_labelled "$label" <<< "$after" | head -1)
	[ -n "$new" ] || { pf_warn "the new boot entry '$label' is not listed by efibootmgr: BootOrder left as is"; return 0; }
	order=$(pf_efi_order_new "$new" "${deleted[@]}" <<< "$before")
	cur=$(sed -n 's/^BootOrder:[[:space:]]*//p' <<< "$after" | tr 'a-f' 'A-F')
	if [ -n "$order" ] && [ "$order" != "$cur" ]; then
		run efibootmgr -o "$order" || pf_warn "efibootmgr could not restore BootOrder $order (the network entries are no longer first)"
	fi
}
# the second ESP of a mirror: a copy of the first, the loaders installed into it the same
# way, mounted for the duration under the Live's /run (visible in the chroot as /run/…)
_pf_esp2() {   # ESP2DEV FROM_LIVE ID EFIDIR DISK2 ESPNUM
	local dev=$1 live=$2 id=$3 efidir=$4 disk2=$5 num=$6 m=/run/migrator-esp2 mnt=$TARGET_MNT/run/migrator-esp2
	[ -n "$dev" ] && [ "$dev" != - ] || { pf_warn "raid=1 on uefi but the plan names no second ESP (esp2=): disk 2 cannot boot on its own"; return 0; }
	if [ -n "$DRY" ]; then
		say "(dry) would mount $dev at $m, copy $efidir onto it, grub-install --target=x86_64-efi --efi-directory=$m (+ --removable) into it, and register it in NVRAM"
		return 0
	fi
	mkdir -p "$mnt" || die "$EX_FAIL" "cannot create $mnt"
	must mount -t vfat -o rw,umask=0077 "$dev" "$mnt"
	cleanup_add "umount $(printf '%q' "$mnt") 2>/dev/null"
	# cp -r, not -a: vfat has no owners or modes to preserve
	run cp -r "$TARGET_MNT$efidir/." "$mnt/" || pf_warn "copying $efidir onto $dev was not complete ($?)"
	if [ -z "$live" ]; then
		target_chroot grub-install --target=x86_64-efi "--efi-directory=$m" "--bootloader-id=$id" --recheck --no-nvram \
			|| { umount "$mnt"; die "$EX_FAIL" "grub-install into the second ESP $dev failed: run 'rescue', mount $dev, 'chroot <root> grub-install --target=x86_64-efi --efi-directory=<mount> --bootloader-id=$id --recheck --no-nvram' and repeat 'migrator -s postfix'"; }
		target_chroot grub-install --target=x86_64-efi "--efi-directory=$m" "--bootloader-id=$id" --recheck --no-nvram --removable \
			|| { umount "$mnt"; die "$EX_FAIL" "grub-install --removable into the second ESP $dev failed"; }
	else
		must grub-install --target=x86_64-efi "--efi-directory=$mnt" "--boot-directory=$TARGET_MNT/boot" --removable --no-nvram --recheck
	fi
	sync
	_pf_efi_nvram "$disk2" "$num" "$id" /run/migrator-esp2 " (disk 2)"
	must umount "$mnt"; rmdir "$mnt" 2>/dev/null || true
	say "second ESP $dev: loaders installed, a copy of $efidir"
}
_pf_grub_uefi() {   # DISK FROM_LIVE [DISK2 ESP2DEV]
	local disk=$1 live=$2 disk2=${3:-} esp2=${4:-} efidir id devs
	efidir=$(pf_efi_dir); id=$(pf_efi_id "$efidir")
	[ -n "$DRY" ] || [ -d "$TARGET_MNT$efidir" ] || die "$EX_FAIL" "the ESP mount point $efidir is missing in the target"
	if [ -z "$live" ]; then
		target_chroot grub-install --target=x86_64-efi "--efi-directory=$efidir" "--bootloader-id=$id" --recheck --no-nvram \
			|| die "$EX_FAIL" "grub-install failed in the target: run 'rescue', then 'chroot <root> grub-install --target=x86_64-efi --efi-directory=$efidir --bootloader-id=$id --recheck --no-nvram' by hand and repeat 'migrator postfix'"
		# the removable path is what boots when the NVRAM entry is lost (or never written)
		target_chroot grub-install --target=x86_64-efi "--efi-directory=$efidir" "--bootloader-id=$id" --recheck --no-nvram --removable \
			|| die "$EX_FAIL" "grub-install --removable failed in the target (the fallback \\EFI\\BOOT\\BOOTX64.EFI was not written)"
	else
		# bios -> uefi: the donor OS has no grub-efi; the Live's grub writes the removable loader
		_pf_live_grub x86_64-efi
		must grub-install --target=x86_64-efi "--efi-directory=$TARGET_MNT$efidir" "--boot-directory=$TARGET_MNT/boot" --removable --no-nvram --recheck
		pf_warn "grub for UEFI was installed from the Live: the migrated OS still carries grub-pc and will not update this loader"
		pf_followup "apt install grub-efi-amd64 && apt purge grub-pc in the migrated OS (grub for UEFI came from the Live)"
	fi
	_pf_update_grub
	if [ -n "$live" ] && _pf_debconf_ready; then
		# grub-pc would otherwise try to reinstall itself to the donor's disk on its next upgrade
		target_chroot_sh "printf '%s\\n' 'grub-pc grub-pc/install_devices multiselect ' 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections" \
			|| pf_warn "debconf: grub-pc/install_devices could not be emptied (the next grub-pc upgrade may fail)"
	fi
	_pf_efi_nvram "$disk" "$(plan_get "$PF_PLAN" target esp)" "$id" "$efidir"
	if [ -n "$disk2" ]; then
		_pf_esp2 "$esp2" "$live" "$id" "$efidir" "$disk2" "$(plan_get "$PF_PLAN" target esp)"
		# a grub-efi that knows grub-efi/install_devices keeps several ESPs current on
		# upgrades (its template is in the debconf cache): tell it about both
		if [ -z "$live" ] && [ -z "$DRY" ] && grep -qs '^Name: grub-efi/install_devices$' "$TARGET_MNT/var/cache/debconf/templates.dat"; then
			devs="$(_pf_byid "$disk" "$(plan_get "$PF_PLAN" target esp)"), $(_pf_byid "$disk2" "$(plan_get "$PF_PLAN" target esp)")"
			target_chroot_sh "echo 'grub-efi-amd64 grub-efi/install_devices multiselect $devs' | debconf-set-selections" \
				|| pf_warn "debconf: grub-efi/install_devices could not be set to $devs"
		else
			pf_followup "the second ESP ($esp2) is a copy made now: after a grub-efi upgrade copy /boot/efi onto it again (mount it, cp -r), unless grub-efi/install_devices lists both"
		fi
	fi
}
# --- rhel: grub2 ---------------------------------------------------------------------------
# A firmware change on rhel brings the grub2 of the OTHER firmware in through dnf
# ([postfix] grub_pkgs=): rhel's grub2-mkconfig writes blscfg, which the Live's
# Debian grub does not know, so nothing of the Live can serve here (deb: grub_from_live).
pf_grub_pkgs() { local p; p=$(plan_get "$PF_PLAN" postfix grub_pkgs); [ "$p" != - ] || p=; printf '%s\n' "${p//,/ }"; }
# _pf_dnf_install PKG...: dnf (yum where there is no dnf: CentOS 7) in the chroot with the
# target's own repositories; packages already there are skipped (rpm -q)
_pf_dnf_install() {
	local p missing='' tool=dnf rc=0
	if [ -n "$DRY" ]; then say "(dry) chroot rpm -q $* || dnf -y --setopt=install_weak_deps=False install <the missing ones> (yum where there is no dnf)"; return 0; fi
	for p in "$@"; do
		if target_chroot_q rpm -q "$p" >/dev/null 2>&1; then say "$p is in the target"; else missing="${missing:+$missing }$p"; fi
	done
	[ -n "$missing" ] || return 0
	target_chroot_q sh -c 'command -v dnf' >/dev/null 2>&1 || tool=yum
	_pf_resolv_begin
	# no weak dependencies: shim-x64 would otherwise bring fwupd, bluez and friends into a
	# server that never asked for them (yum of CentOS 7 knows no weak deps and no such option)
	# shellcheck disable=SC2086  # the package list is split on purpose
	if [ "$tool" = dnf ]; then target_chroot dnf -y --setopt=install_weak_deps=False install $missing || rc=$?
	else target_chroot yum -y install $missing || rc=$?; fi
	_pf_resolv_end
	[ "$rc" = 0 ] || return "$rc"
	for p in $missing; do target_chroot_q rpm -q "$p" >/dev/null 2>&1 || { warn "$p is still missing after $tool install"; return 1; }; done
	return 0
}
_pf_dnf_die() {   # PKGS WHAT: the disk is written, the OS is there: the manual path is dnf in a chroot
	die "$EX_FAIL" "installing $1 into the target failed: $2 cannot be set up. By hand: 'rescue', chroot <root>, check /etc/resolv.conf and the repositories (dnf repolist; a RHEL without a subscription needs a reachable repo or the rpms by hand), dnf -y install $1, then repeat 'migrator -s postfix'"
}
# pf_fs_uuid_of PATH: the UUID of the filesystem PATH of the target lives on (a seam for the tests)
pf_fs_uuid_of() { findmnt -no UUID -T "$TARGET_MNT$1" 2>/dev/null | head -1; }
# _pf_grub2_efi_stub CFG: what the packages' grubx64.efi reads first on the ESP: on a rhel 9
# it only hands over to /boot/grub2/grub.cfg (RHEL 8 ships the real one there, but the hand-over
# works for its grub too); written only when the install left none
_pf_grub2_efi_stub() {   # CFG (path inside the target)
	local uuid
	uuid=$(pf_fs_uuid_of /boot/grub2); [ -n "$uuid" ] || uuid=$(pf_fs_uuid_of /boot)
	[ -n "$uuid" ] || { pf_warn "cannot tell the UUID of the filesystem under /boot/grub2: no $1 written, grub will look for its config by hand"; return 0; }
	# shellcheck disable=SC2016  # grub's own $dev/$prefix, not the shell's
	pf_new "$1" 0700 < <(printf '%s\n' \
		"search --no-floppy --fs-uuid --set=dev $uuid" \
		'set prefix=($dev)/grub2' \
		'export $prefix' \
		'configfile $prefix/grub.cfg')
	say "$1: a stub handing over to /boot/grub2/grub.cfg (filesystem $uuid)"
}
# a grubenv symlinked into the ESP (RHEL 8 uefi) is out of reach for a BIOS grub (another
# filesystem): the block itself is put in its place
_pf_grubenv_regular() {
	local f=$TARGET_MNT/boot/grub2/grubenv real
	[ -L "$f" ] || return 0
	real=$(_pf_real /boot/grub2/grubenv)
	if [ -n "$DRY" ]; then say "(dry) would replace the symlink /boot/grub2/grubenv (-> $(readlink "$f")) by a copy of the block"; return 0; fi
	if [ -f "$real" ]; then rm -f "$f" && cp "$real" "$f" && chmod 0600 "$f" || die "$EX_FAIL" "cannot replace the grubenv symlink $f"
	else rm -f "$f"; fi
	PF_CHANGED=$((PF_CHANGED + 1)); log "replaced the symlink /boot/grub2/grubenv by a regular grubenv (BIOS grub cannot follow it into the ESP)"
}
# _pf_grub2_cfg: the grub.cfg grub really reads in the target (RHEL 9: /boot/grub2/grub.cfg,
# the one on the ESP is a stub; RHEL 8 uefi: the one on the ESP; bios: /boot/grub2/grub.cfg)
_pf_grub2_cfg() {
	local c
	for c in "$TARGET_MNT/boot/grub2/grub.cfg" "$TARGET_MNT"/boot/efi/EFI/*/grub.cfg; do
		[ -f "$c" ] || continue
		if [ "$(wc -c < "$c")" -lt 1024 ] && grep -q configfile "$c"; then continue; fi
		printf '%s\n' "${c#"$TARGET_MNT"}"; return 0
	done
	return 1
}
_pf_grub2_mkconfig() {   # CFG (path inside the target)
	# os-prober would mount every foreign disk of this box; rhel's grub2-mkconfig reads no
	# /etc/default/grub.d, so the switch goes in through the environment
	target_chroot env GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o "$1" \
		|| die "$EX_FAIL" "grub2-mkconfig failed in the target: run 'rescue', then 'chroot <root> grub2-mkconfig -o $1' by hand, fix what it reports and repeat 'migrator -s postfix'"
}
_pf_grub2_bios() {   # DISK
	local pkgs; pkgs=$(pf_grub_pkgs)
	if [ -n "$pkgs" ]; then
		# uefi -> bios: the donor OS carries grub2-efi only; grub2-pc (+ its i386-pc modules)
		# comes from its own repositories, then the usual grub2-install writes the boot code
		say "firmware change: grub2 for BIOS ($pkgs) is installed into the target by dnf"
		# shellcheck disable=SC2086  # the package list is split on purpose
		_pf_dnf_install $pkgs || _pf_dnf_die "$pkgs" "the BIOS boot code"
		_pf_grubenv_regular
		pf_followup "grub2 for BIOS ($pkgs) was installed by dnf; the uefi packages (grub2-efi-x64, shim-x64) stay and may be removed"
	fi
	target_chroot grub2-install --target=i386-pc --recheck "$1" \
		|| die "$EX_FAIL" "grub2-install failed in the target: run 'rescue', then 'chroot <root> grub2-install --target=i386-pc --recheck $1' by hand and repeat 'migrator -s postfix'"
	_pf_grub2_mkconfig /boot/grub2/grub.cfg
}
_pf_grub2_uefi() {   # DISK
	local efidir id cfg pkgs; pkgs=$(pf_grub_pkgs)
	efidir=$(pf_efi_dir)
	[ -n "$DRY" ] || [ -d "$TARGET_MNT$efidir" ] || die "$EX_FAIL" "the ESP mount point $efidir is missing in the target"
	if [ -n "$pkgs" ]; then
		# bios -> uefi: the new ESP is mounted at $efidir (target_mount, the esp-new row); the
		# packages put the signed shim + grub into EFI/<vendor>/ and EFI/BOOT/BOOTX64.EFI
		say "firmware change: shim and grub2 for UEFI ($pkgs) are installed into the target by dnf"
		# shellcheck disable=SC2086  # the package list is split on purpose
		_pf_dnf_install $pkgs || _pf_dnf_die "$pkgs" "the UEFI loaders"
		pf_followup "shim and grub2 for UEFI ($pkgs) were installed by dnf; grub2-pc stays and may be removed"
	fi
	# after the install: the vendor directory the packages made (redhat on RHEL and Oracle)
	id=$(pf_efi_id "$efidir")
	# never grub2-install on a uefi rhel: the signed shim + grub of the packages are on the
	# ESP already (the donor's, or just installed), and grub2-install would replace them with an unsigned core
	if [ -z "$DRY" ] && [ ! -f "$TARGET_MNT$efidir/EFI/$id/grubx64.efi" ]; then
		pf_warn "no $efidir/EFI/$id/grubx64.efi on the ESP: the firmware has nothing of $id to load (dnf reinstall grub2-efi-x64 shim-x64 in the target)"
		pf_followup "dnf reinstall grub2-efi-x64 shim-x64 (the ESP had no $id loader)"
	fi
	if [ -n "$pkgs" ] && [ -z "$DRY" ] && [ ! -f "$TARGET_MNT$efidir/EFI/$id/grub.cfg" ]; then _pf_grub2_efi_stub "$efidir/EFI/$id/grub.cfg"; fi
	if cfg=$(_pf_grub2_cfg); then _pf_grub2_mkconfig "$cfg"
	elif [ -n "$DRY" ]; then say "(dry) chroot grub2-mkconfig -o <the real grub.cfg of the tree>"
	elif [ -n "$pkgs" ]; then _pf_grub2_mkconfig /boot/grub2/grub.cfg
	else pf_warn "no grub.cfg found under /boot/grub2 or the ESP: grub2-mkconfig not run"; fi
	_pf_efi_nvram "$1" "$(plan_get "$PF_PLAN" target esp)" "$id" "$efidir"
}
pf_step_bootloader() {
	say "--- bootloader"
	local grub disk live='' disk2='' esp2=''
	grub=$(plan_get "$PF_PLAN" postfix grub); disk=$(plan_get "$PF_PLAN" target disk)
	[ "$(plan_get "$PF_PLAN" target grub_from_live)" != 1 ] || live=y
	if pf_raid; then disk2=$(plan_get "$PF_PLAN" postfix disk2); esp2=$(plan_get "$PF_PLAN" postfix esp2); fi
	if [ "$(plan_get "$PF_PLAN" postfix family)" = rhel ]; then
		case $grub in
			i386-pc)    _pf_grub2_bios "$disk" ;;
			x86_64-efi) _pf_grub2_uefi "$disk" ;;
		esac
		return 0
	fi
	_pf_osprober_off
	case $grub in
		i386-pc)    _pf_grub_bios "$disk" "$live" "$disk2" ;;
		x86_64-efi) _pf_grub_uefi "$disk" "$live" "$disk2" "$esp2" ;;
	esac
	_pf_osprober_restore
	if pf_raid; then pf_followup "md RAID1: the resync of $(plan_get "$PF_PLAN" target md | tr ',' ' ') continues in the background after the boot (cat /proc/mdstat); both disks carry the bootloader"; fi
}
# a swapfile is excluded from the files method (a tar of zeroes); block copies carry it
pf_step_swapfiles() {
	say "--- swapfiles"
	local rec path size method f mib avail n=0
	[ -r "$PF_DIR/donor.inv" ] || return 0
	# In the pre-check the target is a dm-snapshot and every write goes to its COW,
	# which on the Live lives on a tmpfs of half the RAM (982 MiB on a 2 GiB box):
	# dd'ing a 2 GiB swapfile into it fills the COW and the next write returns
	# EIO - in the E2 run that was a "cannot create the directory of
	# /mnt/migrator/precheck/etc/sysctl.d: Input/output error" far from the cause
	# (D38).  The swapfile is the one step that has to wait for the real
	# filesystem; the post-freeze pass creates it there, on disk.
	if [ "${PF_PRECHECK:-0}" = 1 ]; then
		while IFS= read -r rec; do
			path=$(pl_field "$rec" path); size=$(pl_field "$rec" size)
			case $path in /*) ;; *) continue;; esac
			n=$((n + 1))
			say "swapfile $path ($(human "${size:-0}")): left to the post-freeze pass, it would fill the snapshot's COW"
		done < <(pl_records "$PF_DIR/donor.inv" swapfile)
		[ "$n" -gt 0 ] || say "no swapfiles on the donor"
		return 0
	fi
	while IFS= read -r rec; do
		path=$(pl_field "$rec" path); size=$(pl_field "$rec" size)
		case $path in /*) ;; *) continue;; esac
		n=$((n + 1))
		method=$(pf_method_of_path "$path")
		if [ "$method" != files ]; then say "swapfile $path came with its filesystem (${method:-?})"; continue; fi
		case $size in ''|*[!0-9]*) pf_warn "swapfile $path: size unknown, not recreated"; pf_followup "recreate the swapfile $path (or drop it from fstab)"; continue;; esac
		f=$TARGET_MNT$path
		if [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null)" = "$size" ]; then say "swapfile $path is in place ($(human "$size"))"; continue; fi
		_pf_inside "$f" || { pf_warn "swapfile $path resolves outside the target: not recreated"; continue; }
		mib=$(( (size + 1048575) / 1048576 ))
		if [ -z "$DRY" ]; then
			mkdir -p "$(dirname "$f")"
			avail=$(df -B1 --output=avail "$(dirname "$f")" 2>/dev/null | tail -1 | tr -d ' ')
			case $avail in ''|*[!0-9]*) avail=;; esac
			if [ -n "$avail" ] && [ "$avail" -lt $((size + 268435456)) ]; then
				pf_warn "swapfile $path ($(human "$size")) does not fit into $(human "$avail") free: not recreated"
				pf_followup "recreate the swapfile $path smaller, or drop it from fstab"
				continue
			fi
		fi
		# dd, not fallocate: xfs refuses to swap on preallocated extents
		if run dd if=/dev/zero "of=$f" bs=1M "count=$mib" conv=fsync && run chmod 600 "$f" && run mkswap "$f"; then
			PF_CHANGED=$((PF_CHANGED + 1))
		else
			[ -n "$DRY" ] || rm -f "$f"
			pf_warn "swapfile $path could not be recreated"
			pf_followup "recreate the swapfile $path (dd, chmod 600, mkswap) or drop it from fstab"
		fi
	done < <(pl_records "$PF_DIR/donor.inv" swapfile)
	[ "$n" -gt 0 ] || say "no swapfiles on the donor"
}
# cloud-init would regenerate the network config for the donor's NIC on first boot
pf_step_cloudinit() {
	say "--- cloud-init"
	case $(plan_get "$PF_PLAN" postfix cloudinit) in
		disable) ;;
		*) say "cloud-init: left as is"; return 0;;
	esac
	if [ ! -d "$TARGET_MNT/etc/cloud" ]; then say "cloud-init: no /etc/cloud in the target"; return 0; fi
	pf_new /etc/cloud/cloud.cfg.d/99-migrator.cfg 0644 < <(printf '%s\n' \
		'# migrator: this system was migrated; its network config is final and its hostname stays' \
		'network: {config: disabled}' \
		'preserve_hostname: true')
}
# SELinux: files copied by tar carry the donor's labels where the xattrs came along and
# none where they did not; a block copy carries them all. The plan asks for a relabel
# whenever it cannot be sure: the first boot then takes longer and reboots by itself.
pf_step_selinux() {
	say "--- selinux"
	[ "$(plan_get "$PF_PLAN" postfix selinux)" = autorelabel ] || { say "no relabel needed"; return 0; }
	if [ -e "$TARGET_MNT/.autorelabel" ]; then say "/.autorelabel is there"
	elif [ -n "$DRY" ]; then say "(dry) would create /.autorelabel"; PF_CHANGED=$((PF_CHANGED + 1))
	else : > "$TARGET_MNT/.autorelabel" || die "$EX_FAIL" "cannot create /.autorelabel in the target"; PF_CHANGED=$((PF_CHANGED + 1)); log "wrote /.autorelabel"; fi
	pf_followup "SELinux: the first boot relabels every file and reboots once by itself (two boots, some minutes without the network)"
}
# the IP moved to another MAC: announce it on link-up so the neighbours relearn it
pf_step_sysctl() {
	say "--- sysctl"
	pf_new /etc/sysctl.d/99-migrator.conf 0644 < <(printf '%s\n' \
		'# migrator: gratuitous ARP on link-up (the MAC behind this IP changed with the migration)' \
		'net.ipv4.conf.all.arp_notify = 1')
}

pf_followups() {
	local x joined=''
	if [ ${#PF_WARNS[@]} -gt 0 ]; then
		say "postfix warnings (${#PF_WARNS[@]}):"
		for x in "${PF_WARNS[@]}"; do say "  - $x"; done
	fi
	if [ ${#PF_FOLLOWUPS[@]} -gt 0 ]; then
		say "manual follow-ups after the first boot of the migrated OS (${#PF_FOLLOWUPS[@]}):"
		for x in "${PF_FOLLOWUPS[@]}"; do say "  - $x"; joined="${joined:+$joined; }$x"; done
	fi
	[ -n "$DRY" ] || state_set postfix.followups "$joined"
}

# ==============================================================================
# the phase
# ==============================================================================
# under -n without ROOT: is the plan's root really on the disk? (after a dry
# apply it is not; an OLD system on the same partition must not be mistaken for it)
pf_target_present() {
	local dev src have want row
	dev=$(target_dev_of / "$PF_PLAN")
	[ -n "$dev" ] && [ -b "$dev" ] || return 1
	have=$(blkid -c /dev/null -o value -s UUID "$dev" 2>/dev/null)
	[ -n "$have" ] || return 1
	while IFS= read -r row; do [ "$(pl_field "$row" mount)" != / ] || src=$(pl_field "$row" src); done < <(plan_section "$PF_PLAN" volumes)
	want=$(pl_lookup "$PF_DIR/donor.inv" fs dev "${src:--}" uuid 2>/dev/null)
	[ -z "$want" ] || [ "$want" = "$have" ]
}
_pf_outline() {
	local p=$PF_PLAN disk grub drv n r a pkgs
	disk=$(plan_get "$p" target disk); grub=$(plan_get "$p" postfix grub); drv=$(plan_get "$p" target driver)
	n=$(grep -c . "$PF_IDENT"); r=$(grep -c "$(printf '\t')->" "$PF_IDENT"); a=$(grep -c "$(printf '\t')remove" "$PF_IDENT")
	say "(dry) postfix would: (the target is not on the disk yet, so this is the outline from the plan)"
	say "(dry)   fstab: $n identity rules ($r rewritten, $a removed)"
	if [ "$(plan_get "$p" postfix raid)" = 1 ]; then say "(dry)   mdadm: install mdadm into the target when missing (donor mdadm=$(plan_get "$p" postfix mdadm)), mdadm.conf = the ARRAY lines of $(plan_get "$p" target md | tr ',' ' '), remove /boot/grub/device.map"
	else say "(dry)   mdadm: comment out ARRAY lines, remove /boot/grub/device.map"; fi
	say "(dry)   kernel cmdline: add '$PF_ADD'${PF_CONSOLE:+ console=$PF_CONSOLE}, drop rd.md.*"
	say "(dry)   lvm: devices file $(plan_get "$p" postfix lvm_devices_file), filter $(plan_get "$p" postfix lvm_filter)"
	say "(dry)   network: $(plan_get "$p" network donor) -> $(plan_get "$p" network target) @ $(plan_get "$p" network mac), pin=$(plan_get "$p" network pin)"
	if [ "$(plan_get "$p" postfix initramfs)" = dracut ]; then say "(dry)   initramfs: /etc/dracut.conf.d/90-migrator.conf (add_drivers ${drv//,/ }, hostonly_cmdline=no); chroot dracut --force per donor kernel ($(pl_records "$PF_DIR/donor.inv" kernel 2>/dev/null | grep -c .))"
	else say "(dry)   initramfs: /etc/initramfs-tools/modules += ${drv//,/ }; MODULES=dep -> most; chroot update-initramfs -u -k all"; fi
	[ "$(plan_get "$p" postfix raid)" != 1 ] || disk="$disk and $(plan_get "$p" postfix disk2)$([ "$(plan_get "$p" postfix esp2)" != - ] && echo " (second ESP $(plan_get "$p" postfix esp2))")"
	if [ "$(plan_get "$p" postfix family)" = rhel ]; then
		pkgs=$(pf_grub_pkgs)
		[ -z "$pkgs" ] || say "(dry)   bootloader: firmware change: chroot dnf -y --setopt=install_weak_deps=False install $pkgs (the target's own repositories; yum where there is no dnf)"
		if [ "$grub" = i386-pc ]; then say "(dry)   bootloader: chroot grub2-install --target=i386-pc ($disk), grub2-mkconfig -o /boot/grub2/grub.cfg"
		elif [ -n "$pkgs" ]; then say "(dry)   bootloader: no grub2-install on uefi (the signed shim/grub of the packages); a stub grub.cfg on the new ESP handing over to /boot/grub2/grub.cfg; chroot grub2-mkconfig -o /boot/grub2/grub.cfg; NVRAM entry with shimx64.efi"
		else say "(dry)   bootloader: no grub2-install on uefi (the signed shim/grub of the packages stay); chroot grub2-mkconfig into the real grub.cfg; NVRAM entry with shimx64.efi"; fi
		say "(dry)   kernel cmdline: also BLS entries (boot/loader/entries/*.conf) and grubenv kernelopts"
	elif [ "$(plan_get "$p" target grub_from_live)" = 1 ]; then say "(dry)   bootloader: grub-install --target=$grub on $disk from the Live, chroot update-grub"
	else say "(dry)   bootloader: chroot grub-install --target=$grub ($disk), chroot update-grub"; fi
	[ "$(plan_get "$p" postfix selinux)" != autorelabel ] || say "(dry)   selinux: /.autorelabel (the first boot relabels and reboots once)"
	say "(dry)   swapfiles: $(pl_records "$PF_DIR/donor.inv" swapfile 2>/dev/null | grep -c .) on the donor; cloud-init: $(plan_get "$p" postfix cloudinit); sysctl arp_notify"
}

postfix_run() {
	local root=${1:-} family initramfs grub
	PF_FOLLOWUPS=(); PF_WARNS=(); PF_CHANGED=0
	[ -s "$RUN/plan" ] || die "$EX_ENV" "no plan at $RUN/plan: run 'migrator -s plan DONOR' first"
	family=$(plan_get "$RUN/plan" postfix family)
	case $family in
		deb|rhel) ;;
		*)    die "$EX_PLAN" "[postfix] family='$family' in $RUN/plan: want deb or rhel" ;;
	esac
	initramfs=$(plan_get "$RUN/plan" postfix initramfs)
	case $initramfs in
		initramfs-tools|dracut) ;;
		*) die "$EX_FAIL" "[postfix] initramfs=$initramfs: neither initramfs-tools nor dracut (the disk is written; run 'rescue' and rebuild the initramfs by hand)" ;;
	esac
	grub=$(plan_get "$RUN/plan" postfix grub)
	case $grub in i386-pc|x86_64-efi) ;; *) die "$EX_PLAN" "[postfix] grub='$grub' in $RUN/plan: want i386-pc or x86_64-efi";; esac
	[ -n "$(plan_get "$RUN/plan" target disk)" ] || die "$EX_PLAN" "[target] disk= is missing in $RUN/plan"
	_pf_context

	if [ -n "$root" ]; then
		[ "$root" = / ] || root=${root%/}
		[ -d "$root/etc" ] || die "$EX_ENV" "postfix ROOT: $root is not a mounted system tree (no etc/ there)"
		[ "$(readlink -f "$root")" != / ] || die "$EX_ENV" "postfix ROOT: refusing to work on / of this box"
		TARGET_MNT=$root
		if [ -z "$DRY" ]; then
			pf_chroot_ready || die "$EX_ENV" "postfix ROOT: $root has no /proc bound, the chroot steps would fail: for m in dev proc sys run; do mount --rbind /\$m $root/\$m && mount --make-rslave $root/\$m; done (after 'mount --make-private $root'), or run 'migrator postfix' without ROOT"
			TARGET_BINDS=y
		fi
		say "postfix on the tree at $TARGET_MNT (mounted by the operator: it stays mounted)"
	elif [ -n "$DRY" ]; then
		if ! pf_target_present; then _pf_outline; return 0; fi
		if target_is_mounted; then target_umount; fi
		target_mount ro
	else
		phase_is_done transfer || die "$EX_ENV" "run transfer first (phase transfer is not done in $RUN/state)"
		if target_is_mounted; then target_umount; fi
		target_mount rw binds
		# raid=1: whatever paused the resync (apply, an interrupted transfer), it runs from here on
		if pf_raid && declare -F md_sync_resume_plan >/dev/null; then md_sync_resume_plan "$RUN/plan"; fi
	fi

	pf_step_mountpoints
	pf_step_fstab
	pf_step_mdadm
	pf_step_cmdline
	pf_step_lvm
	pf_step_network
	pf_step_initramfs
	pf_step_bootloader
	pf_step_swapfiles
	pf_step_cloudinit
	pf_step_selinux
	pf_step_sysctl
	pf_followups

	[ -n "$root" ] || target_umount
	if [ -n "$DRY" ]; then say "(dry) postfix: $PF_CHANGED file(s) would change, nothing was written"; return 0; fi
	phase_done postfix
	say "postfix done: $PF_CHANGED file(s) changed (originals under /var/lib/migrator/orig in the target), ${#PF_FOLLOWUPS[@]} manual follow-up(s)"
}

# postfix_record [ROOT]: what was done to this system travels with it. Called by
# verify once everything is green; calling it again refreshes the same record.
postfix_record() {
	local root=${1:-} was='' t dir stamp f sha old
	if [ -n "$DRY" ]; then say "(dry) would copy the plan, log and state into the target's /root/migrator-<date>/ and write /etc/migrator-migrated"; return 0; fi
	[ -s "$RUN/plan" ] || die "$EX_ENV" "no plan at $RUN/plan: nothing to record"
	if [ -n "$root" ]; then
		[ "$root" = / ] || root=${root%/}
		[ -d "$root/etc" ] || die "$EX_ENV" "postfix_record: $root is not a mounted system tree"
		TARGET_MNT=$root
	elif target_is_mounted; then
		# verify looks at the target read-only: remount our way, give it back the way it was
		if findmnt -no OPTIONS "$TARGET_MNT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then was=ro; target_umount; target_mount rw; else was=rw; fi
	else
		target_mount rw
	fi
	t=$TARGET_MNT; stamp=$t/etc/migrator-migrated
	sha=$(sha256sum "$RUN/plan" | cut -c1-64)
	# the same plan recorded before: the same directory again
	old=$(sed -n 's/^record=//p' "$stamp" 2>/dev/null | head -1)
	if [ -n "$old" ] && [ -d "$t$old" ] && [ "$(sed -n 's/^plan_sha256=//p' "$stamp" | head -1)" = "$sha" ]; then dir=$old
	else dir=/root/migrator-$(date '+%Y%m%d-%H%M%S'); fi
	mkdir -p "$t$dir" && chmod 0700 "$t$dir" || die "$EX_FAIL" "cannot create $dir in the target"
	for f in plan log state donor.inv recipient.inv; do
		[ -r "$RUN/$f" ] || continue
		cp -f "$RUN/$f" "$t$dir/$f" && chmod 0600 "$t$dir/$f" || die "$EX_FAIL" "cannot copy $RUN/$f into the target"
	done
	{
		echo "date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "donor_serial=$(pl_field "$(pl_records "$RUN/donor.inv" host 2>/dev/null | head -1)" dmi_serial)"
		echo "recipient_serial=$(pl_field "$(pl_records "$RUN/recipient.inv" host 2>/dev/null | head -1)" dmi_serial)"
		echo "plan_sha256=$sha"
		echo "donor_machine_id=$(pl_field "$(pl_records "$RUN/donor.inv" os 2>/dev/null | head -1)" machine_id)"
		echo "migrator_version=$(migrator_version)"
		echo "record=$dir"
	} > "$stamp" || die "$EX_FAIL" "cannot write $stamp"
	chmod 0644 "$stamp"
	say "recorded: $dir/ and /etc/migrator-migrated in the target"
	case $was in
		'') [ -n "$root" ] || target_umount ;;
		ro) target_umount; target_mount ro ;;
	esac
	return 0
}
