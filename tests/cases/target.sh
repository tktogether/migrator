#!/bin/bash
# tests/cases/target.sh — lib/target.sh without mounting anything: which device
# goes where (from the plan's [volumes]), in which order, and the guards that
# keep a dry run from ever mounting read-write.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO/lib/plan.sh"
# shellcheck source=lib/target.sh
. "$REPO/lib/target.sh"
FIX=$REPO/tests/fixtures

for fn in target_mount target_umount target_chroot target_chroot_sh target_chroot_q target_is_mounted target_dev_of target_fstype; do
	assert_ok "defines $fn" declare -f "$fn"
done

# shallowest mountpoint first, / always first whatever the row order in the plan
assert_eq "centos7: / then /boot" "/=/dev/centos/root /boot=/dev/sda1" \
	"$(_target_mounts "$FIX/centos7-md-lvm-xfs-bios/expected.plan" | awk -F'\t' '{printf "%s%s=%s", (NR>1?" ":""), $1, $2}')"
assert_eq "ubuntu uefi: / /boot /boot/efi" "/=/dev/vda3 /boot=/dev/vda2 /boot/efi=/dev/vda1" \
	"$(_target_mounts "$FIX/ubuntu-nvme-uefi-to-bios-vm/expected.plan" | awk -F'\t' '{printf "%s%s=%s", (NR>1?" ":""), $1, $2}')"
assert_eq "swap and pv rows are not mounts" 2 "$(_target_mounts "$FIX/centos7-md-lvm-xfs-bios/expected.plan" | wc -l)"
assert_eq "target_dev_of /boot"     /dev/vda2 "$(target_dev_of /boot "$FIX/ubuntu-nvme-uefi-to-bios-vm/expected.plan")"
assert_eq "target_dev_of /"         /dev/vda4 "$(target_dev_of / "$FIX/stand-debian-md-ext4-bios/expected.plan")"
assert_eq "target_dev_of a mountpoint the plan does not have" "" "$(target_dev_of /var "$FIX/stand-debian-md-ext4-bios/expected.plan")"

assert_eq "ro ext4 never replays the journal" ro,noload     "$(_target_opts ro ext4)"
assert_eq "ro xfs never replays the log"      ro,norecovery "$(_target_opts ro xfs)"
assert_eq "rw vfat is root-only"              rw,umask=0077 "$(_target_opts rw vfat)"

# guards (each in a subshell: die exits)
d=$RUN/target; mkdir -p "$d"
( RUN=$d; TARGET_MNT=$d/mnt; target_mount rw ) >/dev/null 2>&1; assert_eq "no plan -> exit 2" 2 $?
cp "$FIX/stand-debian-md-ext4-bios/expected.plan" "$d/plan"
( RUN=$d; TARGET_MNT=$d/mnt; DRY=y; target_mount rw ) >/dev/null 2>&1; assert_eq "rw under -n is refused" 1 $?
( RUN=$d; TARGET_MNT=$d/mnt; target_mount sideways ) >/dev/null 2>&1; assert_eq "bad mode -> exit 1" 1 $?
out=$( ( RUN=$d; TARGET_MNT=$d/mnt; target_mount ro ) 2>&1 ); rc=$?
if [ -b /dev/vda4 ]; then skip "absent target root" "this host has /dev/vda4"
else
	assert_eq  "target root device absent -> exit 2" 2 "$rc"
	assert_has "says which device"                   "target root /dev/vda4 is not a block device" "$out"
fi
( RUN=$d; TARGET_MNT=$d/mnt; target_chroot true ) >/dev/null 2>&1; assert_eq "chroot without binds is refused" 1 $?
assert_ok "target_umount of nothing is a no-op" target_umount
assert_fail "nothing mounted" target_is_mounted

t_end
