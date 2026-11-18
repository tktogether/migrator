#!/bin/bash
# lib/apply.sh — the DESTRUCTIVE phase on the recipient: wipe the target disk,
# partition it from the plan's [sfdisk], set every other disk read-only, build
# the LVM of [lvm], run the [mkfs] lines and prove that each new filesystem
# carries exactly the donor's raw feature masks — all before a single byte of
# the donor is copied. Nothing here talks to the donor. Needs common.sh,
# plan.sh (plan_get/plan_section/plan_sfdisk/pl_*) and inventory.sh
# (parse_dumpe2fs/parse_xfs_db), sourced before this file by the driver.
#
#   apply_run                 driver entry over $RUN/plan + $RUN/recipient.inv; the steps
#                             below in order, every device command echoed ("+ ", or
#                             "(dry) " under -n) and logged: plan_check -> pre-apply
#                             fingerprint gate -> the typed confirmation -> deactivate
#                             (swapoff, vgchange -an, mdadm --stop, dmsetup remove;
#                             anything mounted from the disk is refused) -> old
#                             signatures (zero-superblock + wipefs per partition, wipefs +
#                             sgdisk --zap-all on the disk) -> blockdev --setro on every
#                             other disk -> sfdisk --wipe always -> partprobe + settle +
#                             wait for the nodes (and by-partuuid on gpt) -> stop what udev
#                             re-assembled -> post-apply fingerprint into state ->
#                             pmbr_boot -> [md] (raid=1: mdadm --create per slot, the
#                             resync frozen until transfer is done) -> [lvm] + vgchange -ay
#                             -> [mkfs] with the mask guard after each mkfs.ext*/mkfs.xfs
#                             -> volumes pending, phase.apply=done.
#                             raid=1 ([target] disk2=): every disk step runs on both disks
#                             ([sfdisk] on disk, [sfdisk2] on disk2), the gate shows both,
#                             the fingerprint covers both (state target.*2)
#   cleanup_all               "reloca.to -s cleanup" and the crash path: registered cleanup
#                             snippets, umount under /mnt/reloca.to (and /mnt/localboot),
#                             vgchange -an the plan's VGs, setrw the disks apply marked
#                             (state setro.disks), the donor's data sshd and mounts through
#                             the master, ssh_disconnect, the lock; idempotent, never dies
#   apply_fingerprint_check   state target.{disk,id,size,ptuuid,parts} vs the disk now;
#                             die 2 on any difference (transfer calls it before every volume,
#                             apply before every lvm/mkfs line); silent no-op under -n
#   apply_fingerprint_verify  the same, status 1 + the differences on stdout, never dies
#   apply_target_disk [PLAN]  the disk of the plan          apply_partnode DISK N -> node
#   apply_wait_nodes NODE...  wait up to APPLY_NODE_TIMEOUT s for device nodes (die 1)
#   apply_setro_others [DISK [INV]]   every non-target disk read-only (+ cleanup_add setrw,
#                             state setro.disks); transfer/postfix may call it again
#   apply_disk_blank DISK     0 when nothing is on DISK (inventory usage=free, no partition,
#                             no signature): the gate then asks a plain y/N instead of the
#                             typed "<name> <GiB>" (a blank disk cannot be the wrong one)
#   md_stop_retry DEV         udevadm settle + mdadm --stop, up to APPLY_MD_RETRIES tries
#   md_sync_set DEV ACTION    frozen|idle into /sys/block/<md>/md/sync_action
#   md_sync_resume_plan [PLAN]  idle for every [md] array (transfer's end, cleanup)
#   md_assemble_plan [PLAN]   assemble the plan's arrays by UUID when they are not running
#                             (target_mount after a reboot of the Live or a cleanup)
#   masks_of_fs DEV [TYPE]    canonical feature masks of the filesystem on DEV
#   masks_from_dumpe2fs / masks_from_xfs_db     the same from the tool's output on stdin
#   masks_norm TYPE RAW [NAMES]   inventory/plan masks= -> canonical:
#                             ext|features=<sorted csv>|journal=-   (journal flags are kernel-set, ignored)
#                             xfs|versionnum=N|features2=N|compat=N|ro_compat=N|incompat=N|log_incompat=N|features=<sorted csv|?>
#                             (versionnum without ATTRBIT/QUOTABIT, names without ATTR/QUOTA: kernel-set, ignored)
#   masks_equal A B           0 when every field agrees (sets, not lists; "?" = unknown, matches)
#   masks_diff A B            one line per differing field, donor first
#
# Dry run (-n): the same lines with "(dry)"; reads of the target (blockdev, lsblk,
# dd of the first MiB) still happen when the disk is present, nothing is written,
# no state, no phase marker and no cleanup action is left behind (a dry run must
# leave nothing a real run would trust); $RUN/sfdisk.script is written (it is the
# plan's [sfdisk] verbatim). A plan naming a disk this host does not have is
# walked with a warning under -n and refused (exit 2) otherwise.

# shellcheck disable=SC2119,SC2120  # apply_target_disk/apply_setro_others take optional arguments other libs pass
APPLY_NODE_TIMEOUT=${APPLY_NODE_TIMEOUT:-30}   # seconds to wait for partition/LV nodes
APPLY_MD_RETRIES=${APPLY_MD_RETRIES:-5}        # mdadm --stop attempts (udev holds members for a while)
APPLY_MNT=/mnt/reloca.to
APPLY_SFDISK=/usr/sbin/sfdisk                  # absolute on purpose: the image carries two sfdisk binaries
AP_PLAN=${AP_PLAN:-}                           # the plan apply_run works on ($RUN/plan)
AP_TREE=                                       # lsblk's view of the target disk at the start of apply_run
AP_DISK2=                                      # raid=1: the second disk ([target] disk2=), else empty
AP_TREE2=                                      # lsblk's view of it

# --- small pure helpers ------------------------------------------------------------
ap_trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s\n' "$v"; }
ap_dec()  { local s=$1; s=${s//%20/ }; s=${s//%2C/,}; printf '%s\n' "$s"; }     # the plan's %20/%2C encoding
ap_gib()  { echo $(( $1 / 1073741824 )); }
# a partition-table id as lsblk prints it: dos "0badcafe" (no 0x), gpt lowercase; "-" = none
ap_ptuuid_norm() { local v=${1,,}; v=${v#0x}; [ "$v" = - ] && v=; printf '%s\n' "$v"; }
# ap_kv LINE KEY: the value of KEY="..." in an lsblk -P line
ap_kv() { local re="(^|[[:space:]])$2=\"([^\"]*)\""; [[ $1 =~ $re ]] && printf '%s\n' "${BASH_REMATCH[2]}"; return 0; }
# ap_set LIST: a space/comma list as a sorted, deduplicated csv ("-" when empty)
ap_set() { local s; s=$(printf '%s' "$1" | tr ' ,' '\n' | grep -v '^$' | LC_ALL=C sort -u | paste -sd, -); printf '%s\n' "${s:--}"; }
# ap_disk_rec DISK INV: the inventory's disk record of DISK
ap_disk_rec() { pl_records "$2" disk | awk -F'\t' -v d="dev=$1" '{ for (i = 2; i <= NF; i++) if ($i == d) { print; exit } }'; }
# ap_inv_id RECORD: wwn:… | serial:… | model:… — the rule plan.sh applies (R1)
ap_inv_id() {
	local v
	v=$(pl_field "$1" wwn); if [ -n "$v" ] && [ "$v" != - ]; then echo "wwn:$v"; return 0; fi
	v=$(pl_field "$1" serial); if [ -n "$v" ] && [ "$v" != - ]; then echo "serial:$v"; return 0; fi
	v=$(pl_field "$1" model); echo "model:${v:--}"
}

apply_target_disk() { plan_get "${1:-$RUN/plan}" target disk; }
# apply_partnode DISK N: the node name the way the kernel/lsblk builds it (sda3, nvme0n1p3, mmcblk0p1)
apply_partnode() { case $1 in *[0-9]) echo "$1p$2";; *) echo "$1$2";; esac; }
# the one place that decides whether the target is here (tests override it)
apply_disk_present() { [ -b "$1" ]; }

# --- reading the disk (read-only; allowed under -n) ------------------------------------
apply_read_id() {   # DISK -> wwn:… | serial:… | model:…, the same rule as the inventory + plan.sh
	local v
	v=$(ap_trim "$(lsblk -dno WWN "$1" 2>/dev/null)");    if [ -n "$v" ] && [ "$v" != - ]; then echo "wwn:$v"; return 0; fi
	v=$(ap_trim "$(lsblk -dno SERIAL "$1" 2>/dev/null)"); if [ -n "$v" ] && [ "$v" != - ]; then echo "serial:$v"; return 0; fi
	v=$(ap_trim "$(lsblk -dno MODEL "$1" 2>/dev/null)");  echo "model:${v:--}"
}
apply_read_size()   { blockdev --getsize64 "$1" 2>/dev/null; }
apply_read_lsec()   { blockdev --getss "$1" 2>/dev/null; }
apply_read_psec()   { blockdev --getpbsz "$1" 2>/dev/null; }
apply_read_ptuuid() { ap_ptuuid_norm "$(ap_trim "$(lsblk -dno PTUUID "$1" 2>/dev/null)")"; }
apply_read_head()   { dd if="$1" bs=1M count=1 status=none 2>/dev/null | sha256sum | cut -c1-64; }
# apply_read_tree DISK: one lsblk -P line per device on the disk (the disk itself first):
# PATH="…" TYPE="disk|part|raid1|lvm|crypt|…" PARTUUID="…" MOUNTPOINT="…|[SWAP]"
apply_read_tree()   { lsblk -nP -o PATH,TYPE,PARTUUID,MOUNTPOINT "$1" 2>/dev/null; }
# apply_read_parts DISK: "<node>:<partuuid>,…" of the partitions, sorted (the post-apply fingerprint)
apply_read_parts() {
	apply_read_tree "$1" | sed -n 's/^PATH="\([^"]*\)" TYPE="part" PARTUUID="\([^"]*\)".*/\1:\2/p' | sort | paste -sd, -
}
# apply_read_sigs DISK: how many signatures wipefs sees on the whole disk (0 = none)
apply_read_sigs() { wipefs -n "$1" 2>/dev/null | awk 'NR > 1 && $3 != "" { n++ } END { print n + 0 }'; }
# apply_disk_blank DISK: the inventory saw nothing on it AND (when the disk is here) lsblk shows
# no partition and wipefs no signature; absent under -n, the inventory alone decides
apply_disk_blank() {
	local disk=$1 r tree
	r=$(ap_disk_rec "$disk" "$RUN/recipient.inv"); [ "$(pl_field "$r" usage)" = free ] || return 1
	apply_disk_present "$disk" || { [ -n "$DRY" ] && return 0; return 1; }
	tree=$(apply_read_tree "$disk")
	[ "$(grep -c 'TYPE="part"' <<< "$tree")" -eq 0 ] || return 1
	[ "$(apply_read_sigs "$disk")" -eq 0 ]
}

# --- what the inventory says lives on the target -----------------------------------------
# apply_target_map DISK INV: AP_PARTS (devices), AP_MDS (arrays with a member on the disk),
# AP_VGS (VGs with a PV on any of those), AP_LVS (their LVs), AP_SWAPS (swap devices among
# them), AP_OTHERS ("dev:ro" of every other disk), AP_ON[dev]=1 for all of the above.
# raid=1: AP_DISK2 (the plan's disk2) counts as a target disk too.
apply_target_map() {
	local disk=$1 inv=$2 r dev vg x
	local -a m; local -A vgs=()
	AP_PARTS=(); AP_MDS=(); AP_VGS=(); AP_LVS=(); AP_SWAPS=(); AP_OTHERS=()
	declare -gA AP_ON; AP_ON=()
	AP_ON[$disk]=1; [ -z "$AP_DISK2" ] || AP_ON[$AP_DISK2]=1
	while read -r r; do
		dev=$(pl_field "$r" dev)
		if [ -n "${AP_ON[$(pl_field "$r" disk)]:-}" ]; then AP_PARTS+=("$dev"); AP_ON[$dev]=1; fi
	done < <(pl_records "$inv" part)
	while read -r r; do
		dev=$(pl_field "$r" dev); IFS=, read -ra m <<< "$(pl_field "$r" members)"
		for x in "${m[@]}"; do
			if [ -n "${AP_ON[$x]:-}" ]; then AP_MDS+=("$dev"); AP_ON[$dev]=1; break; fi
		done
	done < <(pl_records "$inv" md)
	while read -r r; do
		dev=$(pl_field "$r" dev); [ -n "${AP_ON[$dev]:-}" ] || continue
		vg=$(pl_field "$r" vg)
		if [ -z "${vgs[$vg]:-}" ]; then vgs[$vg]=1; AP_VGS+=("$vg"); fi
	done < <(pl_records "$inv" pv)
	while read -r r; do
		vg=$(pl_field "$r" vg); [ -n "${vgs[$vg]:-}" ] || continue
		dev=$(pl_field "$r" path); AP_LVS+=("$dev"); AP_ON[$dev]=1
	done < <(pl_records "$inv" lv)
	while read -r r; do
		dev=$(pl_field "$r" dev)
		if [ -n "${AP_ON[$dev]:-}" ]; then AP_SWAPS+=("$dev"); fi
	done < <(pl_records "$inv" swap)
	while read -r r; do
		dev=$(pl_field "$r" dev)
		if [ "$dev" != "$disk" ] && [ "$dev" != "$AP_DISK2" ]; then AP_OTHERS+=("$dev:$(pl_field "$r" ro)"); fi
	done < <(pl_records "$inv" disk)
}

# --- waiting, stopping -----------------------------------------------------------------------
apply_wait_nodes() {   # NODE...: until every node exists, up to APPLY_NODE_TIMEOUT s; die 1 naming the missing
	local n i missing=()
	[ $# -gt 0 ] || return 0
	if [ -n "$DRY" ]; then echo "(dry) would wait up to ${APPLY_NODE_TIMEOUT}s for: $*"; return 0; fi
	for ((i = 0; i <= APPLY_NODE_TIMEOUT; i++)); do
		missing=(); for n in "$@"; do [ -e "$n" ] || missing+=("$n"); done
		if [ ${#missing[@]} -eq 0 ]; then say "device nodes present: $*"; return 0; fi
		[ "$i" -lt "$APPLY_NODE_TIMEOUT" ] && sleep 1
	done
	die "$EX_FAIL" "device nodes did not appear within ${APPLY_NODE_TIMEOUT}s: ${missing[*]}"
}
# md_stop_retry DEV: udev re-opens the members for a while after any change, so
# settle first and try up to APPLY_MD_RETRIES times (the stand's rule); 1 when it stays
md_stop_retry() {
	local dev=$1 i
	for ((i = 1; i <= APPLY_MD_RETRIES; i++)); do
		run udevadm settle || true
		run mdadm --stop "$dev" && return 0
		[ -n "$DRY" ] && return 0
		grep -q "^${dev#/dev/} " /proc/mdstat 2>/dev/null || return 0   # gone between the check and the stop
		sleep 1
	done
	return 1
}
# apply_md_on_disk DISK [MDSTAT]: arrays in /proc/mdstat with a member on DISK (members read "vda1[0]")
apply_md_on_disk() {
	local base=${1#/dev/}
	awk -v b="$base" '$2 == ":" { for (i = 4; i <= NF; i++) { m = $i; sub(/\[.*/, "", m)
		if (m == b || m ~ ("^" b "p?[0-9]+$")) { print "/dev/" $1; break } } }' "${2:-/proc/mdstat}" 2>/dev/null
}
# --- raid=1: the plan's arrays ------------------------------------------------------------------
apply_md_devs() { plan_get "${1:-$AP_PLAN}" target md | tr ',' '\n' | grep -v '^-$' | grep .; return 0; }   # PLAN -> /dev/mdN per line
md_is_running() { grep -q "^${1#/dev/} " /proc/mdstat 2>/dev/null; }
md_sync_set() {   # DEV frozen|idle: pause or resume the initial resync (writes are mirrored either way)
	local f=/sys/block/${1#/dev/}/md/sync_action
	if [ -n "$DRY" ]; then echo "(dry) echo $2 > $f"; log "(dry) echo $2 > $f"; return 0; fi
	[ -w "$f" ] || { warn "cannot set sync_action of $1 ($f): the resync runs at its own pace"; return 0; }
	run_sh "echo $2 > $f" || warn "sync_action $2 for $1 failed ($?)"
}
md_sync_resume_plan() {   # [PLAN]: idle for every array of the plan that is running
	local plan=${1:-$RUN/plan} md
	[ -r "$plan" ] || return 0
	for md in $(apply_md_devs "$plan"); do md_is_running "$md" && md_sync_set "$md" idle; done
	return 0
}
md_assemble_plan() {   # [PLAN]: assemble the plan's arrays by UUID when they are not running
	local plan=${1:-$RUN/plan} md uuid
	[ -r "$plan" ] || return 0
	while IFS= read -r line; do
		md=$(awk '{ print $3 }' <<< "$line"); uuid=$(sed -n 's/.*--uuid=\([^ ]*\).*/\1/p' <<< "$line")
		if [ -z "$md" ] || [ -z "$uuid" ] || md_is_running "$md"; then continue; fi
		[ -n "$DRY" ] && { echo "(dry) mdadm --assemble $md --uuid=$uuid"; continue; }
		run mdadm --assemble "$md" --uuid="$uuid" || warn "mdadm --assemble $md --uuid=$uuid failed ($?)"
	done < <(plan_section "$plan" md | grep '^mdadm --create ')
	run udevadm settle 2>/dev/null || true
	return 0
}
# apply_md_create: one mdadm --create per [md] line, the node awaited, the array's size
# checked against the plan (an array smaller than its [volumes] tsize would break the
# copy), then the initial resync is frozen: it would compete with partclone for the same
# two disks, and every block the copy writes is mirrored anyway. transfer resumes it.
apply_md_create() {
	local line md want have nodes=()
	[ -n "$(plan_section "$AP_PLAN" md)" ] || { say "no [md] in the plan"; return 0; }
	while IFS= read -r line; do
		apply_fingerprint_check
		must_sh "$line"
		nodes+=("$(awk '{ print $3 }' <<< "$line")")
	done < <(plan_section "$AP_PLAN" md | grep '^mdadm --create ')
	run udevadm settle || true
	apply_wait_nodes "${nodes[@]}"
	for md in "${nodes[@]}"; do
		want=$(plan_section "$AP_PLAN" volumes | awk -F'\t' -v t="target=$md" '{ for (i = 1; i <= NF; i++) if ($i == t) { for (j = 1; j <= NF; j++) if (index($j, "tsize=") == 1) print substr($j, 7); exit } }')
		if [ -n "$DRY" ]; then echo "(dry) would check that $md is at least $want bytes"; else
			have=$(apply_read_size "$md")
			if [ -z "$want" ] || [ -z "$have" ] || [ "$have" -lt "$want" ]; then
				die "$EX_FAIL" "$md is ${have:-?} bytes, the plan needs ${want:-?} (mdadm reserved more than --data-offset=8M?): re-run 'reloca.to -s plan DONOR'"
			fi
			say "$md: $(human "$have") as planned"
		fi
		md_sync_set "$md" frozen
	done
	[ -n "$DRY" ] || state_set md.frozen 1
	say "md: ${#nodes[@]} array(s) created, the initial resync is paused until the transfer is done"
}

# --- feature masks (the "never format with defaults" guard) -----------------------------------
# masks_norm TYPE RAW [NAMES]: the inventory/plan masks= string -> the canonical form.
# ext: "features:a b c|journal:x y" — sets, so order never matters; needs_recovery and
# orphan_present are state flags, not format features, and are dropped. xfs:
# "versionnum=0x…,features2=…,compat=…,ro_compat=…,incompat=…,log_incompat=…" — numeric,
# plus the feature-name set (xfs_db's version line) when known, "?" otherwise.
masks_norm() {
	local type=$1 raw=$2 names=${3-'?'} f j k v kv vn='?' f2='?' c='?' ro='?' inc='?' li='?'
	case $type in
		ext*)
			f=${raw#features:}; f=${f%%|*}
			if [ "$raw" != "${raw#*|journal:}" ]; then j=${raw#*|journal:}; else j=; fi
			f=$(printf '%s' "$f" | tr ' ,' '\n' | grep -vx -e needs_recovery -e orphan_present | paste -sd, -)
			# journal features (journal_64bit, journal_checksum_v3, journal_incompat_revoke)
			# are NOT written by mke2fs: jbd2 sets them on the first mount from the fs
			# features, so a fresh mkfs shows "(none)" and can never match a used donor
			# (stand phase B, smaller variant). They carry no compatibility information
			# of their own and are left out of the comparison.
			: "$j"
			echo "ext|features=$(ap_set "$f")|journal=-";;
		xfs)
			IFS=, read -ra kv <<< "$raw"
			for k in "${kv[@]}"; do
				v=${k#*=}
				if [[ $v =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then v=$(( v )); else v='?'; fi
				case ${k%%=*} in versionnum) vn=$v;; features2) f2=$v;; compat|features_compat) c=$v;; ro_compat|features_ro_compat) ro=$v;;
					incompat|features_incompat) inc=$v;; log_incompat|features_log_incompat) li=$v;; esac
			done
			# versionnum bits the KERNEL sets on a mounted fs, never mkfs.xfs: ATTRBIT
			# (0x10) on the first extended attribute, QUOTABIT (0x40) when quota is
			# turned on. A used donor carries them, a fresh target cannot (stand phase
			# B, xfs root by the files method: "versionnum: donor 0xb4b5, target
			# 0xb4a5"); like ext's journal flags they say nothing about the format
			[ "$vn" = '?' ] || vn=$(( vn & ~0x50 ))
			if [ "$names" = "?" ] || [ -z "$names" ] || [ "$names" = - ]; then names='?'
			else names=$(ap_set "$(printf '%s' "$names" | tr ' ,' '\n' | grep -vx -e ATTR -e QUOTA | paste -sd, -)"); fi
			echo "xfs|versionnum=$vn|features2=$f2|compat=$c|ro_compat=$ro|incompat=$inc|log_incompat=$li|features=$names";;
		*) return 1;;
	esac
}
masks_from_dumpe2fs() {   # dumpe2fs -h on stdin -> canonical
	local kv; kv=$(parse_dumpe2fs); [ -n "$kv" ] || return 1
	masks_norm ext "$(pl_field "$kv" masks)"
}
masks_from_xfs_db() {     # xfs_db -r -c version -c 'sb 0' -c 'p …' on stdin -> canonical
	local kv; kv=$(parse_xfs_db); [ -n "$kv" ] || return 1
	masks_norm xfs "$(pl_field "$kv" masks)" "$(pl_field "$kv" features)"
}
masks_of_fs() {           # DEV [TYPE] -> canonical masks of the filesystem on DEV (1 when unreadable)
	local dev=$1 type=${2:-}
	[ -n "$type" ] || type=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
	case $type in
		ext*) dumpe2fs -h "$dev" 2>/dev/null | masks_from_dumpe2fs;;
		xfs)  xfs_db -r -c version -c 'sb 0' -c 'p blocksize sectsize inodesize dirblklog dblocks fdblocks icount ifree versionnum features2 features_compat features_ro_compat features_incompat features_log_incompat' "$dev" 2>/dev/null | masks_from_xfs_db;;
		*) return 1;;
	esac
}
masks_equal() {           # A B (canonical): 0 when every field agrees; "?" on either side matches anything
	local -a a b; local i va vb
	IFS='|' read -ra a <<< "$1"; IFS='|' read -ra b <<< "$2"
	[ "${a[0]}" = "${b[0]}" ] && [ ${#a[@]} -eq ${#b[@]} ] || return 1
	for ((i = 1; i < ${#a[@]}; i++)); do
		[ "${a[$i]%%=*}" = "${b[$i]%%=*}" ] || return 1
		va=${a[$i]#*=}; vb=${b[$i]#*=}
		if [ "$va" = "?" ] || [ "$vb" = "?" ]; then continue; fi
		[ "$va" = "$vb" ] || return 1
	done
	return 0
}
masks_diff() {            # A B (canonical) -> one line per differing field, donor (A) first
	local -a a b; local i k va vb oa ob
	IFS='|' read -ra a <<< "$1"; IFS='|' read -ra b <<< "$2"
	if [ "${a[0]}" != "${b[0]}" ]; then echo "type: donor ${a[0]}, target ${b[0]}"; return 0; fi
	for ((i = 1; i < ${#a[@]}; i++)); do
		k=${a[$i]%%=*}; va=${a[$i]#*=}; vb=${b[$i]#*=}
		[ "$va" != "$vb" ] || continue
		if [ "$va" = "?" ] || [ "$vb" = "?" ]; then continue; fi
		case $k in
			features)
				oa=$(LC_ALL=C comm -23 <(tr ',' '\n' <<< "$va" | grep -vx -- - | LC_ALL=C sort) <(tr ',' '\n' <<< "$vb" | grep -vx -- - | LC_ALL=C sort) | paste -sd, -)
				ob=$(LC_ALL=C comm -13 <(tr ',' '\n' <<< "$va" | grep -vx -- - | LC_ALL=C sort) <(tr ',' '\n' <<< "$vb" | grep -vx -- - | LC_ALL=C sort) | paste -sd, -)
				echo "$k: donor-only ${oa:-none}, target-only ${ob:-none}";;
			*) printf '%s: donor 0x%x, target 0x%x\n' "$k" "$va" "$vb";;
		esac
	done
}
# ap_verify_entry DEV: "<fstype>:<masks>" of DEV from the plan's [verify] features=
ap_verify_entry() {
	plan_get "$AP_PLAN" verify features | tr ',' '\n' | awk -v d="$1:" 'index($0, d) == 1 { print substr($0, length(d) + 1); exit }'
}
# apply_masks_guard DEV TYPE: the fresh filesystem on DEV vs the donor's masks; die 4 on any difference
apply_masks_guard() {
	local dev=$1 type=$2 entry fstype raw names='?' donor mine src
	entry=$(ap_verify_entry "$dev")
	[ -n "$entry" ] || { warn "no donor masks for $dev in [verify] features=: the feature guard cannot run"; return 0; }
	fstype=${entry%%:*}; raw=$(ap_dec "${entry#*:}")
	# xfs: the plan holds the numeric masks; the donor's feature-name set is in its inventory
	if [ "$type" = xfs ] && [ -r "$RUN/donor.inv" ]; then
		src=$(plan_section "$AP_PLAN" volumes | awk -F'\t' -v t="target=$dev" '{ for (i = 1; i <= NF; i++) if ($i == t) { print substr($1, 5); exit } }')
		[ -z "$src" ] || names=$(pl_lookup "$RUN/donor.inv" fs dev "$src" features)
	fi
	donor=$(masks_norm "$type" "$raw" "$names")
	if [ -n "$DRY" ]; then echo "(dry) would compare masks of $dev with the donor's ($fstype): $donor"; return 0; fi
	mine=$(masks_of_fs "$dev" "$type") || die "$EX_FAIL" "cannot read the feature masks of the new $fstype on $dev"
	if masks_equal "$donor" "$mine"; then say "$dev: $fstype feature masks match the donor's"
	else die "$EX_PLAN" "$dev: $fstype feature masks differ from the donor's (nothing transferred): $(masks_diff "$donor" "$mine" | paste -sd';' -)"; fi
}

# --- the fingerprint (state target.*) ----------------------------------------------------------
apply_fingerprint_record() {   # DISK ID [SFX]: what apply left on the disk, checked before every later write (SFX=2: disk2)
	local disk=$1 id=$2 x=${3:-} size ptuuid parts
	if [ -n "$DRY" ]; then echo "(dry) would record the post-apply fingerprint of $disk (id, size, ptuuid, partuuids) in $RUN/state"; return 0; fi
	size=$(apply_read_size "$disk"); ptuuid=$(apply_read_ptuuid "$disk"); parts=$(apply_read_parts "$disk")
	state_set "target.disk$x" "$disk"; state_set "target.id$x" "$id"; state_set "target.size$x" "$size"
	state_set "target.ptuuid$x" "$ptuuid"; state_set "target.parts$x" "$parts"
	say "fingerprint recorded: $disk $id size=$size ptuuid=${ptuuid:--} parts=${parts:--}"
}
_ap_fp_verify_one() {   # SFX: the differences of disk<SFX> on stdout, status 1 when any
	local x=$1 disk id v bad=()
	disk=$(state_get "target.disk$x"); id=$(state_get "target.id$x")
	v=$(apply_read_id "$disk");     [ "$v" = "$id" ]                             || bad+=("$disk id: recorded $id, now $v")
	v=$(apply_read_size "$disk");   [ "$v" = "$(state_get "target.size$x")" ]    || bad+=("$disk size: recorded $(state_get "target.size$x"), now ${v:-?}")
	v=$(apply_read_ptuuid "$disk"); [ "$v" = "$(state_get "target.ptuuid$x")" ]  || bad+=("$disk ptuuid: recorded $(state_get "target.ptuuid$x"), now ${v:--}")
	v=$(apply_read_parts "$disk");  [ "$v" = "$(state_get "target.parts$x")" ]   || bad+=("$disk partitions: recorded $(state_get "target.parts$x"), now ${v:--}")
	[ ${#bad[@]} -eq 0 ] && return 0
	printf '%s\n' "${bad[*]}"; return 1
}
apply_fingerprint_verify() {   # -> 0 when the disk(s) match state target.*; 1 + the differences on stdout
	local out rc=0 why
	[ -n "$(state_get target.disk)" ] || { echo "no post-apply fingerprint in $RUN/state (apply has not run)"; return 1; }
	why=$(_ap_fp_verify_one "") || { rc=1; out=$why; }
	if [ -n "$(state_get target.disk2)" ]; then why=$(_ap_fp_verify_one 2) || { rc=1; out="${out:+$out; }$why"; }; fi
	[ "$rc" -eq 0 ] || printf '%s\n' "$out"
	return $rc
}
apply_fingerprint_check() {
	[ -z "$DRY" ] || return 0
	local why; why=$(apply_fingerprint_verify) && return 0
	die "$EX_ENV" "target disk $(state_get target.disk) changed since apply: $why"
}

# --- the steps of apply_run ---------------------------------------------------------------------
# apply_pregate DISK: [target] vs the inventory record the plan came from and vs the disk now.
# Identity (id, size, sector sizes) is never overridable; ptuuid/first-MiB may differ
# only when the disk carries what an earlier apply wrote (redo), or with force=1 (warn).
apply_pregate() {   # DISK [SFX]
	local disk=$1 x=${2:-} inv=$RUN/recipient.inv r pid size lsec psec ptuuid head v ident=() bad=()
	pid=$(ap_dec "$(plan_get "$AP_PLAN" target "id$x")"); size=$(plan_get "$AP_PLAN" target "size$x")
	lsec=$(plan_get "$AP_PLAN" target lsec); psec=$(plan_get "$AP_PLAN" target psec)
	ptuuid=$(ap_ptuuid_norm "$(plan_get "$AP_PLAN" target "ptuuid$x")"); head=$(plan_get "$AP_PLAN" target "head$x")
	r=$(ap_disk_rec "$disk" "$inv")
	[ -n "$r" ] || die "$EX_ENV" "$disk is not a disk of the recipient inventory $inv"
	v=$(ap_inv_id "$r");         [ "$v" = "$pid" ]  || ident+=("id: plan $pid, inventory $v")
	v=$(pl_field "$r" size);     [ "$v" = "$size" ] || ident+=("size: plan $size, inventory $v")
	if apply_disk_present "$disk"; then
		v=$(apply_read_id "$disk");     [ "$v" = "$pid" ]  || ident+=("id: plan $pid, disk now $v")
		v=$(apply_read_size "$disk");   [ "$v" = "$size" ] || ident+=("size: plan $size, disk now ${v:-?}")
		v=$(apply_read_lsec "$disk");   [ "$v" = "$lsec" ] || ident+=("logical sector: plan $lsec, disk now ${v:-?}")
		v=$(apply_read_psec "$disk");   [ "$v" = "$psec" ] || ident+=("physical sector: plan $psec, disk now ${v:-?}")
		v=$(apply_read_ptuuid "$disk"); [ "$v" = "$ptuuid" ] || bad+=("ptuuid: plan ${ptuuid:--}, now ${v:--}")
		if [ "$head" != - ] && [ -n "$head" ]; then
			v=$(apply_read_head "$disk"); [ "sha256:$v" = "$head" ] || bad+=("first MiB: plan $head, now sha256:$v")
		fi
	elif [ -n "$DRY" ]; then
		warn "$disk not present, fingerprint not checked (dry run)"
	else
		die "$EX_ENV" "target disk $disk is not a block device on this box"
	fi
	[ ${#ident[@]} -eq 0 ] || die "$EX_ENV" "target disk changed since the plan: ${ident[*]}"
	if [ ${#bad[@]} -gt 0 ]; then
		if [ "$(state_get "target.disk$x")" = "$disk" ] && [ "$(state_get "target.ptuuid$x")" = "$(apply_read_ptuuid "$disk")" ] && [ "$(state_get "target.parts$x")" = "$(apply_read_parts "$disk")" ]; then
			say "$disk carries the partition table an earlier apply wrote (${bad[*]}): redoing"
		elif [ "$(opt force 0)" = 1 ]; then
			warn "target disk changed since the plan (force=1): ${bad[*]}"
		else
			die "$EX_ENV" "target disk changed since the plan: ${bad[*]} (re-run 'reloca.to -s plan DONOR', or force=1)"
		fi
	fi
	say "fingerprint: $disk is $pid, $size bytes, $lsec/$psec sectors, as planned"
}
# apply_gate DISK [DISK2]: the loud block and the confirmation. A disk that carries
# something takes the typed "<name> <GiB>" ("sda 894", "sda+sdb 894" for a mirror), read
# off the screen, so a reflex "y" cannot pick the wrong disk; blank disks (nothing on
# them in the inventory, no partition, no signature) take a plain y/N: there is nothing
# to lose and nothing to confuse them with.
_ap_gate_disk() {   # DISK LABEL SFX
	local disk=$1 r size
	r=$(ap_disk_rec "$disk" "$RUN/recipient.inv"); size=$(pl_field "$r" size)
	say "TARGET DISK$3 $disk  $(human "$size") ($size bytes = $(ap_gib "$size") GiB)  sectors $(pl_field "$r" lsec)/$(pl_field "$r" psec)"
	say "             model=$(pl_field "$r" model) serial=$(pl_field "$r" serial) wwn=$(pl_field "$r" wwn) tran=$(pl_field "$r" tran) driver=$(pl_field "$r" drivers)"
	say "NOW ON IT    $(ap_dec "$(plan_get "$AP_PLAN" target "currently$3")")   <-- WILL BE WIPED"
}
apply_gate() {
	local disk=$1 disk2=${2:-} label names gib blank=1 d r size sizes='' what
	label=$(plan_get "$AP_PLAN" target label)
	say "=================================================================================="
	_ap_gate_disk "$disk" "$label" ""
	[ -z "$disk2" ] || { say "----------------------------------------------------------------------------------"; _ap_gate_disk "$disk2" "$label" 2; }
	say "PLAN         label=$label, $(plan_sfdisk "$AP_PLAN" | wc -l) partitions$([ -z "$disk2" ] || echo " on each disk, $(plan_md "$AP_PLAN" | wc -l) md RAID1 arrays"), $(plan_section "$AP_PLAN" lvm | wc -l) lvm commands, $(plan_section "$AP_PLAN" mkfs | wc -l) mkfs lines"
	say "=================================================================================="
	names=$(basename "$disk"); [ -z "$disk2" ] || names="$names+$(basename "$disk2")"
	for d in $disk $disk2; do
		apply_disk_blank "$d" || blank=0
		r=$(ap_disk_rec "$d" "$RUN/recipient.inv"); size=$(pl_field "$r" size)
		case "+$sizes+" in *"+$(ap_gib "$size")+"*) ;; *) sizes="${sizes:+$sizes+}$(ap_gib "$size")";; esac
	done
	gib=$sizes
	what=$disk; [ -z "$disk2" ] || what="$disk and $disk2"
	if [ "$blank" = 1 ]; then
		if [ -n "$DRY" ]; then say "(dry) $what: blank (nothing to lose); the gate would ask a plain y/N here; prompt skipped"
		else say "$what: blank (nothing on it in the inventory, no partition, no signature)"; confirm "Partition $what now?"; fi
	else
		if [ -n "$DRY" ]; then say "(dry) the gate would require typing '$names $gib' here; prompt skipped"
		else confirm "Wipe $what and everything on it?" "$names $gib"; fi
	fi
}
# apply_deactivate DISK: nothing of the old contents may be live when the wipe starts.
# Anything mounted from the disk is the operator's, not ours to unmount: refused.
# Order: swapoff (swap on an LV blocks vgchange -an), vgchange -an, mdadm --stop, then
# whatever device-mapper leftovers lsblk still shows (crypt, multipath, a VG the
# inventory did not know); under -n only crypt/multipath are listed for that last step.
apply_deactivate() {   # DISK [DISK2]
	local disk=$1 disk2=${2:-} line p t mp busy=() swaps=() mds=() acted=0 vg md trees d
	local -A seen=()
	trees=$AP_TREE; [ -z "$AP_TREE2" ] || trees="$trees"$'\n'"$AP_TREE2"
	if [ -n "$trees" ]; then
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			p=$(ap_kv "$line" PATH); mp=$(ap_kv "$line" MOUNTPOINT); t=$(ap_kv "$line" TYPE)
			case $mp in '') ;; '[SWAP]') swaps+=("$p");; *) busy+=("$p on $mp");; esac
			# an array the inventory did not know (an earlier apply of this plan): stopped like the others
			case $t in raid*) [ -n "${seen[md:$p]:-}" ] || { seen[md:$p]=1; mds+=("$p"); };; esac
		done <<< "$trees"
	fi
	[ ${#busy[@]} -eq 0 ] || die "$EX_ENV" "unmount first: ${busy[*]} (reloca.to never unmounts what it did not mount)"
	for p in "${AP_SWAPS[@]}"; do grep -q "^$p " /proc/swaps 2>/dev/null && swaps+=("$p"); done
	for p in "${swaps[@]}"; do [ -n "${seen[$p]:-}" ] && continue; seen[$p]=1; must swapoff "$p"; acted=$((acted+1)); done
	for vg in "${AP_VGS[@]}"; do must vgchange -an "$vg"; acted=$((acted+1)); done
	for md in "${AP_MDS[@]}"; do [ -n "${seen[md:$md]:-}" ] || { seen[md:$md]=1; mds+=("$md"); }; done
	for md in "${mds[@]}"; do md_stop_retry "$md" || die "$EX_FAIL" "cannot stop $md (still busy after $APPLY_MD_RETRIES tries)"; acted=$((acted+1)); done
	for d in $disk $disk2; do
		if [ -n "$DRY" ]; then { [ "$d" = "$disk" ] && line=$AP_TREE; } || line=$AP_TREE2; elif apply_disk_present "$d"; then line=$(apply_read_tree "$d"); else line=; fi
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			p=$(ap_kv "$line" PATH); t=$(ap_kv "$line" TYPE)
			case $t in crypt|mpath|dm) ;; lvm) [ -z "$DRY" ] || continue;; *) continue;; esac
			[ -n "${seen[dm:$p]:-}" ] && continue; seen[dm:$p]=1
			run dmsetup remove "$p" || warn "dmsetup remove $p failed ($?)"; acted=$((acted+1))
		done <<< "$line"
	done
	[ "$acted" -gt 0 ] || say "nothing active on $disk${disk2:+ or $disk2} to deactivate"
}
# apply_wipe_old DISK [TREE]: every signature of the old contents, partitions first, then the disk
apply_wipe_old() {
	local disk=$1 tree=${2-$AP_TREE} line p parts=()
	if [ -n "$tree" ]; then
		while IFS= read -r line; do [ "$(ap_kv "$line" TYPE)" = part ] && parts+=("$(ap_kv "$line" PATH)"); done <<< "$tree"
	else
		for p in "${AP_PARTS[@]}"; do case $p in "$disk"*) parts+=("$p");; esac; done   # the disk is not here (dry run): the inventory's view
	fi
	for p in "${parts[@]}"; do
		run mdadm --zero-superblock --force "$p" 2>/dev/null || true   # not an md member: fine
		must wipefs -a "$p"
	done
	must wipefs -a "$disk"
	run sgdisk --zap-all "$disk" || warn "sgdisk --zap-all $disk returned $?: continuing, sfdisk --wipe always follows"
	run udevadm settle || true
}
# apply_setro_others [DISK [INV]]: every other disk of the inventory read-only until cleanup;
# a typo in a device name then meets EROFS instead of data. Disks already ro are left alone.
apply_setro_others() {
	local d ro list=() csv
	if [ -n "${1:-}" ] || [ -z "${AP_OTHERS+x}" ]; then
		[ -n "$AP_DISK2" ] || AP_DISK2=$(plan_get "${AP_PLAN:-$RUN/plan}" target disk2 2>/dev/null)
		apply_target_map "${1:-$(apply_target_disk)}" "${2:-$RUN/recipient.inv}"
	fi
	for d in "${AP_OTHERS[@]}"; do
		ro=${d#*:}; d=${d%%:*}
		if [ "$ro" = 1 ]; then say "$d is already read-only"; continue; fi
		must blockdev --setro "$d"; list+=("$d")
		[ -n "$DRY" ] || cleanup_add "blockdev --setrw $(printf '%q' "$d")"
	done
	if [ ${#list[@]} -eq 0 ]; then say "no other disks on this box to set read-only"; return 0; fi
	csv=$(IFS=,; echo "${list[*]}")
	[ -n "$DRY" ] || state_set setro.disks "$csv"
	say "read-only until cleanup: $csv"
}
# apply_partition DISK LABEL [SECTION]: the plan's [sfdisk] (or [sfdisk2] for disk2) verbatim
# through /usr/sbin/sfdisk, then the nodes
apply_partition() {
	local disk=$1 label=$2 sec=${3:-sfdisk} script dev n u line nodes=()
	script=$RUN/$sec.script
	mkdir -p "$RUN"
	plan_section "$AP_PLAN" "$sec" > "$script"
	say "sfdisk script $script:"; sed 's/^/    /' "$script"
	must_sh "$APPLY_SFDISK --wipe always --wipe-partitions always $(printf '%q' "$disk") < $(printf '%q' "$script")"
	run partprobe "$disk" || warn "partprobe $disk returned $?"
	run udevadm settle || true
	while read -r dev _ _; do
		n=${dev#"$disk"}; n=${n#p}; nodes+=("$(apply_partnode "$disk" "$n")")
	done < <(plan_sfdisk "$AP_PLAN" "$sec")
	if [ "$label" = gpt ]; then
		while IFS= read -r line; do
			u=$(sed -n 's/.*[ ,]uuid=\([^, ]*\).*/\1/p' <<< "$line"); [ -z "$u" ] || nodes+=("/dev/disk/by-partuuid/${u,,}")
		done < <(plan_section "$AP_PLAN" "$sec" | grep ' : ')
	fi
	apply_wait_nodes "${nodes[@]}"
}
# apply_md_recheck DISK: udev may assemble an array from a superblock the wipe did not reach
apply_md_recheck() {
	local disk=$1 md left
	if [ -n "$DRY" ]; then echo "(dry) would stop any md array udev re-assembles from $disk (settle + retry, fatal if it persists)"; return 0; fi
	for md in $(apply_md_on_disk "$disk"); do
		warn "$md re-assembled from $disk after partitioning: stopping it"
		md_stop_retry "$md" || die "$EX_FAIL" "cannot stop $md, re-assembled from $disk"
	done
	run udevadm settle || true
	left=$(apply_md_on_disk "$disk")
	[ -z "$left" ] || die "$EX_FAIL" "md arrays keep re-assembling from $disk: $(echo "$left" | paste -sd' ' -)"
}
apply_lvm() {
	local line newvgs=() vg nodes=()
	[ -n "$(plan_section "$AP_PLAN" lvm)" ] || { say "no [lvm] in the plan"; return 0; }
	while IFS= read -r line; do
		apply_fingerprint_check
		must_sh "$line"
		# shellcheck disable=SC2086  # the lvm line is split into words on purpose
		case $line in vgcreate\ *) set -- $line; newvgs+=("$2");; esac
	done < <(plan_section "$AP_PLAN" lvm)
	for vg in "${newvgs[@]}"; do must vgchange -ay "$vg"; done
	run udevadm settle || true
	while IFS= read -r line; do
		[ "$(pl_field "$line" kind)" = lv ] && nodes+=("$(pl_field "$line" target)")
	done < <(plan_section "$AP_PLAN" volumes)
	apply_wait_nodes "${nodes[@]}"
}
apply_mkfs() {
	local line cmd dev type
	[ -n "$(plan_section "$AP_PLAN" mkfs)" ] || { say "no [mkfs] lines in the plan"; return 0; }
	while IFS= read -r line; do
		apply_fingerprint_check
		must_sh "$line"
		# shellcheck disable=SC2086  # the mkfs line is split into words on purpose
		set -- $line; cmd=$1; dev=${*: -1}
		case $cmd in mkfs.ext2|mkfs.ext3|mkfs.ext4) type=ext;; mkfs.xfs) type=xfs;; *) continue;; esac
		apply_masks_guard "$dev" "$type"
	done < <(plan_section "$AP_PLAN" mkfs)
}
apply_finish() {   # DISK [DISK2]: every [volumes] row pending (unless done/running), phase.apply=done
	local disk=$1 disk2=${2:-} line src n=0
	if [ -n "$DRY" ]; then
		echo "(dry) would mark every [volumes] row pending and phase apply done in $RUN/state"
		say "dry run of apply finished: nothing written, no state left"; return 0
	fi
	while IFS= read -r line; do
		src=$(pl_field "$line" src); n=$((n+1))
		case $(vol_state_get "$src") in done|running) ;; *) vol_state_set "$src" pending;; esac
	done < <(plan_section "$AP_PLAN" volumes)
	phase_done apply; state_set apply.time "$(date +%s)"
	say "apply done: $disk${disk2:+ and $disk2 (md RAID1)} partitioned and formatted, $n volume(s) pending"
}

# ==============================================================================
# apply_run — the driver's apply phase
# ==============================================================================
apply_run() {
	AP_PLAN=$RUN/plan
	local inv=$RUN/recipient.inv disk id label why disk2='' id2=''
	plan_check "$AP_PLAN"                                  # dies 4 on anything it dislikes
	[ -r "$inv" ] || die "$EX_ENV" "no recipient inventory at $inv (run 'reloca.to -s plan DONOR' first)"
	disk=$(plan_get "$AP_PLAN" target disk); id=$(ap_dec "$(plan_get "$AP_PLAN" target id)"); label=$(plan_get "$AP_PLAN" target label)
	[ -n "$disk" ] || die "$EX_PLAN" "[target] lacks disk="
	[ -n "$label" ] || die "$EX_PLAN" "[target] lacks label="
	if [ "$(plan_get "$AP_PLAN" target raid)" = 1 ]; then
		disk2=$(plan_get "$AP_PLAN" target disk2); id2=$(ap_dec "$(plan_get "$AP_PLAN" target id2)")
		[ -n "$disk2" ] || die "$EX_PLAN" "[target] raid=1 lacks disk2="
	fi
	AP_DISK2=$disk2
	apply_target_map "$disk" "$inv"
	# 0. already done? (a dry run keeps no state, so it always walks the steps)
	if [ -z "$DRY" ] && phase_is_done apply; then
		if [ "$(opt force 0)" = 1 ]; then say "apply is marked done: redoing it (force=1)"
		elif why=$(apply_fingerprint_verify); then say "apply already done: $disk still carries the recorded fingerprint (force=1 to redo)"; return 0
		else warn "apply is marked done but $disk does not match the recorded fingerprint ($why): redoing it"; fi
	fi
	AP_TREE=; if apply_disk_present "$disk"; then AP_TREE=$(apply_read_tree "$disk"); fi
	AP_TREE2=; if [ -n "$disk2" ] && apply_disk_present "$disk2"; then AP_TREE2=$(apply_read_tree "$disk2"); fi
	# 1. the plan still describes this disk (both of them under raid=1)
	apply_pregate "$disk"
	[ -z "$disk2" ] || apply_pregate "$disk2" 2
	# 2. the gate: the operator types the disk name(s) and size read off the screen (blank disks: y/N)
	apply_gate "$disk" "$disk2"
	# 3. nothing of the old contents may be live
	say "--- deactivating what lives on $disk${disk2:+ and $disk2}"
	apply_deactivate "$disk" "$disk2"
	# 4. old signatures
	say "--- wiping old signatures on $disk"
	apply_wipe_old "$disk"
	[ -z "$disk2" ] || { say "--- wiping old signatures on $disk2"; apply_wipe_old "$disk2" "$AP_TREE2"; }
	# 5. every other disk read-only from here on
	say "--- other disks read-only"
	apply_setro_others
	# 6. the partition table(s)
	say "--- partitioning $disk ($label)"
	apply_partition "$disk" "$label"
	apply_md_recheck "$disk"
	if [ -n "$disk2" ]; then
		say "--- partitioning $disk2 ($label, the mirror's own table)"
		apply_partition "$disk2" "$label" sfdisk2
		apply_md_recheck "$disk2"
	fi
	# 7. the post-apply fingerprint every later write is checked against
	apply_fingerprint_record "$disk" "$id"
	[ -z "$disk2" ] || apply_fingerprint_record "$disk2" "$id2" 2
	# 8. BIOS+GPT: the protective MBR needs the boot flag for some firmware. parted
	#    rewrites the table and has the kernel re-read it: every partition is removed
	#    and added again, and until udev has worked through that lsblk shows them
	#    without a PARTUUID - the fingerprint check before the first [lvm]/[mkfs]
	#    line then saw "the disk changed since apply" (stand, uefi donor -> bios)
	if [ "$(plan_get "$AP_PLAN" target pmbr_boot)" = 1 ]; then
		must parted -s "$disk" disk_set pmbr_boot on
		[ -z "$disk2" ] || must parted -s "$disk2" disk_set pmbr_boot on
		run udevadm settle || true
	fi
	# 8b. raid=1: the arrays, one per slot
	if [ -n "$disk2" ]; then say "--- md RAID1 arrays"; apply_md_create; fi
	# 9. LVM
	say "--- lvm"
	apply_lvm
	# 10. mkswap / mkfs, each ext/xfs checked against the donor's masks at once
	say "--- mkfs"
	apply_mkfs
	# 11. state
	apply_finish "$disk" "$disk2"
}

# ==============================================================================
# cleanup_all — "reloca.to -s cleanup" and the crash path; idempotent, never dies
# ==============================================================================
cleanup_all() {
	local undid=() m vg d list plan=$RUN/plan target user host port fd
	local -a mounts=()
	say "cleanup: undoing what reloca.to left behind"
	# 1. what this process registered (setrw, umounts, the donor's data sshd)
	if [ ${#CLEANUP_CMDS[@]} -gt 0 ]; then
		say "cleanup: ${#CLEANUP_CMDS[@]} registered action(s)"; undid+=("${#CLEANUP_CMDS[@]} registered actions"); run_cleanup
	fi
	# 2. mounts under /mnt/reloca.to and /mnt/localboot, deepest first (mounted with
	#    --make-private, so a plain umount suffices; lazy as the last resort)
	mapfile -t mounts < <(findmnt -rn -o TARGET 2>/dev/null | grep -E "^($APPLY_MNT|/mnt/localboot)(/|$)" | awk '{ print length($0), $0 }' | sort -rn | cut -d' ' -f2-)
	for m in "${mounts[@]}"; do
		run umount "$m" || run umount -l "$m" || warn "cleanup: cannot unmount $m"
		undid+=("umount $m")
	done
	[ ! -d "$APPLY_MNT" ] || run_sh "find $(printf '%q' "$APPLY_MNT") -mindepth 1 -depth -type d -empty -delete" || true
	# 3. the plan's VGs (activated by apply, left active for transfer/postfix), then the
	#    plan's md arrays (raid=1): resync resumed so it is not left frozen, then stopped
	if [ -r "$plan" ]; then
		for vg in $(plan_section "$plan" lvm | awk '$1 == "vgcreate" { print $2 }'); do
			[ -d "/dev/$vg" ] || continue
			run vgchange -an "$vg" || warn "cleanup: vgchange -an $vg failed"; undid+=("vg $vg")
		done
		for m in $(apply_md_devs "$plan"); do
			md_is_running "$m" || continue
			md_sync_set "$m" idle
			if md_stop_retry "$m"; then undid+=("md $m"); else warn "cleanup: cannot stop $m"; fi
		done
	fi
	# 4. the disks apply set read-only (state survives a crash; the registered snippet does not)
	list=$(state_get setro.disks)
	if [ -n "$list" ] && [ "$list" != - ]; then
		for d in ${list//,/ }; do run blockdev --setrw "$d" || warn "cleanup: blockdev --setrw $d failed"; undid+=("setrw $d"); done
		[ -n "$DRY" ] || state_set setro.disks -
	fi
	# 5. the donor, through the master only (no new login): its data sshd by OUR pid file
	#    and our mount points; then the master itself. Rule 4: nothing else is touched there.
	target=$(state_get donor.target)
	if [ "$(state_get mode)" = online ]; then
		say "cleanup: on-line donor: nothing to undo there (the agent's tmpfs stays; a frozen donor is thawed only by 'reloca.to -s cutover -o cutover=rollback')"
	elif [ -S "$RUN/ssh.sock" ] && [ -n "$target" ]; then
		user=${target%%@*}; host=${target#*@}; port=${host##*:}; host=${host%:*}
		# shellcheck disable=SC2016  # $p and $m expand on the donor, not here
		run ssh -S "$RUN/ssh.sock" -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR -p "${port:-22}" "${user:-root}@$host" -- \
			sh -c 'p=$(cat /run/reloca-sshd.pid 2>/dev/null); [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = sshd ] && kill "$p"; rm -f /run/reloca-sshd.pid; for m in $(findmnt -rn -o TARGET | grep "^/mnt/reloca.to/" | sort -r); do umount "$m"; done; true' \
			|| warn "cleanup: the donor could not be reached through the master"
		undid+=("donor sshd/mounts")
	fi
	if declare -f ssh_disconnect >/dev/null && [ -S "$RUN/ssh.sock" ]; then
		if [ -n "$DRY" ]; then echo "(dry) ssh_disconnect"; else ssh_disconnect; fi
		undid+=("ssh master")
	fi
	# 6. the lock: only when nobody holds it (a running instance keeps its own)
	if [ -e "$RUN/lock" ]; then
		if { exec {fd}<"$RUN/lock"; } 2>/dev/null && flock -n "$fd"; then
			[ -n "$DRY" ] || rm -f "$RUN/lock"; undid+=("lock")
		else say "cleanup: $RUN/lock is held by a running reloca.to, left in place"; fi
		[ -z "${fd:-}" ] || exec {fd}<&-
	fi
	if [ ${#undid[@]} -gt 0 ]; then say "cleanup: done (${undid[*]})"; else say "cleanup: done, nothing to undo"; fi
	return 0
}
