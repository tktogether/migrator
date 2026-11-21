#!/bin/bash
# live-entry.sh — boot THIS machine into the self-contained migrator Live
# without an ISO: the squashfs, the kernel and the initrd are copied onto one
# of its own filesystems, and a grub entry is written for them.
#
# Why this exists: a recipient usually has no console to attach an ISO to
# (a hosted VM, a machine already handed over), and a donor must keep serving
# until the transfer is done. Both can be booted into the Live this way.
#
# The four constraints this encodes, each one paid for on real hardware:
#
#   D25  toram=filesystem.squashfs, never a bare `toram`. On a partition medium
#        a bare toram tries to copy the whole partition into RAM and fails,
#        leaving the target disk mounted — apply would then wipe the Live.
#   D28  the kernel and the initrd must sit on the filesystem the grub entry
#        searches (`search --fs-uuid`), which is not always /boot.
#   D29  with a separate /boot, boot files placed under it but searched on /
#        produce a grub rescue. The entry below is generated from the
#        filesystem the artefacts are actually copied to.
#   D30  (1) live-boot's media scan does not look inside LVM: the /live tree
#            goes on a NON-LVM filesystem (/boot when that is a separate
#            ext4/xfs/btrfs partition, otherwise /).
#        (2) a file named vmlinuz-* at the top of /boot is taken by
#            update-grub as the newest kernel and becomes the default (a
#            Debian kernel over an Ubuntu root = emergency). The tree lives
#            in a `live/` subdirectory, so 10_linux never matches it.
#        (3) the Live runs from RAM and the target disk gets wiped, so the
#            entry must survive a failed boot: -s uses grub-set-default
#            (persistent) instead of grub-reboot (one shot).
#
# usage: live-entry.sh [-n] [-s] [-r] [-p PORT] [-f DIR] -i IP[/PREFIX][,GW[,DNS1[,DNS2]]]
#   -i SPEC   static address for the Live, passed as migrator.ip=, e.g.
#             "192.168.8.111/24,192.168.8.1,192.168.8.1" (required unless -r:
#             the Live must not depend on this network handing out DHCP)
#   -f DIR    where the artefacts are (default /root): vmlinuz-live,
#             initrd-live.img, live/filesystem.squashfs (a filesystem.squashfs
#             lying beside them is accepted too)
#   -p PORT   sshd port for the Live, passed as migrator.ssh_port= (default: as
#             built, 22 unless the image was built with LIVE_SSH_PORT). Only the
#             port is settable here: a password cannot go on the boot line,
#             which every local user can read
#   -s        also make the entry the DEFAULT (persistent, GRUB_DEFAULT=saved);
#             without it the entry is only for the next boot (grub-reboot)
#   -r        remove the entry and the copied artefacts, then re-run update-grub
#   -n        dry run: say what would be copied and written, touch nothing
#   -h        this text
#
# exit: 0 done (or dry run ok) · 1 failure (including "cannot run here": not
#       root, no update-grub, artefacts missing, no non-LVM filesystem with
#       room, less RAM than the squashfs needs in tmpfs)
#
# Run this from the system that is going away, BEFORE the disks are touched.
# Once apply has wiped the disk the Live can only be re-entered through a
# console and an ISO.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TITLE='migrator Live'
DRY=; SETDEF=; REMOVE=; SRC=/root; SPEC=; SPORT=; GRUB_D=/etc/grub.d/41_migrator-live; CFG=/boot/grub/grub.cfg

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() { if [ -n "$DRY" ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }
iec() { numfmt --to=iec "$1"; }

while getopts "nsrf:i:p:h" o; do
	case $o in
		n) DRY=1;;
		s) SETDEF=1;;
		r) REMOVE=1;;
		f) SRC=$OPTARG;;
		i) SPEC=$OPTARG;;
		p) SPORT=$OPTARG;;
		h) usage 0;;
		*) usage 2;;
	esac
done
if [ -n "$SPORT" ]; then
	case $SPORT in *[!0-9]*|'') die "-p $SPORT: 需要 1 到 65535 之间的数字";; esac
	[ "$SPORT" -ge 1 ] && [ "$SPORT" -le 65535 ] || die "-p $SPORT: 需要 1 到 65535 之间的数字"
fi
[ "$(id -u)" = 0 ] || die "must run as root: it writes a grub entry and copies into /boot or /"
command -v update-grub > /dev/null || die "update-grub not found: this script drives a grub2 system (Debian/Ubuntu)"

# --- where the /live tree goes ---------------------------------------------------
# live-boot scans block devices for <fs>/live/filesystem.squashfs, and it does
# not enter LVM (D30 ①). Prefer a separate /boot (the usual ext4 system
# partition), fall back to / when that is not on LVM.
pick_fs() {
	local cand mnt fs dev
	for cand in /boot /; do
		mnt=$(findmnt -no TARGET -T "$cand" 2>/dev/null) || continue
		[ "$mnt" = "$cand" ] || continue          # /boot not separate -> mnt is /
		fs=$(findmnt -no FSTYPE -T "$mnt" 2>/dev/null)
		dev=$(findmnt -no SOURCE -T "$mnt" 2>/dev/null)
		case $dev in /dev/mapper/*|/dev/dm-*) continue;; esac
		case $fs in ext2|ext3|ext4|xfs|btrfs|vfat) ;; *) continue;; esac
		[ -n "$dev" ] || continue
		MP=$mnt FS=$fs TGT_DEV=$dev UUID=$(findmnt -no UUID -T "$mnt" 2>/dev/null)
		[ -n "$UUID" ] && return 0
	done
	return 1
}

# --- the artefacts ---------------------------------------------------------------
SQ=$SRC/live/filesystem.squashfs; [ -f "$SQ" ] || SQ=$SRC/filesystem.squashfs
K=$SRC/vmlinuz-live; I=$SRC/initrd-live.img
need=0
if [ -z "$REMOVE" ]; then
	for f in "$SQ" "$K" "$I"; do
		[ -f "$f" ] || die "$f: missing (the three artefacts are vmlinuz-live, initrd-live.img and live/filesystem.squashfs)"
	done
	need=$(( $(stat -c %s "$SQ") + $(stat -c %s "$K") + $(stat -c %s "$I") ))
fi

# --- leftovers from the earlier entries (D30 ②) ----------------------------------
for stale in /boot/vmlinuz-live /boot/initrd-live.img; do
	[ -e "$stale" ] || continue
	say "WARN: $stale sits at the top of /boot: update-grub takes it for the newest kernel and boots it by default"
	[ -n "$DRY" ] || { rm -f "$stale"; say "      removed (the copy below is inside live/, which 10_linux does not match)"; }
done

# --- -r: remove ------------------------------------------------------------------
if [ -n "$REMOVE" ]; then
	say "removing the Live entry and its artefacts"
	[ -e "$GRUB_D" ] && run rm -f "$GRUB_D"
	for f in /boot/live /live; do
		if [ -d "$f" ] && [ ! -L "$f" ]; then
			if [ -n "$DRY" ]; then say "  would remove: $f"; else rm -rf "$f"; say "  removed: $f"; fi
		fi
	done
	run update-grub
	if grep -q '^GRUB_DEFAULT=saved' /etc/default/grub 2>/dev/null; then
		say "note: GRUB_DEFAULT=saved is still in /etc/default/grub (harmless; change it by hand to restore the old default)"
	fi
	say "done: the next boot follows the normal grub default again"
	exit 0
fi

# 端口由引导参数传给 Live 内的 migrator-live-ssh.service，它在 sshd 启动前改写
# sshd_config.d 中的同一个文件，因此与构建时的端口不会同时生效。
SSHPORT=; [ -n "$SPORT" ] && SSHPORT=" migrator.ssh_port=$SPORT"

# --- checks ----------------------------------------------------------------------
pick_fs || die "no non-LVM filesystem to host the Live: live-boot cannot see inside LVM (D30), so give this machine a plain ext4 /boot"
[ -n "$SPEC" ] || die "-i is required: the Live needs migrator.ip=IP/PREFIX,GW,DNS (do not bet on DHCP here)"
avail=$(df -B1 --output=avail "$MP" | tail -1 | tr -d ' ')
[ "$avail" -gt "$need" ] || die "$MP has $(iec "$avail") free, the artefacts need $(iec "$need")"
mem=$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)
sq=$(stat -c %s "$SQ")
[ "$mem" -gt $(( sq + 268435456 )) ] || \
	say "WARN: $(iec "$mem") RAM for a $(iec "$sq") squashfs: toram may not fit, the Live could fail to start"

# --- copy ------------------------------------------------------------------------
say "artefacts $(iec "$need") -> $MP/live ($FS on $TGT_DEV, UUID $UUID)"
run mkdir -p "$MP/live"
run cp -f "$SQ" "$MP/live/filesystem.squashfs"
run cp -f "$K"  "$MP/live/vmlinuz-live"
run cp -f "$I"  "$MP/live/initrd-live.img"
run sync

# --- the grub entry --------------------------------------------------------------
say "writing $GRUB_D"
if [ -z "$DRY" ]; then
	cat > "$GRUB_D" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# tools/live-entry.sh (D25/D28/D29/D30): the /live tree is on $MP ($FS, UUID $UUID)
menuentry '$TITLE' {
	search --no-floppy --set=root --fs-uuid $UUID
	linux /live/vmlinuz-live boot=live components toram=filesystem.squashfs \\
		net.ifnames=0 biosdevname=0 systemd.default_timeout_start_sec=600 \\
		console=tty0 console=ttyS0,115200n8 panic=30 migrator.ip=$SPEC$SSHPORT
	initrd /live/initrd-live.img
}
EOF
	chmod 0755 "$GRUB_D"
fi

# grub-set-default only works with GRUB_DEFAULT=saved; grub-reboot does not care
if [ -n "$SETDEF" ]; then
	say "making '$TITLE' the persistent default (GRUB_DEFAULT=saved)"
	if [ -f /etc/default/grub ] && grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
		run sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
	elif [ -f /etc/default/grub ]; then
		run sh -c 'printf "%s\n" GRUB_DEFAULT=saved >> /etc/default/grub'
	else
		run sh -c 'printf "%s\n" GRUB_DEFAULT=saved > /etc/default/grub'
	fi
fi

run update-grub
if [ -z "$DRY" ]; then
	grep -q "menuentry '$TITLE'" "$CFG" || die "update-grub did not write the entry into $CFG"
fi

if [ -n "$SETDEF" ]; then
	run grub-set-default "$TITLE"
	say "default entry set: it survives a failed boot (grub-set-default, not grub-reboot)"
	ADDR=${SPEC%%,*}
else
	run grub-reboot "$TITLE"
	say "next boot only (grub-reboot); use -s when the disk is about to be wiped and a failed boot must still land in the Live"
	ADDR=${SPEC%%,*}
fi

say ""
SSH_LINE="ssh${SPORT:+ -p $SPORT} root@${ADDR%%/*}"
say "after the reboot:"
say "  $SSH_LINE                    # the Live carries /root/rig-key"
say "  cat /etc/migrator-live-release"
say "  free -m; swapon --show                  # zram does the swapping"
say "  findmnt -S $TGT_DEV || echo '$TGT_DEV free'   # toram released the disk"
exit 0
