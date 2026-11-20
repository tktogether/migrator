#!/bin/bash
# tests/cases/apply.sh — lib/apply.sh without a disk: the function contract, the
# dry-run command sequence over real fixture plans (stand-debian-md-ext4-bios as is,
# centos7-md-lvm-xfs-bios with old contents and a second disk added to its recipient
# inventory, the gpt+bios ubuntu-nvme plan), the pre-apply fingerprint gate against
# canned lsblk/blockdev/dd shims (pass, wrong size, wrong ptuuid, force=1, first-MiB
# hash, a mounted partition), the mask helpers over recorded dumpe2fs/xfs_db output,
# apply_partnode, the post-apply fingerprint check against a fake state, wait/stop
# helpers, and cleanup_all on an empty state dir. Every device command is printed
# under -n and nothing is executed; anything that dies runs in a subshell.
# shellcheck disable=SC2016,SC2030,SC2031  # snippets handed to eval/shims keep their $s; PATH/SHIM_VALS are changed in subshells on purpose
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO/lib/plan.sh"
# shellcheck source=lib/inventory.sh
. "$REPO/lib/inventory.sh"
# shellcheck source=lib/apply.sh
. "$REPO/lib/apply.sh"
FIX=$REPO/tests/fixtures
MIGRATOR_LIB=$REPO/lib; export MIGRATOR_LIB
W=$RUN/apply-work; mkdir -p "$W"

# --- (a) contract, silent sourcing -----------------------------------------------------
for fn in apply_run cleanup_all apply_fingerprint_check apply_fingerprint_verify apply_target_disk apply_partnode \
          apply_wait_nodes apply_setro_others md_stop_retry masks_of_fs masks_from_dumpe2fs masks_from_xfs_db \
          masks_norm masks_equal masks_diff; do
	if declare -F "$fn" >/dev/null; then _pass "defines $fn"; else _fail "defines $fn" "missing"; fi
done
out=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; . "$1/lib/inventory.sh"; . "$1/lib/apply.sh"' _ "$REPO" 2>&1); rc=$?
assert_eq "apply.sh sources cleanly"     0  "$rc"
assert_eq "apply.sh is silent on source" "" "$out"

# --- helpers -----------------------------------------------------------------------------
# mkrun DIR CASE [RECIPIENT.inv]: a state dir with the fixture's inventories and plan; with a
# modified recipient inventory the plan header's inv_sha256 is rewritten to match it
mkrun() {
	local d=$1 c=$2 h rinv
	rinv=${3:-$FIX/$c/recipient.inv}
	mkdir -p "$d"; cp "$FIX/$c/donor.inv" "$d/donor.inv"; cp "$rinv" "$d/recipient.inv"; cp "$FIX/$c/expected.plan" "$d/plan"
	h="$(sha256sum "$d/donor.inv" | cut -c1-64):$(sha256sum "$d/recipient.inv" | cut -c1-64)"
	sed -i "s/^# inv_sha256=[^ ]*/# inv_sha256=$h/" "$d/plan"
}
# dry DIR [SNIPPET]: apply_run under -n -y in a subshell with RUN=DIR (SNIPPET eval'd first);
# stdout+stderr -> DIR/out, status echoed
dry() { ( RUN=$1; DRY=y; YES=y; eval "${2:-}"; apply_run ) > "$1/out" 2>&1; echo $?; }
# in_order NAME FILE PATTERN...: every pattern appears (fixed string), each after the previous one
in_order() {
	local name=$1 f=$2 pat last=0 n; shift 2
	for pat in "$@"; do
		n=$(awk -v p="$pat" -v s="$last" 'NR > s && index($0, p) { print NR; exit }' "$f")
		[ -n "$n" ] || { _fail "$name" "'$pat' not found after line $last"; return 0; }
		last=$n
	done
	_pass "$name"
}
# canned lsblk / blockdev / dd: values from the file $SHIM_VALS names
SHIM=$W/shim; mkdir -p "$SHIM"
cat > "$SHIM/lsblk" <<'EOF'
#!/bin/bash
. "$SHIM_VALS"
case " $* " in
	*" WWN "*)    echo "$WWN";;
	*" SERIAL "*) echo "$SERIAL";;
	*" MODEL "*)  echo "$MODEL";;
	*" PTUUID "*) echo "$PTUUID";;
	*" PATH,TYPE,PARTUUID,MOUNTPOINT "*) printf '%s\n' "$TREE";;
	*) echo "shim lsblk: unexpected arguments: $*" >&2; exit 1;;
esac
EOF
cat > "$SHIM/blockdev" <<'EOF'
#!/bin/bash
. "$SHIM_VALS"
case "$1" in --getsize64) echo "$SIZE";; --getss) echo "$LSEC";; --getpbsz) echo "$PSEC";; *) echo "shim blockdev: unexpected arguments: $*" >&2; exit 1;; esac
EOF
cat > "$SHIM/dd" <<'EOF'
#!/bin/bash
. "$SHIM_VALS"; printf '%s' "$HEAD"
EOF
chmod +x "$SHIM"/*
# with_shim VALSFILE: the snippet that puts the shims on PATH and pretends the disk is present
with_shim() { echo "export SHIM_VALS=$1; PATH=$SHIM:\$PATH; apply_disk_present() { return 0; }"; }

# --- (b) dry run over the real stand capture: /dev/vda, no old contents, no other disks --------
D=$W/stand; mkrun "$D" stand-debian-md-ext4-bios
if [ -b /dev/vda ]; then
	skip "stand dry run" "this host has a /dev/vda: the absent-disk path cannot be exercised"
else
	rc=$(dry "$D")
	assert_eq  "stand: dry apply_run exits 0"             0 "$rc"
	assert_has "stand: plan_check ran first"              "plan check passed" "$(cat "$D/out")"
	assert_has "stand: absent disk is a warning under -n" "/dev/vda not present, fingerprint not checked (dry run)" "$(cat "$D/out")"
	assert_has "stand: a blank disk takes a plain y/N, not the typed name"  "(dry) /dev/vda: blank (nothing to lose); the gate would ask a plain y/N here; prompt skipped" "$(cat "$D/out")"
	assert_eq  "stand: ... so nothing to type is announced" 0 "$(grep -c 'would require typing' "$D/out")"
	assert_has "stand: gate shows what is on the disk"    "NOW ON IT    free   <-- WILL BE WIPED" "$(cat "$D/out")"
	in_order "stand: command order" "$D/out" \
		"plan check passed" \
		"blank (nothing to lose); the gate would ask a plain y/N" \
		"nothing active on /dev/vda to deactivate" \
		"(dry) wipefs -a /dev/vda" \
		"(dry) sgdisk --zap-all /dev/vda" \
		"(dry) udevadm settle" \
		"no other disks on this box to set read-only" \
		"(dry) /usr/sbin/sfdisk --wipe always --wipe-partitions always /dev/vda < $D/sfdisk.script" \
		"(dry) partprobe /dev/vda" \
		"(dry) udevadm settle" \
		"(dry) would wait up to 30s for: /dev/vda1 /dev/vda2 /dev/vda3 /dev/vda4" \
		"(dry) would stop any md array udev re-assembles from /dev/vda" \
		"(dry) would record the post-apply fingerprint of /dev/vda" \
		"(dry) mkswap -U 231753ee-4ef0-48a7-9f6d-19a3e1b26951 -L swap0 /dev/vda2" \
		"(dry) mkswap -U 129f6d9f-179a-4b12-b100-bc56202e6541 -L swap1 /dev/vda3" \
		"(dry) would mark every [volumes] row pending and phase apply done"
	assert_eq  "stand: the first (dry) command is the disk wipe"  "(dry) wipefs -a /dev/vda" "$(grep -m1 '^(dry) ' "$D/out")"
	assert_eq  "stand: 12 (dry) lines, nothing else"              12 "$(grep -c '^(dry) ' "$D/out")"
	assert_eq  "stand: setro list is empty"                       0 "$(grep -c 'blockdev --setro' "$D/out")"
	assert_eq  "stand: no pvcreate for a plan without [lvm]"      0 "$(grep -c pvcreate "$D/out")"
	assert_eq  "stand: no parted (dos label)"                     0 "$(grep -c 'parted' "$D/out")"
	assert_eq  "stand: sfdisk script == the plan's [sfdisk]"      "$(plan_section "$D/plan" sfdisk)" "$(cat "$D/sfdisk.script")"
	assert_eq  "stand: sfdisk script has 8 lines"                 8 "$(wc -l < "$D/sfdisk.script")"
	assert_eq  "stand: both mkswap lines verbatim"                2 "$(grep -cF -e '(dry) mkswap -U 231753ee-4ef0-48a7-9f6d-19a3e1b26951 -L swap0 /dev/vda2' -e '(dry) mkswap -U 129f6d9f-179a-4b12-b100-bc56202e6541 -L swap1 /dev/vda3' "$D/out")"
	assert_fail "stand: no state written by a dry run"            test -e "$D/state"
	assert_has "stand: says nothing was written"                  "nothing written, no state left" "$(cat "$D/out")"
	assert_ok  "stand: dry lines are in the log"                  grep -q '(dry) wipefs -a /dev/vda' "$D/log"
	# the same plan without -n: the disk is not here, exit 2 before any command
	( RUN=$D; DRY=; YES=y; apply_run ) > "$D/real.out" 2>&1; rc=$?
	assert_eq  "stand: without -n an absent disk exits 2"         2 "$rc"
	assert_has "stand: without -n says why"                       "target disk /dev/vda is not a block device" "$(cat "$D/real.out")"
	assert_eq  "stand: without -n nothing ran before the gate"    0 "$(grep -c '^+ ' "$D/real.out")"
	assert_fail "stand: failure leaves no state either"           test -e "$D/state"
	# a broken plan never reaches the disk: plan_check dies 4 first
	sed -i 's|^/dev/vda2 : start=2099200,|/dev/vda2 : start=2048,|' "$D/plan"
	rc=$(dry "$D")
	assert_eq  "stand: plan_check red -> exit 4"                  4 "$rc"
	assert_eq  "stand: plan_check red -> no (dry) command"        0 "$(grep -c '^(dry) ' "$D/out")"
fi

# --- (c) centos7 md+lvm+xfs: old contents on the disk, a second disk, [lvm], the gate on shims ---
C=$FIX/centos7-md-lvm-xfs-bios
R=$W/centos-recipient.inv
{
	cat "$C/recipient.inv"
	printf 'disk\tdev=/dev/sdb\tsize=2000398934016\tlsec=512\tpsec=4096\tmodel=ST2000NM0008\tserial=ZC2AAAAA\twwn=0x5000c500a0000001\tbyid=ata-ST2000NM0008_ZC2AAAAA\ttran=sata\trm=0\tro=0\tpttype=-\tptuuid=-\tdrivers=sd,ahci\tmodalias=pci:v00008086d0000A102\tusage=free\n'
	printf 'disk\tdev=/dev/sdc\tsize=2000398934016\tlsec=512\tpsec=4096\tmodel=ST2000NM0008\tserial=ZC2BBBBB\twwn=0x5000c500a0000002\tbyid=ata-ST2000NM0008_ZC2BBBBB\ttran=sata\trm=0\tro=1\tpttype=-\tptuuid=-\tdrivers=sd,ahci\tmodalias=pci:v00008086d0000A102\tusage=free\n'
	printf 'part\tdev=/dev/sda1\tdisk=/dev/sda\tnum=1\tstart=2048\tsize=8388608\ttype=82\tbootable=0\tpartuuid=0badcafe-01\tname=\tfstype=swap\tptype=primary\n'
	printf 'part\tdev=/dev/sda2\tdisk=/dev/sda\tnum=2\tstart=8390656\tsize=1943033856\ttype=fd\tbootable=1\tpartuuid=0badcafe-02\tname=\tfstype=linux_raid_member\tptype=primary\n'
	printf 'md\tdev=/dev/md127\tlevel=raid1\tuuid=11111111:22222222:33333333:44444444\tname=old:0\tmetadata=1.2\tsize=994799190016\tmembers=/dev/sda2\tdata_offset=4096\tstate=clean\tro=0\n'
	printf 'pv\tdev=/dev/md127\tuuid=Old0pv-0000-0000-0000-0000-0000-000000\tvg=oldvg\tsize=994799190016\tpe_start=1048576\n'
	printf 'vg\tname=oldvg\tuuid=Old0vg-0000-0000-0000-0000-0000-000000\tsize=994795995136\tfree=0\tpvs=/dev/md127\n'
	printf 'lv\tpath=/dev/oldvg/root\tvg=oldvg\tname=root\tuuid=Old0lv-0000-0000-0000-0000-0000-000000\tsize=994795995136\tsegtype=linear\n'
	printf 'swap\tdev=/dev/sda1\tuuid=0e0e0e0e-0000-4000-8000-000000000001\tlabel=\tsize=4294967296\n'
} > "$R"
D=$W/centos; mkrun "$D" centos7-md-lvm-xfs-bios "$R"
cat > "$D/vals" <<'EOF'
WWN=0x6d0946606e5ad1002a1f2b3c4d5e6f70
SERIAL=00e1f2a3b4c5d6e7
MODEL=PERC_H730P_Mini
PTUUID=0badcafe
SIZE=999653638144
LSEC=512
PSEC=4096
HEAD=
TREE='PATH="/dev/sda" TYPE="disk" PARTUUID="" MOUNTPOINT=""
PATH="/dev/sda1" TYPE="part" PARTUUID="0badcafe-01" MOUNTPOINT="[SWAP]"
PATH="/dev/sda2" TYPE="part" PARTUUID="0badcafe-02" MOUNTPOINT=""
PATH="/dev/md127" TYPE="raid1" PARTUUID="" MOUNTPOINT=""
PATH="/dev/mapper/oldvg-root" TYPE="lvm" PARTUUID="" MOUNTPOINT=""'
EOF
rc=$(dry "$D" "$(with_shim "$D/vals")")
assert_eq  "centos7: dry apply_run exits 0"                 0 "$rc"
assert_has "centos7: the live disk matched the plan"        "fingerprint: /dev/sda is wwn:0x6d0946606e5ad1002a1f2b3c4d5e6f70, 999653638144 bytes, 512/4096 sectors, as planned" "$(cat "$D/out")"
assert_eq  "centos7: no absent-disk warning with the shims" 0 "$(grep -c 'not present' "$D/out")"
assert_has "centos7: gate: what is on the disk"             'NOW ON IT    old-os:"web3 Ubuntu 20.04.6 LTS mtime=2024-03-01"   <-- WILL BE WIPED' "$(cat "$D/out")"
assert_has "centos7: gate: model/serial/driver"             "model=PERC_H730P_Mini serial=00e1f2a3b4c5d6e7 wwn=0x6d0946606e5ad1002a1f2b3c4d5e6f70 tran=sas driver=sd,megaraid_sas" "$(cat "$D/out")"
assert_has "centos7: gate: sda 931"                         "would require typing 'sda 931'" "$(cat "$D/out")"
in_order "centos7: command order" "$D/out" \
	"would require typing 'sda 931'" \
	"(dry) swapoff /dev/sda1" \
	"(dry) vgchange -an oldvg" \
	"(dry) udevadm settle" \
	"(dry) mdadm --stop /dev/md127" \
	"(dry) mdadm --zero-superblock --force /dev/sda1" \
	"(dry) wipefs -a /dev/sda1" \
	"(dry) mdadm --zero-superblock --force /dev/sda2" \
	"(dry) wipefs -a /dev/sda2" \
	"(dry) wipefs -a /dev/sda" \
	"(dry) sgdisk --zap-all /dev/sda" \
	"(dry) udevadm settle" \
	"(dry) blockdev --setro /dev/sdb" \
	"read-only until cleanup: /dev/sdb" \
	"(dry) /usr/sbin/sfdisk --wipe always --wipe-partitions always /dev/sda < $D/sfdisk.script" \
	"(dry) partprobe /dev/sda" \
	"(dry) udevadm settle" \
	"(dry) would wait up to 30s for: /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4" \
	"(dry) would stop any md array udev re-assembles from /dev/sda" \
	"(dry) would record the post-apply fingerprint of /dev/sda" \
	"(dry) pvcreate -ff -y --uuid Zx1yQ2-abcd-efgh-ijkl-mnop-qrst-uvwxYZ --norestorefile /dev/sda4" \
	"(dry) vgcreate centos /dev/sda4" \
	"(dry) lvcreate -y -n swap -L 4294967296b centos" \
	"(dry) lvcreate -y -n root -l 100%FREE centos" \
	"(dry) vgchange -ay centos" \
	"(dry) udevadm settle" \
	"(dry) would wait up to 30s for: /dev/centos/swap /dev/centos/root" \
	"(dry) mkswap -U b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e /dev/sda2" \
	"(dry) mkswap -U c2d3e4f5-a6b7-4c8d-9e0f-1a2b3c4d5e6f /dev/sda3" \
	"(dry) mkswap -U e4f5a6b7-c8d9-4e0f-9a1b-2c3d4e5f6071 /dev/centos/swap" \
	"(dry) mkfs.xfs -f -m crc=1,finobt=1,reflink=0,rmapbt=0,bigtime=0,inobtcount=0,uuid=d3e4f5a6-b7c8-4d9e-8f0a-1b2c3d4e5f60 -i sparse=0,nrext64=0,size=512 -n ftype=1,size=4096 -b size=4096 -s size=512 /dev/centos/root" \
	"(dry) would compare masks of /dev/centos/root with the donor's (xfs): xfs|versionnum=46245|features2=394|compat=0|ro_compat=1|incompat=1|log_incompat=0|features=CRC,FINOBT,FTYPE" \
	"(dry) would mark every [volumes] row pending and phase apply done"
assert_eq  "centos7: the first (dry) command is swapoff"     "(dry) swapoff /dev/sda1" "$(grep -m1 '^(dry) ' "$D/out")"
assert_eq  "centos7: setro on the second disk only"          1 "$(grep -c '^(dry) blockdev --setro' "$D/out")"
assert_eq  "centos7: never setro on the target"              0 "$(grep -c 'blockdev --setro /dev/sda$' "$D/out")"
assert_has "centos7: an already-ro disk is left alone"       "/dev/sdc is already read-only" "$(cat "$D/out")"
assert_eq  "centos7: no dmsetup for an LV of a known VG"     0 "$(grep -c dmsetup "$D/out")"
assert_eq  "centos7: one mask comparison (mkswap has none)"  1 "$(grep -c 'would compare masks' "$D/out")"
assert_eq  "centos7: sfdisk script == the plan's [sfdisk]"   "$(plan_section "$D/plan" sfdisk)" "$(cat "$D/sfdisk.script")"
assert_fail "centos7: no state written by a dry run"         test -e "$D/state"
# the gate on the shims: what changes is refused before the first command, even under -n
sed 's/^SIZE=.*/SIZE=999653638143/' "$D/vals" > "$D/vals-size"
rc=$(dry "$D" "$(with_shim "$D/vals-size")")
assert_eq  "gate: size differs -> exit 2"                    2 "$rc"
assert_has "gate: size differs -> says so"                   "target disk changed since the plan: size: plan 999653638144, disk now 999653638143" "$(cat "$D/out")"
assert_eq  "gate: size differs -> no (dry) command at all"   0 "$(grep -c '^(dry) ' "$D/out")"
sed 's/^WWN=.*/WWN=0x6d0946606e5ad1002a1f2b3c4d5e6f71/' "$D/vals" > "$D/vals-id"
rc=$(dry "$D" "$(with_shim "$D/vals-id")")
assert_eq  "gate: wwn differs -> exit 2"                     2 "$rc"
assert_has "gate: wwn differs -> names both"                 "id: plan wwn:0x6d0946606e5ad1002a1f2b3c4d5e6f70, disk now wwn:0x6d0946606e5ad1002a1f2b3c4d5e6f71" "$(cat "$D/out")"
rc=$(dry "$D" "$(with_shim "$D/vals-id"); OPT[force]=1")
assert_eq  "gate: identity is not overridable by force=1"    2 "$rc"
sed 's/^PSEC=.*/PSEC=512/' "$D/vals" > "$D/vals-psec"
rc=$(dry "$D" "$(with_shim "$D/vals-psec")")
assert_eq  "gate: physical sector differs -> exit 2"         2 "$rc"
sed 's/^PTUUID=.*/PTUUID=deadbeef/' "$D/vals" > "$D/vals-pt"
rc=$(dry "$D" "$(with_shim "$D/vals-pt")")
assert_eq  "gate: ptuuid differs -> exit 2"                  2 "$rc"
assert_has "gate: ptuuid differs -> says so"                 "ptuuid: plan 0badcafe, now deadbeef" "$(cat "$D/out")"
assert_has "gate: ptuuid differs -> hints at force=1"        "or force=1" "$(cat "$D/out")"
rc=$(dry "$D" "$(with_shim "$D/vals-pt"); OPT[force]=1")
assert_eq  "gate: ptuuid differs + force=1 -> continues"     0 "$rc"
assert_has "gate: ptuuid differs + force=1 -> WARN"          "WARN: target disk changed since the plan (force=1): ptuuid: plan 0badcafe, now deadbeef" "$(cat "$D/out")"
# the first-MiB hash: the plan's head= against dd (the shim prints HEAD; empty -> sha256 of nothing)
cp "$D/plan" "$D/plan.nohead"
sed -i '1,/^currently=/s|head=-|head=sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|' "$D/plan"
rc=$(dry "$D" "$(with_shim "$D/vals")")
assert_eq  "gate: first-MiB hash matches -> continues"       0 "$rc"
sed 's/^HEAD=.*/HEAD=changed/' "$D/vals" > "$D/vals-head"
rc=$(dry "$D" "$(with_shim "$D/vals-head")")
assert_eq  "gate: first-MiB hash differs -> exit 2"          2 "$rc"
assert_has "gate: first-MiB hash differs -> says so"         "first MiB: plan sha256:e3b0c442" "$(cat "$D/out")"
cp "$D/plan.nohead" "$D/plan"
# something mounted from the disk: refused, never unmounted
sed 's|PATH="/dev/sda2" TYPE="part" PARTUUID="0badcafe-02" MOUNTPOINT=""|PATH="/dev/sda2" TYPE="part" PARTUUID="0badcafe-02" MOUNTPOINT="/mnt/old"|' "$D/vals" > "$D/vals-mnt"
rc=$(dry "$D" "$(with_shim "$D/vals-mnt")")
assert_eq  "mounted from the disk -> exit 2"                 2 "$rc"
assert_has "mounted from the disk -> unmount first"          "unmount first: /dev/sda2 on /mnt/old" "$(cat "$D/out")"
assert_eq  "mounted from the disk -> no umount, no command"  0 "$(grep -c '^(dry) ' "$D/out")"
# a crypt leftover in lsblk's tree gets dmsetup remove after the VG and the array
sed 's|^PATH="/dev/mapper/oldvg-root" TYPE="lvm"|PATH="/dev/mapper/luks-old" TYPE="crypt"|' "$D/vals" > "$D/vals-crypt"
rc=$(dry "$D" "$(with_shim "$D/vals-crypt")")
assert_eq  "crypt leftover: exits 0"                         0 "$rc"
in_order "crypt leftover: dmsetup remove after vgchange/mdadm, before the wipe" "$D/out" \
	"(dry) vgchange -an oldvg" "(dry) mdadm --stop /dev/md127" "(dry) dmsetup remove /dev/mapper/luks-old" "(dry) wipefs -a /dev/sda1"

# --- (c2) gpt + bios (ubuntu-nvme-uefi-to-bios-vm): by-partuuid waits, pmbr_boot, mkfs.ext4 guard --
D=$W/gptbios; mkrun "$D" ubuntu-nvme-uefi-to-bios-vm
if [ -b /dev/vda ]; then
	skip "gpt+bios dry run" "this host has a /dev/vda"
else
	rc=$(dry "$D")
	assert_eq  "gpt+bios: dry apply_run exits 0"                 0 "$rc"
	in_order "gpt+bios: command order" "$D/out" \
		"(dry) wipefs -a /dev/vda" \
		"(dry) /usr/sbin/sfdisk --wipe always --wipe-partitions always /dev/vda <" \
		"(dry) partprobe /dev/vda" \
		"(dry) would wait up to 30s for: /dev/vda128 /dev/vda1 /dev/vda2 /dev/vda3 /dev/disk/by-partuuid/80d4689b-5f52-0a13-c9b9-8b8526335ae1 /dev/disk/by-partuuid/11111111-aaaa-4bbb-8ccc-000000000001 /dev/disk/by-partuuid/11111111-aaaa-4bbb-8ccc-000000000002 /dev/disk/by-partuuid/11111111-aaaa-4bbb-8ccc-000000000003" \
		"(dry) would record the post-apply fingerprint of /dev/vda" \
		"(dry) parted -s /dev/vda disk_set pmbr_boot on" \
		"(dry) mkfs.vfat -F32 -i A1B2C3D4 /dev/vda1" \
		"(dry) mkfs.ext4 -F -U 6b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e -b 4096 -I 256 -N 31088640 -O none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum /dev/vda3" \
		"(dry) would compare masks of /dev/vda3 with the donor's (ext4): ext|features=64bit,dir_index,dir_nlink,ext_attr,extent,extra_isize,filetype,flex_bg,has_journal,huge_file,large_file,metadata_csum,resize_inode,sparse_super|journal=-" \
		"(dry) would mark every [volumes] row pending"
	assert_eq  "gpt+bios: pmbr_boot exactly once"                1 "$(grep -c 'pmbr_boot on' "$D/out")"
	assert_eq  "gpt+bios: no mask comparison for vfat"           1 "$(grep -c 'would compare masks' "$D/out")"
	assert_eq  "gpt+bios: sfdisk script == the plan's [sfdisk]"  "$(plan_section "$D/plan" sfdisk)" "$(cat "$D/sfdisk.script")"
fi

# --- (c2) raid=1: two disks, every disk step twice, the arrays, the gate over both -------------
RD=$W/raid; mkrun "$RD" raid1-md-bios
# both disks absent (dry run): the inventory says free -> blank -> a plain y/N
rc=$(dry "$RD")
assert_eq  "raid: dry apply_run exits 0"                        0 "$rc"
assert_has "raid: plan_check names both disks and the arrays"  "target /dev/vda (894.3G, label dos) + /dev/vdb (894.3G) as md RAID1, 3 arrays" "$(cat "$RD/out")"
assert_has "raid: pregate on the second disk"                  "fingerprint: /dev/vdb is model:-, 960197124096 bytes, 512/512 sectors, as planned" "$(cat "$RD/out")"
assert_has "raid: the gate shows disk 1"                       "TARGET DISK /dev/vda  894.3G" "$(cat "$RD/out")"
assert_has "raid: the gate shows disk 2"                       "TARGET DISK2 /dev/vdb  894.3G" "$(cat "$RD/out")"
assert_has "raid: the gate counts the arrays"                  "3 partitions on each disk, 3 md RAID1 arrays" "$(cat "$RD/out")"
assert_has "raid: two blank disks take a plain y/N"            "(dry) /dev/vda and /dev/vdb: blank (nothing to lose); the gate would ask a plain y/N here" "$(cat "$RD/out")"
in_order "raid: command order" "$RD/out" \
	"plan check passed" \
	"blank (nothing to lose)" \
	"nothing active on /dev/vda or /dev/vdb to deactivate" \
	"--- wiping old signatures on /dev/vda" \
	"(dry) wipefs -a /dev/vda" \
	"(dry) sgdisk --zap-all /dev/vda" \
	"--- wiping old signatures on /dev/vdb" \
	"(dry) wipefs -a /dev/vdb" \
	"(dry) sgdisk --zap-all /dev/vdb" \
	"(dry) blockdev --setro /dev/sdc" \
	"(dry) /usr/sbin/sfdisk --wipe always --wipe-partitions always /dev/vda < $RD/sfdisk.script" \
	"(dry) would wait up to 30s for: /dev/vda1 /dev/vda2 /dev/vda3" \
	"(dry) would stop any md array udev re-assembles from /dev/vda" \
	"--- partitioning /dev/vdb (dos, the mirror's own table)" \
	"(dry) /usr/sbin/sfdisk --wipe always --wipe-partitions always /dev/vdb < $RD/sfdisk2.script" \
	"(dry) would wait up to 30s for: /dev/vdb1 /dev/vdb2 /dev/vdb3" \
	"(dry) would stop any md array udev re-assembles from /dev/vdb" \
	"(dry) would record the post-apply fingerprint of /dev/vda" \
	"(dry) would record the post-apply fingerprint of /dev/vdb" \
	"--- md RAID1 arrays" \
	"(dry) mdadm --create /dev/md1 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=web1 --name=1 --uuid=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b /dev/vda1 /dev/vdb1" \
	"(dry) mdadm --create /dev/md2 " \
	"(dry) mdadm --create /dev/md3 " \
	"(dry) would wait up to 30s for: /dev/md1 /dev/md2 /dev/md3" \
	"(dry) would check that /dev/md1 is at least 1073741824 bytes" \
	"(dry) echo frozen > /sys/block/md1/md/sync_action" \
	"(dry) echo frozen > /sys/block/md3/md/sync_action" \
	"3 array(s) created, the initial resync is paused until the transfer is done" \
	"--- lvm" \
	"(dry) mkswap -U 3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02 /dev/md2" \
	"(dry) mkfs.ext4 -F -U 0d9e8f7a-2222-4b1c-8a3d-5e6f7a8b9c01 " \
	"(dry) would compare masks of /dev/md3 with the donor's (ext4)" \
	"(dry) would mark every [volumes] row pending and phase apply done"
assert_eq  "raid: sfdisk2 script == the plan's [sfdisk2]"        "$(plan_section "$RD/plan" sfdisk2)" "$(cat "$RD/sfdisk2.script")"
assert_eq  "raid: no sfdisk line names a partition of the wrong disk" 0 "$(grep -c '/dev/vda' "$RD/sfdisk2.script")"
assert_eq  "raid: the mkfs.ext4 goes onto the array, never a partition" "/dev/md3" "$(grep '^(dry) mkfs.ext4' "$RD/out" | awk '{ print $NF }')"
assert_eq  "raid: 34 (dry) lines (every disk step twice, 3 arrays)" 34 "$(grep -c '^(dry) ' "$RD/out")"
assert_eq  "raid: only the USB stick is set read-only"           "(dry) blockdev --setro /dev/sdc" "$(grep '^(dry) blockdev --setro' "$RD/out")"
# the same with both disks "present" and carrying a partition: the typed confirmation names both
cat > "$RD/vals" <<'EOF'
WWN=
SERIAL=
MODEL=
PTUUID=
SIZE=960197124096
LSEC=512
PSEC=512
HEAD=
TREE='PATH="/dev/vdx" TYPE="disk" PARTUUID="" MOUNTPOINT=""
PATH="/dev/vdx1" TYPE="part" PARTUUID="deadbeef-01" MOUNTPOINT=""'
EOF
rc=$(dry "$RD" "$(with_shim "$RD/vals")")
assert_eq  "raid, used disks: dry apply_run exits 0"             0 "$rc"
assert_has "raid, used disks: the gate wants both names and the size" "(dry) the gate would require typing 'vda+vdb 894' here" "$(cat "$RD/out")"
assert_has "raid, used disks: the old partition of each disk is wiped" "(dry) wipefs -a /dev/vdx1" "$(cat "$RD/out")"
assert_eq  "raid, used disks: ... on both disks"                 2 "$(grep -c '^(dry) wipefs -a /dev/vdx1' "$RD/out")"

# --- (d) mask helpers over recorded tool output -----------------------------------------
F=$FIX/raw
ext_a=$(masks_from_dumpe2fs < "$F/dumpe2fs-h.txt")
assert_eq  "ext canonical form"                       "ext|features=64bit,dir_index,dir_nlink,ext_attr,extent,extra_isize,filetype,flex_bg,has_journal,huge_file,large_file,resize_inode,sparse_super,uninit_bg|journal=-" "$ext_a"
assert_ok  "ext masks equal to themselves"            masks_equal "$ext_a" "$ext_a"
ext_b=$(sed 's/^Filesystem features:      has_journal ext_attr resize_inode/Filesystem features:      resize_inode ext_attr has_journal/; s/^Journal features:         journal_incompat_revoke journal_64bit/Journal features:         journal_64bit journal_incompat_revoke/' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_ok  "ext: shuffled feature lists are equal (sets)"   masks_equal "$ext_a" "$ext_b"
assert_eq  "ext: no diff for shuffled lists"          "" "$(masks_diff "$ext_a" "$ext_b")"
ext_c=$(sed 's/^\(Filesystem features:.*\)$/\1 metadata_csum/' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_fail "ext: an extra feature -> not equal"      masks_equal "$ext_a" "$ext_c"
assert_eq  "ext: diff names the extra feature"        "features: donor-only none, target-only metadata_csum" "$(masks_diff "$ext_a" "$ext_c")"
assert_eq  "ext: diff the other way round"            "features: donor-only metadata_csum, target-only none" "$(masks_diff "$ext_c" "$ext_a")"
# journal flags are set by jbd2 on the first mount, never by mke2fs: a fresh
# target always shows "(none)" and must still match a used donor (stand phase B)
ext_d=$(sed 's/^Journal features:.*/Journal features:         (none)/' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_ok  "ext: journal flags are ignored (kernel-set)" masks_equal "$ext_a" "$ext_d"
assert_eq  "ext: no journal diff reported"            "" "$(masks_diff "$ext_a" "$ext_d")"
ext_h=$(sed 's/has_journal //' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_fail "ext: has_journal itself is still compared" masks_equal "$ext_a" "$ext_h"
ext_e=$(sed 's/needs_recovery //; s/^Filesystem state:.*/Filesystem state:         clean/' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_ok  "ext: needs_recovery (a state flag) is ignored" masks_equal "$ext_a" "$ext_e"
ext_n=$(sed 's/^Journal features:.*/Journal features:         (none)/' "$F/dumpe2fs-h.txt" | masks_from_dumpe2fs)
assert_has "ext: no journal -> journal=-"             "|journal=-" "$ext_n"
assert_ok  "ext: journal (none) equals a used journal (kernel-set flags)" masks_equal "$ext_a" "$ext_n"
assert_eq  "masks_norm ext from the plan's encoding"  "ext|features=ext_attr,has_journal|journal=-" "$(masks_norm ext "$(ap_dec 'features:has_journal%20ext_attr|journal:journal_64bit')")"
assert_eq  "masks_norm ext without a journal part"    "ext|features=ext_attr|journal=-" "$(masks_norm ext 'features:ext_attr')"
xfs_x=$(masks_from_xfs_db < "$F/xfs_db.txt")
assert_eq  "xfs canonical form"                       "xfs|versionnum=46245|features2=394|compat=0|ro_compat=15|incompat=43|log_incompat=0|features=ALIGN,ATTR2,BIGTIME,CRC,DIRV2,EXTFLG,FINOBT,FTYPE,INOBTCNT,LAZYSBCOUNT,LOGV2,MOREBITS,NLINK,NREXT64,PROJID32BIT,REFLINK,RMAPBT,SPARSE_INODES,V5" "$xfs_x"
xfs_y=$(sed 's/^features_incompat = 0x2b/features_incompat = 0x3b/' "$F/xfs_db.txt" | masks_from_xfs_db)
assert_fail "xfs: a different incompat mask -> not equal" masks_equal "$xfs_x" "$xfs_y"
assert_eq  "xfs: diff prints the masks in hex"        "incompat: donor 0x2b, target 0x3b" "$(masks_diff "$xfs_x" "$xfs_y")"
xfs_z=$(sed 's/^versionnum \[0xb4a5+0x18a\] = V5,NLINK/versionnum [0xb4a5+0x18a] = NLINK,V5/' "$F/xfs_db.txt" | masks_from_xfs_db)
assert_ok  "xfs: shuffled names are equal"            masks_equal "$xfs_x" "$xfs_z"
xfs_p=$(masks_norm xfs "$(ap_dec 'versionnum=0xb4b5%2Cfeatures2=0x18a%2Ccompat=0x0%2Cro_compat=0x1%2Cincompat=0x1%2Clog_incompat=0x0')")
assert_eq  "masks_norm xfs from the plan's encoding"  "xfs|versionnum=46245|features2=394|compat=0|ro_compat=1|incompat=1|log_incompat=0|features=?" "$xfs_p"
assert_ok  "xfs: unknown donor names match any names" masks_equal "$xfs_p" "xfs|versionnum=46245|features2=394|compat=0|ro_compat=1|incompat=1|log_incompat=0|features=CRC,FINOBT,FTYPE"
assert_fail "xfs: unknown names do not hide a mask difference" masks_equal "$xfs_p" "xfs|versionnum=46245|features2=394|compat=0|ro_compat=1|incompat=3|log_incompat=0|features=CRC,FINOBT,FTYPE"
assert_eq  "masks_norm xfs with names"                "xfs|versionnum=46245|features2=394|compat=0|ro_compat=1|incompat=1|log_incompat=0|features=CRC,FINOBT,FTYPE" "$(masks_norm xfs "versionnum=0xb4b5,features2=0x18a,compat=0x0,ro_compat=0x1,incompat=0x1,log_incompat=0x0" "CRC,FINOBT,FTYPE")"
# versionnum 0xb4b5 above carries ATTRBIT (0x10), set by the kernel on the first
# xattr and never by mkfs.xfs: the canonical form drops it (0xb4a5 = 46245), as it
# drops QUOTABIT (0x40) and the ATTR/QUOTA names (stand phase B, smaller: a fresh
# xfs root was refused against a used donor over exactly this bit)
xfs_used=$(masks_norm xfs "versionnum=0xb4f5,features2=0x18a,compat=0,ro_compat=0xd,incompat=0xb,log_incompat=0" "V5,NLINK,ATTR,QUOTA,CRC,FTYPE")
xfs_fresh=$(masks_norm xfs "versionnum=0xb4a5,features2=0x18a,compat=0,ro_compat=0xd,incompat=0xb,log_incompat=0" "V5,NLINK,CRC,FTYPE")
assert_ok  "xfs: a used donor (ATTR, QUOTA set by the kernel) equals a fresh target" masks_equal "$xfs_used" "$xfs_fresh"
assert_eq  "xfs: ATTR/QUOTA dropped from versionnum and the names" "xfs|versionnum=46245|features2=394|compat=0|ro_compat=13|incompat=11|log_incompat=0|features=CRC,FTYPE,NLINK,V5" "$xfs_used"
assert_fail "xfs: a real versionnum difference (NLINK) is still seen" masks_equal "$xfs_fresh" "$(masks_norm xfs "versionnum=0xb485,features2=0x18a,compat=0,ro_compat=0xd,incompat=0xb,log_incompat=0" "V5,CRC,FTYPE")"
assert_fail "ext vs xfs -> not equal"                 masks_equal "$ext_a" "$xfs_x"
assert_eq  "type diff"                                "type: donor ext, target xfs" "$(masks_diff "$ext_a" "$xfs_x")"
assert_fail "masks_norm of an unknown type fails"     masks_norm btrfs x
assert_fail "masks_of_fs on a missing device fails"   masks_of_fs "$W/nonexistent" ext4
# shellcheck disable=SC2317  # called through assert_fail
garbage() { echo nonsense | masks_from_dumpe2fs; }
assert_fail "masks_from_dumpe2fs on garbage fails"    garbage

# --- (e) node names, the plan's disk -----------------------------------------------------
assert_eq "partnode sda 3"        /dev/sda3        "$(apply_partnode /dev/sda 3)"
assert_eq "partnode nvme0n1 3"    /dev/nvme0n1p3   "$(apply_partnode /dev/nvme0n1 3)"
assert_eq "partnode mmcblk0 1"    /dev/mmcblk0p1   "$(apply_partnode /dev/mmcblk0 1)"
assert_eq "partnode md0 128"      /dev/md0p128     "$(apply_partnode /dev/md0 128)"
assert_eq "apply_target_disk PLAN" /dev/sda        "$(apply_target_disk "$C/expected.plan")"
assert_eq "apply_target_disk default \$RUN/plan" /dev/vda "$(RUN=$W/gptbios apply_target_disk)"
assert_eq "ptuuid normalised: 0x and case"  0badcafe "$(ap_ptuuid_norm 0x0BADCAFE)"
assert_eq "ptuuid normalised: - is none"    ""       "$(ap_ptuuid_norm -)"
assert_eq "gib is an integer floor"          894      "$(ap_gib 960197124096)"

# --- (f) the post-apply fingerprint check against a fake state and the shims --------------
FP=$W/fp; mkdir -p "$FP"
( RUN=$FP; state_set target.disk /dev/fake; state_set target.id serial:S123; state_set target.size 1000
  state_set target.ptuuid abcd1234; state_set target.parts "/dev/fake1:abcd1234-01,/dev/fake2:abcd1234-02" )
cat > "$FP/vals" <<'EOF'
WWN=
SERIAL=S123
MODEL='Fake Disk'
PTUUID=abcd1234
SIZE=1000
LSEC=512
PSEC=512
HEAD=
TREE='PATH="/dev/fake" TYPE="disk" PARTUUID="" MOUNTPOINT=""
PATH="/dev/fake1" TYPE="part" PARTUUID="abcd1234-01" MOUNTPOINT=""
PATH="/dev/fake2" TYPE="part" PARTUUID="abcd1234-02" MOUNTPOINT=""'
EOF
# fp VALS [DRY]: apply_fingerprint_check in a subshell on the shims; output in $FP/out, status echoed
fp() { ( RUN=$FP; DRY=${2:-}; export SHIM_VALS=$1; PATH=$SHIM:$PATH; apply_fingerprint_check ) > "$FP/out" 2>&1; echo $?; }
assert_eq  "fingerprint: matches -> 0"                    0 "$(fp "$FP/vals")"
assert_eq  "fingerprint: matches -> silent"               "" "$(cat "$FP/out")"
sed 's/^SERIAL=.*/SERIAL=S999/' "$FP/vals" > "$FP/vals-serial"
assert_eq  "fingerprint: serial changed -> exit 2"        2 "$(fp "$FP/vals-serial")"
assert_has "fingerprint: serial changed -> says so"       "changed since apply: /dev/fake id: recorded serial:S123, now serial:S999" "$(cat "$FP/out")"
sed 's/^SIZE=.*/SIZE=1001/' "$FP/vals" > "$FP/vals-size"
assert_eq  "fingerprint: size changed -> exit 2"          2 "$(fp "$FP/vals-size")"
assert_has "fingerprint: size changed -> says so"         "size: recorded 1000, now 1001" "$(cat "$FP/out")"
sed 's/^PTUUID=.*/PTUUID=0x0000ffff/' "$FP/vals" > "$FP/vals-pt"
assert_eq  "fingerprint: label-id changed -> exit 2"      2 "$(fp "$FP/vals-pt")"
assert_has "fingerprint: label-id changed -> says so"     "ptuuid: recorded abcd1234, now 0000ffff" "$(cat "$FP/out")"
sed 's/abcd1234-02/abcd1234-03/' "$FP/vals" > "$FP/vals-parts"
assert_eq  "fingerprint: a partuuid changed -> exit 2"    2 "$(fp "$FP/vals-parts")"
assert_has "fingerprint: a partuuid changed -> says so"   "partitions: recorded /dev/fake1:abcd1234-01,/dev/fake2:abcd1234-02, now /dev/fake1:abcd1234-01,/dev/fake2:abcd1234-03" "$(cat "$FP/out")"
sed 's/^WWN=.*/WWN=0x5000c500deadbeef/' "$FP/vals" > "$FP/vals-wwn"
assert_eq  "fingerprint: a wwn that appeared -> exit 2"   2 "$(fp "$FP/vals-wwn")"
assert_eq  "fingerprint: under -n a mismatch is a no-op"  0 "$(fp "$FP/vals-serial" y)"
rm -f "$FP/failure"
out=$( ( RUN=$FP; export SHIM_VALS=$FP/vals-serial; PATH=$SHIM:$PATH; apply_fingerprint_verify ); echo "rc=$?" )
assert_has "fingerprint_verify: reports without dying"    "id: recorded serial:S123, now serial:S999" "$out"
assert_has "fingerprint_verify: returns 1"                "rc=1" "$out"
assert_fail "fingerprint_verify: no failure record"       test -e "$FP/failure"
mkdir -p "$W/nostate"
out=$( ( RUN=$W/nostate; apply_fingerprint_verify ); echo "rc=$?" )
assert_has "fingerprint_verify: no state -> says so"      "no post-apply fingerprint" "$out"
( RUN=$W/nostate; DRY=; apply_fingerprint_check ) >/dev/null 2>&1; rc=$?
assert_eq  "fingerprint_check: no state -> exit 2"        2 "$rc"

# --- (g) cleanup_all: no-op on an empty state dir, undoes setro/lock, never dies -----------
E=$W/empty; mkdir -p "$E"
if [ -d /mnt/migrator ]; then
	skip "cleanup_all on an empty \$RUN (real)" "/mnt/migrator exists on this host"
else
	( RUN=$E; DRY=; cleanup_all ) > "$E/out" 2>&1; rc=$?
	assert_eq  "cleanup_all: empty \$RUN returns 0"        0 "$rc"
	assert_has "cleanup_all: nothing to undo"              "cleanup: done, nothing to undo" "$(cat "$E/out")"
	assert_eq  "cleanup_all: ran no command"               0 "$(grep -c '^+ ' "$E/out")"
	assert_fail "cleanup_all: left no state"               test -e "$E/state"
fi
( RUN=$E; DRY=y; state_set setro.disks "/dev/sdzz,/dev/sdzy" 2>/dev/null; cleanup_all ) > "$E/out2" 2>&1; rc=$?
assert_eq  "cleanup_all -n: returns 0"                    0 "$rc"
in_order "cleanup_all -n: setrw for every state disk" "$E/out2" "(dry) blockdev --setrw /dev/sdzz" "(dry) blockdev --setrw /dev/sdzy" "cleanup: done (setrw /dev/sdzz setrw /dev/sdzy)"
assert_eq  "cleanup_all -n: state untouched"              "/dev/sdzz,/dev/sdzy" "$(RUN=$E state_get setro.disks)"
: > "$E/lock"
( RUN=$E; DRY=; findmnt() { :; }; cleanup_all ) > "$E/out3" 2>&1; rc=$?
assert_eq  "cleanup_all: returns 0 with work to do"       0 "$rc"
assert_fail "cleanup_all: removes an unheld lock"         test -e "$E/lock"
assert_eq  "cleanup_all: setro.disks cleared after setrw" "-" "$(RUN=$E state_get setro.disks)"
assert_has "cleanup_all: a bogus disk is a WARN, not a death" "WARN: cleanup: blockdev --setrw /dev/sdzz failed" "$(cat "$E/out3")"
( RUN=$E; DRY=; findmnt() { :; }; lock; cleanup_all ) > "$E/out4" 2>&1; rc=$?
assert_eq  "cleanup_all: returns 0 while the lock is held" 0 "$rc"
assert_has "cleanup_all: a held lock is left in place"    "is held by a running migrator, left in place" "$(cat "$E/out4")"
( RUN=$E; DRY=; findmnt() { :; }; cleanup_add "echo registered-ran >> $E/reg"; cleanup_all ) > "$E/out5" 2>&1
assert_eq  "cleanup_all: runs the registered snippets"    "registered-ran" "$(cat "$E/reg")"
assert_has "cleanup_all: counts them"                     "1 registered actions" "$(cat "$E/out5")"

# --- (h) waiting and stopping ---------------------------------------------------------------
out=$( ( DRY=; apply_wait_nodes /dev/null "$REPO/lib/apply.sh" ); echo "rc=$?" )
assert_has "wait_nodes: present nodes -> 0"               "rc=0" "$out"
out=$( ( DRY=; APPLY_NODE_TIMEOUT=1; apply_wait_nodes /dev/null "$W/no-such-node" ) 2>&1; echo "rc=$?" )
assert_has "wait_nodes: a missing node -> exit 1"         "rc=1" "$out"
assert_has "wait_nodes: names the missing node"           "did not appear within 1s: $W/no-such-node" "$out"
assert_eq  "wait_nodes -n: prints one would-wait line"    "(dry) would wait up to 30s for: /dev/x /dev/y" "$(DRY=y apply_wait_nodes /dev/x /dev/y)"
assert_eq  "wait_nodes: nothing to wait for -> silent"    "" "$(DRY=y apply_wait_nodes)"
assert_eq  "md_stop_retry -n: settle then stop, once"     "(dry) udevadm settle
(dry) mdadm --stop /dev/md127" "$(DRY=y md_stop_retry /dev/md127)"
printf 'Personalities : [raid1]\nmd127 : active raid1 vdb1[1] vda1[0]\n      1046528 blocks super 1.2 [2/2] [UU]\nmd126 : active raid1 nvme0n1p2[0] nvme1n1p2[1]\n      5237760 blocks super 1.2 [2/2] [UU]\nunused devices: <none>\n' > "$W/mdstat"
assert_eq  "md on disk: vda -> md127"                     /dev/md127 "$(apply_md_on_disk /dev/vda "$W/mdstat")"
assert_eq  "md on disk: nvme0n1 -> md126 (p numbering)"   /dev/md126 "$(apply_md_on_disk /dev/nvme0n1 "$W/mdstat")"
assert_eq  "md on disk: vdc -> none"                      ""         "$(apply_md_on_disk /dev/vdc "$W/mdstat")"
assert_eq  "md on disk: vd is not a prefix match"         ""         "$(apply_md_on_disk /dev/vd "$W/mdstat")"

t_end
