#!/bin/bash
# lib/target.sh — the migrated system on the recipient's disk, mounted where
# postfix and verify can work on it. One place decides WHAT is mounted WHERE,
# so both phases (and cleanup) agree. Sourced after common.sh and plan.sh;
# defines functions and defaults only.
#
#   target_mount rw|ro [binds]   mount the target tree at $TARGET_MNT from the plan's
#                                [volumes] (mount=/… rows, shallowest first); "binds"
#                                adds /dev /proc /sys /run and resolv.conf for a chroot
#   target_umount                undo it (safe to call twice)
#   target_chroot CMD ARGS...    run a command inside the tree (echoed like run)
#   target_chroot_sh 'pipeline'  same, through sh -c inside the tree
#   target_is_mounted            0 when $TARGET_MNT carries the target root
#   target_dev_of MOUNTPOINT     the recipient device the plan puts at MOUNTPOINT (or empty)
#   target_fstype DEV            blkid's TYPE of DEV
#
# Why the plan and not the target's fstab: before postfix the fstab still names
# the donor's devices (/dev/md0 …), and after a failed postfix it may be half
# rewritten; [volumes] is what apply and transfer actually made.
# Why --make-private: / in the Live is a shared mount; without it every bind
# below propagates into the mount namespaces of udevd/logind, the later umount
# "succeeds" and the device stays busy (DEVLOG 2026-09-29).
# Under -n: "ro" still mounts (read-only, no journal replay) so postfix can show
# diffs and verify can look; "rw" is refused, nothing is ever written in a dry run.

: "${TARGET_MNT:=/mnt/reloca.to/target}"
TARGET_BINDS=

# rows of [volumes] that carry a filesystem mounted somewhere in the tree,
# as "MOUNT<TAB>DEV", shallowest mountpoint first. $RUN/target.map ("DEV<TAB>OTHER"
# lines) substitutes devices: the on-line pre-check mounts dm-snapshots of the
# copies instead of the copies themselves (transfer.sh), nothing else writes it.
_target_mounts() {
	local plan=${1:-$RUN/plan}
	plan_section "$plan" volumes | while IFS= read -r row; do
		local m d
		m=$(pl_field "$row" mount); d=$(pl_field "$row" target)
		case $m in /*) printf '%s\t%s\n' "$m" "$d";; esac
	done | awk -F'\t' '{ n = gsub("/", "/", $1); if ($1 == "/") n = 0; printf "%d\t%s\t%s\n", n, $1, $2 }' | sort -n -k1,1 -k2,2 | cut -f2- \
	| awk -F'\t' -v OFS='\t' -v map="$RUN/target.map" 'BEGIN { while ((getline l < map) > 0) { split(l, a, "\t"); if (a[1] != "") m[a[1]] = a[2] } } { if ($2 in m) $2 = m[$2]; print }'
}
target_dev_of() { _target_mounts "${2:-$RUN/plan}" | awk -F'\t' -v m="$1" '$1 == m { print $2; exit }'; }
target_fstype() { blkid -c /dev/null -o value -s TYPE "$1" 2>/dev/null; }
target_is_mounted() { mountpoint -q "$TARGET_MNT" 2>/dev/null; }

# read-only must not replay a journal: a dry run and verify never write
_target_opts() {   # MODE FSTYPE
	if [ "$1" = ro ]; then
		case $2 in ext2|ext3|ext4) echo ro,noload;; xfs) echo ro,norecovery;; *) echo ro;; esac
	else
		case $2 in vfat) echo rw,umask=0077;; *) echo rw;; esac
	fi
}

target_mount() {
	local mode=${1:-rw} binds=${2:-} plan=$RUN/plan m d t vg
	[ -r "$plan" ] || die "$EX_ENV" "no plan at $plan: nothing to mount"
	case $mode in rw|ro) ;; *) die "$EX_FAIL" "target_mount: bad mode '$mode'";; esac
	[ -z "$DRY" ] || [ "$mode" = ro ] || die "$EX_FAIL" "target_mount rw under -n (a dry run never writes the target)"
	target_is_mounted && { log "target already mounted at $TARGET_MNT"; return 0; }
	# raid=1: the arrays must be running before the VGs on them (apply left them running;
	# after a reboot of the Live or a cleanup they are assembled again from the plan)
	! declare -F md_assemble_plan >/dev/null || md_assemble_plan "$plan"
	# LVs of the plan must be active before their nodes exist
	while IFS= read -r vg; do
		[ -n "$vg" ] && vgchange -ay "$vg" >/dev/null 2>&1
	done < <(plan_section "$plan" lvm | sed -n 's/^vgcreate \([^ ]*\) .*/\1/p')
	udevadm settle 2>/dev/null
	[ -n "$(target_dev_of / "$plan")" ] || die "$EX_PLAN" "the plan has no volume mounted at /"
	mkdir -p "$TARGET_MNT"
	if [ -z "${_TARGET_CLEANUP:-}" ]; then
		cleanup_add "umount -R $(printf '%q' "$TARGET_MNT") 2>/dev/null || umount -R -l $(printf '%q' "$TARGET_MNT") 2>/dev/null"
		_TARGET_CLEANUP=y
	fi
	while IFS=$'\t' read -r m d; do
		[ -b "$d" ] || { [ "$m" = / ] && die "$EX_ENV" "target root $d is not a block device (apply/transfer not run on this box?)"; warn "target $d for $m is not there, skipped"; continue; }
		t=$(target_fstype "$d")
		[ -n "$t" ] || { [ "$m" = / ] && die "$EX_FAIL" "no filesystem on the target root $d (transfer not finished?)"; warn "no filesystem on $d for $m, skipped"; continue; }
		if [ "$m" != / ] && [ ! -d "$TARGET_MNT$m" ]; then
			if [ "$mode" = rw ]; then mkdir -p "$TARGET_MNT$m"; else warn "mountpoint $m is missing in the target root, $d not mounted"; continue; fi
		fi
		log "+ mount -t $t -o $(_target_opts "$mode" "$t") $d $TARGET_MNT$m"
		mount -t "$t" -o "$(_target_opts "$mode" "$t")" "$d" "$TARGET_MNT$m" \
			|| die "$EX_FAIL" "cannot mount $d ($t) at $TARGET_MNT$m ($mode)"
		[ "$m" != / ] || mount --make-private "$TARGET_MNT"
	done < <(_target_mounts "$plan")
	say "target mounted at $TARGET_MNT ($mode): $(_target_mounts "$plan" | awk -F'\t' '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $1, $2 }')"
	if [ "$binds" = binds ]; then
		[ "$mode" = rw ] || die "$EX_FAIL" "target_mount: binds need rw"
		for m in dev proc sys run; do
			mkdir -p "$TARGET_MNT/$m"
			if ! { mount --rbind "/$m" "$TARGET_MNT/$m" && mount --make-rslave "$TARGET_MNT/$m"; }; then
				die "$EX_FAIL" "cannot bind /$m into the target"
			fi
		done
		# a regular resolv.conf is bound over (never rewritten); a symlink
		# (systemd-resolved) is left alone: nothing in postfix needs DNS by default
		if [ -f "$TARGET_MNT/etc/resolv.conf" ] && [ ! -L "$TARGET_MNT/etc/resolv.conf" ]; then
			mount --bind /etc/resolv.conf "$TARGET_MNT/etc/resolv.conf" 2>/dev/null || true
		fi
		TARGET_BINDS=y
	fi
}

target_umount() {
	TARGET_BINDS=
	target_is_mounted || return 0
	sync
	for _ in 1 2 3 4 5; do
		umount -R "$TARGET_MNT" 2>/dev/null && break
		udevadm settle 2>/dev/null; sleep 1
	done
	if target_is_mounted; then
		warn "cannot unmount $TARGET_MNT cleanly ($(fuser -vm "$TARGET_MNT" 2>&1 | tail -n +2 | awk '{print $NF}' | sort -u | tr '\n' ' ')): lazy unmount"
		umount -R -l "$TARGET_MNT" 2>/dev/null
	fi
	rmdir "$TARGET_MNT" 2>/dev/null
	log "target unmounted"
	return 0
}

# A clean environment: the Live's locale/TERM quirks must not leak into
# update-initramfs or grub; PATH covers both usr-merged and old layouts.
_TARGET_ENV=(env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C TERM=dumb DEBIAN_FRONTEND=noninteractive HOME=/root)
target_chroot() {
	[ -n "$TARGET_BINDS" ] || [ -n "$DRY" ] || die "$EX_FAIL" "target_chroot without target_mount rw binds"
	run chroot "$TARGET_MNT" "${_TARGET_ENV[@]}" "$@"
}
target_chroot_sh() {
	[ -n "$TARGET_BINDS" ] || [ -n "$DRY" ] || die "$EX_FAIL" "target_chroot_sh without target_mount rw binds"
	run chroot "$TARGET_MNT" "${_TARGET_ENV[@]}" sh -c "$1"
}
# quiet variant for probes (command -v, reading a version): not echoed, only logged
target_chroot_q() { log "chroot: $*"; chroot "$TARGET_MNT" "${_TARGET_ENV[@]}" "$@"; }
