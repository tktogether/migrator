#!/bin/bash
# lib/bootstrap.sh — make sure both Lives carry the tools a migration needs,
# installing what is missing from the mirror at runtime (the image is not
# rebuilt for migrator). Sourced by bin/migrator after common.sh and ssh.sh;
# defines functions and defaults only, nothing runs at source time.
#
#   bootstrap_local [SET...]   this box: check binaries, apt-get what is missing; SET = base (default), grub
#   bootstrap_donor            the donor through the ssh master (set "donor"), then version parity
#   bootstrap_donor_online     on-line migration: no apt; a tmpfs at $DONOR_RUN (/run is noexec)
#                              with migrator-agent in it, same version as ours; records the
#                              donor's compressors (donor.tool.zstd/lz4)
#   bootstrap_missing SET      print the missing binaries/dirs of SET, one per line (tests use it)
#   tool_version NAME          first x.y[.z] token of NAME's version banner (empty when absent)
#
# Package sets (what apt installs when a binary of the set is missing):
#   base   partclone xfsprogs tmux pv   -> partclone.xfs, mkfs.xfs/xfs_db/xfs_repair, tmux, pv
#   grub   grub2-common grub-pc-bin grub-efi-amd64-bin grub-common  (firmware change, deb family)
#   donor  partclone xfsprogs           (the donor only reads: no tmux, no pv, no grub)
# Everything else in the lists (lz4 zstd mdadm sfdisk sgdisk lsblk blkid wipefs mkswap
# pvcreate lsinitramfs dumpe2fs resize2fs tar) ships in the full Live already.
#
# Read from the driver: RUN DRY OPT[offline] OPT[force]; state keys written:
# tool.<name>, donor.tool.<name>. Exit codes: EX_ENV (2) when something is still
# missing after apt, or when tool versions differ between the sides (force=1 warns).

# --- what is missing (self-contained: rsh_fn ships it to the donor) ----------------
bootstrap_missing() {
	local set=${1:-base} need d
	case $set in
		base)  need="partclone.extfs partclone.xfs mkfs.xfs xfs_db xfs_repair tmux pv lz4 zstd mdadm sfdisk sgdisk lsblk blkid wipefs mkswap pvcreate lsinitramfs" ;;
		grub)  need="grub-install grub-probe /usr/lib/grub/i386-pc /usr/lib/grub/x86_64-efi" ;;
		donor) need="partclone.extfs partclone.xfs xfs_db lz4 zstd mdadm sfdisk lsblk blkid dumpe2fs resize2fs pvs tar" ;;
		boottest) need="qemu-system-x86_64 qemu-img" ;;
		*) echo "bootstrap_missing: unknown set '$set'" >&2; return 2 ;;
	esac
	for d in $need; do
		case $d in
			/*) [ -d "$d" ] || echo "$d" ;;
			*)  command -v "$d" >/dev/null 2>&1 || echo "$d" ;;
		esac
	done
}
# binary -> package(s). grub is one indivisible set: grub-install needs the
# platform dirs to have anything to install.
_bootstrap_pkg_of() {
	case $1 in
		partclone.*)                       echo partclone ;;
		mkfs.xfs|xfs_*)                    echo xfsprogs ;;
		tmux)                              echo tmux ;;
		pv)                                echo pv ;;
		grub-install|grub-probe|/usr/lib/grub/*) echo "grub2-common grub-pc-bin grub-efi-amd64-bin grub-common" ;;
		lz4)                               echo lz4 ;;
		zstd)                              echo zstd ;;
		mdadm)                             echo mdadm ;;
		sgdisk)                            echo gdisk ;;
		qemu-system-x86_64)                echo qemu-system-x86 ;;
		qemu-img)                          echo qemu-utils ;;
		pvcreate|pvs)                      echo lvm2 ;;
		sfdisk|lsblk|blkid|wipefs|mkswap)  echo util-linux ;;
		lsinitramfs)                       echo initramfs-tools ;;
		dumpe2fs|resize2fs)                echo e2fsprogs ;;
		tar)                               echo tar ;;
	esac
}
_bootstrap_pkgs_for() {   # missing items -> sorted unique package list, one line
	local m
	for m in "$@"; do _bootstrap_pkg_of "$m"; done | tr ' ' '\n' | grep . | sort -u | xargs
}

# --- versions (self-contained: shipped to the donor) ---------------------------------
# Banners differ per tool ("Partclone : v0.3.48 ($Format:%h$)", "*** LZ4 command
# line interface 64-bits v1.10.0 ..."), so parity compares the first x.y[.z] token.
tool_version() {
	local out
	command -v "$1" >/dev/null 2>&1 || { echo; return 0; }
	case $1 in
		partclone.*)     out=$("$1" -v 2>&1) ;;
		lz4|zstd)        out=$("$1" --version 2>&1) ;;
		mkfs.xfs|xfs_*)  out=$("$1" -V 2>&1) ;;
		tmux|pv)         out=$("$1" -V 2>&1) ;;
		*)               out=$("$1" --version 2>&1) ;;
	esac
	echo "$out" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}
_bootstrap_versions() {   # name=version lines for the tools whose parity matters
	local t
	for t in partclone.extfs partclone.xfs lz4 mkfs.xfs; do echo "$t=$(tool_version "$t")"; done
}
_bootstrap_record_versions() {
	local t
	for t in partclone.extfs partclone.xfs lz4 mkfs.xfs tmux pv; do state_set "tool.$t" "$(tool_version "$t")"; done
}

# --- apt, mirror only ---------------------------------------------------------------
# /etc/apt/sources.list also lists security.debian.org, which a DC often cannot
# reach; a one-line list handed to apt with -o Dir::Etc::SourceList keeps update
# from failing on it. The mirror and codename come from the Live's own release
# file so a Live built for another suite keeps working. Self-contained: the donor
# runs its own copy and may be a different Live build.
_bootstrap_sources_line() {
	local rf codename mirror
	rf=$(live_release_file)
	codename=$(sed -n 's/^CODENAME=//p' "$rf" 2>/dev/null)
	[ -n "$codename" ] || codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null)
	mirror=$(sed -n 's/^MIRROR=//p' "$rf" 2>/dev/null)
	echo "deb ${mirror:-http://deb.debian.org/debian} ${codename:-bookworm} main contrib non-free non-free-firmware"
}
# _bootstrap_apt_opts LIST [protect]: the Debian partclone package carries its own
# partclone.extfs (0.3.36) and would overwrite the custom 0.3.48 the image ships;
# --path-exclude keeps dpkg from unpacking that one file (the untracked custom
# binary survives; dpkg's file list still records the path, so every later apt
# call that touches partclone must repeat the option, and partclone must never
# be reinstalled or removed in-session). Only when the custom binary is really
# there: excluding it on an image without one would leave no partclone.extfs.
_bootstrap_apt_opts() {
	local o="-o Dir::Etc::SourceList=$1 -o Dir::Etc::SourceParts=-"
	[ -n "${2:-}" ] && o="$o -o DPkg::Options::=--path-exclude=/usr/sbin/partclone.extfs"
	echo "$o"
}
# _bootstrap_apt_local PKGS: update, install (one retry after dpkg --configure -a,
# which is what a package left half-configured by an earlier interrupted run
# needs), clean (the root is tmpfs: every cached .deb is RAM).
_bootstrap_apt_local() {
	local pkgs=$1 list=$RUN/sources.list opts protect=
	mkdir -p "$RUN"
	_bootstrap_sources_line > "$list"
	[ -e /usr/sbin/partclone.extfs ] && protect=y
	opts=$(_bootstrap_apt_opts "$list" "$protect")
	run_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -q update" \
		|| warn "apt-get update failed (mirror unreachable?), trying the install anyway"
	if ! run_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -y --no-install-recommends install $pkgs"; then
		warn "apt-get install failed, retrying once after dpkg --configure -a"
		run dpkg --configure -a || true
		run_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -y --no-install-recommends install $pkgs" \
			|| die "$EX_ENV" "apt-get install $pkgs failed on this box (mirror down? use -o offline=1 to go without)"
	fi
	run apt-get clean || true
}
_bootstrap_apt_donor() {
	local pkgs=$1 list=$DONOR_RUN/sources.list line opts protect=
	line=$(rsh_fn _bootstrap_sources_line)
	# the line never holds a quote (mirror URL, suite, components): plain single
	# quotes keep the echoed runbook readable
	rrun_sh "mkdir -p $DONOR_RUN && echo '$line' > $list" || die "$EX_ENV" "cannot write $list on the donor"
	rsh test -e /usr/sbin/partclone.extfs && protect=y
	opts=$(_bootstrap_apt_opts "$list" "$protect")
	rrun_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -q update" \
		|| warn "apt-get update failed on the donor (mirror unreachable?), trying the install anyway"
	if ! rrun_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -y --no-install-recommends install $pkgs"; then
		warn "apt-get install failed on the donor, retrying once after dpkg --configure -a"
		rrun dpkg --configure -a || true
		rrun_sh "DEBIAN_FRONTEND=noninteractive apt-get $opts -y --no-install-recommends install $pkgs" \
			|| die "$EX_ENV" "apt-get install $pkgs failed on the donor (mirror down? use -o offline=1 to go without)"
	fi
	rrun apt-get clean || true
}

# --- degradation without a mirror ----------------------------------------------------
# offline=1 is a promise to live without the packages; the exact consequences
# are spelled out here and enforced later (plan refuses XFS, transfer runs
# without pv, the driver stays in the foreground without tmux).
_bootstrap_offline_warn() {
	local where=$1 m core=
	shift
	for m in "$@"; do
		case $m in
			partclone.xfs|mkfs.xfs|xfs_db|xfs_repair) ;;
			pv)   warn "offline=1, $where: no pv, the files method shows no progress/ETA" ;;
			tmux) warn "offline=1, $where: no tmux, the run stays in the foreground and a dropped ssh session kills it" ;;
			grub-*|/usr/lib/grub/*) ;;
			*)    core="$core $m" ;;
		esac
	done
	case " $* " in *" partclone.xfs "*|*" xfs_db "*|*" xfs_repair "*|*" mkfs.xfs "*)
		warn "offline=1, $where: no partclone.xfs/xfsprogs, donors with XFS filesystems will be refused" ;;
	esac
	case " $* " in *" grub-install "*|*" /usr/lib/grub/"*)
		warn "offline=1, $where: no grub from apt, a firmware change (UEFI<->BIOS) will be refused" ;;
	esac
	[ -z "$core" ] || warn "offline=1, $where: core tools missing, apply/transfer will refuse:$core"
}

# --- entry points --------------------------------------------------------------------
bootstrap_local() {
	local -a sets=("$@") missing
	[ ${#sets[@]} -gt 0 ] || sets=(base)
	local s pkgs
	mapfile -t missing < <(for s in "${sets[@]}"; do bootstrap_missing "$s"; done)
	if [ ${#missing[@]} -eq 0 ]; then
		say "tools present on this box (${sets[*]})"
		_bootstrap_record_versions
		return 0
	fi
	say "missing on this box (${sets[*]}): ${missing[*]}"
	if [ "$(opt offline)" = 1 ]; then
		_bootstrap_offline_warn "this box" "${missing[@]}"
		_bootstrap_record_versions
		return 0
	fi
	pkgs=$(_bootstrap_pkgs_for "${missing[@]}")
	[ -n "$pkgs" ] || die "$EX_ENV" "no package known for: ${missing[*]}"
	say "installing on this box: $pkgs"
	_bootstrap_apt_local "$pkgs"
	mapfile -t missing < <(for s in "${sets[@]}"; do bootstrap_missing "$s"; done)
	if [ ${#missing[@]} -gt 0 ]; then
		if [ -n "$DRY" ]; then warn "(dry) still missing on this box: ${missing[*]}"
		else die "$EX_ENV" "still missing on this box after apt: ${missing[*]}"; fi
	fi
	_bootstrap_record_versions
}

# An ssh failure must not read as "nothing missing": the probe's output is
# checked together with its status.
_bootstrap_donor_missing() {
	local out
	out=$(rsh_fn bootstrap_missing donor) || die "$EX_ENV" "cannot check the donor's tools (ssh to $DONOR_HOST failed)"
	printf '%s' "$out"
}
bootstrap_donor() {
	local -a missing
	local pkgs
	mapfile -t missing < <(_bootstrap_donor_missing)
	if [ ${#missing[@]} -eq 0 ]; then
		say "tools present on the donor"
	else
		say "missing on the donor: ${missing[*]}"
		if [ "$(opt offline)" = 1 ]; then
			_bootstrap_offline_warn "donor" "${missing[@]}"
		else
			pkgs=$(_bootstrap_pkgs_for "${missing[@]}")
			[ -n "$pkgs" ] || die "$EX_ENV" "no package known for: ${missing[*]}"
			say "installing on the donor: $pkgs"
			_bootstrap_apt_donor "$pkgs"
			mapfile -t missing < <(_bootstrap_donor_missing)
			if [ ${#missing[@]} -gt 0 ]; then
				if [ -n "$DRY" ]; then warn "(dry) still missing on the donor: ${missing[*]}"
				else die "$EX_ENV" "still missing on the donor after apt: ${missing[*]}"; fi
			fi
		fi
	fi
	_bootstrap_parity
}

# Same version on both ends of a partclone/lz4 pipe: image formats are stable,
# but a different build has not been proven against ours, and a mismatch found
# here costs a minute, one found in transfer costs the whole copy. One side
# lacking partclone.xfs (offline on that side) is only a warning: XFS volumes are
# then refused by the plan, everything else still works.
_bootstrap_parity() {
	local report t lv dv bad='' same=''
	report=$(rsh_fn _bootstrap_versions,tool_version) || die "$EX_ENV" "cannot read tool versions on the donor (ssh to $DONOR_HOST failed)"
	for t in partclone.extfs partclone.xfs lz4; do
		lv=$(tool_version "$t")
		dv=$(echo "$report" | sed -n "s/^$t=//p")
		state_set "donor.tool.$t" "$dv"
		if [ "$lv" = "$dv" ]; then
			[ -n "$lv" ] && same="$same $t=$lv"
		elif [ "$t" = partclone.xfs ] && { [ -z "$lv" ] || [ -z "$dv" ]; }; then
			warn "partclone.xfs only on one side (this box ${lv:-none}, donor ${dv:-none}): XFS donors will be refused"
		else
			bad="$bad $t(${lv:-none}/${dv:-none})"
		fi
	done
	[ -z "$same" ] || say "tool versions match:$same"
	[ -n "$bad" ] || return 0
	if [ "$(opt force)" = 1 ]; then
		warn "tool versions differ (this box/donor):$bad, continuing because force=1"
	else
		die "$EX_ENV" "tool versions differ (this box/donor):$bad; use the same Live build on both sides or pass -o force=1"
	fi
}

# --- the on-line donor -----------------------------------------------------------------
# Nothing is installed and nothing on the donor's disks changes: the agent (one
# static binary) is copied over the master into a small tmpfs of its own under
# /run (/run itself is noexec on Debian). Idempotent: a later phase that
# reconnects finds it there (gone with a reboot of the donor, copied again).
MIGRATOR_AGENT=${MIGRATOR_AGENT:-}
bootstrap_agent_path() {   # where this box's migrator-agent is: beside the driver and libs (installed), in the tree (dev), or on PATH
	local here; here=$(dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")")
	if [ -n "$MIGRATOR_AGENT" ] && [ -x "$MIGRATOR_AGENT" ]; then echo "$MIGRATOR_AGENT"; return 0; fi
	for f in /usr/local/sbin/migrator-agent "$MIGRATOR_LIB/migrator-agent" /usr/lib/migrator/migrator-agent \
	         "$MIGRATOR_LIB/../agent/migrator-agent" "$here/migrator-agent" "$here/../agent/migrator-agent"; do
		[ -x "$f" ] && { readlink -f "$f"; return 0; }
	done
	command -v migrator-agent 2>/dev/null
}
bootstrap_donor_online() {
	local agent ver dver tools t
	agent=$(bootstrap_agent_path) || die "$EX_ENV" "no migrator-agent on this box (the tarball ships it as bin/migrator-agent; in the tree: make agent)"
	ver=$("$agent" version 2>/dev/null) || die "$EX_ENV" "$agent does not run here"
	MIGRATOR_AGENT=$agent; export MIGRATOR_AGENT
	state_set agent.path "$agent"; state_set agent.version "$ver"
	if [ -n "$DRY" ]; then
		echo "(dry) donor: mount -t tmpfs -o size=16m,mode=0700 tmpfs $DONOR_RUN; cat > $DONOR_RUN/agent < $agent"
		return 0
	fi
	rrun_sh "mkdir -p $DONOR_RUN && { mountpoint -q $DONOR_RUN || mount -t tmpfs -o size=16m,mode=0700 tmpfs $DONOR_RUN; }" \
		|| die "$EX_ENV" "cannot prepare the tmpfs $DONOR_RUN on the donor"
	dver=$(rsh sh -c "$DONOR_RUN/agent version 2>/dev/null" </dev/null) || dver=
	if [ "$dver" != "$ver" ]; then
		say "copying migrator-agent $ver ($(du -h "$agent" | cut -f1)) to the donor's $DONOR_RUN/agent"
		rsh_sh "cat > $DONOR_RUN/agent.new && chmod 0700 $DONOR_RUN/agent.new && mv -f $DONOR_RUN/agent.new $DONOR_RUN/agent" < "$agent" \
			|| die "$EX_ENV" "cannot copy the agent to the donor's $DONOR_RUN"
		dver=$(rsh sh -c "$DONOR_RUN/agent version" </dev/null) || die "$EX_ENV" "the agent does not run on the donor ($DONOR_RUN/agent version failed)"
		[ "$dver" = "$ver" ] || die "$EX_ENV" "the agent on the donor says $dver, ours is $ver"
	else
		say "migrator-agent $ver is already on the donor ($DONOR_RUN/agent)"
	fi
	# what can compress the stream on the donor (transfer picks from these)
	# shellcheck disable=SC2016  # $t expands on the donor
	tools=$(rsh sh -c 'for t in zstd lz4 gzip tar rsync; do command -v $t >/dev/null 2>&1 && echo "$t=1" || echo "$t=0"; done' </dev/null)
	for t in zstd lz4 gzip tar rsync; do state_set "donor.tool.$t" "$(echo "$tools" | sed -n "s/^$t=//p")"; done
	say "donor probe: $(rsh sh -c "$DONOR_RUN/agent probe" </dev/null | grep -E '^(tracefs|bpf)=' | tr '\n' ' ')tools: $(echo "$tools" | tr '\n' ' ')"
}
