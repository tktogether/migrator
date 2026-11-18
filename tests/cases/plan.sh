#!/bin/bash
# tests/cases/plan.sh — lib/plan.sh over tests/fixtures/<case>/{donor.inv,recipient.inv,expected.plan}:
# the pure core (plan_compute) is diffed against every expected.plan (volatile header
# fields normalised) AND key facts are asserted explicitly per case: elastic slot last
# and the size arithmetic (Σ sizes + first/last MiB == disk), type conversions,
# numbering, identity rewrites, mkfs flags, [lvm] lines, refusal codes and messages.
# Then plan_check is green on every expected.plan and red after hand corruptions,
# plan_build writes $RUN/plan and prints the summary, and the driver's "check" wiring
# is exercised with bin/reloca.to -n. No root, no devices: everything is text.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO/lib/plan.sh"
FIX=$REPO/tests/fixtures
RELOCA_LIB=$REPO/lib; export RELOCA_LIB     # reloca_version() needs it, as under the driver
W=$RUN/plan-work; mkdir -p "$W"
MIB=1048576

# --- helpers -------------------------------------------------------------------
# norm FILE: the header fields that legitimately differ between runs
norm() { sed -e 's/^# inv_sha256=[^ ]*/# inv_sha256=X/' -e 's/  reloca=[^ ]*/  reloca=X/' -e 's/  live=[^ ]*/  live=X/' -e 's/  date=[^ ]*/  date=X/' "$1"; }
# compute CASE [DISK] [key=value...]: run the pure core -> $W/CASE.{out,err,rc}
compute() { local c=$1; shift; plan_compute "$FIX/$c/donor.inv" "$FIX/$c/recipient.inv" "${1:-auto}" "${@:2}" > "$W/$c.out" 2> "$W/$c.err"; echo $? > "$W/$c.rc"; }
rc()    { cat "$W/$1.rc"; }
pget()  { plan_get "$W/$1.out" "$2" "$3"; }                                   # CASE SECTION KEY
row()   { plan_section "$W/$1.out" volumes | grep "^src=$2	"; }                # CASE SRC -> the volumes row
rowf()  { pl_field "$(row "$1" "$2")" "$3"; }                                  # CASE SRC FIELD
sfd()   { plan_section "$W/$1.out" sfdisk | grep "^$2 :"; }                    # CASE DEV -> its sfdisk line
ident() { plan_section "$W/$1.out" identity | grep "^$2	" | cut -f2; }        # CASE SPEC -> action
warns() { grep -c '^# WARN: ' "$W/$1.out"; }
# diff_case CASE: normalised output == normalised expected.plan
diff_case() {
	if diff -u <(norm "$FIX/$1/expected.plan") <(norm "$W/$1.out") > "$W/$1.diff"; then _pass "$1: matches expected.plan"
	else _fail "$1: matches expected.plan" "see $W/$1.diff: $(head -c 300 "$W/$1.diff" | tr '\n' ' ')"; fi
}
# layout_ok CASE: partitions are contiguous from the first MiB, and Σ sizes + first MiB + last MiB
# == disk size floored to MiB (the whole disk is used, the elastic slot took the rest)
# shellcheck disable=SC2317  # called through assert_ok
layout_ok() {
	local c=$1 size lsec sum=0 pos=$MIB dev start psize ok=1
	size=$(pget "$c" target size); lsec=$(pget "$c" target lsec)
	while read -r dev start psize; do
		[ $(( start * lsec )) -eq "$pos" ] || { ok=0; echo "    $dev starts at $((start * lsec)), expected $pos"; }
		pos=$(( pos + psize * lsec )); sum=$(( sum + psize * lsec ))
	done < <(plan_sfdisk "$W/$c.out" | sort -k2,2n)
	[ "$ok" = 1 ] && [ $(( sum + 2 * MIB )) -eq $(( size / MIB * MIB )) ]
}
# elastic_last CASE: the row noted elastic is the physically last partition of [sfdisk]
# (raid=1: the array's first member is)
# shellcheck disable=SC2317  # called through assert_ok
elastic_last() {
	local c=$1 last el m
	last=$(plan_sfdisk "$W/$c.out" | sort -k2,2n | tail -1 | cut -d' ' -f1)
	el=$(plan_section "$W/$c.out" volumes | grep 'notes=[^	]*elastic' | head -1 | sed 's/.*	target=\([^	]*\).*/\1/')
	m=$(plan_md "$W/$c.out" | awk -v d="$el" '$1 == d { print $2 }'); [ -z "$m" ] || el=$m
	[ -n "$el" ] && [ "$el" = "$last" ]
}
n_sfdisk() { plan_sfdisk "$W/$1.out" | wc -l; }

# --- 1. debian-md-ext4-bios ------------------------------------------------------
c=debian-md-ext4-bios; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_eq  "$c: no warnings"                      0 "$(warns $c)"
assert_eq  "$c: stderr empty"                     "" "$(cat "$W/$c.err")"
assert_eq  "$c: label dos kept"                   dos "$(pget $c target label)"
assert_eq  "$c: no bios_grub on dos"              - "$(pget $c target bios_grub)"
assert_eq  "$c: tuple id on virtio"               "model:-" "$(pget $c target id)"
assert_eq  "$c: head is not computed by the core" - "$(pget $c target head)"
assert_eq  "$c: three partitions"                 3 "$(n_sfdisk $c)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: elastic slot is physically last"  elastic_last $c
assert_has "$c: md member fd -> 83 on /boot"      "type=83, bootable" "$(sfd $c /dev/vda1)"
assert_has "$c: swap type 82"                     "type=82" "$(sfd $c /dev/vda2)"
assert_eq  "$c: exactly one bootable flag"        1 "$(plan_section "$W/$c.out" sfdisk | grep -c bootable)"
assert_eq  "$c: /boot block"                      block "$(rowf $c /dev/md0 method)"
assert_eq  "$c: /boot slot 1024 MiB > md 1023 MiB -> grow" grow "$(rowf $c /dev/md0 notes)"
assert_eq  "$c: root files (fs > slot)"           files "$(rowf $c /dev/md1 method)"
assert_eq  "$c: root tsize 906497 MiB"            950530998272 "$(rowf $c /dev/md1 tsize)"
assert_eq  "$c: root notes elastic, no grow"      elastic "$(rowf $c /dev/md1 notes)"
assert_eq  "$c: mkfs.ext4 explicit"               "mkfs.ext4 -F -U 0d9e8f7a-2222-4b1c-8a3d-5e6f7a8b9c01 -b 4096 -I 256 -N 60456960 -O none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum /dev/vda3" "$(plan_section "$W/$c.out" mkfs | grep mkfs.ext4)"
assert_eq  "$c: mkswap with the donor uuid"       "mkswap -U 3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02 /dev/vda2" "$(plan_section "$W/$c.out" mkfs | grep mkswap)"
assert_eq  "$c: no mkfs for the block /boot"      0 "$(plan_section "$W/$c.out" mkfs | grep -c vda1)"
assert_eq  "$c: /dev/md0 -> UUID"                 "-> UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50" "$(ident $c /dev/md0)"
assert_eq  "$c: UUID root spec kept"              keep "$(ident $c UUID=0d9e8f7a-2222-4b1c-8a3d-5e6f7a8b9c01)"
assert_eq  "$c: [lvm] empty"                      "" "$(plan_section "$W/$c.out" lvm)"
assert_eq  "$c: postfix os_root/boot"             "/dev/vda3 /dev/vda1 -" "$(pget $c postfix os_root) $(pget $c postfix boot) $(pget $c postfix esp)"
assert_eq  "$c: drivers virtio-pci -> virtio_pci" "virtio_blk,virtio_pci,virtio_net" "$(pget $c verify drivers)"
assert_eq  "$c: transfer order swap, /boot, / last" "/dev/sda2 /dev/md0 /dev/md1" "$(plan_section "$W/$c.out" volumes | sed 's/^src=\([^	]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//')"
assert_eq  "$c: guard comment per fs volume"      2 "$(grep -c '^# guard: .* ok$' "$W/$c.out")"
assert_eq  "$c: inv_sha256 is the sha256 of both files" "$(sha256sum "$FIX/$c/donor.inv" | cut -c1-64):$(sha256sum "$FIX/$c/recipient.inv" | cut -c1-64)" "$(sed -n 's/^# inv_sha256=\([^ ]*\).*/\1/p' "$W/$c.out")"
# options on the same fixture
compute $c auto root=block
assert_eq  "$c root=block: refused (does not fit)" 4 "$(rc $c)"
assert_has "$c root=block: says short by"         "does not fit /dev/vda3" "$(tail -1 "$W/$c.out")"
compute $c auto label=gpt
assert_eq  "$c label=gpt: gpt with bios_grub 128" "gpt 128 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target pmbr_boot)"
assert_has "$c label=gpt: dos->gpt warned"        "partition table dos -> gpt" "$(cat "$W/$c.err")"
assert_has "$c label=gpt: bios_grub first"        "/dev/vda128 : start=2048, size=2048, type=21686148-6449-6E6F-744E-656564454649" "$(sfd $c /dev/vda128)"
assert_ok  "$c label=gpt: layout still packs"     layout_ok $c
compute $c auto driver=mpt3sas,virtio-scsi compress=zstd data=raw nic-pin=0
assert_eq  "$c driver=: appended, normalised"     "virtio_blk,virtio_pci,virtio_net,mpt3sas,virtio_scsi" "$(pget $c verify drivers)"
assert_has "$c driver=: unknown extra is a WARN"  "driver mpt3sas (from driver=) is in no donor kernel" "$(cat "$W/$c.err")"
assert_eq  "$c options land in [target]/[network]" "raw zstd 0" "$(pget $c target data) $(pget $c target compress) $(pget $c network pin)"
compute $c auto label=bogus
assert_eq  "$c: bad option value exits 4"         4 "$(rc $c)"
compute $c /dev/vda
assert_eq  "$c: explicit disk accepted"           0 "$(rc $c)"
compute $c /dev/sdz
assert_eq  "$c: unknown explicit disk refused"    4 "$(rc $c)"
assert_has "$c: unknown disk names the inventory disks" "not in the recipient inventory (disks: /dev/vda" "$(tail -1 "$W/$c.out")"

# --- 2. centos7-md-lvm-xfs-bios ----------------------------------------------------
c=centos7-md-lvm-xfs-bios; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_eq  "$c: id from wwn"                      "wwn:0x6d0946606e5ad1002a1f2b3c4d5e6f70" "$(pget $c target id)"
assert_has "$c: currently shows the old OS"       'old-os:"web3%20Ubuntu' "$(pget $c target currently)"
assert_eq  "$c: dos kept, 4 primaries"            "dos 4" "$(pget $c target label) $(n_sfdisk $c)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: elastic (PV) is last"             elastic_last $c
assert_eq  "$c: PV renumbered 3->4, elastic"      "elastic,renumbered%203->4" "$(rowf $c /dev/md126 notes)"
assert_eq  "$c: PV tsize"                         989987864576 "$(rowf $c /dev/md126 tsize)"
assert_eq  "$c: sdb2 appended from the other disk" "/dev/sda3 from-other-disk,renumbered%202->3" "$(rowf $c /dev/sdb2 target) $(rowf $c /dev/sdb2 notes)"
assert_has "$c: WARN extra slots"                 "appended to /dev/sda as extra slots: /dev/sdb2(swap)" "$(cat "$W/$c.err")"
assert_has "$c: WARN renumbered"                  "partitions are renumbered" "$(cat "$W/$c.err")"
assert_has "$c: md member fd -> 8e for the PV"    "type=8e" "$(sfd $c /dev/sda4)"
assert_has "$c: /boot fd -> 83 bootable"          "type=83, bootable" "$(sfd $c /dev/sda1)"
assert_eq  "$c: [lvm] lines"                      "pvcreate -ff -y --uuid Zx1yQ2-abcd-efgh-ijkl-mnop-qrst-uvwxYZ --norestorefile /dev/sda4|vgcreate centos /dev/sda4|lvcreate -y -n swap -L 4294967296b centos|lvcreate -y -n root -l 100%FREE centos" "$(plan_section "$W/$c.out" lvm | tr '\n' '|' | sed 's/|$//')"
assert_eq  "$c: root LV files, tsize = PV - swap - 4 MiB rounded to PE" "files 985686605824 /" "$(rowf $c /dev/centos/root method) $(rowf $c /dev/centos/root tsize) $(rowf $c /dev/centos/root mount)"
assert_eq  "$c: swap LV kept at 4 GiB (under the cap)" "4294967296 mkswap" "$(rowf $c /dev/centos/swap tsize) $(rowf $c /dev/centos/swap method)"
assert_eq  "$c: mkfs.xfs flags from the donor"    "mkfs.xfs -f -m crc=1,finobt=1,reflink=0,rmapbt=0,bigtime=0,inobtcount=0,uuid=d3e4f5a6-b7c8-4d9e-8f0a-1b2c3d4e5f60 -i sparse=0,nrext64=0,size=512 -n ftype=1,size=4096 -b size=4096 -s size=512 /dev/centos/root" "$(plan_section "$W/$c.out" mkfs | grep mkfs.xfs)"
assert_eq  "$c: three mkswap lines"               3 "$(plan_section "$W/$c.out" mkfs | grep -c '^mkswap')"
assert_eq  "$c: rd.md.uuid removed"               "remove remove" "$(ident $c rd.md.uuid=9b8a7c6d:5e4f3a2b:1c0d9e8f:7a6b5c4d) $(ident $c rd.md.uuid=2e3f4a5b:6c7d8e9f:0a1b2c3d:4e5f6a7b)"
assert_eq  "$c: rd.lvm.lv kept"                   "keep keep" "$(ident $c rd.lvm.lv=centos/root) $(ident $c rd.lvm.lv=centos/swap)"
assert_eq  "$c: /dev/mapper kept"                 "keep keep" "$(ident $c /dev/mapper/centos-root) $(ident $c /dev/mapper/centos-swap)"
assert_eq  "$c: postfix rhel"                     "rhel dracut i386-pc autorelabel neutralise keep" "$(pget $c postfix family) $(pget $c postfix initramfs) $(pget $c postfix grub) $(pget $c postfix selinux) $(pget $c postfix lvm_filter) $(pget $c postfix lvm_devices_file)"
assert_eq  "$c: pins by PCI order"                "eth0:b0:83:fe:00:00:01,eth1x:b0:83:fe:00:00:02,eth2x:b0:83:fe:00:00:03,eth3x:b0:83:fe:00:00:04" "$(pget $c network pins)"
assert_has "$c: multi-NIC WARN"                   "recipient has 4 NICs" "$(cat "$W/$c.err")"
assert_eq  "$c: donor network line"               "eno1/3c:ec:ef:11:22:33/ifcfg" "$(pget $c network donor)"
assert_eq  "$c: verify swap uuids"                "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e,c2d3e4f5-a6b7-4c8d-9e0f-1a2b3c4d5e6f,e4f5a6b7-c8d9-4e0f-9a1b-2c3d4e5f6071" "$(pget $c verify swap)"
assert_has "$c: xfs masks with %2C"               "/dev/centos/root:xfs:versionnum=0xb4b5%2Cfeatures2=0x18a" "$(pget $c verify features)"
assert_eq  "$c: pv row first, root last"          "/dev/md126 /dev/centos/root" "$(plan_section "$W/$c.out" volumes | sed -n '1p;$p' | sed 's/^src=\([^	]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//')"
assert_eq  "$c: drivers checked in both kernels"  "megaraid_sas,igb" "$(pget $c target driver)"

# --- 3. ubuntu-nvme-uefi-to-bios-vm --------------------------------------------------
c=ubuntu-nvme-uefi-to-bios-vm; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_has "$c: cross-firmware WARN (deb)"        "firmware change uefi -> bios" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt kept, bios_grub 128, esp 1"   "gpt 128 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target esp)"
assert_eq  "$c: grub_from_live + pmbr_boot"       "1 1" "$(pget $c target grub_from_live) $(pget $c target pmbr_boot)"
assert_eq  "$c: bios_grub is the first partition" "/dev/vda128" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -1 | cut -d' ' -f1)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: root elastic last"                elastic_last $c
assert_has "$c: donor partition uuids kept"       "uuid=11111111-aaaa-4bbb-8ccc-000000000003" "$(sfd $c /dev/vda3)"
assert_eq  "$c: ESP slot kept, esp method"        "esp /dev/vda1 /boot/efi" "$(rowf $c /dev/nvme0n1p1 method) $(rowf $c /dev/nvme0n1p1 target) $(rowf $c /dev/nvme0n1p1 mount)"
assert_has "$c: ESP kept WARN"                    "kept as a slot on the bios recipient" "$(cat "$W/$c.err")"
assert_eq  "$c: mkfs.vfat with the volid"         "mkfs.vfat -F32 -i A1B2C3D4 /dev/vda1" "$(plan_section "$W/$c.out" mkfs | grep vfat)"
assert_eq  "$c: root files (474 GiB fs > 370 GiB slot)" "files 397311737856" "$(rowf $c /dev/nvme0n1p3 method) $(rowf $c /dev/nvme0n1p3 tsize)"
assert_eq  "$c: /boot block, no grow (same size)" "block -" "$(rowf $c /dev/nvme0n1p2 method) $(rowf $c /dev/nvme0n1p2 notes)"
assert_eq  "$c: swapfile kept"                    keep "$(ident $c /swapfile)"
assert_eq  "$c: postfix grub i386-pc, cloud-init disabled, esp" "i386-pc disable /dev/vda1" "$(pget $c postfix grub) $(pget $c postfix cloudinit) $(pget $c postfix esp)"
assert_has "$c: modalias not checked WARN"        "not checked against the donor kernels" "$(cat "$W/$c.err")"
assert_eq  "$c: verify esp and no swap"           "/dev/vda1 -" "$(pget $c verify esp) $(pget $c verify swap)"
compute $c auto cloudinit=keep
assert_eq  "$c cloudinit=keep"                    keep "$(pget $c postfix cloudinit)"

# --- 4. debian-boot-root-swap-bios ---------------------------------------------------
c=debian-boot-root-swap-bios; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_eq  "$c: dos kept"                         dos "$(pget $c target label)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: root (elastic) moved last"        elastic_last $c
assert_eq  "$c: swap renumbered 3->2"             "/dev/sda2 renumbered%203->2" "$(rowf $c /dev/sda3 target) $(rowf $c /dev/sda3 notes)"
assert_eq  "$c: root renumbered 2->3, block, grow" "/dev/sda3 block elastic,renumbered%202->3,grow" "$(rowf $c /dev/sda2 target) $(rowf $c /dev/sda2 method) $(rowf $c /dev/sda2 notes)"
assert_eq  "$c: root tsize"                       994833334272 "$(rowf $c /dev/sda2 tsize)"
assert_has "$c: WARN renumbered"                  "partitions are renumbered" "$(cat "$W/$c.err")"
assert_eq  "$c: fstab UUIDs kept"                 "keep keep keep" "$(ident $c UUID=ad1e2f3a-4b5c-4d6e-9f70-8192a3b4c5d6) $(ident $c UUID=9c0d1e2f-3a4b-4c5d-8e6f-7a8b9c0d1e2f) $(ident $c UUID=be2f3a4b-5c6d-4e7f-8091-a2b3c4d5e6f7)"
assert_eq  "$c: resume=UUID kept"                 keep "$(ident $c resume=UUID=be2f3a4b-5c6d-4e7f-8091-a2b3c4d5e6f7)"
assert_eq  "$c: no mkfs, one mkswap"              "1 0" "$(plan_section "$W/$c.out" mkfs | grep -c '^mkswap') $(plan_section "$W/$c.out" mkfs | grep -c '^mkfs')"
assert_has "$c: guard knows orphan_file:5.15 vs 6.1" "needs=orphan_file:5.15 ok" "$(grep '^# guard: /dev/sda3' "$W/$c.out")"
assert_has "$c: bootable on /boot"                "bootable" "$(sfd $c /dev/sda1)"
# on the fly: the same donor onto a uefi recipient -> a new ESP (R5 esp-new)
mkdir -p "$W/uefi"; cp "$FIX/$c/donor.inv" "$W/uefi/"; sed 's/\tfw=bios\t/\tfw=uefi\t/' "$FIX/$c/recipient.inv" > "$W/uefi/recipient.inv"
plan_compute "$W/uefi/donor.inv" "$W/uefi/recipient.inv" auto > "$W/uefi.out" 2> "$W/uefi.err"; echo $? > "$W/uefi.rc"; c=uefi
assert_eq  "bios->uefi: exit 0"                   0 "$(rc $c)"
assert_eq  "bios->uefi: gpt, no bios_grub, esp 4, grub_from_live" "gpt - 4 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target esp) $(pget $c target grub_from_live)"
assert_eq  "bios->uefi: esp-new row"              "esp /dev/sda4 536870912 /boot/efi esp-new" "$(rowf $c - method) $(rowf $c - target) $(rowf $c - tsize) $(rowf $c - mount) $(rowf $c - notes)"
assert_eq  "bios->uefi: new ESP is physically first" "/dev/sda4" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -1 | cut -d' ' -f1)"
assert_has "bios->uefi: mkfs.vfat for the new ESP" "mkfs.vfat -F32 -i " "$(plan_section "$W/$c.out" mkfs | grep 'sda4$')"
assert_has "bios->uefi: fstab line to add"        "	+ /boot/efi vfat umask=0077 0 1" "$(plan_section "$W/$c.out" identity | grep '^UUID=[0-9A-F]\{4\}-[0-9A-F]\{4\}	')"
assert_has "bios->uefi: WARN new ESP"             "donor has no ESP" "$(cat "$W/$c.err")"
assert_eq  "bios->uefi: postfix grub x86_64-efi, esp" "x86_64-efi /dev/sda4" "$(pget $c postfix grub) $(pget $c postfix esp)"
assert_ok  "bios->uefi: layout packs"             layout_ok $c
assert_eq  "bios->uefi: numbers kept on gpt (root stays 2)" "/dev/sda2 /dev/sda3" "$(rowf $c /dev/sda2 target) $(rowf $c /dev/sda3 target)"

# --- 5. rocky9-lvm-xfs-uefi -----------------------------------------------------------
c=rocky9-lvm-xfs-uefi; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_has "$c: secureboot WARN shim assumed"     "shimx64.efi on the donor ESP is assumed" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt, no bios_grub, esp 1"         "gpt - 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target esp)"
assert_eq  "$c: no pmbr_boot/grub_from_live on uefi->uefi" "" "$(pget $c target pmbr_boot)$(pget $c target grub_from_live)"
assert_eq  "$c: numbers kept 1 2 3"               "/dev/sda1 /dev/sda2 /dev/sda3" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_has "$c: partition name kept and quoted"   'name="EFI System Partition"' "$(sfd $c /dev/sda1)"
assert_has "$c: label-id is the donor ptuuid"     "label-id: 7e6d5c4b-3a29-4180-9f8e-7d6c5b4a3928" "$(plan_section "$W/$c.out" sfdisk)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: PV elastic last"                  elastic_last $c
assert_eq  "$c: root LV 100%FREE block grow"      "block 1990096584704 100%FREE,grow" "$(rowf $c /dev/rl/root method) $(rowf $c /dev/rl/root tsize) $(rowf $c /dev/rl/root notes)"
assert_eq  "$c: [lvm] root last"                  "lvcreate -y -n root -l 100%FREE rl" "$(plan_section "$W/$c.out" lvm | tail -1)"
assert_eq  "$c: no mkfs for block xfs, vfat + mkswap only" "2" "$(plan_section "$W/$c.out" mkfs | grep -c '^mk')"
assert_eq  "$c: identity keeps /dev/mapper (fstab and BLS)" "keep keep keep keep" "$(ident $c /dev/mapper/rl-root) $(ident $c /dev/mapper/rl-swap) $(ident $c root=/dev/mapper/rl-root) $(ident $c resume=/dev/mapper/rl-swap)"
assert_eq  "$c: identity deduplicated (8 lines)"  8 "$(plan_section "$W/$c.out" identity | wc -l)"
assert_eq  "$c: postfix rocky"                    "rhel x86_64-efi 1 delete keep autorelabel /dev/sda1" "$(pget $c postfix family) $(pget $c postfix grub) $(pget $c postfix bls) $(pget $c postfix lvm_devices_file) $(pget $c postfix lvm_filter) $(pget $c postfix selinux) $(pget $c postfix esp)"
assert_eq  "$c: pins eth0 + eth1x"                "eth0:b4:96:91:00:00:01,eth1x:b4:96:91:00:00:02" "$(pget $c network pins)"
assert_has "$c: guard lists xfs features vs 5.14" "needs=SPARSE_INODES:4.2,REFLINK:4.9,BIGTIME:5.10,INOBTCNT:5.10 ok" "$(grep '^# guard: /dev/rl/root' "$W/$c.out")"
compute $c auto nic=eno1
assert_eq  "$c nic=eno1 lands in [network]"       "eno1 eno1:b4:96:91:00:00:01,eth1x:b4:96:91:00:00:02" "$(pget $c network target) $(pget $c network pins)"

# --- 5a. rocky9-uefi-to-bios: the firmware change on rhel, uefi -> bios (grub2-pc by dnf in postfix) ----
c=rocky9-uefi-to-bios; compute $c
assert_eq  "$c: exit 0 (no refusal on rhel any more)" 0 "$(rc $c)"
diff_case $c
assert_has "$c: WARN names the packages and dnf"  "firmware change uefi -> bios: grub2 for bios (grub2-pc grub2-pc-modules) is installed into the migrated OS by dnf in postfix, from its own repositories: they must be reachable from the recipient (grub_pkgs=)" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt, bios_grub 128, pmbr_boot, donor ESP kept as slot 1" "gpt 128 1 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target pmbr_boot) $(pget $c target esp)"
assert_eq  "$c: grub_from_live is deb-only (absent)" "" "$(pget $c target grub_from_live)"
assert_eq  "$c: [postfix] grub i386-pc + grub_pkgs" "i386-pc grub2-pc,grub2-pc-modules rhel 1" "$(pget $c postfix grub) $(pget $c postfix grub_pkgs) $(pget $c postfix family) $(pget $c postfix bls)"
assert_eq  "$c: bios_grub physically first, ESP second" "/dev/sda128 /dev/sda1" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -2 | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_has "$c: ESP kept WARN"                    "donor ESP /dev/sda1 is kept as a slot on the bios recipient" "$(cat "$W/$c.err")"
assert_eq  "$c: ESP fstab line untouched (keep)"  keep "$(ident $c UUID=1C2D-3E4F)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: PV elastic last"                  elastic_last $c
assert_eq  "$c: the same root LV as uefi->uefi"   "block 1990096584704 100%FREE,grow" "$(rowf $c /dev/rl/root method) $(rowf $c /dev/rl/root tsize) $(rowf $c /dev/rl/root notes)"

# --- 5b. centos7-bios-to-uefi: the firmware change on rhel, bios -> uefi (shim + grub2-efi by yum/dnf) ----
c=centos7-bios-to-uefi; compute $c
assert_eq  "$c: exit 0 (no refusal on rhel any more)" 0 "$(rc $c)"
diff_case $c
assert_has "$c: WARN names the packages and dnf"  "firmware change bios -> uefi: grub2 for uefi (grub2-efi-x64 shim-x64 efibootmgr) is installed into the migrated OS by dnf in postfix" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt, no bios_grub, new ESP = slot 4" "gpt - 4" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target esp)"
assert_eq  "$c: no grub_from_live, no pmbr_boot"  "" "$(pget $c target grub_from_live)$(pget $c target pmbr_boot)"
assert_eq  "$c: [postfix] grub x86_64-efi + grub_pkgs, esp" "x86_64-efi grub2-efi-x64,shim-x64,efibootmgr /dev/sda4 0" "$(pget $c postfix grub) $(pget $c postfix grub_pkgs) $(pget $c postfix esp) $(pget $c postfix bls)"
assert_eq  "$c: esp-new row, physically first"    "esp-new /dev/sda4" "$(rowf $c - notes) $(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -1 | cut -d' ' -f1)"
assert_eq  "$c: the ESP fstab line the rhel way"  "+ /boot/efi vfat umask=0077,shortname=winnt 0 2" "$(ident $c UUID=C5F3-802F)"
assert_eq  "$c: mkfs.vfat with the new volid"     "mkfs.vfat -F32 -i C5F3802F -n EFI /dev/sda4" "$(plan_section "$W/$c.out" mkfs | grep mkfs.vfat)"
assert_eq  "$c: rd.md.uuid removed, rd.lvm.lv kept" "remove keep" "$(ident $c rd.md.uuid=9b8a7c6d:5e4f3a2b:1c0d9e8f:7a6b5c4d) $(ident $c rd.lvm.lv=centos/root)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: PV elastic last"                  elastic_last $c
assert_eq  "$c: the same root LV as bios->bios"   "files 985149734912" "$(rowf $c /dev/centos/root method) $(rowf $c /dev/centos/root tsize)"

# --- 6. mbr-2x1tb-md-to-4tb ------------------------------------------------------------
c=mbr-2x1tb-md-to-4tb; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_has "$c: dos->gpt WARN"                    "partition table dos -> gpt" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt, bios_grub 128, pmbr_boot"    "gpt 128 1" "$(pget $c target label) $(pget $c target bios_grub) $(pget $c target pmbr_boot)"
assert_eq  "$c: bios_grub first, 4 partitions"    "/dev/sda128 4" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -1 | cut -d' ' -f1) $(n_sfdisk $c)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: root elastic last"                elastic_last $c
lid=$(plan_section "$W/$c.out" sfdisk | sed -n 's/^label-id: //p')
assert_fail "$c: new label-id (not the dos one)"  test "$lid" = 0x5c3f1a2b
assert_ok  "$c: label-id is a GUID"               grep -qE '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$' <<< "$lid"
assert_eq  "$c: label-id deterministic from the donor seed" "$(pl_uuid_from 0x5c3f1a2b label)" "$lid"
assert_has "$c: sda1 uuid deterministic"          "uuid=$(pl_uuid_from 0x5c3f1a2b 1)" "$(sfd $c /dev/sda1)"
assert_has "$c: md member -> Linux fs GUID"       "type=0FC63DAF-8483-4772-8E79-3D69D8477DE4" "$(sfd $c /dev/sda3)"
assert_has "$c: swap GUID"                        "type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" "$(sfd $c /dev/sda2)"
assert_eq  "$c: PARTUUID -> UUID in fstab"        "-> UUID=3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02" "$(ident $c PARTUUID=5c3f1a2b-02)"
assert_eq  "$c: resume=PARTUUID -> resume=UUID"   "-> resume=UUID=3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02" "$(ident $c resume=PARTUUID=5c3f1a2b-02)"
assert_eq  "$c: /dev/md0 -> UUID"                 "-> UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50" "$(ident $c /dev/md0)"
assert_eq  "$c: root block grow (3.6 TiB slot)"   "block 3991119331328 elastic,grow" "$(rowf $c /dev/md1 method) $(rowf $c /dev/md1 tsize) $(rowf $c /dev/md1 notes)"
assert_eq  "$c: same donor as case 1 keeps PARTUUID on dos" keep "$(compute debian-md-ext4-bios; plan_compute "$FIX/$c/donor.inv" "$FIX/debian-md-ext4-bios/recipient.inv" auto 2>/dev/null | grep '^PARTUUID=5c3f1a2b-02	' | cut -f2)"

# --- 7. extended-mbr-5-parts -------------------------------------------------------------
c=extended-mbr-5-parts; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_has "$c: WARN more than 4 primaries"       "5 slots need more than 4 primary partitions: gpt" "$(cat "$W/$c.err")"
assert_eq  "$c: gpt with bios_grub"               "gpt 128" "$(pget $c target label) $(pget $c target bios_grub)"
assert_eq  "$c: 6 partitions, none logical"       "6 0" "$(n_sfdisk $c) $(grep -c 'type=5\b\|type=f\b' "$W/$c.out")"
assert_eq  "$c: sequential numbers 128 1 2 3 4 5" "/dev/sda128 /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 /dev/sda5" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: root elastic last"                elastic_last $c
assert_eq  "$c: /var 6->2, swap 7->3, /home 8->4" "/dev/sda2 /dev/sda3 /dev/sda4" "$(rowf $c /dev/sda6 target) $(rowf $c /dev/sda7 target) $(rowf $c /dev/sda8 target)"
assert_eq  "$c: root sda5 block grow"             "/dev/sda5 block 850950881280 elastic,grow" "$(rowf $c /dev/sda5 target) $(rowf $c /dev/sda5 method) $(rowf $c /dev/sda5 tsize) $(rowf $c /dev/sda5 notes)"
assert_eq  "$c: dirty /var noted"                 "renumbered%206->2,dirty" "$(rowf $c /dev/sda6 notes)"
assert_has "$c: dirty WARN (-I, fsck on the copy)" "/dev/sda6 (ext4) is dirty on the donor: block copy with partclone -I" "$(cat "$W/$c.err")"
assert_eq  "$c: resume=/dev/sda7 -> UUID"         "-> resume=UUID=c4d5e6f7-0819-42a3-b4c5-d6e7f8091a2b" "$(ident $c resume=/dev/sda7)"
assert_eq  "$c: mkswap keeps the label"           "mkswap -U c4d5e6f7-0819-42a3-b4c5-d6e7f8091a2b -L swap /dev/sda3" "$(plan_section "$W/$c.out" mkfs | grep mkswap)"
assert_eq  "$c: all UUID specs kept"              5 "$(plan_section "$W/$c.out" identity | grep -c '^UUID=.*	keep$')"
compute $c auto label=dos
assert_eq  "$c label=dos forced: refused"         4 "$(rc $c)"
assert_has "$c label=dos forced: says why"        "do not fit a dos label" "$(tail -1 "$W/$c.out")"

# --- 8. refusals: exit 4, "# ERROR:" last on stdout, reason on stderr ------------------------
refused() {   # CASE DISK NEEDLE
	local c=$1; compute "$c" "$2"
	assert_eq  "$c: exit 4"                       4 "$(rc "$c")"
	diff_case "$c"
	assert_has "$c: last stdout line is # ERROR"  "# ERROR: " "$(tail -1 "$W/$c.out")"
	assert_has "$c: reason"                       "$3" "$(tail -1 "$W/$c.out")"
	assert_has "$c: reason on stderr too"         "$3" "$(grep "^ERROR: " "$W/$c.err")"
	assert_ok  "$c: header printed before the error" grep -q '^# reloca.to plan  donor=' "$W/$c.out"
}
refused_with() {   # CASE DISK NEEDLE [key=value...]: a refusal of a fixture whose expected.plan is a success (no diff)
	local c=$1; compute "$c" "$2" "${@:4}"
	assert_eq  "$c $2 ${*:4}: exit 4"             4 "$(rc "$c")"
	assert_has "$c $2 ${*:4}: reason"             "$3" "$(tail -1 "$W/$c.out")"
	assert_has "$c $2 ${*:4}: reason on stderr too" "$3" "$(grep "^ERROR: " "$W/$c.err")"
}
refused refuse-too-small auto "short by 96823200972 bytes (90.2G)"
assert_has "refuse-too-small: names the requirement" "487156665548 bytes = used x 1.10 + 512 MiB" "$(tail -1 "$W/refuse-too-small.out")"
refused refuse-btrfs auto "/dev/sda2 is btrfs: only ext2/3/4 and xfs"
refused refuse-two-disks-auto auto "2 target disk candidates: -o raid=1 mirrors two of them (md RAID1), -d DISK migrates onto one; nothing is chosen for you: /dev/vda (894.3G - virtio free) /dev/vdb (894.3G - virtio free)"
compute refuse-two-disks-auto /dev/vdb
assert_eq  "refuse-two-disks-auto: explicit /dev/vdb accepted" "0 /dev/vdb" "$(rc refuse-two-disks-auto) $(pget refuse-two-disks-auto target disk)"
refused refuse-fstab-no-target auto "fstab entry /dev/sdc1 /data has no target and no nofail"
sed 's|\tmount=/data\t\(.*\)\tnofail=0$|\tmount=/data\t\1\tnofail=1|' "$FIX/refuse-fstab-no-target/donor.inv" > "$W/nofail.inv"
plan_compute "$W/nofail.inv" "$FIX/refuse-fstab-no-target/recipient.inv" auto > "$W/nofail.out" 2> "$W/nofail.err"; rcn=$?
assert_eq  "fstab no target WITH nofail: accepted" 0 "$rcn"
assert_eq  "fstab no target WITH nofail: removed"  remove "$(plan_section "$W/nofail.out" identity | grep '^/dev/sdc1	' | cut -f2)"
assert_has "fstab no target WITH nofail: WARN"     "/dev/sdc1 /data has no target on the recipient: removed (nofail)" "$(cat "$W/nofail.err")"
# secureboot on a bios donor is refused; a VG on a non-target recipient disk is refused
sed 's/\tsecureboot=0\t/\tsecureboot=1\t/' "$FIX/debian-md-ext4-bios/recipient.inv" > "$W/sb.inv"
plan_compute "$FIX/debian-md-ext4-bios/donor.inv" "$W/sb.inv" auto > "$W/sb.out" 2>/dev/null; rcn=$?
assert_eq  "secureboot=1 with a bios donor: refused" 4 "$rcn"
assert_has "secureboot=1 with a bios donor: says why" "Secure Boot enabled and the donor has no ESP" "$(tail -1 "$W/sb.out")"
# the same rule on rhel: a bios -> uefi change would bring shim by dnf, but the plan does not count on it
sed 's/\tsecureboot=0\t/\tsecureboot=1\t/' "$FIX/centos7-bios-to-uefi/recipient.inv" > "$W/sb-rhel.inv"
plan_compute "$FIX/centos7-bios-to-uefi/donor.inv" "$W/sb-rhel.inv" auto > "$W/sb-rhel.out" 2>/dev/null; rcn=$?
assert_eq  "secureboot=1 with a bios rhel donor: refused too" 4 "$rcn"
assert_has "secureboot=1 with a bios rhel donor: says why" "Secure Boot enabled and the donor has no ESP" "$(tail -1 "$W/sb-rhel.out")"
{ cat "$FIX/centos7-md-lvm-xfs-bios/recipient.inv"; printf 'disk\tdev=/dev/sdb\tsize=999653638144\tlsec=512\tpsec=4096\tmodel=PERC\tserial=x\twwn=-\tbyid=-\ttran=sas\trm=0\tro=0\tpttype=dos\tptuuid=0x1\tdrivers=sd,megaraid_sas\tmodalias=-\tusage=lvm:centos\n'; } > "$W/vg.inv"
plan_compute "$FIX/centos7-md-lvm-xfs-bios/donor.inv" "$W/vg.inv" /dev/sda > "$W/vg.out" 2>/dev/null; rcn=$?
assert_eq  "VG collision on a non-target disk: refused" 4 "$rcn"
assert_has "VG collision: says which disk"         "VG centos already exists on recipient disk /dev/sdb" "$(tail -1 "$W/vg.out")"

# --- 8b. the REAL stand capture: base disk despite mdadm's member order ----------------------
compute stand-debian-md-ext4-bios
diff_case stand-debian-md-ext4-bios
assert_eq  "stand: plan succeeds"                         0 "$(rc stand-debian-md-ext4-bios)"
assert_eq  "stand: base disk is vda (label-id of vda)"    432b9631 "$(plan_section "$W/stand-debian-md-ext4-bios.out" sfdisk | sed -n 's/^label-id: //p')"
assert_eq  "stand: /boot md126 is not from-other-disk"    grow "$(rowf stand-debian-md-ext4-bios /dev/md126 notes)"
assert_eq  "stand: second swap vdb2 is the extra slot"    "from-other-disk,renumbered%202->3" "$(rowf stand-debian-md-ext4-bios /dev/vdb2 notes)"
assert_eq  "stand: root elastic on vda4"                  /dev/vda4 "$(rowf stand-debian-md-ext4-bios /dev/md127 target)"
assert_has "stand: mkswap keeps the fixture swap UUID"    "mkswap -U 231753ee-4ef0-48a7-9f6d-19a3e1b26951 -L swap0 /dev/vda2" "$(plan_section "$W/stand-debian-md-ext4-bios.out" mkfs)"

# --- 8c. the REAL uefi/gpt/lvm/xfs capture: LV names, the ESP volume id, 100%FREE root ----------
# (tools/fixtures/debian-gpt-lvm-xfs-uefi.sh captured by the stand; the recipient is the
# stand's own 20 GiB virtio VM under OVMF; expected.plan reviewed by hand, see its README)
c=stand-debian-gpt-lvm-xfs-uefi; compute $c
assert_eq  "$c: exit 0"                            0 "$(rc $c)"
diff_case $c
assert_eq  "$c: gpt kept, uefi, esp=1, no bios_grub" "gpt uefi - 1" "$(pget $c target label) $(pget $c target firmware) $(pget $c target bios_grub) $(pget $c target esp)"
assert_eq  "$c: 5 volumes, PV first, root last"    "/dev/vda3 /dev/vg0/root" "$(plan_section "$W/$c.out" volumes | sed -n '1p;$p' | sed 's/^src=\([^	]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//')"
assert_eq  "$c: fs/swap of the LVs are named by lv_path (not /dev/mapper)" "mkswap block" "$(rowf $c /dev/vg0/swap method) $(rowf $c /dev/vg0/root method)"
assert_eq  "$c: ESP by the esp method, volid without the dash" "esp /dev/vda1 /boot/efi|mkfs.vfat -F32 -i C0DE0E5F -n EFI /dev/vda1" "$(rowf $c /dev/vda1 method) $(rowf $c /dev/vda1 target) $(rowf $c /dev/vda1 mount)|$(plan_section "$W/$c.out" mkfs | grep vfat)"
assert_eq  "$c: PV elastic, root LV 100%FREE block grow" "elastic block 18782093312 100%FREE,grow" "$(rowf $c /dev/vda3 notes) $(rowf $c /dev/vg0/root method) $(rowf $c /dev/vg0/root tsize) $(rowf $c /dev/vg0/root notes)"
assert_eq  "$c: /boot ext4 block, same size, no grow" "block 1073741824 -" "$(rowf $c /dev/vda2 method) $(rowf $c /dev/vda2 tsize) $(rowf $c /dev/vda2 notes)"
assert_eq  "$c: [lvm] lines"                       "pvcreate -ff -y --uuid fxPV00-uefi-Lvm2-Xfs0-Gpt0-Esp0-000001 --norestorefile /dev/vda3|vgcreate vg0 /dev/vda3|lvcreate -y -n swap -L 1073741824b vg0|lvcreate -y -n root -l 100%FREE vg0" "$(plan_section "$W/$c.out" lvm | tr '\n' '|' | sed 's/|$//')"
assert_eq  "$c: mkswap with the LV's uuid and label" "mkswap -U 5a5a0000-0eaf-4a1c-8000-000000000004 -L swap /dev/vg0/swap" "$(plan_section "$W/$c.out" mkfs | grep '^mkswap')"
assert_eq  "$c: no mkfs for the block volumes (vfat + mkswap only)" 2 "$(plan_section "$W/$c.out" mkfs | grep -c '^mk')"
assert_has "$c: label-id and partition GUIDs are the donor's (lowercase, as lsblk prints them)" "label-id: 7a1e2d3c-4b5a-4968-8776-655443322110" "$(plan_section "$W/$c.out" sfdisk)"
assert_has "$c: ESP line keeps its type, uuid and name" 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=7a1e2d3c-0001-4000-8000-000000000001, name="EFI System Partition"' "$(sfd $c /dev/vda1)"
assert_ok  "$c: layout packs the whole disk"       layout_ok $c
assert_ok  "$c: PV elastic last"                   elastic_last $c
assert_eq  "$c: identity keeps /dev/mapper and UUID specs" "keep keep keep keep" "$(ident $c /dev/mapper/vg0-root) $(ident $c /dev/mapper/vg0-swap) $(ident $c UUID=b0070000-e4f4-4b00-8000-000000000002) $(ident $c UUID=C0DE-0E5F)"
assert_eq  "$c: postfix deb/initramfs-tools/x86_64-efi, esp, boot, root" "deb initramfs-tools x86_64-efi /dev/vda1 /dev/vda2 /dev/vg0/root" "$(pget $c postfix family) $(pget $c postfix initramfs) $(pget $c postfix grub) $(pget $c postfix esp) $(pget $c postfix boot) $(pget $c postfix os_root)"
assert_eq  "$c: network donor ens3/-/networkd"     "ens3/-/networkd" "$(pget $c network donor)"
assert_has "$c: guard lists the xfs features vs 6.1" "needs=SPARSE_INODES:4.2,REFLINK:4.9,INOBTCNT:5.10,BIGTIME:5.10 ok" "$(grep '^# guard: /dev/vg0/root' "$W/$c.out")"
assert_eq  "$c: verify esp and swap"               "/dev/vda1 5a5a0000-0eaf-4a1c-8000-000000000004" "$(pget $c verify esp) $(pget $c verify swap)"
# on the fly: the same donor onto a SeaBIOS recipient (the stand's -r bios): gpt kept,
# bios_grub 128 first, pmbr_boot, grub from the Live, the ESP kept as a slot, a WARN
mkdir -p "$W/ubios"; cp "$FIX/$c/donor.inv" "$W/ubios/"; sed 's/\tfw=uefi\t/\tfw=bios\t/' "$FIX/$c/recipient.inv" > "$W/ubios/recipient.inv"
plan_compute "$W/ubios/donor.inv" "$W/ubios/recipient.inv" auto > "$W/ubios.out" 2> "$W/ubios.err"; echo $? > "$W/ubios.rc"; c=ubios
assert_eq  "uefi->bios: exit 0"                    0 "$(rc $c)"
assert_eq  "uefi->bios: gpt, bios_grub 128, esp 1, pmbr_boot, grub_from_live" "gpt bios 128 1 1 1" "$(pget $c target label) $(pget $c target firmware) $(pget $c target bios_grub) $(pget $c target esp) $(pget $c target pmbr_boot) $(pget $c target grub_from_live)"
assert_has "uefi->bios: firmware change WARN (deb)" "firmware change uefi -> bios" "$(cat "$W/$c.err")"
assert_has "uefi->bios: ESP kept WARN"             "kept as a slot on the bios recipient" "$(cat "$W/$c.err")"
assert_eq  "uefi->bios: bios_grub is physically first" "/dev/vda128" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | head -1 | cut -d' ' -f1)"
assert_eq  "uefi->bios: 4 partitions, numbers kept" "/dev/vda128 /dev/vda1 /dev/vda2 /dev/vda3" "$(plan_sfdisk "$W/$c.out" | sort -k2,2n | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_ok  "uefi->bios: layout packs"              layout_ok $c
assert_eq  "uefi->bios: postfix grub i386-pc, esp kept" "i386-pc /dev/vda1" "$(pget $c postfix grub) $(pget $c postfix esp)"
assert_eq  "uefi->bios: PV slot one MiB smaller (bios_grub), root LV the same after PE rounding" "19861078016 18782093312" "$(rowf $c /dev/vda3 tsize) $(rowf $c /dev/vg0/root tsize)"

# --- 8a. stand-rocky9-lvm-xfs-uefi: the captured Rocky 9 (anaconda) donor on the stand's uefi VM ----
c=stand-rocky9-lvm-xfs-uefi; compute $c
assert_eq  "$c: exit 0"                               0 "$(rc $c)"
diff_case $c
assert_eq  "$c: rhel, dracut, x86_64-efi, bls, devices file deleted, autorelabel" "rhel dracut x86_64-efi 1 delete keep autorelabel" "$(pget $c postfix family) $(pget $c postfix initramfs) $(pget $c postfix grub) $(pget $c postfix bls) $(pget $c postfix lvm_devices_file) $(pget $c postfix lvm_filter) $(pget $c postfix selinux)"
assert_eq  "$c: os_root/boot/esp"                     "/dev/rl/root /dev/vda2 /dev/vda1" "$(pget $c postfix os_root) $(pget $c postfix boot) $(pget $c postfix esp)"
assert_eq  "$c: every fstab spec and BLS token kept"  8 "$(plan_section "$W/$c.out" identity | grep -c '	keep$')"
assert_eq  "$c: root=/resume=/rd.lvm.lv kept"         "keep keep keep keep" "$(ident $c root=/dev/mapper/rl-root) $(ident $c resume=/dev/mapper/rl-swap) $(ident $c rd.lvm.lv=rl/root) $(ident $c rd.lvm.lv=rl/swap)"
assert_eq  "$c: root LV by block with grow, /boot xfs block" "block 100%FREE,grow block" "$(rowf $c /dev/rl/root method) $(rowf $c /dev/rl/root notes) $(rowf $c /dev/vda2 method)"
assert_eq  "$c: ESP with the fixture's volume id"     "mkfs.vfat -F32 -i C0DE0E5E /dev/vda1" "$(plan_section "$W/$c.out" mkfs | grep mkfs.vfat)"
assert_eq  "$c: keyfile on ens3 without a MAC"        "ens3/-/nm-keyfile" "$(pget $c network donor)"
assert_has "$c: xfs masks of a 5.14 kernel"           "/dev/rl/root:xfs:versionnum=0xb4b5" "$(pget $c verify features)"
assert_ok  "$c: layout packs the whole disk"          layout_ok $c
assert_ok  "$c: elastic slot is physically last"      elastic_last $c


# --- 8b. stand-rocky9-lvm-xfs-bios: the captured BIOS/MBR twin on the stand's bios VM, and on its uefi VM (firmware change) ----
c=stand-rocky9-lvm-xfs-bios; compute $c
assert_eq  "$c: exit 0"                           0 "$(rc $c)"
diff_case $c
assert_eq  "$c: rhel, dracut, i386-pc, bls, devices file deleted, autorelabel, no grub_pkgs" "rhel dracut i386-pc 1 delete keep autorelabel" "$(pget $c postfix family) $(pget $c postfix initramfs) $(pget $c postfix grub) $(pget $c postfix bls) $(pget $c postfix lvm_devices_file) $(pget $c postfix lvm_filter) $(pget $c postfix selinux)$(pget $c postfix grub_pkgs)"
assert_eq  "$c: dos kept, the donor's label-id, 2 partitions, vda1 bootable" "dos 7088cb2f 2 bootable" "$(pget $c target label) $(plan_section "$W/$c.out" sfdisk | sed -n 's/^label-id: //p') $(plan_sfdisk "$W/$c.out" | wc -l) $(sfd $c /dev/vda1 | grep -o bootable)"
assert_eq  "$c: no ESP, no bios_grub"             "- -" "$(pget $c target esp) $(pget $c target bios_grub)"
assert_eq  "$c: root LV block grow 100%FREE, /boot block on vda1" "block 100%FREE,grow block /dev/vda1" "$(rowf $c /dev/rl/root method) $(rowf $c /dev/rl/root notes) $(rowf $c /dev/vda1 method) $(rowf $c /dev/vda1 target)"
assert_ok  "$c: layout packs the whole disk"      layout_ok $c
assert_ok  "$c: PV elastic last"                  elastic_last $c
# the same donor onto the stand's uefi VM: the bios -> uefi change on rhel, as the stand runs it (-r uefi)
plan_compute "$FIX/$c/donor.inv" "$FIX/stand-debian-gpt-lvm-xfs-uefi/recipient.inv" auto > "$W/$c-uefi.out" 2> "$W/$c-uefi.err"; rcn=$?
assert_eq  "$c -> uefi: exit 0"                   0 "$rcn"
assert_has "$c -> uefi: WARN dnf"                 "firmware change bios -> uefi: grub2 for uefi (grub2-efi-x64 shim-x64 efibootmgr) is installed into the migrated OS by dnf in postfix" "$(cat "$W/$c-uefi.err")"
assert_eq  "$c -> uefi: gpt, esp-new vda3 first, no bios_grub" "gpt 3 - /dev/vda3" "$(plan_get "$W/$c-uefi.out" target label) $(plan_get "$W/$c-uefi.out" target esp) $(plan_get "$W/$c-uefi.out" target bios_grub) $(plan_sfdisk "$W/$c-uefi.out" | sort -k2,2n | head -1 | cut -d' ' -f1)"
assert_eq  "$c -> uefi: grub x86_64-efi, grub_pkgs, esp"  "x86_64-efi grub2-efi-x64,shim-x64,efibootmgr /dev/vda3" "$(plan_get "$W/$c-uefi.out" postfix grub) $(plan_get "$W/$c-uefi.out" postfix grub_pkgs) $(plan_get "$W/$c-uefi.out" postfix esp)"
assert_has "$c -> uefi: the rhel fstab line for the new ESP" "	+ /boot/efi vfat umask=0077,shortname=winnt 0 2" "$(plan_section "$W/$c-uefi.out" identity | grep '^UUID=[0-9A-F]\{4\}-[0-9A-F]\{4\}	')"
assert_eq  "$c -> uefi: no grub_from_live"        "" "$(plan_get "$W/$c-uefi.out" target grub_from_live)"
# --- 8b. raid=1 (R16): two disks as md RAID1 pairs -----------------------------------------------
c=raid1-md-bios; compute $c auto raid=1
assert_eq  "$c: exit 0"                               0 "$(rc $c)"
diff_case $c
assert_eq  "$c: two WARNs (raid, PARTUUID->UUID)"     2 "$(warns $c)"
assert_has "$c: WARN names both disks"                "raid=1: /dev/vda + /dev/vdb become md RAID1 pairs" "$(cat "$W/$c.err")"
assert_eq  "$c: [target] raid=1, disk2, md list"      "1 /dev/vdb /dev/md1,/dev/md2,/dev/md3 -" "$(pget $c target raid) $(pget $c target disk2) $(pget $c target md) $(pget $c target esp2)"
assert_eq  "$c: geometry = the (equal) disk size"     960197124096 "$(pget $c target geometry)"
assert_eq  "$c: 3 partitions on each disk"            "3 3" "$(n_sfdisk $c) $(plan_sfdisk "$W/$c.out" sfdisk2 | wc -l)"
assert_eq  "$c: [sfdisk2] geometry equals [sfdisk]"   "$(plan_sfdisk "$W/$c.out" | sed 's|/dev/vda||')" "$(plan_sfdisk "$W/$c.out" sfdisk2 | sed 's|/dev/vdb||')"
assert_eq  "$c: [sfdisk2] has its own label-id"       "0x5c3f1a2b 0x170b5b47" "$(plan_section "$W/$c.out" sfdisk | sed -n 's/^label-id: //p') $(plan_section "$W/$c.out" sfdisk2 | sed -n 's/^label-id: //p')"
assert_has "$c: bootable flag on both first partitions" "type=83, bootable" "$(plan_section "$W/$c.out" sfdisk2 | grep '^/dev/vdb1 :')"
assert_eq  "$c: 3 [md] lines, md after the partition number" "/dev/md1 /dev/vda1 /dev/vdb1|/dev/md2 /dev/vda2 /dev/vdb2|/dev/md3 /dev/vda3 /dev/vdb3" "$(plan_md "$W/$c.out" | tr '\n' '|' | sed 's/|$//')"
assert_eq  "$c: the donor's md UUIDs are kept (boot, root), the swap gets a derived one" "1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b 8cdd67b2:a490888e:139944df:c3e3bdd9 7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e" "$(plan_section "$W/$c.out" md | sed -n 's/.*--uuid=\([^ ]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
assert_has "$c: mdadm line as apply runs it"          "mdadm --create /dev/md1 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=web1 --name=1 --uuid=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b /dev/vda1 /dev/vdb1" "$(plan_section "$W/$c.out" md)"
assert_eq  "$c: /boot slot = md 1 GiB + 8 MiB"        "2113536 1073741824" "$(plan_sfdisk "$W/$c.out" | awk '$1 == "/dev/vda1" { print $3 }') $(rowf $c /dev/md0 tsize)"
assert_eq  "$c: /boot block + grow onto /dev/md1"     "block /dev/md1 raid1,grow" "$(rowf $c /dev/md0 method) $(rowf $c /dev/md0 target) $(rowf $c /dev/md0 notes)"
assert_eq  "$c: root files onto /dev/md3, elastic"    "files /dev/md3 elastic,raid1" "$(rowf $c /dev/md1 method) $(rowf $c /dev/md1 target) $(rowf $c /dev/md1 notes)"
assert_eq  "$c: root tsize = elastic slot - 8 MiB"    "$(( $(plan_sfdisk "$W/$c.out" | awk '$1 == "/dev/vda3" { print $3 }') * 512 - 8388608 ))" "$(rowf $c /dev/md1 tsize)"
assert_eq  "$c: swap on /dev/md2 with the donor uuid" "mkswap -U 3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02 /dev/md2" "$(plan_section "$W/$c.out" mkfs | grep mkswap)"
assert_ok  "$c: layout packs the whole disk"          layout_ok $c
assert_ok  "$c: elastic slot is physically last"      elastic_last $c
assert_eq  "$c: /dev/md0 -> UUID (not a partition any more)" "-> UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50" "$(ident $c /dev/md0)"
assert_eq  "$c: [postfix] raid=1 disk2 esp2 mdadm"    "1 /dev/vdb - -" "$(pget $c postfix raid) $(pget $c postfix disk2) $(pget $c postfix esp2) $(pget $c postfix mdadm)"
assert_eq  "$c: [verify] md list"                     "/dev/md1,/dev/md2,/dev/md3" "$(pget $c verify md)"
assert_eq  "$c: mkfs targets are the arrays"          "/dev/md2 /dev/md3" "$(plan_section "$W/$c.out" mkfs | grep -v '^#' | awk '{ print $NF }' | tr '\n' ' ' | sed 's/ $//')"
compute $c /dev/vda,/dev/vdb raid=1
assert_eq  "$c: -d A,B with raid=1 accepted"          "0 /dev/vda /dev/vdb" "$(rc $c) $(pget $c target disk) $(pget $c target disk2)"
compute $c /dev/vdb,/dev/vda raid=1
assert_eq  "$c: -d B,A: the first named is 'disk'"    "0 /dev/vdb /dev/vda" "$(rc $c) $(pget $c target disk) $(pget $c target disk2)"
assert_has "$c: -d B,A: md members in that order"     "/dev/vdb1 /dev/vda1" "$(plan_section "$W/$c.out" md | head -1)"
refused_with $c /dev/vda,/dev/vdb "-d /dev/vda,/dev/vdb names two disks: that is a mirror, add -o raid=1 (or name one disk)"
refused_with $c /dev/vda "raid=1 needs two disks: -d DISK,DISK2 (or no -d when the recipient has exactly two candidates)" raid=1
refused_with $c /dev/vda,/dev/vda "-d /dev/vda,/dev/vda names the same disk twice" raid=1
refused_with $c /dev/vda,/dev/sdz "target disk /dev/sdz is not in the recipient inventory" raid=1
compute $c auto raid=2
assert_eq  "$c: raid=2 is refused"                    4 "$(rc $c)"
# a single-disk recipient with raid=1
compute debian-md-ext4-bios auto raid=1
assert_eq  "one disk + raid=1: exit 4"                4 "$(rc debian-md-ext4-bios)"
assert_has "one disk + raid=1: says so"               "raid=1 mirrors two disks but the recipient has 1 candidate(s)" "$(tail -1 "$W/debian-md-ext4-bios.out")"
# rhel donor + raid=1
compute centos7-md-lvm-xfs-bios auto raid=1
assert_eq  "rhel + raid=1: exit 4"                    4 "$(rc centos7-md-lvm-xfs-bios)"
assert_has "rhel + raid=1: deb only until M4"         "raid=1 is implemented for the deb family only" "$(tail -1 "$W/centos7-md-lvm-xfs-bios.out")"
c=raid1-lvm-uefi; compute $c auto raid=1
assert_eq  "$c: exit 0"                               0 "$(rc $c)"
diff_case $c
assert_eq  "$c: gpt on both, own label-id on disk2"   "7a1e2d3c-4b5a-4968-8776-655443322110 BC0506F8-9A72-E9F2-9124-BAA8568CEFBA" "$(plan_section "$W/$c.out" sfdisk | sed -n 's/^label-id: //p') $(plan_section "$W/$c.out" sfdisk2 | sed -n 's/^label-id: //p')"
assert_eq  "$c: partition GUIDs differ between the disks" 0 "$(comm -12 <(plan_section "$W/$c.out" sfdisk | sed -n 's/.*uuid=\([^,]*\).*/\1/p' | sort) <(plan_section "$W/$c.out" sfdisk2 | sed -n 's/.*uuid=\([^,]*\).*/\1/p' | sort) | wc -l)"
assert_eq  "$c: ESP stays plain on both disks"        "/dev/vda1 /dev/vdb1" "$(pget $c target esp2 | sed 's|^|/dev/vda1 |')"
assert_eq  "$c: esp-mirror row: no source, not mounted" "src=-	kind=esp	fs=vfat	size=536870912	used=-	method=esp	target=/dev/vdb1	tsize=536870912	mount=-	num=1	notes=esp-mirror" "$(plan_section "$W/$c.out" volumes | grep esp-mirror)"
assert_eq  "$c: two mkfs.vfat with the same volume id" 2 "$(plan_section "$W/$c.out" mkfs | grep -c '^mkfs.vfat -F32 -i C0DE0E5F -n EFI /dev/vd[ab]1$')"
assert_eq  "$c: /boot on /dev/md2, PV on /dev/md3"     "/dev/md2 /dev/md3" "$(rowf $c /dev/vda2 target) $(rowf $c /dev/vda3 target)"
assert_eq  "$c: [lvm] on the array"                   "pvcreate -ff -y --uuid fxPV00-uefi-Lvm2-Xfs0-Gpt0-Esp0-000001 --norestorefile /dev/md3|vgcreate vg0 /dev/md3" "$(plan_section "$W/$c.out" lvm | head -2 | tr '\n' '|' | sed 's/|$//')"
assert_eq  "$c: PV tsize = slot - 8 MiB"              "$(( $(plan_sfdisk "$W/$c.out" | awk '$1 == "/dev/vda3" { print $3 }') * 512 - 8388608 ))" "$(rowf $c /dev/vda3 tsize)"
assert_eq  "$c: root LV = PV - swap - 4 MiB"          "$(( ($(rowf $c /dev/vda3 tsize) - 1073741824 - 4194304) / 4194304 * 4194304 ))" "$(rowf $c /dev/vg0/root tsize)"
assert_eq  "$c: [postfix] esp2 and the donor's mdadm" "/dev/vdb1 -" "$(pget $c postfix esp2) $(pget $c postfix mdadm)"
assert_eq  "$c: [verify] md and esp2"                 "/dev/md2,/dev/md3 /dev/vdb1" "$(pget $c verify md) $(pget $c verify esp2)"
assert_ok  "$c: layout packs the whole disk"          layout_ok $c
assert_ok  "$c: elastic slot is physically last"      elastic_last $c

# --- 9. plan_check: green on every expected.plan, red after corruption ------------------------
check_in() {   # DIR [FORCE] -> runs plan_check in a subshell with RUN=DIR; output in DIR/check.out, status echoed
	( RUN=$1; OPT[force]=${2:-0}; plan_check "$1/plan" ) > "$1/check.out" 2>&1; echo $?
}
for c in debian-md-ext4-bios centos7-md-lvm-xfs-bios ubuntu-nvme-uefi-to-bios-vm debian-boot-root-swap-bios rocky9-lvm-xfs-uefi rocky9-uefi-to-bios centos7-bios-to-uefi mbr-2x1tb-md-to-4tb extended-mbr-5-parts stand-debian-md-ext4-bios stand-debian-gpt-lvm-xfs-uefi stand-rocky9-lvm-xfs-uefi stand-rocky9-lvm-xfs-bios raid1-md-bios raid1-lvm-uefi; do
	d=$W/check-$c; mkdir -p "$d"; cp "$FIX/$c/donor.inv" "$FIX/$c/recipient.inv" "$d/"; cp "$FIX/$c/expected.plan" "$d/plan"
	assert_eq  "check $c: green (hash matches, no force)" 0 "$(check_in "$d")"
	assert_has "check $c: says passed"                "plan check passed" "$(cat "$d/check.out")"
	assert_ok  "check $c: prints the sizes table"     grep -qE '^  src +method +target +tsize +size +used +mount +notes$' "$d/check.out"
	assert_eq  "check $c: green with force=1 too"     0 "$(check_in "$d" 1)"
done
d=$W/check-debian-md-ext4-bios
echo "# touched" >> "$d/donor.inv"
assert_eq  "check: changed inventory is refused"       4 "$(check_in "$d")"
assert_has "check: changed inventory says so"          "inv_sha256 differs" "$(cat "$d/check.out")"
assert_eq  "check: force=1 overrides the hash"         0 "$(check_in "$d" 1)"
assert_has "check: force=1 warns"                      "WARN: inventories changed" "$(cat "$d/check.out")"
cp "$FIX/debian-md-ext4-bios/donor.inv" "$d/"
cp "$d/plan" "$d/plan.good"
sed 's|^/dev/vda2 : start=2099200,|/dev/vda2 : start=2048,|' "$d/plan.good" > "$d/plan"
assert_eq  "check: overlap is red"                     4 "$(check_in "$d")"
assert_has "check: overlap named"                      "overlaps /dev/vda1" "$(cat "$d/check.out")"
sed 's|^/dev/vda2 : start=2099200,|/dev/vda2 : start=2099201,|' "$d/plan.good" > "$d/plan"
assert_has "check: misaligned start named"             "start 2099201 is not MiB-aligned" "$(cat "$d/check.out" 2>/dev/null; check_in "$d" >/dev/null; cat "$d/check.out")"
sed 's|\ttsize=950530998272\t|\ttsize=950530998273\t|' "$d/plan.good" > "$d/plan"
assert_eq  "check: tsize mismatch is red"              4 "$(check_in "$d")"
assert_has "check: tsize mismatch named"               "tsize=950530998273 but [sfdisk] makes it 950530998272" "$(cat "$d/check.out")"
sed 's|\tsize=1856505856, type=83|\tsize=1856505857, type=83|; s|^/dev/vda3 : start=18876416, size=1856505856,|/dev/vda3 : start=18876416, size=1856505857,|' "$d/plan.good" > "$d/plan"
assert_eq  "check: partition past the last MiB is red"  4 "$(check_in "$d")"
grep -v '^mkswap' "$d/plan.good" > "$d/plan"
assert_eq  "check: missing mkswap is red"              4 "$(check_in "$d")"
assert_has "check: missing mkswap named"               "no mkfs/mkswap line for /dev/vda2" "$(cat "$d/check.out")"
{ cat "$d/plan.good"; } | sed '/^\[mkfs\]/a mkfs.ext4 -F /dev/vda1' > "$d/plan"
assert_eq  "check: mkfs on a block volume is red"      4 "$(check_in "$d")"
grep -v '^/dev/md0	' "$d/plan.good" > "$d/plan"
assert_eq  "check: identity gap is red"                4 "$(check_in "$d")"
assert_has "check: identity gap named"                 "no line for fstab spec /dev/md0" "$(cat "$d/check.out")"
sed 's|\tmethod=files\t|\tmethod=block\t|' "$d/plan.good" > "$d/plan"
assert_eq  "check: block that does not fit is red"     4 "$(check_in "$d")"
assert_has "check: block fit named"                    "(block) 990404673536 bytes does not fit /dev/vda3" "$(cat "$d/check.out")"
d=$W/check-centos7-md-lvm-xfs-bios; cp "$d/plan" "$d/plan.good"
sed 's|^lvcreate -y -n swap -L 4294967296b centos|lvcreate -y -n swap -L 8589934592b centos|' "$d/plan.good" > "$d/plan"
assert_eq  "check: LV size vs [lvm] is red"            4 "$(check_in "$d")"
assert_has "check: LV size mismatch named"             "/dev/centos/root tsize=985686605824 but [lvm] makes it 981391638528" "$(cat "$d/check.out")"
# raid=1 plans: the mirror's table and the arrays are checked too
d=$W/check-raid1-md-bios; cp "$d/plan" "$d/plan.good"
assert_has "check raid: names both disks and the arrays"  "target /dev/vda (894.3G, label dos) + /dev/vdb (894.3G) as md RAID1, 3 arrays" "$(cat "$d/check.out")"
sed 's|^/dev/vdb2 : start=2115584,|/dev/vdb2 : start=2117632,|' "$d/plan.good" > "$d/plan"
assert_eq  "check raid: [sfdisk2] drifting from [sfdisk] is red" 4 "$(check_in "$d")"
assert_has "check raid: drift named"                   "[sfdisk2] /dev/vdb2 (start 2117632, size 16793600) differs from partition 2 of [sfdisk]" "$(cat "$d/check.out")"
grep -v '^/dev/vdb3 :' "$d/plan.good" > "$d/plan"
assert_eq  "check raid: a missing mirror partition is red" 4 "$(check_in "$d")"
assert_has "check raid: md member missing named"       "[md] /dev/md3: member /dev/vdb3 is not in [sfdisk2]" "$(cat "$d/check.out")"
sed 's|^mdadm --create /dev/md3 .*|mdadm --create /dev/md3 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=web1 --name=3 --uuid=7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e /dev/vda3 /dev/vdb2|' "$d/plan.good" > "$d/plan"
assert_eq  "check raid: members of different size are red" 4 "$(check_in "$d")"
assert_has "check raid: size mismatch named"           "[md] /dev/md3: members /dev/vda3 and /dev/vdb2 differ in size" "$(cat "$d/check.out")"
grep -v '^mdadm --create /dev/md2 ' "$d/plan.good" > "$d/plan"
assert_eq  "check raid: a volume without its array is red" 4 "$(check_in "$d")"
assert_has "check raid: missing array named"           "[volumes] /dev/sda2 -> /dev/md2: not in [sfdisk], [sfdisk2] or [md]" "$(cat "$d/check.out")"
sed 's|^label=dos firmware=bios \(.*\) raid=1$|label=dos firmware=bios \1|' "$d/plan.good" > "$d/plan"
assert_eq  "check raid: [md] lines without raid=1 are red" 4 "$(check_in "$d")"
cp "$d/plan.good" "$d/plan"
( RUN=$W/nowhere; plan_check "$W/nowhere/plan" ) >/dev/null 2>&1; rcn=$?
assert_eq  "check: no plan file exits 4"               4 "$rcn"
# plan_section / plan_get
assert_eq  "plan_get target disk"                      /dev/vda "$(plan_get "$FIX/debian-md-ext4-bios/expected.plan" target disk)"
assert_eq  "plan_get finds keys on later lines"        dos "$(plan_get "$FIX/debian-md-ext4-bios/expected.plan" target label)"
assert_eq  "plan_section strips comments and blanks"   "7 0" "$(plan_section "$FIX/debian-md-ext4-bios/expected.plan" sfdisk | wc -l) $(plan_section "$FIX/debian-md-ext4-bios/expected.plan" volumes | grep -c '^#')"
assert_eq  "plan_section of a missing section is empty" "" "$(plan_section "$FIX/debian-md-ext4-bios/expected.plan" nosuch)"

# --- 9b. on-line relocation: the inventory of a RUNNING donor (host online=1) ------------------
compute online-debian-md-ext4-bios
assert_eq  "online: exit 0"                            0 "$(rc online-debian-md-ext4-bios)"
diff_case  online-debian-md-ext4-bios
assert_eq  "online: [target] mode=online"              online "$(pget online-debian-md-ext4-bios target mode)"
assert_eq  "online: the mounted root gets no dirty note" "" "$(rowf online-debian-md-ext4-bios /dev/md127 notes | grep -o dirty)"
assert_has "online: the on-line WARN"                  "on-line relocation: the donor keeps running" "$(cat "$W/online-debian-md-ext4-bios.err")"
assert_eq  "online: / stays a block volume"            block "$(rowf online-debian-md-ext4-bios /dev/md127 method)"
assert_eq  "off-line plan has no mode="                "" "$(pget stand-debian-md-ext4-bios target mode)"
compute online-debian-md-ext4-bios auto root=files
assert_eq  "online root=files: accepted (exit 0)"       0 "$(rc online-debian-md-ext4-bios)"
assert_eq  "online root=files: / by files"             files "$(rowf online-debian-md-ext4-bios /dev/md127 method)"
assert_has "online root=files: the tar-passes WARN"    "by files: tar incremental passes" "$(cat "$W/online-debian-md-ext4-bios.err")"
assert_eq  "online root=files: still mode=online"      online "$(pget online-debian-md-ext4-bios target mode)"
compute stand-debian-md-ext4-bios

# --- 10. plan_build: inventories in $RUN + OPT -> $RUN/plan + summary ------------------------
b=$W/build; mkdir -p "$b"; cp "$FIX/debian-md-ext4-bios/donor.inv" "$FIX/debian-md-ext4-bios/recipient.inv" "$b/"
( RUN=$b; DRY=y; OPT[compress]=zstd; plan_build auto ) > "$b/build.out" 2> "$b/build.err"; rcn=$?
assert_eq  "plan_build: exit 0"                        0 "$rcn"
assert_ok  "plan_build: wrote \$RUN/plan under -n"     test -s "$b/plan"
assert_eq  "plan_build: plan == core output (with the option)" "" "$(diff <(norm "$b/plan") <(plan_compute "$b/donor.inv" "$b/recipient.inv" auto compress=zstd 2>/dev/null | norm /dev/stdin))"
assert_eq  "plan_build: header carries reloca.to/live/date" 1 "$(grep -c '^# inv_sha256=[0-9a-f]*:[0-9a-f]*  reloca=dev  live=[^ ]*  date=20' "$b/plan")"
assert_has "plan_build: summary title"                 "план записан: $b/plan (dry)" "$(cat "$b/build.out")"
assert_has "plan_build: summary lists volumes"         "/dev/md1" "$(cat "$b/build.out")"
assert_has "plan_build: summary shows the disk"        "disk=/dev/vda" "$(cat "$b/build.out")"
assert_has "plan_build: summary next steps"            "reloca.to -s check" "$(cat "$b/build.out")"
assert_eq  "plan_build: check accepts its own plan"    0 "$(check_in "$b")"
cp "$FIX/refuse-btrfs/donor.inv" "$FIX/refuse-btrfs/recipient.inv" "$b/"; rm -f "$b/plan" "$b/failure"
( RUN=$b; plan_build auto ) > "$b/build.out" 2> "$b/build.err"; rcn=$?
assert_eq  "plan_build refusal: exit 4"                4 "$rcn"
assert_has "plan_build refusal: last line is the reason" "ERROR: /dev/sda2 is btrfs" "$(tail -1 "$b/build.out")"
assert_fail "plan_build refusal: no \$RUN/plan"        test -e "$b/plan"
assert_has "plan_build refusal: failure record"        "exit=4 " "$(cat "$b/failure")"
( RUN=$W/empty; plan_build auto ) >/dev/null 2>&1; rcn=$?
assert_eq  "plan_build without inventories exits 2"    2 "$rcn"
# warnings of the core come out through warn() in plan_build
cp "$FIX/centos7-md-lvm-xfs-bios/donor.inv" "$FIX/centos7-md-lvm-xfs-bios/recipient.inv" "$b/"
( RUN=$b; plan_build auto ) > "$b/build.out" 2> "$b/build.err"; rcn=$?
assert_eq  "plan_build with warnings: exit 0"          0 "$rcn"
assert_has "plan_build: WARN relayed via warn()"       "WARN: recipient has 4 NICs" "$(cat "$b/build.out")"

# --- 11. the driver's check wiring (no Live needed: check only needs set_roles) ---------------
M=$REPO/bin/reloca.to; dd=$W/driver; mkdir -p "$dd"
out=$(RUN=$dd bash "$M" -n -o force=1 -s check "$FIX/rocky9-lvm-xfs-uefi/expected.plan" 2>&1); rcn=$?
assert_eq  "driver check -o force=1: exit 0"           0 "$rcn"
assert_has "driver check: passed"                      "plan check passed" "$out"
out=$(RUN=$dd bash "$M" -n -s check "$FIX/rocky9-lvm-xfs-uefi/expected.plan" 2>&1); rcn=$?
assert_eq  "driver check without inventories: exit 4"  4 "$rcn"
assert_has "driver check without inventories: says so" "no $dd/{donor,recipient}.inv" "$out"

t_end
