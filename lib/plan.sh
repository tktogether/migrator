#!/bin/bash
# lib/plan.sh — the planner: two inventories (docs/format.md) in, one plan out.
#
#   plan_compute DONOR.inv RECIPIENT.inv DISK|DISK,DISK2|auto [key=value ...]
#       the PURE core: no $RUN, no OPT, no disk access; plan text on stdout,
#       "WARN: ..." on stderr (and as "# WARN:" lines after the header),
#       exit 4 with "# ERROR: <reason>" as the last stdout line when the
#       migration is infeasible. This is what tests/cases/plan.sh drives.
#   plan_build DISK           driver entry: $RUN/{donor,recipient}.inv + -o options
#                             -> $RUN/plan, the one-screen summary; die 4 on refusal
#   plan_check [PLANFILE]     driver entry: re-validate a (hand-edited) plan
#   plan_section FILE NAME    body of [NAME] without comments/blank lines
#   plan_get FILE SECTION KEY value of key=value anywhere in [SECTION]
#   pl_records FILE TYPE / pl_field RECORD KEY / pl_lookup FILE TYPE KEY VALUE FIELD
#                             inventory readers (tab-separated key=value records)
#
# Every rule below is numbered as in the design (R1..R15) so the fixtures'
# README files can say which rule they assert. All sizes are bytes in bash
# integers (64-bit); awk (mawk) only formats tables.
#
# raid=1 (R16, a recipient with two disks): both disks get the same partition
# table ([sfdisk] for disk, [sfdisk2] for disk2: own label id and partition
# GUIDs), every data slot becomes an md RAID1 of the two partitions ([md]: one
# mdadm --create per array, /dev/md<N> after the partition number, metadata
# 1.2 at a fixed 8 MiB data offset so the array is exactly slot - 8 MiB), the
# ESP (uefi) and bios_grub stay plain on BOTH disks (esp-mirror row: the second
# ESP is a copy postfix fills), PARTUUID= references are rewritten to UUID=
# (a partition is a member now, not a filesystem). Never chosen silently: two
# eligible disks without raid=1 or -d are a refusal naming both options.
# shellcheck disable=SC2015  # "test && test || continue" guards are used on purpose throughout

PL_MIB=1048576
PL_GIB=1073741824
PL_TIB=1099511627776
# sfdisk partition types per label (R6)
PL_GPT_FS=0FC63DAF-8483-4772-8E79-3D69D8477DE4
PL_GPT_SWAP=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
PL_GPT_LVM=E6D6D379-F507-44C2-A23C-238F2A3DF928
PL_GPT_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
PL_GPT_BIOS=21686148-6449-6E6F-744E-656564454649
# raid=1 (R16): metadata 1.2 at a fixed data offset, so an array is exactly its slot minus this
PL_MD_OFF=8388608          # 8 MiB; the mdadm flag is --data-offset=8M
PL_MD_OFF_FLAG=8M
# feature -> oldest kernel that reads it (R8 guard, informational)
PL_FEATURE_KERNEL="orphan_file:5.15 metadata_csum_seed:4.4 large_dir:4.13 casefold:5.2 verity:5.4 fast_commit:5.10 REFLINK:4.9 RMAPBT:4.8 BIGTIME:5.10 INOBTCNT:5.10 NREXT64:5.19 SPARSE_INODES:4.2"
# driver names that are not initramfs modules worth listing (R9)
PL_GENERIC_DRIVERS=" sd sr scsi sd_mod sr_mod scsi_mod sg pcieport pci "

# --- inventory readers ----------------------------------------------------------
# pl_records FILE TYPE: every record of TYPE, one per line (comments skipped)
pl_records() { awk -F'\t' -v t="$2" '$1 == t' "$1"; }
# pl_field RECORD KEY: the value of KEY= in a record; status 1 when absent
pl_field() {
	local -a f; local x
	IFS=$'\t' read -ra f <<< "$1"
	for x in "${f[@]}"; do case $x in "$2="*) printf '%s\n' "${x#*=}"; return 0;; esac; done
	return 1
}
# pl_lookup FILE TYPE KEY VALUE FIELD: FIELD of the first TYPE record with KEY=VALUE
pl_lookup() {
	awk -F'\t' -v t="$2" -v kv="$3=$4" -v f="$5=" '
		$1 != t { next }
		{ hit = 0; for (i = 2; i <= NF; i++) if ($i == kv) hit = 1
		  if (!hit) next
		  for (i = 2; i <= NF; i++) if (index($i, f) == 1) { print substr($i, length(f) + 1); exit }
		  exit }' "$1"
}
# pc_find ARRAY KEY VALUE: first record of the bash array ARRAY with KEY=VALUE
pc_find() {
	local -n _pcf=$1; local r
	for r in "${_pcf[@]}"; do
		case "$r" in *$'\t'"$2=$3"$'\t'*|*$'\t'"$2=$3") printf '%s\n' "$r"; return 0;; esac
	done
	return 1
}
# pc_f RECORD KEY DEFAULT: pl_field with a default for "" and "-"
pc_f() { local v; v=$(pl_field "$1" "$2"); if [ -z "$v" ] || [ "$v" = - ]; then printf '%s\n' "${3-}"; else printf '%s\n' "$v"; fi; }

# --- small helpers ----------------------------------------------------------------
pl_mib_up()   { echo $(( ($1 + PL_MIB - 1) / PL_MIB * PL_MIB )); }
pl_mib_down() { echo $(( $1 / PL_MIB * PL_MIB )); }
pl_pct110()   { echo $(( $1 + $1 / 10 )); }       # used x 1.10 (integer, rounds down by < 1 byte)
pl_max()      { if [ "$1" -ge "$2" ]; then echo "$1"; else echo "$2"; fi; }
pl_enc()      { local s=$1; s=${s// /%20}; s=${s//,/%2C}; s=${s//$'\t'/%20}; printf '%s\n' "$s"; }
pl_enc_sp()   { local s=$1; s=${s// /%20}; s=${s//$'\t'/%20}; printf '%s\n' "$s"; }
# pl_uuid_from SEED N: a GUID that is the same on every run for the same donor
# (tests diff the plan), derived from the donor's label id (R4)
pl_uuid_from() {
	local h; h=$(echo "$1:$2" | sha256sum | cut -c1-32 | tr a-f A-F)
	echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
}
# pl_partdev DISK N: /dev/sda -> /dev/sda3, /dev/nvme0n1 -> /dev/nvme0n1p3
pl_partdev() { case $1 in *[0-9]) echo "$1p$2";; *) echo "$1$2";; esac; }
# pl_mduuid_from SEED N: an md UUID in mdadm's colon form, the same on every run (R16)
pl_mduuid_from() {
	local h; h=$(echo "$1:md:$2" | sha256sum | cut -c1-32)
	echo "${h:0:8}:${h:8:8}:${h:16:8}:${h:24:8}"
}
# pl_kver_lt A B: "5.4" < "5.15" by major.minor
pl_kver_lt() {
	local a1=${1%%.*} b1=${2%%.*} a2 b2
	a2=${1#*.}; a2=${a2%%[!0-9]*}; b2=${2#*.}; b2=${b2%%[!0-9]*}
	[ "${a1:-0}" -lt "${b1:-0}" ] || { [ "${a1:-0}" -eq "${b1:-0}" ] && [ "${a2:-0}" -lt "${b2:-0}" ]; }
}
# pl_has LIST ITEM: comma-separated LIST contains ITEM
pl_has() { case ",$1," in *",$2,"*) return 0;; esac; return 1; }

# ==============================================================================
# plan_compute — the pure core. Runs in a subshell so a refusal can exit 4 from
# any depth; every pc_* helper below works on pc_main's locals (dynamic scope).
# ==============================================================================
plan_compute() { ( pc_main "$@" ); }

pc_warn()   { echo "WARN: $*" >&2; WARNS+=("$*"); }
pc_refuse() { pc_header; echo "# ERROR: $*"; echo "ERROR: $*" >&2; exit 4; }
# the plan header: identity of both machines, inventory hashes, versions, warnings
pc_header() {
	local dsum rsum
	dsum=$(sha256sum "$D" | cut -c1-64); rsum=$(sha256sum "$R" | cut -c1-64)
	echo "# reloca.to plan  donor=$(pc_f "$D_HOST" bootip -)/$(pc_f "$D_HOST" hostname -) ($(pl_enc_sp "$(pc_f "$D_HOST" dmi_vendor -) $(pc_f "$D_HOST" dmi_product -) SN=$(pc_f "$D_HOST" dmi_serial -)"), $(pl_enc_sp "$(pc_f "$D_OS" pretty unknown-os)"))  recipient=$(pc_f "$R_HOST" hostname -) ($(pl_enc_sp "$(pc_f "$R_HOST" dmi_vendor -) $(pc_f "$R_HOST" dmi_product -) SN=$(pc_f "$R_HOST" dmi_serial -)"), boot=$(pc_f "$R_HOST" bootnic -)/$(pc_f "$R_HOST" bootmac -))"
	echo "# inv_sha256=$dsum:$rsum  reloca=${O[reloca]}  live=${O[live]}  date=${O[date]}"
	local w; for w in "${WARNS[@]}"; do echo "# WARN: $w"; done
}

pc_main() {
	local D=$1 R=$2 DISK=$3; shift 3
	[ -r "$D" ] || { echo "ERROR: cannot read donor inventory $D" >&2; echo "# ERROR: cannot read donor inventory $D"; exit 4; }
	[ -r "$R" ] || { echo "ERROR: cannot read recipient inventory $R" >&2; echo "# ERROR: cannot read recipient inventory $R"; exit 4; }
	local -A O=([label]=auto [root]=auto [data]=ssh [compress]=lz4 [driver]="" [nic]=eth0 [donor-nic]="" [nic-pin]=1 [boot-part]="" [cloudinit]=disable [bootorder]=pxe [force]=0 [raid]=0 [reloca]=- [live]=- [date]=-)
	local kv k; for kv in "$@"; do case $kv in *=*) k=${kv%%=*}; O[${k//_/-}]=${kv#*=};; *) echo "ERROR: bad option '$kv' (want key=value)" >&2; exit 4;; esac; done
	case ${O[label]} in auto|gpt|dos) ;; *) echo "ERROR: label=${O[label]}: want auto|gpt|dos" >&2; exit 4;; esac
	case ${O[root]} in auto|block|files) ;; *) echo "ERROR: root=${O[root]}: want auto|block|files" >&2; exit 4;; esac
	case ${O[raid]} in 0|1) ;; *) echo "ERROR: raid=${O[raid]}: want 1 (md RAID1 over two disks) or 0" >&2; exit 4;; esac
	RAID=${O[raid]}
	local -a WARNS=()
	local -A MIG=()      # donor device -> UUID=… of its content | keep | member | - (pv)
	pc_load
	pc_target_disk
	pc_firmware
	pc_base_disk
	pc_slots
	pc_label
	pc_layout
	pc_methods
	pc_drivers
	pc_identity
	pc_emit
}

# --- records into arrays ----------------------------------------------------------
# shellcheck disable=SC2034  # the D_*/R_* arrays are read through pc_find's nameref
pc_load() {
	mapfile -t D_DISK    < <(pl_records "$D" disk)
	mapfile -t D_PART    < <(pl_records "$D" part)
	mapfile -t D_MD      < <(pl_records "$D" md)
	mapfile -t D_PV      < <(pl_records "$D" pv)
	mapfile -t D_VG      < <(pl_records "$D" vg)
	mapfile -t D_LV      < <(pl_records "$D" lv)
	mapfile -t D_FS      < <(pl_records "$D" fs)
	mapfile -t D_SWAP    < <(pl_records "$D" swap)
	mapfile -t D_FSTAB   < <(pl_records "$D" fstab)
	mapfile -t D_CMDLINE < <(pl_records "$D" cmdline)
	mapfile -t D_KERNEL  < <(pl_records "$D" kernel)
	mapfile -t D_SWAPFILE < <(pl_records "$D" swapfile)
	D_HOST=$(pl_records "$D" host | head -1)
	D_OS=$(pl_records "$D" os | head -1)
	# -o donor-nic=IFACE names the donor's primary interface when the inventory
	# could not tell (several gateways, exotic config); nic= is the TARGET name
	[ -z "${O[donor-nic]}" ] || D_OS=$(printf '%s' "$D_OS" | awk -F'\t' -v OFS='\t' -v n="${O[donor-nic]}" '{ for (i = 1; i <= NF; i++) if ($i ~ /^primary_nic=/) $i = "primary_nic=" n; print }')
	D_LVMCONF=$(pl_records "$D" lvmconf | head -1)
	mapfile -t R_DISK < <(pl_records "$R" disk)
	mapfile -t R_NIC  < <(pl_records "$R" nic)
	R_HOST=$(pl_records "$R" host | head -1)
	[ -n "$D_HOST" ] || pc_refuse "donor inventory has no host record"
	[ -n "$R_HOST" ] || pc_refuse "recipient inventory has no host record"
	[ -n "$D_OS" ]   || pc_refuse "donor inventory has no os record (root not found or not mounted)"
	[ "$(pc_f "$D_HOST" role)" = donor ] || pc_refuse "$D is not a donor inventory (role=$(pc_f "$D_HOST" role -))"
	[ "$(pc_f "$R_HOST" role)" = recipient ] || pc_refuse "$R is not a recipient inventory (role=$(pc_f "$R_HOST" role -))"
	FAMILY=$(pc_f "$D_OS" family unsupported)
	case $FAMILY in deb|rhel) ;; *) pc_refuse "unsupported donor OS family '$FAMILY' ($(pc_f "$D_OS" pretty -)): v1 handles deb and rhel";; esac
	[ "$(pc_f "$D_OS" grub)" != grub1 ] || pc_refuse "donor boots with grub-legacy: not supported (CentOS 6 and older)"
}

# --- R1: target disk (R16: two of them under raid=1) -----------------------------------------
# pc_disk_rec DEV -> the recipient disk record of DEV (by path or by-id), "" when none
pc_disk_rec() {
	local r; r=$(pc_find R_DISK dev "$1") || r=$(pc_find R_DISK byid "${1#/dev/disk/by-id/}") || r=
	printf '%s\n' "$r"
}
pc_disk_id() {   # RECORD -> wwn:… | serial:… | model:…
	local dev; dev=$(pc_f "$1" wwn); if [ -n "$dev" ]; then echo "wwn:$dev"; return; fi
	dev=$(pc_f "$1" serial); if [ -n "$dev" ]; then echo "serial:$dev"; else echo "model:$(pc_f "$1" model -)"; fi
}
pc_disk_check() {   # RECORD: the rules every target disk must meet
	local dev size lsec
	dev=$(pc_f "$1" dev); size=$(pc_f "$1" size 0); lsec=$(pc_f "$1" lsec 512)
	[ "$(pc_f "$1" ro 0)" = 0 ] || pc_refuse "target disk $dev is read-only"
	[ "$size" -ge $((20 * PL_GIB)) ] || pc_refuse "target disk $dev is only $(human "$size"): less than 20 GiB"
	case $lsec in 512|4096) ;; *) pc_refuse "target disk $dev has a logical sector of $lsec bytes";; esac
}
pc_target_disk() {
	local r cands=() c list='' d1 d2 n note
	for r in "${R_DISK[@]}"; do
		[ "$(pc_f "$r" rm 0)" = 0 ] || continue
		[ "$(pc_f "$r" tran)" != usb ] || continue
		[ "$(pc_f "$r" size 0)" -ge $((20 * PL_GIB)) ] || continue
		cands+=("$r")
	done
	for c in "${cands[@]}"; do list="$list $(pc_f "$c" dev) ($(human "$(pc_f "$c" size 0)") $(pc_f "$c" model -) $(pc_f "$c" tran -) $(pc_f "$c" usage -))"; done
	T2_REC=
	# the family blocker first: it is the real answer, whatever the disks look like
	[ "$RAID" != 1 ] || [ "$FAMILY" = deb ] || pc_refuse "raid=1 is implemented for the deb family only (mdadm.conf, initramfs-tools, grub on both disks); rhel arrives with M4"
	case $DISK in
		auto)
			[ ${#cands[@]} -gt 0 ] || pc_refuse "no target disk candidate on the recipient (non-removable, not USB, >= 20 GiB): pass -d DISK explicitly"
			if [ "$RAID" = 1 ]; then
				[ ${#cands[@]} -eq 2 ] || pc_refuse "raid=1 mirrors two disks but the recipient has ${#cands[@]} candidate(s): name the pair with -d DISK,DISK2:$list"
				T_REC=${cands[0]}; T2_REC=${cands[1]}
			else
				[ ${#cands[@]} -eq 1 ] || pc_refuse "${#cands[@]} target disk candidates: -o raid=1 mirrors two of them (md RAID1), -d DISK migrates onto one; nothing is chosen for you:$list"
				T_REC=${cands[0]}
			fi;;
		*,*)
			d1=${DISK%%,*}; d2=${DISK#*,}
			[ "$RAID" = 1 ] || pc_refuse "-d $DISK names two disks: that is a mirror, add -o raid=1 (or name one disk)"
			case $d2 in *,*) pc_refuse "-d $DISK: raid=1 takes exactly two disks";; esac
			[ "$d1" != "$d2" ] || pc_refuse "-d $DISK names the same disk twice"
			T_REC=$(pc_disk_rec "$d1"); T2_REC=$(pc_disk_rec "$d2")
			[ -n "$T_REC" ] || pc_refuse "target disk $d1 is not in the recipient inventory (disks: $(for r in "${R_DISK[@]}"; do printf '%s ' "$(pc_f "$r" dev)"; done))"
			[ -n "$T2_REC" ] || pc_refuse "target disk $d2 is not in the recipient inventory (disks: $(for r in "${R_DISK[@]}"; do printf '%s ' "$(pc_f "$r" dev)"; done))";;
		*)
			[ "$RAID" != 1 ] || pc_refuse "raid=1 needs two disks: -d DISK,DISK2 (or no -d when the recipient has exactly two candidates)"
			T_REC=$(pc_disk_rec "$DISK")
			[ -n "$T_REC" ] || pc_refuse "target disk $DISK is not in the recipient inventory (disks: $(for r in "${R_DISK[@]}"; do printf '%s ' "$(pc_f "$r" dev)"; done))";;
	esac
	pc_disk_check "$T_REC"
	T_DEV=$(pc_f "$T_REC" dev); T_SIZE=$(pc_f "$T_REC" size 0)
	T_LSEC=$(pc_f "$T_REC" lsec 512); T_PSEC=$(pc_f "$T_REC" psec "$T_LSEC")
	T_PTUUID=$(pc_f "$T_REC" ptuuid -); T_USAGE=$(pc_f "$T_REC" usage free)
	T_ID=$(pc_disk_id "$T_REC")
	T_DISKSIZE=$T_SIZE
	T2_DEV=-; T2_SIZE=0; T2_ID=-; T2_PTUUID=-; T2_USAGE=-
	if [ "$RAID" = 1 ]; then
		pc_disk_check "$T2_REC"
		T2_DEV=$(pc_f "$T2_REC" dev); T2_SIZE=$(pc_f "$T2_REC" size 0); T2_ID=$(pc_disk_id "$T2_REC")
		T2_PTUUID=$(pc_f "$T2_REC" ptuuid -); T2_USAGE=$(pc_f "$T2_REC" usage free)
		[ "$(pc_f "$T2_REC" lsec 512)" = "$T_LSEC" ] || pc_refuse "raid=1: $T_DEV and $T2_DEV have different logical sectors ($T_LSEC vs $(pc_f "$T2_REC" lsec 512)): one partition table cannot fit both"
		# the geometry is the smaller disk's and goes onto both; the tail of a bigger one stays unused
		if [ "$T2_SIZE" -lt "$T_SIZE" ]; then T_SIZE=$T2_SIZE; fi
		[ "$T2_SIZE" -eq "$T_DISKSIZE" ] || pc_warn "raid=1: the disks differ in size ($T_DEV $(human "$T_DISKSIZE"), $T2_DEV $(human "$T2_SIZE")): the layout follows the smaller one, $(human $(( (T_DISKSIZE > T2_SIZE ? T_DISKSIZE : T2_SIZE) - T_SIZE ))) of the bigger disk stay unused"
		n=${#D_MD[@]}; note=; [ "$n" -eq 0 ] || note=" (the donor's $n md array(s) keep their UUIDs)"
		pc_warn "raid=1: $T_DEV + $T2_DEV become md RAID1 pairs per slot, ESP/bios_grub on both disks, the resync runs in the background after the copy$note"
	fi
	R_FW=$(pc_f "$R_HOST" fw bios); R_SB=$(pc_f "$R_HOST" secureboot 0)
	R_BOOTMAC=$(pc_f "$R_HOST" bootmac -); R_BOOTNIC=$(pc_f "$R_HOST" bootnic -)
	# on-line relocation: the inventory came from the donor's running OS (host.online=1);
	# the volumes are copied by the agent in passes and frozen for the last one
	ONLINE=$(pc_f "$D_HOST" online 0)
	[ "$ONLINE" != 1 ] || pc_warn "on-line relocation: the donor keeps running; block volumes are copied in passes by reloca-agent, file volumes by tar incremental passes, all frozen for the final pass (mode=online)"
}

# --- R2: firmware ----------------------------------------------------------------------
# donor mode: uefi when it has an ESP (vfat at /boot/efi in fstab or a partition
# of ESP type), else bios. Cross-firmware is a WARN: deb gets grub from the Live
# (grub_from_live=1), rhel gets its own grub2 packages through dnf in the chroot
# (grub_pkgs=: rhel's grub2-mkconfig writes blscfg, which the Live's grub lacks,
# so nothing of the Live can serve it). SecureBoot needs a shim on the donor ESP.
pc_firmware() {
	local r
	D_FW=bios; D_ESP_DEV=
	for r in "${D_FSTAB[@]}"; do
		if [ "$(pc_f "$r" mount)" = /boot/efi ] && [ "$(pc_f "$r" type)" = vfat ]; then D_FW=uefi; D_ESP_DEV=$(pc_f "$r" dev); fi
	done
	for r in "${D_PART[@]}"; do
		case $(pc_f "$r" type) in ef|EF|"$PL_GPT_ESP"|"$(echo "$PL_GPT_ESP" | tr A-F a-f)") D_FW=uefi; [ -n "$D_ESP_DEV" ] || D_ESP_DEV=$(pc_f "$r" dev);; esac
	done
	GRUB_FROM_LIVE=0; GRUB_PKGS=-
	if [ "$D_FW" != "$R_FW" ]; then
		if [ "$FAMILY" = rhel ]; then
			# the same package names on CentOS 7 and RHEL/Rocky/Alma 8-10; grub2-tools (grub2-install,
			# grub2-mkconfig) is on every rhel already, as is efibootmgr on a uefi one
			if [ "$R_FW" = uefi ]; then GRUB_PKGS=grub2-efi-x64,shim-x64,efibootmgr; else GRUB_PKGS=grub2-pc,grub2-pc-modules; fi
			pc_warn "firmware change $D_FW -> $R_FW: grub2 for $R_FW (${GRUB_PKGS//,/ }) is installed into the migrated OS by dnf in postfix, from its own repositories: they must be reachable from the recipient (grub_pkgs=)"
		else
			GRUB_FROM_LIVE=1
			pc_warn "firmware change $D_FW -> $R_FW: grub for $R_FW is installed from the Live (grub_from_live=1); afterwards on the donor OS: apt install grub-$([ "$R_FW" = uefi ] && echo efi-amd64 || echo pc) and purge the other"
		fi
	fi
	if [ "$R_SB" = 1 ]; then
		[ "$D_FW" = uefi ] || pc_refuse "recipient has Secure Boot enabled and the donor has no ESP (bios): no shim to boot with; disable Secure Boot on the recipient"
		pc_warn "recipient has Secure Boot enabled: \\EFI\\*\\shimx64.efi on the donor ESP is assumed (not visible in the inventory)"
	fi
}

# --- device resolution on the donor ----------------------------------------------------
# pc_canon DEV: /dev/mapper/vg-lv -> /dev/vg/lv (lv record path); else DEV
pc_canon() {
	local r vg lv
	case $1 in /dev/mapper/*)
		for r in "${D_LV[@]}"; do
			vg=$(pc_f "$r" vg); lv=$(pc_f "$r" name)
			[ "/dev/mapper/${vg//-/--}-${lv//-/--}" = "$1" ] && { pc_f "$r" path; return 0; }
		done;;
	esac
	printf '%s\n' "$1"
}
# pc_md_of_member DEV: the md whose members list DEV (empty when none)
pc_md_of_member() {
	local r; for r in "${D_MD[@]}"; do pl_has "$(pc_f "$r" members)" "$1" && { pc_f "$r" dev; return 0; }; done; return 1
}
# pc_disk_of DEV: the donor disk that carries DEV (part, md -> first member, lv -> first pv)
pc_disk_of() {
	local dev r m; dev=$(pc_canon "$1")
	if r=$(pc_find D_PART dev "$dev"); then pc_f "$r" disk; return 0; fi
	# an md lives on every member: pick the member on the disk that sorts first,
	# which is the order pc_slots walks the partitions in (mdadm lists members in
	# the order they were added, which on a mirror is arbitrary)
	if r=$(pc_find D_MD dev "$dev"); then
		m=$(pc_f "$r" members | tr ',' '\n' | while IFS= read -r m; do [ -n "$m" ] && pc_disk_of "$m"; done | sort | head -1)
		[ -n "$m" ] && { echo "$m"; return 0; }
		return 1
	fi
	if r=$(pc_find D_LV path "$dev"); then
		r=$(pc_find D_VG name "$(pc_f "$r" vg)") || return 1
		m=$(pc_f "$r" pvs); pc_disk_of "${m%%,*}"; return 0
	fi
	return 1
}
# pc_content DEV: what lives on DEV -> CT_KIND=fs|swap|pv|esp|none, CT_REC=its record
pc_content() {
	local r
	CT_KIND=none; CT_REC=
	if CT_REC=$(pc_find D_PV dev "$1"); then CT_KIND=pv; return 0; fi
	if CT_REC=$(pc_find D_SWAP dev "$1"); then CT_KIND=swap; return 0; fi
	if CT_REC=$(pc_find D_FS dev "$1"); then
		CT_KIND=fs
		if [ "$(pc_f "$CT_REC" type)" = vfat ]; then
			[ "$1" = "$D_ESP_DEV" ] && CT_KIND=esp
			if r=$(pc_find D_PART dev "$1"); then case $(pc_f "$r" type) in ef|EF|"$PL_GPT_ESP") CT_KIND=esp;; esac; fi
		fi
		return 0
	fi
	CT_REC=; return 1
}
# pc_mount_of DEV: fstab mount point of DEV (canonical), "-" when not mounted
pc_mount_of() {
	local r dev; dev=$(pc_canon "$1")
	for r in "${D_FSTAB[@]}"; do
		[ "$(pc_canon "$(pc_f "$r" dev)")" = "$dev" ] && { pc_f "$r" mount -; return 0; }
	done
	echo -
}
# pc_fstab_dev MOUNT: the (canonical) device fstab mounts at MOUNT, "" when none
pc_fstab_dev() {
	local r; for r in "${D_FSTAB[@]}"; do [ "$(pc_f "$r" mount)" = "$1" ] && { pc_canon "$(pc_f "$r" dev)"; return 0; }; done; return 1
}
# pc_part_bytes PARTREC: size of a donor partition in bytes (sectors x its disk's lsec)
pc_part_bytes() {
	local lsec; lsec=$(pl_lookup "$D" disk dev "$(pc_f "$1" disk)" lsec); : "${lsec:=512}"
	echo $(( $(pc_f "$1" size 0) * lsec ))
}

# --- R3: base disk ------------------------------------------------------------------------
# the disk that carries /boot (or the bootable flag, or /), in that order
pc_base_disk() {
	local dev r
	ROOT_DEV=$(pc_fstab_dev /) || pc_refuse "donor fstab has no / entry"
	[ "$ROOT_DEV" != - ] || pc_refuse "donor fstab / entry does not resolve to a device"
	BOOT_DEV=$(pc_fstab_dev /boot) || BOOT_DEV=
	[ "$BOOT_DEV" != - ] || BOOT_DEV=
	BASE=
	[ -z "$BOOT_DEV" ] || BASE=$(pc_disk_of "$BOOT_DEV") || BASE=
	if [ -z "$BASE" ]; then
		for r in "${D_PART[@]}"; do [ "$(pc_f "$r" bootable 0)" = 1 ] && { BASE=$(pc_f "$r" disk); break; }; done
	fi
	[ -n "$BASE" ] || BASE=$(pc_disk_of "$ROOT_DEV") || BASE=
	[ -n "$BASE" ] || pc_refuse "cannot tell the donor's base disk (no /boot, no bootable flag, / on $ROOT_DEV not on a disk)"
	BASE_REC=$(pc_find D_DISK dev "$BASE") || pc_refuse "donor disk $BASE has no disk record"
	D_LABEL=$(pc_f "$BASE_REC" pttype dos); D_PTUUID=$(pc_f "$BASE_REC" ptuuid -)
	case $D_LABEL in dos|gpt) ;; *) pc_refuse "donor base disk $BASE has partition table '$D_LABEL': only dos and gpt are supported";; esac
	dev=$(pc_canon "$ROOT_DEV")
	if r=$(pc_find D_LV path "$dev"); then ROOT_VG=$(pc_f "$r" vg); ROOT_LV=$(pc_f "$r" name); else ROOT_VG=; ROOT_LV=; fi
}

# --- R3: slots, in donor order --------------------------------------------------------
# One slot per donor partition that carries something (fs, swap, PV, ESP),
# directly or through an md. Members of an md already mapped are mirrors and
# are dropped; partitions of other disks with their own content are appended.
pc_add_slot() {   # PARTREC VOLDEV KIND NOTES
	local rec=$1 vol=$2 kind=$3 notes=$4 size msize
	size=$(pl_mib_up "$(pc_part_bytes "$rec")")
	if [ "$vol" != "$(pc_f "$rec" dev)" ]; then   # md-backed: max(member, md size) (R5)
		msize=$(pl_lookup "$D" md dev "$vol" size); msize=$(pl_mib_up "${msize:-0}")
		size=$(pl_max "$size" "$msize")
	fi
	# raid=1: the slot carries an md array of exactly the donor's volume size (R16)
	[ "$RAID" != 1 ] || [ "$kind" = esp ] || size=$(( size + PL_MD_OFF ))
	S_SRC+=("$(pc_f "$rec" dev)"); S_ONUM+=("$(pc_f "$rec" num 0)"); S_KIND+=("$kind")
	S_VOL+=("$vol"); S_SIZE+=("$size"); S_UUID+=("$(pc_f "$rec" partuuid -)"); S_NAME+=("$(pc_f "$rec" name -)")
	S_NOTES+=("$notes"); S_MOUNT+=("$(pc_mount_of "$vol")"); S_PTYPE+=("$(pc_f "$rec" ptype primary)")
}
pc_slots() {
	local -A MAPPED=()
	S_SRC=(); S_ONUM=(); S_KIND=(); S_VOL=(); S_SIZE=(); S_UUID=(); S_NAME=(); S_NOTES=(); S_MOUNT=(); S_PTYPE=()
	D_HAS_LOGICAL=0
	local r md dev kind extra=() ordered
	# donor partitions come in disk order, then by start (physical order)
	mapfile -t ordered < <(for r in "${D_PART[@]}"; do printf '%s\t%s\t%s\n' "$(pc_f "$r" disk)" "$(printf '%012d' "$(pc_f "$r" start 0)")" "$r"; done | sort -t $'\t' -k1,1 -k2,2 | cut -f3-)
	for r in "${ordered[@]}"; do
		dev=$(pc_f "$r" dev)
		[ "$(pc_f "$r" ptype)" != extended ] || { [ "$(pc_f "$r" disk)" = "$BASE" ] && D_HAS_LOGICAL=1; continue; }
		[ "$(pc_f "$r" type)" != "$PL_GPT_BIOS" ] || continue    # the donor's bios_grub: we make our own (R5)
		if md=$(pc_md_of_member "$dev"); then
			[ -z "${MAPPED[$md]:-}" ] || continue            # mirror of a mapped array
			pc_content "$md"; kind=$CT_KIND
			[ "$kind" != none ] && MAPPED[$md]=1
		else
			pc_content "$dev"; kind=$CT_KIND; md=$dev
		fi
		case $kind in
			none) [ "$(pc_f "$r" disk)" = "$BASE" ] && [ "$(pc_f "$r" fstype -)" != - ] && pc_warn "donor partition $dev ($(pc_f "$r" fstype)) has nothing reloca.to can carry: skipped"; continue;;
			pv) [ "$(pc_f "$r" disk)" = "$BASE" ] || [ -n "$(pc_f "$CT_REC" vg)" ] || continue;;
		esac
		if [ "$(pc_f "$r" disk)" = "$BASE" ]; then pc_add_slot "$r" "$md" "$kind" ""
		else pc_add_slot "$r" "$md" "$kind" "from-other-disk"; extra+=("$dev($kind)"); fi
	done
	[ ${#S_SRC[@]} -gt 0 ] || pc_refuse "no partition with a filesystem, swap or PV on donor disk $BASE"
	[ ${#extra[@]} -eq 0 ] || pc_warn "partitions of other donor disks are appended to $T_DEV as extra slots: ${extra[*]}"
	# a VG must sit on exactly one PV in v1 (R3: PV spanning disks is refused)
	local vg pvs n
	for r in "${D_VG[@]}"; do
		vg=$(pc_f "$r" name); pvs=$(pc_f "$r" pvs); n=$(echo "$pvs" | tr ',' '\n' | grep -c .)
		[ "$n" -le 1 ] || pc_refuse "VG $vg spans $n PVs ($pvs): a VG on more than one PV/disk is not supported in v1"
	done
	# a VG with the same name on a recipient disk that is NOT the target (R7)
	for r in "${R_DISK[@]}"; do
		[ "$(pc_f "$r" dev)" != "$T_DEV" ] && [ "$(pc_f "$r" dev)" != "$T2_DEV" ] || continue
		case $(pc_f "$r" usage) in lvm:*)
			vg=$(pc_f "$r" usage); vg=${vg#lvm:}
			pc_find D_VG name "$vg" >/dev/null && pc_refuse "VG $vg already exists on recipient disk $(pc_f "$r" dev), which is not the target: rename or wipe it first";;
		esac
	done
}

# --- R4: partition table label ---------------------------------------------------------
pc_label() {
	local i n=0
	LABEL=$D_LABEL
	[ "$T_SIZE" -le $((2 * PL_TIB)) ] || LABEL=gpt
	[ "$R_FW" != uefi ] || LABEL=gpt
	case ${O[label]} in gpt|dos) LABEL=${O[label]};; esac
	# an ESP is needed on a uefi recipient; the donor's is kept as a slot (R5)
	ESP_SLOT=-; for i in "${!S_SRC[@]}"; do [ "${S_KIND[$i]}" = esp ] && ESP_SLOT=$i; done
	NEED_ESP_NEW=0; [ "$R_FW" != uefi ] || [ "$ESP_SLOT" != - ] || NEED_ESP_NEW=1
	n=$(( ${#S_SRC[@]} + NEED_ESP_NEW ))
	if [ "$LABEL" = dos ] && [ $n -gt 4 ]; then
		[ "${O[label]}" != dos ] || pc_refuse "$n partitions do not fit a dos label (4 primaries, logical partitions are never written): drop label=dos"
		LABEL=gpt; pc_warn "$n slots need more than 4 primary partitions: gpt instead of dos (no extended/logical partitions)"
	fi
	if [ "$LABEL" = dos ] && [ "$T_SIZE" -gt $((2 * PL_TIB)) ]; then pc_warn "label=dos on a $(human "$T_SIZE") disk: only the first 2 TiB are usable"; fi
	if [ "$LABEL" = dos ] && [ "$R_FW" = uefi ]; then pc_warn "label=dos on a uefi recipient: firmware may refuse to boot an MBR disk"; fi
	[ "$LABEL" = "$D_LABEL" ] || pc_warn "partition table $D_LABEL -> $LABEL: new label-id and partition GUIDs, PARTUUID= references are rewritten to UUID="
	[ -z "${O[boot-part]}" ] || pc_refuse "boot-part=${O[boot-part]}: a new /boot slot is not implemented yet (M3); migrate with the donor's layout"
}

# --- R5/R6: physical order, sizes, numbers, sfdisk lines ------------------------------
pc_slot_type() {   # KIND -> sfdisk type for LABEL
	if [ "$LABEL" = gpt ]; then
		case $1 in fs) echo "$PL_GPT_FS";; swap) echo "$PL_GPT_SWAP";; pv) echo "$PL_GPT_LVM";; esp) echo "$PL_GPT_ESP";; bios_grub) echo "$PL_GPT_BIOS";; esac
	else
		case $1 in fs) echo 83;; swap) echo 82;; pv) echo 8e;; esp) echo ef;; esac
	fi
}
pc_layout() {
	local i best=-1 bestsize=-1 sum=0 pos n next used=() vg line
	# the new ESP slot (uefi recipient, donor without one) goes physically first
	ESP_NEW_IDX=-
	if [ "$NEED_ESP_NEW" = 1 ]; then
		S_SRC+=(-); S_ONUM+=(0); S_KIND+=(esp); S_VOL+=(-); S_SIZE+=($((512 * PL_MIB))); S_UUID+=(-); S_NAME+=(-)
		S_NOTES+=(esp-new); S_MOUNT+=(/boot/efi); S_PTYPE+=(primary)
		ESP_NEW_IDX=$(( ${#S_SRC[@]} - 1 )); ESP_SLOT=$ESP_NEW_IDX
		pc_warn "donor has no ESP: a new 512 MiB vfat ESP is created and added to fstab (see [identity])"
	fi
	[ "$R_FW" != bios ] || [ "$ESP_SLOT" = - ] || pc_warn "donor ESP ${S_SRC[$ESP_SLOT]} is kept as a slot on the bios recipient (harmless, /boot/efi stays in fstab)"
	# the slot holding / (directly or through its VG)
	ROOT_SLOT=-
	for i in "${!S_SRC[@]}"; do
		if [ "${S_VOL[$i]}" = "$(pc_canon "$ROOT_DEV")" ]; then ROOT_SLOT=$i; fi
		if [ -n "$ROOT_VG" ] && [ "${S_KIND[$i]}" = pv ]; then
			vg=$(pl_lookup "$D" pv dev "${S_VOL[$i]}" vg); [ "$vg" = "$ROOT_VG" ] && ROOT_SLOT=$i
		fi
	done
	[ "$ROOT_SLOT" != - ] || pc_refuse "the donor root $ROOT_DEV is not on any migrated slot"
	# elastic = the slot backing the largest fs/PV; ties go to root's slot
	for i in "${!S_SRC[@]}"; do
		case ${S_KIND[$i]} in fs|pv) ;; *) continue;; esac
		if [ "${S_SIZE[$i]}" -gt "$bestsize" ] || { [ "${S_SIZE[$i]}" -eq "$bestsize" ] && [ "$i" = "$ROOT_SLOT" ]; }; then best=$i; bestsize=${S_SIZE[$i]}; fi
	done
	ELASTIC=$best
	# physical order
	ORDER=()
	[ "$ESP_NEW_IDX" = - ] || ORDER+=("$ESP_NEW_IDX")
	for i in "${!S_SRC[@]}"; do [ "$i" != "$ESP_NEW_IDX" ] && [ "$i" != "$ELASTIC" ] && { [ "${S_KIND[$i]}" = esp ] || [ "${S_MOUNT[$i]}" = /boot ]; } && ORDER+=("$i"); done
	for i in "${!S_SRC[@]}"; do [ "$i" != "$ESP_NEW_IDX" ] && [ "$i" != "$ELASTIC" ] && [ "${S_KIND[$i]}" != esp ] && [ "${S_MOUNT[$i]}" != /boot ] && ORDER+=("$i"); done
	ORDER+=("$ELASTIC")
	# sizes: first usable MiB, last MiB kept free (GPT backup header), bios_grub 1 MiB
	BIOS_GRUB=-; [ "$R_FW" = bios ] && [ "$LABEL" = gpt ] && BIOS_GRUB=128
	USABLE=$(( $(pl_mib_down "$T_SIZE") - 2 * PL_MIB ))
	[ "$LABEL" != dos ] || [ "$T_SIZE" -le $((2 * PL_TIB)) ] || USABLE=$(( 2 * PL_TIB - 2 * PL_MIB ))
	[ "$BIOS_GRUB" = - ] || USABLE=$(( USABLE - PL_MIB ))
	for i in "${ORDER[@]}"; do [ "$i" = "$ELASTIC" ] || sum=$(( sum + S_SIZE[i] )); done
	ELASTIC_SIZE=$(( USABLE - sum ))
	[ "$ELASTIC_SIZE" -gt $(( RAID == 1 ? PL_MD_OFF : 0 )) ] || pc_refuse "the fixed slots alone need $(human "$sum") ($sum bytes) but $T_DEV has $(human "$USABLE") usable: short by $(( sum - USABLE )) bytes ($(human $(( sum - USABLE ))))"
	S_SIZE[ELASTIC]=$ELASTIC_SIZE
	# the volume a slot carries: the slot itself, or the md array inside it (raid=1)
	for i in "${!S_SRC[@]}"; do
		if [ "$RAID" = 1 ] && [ "${S_KIND[$i]}" != esp ]; then S_VSIZE[i]=$(( S_SIZE[i] - PL_MD_OFF )); else S_VSIZE[i]=${S_SIZE[$i]}; fi
	done
	[ "$R_FW" != bios ] || [ -n "$BOOT_DEV" ] || [ "$T_SIZE" -le $((2 * PL_TIB)) ] || pc_warn "bios boot without a separate /boot on a $(human "$T_SIZE") disk: grub must read / beyond 2 TiB (fine on gpt with a modern grub); a separate /boot needs boot-part= (M3)"
	# numbers (R6): gpt keeps the donor's; dos (and an ex-extended layout) counts in physical order
	RENUMBER=0
	if [ "$LABEL" = dos ] || [ "$D_HAS_LOGICAL" = 1 ]; then
		n=0; for i in "${ORDER[@]}"; do n=$((n+1)); S_NUM[i]=$n; done
	else
		for i in "${ORDER[@]}"; do [ "${S_ONUM[$i]}" -gt 0 ] && [ -z "${S_NOTES[$i]}" ] && { S_NUM[i]=${S_ONUM[$i]}; used[S_ONUM[i]]=1; }; done
		next=1
		for i in "${ORDER[@]}"; do
			[ -z "${S_NUM[$i]:-}" ] || continue
			while [ -n "${used[$next]:-}" ] || [ "$next" = 128 ]; do next=$((next+1)); done
			S_NUM[i]=$next; used[next]=1
		done
	fi
	for i in "${ORDER[@]}"; do
		[ "${S_ONUM[$i]}" -gt 0 ] && [ "${S_NUM[$i]}" != "${S_ONUM[$i]}" ] && RENUMBER=1
		[ "$i" = "$ELASTIC" ] && S_NOTES[i]="${S_NOTES[$i]:+${S_NOTES[$i]},}elastic"
		if [ "${S_ONUM[$i]}" -gt 0 ] && [ "${S_NUM[$i]}" != "${S_ONUM[$i]}" ]; then S_NOTES[i]="${S_NOTES[$i]:+${S_NOTES[$i]},}renumbered%20${S_ONUM[$i]}->${S_NUM[$i]}"; fi
	done
	[ "$RENUMBER" = 0 ] || pc_warn "partitions are renumbered (physical order on $LABEL): PARTUUID= and /dev/${T_DEV##*/}N references are rewritten to UUID="
	NUMBERING_CHANGED=0; { [ "$RENUMBER" = 1 ] || [ "$LABEL" != "$D_LABEL" ] || [ "$RAID" = 1 ]; } && NUMBERING_CHANGED=1
	[ "$RAID" != 1 ] || pc_warn "raid=1: the filesystems live on md arrays, not on partitions: PARTUUID= references are rewritten to UUID="
	# label id and partition GUIDs: kept from a gpt donor, else derived from its label id (R4)
	if [ "$LABEL" = gpt ]; then
		if [ "$D_LABEL" = gpt ]; then LABEL_ID=$D_PTUUID; else LABEL_ID=$(pl_uuid_from "$D_PTUUID" label); fi
		LABEL_ID2=$(pl_uuid_from "$D_PTUUID" label2)      # the mirror's own table id (R16)
	else
		if [ "$D_LABEL" = dos ]; then LABEL_ID=$D_PTUUID; else LABEL_ID=0x$(echo "$D_PTUUID:label" | sha256sum | cut -c1-8); fi
		LABEL_ID2=0x$(echo "$D_PTUUID:label2" | sha256sum | cut -c1-8)
	fi
	# bootable flag on dos: the /boot slot, else root's slot
	BOOT_SLOT=-; for i in "${!S_SRC[@]}"; do [ "${S_MOUNT[$i]}" = /boot ] && BOOT_SLOT=$i; done
	[ "$BOOT_SLOT" != - ] || BOOT_SLOT=$ROOT_SLOT
	# positions and the sfdisk lines, physical order; under raid=1 the same lines for
	# disk2 (own GUIDs) and one mdadm --create per data slot (R16)
	SFDISK=(); SFDISK2=(); MDLINES=(); MD_DEVS=; ESP2_TARGET=-
	local hn mduuid line2 geom
	hn=$(pc_f "$D_OS" hostname reloca); hn=${hn%%.*}; hn=${hn:0:24}
	pos=$PL_MIB
	if [ "$BIOS_GRUB" != - ]; then
		geom="start=$((pos / T_LSEC)), size=$((PL_MIB / T_LSEC)), type=$PL_GPT_BIOS"
		SFDISK+=("$(pl_partdev "$T_DEV" 128) : $geom, uuid=$(pl_uuid_from "$D_PTUUID" 128), name=\"BIOS boot\"")
		[ "$RAID" != 1 ] || SFDISK2+=("$(pl_partdev "$T2_DEV" 128) : $geom, uuid=$(pl_uuid_from "$D_PTUUID" 128:2), name=\"BIOS boot\"")
		pos=$((pos + PL_MIB))
	fi
	for i in "${ORDER[@]}"; do
		S_PART[i]=$(pl_partdev "$T_DEV" "${S_NUM[$i]}"); S_PART2[i]=-
		S_TARGET[i]=${S_PART[$i]}
		geom="start=$((pos / T_LSEC)), size=$((S_SIZE[i] / T_LSEC)), type=$(pc_slot_type "${S_KIND[$i]}")"
		line="${S_PART[$i]} : $geom"; line2=
		[ "$RAID" != 1 ] || { S_PART2[i]=$(pl_partdev "$T2_DEV" "${S_NUM[$i]}"); line2="${S_PART2[$i]} : $geom"; }
		if [ "$LABEL" = gpt ]; then
			if [ "$D_LABEL" = gpt ] && [ "${S_UUID[$i]}" != - ]; then line="$line, uuid=${S_UUID[$i]}"; else line="$line, uuid=$(pl_uuid_from "$D_PTUUID" "${S_NUM[$i]}")"; fi
			[ -z "$line2" ] || line2="$line2, uuid=$(pl_uuid_from "$D_PTUUID" "${S_NUM[$i]}:2")"
			[ "${S_NAME[$i]}" = - ] || { line="$line, name=\"${S_NAME[$i]}\""; [ -z "$line2" ] || line2="$line2, name=\"${S_NAME[$i]}\""; }
		else
			[ "$i" != "$BOOT_SLOT" ] || { line="$line, bootable"; [ -z "$line2" ] || line2="$line2, bootable"; }
		fi
		SFDISK+=("$line"); [ -z "$line2" ] || SFDISK2+=("$line2")
		if [ "$RAID" = 1 ]; then
			if [ "${S_KIND[$i]}" = esp ]; then
				ESP2_TARGET=${S_PART2[$i]}
			else
				S_TARGET[i]=/dev/md${S_NUM[$i]}
				# a donor md keeps its UUID (its mdadm.conf lines stay true); a new array gets a stable derived one
				mduuid=; [ "${S_VOL[$i]}" = "${S_SRC[$i]}" ] || mduuid=$(pl_lookup "$D" md dev "${S_VOL[$i]}" uuid)
				[ -n "$mduuid" ] || mduuid=$(pl_mduuid_from "$D_PTUUID" "${S_NUM[$i]}")
				# mdadm 4.3 refuses a ':' in --name; --homehost + a bare --name is stored as "host:N"
				MDLINES+=("mdadm --create ${S_TARGET[$i]} --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=$PL_MD_OFF_FLAG --homehost=$hn --name=${S_NUM[$i]} --uuid=$mduuid ${S_PART[$i]} ${S_PART2[$i]}")
				MD_DEVS="${MD_DEVS:+$MD_DEVS,}${S_TARGET[$i]}"
				S_NOTES[i]=$(pc_note "${S_NOTES[$i]}" raid1)
			fi
		fi
		pos=$((pos + S_SIZE[i]))
	done
	PMBR_BOOT=0; [ "$BIOS_GRUB" = - ] || PMBR_BOOT=1
}

# --- R7/R8: methods per volume, mkfs and lvm lines --------------------------------------
# pc_vol GROUP src kind fs size used method target tsize mount num notes
# GROUP orders the [volumes] rows: 0 pv (apply time), 1 mkswap/esp, 2 fs by
# size, 3 root last (R14).
pc_vol() {
	V_KEYS+=("$(printf '%d %020d' "$1" "$5")")
	V_ROWS+=("$(printf 'src=%s\tkind=%s\tfs=%s\tsize=%s\tused=%s\tmethod=%s\ttarget=%s\ttsize=%s\tmount=%s\tnum=%s\tnotes=%s' "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12:--}")")
}
pc_note() { printf '%s\n' "${1:+$1,}$2"; }   # append a note to a comma list
# pc_fs_method FSREC TSIZE IS_ROOT IS_ELASTIC TARGET: sets PC_M=block|files; refuses when nothing
# fits (sets a variable, not $(...): a refusal must exit the planner, not a capture subshell)
pc_fs_method() {
	local rec=$1 tsize=$2 isroot=$3 elastic=$4 target=$5 type fssize used min req m
	type=$(pc_f "$rec" type unknown); fssize=$(pc_f "$rec" fssize 0); used=$(pc_f "$rec" used 0); min=$(pc_f "$rec" min 0)
	case $type in
		ext2|ext3|ext4|xfs) ;;
		btrfs|ntfs|zfs|zfs_member|crypto_LUKS|luks|f2fs|reiserfs) pc_refuse "$(pc_f "$rec" dev) is $type: only ext2/3/4 and xfs are migrated in v1";;
		*) pc_refuse "$(pc_f "$rec" dev) has an unknown filesystem '$type'";;
	esac
	req=$(( $(pl_pct110 "$used") + 512 * PL_MIB )); [ "$min" -le "$req" ] || req=$min
	m=; if [ "$tsize" -ge "$fssize" ]; then m=block; else m=files; fi
	if [ "$isroot" = 1 ]; then
		case ${O[root]} in
			block) [ "$tsize" -ge "$fssize" ] || pc_refuse "root=block: $(pc_f "$rec" dev) ($type, $(human "$fssize")) does not fit $target ($(human "$tsize")): short by $(( fssize - tsize )) bytes ($(human $(( fssize - tsize ))))"; m=block;;
			files) m=files;;
		esac
	fi
	if [ "$m" = files ] && [ "$tsize" -lt "$req" ]; then
		pc_refuse "$(pc_f "$rec" dev) ($type, used $(human "$used")) needs $(human "$req") ($req bytes = used x 1.10 + 512 MiB$([ "$min" -gt 0 ] && echo ", min $(human "$min")")) for the file copy but $target$([ "$elastic" = 1 ] && echo " (elastic slot)") has $(human "$tsize") ($tsize bytes): short by $(( req - tsize )) bytes ($(human $(( req - tsize ))))"
	fi
	PC_M=$m
}
# pc_mkfs_line FSREC TARGET: the explicit mkfs command that reproduces the donor's fs (R8)
pc_mkfs_line() {
	local rec=$1 target=$2 type uuid label bs isz feats f n it iu l
	type=$(pc_f "$rec" type); uuid=$(pc_f "$rec" uuid); label=$(pc_f "$rec" label)
	bs=$(pc_f "$rec" bs 4096); isz=$(pc_f "$rec" isz 256); feats=$(pc_f "$rec" features)
	l=; [ -z "$label" ] || l=" -L $label"
	case $type in
		ext2|ext3|ext4)
			# runtime flags are not features mke2fs can set
			n=; for f in ${feats//,/ }; do case $f in needs_recovery|orphan_present) ;; *) n="$n,$f";; esac; done
			it=$(pc_f "$rec" inodes_total 0); iu=$(pc_f "$rec" inodes_used 0); iu=$(( iu + iu / 5 ))
			[ "$it" -ge "$iu" ] || it=$iu
			echo "mkfs.$type -F -U $uuid$l -b $bs -I $isz -N $it -O none${n} $target";;
		xfs)
			echo "mkfs.xfs -f -m crc=$(pl_has "$feats" CRC && echo 1 || echo 0),finobt=$(pl_has "$feats" FINOBT && echo 1 || echo 0),reflink=$(pl_has "$feats" REFLINK && echo 1 || echo 0),rmapbt=$(pl_has "$feats" RMAPBT && echo 1 || echo 0),bigtime=$(pl_has "$feats" BIGTIME && echo 1 || echo 0),inobtcount=$(pl_has "$feats" INOBTCNT && echo 1 || echo 0),uuid=$uuid -i sparse=$(pl_has "$feats" SPARSE_INODES && echo 1 || echo 0),nrext64=$(pl_has "$feats" NREXT64 && echo 1 || echo 0),size=$isz -n ftype=$(pl_has "$feats" FTYPE && echo 1 || echo 0),size=$(pc_f "$rec" dirbs 4096) -b size=$bs -s size=$(pc_f "$rec" ssz 512)$l $target";;
	esac
}
# pc_guard FSREC TARGET: "# guard:" comment — no donor feature newer than its oldest kernel
pc_guard() {
	local feats f need="" bad=0 kv
	feats=$(pc_f "$1" features)
	for f in ${feats//,/ }; do
		for kv in $PL_FEATURE_KERNEL; do
			[ "${kv%%:*}" = "$f" ] || continue
			need="${need:+$need,}$f:${kv#*:}"
			pl_kver_lt "$OLDEST_KVER" "${kv#*:}" && bad=1
		done
	done
	if [ "$bad" = 1 ]; then
		pc_warn "$(pc_f "$1" dev): feature set ($need) is newer than the oldest donor kernel $OLDEST_KVER: that kernel cannot mount it"
		echo "# guard: $2 $(pc_f "$1" type) oldest_kernel=$OLDEST_KVER needs=${need:-none} EXCEEDS"
	else
		echo "# guard: $2 $(pc_f "$1" type) oldest_kernel=$OLDEST_KVER needs=${need:-none} ok"
	fi
}
# pc_fs_volume src kind fsrec target tsize mount num notes elastic
pc_fs_volume() {
	local src=$1 kind=$2 rec=$3 target=$4 tsize=$5 mount=$6 num=$7 notes=$8 elastic=$9 m isroot=0 group=2 state
	[ "$mount" != / ] || { isroot=1; group=3; }
	pc_fs_method "$rec" "$tsize" "$isroot" "$elastic" "$target"; m=$PC_M
	[ "$m" != block ] || [ "$tsize" -le "$(pc_f "$rec" fssize 0)" ] || notes=$(pc_note "$notes" grow)
	state=$(pc_f "$rec" state clean)
	# online: a mounted filesystem is "not clean" by definition; the copy is taken frozen and is clean
	[ "$ONLINE" != 1 ] || [ "$state" != dirty ] || state=clean
	if [ "$ONLINE" = 1 ] && [ "$m" = files ]; then
		[ "$(pc_f "$D_HOST" tar 1)" != 0 ] || pc_refuse "on-line: $src ($(pc_f "$rec" type), $(human "$(pc_f "$rec" fssize 0)")) does not fit $target ($(human "$tsize")) and the donor has no tar for the file copy: install tar there, or give the recipient a disk the root fits on"
		pc_warn "on-line, $src by files: tar incremental passes (changes by mtime/ctime), the last one from the frozen filesystem; a hard link whose file changes during the copy becomes a separate file on the copy"
	fi
	case $state in dirty|errors)
		notes=$(pc_note "$notes" "$state")
		if [ "$m" = block ]; then pc_warn "$src ($(pc_f "$rec" type)) is $state on the donor: block copy with partclone -I, fsck/journal replay on the copy"
		else pc_warn "$src ($(pc_f "$rec" type)) is $state on the donor: the file copy mounts it ro without journal replay; check the result"; fi;;
	esac
	if [ "$m" = files ] && [ "$(pc_f "$rec" type)" != xfs ] && [ "$(pc_f "$rec" min -)" = - ]; then notes=$(pc_note "$notes" "min%20unknown"); fi
	[ "$m" != files ] || MKFS+=("$(pc_mkfs_line "$rec" "$target")")
	MKFS+=("$(pc_guard "$rec" "$target")")
	pc_vol "$group" "$src" "$kind" "$(pc_f "$rec" type)" "$(pc_f "$rec" fssize 0)" "$(pc_f "$rec" used -)" "$m" "$target" "$tsize" "$mount" "$num" "$notes"
	FEATURES="${FEATURES:+$FEATURES,}$target:$(pc_f "$rec" type):$(pl_enc "$(pc_f "$rec" masks -)")"
	[ "$mount" != / ] || ROOT_TARGET=$target
	[ "$mount" != /boot ] || BOOT_TARGET=$target
	MIG[$src]=UUID=$(pc_f "$rec" uuid)
}
pc_swap_volume() {   # src kind swaprec target tsize num notes
	local l=; [ -z "$(pc_f "$3" label)" ] || l=" -L $(pc_f "$3" label)"
	MKFS+=("mkswap -U $(pc_f "$3" uuid)$l $4")
	pc_vol 1 "$1" "$2" swap "$(pc_f "$3" size 0)" - mkswap "$4" "$5" swap "$6" "$7"
	SWAP_UUIDS="${SWAP_UUIDS:+$SWAP_UUIDS,}$(pc_f "$3" uuid)"
	MIG[$1]=UUID=$(pc_f "$3" uuid)
}
pc_pv_slot() {   # SLOTIDX: the PV, its VG and every LV (R7)
	local i=$1 pvrec vg pvuuid target tsize others=0 r name path size cap rootrec="" lvsize
	pvrec=$(pc_find D_PV dev "${S_VOL[$i]}"); vg=$(pc_f "$pvrec" vg); pvuuid=$(pc_f "$pvrec" uuid)
	target=${S_TARGET[$i]}; tsize=${S_VSIZE[$i]}
	[ -n "$vg" ] || pc_refuse "PV ${S_VOL[$i]} belongs to no VG"
	LVM+=("pvcreate -ff -y --uuid $pvuuid --norestorefile $target" "vgcreate $vg $target")
	pc_vol 0 "${S_VOL[$i]}" pv lvm "$(pc_f "$pvrec" size 0)" - pv "$target" "$tsize" - "${S_NUM[$i]}" "${S_NOTES[$i]}"
	MIG[${S_VOL[$i]}]=-
	for r in "${D_LV[@]}"; do
		[ "$(pc_f "$r" vg)" = "$vg" ] || continue
		name=$(pc_f "$r" name); path=$(pc_f "$r" path); size=$(pc_f "$r" size 0)
		if [ "$vg" = "$ROOT_VG" ] && [ "$name" = "$ROOT_LV" ]; then rootrec=$r; continue; fi
		pc_content "$path"
		case $CT_KIND in
			swap)
				cap=$(pl_max $((2 * PL_GIB)) $(( T_SIZE / 10 / PL_MIB * PL_MIB )))
				if [ "$size" -gt "$cap" ]; then pc_warn "swap LV $path $(human "$size") capped to $(human "$cap") (max of 2 GiB and 10% of the disk)"; size=$cap; fi
				LVM+=("lvcreate -y -n $name -L ${size}b $vg")
				pc_swap_volume "$path" lv "$CT_REC" "$path" "$size" - "$(pc_note "" swap-lv)";;
			fs)
				LVM+=("lvcreate -y -n $name -L ${size}b $vg")
				pc_fs_volume "$path" lv "$CT_REC" "$path" "$size" "$(pc_mount_of "$path")" - "" 0;;
			*) pc_refuse "LV $path carries no filesystem or swap (segtype $(pc_f "$r" segtype -)): not supported";;
		esac
		others=$(( others + size ))
	done
	if [ -n "$rootrec" ]; then
		lvsize=$(( (tsize - others - 4 * PL_MIB) / (4 * PL_MIB) * (4 * PL_MIB) ))
		[ "$lvsize" -gt 0 ] || pc_refuse "VG $vg: the non-root LVs alone need $(human "$others") but the PV slot $target has $(human "$tsize")"
		LVM+=("lvcreate -y -n $ROOT_LV -l 100%FREE $vg")
		pc_content "$(pc_f "$rootrec" path)"
		[ "$CT_KIND" = fs ] || pc_refuse "root LV $(pc_f "$rootrec" path) has no filesystem record"
		pc_fs_volume "$(pc_f "$rootrec" path)" lv "$CT_REC" "$(pc_f "$rootrec" path)" "$lvsize" / - "$(pc_note "" 100%FREE)" "$([ "$i" = "$ELASTIC" ] && echo 1 || echo 0)"
	else
		[ $(( others + 4 * PL_MIB )) -le "$tsize" ] || pc_refuse "VG $vg: its LVs need $(human $(( others + 4 * PL_MIB ))) but the PV slot $target has $(human "$tsize"): short by $(( others + 4 * PL_MIB - tsize )) bytes"
	fi
	for r in "${D_LV[@]}"; do [ "$(pc_f "$r" vg)" = "$vg" ] && { MIG[$(pc_f "$r" path)]=keep; MIG[/dev/mapper/${vg//-/--}-$(pc_f "$r" name | sed 's/-/--/g')]=keep; }; done
}
pc_methods() {
	local i rec r v volid esplabel espsize
	V_KEYS=(); V_ROWS=(); MKFS=(); LVM=(); FEATURES=; SWAP_UUIDS=; ESP_TARGET=-; ROOT_TARGET=-; BOOT_TARGET=-; ESP_NEW_UUID=
	# the oldest donor kernel, for the feature guard
	OLDEST_KVER=; for r in "${D_KERNEL[@]}"; do v=$(pc_f "$r" version 0.0); v=${v%%-*}; if [ -z "$OLDEST_KVER" ] || pl_kver_lt "$v" "$OLDEST_KVER"; then OLDEST_KVER=$v; fi; done
	: "${OLDEST_KVER:=unknown}"
	for i in "${ORDER[@]}"; do
		case ${S_KIND[$i]} in
			esp)
				if [ "$i" = "$ESP_NEW_IDX" ]; then
					volid=$(pl_uuid_from "$D_PTUUID" volid); volid=${volid:0:8}; ESP_NEW_UUID="${volid:0:4}-${volid:4:4}"
					esplabel=EFI; espsize=$((512 * PL_MIB))
					MKFS+=("mkfs.vfat -F32 -i $volid -n EFI ${S_TARGET[$i]}")
					pc_vol 1 - esp vfat "$espsize" - esp "${S_TARGET[$i]}" "${S_SIZE[$i]}" /boot/efi "${S_NUM[$i]}" "${S_NOTES[$i]}"
				else
					rec=$(pc_find D_FS dev "${S_VOL[$i]}")
					volid=$(pc_f "$rec" volid); [ -n "$volid" ] || { volid=$(pc_f "$rec" uuid); volid=${volid//-/}; }
					esplabel=$(pc_f "$rec" label); espsize=$(pc_f "$rec" fssize 0)
					MKFS+=("mkfs.vfat -F32 -i $volid${esplabel:+ -n $esplabel} ${S_TARGET[$i]}")
					pc_vol 1 "${S_VOL[$i]}" esp vfat "$espsize" "$(pc_f "$rec" used -)" esp "${S_TARGET[$i]}" "${S_SIZE[$i]}" "${S_MOUNT[$i]}" "${S_NUM[$i]}" "${S_NOTES[$i]}"
					MIG[${S_VOL[$i]}]=UUID=$(pc_f "$rec" uuid)
				fi
				ESP_TARGET=${S_TARGET[$i]}
				# raid=1: the same ESP (same volume id, so UUID= in fstab finds either) on disk2; postfix fills it (R16)
				if [ "$RAID" = 1 ]; then
					MKFS+=("mkfs.vfat -F32 -i $volid${esplabel:+ -n $esplabel} ${S_PART2[$i]}")
					pc_vol 1 - esp vfat "$espsize" - esp "${S_PART2[$i]}" "${S_SIZE[$i]}" - "${S_NUM[$i]}" esp-mirror
				fi;;
			swap)
				rec=$(pc_find D_SWAP dev "${S_VOL[$i]}")
				pc_swap_volume "${S_VOL[$i]}" "$([ "${S_VOL[$i]}" = "${S_SRC[$i]}" ] && echo swap || echo md)" "$rec" "${S_TARGET[$i]}" "${S_VSIZE[$i]}" "${S_NUM[$i]}" "${S_NOTES[$i]}";;
			fs)
				rec=$(pc_find D_FS dev "${S_VOL[$i]}")
				pc_fs_volume "${S_VOL[$i]}" "$([ "${S_VOL[$i]}" = "${S_SRC[$i]}" ] && echo part || echo md)" "$rec" "${S_TARGET[$i]}" "${S_VSIZE[$i]}" "${S_MOUNT[$i]}" "${S_NUM[$i]}" "${S_NOTES[$i]}" "$([ "$i" = "$ELASTIC" ] && echo 1 || echo 0)";;
			pv) pc_pv_slot "$i";;
		esac
		[ "${S_VOL[$i]}" = "${S_SRC[$i]}" ] || MIG[${S_SRC[$i]}]=member
	done
	for r in "${D_SWAPFILE[@]}"; do MIG[$(pc_f "$r" path)]=keep; done
	[ "$ROOT_TARGET" != - ] || pc_refuse "no volume is mounted at / after planning"
}

# --- R9: drivers the recipient needs in the donor's initramfs ------------------------------
pc_drivers() {
	local list d r nic pd pair found lacking unchecked=0 missing="" extras=",${O[driver]//-/_},"
	list=$(pc_f "$T_REC" drivers)
	if nic=$(pc_find R_NIC name "$R_BOOTNIC"); then list="$list,$(pc_f "$nic" driver)"; fi
	list="$list,${O[driver]}"
	DRIVERS=
	for d in ${list//,/ }; do
		d=${d//-/_}; [ -n "$d" ] && [ "$d" != - ] || continue
		case "$PL_GENERIC_DRIVERS" in *" $d "*) continue;; esac
		pl_has "$DRIVERS" "$d" || DRIVERS="${DRIVERS:+$DRIVERS,}$d"
	done
	[ ${#D_KERNEL[@]} -gt 0 ] || unchecked=1
	for r in "${D_KERNEL[@]}"; do [ "$(pc_f "$r" pci_drivers -)" != - ] || unchecked=1; done
	if [ "$unchecked" = 1 ]; then
		pc_warn "recipient modalias not checked against the donor kernels (no pci_drivers in the kernel records): drivers $DRIVERS are assumed present"
		return 0
	fi
	# a driver must resolve in every donor kernel; missing in all of them is a refusal (R9)
	for d in ${DRIVERS//,/ }; do
		found=0; lacking=
		for r in "${D_KERNEL[@]}"; do
			pd=$(pc_f "$r" pci_drivers); pair=0
			for kv in ${pd//,/ }; do
				[ "${kv%%:*}" != "$d" ] && [ "${kv#*:}" != "$d" ] && [ "${kv%%:*}" != "${d//_/-}" ] || pair=1
			done
			if [ "$pair" = 1 ]; then found=1; else lacking="$lacking $(pc_f "$r" version)"; fi
		done
		if [ "$found" = 0 ]; then
			case $extras in *",$d,"*) pc_warn "driver $d (from driver=) is in no donor kernel: it will be missing from the initramfs";; *) missing="$missing $d";; esac
		elif [ -n "$lacking" ]; then pc_warn "driver $d is missing in donor kernel(s):$lacking (present in the others)"; fi
	done
	[ -z "$missing" ] || pc_refuse "recipient driver(s)$missing are in no donor kernel ($(for r in "${D_KERNEL[@]}"; do printf '%s ' "$(pc_f "$r" version)"; done)): install the module in the donor OS first ($([ "$FAMILY" = rhel ] && echo "dnf install kernel-modules / kmod-<driver>" || echo "apt install linux-modules-extra-<version> or the vendor dkms package"))"
}

# --- R10: identity: every fstab/cmdline spec -> keep | -> NEW | remove | + LINE -------------
pc_ident_add() {   # SPEC ACTION (deduplicated on SPEC)
	local x; for x in "${IDENT[@]}"; do [ "${x%%$'\t'*}" != "$1" ] || return 0; done
	IDENT+=("$1"$'\t'"$2")
}
# pc_resolve SPEC DEV -> keep | -> NEWSPEC | MISSING   (DEV = the inventory's resolution of SPEC)
pc_resolve() {
	local spec=$1 dev m p
	dev=$(pc_canon "$2")
	case $spec in
		UUID=*|LABEL=*)
			[ "$dev" != - ] && [ -n "${MIG[$dev]:-}" ] && [ "${MIG[$dev]}" != member ] && [ "${MIG[$dev]}" != - ] && { echo keep; return; }
			echo MISSING;;
		PARTUUID=*)
			p=$(pl_lookup "$D" part partuuid "${spec#PARTUUID=}" dev)
			[ -n "$p" ] && [ -n "${MIG[$p]:-}" ] || { echo MISSING; return; }
			m=${MIG[$p]}
			case $m in member|-) echo MISSING;; keep) echo keep;;
				*) if [ "$NUMBERING_CHANGED" = 0 ]; then echo keep; else echo "-> $m"; fi;; esac;;
		/dev/*)
			[ "$dev" != - ] && [ -n "${MIG[$dev]:-}" ] || { echo MISSING; return; }
			m=${MIG[$dev]}
			case $m in keep) echo keep;; member|-) echo MISSING;; *) echo "-> $m";; esac;;
		*) echo keep;;
	esac
}
pc_identity() {
	local r spec dev mount act tok val key
	IDENT=()
	for r in "${D_FSTAB[@]}"; do
		spec=$(pc_f "$r" spec); dev=$(pc_f "$r" dev -); mount=$(pc_f "$r" mount -)
		case $spec in UUID=*|LABEL=*|PARTUUID=*|/dev/*) ;; *) pc_ident_add "$spec" keep; continue;; esac
		act=$(pc_resolve "$spec" "$dev")
		if [ "$act" = MISSING ]; then
			if [ "$(pc_f "$r" nofail 0)" = 1 ]; then act=remove; pc_warn "fstab entry $spec $mount has no target on the recipient: removed (nofail)"
			else pc_refuse "fstab entry $spec $mount has no target and no nofail: drop it on the donor or add nofail"; fi
		fi
		pc_ident_add "$spec" "$act"
	done
	for r in "${D_CMDLINE[@]}"; do
		val=$(pc_f "$r" value)
		for tok in $val; do
			case $tok in
				root=*|resume=*)
					key=${tok%%=*}; spec=${tok#*=}
					case $spec in UUID=*|LABEL=*|PARTUUID=*|/dev/*) ;; *) continue;; esac
					dev=$(pl_lookup "$D" fstab spec "$spec" dev); : "${dev:=$(pc_spec_dev "$spec")}"
					act=$(pc_resolve "$spec" "${dev:--}")
					if [ "$act" = MISSING ]; then
						if [ "$key" = root ]; then pc_refuse "cmdline $tok ($(pc_f "$r" source)) does not resolve to a migrated volume"; fi
						act=remove; pc_warn "cmdline $tok ($(pc_f "$r" source)) has no swap on the recipient: removed"
					fi
					case $act in "-> "*) act="-> $key=${act#-> }";; esac
					pc_ident_add "$tok" "$act";;
				rd.md.uuid=*|rd.md=*|rd.md.conf=*) pc_ident_add "$tok" remove;;
				rd.lvm.lv=*) pc_ident_add "$tok" keep;;
			esac
		done
	done
	# the new ESP's fstab line, the way each family's installer writes it
	if [ -n "$ESP_NEW_UUID" ]; then
		if [ "$FAMILY" = rhel ]; then pc_ident_add "UUID=$ESP_NEW_UUID" "+ /boot/efi vfat umask=0077,shortname=winnt 0 2"
		else pc_ident_add "UUID=$ESP_NEW_UUID" "+ /boot/efi vfat umask=0077 0 1"; fi
	fi
}
# pc_spec_dev SPEC: a device for a spec fstab does not list (cmdline-only resume=/dev/x, UUID=)
pc_spec_dev() {
	case $1 in
		/dev/*) printf '%s\n' "$1";;
		UUID=*) pl_lookup "$D" fs uuid "${1#UUID=}" dev | grep . || pl_lookup "$D" swap uuid "${1#UUID=}" dev | grep . || echo -;;
		LABEL=*) pl_lookup "$D" fs label "${1#LABEL=}" dev | grep . || pl_lookup "$D" swap label "${1#LABEL=}" dev | grep . || echo -;;
		PARTUUID=*) pl_lookup "$D" part partuuid "${1#PARTUUID=}" dev | grep . || echo -;;
		*) echo -;;
	esac
}

# --- the plan text (R11 postfix, R12 network, R13 verify, R14 volumes order) -----------------
pc_emit() {
	local i r line n esp=- sel=none files=0 lvmf=keep lvmd=keep ci=keep pins="" k=0 nics=() pci mac
	# network: every physical NIC (has a PCI address) sorted by it; the boot NIC is eth0
	for r in "${R_NIC[@]}"; do
		pci=$(pc_f "$r" pci); mac=$(pc_f "$r" mac); [ -n "$pci" ] && [ -n "$mac" ] || continue
		nics+=("$pci"$'\t'"$mac")
	done
	pins="${O[nic]}:$R_BOOTMAC"
	while IFS=$'\t' read -r pci mac; do
		[ -n "$pci" ] && [ "$mac" != "$R_BOOTMAC" ] || continue
		k=$((k+1)); pins="$pins,eth${k}x:$mac"
	done < <(printf '%s\n' "${nics[@]}" | sort)
	[ "$k" -eq 0 ] || pc_warn "recipient has $((k+1)) NICs: eth0 assignment depends on probe order; the udev pin (pins=) is best-effort"
	[ "$(pc_f "$D_OS" primary_nic -)" != - ] || pc_warn "donor primary NIC not detected: pass -o donor-nic=<iface> so its config is renamed to ${O[nic]}"
	# postfix decisions
	[ "$ESP_SLOT" = - ] || esp=${S_NUM[$ESP_SLOT]}
	for r in "${V_ROWS[@]}"; do [ "$(pc_f "$r" method)" != files ] || files=1; done
	case $(pc_f "$D_OS" selinux -) in enforcing|permissive) { [ "$files" = 1 ] || [ "$FAMILY" = rhel ]; } && sel=autorelabel;; esac
	[ "$(pc_f "$D_LVMCONF" devices_file 0)" != 1 ] || lvmd=delete
	{ [ "$(pc_f "$D_LVMCONF" filter -)" = - ] && [ "$(pc_f "$D_LVMCONF" global_filter -)" = - ]; } || lvmf=neutralise
	[ "$(pc_f "$D_OS" cloudinit 0)" != 1 ] || ci=${O[cloudinit]}
	# --- header and sections ---
	pc_header
	echo "[target]"
	echo "disk=$T_DEV id=$(pl_enc_sp "$T_ID") size=$T_DISKSIZE lsec=$T_LSEC psec=$T_PSEC ptuuid=$T_PTUUID head=-"
	echo "currently=$(pl_enc_sp "$T_USAGE")"
	line="label=$LABEL firmware=$R_FW bios_grub=$BIOS_GRUB esp=$esp driver=${DRIVERS:--} data=${O[data]} compress=${O[compress]}"
	[ "$PMBR_BOOT" = 0 ] || line="$line pmbr_boot=1"
	[ "$GRUB_FROM_LIVE" = 0 ] || line="$line grub_from_live=1"
	[ "$RAID" != 1 ] || line="$line raid=1"
	[ "$ONLINE" != 1 ] || line="$line mode=online"
	echo "$line"
	if [ "$RAID" = 1 ]; then
		# the mirror: the second disk's identity and fingerprint, the geometry both tables follow, the arrays
		echo "disk2=$T2_DEV id2=$(pl_enc_sp "$T2_ID") size2=$T2_SIZE ptuuid2=$T2_PTUUID head2=- geometry=$T_SIZE md=${MD_DEVS:--} esp2=$ESP2_TARGET"
		echo "currently2=$(pl_enc_sp "$T2_USAGE")"
	fi
	echo "[volumes]"
	printf '# %s\n' "src kind fs size used method target tsize mount num notes  (transfer order: small first, root last)"
	for i in "${!V_ROWS[@]}"; do printf '%s\t%s\n' "${V_KEYS[$i]}" "${V_ROWS[$i]}"; done | sort | cut -f2-
	echo "[sfdisk]"
	echo "label: $LABEL"
	echo "label-id: $LABEL_ID"
	echo "unit: sectors"
	echo "sector-size: $T_LSEC"
	printf '%s\n' "${SFDISK[@]}"
	if [ "$RAID" = 1 ]; then
		echo "[sfdisk2]"
		echo "label: $LABEL"
		echo "label-id: $LABEL_ID2"
		echo "unit: sectors"
		echo "sector-size: $T_LSEC"
		printf '%s\n' "${SFDISK2[@]}"
		echo "[md]"
		echo "# one array per data slot, members = the same partition number on both disks; an array is its slot minus $PL_MD_OFF_FLAG"
		printf '%s\n' "${MDLINES[@]}"
	fi
	echo "[lvm]"
	[ ${#LVM[@]} -eq 0 ] || printf '%s\n' "${LVM[@]}"
	echo "[mkfs]"
	[ ${#MKFS[@]} -eq 0 ] || printf '%s\n' "${MKFS[@]}"
	echo "[identity]"
	echo "# spec<TAB>keep | -> new spec | remove | + fstab line to add"
	[ ${#IDENT[@]} -eq 0 ] || printf '%s\n' "${IDENT[@]}"
	echo "[postfix]"
	line="family=$FAMILY initramfs=$(pc_f "$D_OS" initramfs -) grub=$([ "$R_FW" = uefi ] && echo x86_64-efi || echo i386-pc) bls=$(pc_f "$D_OS" bls 0) lvm_devices_file=$lvmd lvm_filter=$lvmf selinux=$sel cloudinit=$ci os_root=$ROOT_TARGET boot=$BOOT_TARGET esp=$ESP_TARGET"
	[ "$RAID" != 1 ] || line="$line raid=1 disk2=$T2_DEV esp2=$ESP2_TARGET mdadm=$(pc_f "$D_OS" mdadm -)"
	[ "$GRUB_PKGS" = - ] || line="$line grub_pkgs=$GRUB_PKGS"
	echo "$line"
	echo "[network]"
	echo "donor=$(pc_f "$D_OS" primary_nic -)/$(pc_f "$D_OS" primary_mac -)/$(pc_f "$D_OS" netcfg unknown) target=${O[nic]} mac=$R_BOOTMAC cmdline=net.ifnames=0%20biosdevname=0 pin=${O[nic-pin]}"
	echo "pins=$pins"
	echo "[verify]"
	n=0; for r in "${D_FSTAB[@]}"; do n=$((n+1)); done
	line="drivers=${DRIVERS:--} features=${FEATURES:--} fstab=$n swap=${SWAP_UUIDS:--} esp=$ESP_TARGET cmdline_forbid=rd.md.uuid,rd.md=,/dev/md"
	[ "$RAID" != 1 ] || line="$line md=${MD_DEVS:--} esp2=$ESP2_TARGET"
	echo "$line"
}

# ==============================================================================
# reading a plan back (check, apply, postfix, verify use these)
# ==============================================================================
# plan_section FILE NAME: the body of [NAME] without comment and blank lines
plan_section() { awk -v s="[$2]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && !/^#/ && !/^[ \t]*$/' "$1"; }
# plan_get FILE SECTION KEY: value of the first KEY=value token in [SECTION] (%20 left as is)
plan_get() {
	plan_section "$1" "$2" | awk -v k="$3=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }'
}
# plan_sfdisk FILE [SECTION]: "dev start size" (sectors) per partition line of [sfdisk] (or [sfdisk2])
plan_sfdisk() {
	plan_section "$1" "${2:-sfdisk}" | awk '
		$2 == ":" { dev = $1; start = size = ""
			for (i = 3; i <= NF; i++) { f = $i; sub(/,$/, "", f)
				if (index(f, "start=") == 1) start = substr(f, 7); if (index(f, "size=") == 1) size = substr(f, 6) }
			print dev, start, size }'
}

# plan_md FILE: "md memberA memberB" per [md] line (raid=1), nothing otherwise
plan_md() {
	plan_section "$1" md | awk '$1 == "mdadm" && $2 == "--create" { print $3, $(NF-1), $NF }'
}
# plan_md_arrays FILE: the mdadm.conf ARRAY line of every [md] array, as "mdadm --detail --scan"
# prints it (the stored name is "<homehost>:<name>")
plan_md_arrays() {
	plan_section "$1" md | awk '$1 == "mdadm" && $2 == "--create" {
		name = ""; uuid = ""; host = ""
		for (i = 4; i <= NF; i++) { if (index($i, "--name=") == 1) name = substr($i, 8); if (index($i, "--uuid=") == 1) uuid = substr($i, 8); if (index($i, "--homehost=") == 1) host = substr($i, 12) }
		printf "ARRAY %s metadata=1.2 name=%s%s UUID=%s\n", $3, (host != "" ? host ":" : ""), name, uuid }'
}

# --- plan_check [PLANFILE]: recompute what apply would trust ---------------------------------
plan_check() {
	local plan=${1:-$RUN/plan} p=() inv cur disk size lsec label dev start psize end prev=0 prevdev="" line n
	local raid disk2 size2 geom sec thisdisk thissize md a b
	local -A PSIZE=() LVSZ=() LVFREE=() VGPV=() VGOTH=() MKT=() IDK=() PNUM=()
	[ -r "$plan" ] || die "$EX_PLAN" "no plan to check at $plan (run 'reloca.to -s plan DONOR' first)"
	grep -q '^\[target\]' "$plan" && grep -q '^\[volumes\]' "$plan" && grep -q '^\[sfdisk\]' "$plan" || die "$EX_PLAN" "$plan is not a reloca.to plan (missing [target]/[volumes]/[sfdisk])"
	# 1. the inventories the plan was computed from must be the ones on disk now
	inv=$(sed -n 's/^# inv_sha256=\([^ ]*\).*/\1/p' "$plan" | head -1)
	if [ -r "$RUN/donor.inv" ] && [ -r "$RUN/recipient.inv" ]; then
		cur="$(sha256sum "$RUN/donor.inv" | cut -c1-64):$(sha256sum "$RUN/recipient.inv" | cut -c1-64)"
		if [ "$inv" != "$cur" ]; then
			if [ "$(opt force 0)" = 1 ]; then warn "inventories changed since the plan was made (inv_sha256 differs): continuing because force=1"
			else p+=("inventories changed since the plan was made (inv_sha256 differs): re-run 'reloca.to -s plan DONOR', or force=1 to override"); fi
		fi
	elif [ "$(opt force 0)" = 1 ]; then warn "no inventories in $RUN to compare the plan against (force=1)"
	else p+=("no $RUN/{donor,recipient}.inv to compare the plan against (force=1 to skip)"); fi
	disk=$(plan_get "$plan" target disk); size=$(plan_get "$plan" target size); lsec=$(plan_get "$plan" target lsec); label=$(plan_get "$plan" target label)
	[ -n "$disk" ] && [ -n "$size" ] && [ -n "$lsec" ] || die "$EX_PLAN" "[target] lacks disk=/size=/lsec="
	raid=$(plan_get "$plan" target raid); [ "$raid" = 1 ] || raid=0
	disk2=$(plan_get "$plan" target disk2); size2=$(plan_get "$plan" target size2); geom=$(plan_get "$plan" target geometry)
	if [ "$raid" = 1 ]; then
		[ -n "$disk2" ] && [ -n "$size2" ] || die "$EX_PLAN" "[target] raid=1 lacks disk2=/size2="
		[ "$disk2" != "$disk" ] || p+=("[target] raid=1: disk2 is the same disk as disk")
		grep -q '^\[sfdisk2\]' "$plan" && grep -q '^\[md\]' "$plan" || p+=("[target] raid=1 but the plan has no [sfdisk2]/[md] sections")
		# both tables fit the smaller disk: that is the geometry the planner used
		[ -n "$geom" ] || geom=$(( size < size2 ? size : size2 ))
	fi
	# 2. partitions: on the target disk, MiB-aligned, inside the disk minus the last MiB, no overlap
	#    (raid=1: [sfdisk2] on disk2 the same way, and the two tables must agree per partition number)
	for sec in sfdisk sfdisk2; do
		if [ "$sec" = sfdisk ]; then thisdisk=$disk; thissize=$size; [ "$raid" != 1 ] || thissize=$geom
		else [ "$raid" = 1 ] || continue; thisdisk=$disk2; thissize=$geom; fi
		[ "$(plan_section "$plan" "$sec" | sed -n 's/^label: //p')" = "$label" ] || p+=("[target] label=$label but [$sec] says label: $(plan_section "$plan" "$sec" | sed -n 's/^label: //p')")
		[ "$(plan_section "$plan" "$sec" | sed -n 's/^sector-size: //p')" = "$lsec" ] || p+=("[$sec] sector-size differs from [target] lsec=$lsec")
		prev=0; prevdev=
		while read -r dev start psize; do
			case $dev in "$thisdisk"*) ;; *) p+=("[$sec] $dev is not a partition of $thisdisk");; esac
			[ -n "$start" ] && [ -n "$psize" ] || { p+=("[$sec] $dev: start= or size= missing"); continue; }
			[ $(( start * lsec % PL_MIB )) -eq 0 ] || p+=("[$sec] $dev: start $start is not MiB-aligned")
			[ "$psize" -gt 0 ] || p+=("[$sec] $dev: size 0")
			end=$(( (start + psize) * lsec ))
			[ "$end" -le $(( thissize - PL_MIB )) ] || p+=("[$sec] $dev ends at $end, beyond the disk minus the last MiB ($(( thissize - PL_MIB )))")
			[ -z "${PSIZE[$dev]:-}" ] || p+=("[$sec] $dev listed twice")
			PSIZE[$dev]=$(( psize * lsec ))
			n=${dev#"$thisdisk"}; n=${n#p}
			[ "$label" != dos ] || [ "${n:-0}" -le 4 ] 2>/dev/null || p+=("[$sec] $dev: dos label allows partitions 1-4 only (no logical partitions)")
			if [ "$sec" = sfdisk ]; then PNUM[$n]="$start:$psize"
			elif [ "${PNUM[$n]:-}" != "$start:$psize" ]; then p+=("[sfdisk2] $dev (start $start, size $psize) differs from partition $n of [sfdisk] (${PNUM[$n]:-absent}): a mirror needs identical tables"); fi
		done < <(plan_sfdisk "$plan" "$sec")
		while read -r dev start psize; do
			[ -n "$start" ] && [ -n "$psize" ] || continue
			[ $(( start * lsec )) -ge "$prev" ] || p+=("[$sec] $dev (start $start) overlaps $prevdev")
			prev=$(( (start + psize) * lsec )); prevdev=$dev
		done < <(plan_sfdisk "$plan" "$sec" | sort -k2,2n)
	done
	if [ "$raid" = 1 ] && [ "$(plan_sfdisk "$plan" | wc -l)" != "$(plan_sfdisk "$plan" sfdisk2 | wc -l)" ]; then p+=("[sfdisk] and [sfdisk2] differ in partition count"); fi
	# 2b. raid=1: every [md] array mirrors one partition of each disk; its size is the member minus the data offset
	while read -r md a b; do
		[ -n "$md" ] && [ -n "$a" ] && [ -n "$b" ] || { p+=("[md] a line without /dev/mdN and two members"); continue; }
		[ -n "${PSIZE[$a]:-}" ] || { p+=("[md] $md: member $a is not in [sfdisk]"); continue; }
		[ -n "${PSIZE[$b]:-}" ] || { p+=("[md] $md: member $b is not in [sfdisk2]"); continue; }
		case $a in "$disk"*) ;; *) p+=("[md] $md: first member $a is not on $disk");; esac
		case $b in "$disk2"*) ;; *) p+=("[md] $md: second member $b is not on $disk2");; esac
		[ "${PSIZE[$a]}" = "${PSIZE[$b]}" ] || p+=("[md] $md: members $a and $b differ in size")
		[ -z "${PSIZE[$md]:-}" ] || p+=("[md] $md listed twice")
		PSIZE[$md]=$(( PSIZE[$a] - PL_MD_OFF ))
	done < <(plan_md "$plan")
	[ "$raid" != 1 ] || [ "$(plan_md "$plan" | wc -l)" -gt 0 ] || p+=("[md] is empty under raid=1")
	[ "$raid" = 1 ] || [ "$(plan_md "$plan" | wc -l)" -eq 0 ] || p+=("[md] lines without raid=1 in [target]")
	# 3. lvm: LV sizes as apply will create them
	while read -r line; do
		# shellcheck disable=SC2086  # the lvm line is split into words on purpose
		set -- $line
		case $1 in
			vgcreate) VGPV[$2]=$3;;
			# lvcreate -y -n NAME -L SIZEb VG | lvcreate -y -n NAME -l 100%FREE VG
			lvcreate) if [ "$5" = -L ]; then LVSZ[$7/$4]=${6%b}; VGOTH[$7]=$(( ${VGOTH[$7]:-0} + ${6%b} )); elif [ "$5" = -l ]; then LVFREE[$7/$4]=1; fi;;
		esac
	done < <(plan_section "$plan" lvm)
	# 4. volumes: every target exists with the same size; the method fits
	local src kind fs vsize used method target tsize lvsize vg pv rows=0 mkfsn=0
	while read -r line; do
		rows=$((rows+1))
		src=$(pl_field "$line" src); kind=$(pl_field "$line" kind); fs=$(pl_field "$line" fs); vsize=$(pl_field "$line" size); used=$(pl_field "$line" used)
		method=$(pl_field "$line" method); target=$(pl_field "$line" target); tsize=$(pl_field "$line" tsize)
		if [ "$kind" = lv ]; then
			vg=${target#/dev/}; vg=${vg%%/*}; pv=${VGPV[$vg]:-}
			[ -n "$pv" ] || { p+=("[volumes] $target: no vgcreate for VG $vg in [lvm]"); continue; }
			[ -n "${PSIZE[$pv]:-}" ] || { p+=("[lvm] VG $vg on $pv, which is not in [sfdisk]"); continue; }
			if [ -n "${LVSZ[${target#/dev/}]:-}" ]; then lvsize=${LVSZ[${target#/dev/}]}
			elif [ -n "${LVFREE[${target#/dev/}]:-}" ]; then lvsize=$(( (PSIZE[$pv] - ${VGOTH[$vg]:-0} - 4 * PL_MIB) / (4 * PL_MIB) * (4 * PL_MIB) ))
			else p+=("[volumes] $target: no lvcreate in [lvm]"); continue; fi
			[ "$tsize" = "$lvsize" ] || p+=("[volumes] $target tsize=$tsize but [lvm] makes it $lvsize")
		else
			[ -n "${PSIZE[$target]:-}" ] || { p+=("[volumes] $src -> $target: not in [sfdisk]$([ "$raid" = 1 ] && echo ', [sfdisk2] or [md]')"); continue; }
			[ "$tsize" = "${PSIZE[$target]}" ] || p+=("[volumes] $target tsize=$tsize but [sfdisk]$([ "$raid" = 1 ] && echo '/[md]') makes it ${PSIZE[$target]}")
		fi
		case $method in
			block|mkswap|esp) [ "$tsize" -ge "$vsize" ] || p+=("[volumes] $src ($method) $vsize bytes does not fit $target ($tsize)");;
			files) [ "$used" != - ] || { p+=("[volumes] $src (files) has no used= size"); continue; }
				[ "$tsize" -ge $(( $(pl_pct110 "$used") + 512 * PL_MIB )) ] || p+=("[volumes] $src (files) needs $(( $(pl_pct110 "$used") + 512 * PL_MIB )) bytes (used x 1.10 + 512 MiB), $target has $tsize");;
			pv) ;;
			*) p+=("[volumes] $src: unknown method '$method'");;
		esac
		case $method in files|mkswap|esp) MKT[$target]=need;; *) MKT[$target]=none;; esac
		: "$fs"
	done < <(plan_section "$plan" volumes)
	[ "$rows" -gt 0 ] || p+=("[volumes] is empty")
	# 5. mkfs: exactly one line per files/mkswap/esp volume, none for block/pv
	while read -r line; do
		# shellcheck disable=SC2086  # the mkfs line is split into words on purpose
		set -- $line; target=${*: -1}; mkfsn=$((mkfsn+1))
		case ${MKT[$target]:-} in
			need) MKT[$target]=seen;; seen) p+=("[mkfs] $target has two mkfs lines");;
			none) p+=("[mkfs] $target is a block/pv volume and must not be formatted");;
			*) p+=("[mkfs] $target is not a [volumes] target");;
		esac
	done < <(plan_section "$plan" mkfs)
	for target in "${!MKT[@]}"; do [ "${MKT[$target]}" != need ] || p+=("[mkfs] no mkfs/mkswap line for $target"); done
	# 6. identity covers every device spec of the donor fstab
	if [ -r "$RUN/donor.inv" ]; then
		while read -r line; do IDK[${line%%$'\t'*}]=1; done < <(plan_section "$plan" identity)
		while read -r line; do
			src=$(pl_field "$line" spec)
			case $src in UUID=*|LABEL=*|PARTUUID=*|/dev/*) [ -n "${IDK[$src]:-}" ] || p+=("[identity] has no line for fstab spec $src");; esac
		done < <(pl_records "$RUN/donor.inv" fstab)
	fi
	# the sizes table
	say "plan $plan: target $disk ($(human "$size"), label $label)$([ "$raid" = 1 ] && echo " + $disk2 ($(human "$size2")) as md RAID1, $(plan_md "$plan" | wc -l) arrays")"
	{
		echo "src method target tsize size used mount notes"
		while read -r line; do
			echo "$(pl_field "$line" src) $(pl_field "$line" method) $(pl_field "$line" target) $(human "$(pl_field "$line" tsize)") $(human "$(pl_field "$line" size)") $([ "$(pl_field "$line" used)" = - ] && echo - || human "$(pl_field "$line" used)") $(pl_field "$line" mount) $(pl_field "$line" notes)"
		done < <(plan_section "$plan" volumes)
	} | awk '{ printf "  %-22s %-7s %-22s %8s %8s %8s %-10s %s\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
	say "sfdisk: $(plan_sfdisk "$plan" | wc -l) partitions$([ "$raid" = 1 ] && echo " x 2 disks, md: $(plan_md "$plan" | wc -l) arrays"), lvm: $(plan_section "$plan" lvm | wc -l) commands, mkfs: $mkfsn lines"
	if [ ${#p[@]} -gt 0 ]; then
		for line in "${p[@]}"; do echo "$(_tag) check: $line"; log "check: $line"; done
		die "$EX_PLAN" "plan check failed: ${#p[@]} problem(s), first: ${p[0]}"
	fi
	say "plan check passed"
}

# ==============================================================================
# plan_build DISK — the driver's plan phase: inventories + options -> $RUN/plan
# ==============================================================================
plan_build() {
	local disk=${1:-auto} d=$RUN/donor.inv r=$RUN/recipient.inv args=() k v rc reason line tdisk head
	[ -r "$d" ] || die "$EX_ENV" "no donor inventory at $d (the inventory phase has not run)"
	[ -r "$r" ] || die "$EX_ENV" "no recipient inventory at $r (the inventory phase has not run)"
	for k in label root data compress driver nic donor-nic nic-pin boot-part cloudinit bootorder force raid; do
		v=$(opt "$k"); [ -z "$v" ] || args+=("$k=$v")
	done
	v=${LIVE_ID:-$(live_build_id)}
	args+=("reloca=$(reloca_version)" "live=${v:--}" "date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
	say "planning $disk from $d and $r${args[*]:+ (${args[*]})}"
	plan_compute "$d" "$r" "$disk" "${args[@]}" > "$RUN/plan.new" 2> "$RUN/plan.warn"; rc=$?
	while read -r line; do
		case $line in WARN:\ *) warn "${line#WARN: }";; ERROR:\ *) ;; *) echo "$(_tag) $line";; esac
	done < "$RUN/plan.warn"
	if [ "$rc" -ne 0 ]; then
		reason=$(sed -n 's/^# ERROR: //p' "$RUN/plan.new" | tail -1)
		mv -f "$RUN/plan.new" "$RUN/plan.refused" 2>/dev/null || true
		die "$EX_PLAN" "${reason:-planner failed (exit $rc)}"
	fi
	# the first-MiB fingerprint of the real target (R1): the pure core never opens a device
	tdisk=$(plan_get "$RUN/plan.new" target disk)
	if [ -b "$tdisk" ]; then
		head=$(dd if="$tdisk" bs=1M count=1 2>/dev/null | sha256sum | cut -c1-64)
		[ -z "$head" ] || sed -i "1,/^currently=/s|head=-|head=sha256:$head|" "$RUN/plan.new"
	fi
	tdisk=$(plan_get "$RUN/plan.new" target disk2)
	if [ -n "$tdisk" ] && [ -b "$tdisk" ]; then
		head=$(dd if="$tdisk" bs=1M count=1 2>/dev/null | sha256sum | cut -c1-64)
		[ -z "$head" ] || sed -i "s|head2=-|head2=sha256:$head|" "$RUN/plan.new"
	fi
	mv -f "$RUN/plan.new" "$RUN/plan"
	plan_summary "$RUN/plan"
}

# plan_summary PLAN: one screen for the operator (labels in Russian, keys as in the file)
plan_summary() {
	local plan=$1 line k v
	say "план записан: $plan${DRY:+ (dry)}"
	sed -n '1s/^# reloca.to plan  //p' "$plan" | awk '{
		d = ""; r = ""
		for (i = 1; i <= NF; i++) { if (index($i, "donor=") == 1) side = "d"; if (index($i, "recipient=") == 1) side = "r"
			if (side == "d") d = d " " $i; else r = r " " $i }
		gsub(/%20/, " ", d); gsub(/%20/, " ", r)
		printf "  донор:     %s\n  реципиент: %s\n", substr(d, 8), substr(r, 12) }'
	line=$(plan_section "$plan" target | sed -n '1p'); k=; for v in $line; do k="$k ${v//%20/ }"; done
	echo "  диск:     $k"
	echo "  сейчас:    $(plan_get "$plan" target currently | sed 's/%20/ /g') (будет стёрто)"
	line=$(plan_section "$plan" target | sed -n '3p'); echo "  разметка:  ${line//%20/ }"
	if [ "$(plan_get "$plan" target raid)" = 1 ]; then
		echo "  зеркало:   $(plan_get "$plan" target disk2) ($(human "$(plan_get "$plan" target size2)")), сейчас: $(plan_get "$plan" target currently2 | sed 's/%20/ /g') (будет стёрто); md RAID1: $(plan_get "$plan" target md | tr ',' ' ')"
	fi
	echo "  тома (порядок передачи):"
	{
		echo "src fs size(used) method target tsize mount notes"
		while read -r line; do
			v=$(pl_field "$line" used); [ "$v" = - ] || v="($(human "$v"))"; [ "$v" != - ] || v=
			echo "$(pl_field "$line" src) $(pl_field "$line" fs) $(human "$(pl_field "$line" size)")$v $(pl_field "$line" method) $(pl_field "$line" target) $(human "$(pl_field "$line" tsize)") $(pl_field "$line" mount) $(pl_field "$line" notes | sed 's/%20/ /g')"
		done < <(plan_section "$plan" volumes)
	} | awk '{ n = $1; f = $2; s = $3; m = $4; t = $5; ts = $6; mp = $7; $1=$2=$3=$4=$5=$6=$7=""; sub(/^ +/, ""); printf "    %-20s %-5s %-16s %-6s %-20s %8s  %-10s %s\n", n, f, s, m, t, ts, mp, $0 }'
	echo "  lvm: $(plan_section "$plan" lvm | wc -l) команд, mkfs: $(plan_section "$plan" mkfs | grep -vc '^#') строк, identity: $(plan_section "$plan" identity | wc -l) спек"
	echo "  postfix:   $(plan_section "$plan" postfix)"
	echo "  network:   $(plan_section "$plan" network | tr '\n' ' ')"
	grep '^# WARN: ' "$plan" | sed 's/^# WARN: /  WARN: /'
	echo "  далее: ${EDITOR:-vi} $plan  →  reloca.to -s check  →  reloca.to -s apply"
}
