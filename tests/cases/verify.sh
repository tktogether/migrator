#!/bin/bash
# tests/cases/verify.sh — lib/verify.sh without a disk, a mount or a reboot.
# The tree is the REAL Debian 11 capture (fixtures/stand-debian-md-ext4-bios/raw/tree)
# plus what postfix would have left behind, written here by hand: ARRAY lines
# commented, net.ifnames=0 biosdevname=0 in /etc/default/grub, interfaces on eth0,
# the udev pin, a grub.cfg (fixtures/raw/verify/grub-debian11.cfg), kernel/initrd
# files, grub's i386-pc modules. The plan is the stand fixture's expected.plan.
# Everything that would touch a device is a seam redefined below (vf_initrd_list,
# vf_resolve_spec, vf_masks_of, vf_disk_head, vf_part_head, vf_partuuid,
# vf_efibootmgr, vf_root_usage; co_ping, co_boot for cutover).
#   (a) contract          (b) the green run, state, summary, the mounted path
#   (c) one mutation per hard check -> exit 3 and its FAIL line
#   (d) WARN-only mutations keep exit 0       (e) vf_boot_entry: menuentry, submenu, BLS, stub
#   (f) the UEFI variant  (g) small pure helpers      (h) cutover with seams
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317  # snippets handed to eval keep their $s; subshells change RUN/DRY on purpose; seam variables and seam functions are used from eval'd snippets and from the lib
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/ssh.sh
. "$REPO/lib/ssh.sh"
# shellcheck source=lib/inventory.sh
. "$REPO/lib/inventory.sh"
# shellcheck source=lib/plan.sh
. "$REPO/lib/plan.sh"
# shellcheck source=lib/apply.sh
. "$REPO/lib/apply.sh"
# shellcheck source=lib/target.sh
. "$REPO/lib/target.sh"
# shellcheck source=lib/verify.sh
. "$REPO/lib/verify.sh"
FIX=$REPO/tests/fixtures
STAND=$FIX/stand-debian-md-ext4-bios
VFIX=$FIX/raw/verify
W=$RUN/verify-work; mkdir -p "$W"
# no waiting in tests: no settle time, no pause between pings, six pings at most
MIGRATOR_CUTOVER_WAIT_S=0; MIGRATOR_CUTOVER_POLL_S=0; MIGRATOR_CUTOVER_TIMEOUT_S=6

U_ROOT=32431f84-84c8-46b5-bcc0-3e1e93c22618
U_BOOT=766ce09c-da55-4d91-90c5-8b5541a7b3be
U_SW0=231753ee-4ef0-48a7-9f6d-19a3e1b26951
U_SW1=129f6d9f-179a-4b12-b100-bc56202e6541
KVER=5.10.0-32-amd64
CMDLINE="root=UUID=$U_ROOT ro console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0"

# --- (a) contract ------------------------------------------------------------------------
for fn in verify_run verify_summary cutover_run vf_boot_entry vf_grubcfg vf_grub_default vf_grubenv_get vf_cmdline_sources vf_efi_parse \
          vf_check_boot vf_check_initramfs vf_check_fstab vf_check_cmdline vf_check_filesystems vf_check_bootloader vf_check_network vf_check_misc vf_check_mdadm \
          vf_ok vf_warn vf_fail vf_initrd_list vf_resolve_spec vf_masks_of vf_disk_head vf_part_head vf_partuuid vf_efibootmgr vf_root_usage \
          co_ping co_boot co_local_cidrs co_in_cidr; do
	if declare -F "$fn" >/dev/null; then _pass "defines $fn"; else _fail "defines $fn" "missing"; fi
done
out=$(bash -c 'set -u; for f in common ssh inventory plan apply target verify; do . "$1/lib/$f.sh"; done' _ "$REPO" 2>&1); rc=$?
assert_eq "verify.sh sources cleanly (set -u)" 0  "$rc"
assert_eq "verify.sh is silent on source"      "" "$out"

# --- helpers -------------------------------------------------------------------------------
# mkenv FILE [key=value...]: a grubenv the way grub-editenv writes it (1024 bytes, # padding)
mkenv() {
	local f=$1 n; shift
	{ echo "# GRUB Environment Block"; [ $# -eq 0 ] || printf '%s\n' "$@"; } > "$f"
	n=$(wc -c < "$f"); [ "$n" -le 1024 ] || { echo "mkenv: $n bytes do not fit the 1024-byte block" >&2; return 1; }
	head -c $((1024 - n)) /dev/zero | tr '\0' '#' >> "$f"
}
# mktree DIR: the captured tree after postfix (modules.alias dropped: 1.2 MB verify never reads)
mktree() {
	local t=$1
	rm -rf "$t"; mkdir -p "$t"
	cp -R "$STAND/raw/tree/." "$t/"
	rm -f "$t"/lib/modules/*/modules.alias
	sed -i 's/^ARRAY /# migrator: ARRAY /' "$t/etc/mdadm/mdadm.conf"
	sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0"/' "$t/etc/default/grub"
	sed -i 's/ens3/eth0/g' "$t/etc/network/interfaces"
	mkdir -p "$t/etc/udev/rules.d" "$t/boot/grub/i386-pc"
	echo 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="52:54:00:cc:dd:01", NAME="eth0"' > "$t/etc/udev/rules.d/70-persistent-net.rules"
	cp "$VFIX/grub-debian11.cfg" "$t/boot/grub/grub.cfg"
	: > "$t/boot/vmlinuz-$KVER"; : > "$t/boot/initrd.img-$KVER"; : > "$t/boot/grub/i386-pc/normal.mod"
}
# mkrun DIR: a state dir with the stand's plan and inventories
mkrun() { rm -rf "$1"; mkdir -p "$1"; cp "$STAND/donor.inv" "$STAND/recipient.inv" "$1/"; cp "$STAND/expected.plan" "$1/plan"; }
# vrun NAME [SNIPPET] [ROOTARG]: a fresh copy of the base tree ($W/NAME.tree, in $T for the
# snippet to mutate) and a fresh state dir ($W/NAME.run = RUN); verify_run on it in a subshell.
# Output -> $W/NAME.run/out, the status is echoed. ROOTARG "-" = call verify_run without ROOT.
vrun() {
	local name=$1 snip=${2:-} arg=${3:-}
	rm -rf "$W/$name.tree"; cp -R "$W/base" "$W/$name.tree"; mkrun "$W/$name.run"
	(
		RUN=$W/$name.run; T=$W/$name.tree
		eval "$snip"
		if [ "$arg" = - ]; then verify_run; else verify_run "$T"; fi
	) > "$W/$name.run/out" 2>&1
	echo $?
}
o() { cat "$W/$1.run/out"; }
st() { ( RUN=$W/$1.run; state_get "$2" ); }
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
# fails NAME SNIPPET LINE...: the mutation makes verify exit 3, mark the phase failed and print each LINE
fails() {
	local name=$1 snip=$2 line rc; shift 2
	rc=$(vrun "$name" "$snip")
	assert_eq "$name: exit 3" 3 "$rc"
	for line in "$@"; do assert_has "$name: $line" "$line" "$(o "$name")"; done
	assert_eq "$name: phase verify not done" "failed" "$(st "$name" phase.verify)"
	assert_has "$name: the last line says do NOT reboot" "do NOT reboot it: fix and re-run 'migrator -s verify'" "$(o "$name" | tail -1)"
}
# warns NAME SNIPPET N LINE...: the mutation keeps exit 0 with exactly N warnings
warns() {
	local name=$1 snip=$2 n=$3 line rc; shift 3
	rc=$(vrun "$name" "$snip")
	assert_eq "$name: exit 0" 0 "$rc"
	assert_has "$name: $n warning(s), no failure" " $n warnings, 0 failures" "$(o "$name")"
	for line in "$@"; do assert_has "$name: $line" "$line" "$(o "$name")"; done
	assert_eq "$name: phase verify done" "done" "$(st "$name" phase.verify)"
	assert_eq "$name: verify.warnings" "$n" "$(st "$name" verify.warnings)"
}

# --- the seams: what the recipient "has" -----------------------------------------------------
INITRD_LIST=".
etc
etc/udev/rules.d/70-persistent-net.rules
etc/modprobe.d
usr/lib/modules/$KVER/kernel/drivers/block/virtio_blk.ko
usr/lib/modules/$KVER/kernel/drivers/virtio/virtio_pci.ko
usr/lib/modules/$KVER/kernel/drivers/net/virtio_net.ko
usr/lib/modules/$KVER/kernel/fs/ext4/ext4.ko
usr/sbin/mdadm"
vf_initrd_list() { printf '%s\n' "$INITRD_LIST"; }
vf_resolve_spec() {
	case ${1//\"/} in
		UUID="$U_ROOT") echo /dev/vda4;; UUID="$U_BOOT") echo /dev/vda1;; UUID="$U_SW0") echo /dev/vda2;; UUID="$U_SW1") echo /dev/vda3;;
		UUID=ABCD-1234) echo /dev/vda5;;
		*) return 1;;
	esac
}
DONOR_MASKS=$(masks_norm ext4 "features:has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum|journal:journal_64bit")
vf_masks_of() { case $1 in /dev/vda1|/dev/vda4) printf '%s\n' "$DONOR_MASKS";; *) return 2;; esac; }
vf_disk_head() { printf 'xx GRUB Geom Hard Disk Read Error'; }
vf_part_head() { printf 'core.img'; }
vf_partuuid() { echo 5d2f6e6b-3a1c-4b7e-9d0f-1a2b3c4d5e6f; }
vf_efibootmgr() { return 2; }
vf_root_usage() { echo 37; }

mktree "$W/base"

# --- (b) the green run ---------------------------------------------------------------------------
rc=$(vrun green 'postfix_record() { echo called > "$RUN/record"; }')
assert_eq  "green: exit 0" 0 "$rc"
assert_has "green: final count line" "verify: 21 ok, 0 warnings, 0 failures" "$(o green)"
in_order "green: sections in order" "$W/green.run/out" \
	"=== boot entry ===" "=== initramfs ===" "=== fstab/swap ===" "=== kernel cmdline ===" \
	"=== filesystems ===" "=== bootloader ===" "=== network ===" "=== misc ===" "verify: "
assert_has "green: default entry line"    "  [ OK ] default entry: kernel $KVER (/boot/vmlinuz-$KVER) [menuentry /boot/grub/grub.cfg default=0]" "$(o green)"
assert_has "green: initrd line"           "  [ OK ] initrd /boot/initrd.img-$KVER" "$(o green)"
assert_has "green: cmdline shown"         "  [INFO] cmdline: $CMDLINE" "$(o green)"
assert_has "green: drivers in the initrd" "  [ OK ] /boot/initrd.img-$KVER: driver(s) virtio_blk,virtio_pci,virtio_net present" "$(o green)"
assert_has "green: pin in the initrd"     "  [ OK ] /boot/initrd.img-$KVER carries the udev pin" "$(o green)"
assert_has "green: fstab root resolves"   "  [ OK ] fstab: UUID=$U_ROOT (/) -> /dev/vda4" "$(o green)"
assert_has "green: fstab swap resolves"   "  [ OK ] fstab: UUID=$U_SW1 (none) -> /dev/vda3" "$(o green)"
assert_has "green: fstab count"           "  [ OK ] fstab has 4 entries, as planned" "$(o green)"
assert_has "green: no forbidden tokens"   "  [ OK ] no forbidden token (rd.md.uuid rd.md= /dev/md) in 3 cmdline source(s)" "$(o green)"
assert_has "green: root= resolves"        "  [ OK ] root=UUID=$U_ROOT -> /dev/vda4" "$(o green)"
assert_has "green: entry has the net tokens" "  [ OK ] default entry carries net.ifnames=0 biosdevname=0" "$(o green)"
assert_has "green: grub default has them" "  [ OK ] /etc/default/grub carries net.ifnames=0 biosdevname=0" "$(o green)"
assert_has "green: masks /boot"           "  [ OK ] /dev/vda1: ext4 feature masks equal the donor's" "$(o green)"
assert_has "green: masks /"               "  [ OK ] /dev/vda4: ext4 feature masks equal the donor's" "$(o green)"
assert_has "green: MBR"                   "  [ OK ] /dev/vda: GRUB boot code in the MBR" "$(o green)"
assert_has "green: grub modules"          "  [ OK ] grub's i386-pc modules are under /boot" "$(o green)"
assert_has "green: network on eth0"       "  [ OK ] primary network config (interfaces) is on eth0 (donor: ens3)" "$(o green)"
assert_has "green: mdadm.conf"            "  [ OK ] /etc/mdadm/mdadm.conf has no active ARRAY line" "$(o green)"
assert_has "green: machine-id"            "  [ OK ] /etc/machine-id is set" "$(o green)"
assert_has "green: free space"            "  [ OK ] target root is 37% used" "$(o green)"
assert_eq  "green: no FAIL line" 0 "$(o green | grep -c '\[FAIL\]')"
assert_eq  "green: no WARN line" 0 "$(o green | grep -c '\[WARN\]')"
assert_eq  "green: phase verify done"     "done" "$(st green phase.verify)"
assert_eq  "green: verify.warnings"       "0"    "$(st green verify.warnings)"
assert_eq  "green: verify.kernel (inside the target root)" "/boot/vmlinuz-$KVER"    "$(st green verify.kernel)"
assert_eq  "green: verify.initrd"         "/boot/initrd.img-$KVER" "$(st green verify.initrd)"
assert_eq  "green: verify.cmdline"        "$CMDLINE" "$(st green verify.cmdline)"
assert_eq  "green: summary file"          "verified: 21 ok, 0 warnings; next: migrator -s cutover" "$(cat "$W/green.run/summary")"
assert_has "green: MAC table"             "52:54:00:cc:dd:01   eth0       eth0" "$(o green)"
assert_has "green: BMC console line"      "on the BMC console: n=\$(grep -il 52:54:00:cc:dd:01 /sys/class/net/*/address" "$(o green)"
assert_eq  "green: postfix_record is not called for an operator's tree" "" "$(cat "$W/green.run/record" 2>/dev/null)"
assert_eq  "green: nothing written into the tree" "" "$(cd "$W" && diff -r base green.tree 2>&1)"
# follow-ups from postfix are part of the summary
out=$( RUN=$W/green.run; state_set postfix.followups "apt install grub-efi-amd64 && apt purge grub-pc; check /etc/rc.local"; verify_summary )
assert_has "summary: follow-up 1" "    - apt install grub-efi-amd64 && apt purge grub-pc" "$out"
assert_has "summary: follow-up 2" "    - check /etc/rc.local" "$out"

# the mounted path (no ROOT): phase postfix gates it, target_mount ro / target_umount bracket the checks
MOUNTED='target_mount() { echo "mount $*" >> "$RUN/calls"; TARGET_MNT=$T; }; target_umount() { echo umount >> "$RUN/calls"; }; postfix_record() { echo record >> "$RUN/calls"; }'
rc=$(vrun nopostfix "$MOUNTED" -)
assert_eq  "no ROOT, postfix not done: exit 2" 2 "$rc"
assert_has "no ROOT, postfix not done: says so" "postfix has not finished" "$(o nopostfix)"
assert_eq  "no ROOT, postfix not done: nothing mounted" "" "$(cat "$W/nopostfix.run/calls" 2>/dev/null)"
rc=$(vrun mounted "$MOUNTED; state_set phase.postfix done" -)
assert_eq  "no ROOT, postfix done: exit 0" 0 "$rc"
assert_eq  "no ROOT: mount ro, umount, then the record" "mount ro,umount,record" "$(paste -sd, "$W/mounted.run/calls")"
assert_eq  "no ROOT: phase verify done" "done" "$(st mounted phase.verify)"
rc=$(vrun mountedfail "$MOUNTED; state_set phase.postfix done; rm \"\$T/boot/vmlinuz-$KVER\"" -)
assert_eq  "no ROOT, a FAIL: exit 3" 3 "$rc"
assert_eq  "no ROOT, a FAIL: unmounted, no record" "mount ro,umount" "$(paste -sd, "$W/mountedfail.run/calls")"
# dry run: no target to look at -> the list of checks, exit 0, no state
rc=$(vrun drylist "$MOUNTED; DRY=y; target_dev_of() { echo /dev/migrator-test-absent; }" -)
assert_eq  "dry, no target: exit 0" 0 "$rc"
assert_has "dry, no target: lists the checks" "verify would check, read-only, after postfix" "$(o drylist)"
assert_has "dry, no target: names the sections" "kernel cmdline" "$(o drylist)"
assert_eq  "dry, no target: nothing mounted" "" "$(cat "$W/drylist.run/calls" 2>/dev/null)"
assert_eq  "dry, no target: no state" "" "$(cat "$W/drylist.run/state" 2>/dev/null)"
rc=$(vrun dryroot 'DRY=y')
assert_eq  "dry with ROOT: the checks run, exit 0" 0 "$rc"
assert_has "dry with ROOT: counts" "verify: 21 ok, 0 warnings, 0 failures" "$(o dryroot)"
assert_eq  "dry with ROOT: no state, no summary" "" "$(cat "$W/dryroot.run/state" "$W/dryroot.run/summary" 2>/dev/null)"
rc=$( ( RUN=$W/noplan; mkdir -p "$RUN"; verify_run "$W/base" ) > "$W/noplan.out" 2>&1; echo $? )
assert_eq  "no plan: exit 2" 2 "$rc"

# --- (c) one mutation per hard check -> exit 3 -------------------------------------------------------
fails m-ifnames 'sed -i "s/ net.ifnames=0//" "$T/boot/grub/grub.cfg"' \
	"  [FAIL] default entry lacks net.ifnames=0: the NIC would not be named eth0"
assert_has "m-ifnames: the count line" "1 failures" "$(o m-ifnames)"
assert_has "m-ifnames: failure file for the panel" "exit=3 " "$(cat "$W/m-ifnames.run/failure")"
fails m-grubdefault 'sed -i "s/ biosdevname=0\"/\"/" "$T/etc/default/grub"' \
	"  [FAIL] /etc/default/grub (GRUB_CMDLINE_LINUX) lacks biosdevname=0"
fails m-array 'sed -i "s/^# migrator: ARRAY/ARRAY/" "$T/etc/mdadm/mdadm.conf"' \
	"  [FAIL] /etc/mdadm/mdadm.conf still has 2 active ARRAY line(s)"
fails m-rdmd 'sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"rd.md.uuid=21422b8e:6e58604b:368cc1d7:0699304b /" "$T/etc/default/grub"' \
	"  [FAIL] /etc/default/grub:GRUB_CMDLINE_LINUX: forbidden token 'rd.md.uuid=21422b8e:6e58604b:368cc1d7:0699304b' (matches rd.md.uuid)"
fails m-rootmd 'sed -i "s|root=UUID=[0-9a-f-]*|root=/dev/md1|" "$T/boot/grub/grub.cfg"' \
	"  [FAIL] default entry: forbidden token 'root=/dev/md1' (matches /dev/md)" \
	"  [FAIL] root=/dev/md1 of the default entry does not resolve on this recipient"
fails m-grubd 'echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet rd.md=1\"" > "$T/etc/default/grub.d/50-old.cfg"' \
	"  [FAIL] /etc/default/grub.d/50-old.cfg:GRUB_CMDLINE_LINUX_DEFAULT: forbidden token 'rd.md=1' (matches rd.md=)"
fails m-driver 'INITRD_LIST=$(grep -v virtio_blk <<< "$INITRD_LIST")' \
	"  [FAIL] /boot/initrd.img-$KVER (default entry) lacks driver(s) virtio_blk"
fails m-devices 'INITRD_LIST="$INITRD_LIST
etc/lvm/devices/system.devices"' \
	"  [FAIL] /boot/initrd.img-$KVER contains etc/lvm/devices/system.devices"
fails m-fstab 'echo "UUID=deadbeef-0000-4000-8000-000000000001 /data ext4 defaults 0 2" >> "$T/etc/fstab"' \
	"  [FAIL] fstab: UUID=deadbeef-0000-4000-8000-000000000001 (/data) does not resolve to a block device on this recipient"
fails m-swapuuid 'sed -i "s/swap='"$U_SW0"',/swap=/" "$RUN/plan"' \
	"  [FAIL] fstab swap UUID=$U_SW0 is not a swap area the plan made"
fails m-ens3 'sed -i "s/eth0/ens3/g" "$T/etc/network/interfaces"' \
	"  [FAIL] primary network config (interfaces) does not name eth0 (the donor's ens3 was not renamed)"
fails m-oldmac 'sed -i "s|donor=ens3/-/|donor=ens3/52:54:00:AB:CD:01/|" "$RUN/plan"; echo "  hwaddress 52:54:00:ab:cd:01" >> "$T/etc/network/interfaces"' \
	"  [FAIL] the donor's MAC 52:54:00:AB:CD:01 is still in: /etc/network/interfaces"
fails m-masks 'vf_masks_of() { masks_norm ext4 "features:has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum orphan_file"; }' \
	"  [FAIL] /dev/vda1: ext4 feature masks differ from the donor's: features: donor-only none, target-only orphan_file" \
	"  [FAIL] /dev/vda4: ext4 feature masks differ from the donor's"
fails m-masksread 'vf_masks_of() { return 1; }' "  [FAIL] /dev/vda4: cannot read the ext4 feature masks"
fails m-mbr 'vf_disk_head() { printf "\353c\220 no boot code here"; }' \
	"  [FAIL] /dev/vda: no GRUB boot code in the first 440 bytes"
fails m-mods 'rm -r "$T/boot/grub/i386-pc"' "  [FAIL] no boot/grub/i386-pc/normal.mod (or boot/grub2/i386-pc) in the tree"
fails m-kernel 'rm "$T/boot/vmlinuz-$KVER"' \
	"  [FAIL] kernel /vmlinuz-$KVER of the default entry is not in the tree"
assert_eq "m-kernel: no stale kernel left for cutover kexec" "" "$(st m-kernel verify.kernel)"
fails m-initrd 'rm "$T/boot/initrd.img-$KVER"' \
	"  [FAIL] initrd /initrd.img-$KVER of the default entry is not in the tree"
fails m-noinitrdline 'sed -i "/^\tinitrd\t/d" "$T/boot/grub/grub.cfg"' "  [FAIL] the default entry has no initrd line"
fails m-nogrubcfg 'rm "$T/boot/grub/grub.cfg"' "  [FAIL] no default boot entry: no grub.cfg in the tree"
fails m-noroot 'sed -i "s|root=UUID=[0-9a-f-]* ||" "$T/boot/grub/grub.cfg"' "  [FAIL] the default entry's cmdline has no root="
fails m-nofstab 'rm "$T/etc/fstab"' "  [FAIL] no etc/fstab in the tree"
# gpt + bios: the bios_grub partition must exist and carry core.img
GPT='sed -i "s/^label=dos firmware=bios bios_grub=-/label=gpt firmware=bios bios_grub=128/" "$RUN/plan"'
rc=$(vrun gpt-ok "$GPT")
assert_eq  "gpt+bios: exit 0" 0 "$rc"
assert_has "gpt+bios: bios_grub checked" "  [ OK ] /dev/vda128 (bios_grub) carries grub's core image" "$(o gpt-ok)"
fails gpt-empty "$GPT; vf_part_head() { head -c 512 /dev/zero; }" "  [FAIL] /dev/vda128 (bios_grub) is empty"
fails gpt-absent "$GPT; vf_part_head() { return 2; }" "  [FAIL] bios_grub partition /dev/vda128 does not exist"
fails gpt-noslot 'sed -i "s/^label=dos /label=gpt /" "$RUN/plan"' "  [FAIL] gpt + bios without a bios_grub partition in the plan"
# selinux=autorelabel in the plan needs /.autorelabel
fails m-relabel 'sed -i "s/selinux=none/selinux=autorelabel/" "$RUN/plan"' "  [FAIL] /.autorelabel is missing"
rc=$(vrun relabel-ok 'sed -i "s/selinux=none/selinux=autorelabel/" "$RUN/plan"; : > "$T/.autorelabel"')
assert_eq  "autorelabel present: exit 0" 0 "$rc"
assert_has "autorelabel present: OK line" "  [ OK ] /.autorelabel is there" "$(o relabel-ok)"
# a re-run that fails takes back an earlier green
rc=$( ( RUN=$W/green.run; rm "$W/green.tree/boot/initrd.img-$KVER"; verify_run "$W/green.tree" ) > "$W/green.run/out2" 2>&1; echo $? )
assert_eq "green then broken: exit 3" 3 "$rc"
assert_eq "green then broken: phase verify taken back" "failed" "$(st green phase.verify)"

# --- (d) WARN-only mutations keep exit 0 ------------------------------------------------------------------
warns w-pin 'INITRD_LIST=$(grep -v persistent-net <<< "$INITRD_LIST")' 1 \
	"  [WARN] /boot/initrd.img-$KVER has no etc/udev/rules.d/70-persistent-net.rules" "         check: lsinitramfs "
rc=$(vrun nopin 'INITRD_LIST=$(grep -v persistent-net <<< "$INITRD_LIST"); sed -i "s/ pin=1/ pin=0/" "$RUN/plan"')
assert_has "pin=0: the pin is not looked for" "verify: 20 ok, 0 warnings, 0 failures" "$(o nopin)"
warns w-oldkernel ': > "$T/boot/initrd.img-5.10.0-30-amd64"; vf_initrd_list() { case $1 in *-30-amd64) grep -v virtio_net <<< "$INITRD_LIST";; *) printf "%s\n" "$INITRD_LIST";; esac; }' 1 \
	"  [WARN] /boot/initrd.img-5.10.0-30-amd64 lacks driver(s) virtio_net: kernel 5.10.0-30-amd64 would not boot on this recipient"
warns w-nolister 'vf_initrd_list() { return 2; }' 1 "  [WARN] cannot inspect initramfs /boot/initrd.img-$KVER"
warns w-builtin 'INITRD_LIST=$(grep -v virtio_blk <<< "$INITRD_LIST"); echo kernel/drivers/block/virtio-blk.ko >> "$T/lib/modules/$KVER/modules.builtin"' 0 \
	"driver(s) virtio_blk,virtio_pci,virtio_net present (virtio_blk built into the kernel)"
warns w-kdump ': > "$T/boot/initramfs-5.10.0-32-amd64kdump.img"; : > "$T/boot/initramfs-0-rescue-abc.img"; : > "$T/boot/initrd.img-$KVER.bak"' 0
warns w-xz 'INITRD_LIST=${INITRD_LIST//virtio_blk.ko/virtio-blk.ko.xz}' 0
warns w-nofail 'echo "UUID=deadbeef-0000-4000-8000-000000000001 /data ext4 defaults,nofail 0 2" >> "$T/etc/fstab"' 1 \
	"  [INFO] fstab: UUID=deadbeef-0000-4000-8000-000000000001 (/data) does not resolve here; it has nofail" \
	"  [WARN] fstab has 5 entries, the plan expects 4"
warns w-pseudo 'printf "%s\n" "tmpfs /tmp tmpfs defaults 0 0" "srv:/export /mnt/nfs nfs defaults 0 0" >> "$T/etc/fstab"; sed -i "s/ fstab=4 / fstab=6 /" "$RUN/plan"' 0 \
	"  [ OK ] fstab has 6 entries, as planned"
warns w-swapfile 'echo "/swapfile none swap sw 0 0" >> "$T/etc/fstab"; sed -i "s/ fstab=4 / fstab=5 /" "$RUN/plan"' 1 \
	"  [WARN] swapfile /swapfile is missing or not mode 600"
warns w-swapfile-ok 'echo "/swapfile none swap sw 0 0" >> "$T/etc/fstab"; sed -i "s/ fstab=4 / fstab=5 /" "$RUN/plan"; : > "$T/swapfile"; chmod 600 "$T/swapfile"' 0 \
	"  [ OK ] swapfile /swapfile is there (mode 600)"
warns w-resume 'mkdir -p "$T/etc/initramfs-tools/conf.d"; echo "RESUME=UUID=deadbeef-0000-4000-8000-000000000002" > "$T/etc/initramfs-tools/conf.d/resume"' 1 \
	"  [WARN] RESUME=UUID=deadbeef-0000-4000-8000-000000000002 (etc/initramfs-tools/conf.d/resume) does not resolve"
warns w-resume-ok 'mkdir -p "$T/etc/initramfs-tools/conf.d"; echo "RESUME=UUID='"$U_SW0"'" > "$T/etc/initramfs-tools/conf.d/resume"' 0 \
	"  [ OK ] RESUME=UUID=$U_SW0 -> /dev/vda2"
warns w-identity 'printf "UUID=gone-1\tremove\nrd.md.uuid=x\tremove\nUUID=ABCD-1234\t+ /boot/efi vfat umask=0077 0 1\n" > "$RUN/id"; sed -i "/^\[postfix\]/e cat $RUN/id" "$RUN/plan"; sed -i "s/ fstab=4 / fstab=5 /" "$RUN/plan"; echo "UUID=ABCD-1234 /boot/efi vfat umask=0077 0 1" >> "$T/etc/fstab"' 0 \
	"  [ OK ] fstab has 5 entries, as planned"
warns w-nodev 'vf_masks_of() { return 2; }' 2 "  [WARN] /dev/vda1 is not on this box: its ext4 feature masks were not compared"
warns w-nodisk 'vf_disk_head() { return 2; }' 1 "  [WARN] /dev/vda is not on this box: the MBR boot code was not checked"
warns w-machineid ': > "$T/etc/machine-id"' 1 "  [WARN] /etc/machine-id is empty or missing"
warns w-full 'vf_root_usage() { echo 97; }' 1 "  [WARN] target root is 97% used (less than 5% free)"
warns w-kcmdline 'mkdir -p "$T/etc/kernel"; echo "root=UUID='"$U_ROOT"' ro" > "$T/etc/kernel/cmdline"' 1 \
	"  [WARN] /etc/kernel/cmdline lacks net.ifnames=0 biosdevname=0"
warns w-maclist 'sed -i "s|donor=ens3/-/|donor=ens3/52:54:00:ab:cd:01/|" "$RUN/plan"; echo "iptables -A INPUT -m mac --mac-source 52:54:00:AB:CD:01 -j ACCEPT" > "$T/etc/rc.local"' 1 \
	"  [ OK ] the donor's MAC 52:54:00:ab:cd:01 is in no network config" \
	"  [WARN] the donor's MAC 52:54:00:ab:cd:01 also appears in: /etc/rc.local"
warns w-unknownnet 'sed -i "s|donor=ens3/-/interfaces|donor=-/-/unknown|" "$RUN/plan"' 1 "  [WARN] the donor's network config format is 'unknown'"
# several NICs: the boot NIC must be the first in PCI order, else eth0 may land elsewhere
NIC2='printf "nic\tname=eth1\tmac=52:54:00:cc:dd:00\tdriver=e1000e\tmodalias=pci:x\tpci=0000:00:02.0\tspeed=-\tlink=down\tfirmware=-\tonboard=-\n" >> "$RUN/recipient.inv"'
warns w-multinic "$NIC2" 1 \
	"  [WARN] 2 NICs and the boot NIC 52:54:00:cc:dd:01 is not the first in PCI order (52:54:00:cc:dd:00 is): eth0 may land on another NIC" \
	"         check: BMC console fix: ip link set eth0 down; ip link set eth0 name eth0x; ip link set eth1 down; ip link set eth1 name eth0; ip link set eth0 up"
warns w-multinic-first "${NIC2/0000:00:02.0/0000:00:1f.6}" 0 "  [ OK ] 2 NICs, the boot NIC 52:54:00:cc:dd:01 is first in PCI order"
# a saved default that names nothing: grub boots the first entry, verify says so
warns w-saved 'sed -i "s/set default=\"0\"/set default=\"\${saved_entry}\"/" "$T/boot/grub/grub.cfg"; mkenv "$T/boot/grub/grubenv" "saved_entry=Windows 95"' 1 \
	"  [WARN] the saved default names no entry (menuentry /boot/grub/grub.cfg default=Windows 95 not found, grub falls back to the first entry)"

# --- (e) vf_boot_entry: pure -------------------------------------------------------------------------------
B=$W/be; TAB=$'\t'
betree() {   # NAME DEFAULT-EXPRESSION [grubenv lines...]: the Debian tree with another "set default"
	local t=$B/$1 def=$2; shift 2
	rm -rf "$t"; mkdir -p "$t/boot/grub"
	sed "s|set default=\"0\"|set default=\"$def\"|" "$VFIX/grub-debian11.cfg" > "$t/boot/grub/grub.cfg"
	: > "$t/boot/vmlinuz-$KVER"; : > "$t/boot/initrd.img-$KVER"
	[ $# -eq 0 ] || mkenv "$t/boot/grub/grubenv" "$@"
}
K30=5.10.0-30-amd64
betree d0 0
assert_eq "menuentry: default=0" "/boot/vmlinuz-$KVER${TAB}/boot/initrd.img-$KVER${TAB}$CMDLINE${TAB}menuentry /boot/grub/grub.cfg default=0" "$(vf_boot_entry "$B/d0")"
assert_eq "menuentry: a trailing slash on ROOT is fine" "$(vf_boot_entry "$B/d0")" "$(vf_boot_entry "$B/d0/")"
betree d12 "1>2"
assert_eq "menuentry: default=1>2 (third entry of the submenu; its files are absent -> grub paths as they are)" \
	"/vmlinuz-$K30${TAB}/initrd.img-$K30${TAB}$CMDLINE${TAB}menuentry /boot/grub/grub.cfg default=1>2" "$(vf_boot_entry "$B/d12")"
betree d11 "1>1"
assert_has "menuentry: default=1>1 is the recovery entry" "ro single console=ttyS0,115200" "$(vf_boot_entry "$B/d11")"
betree d1 1
assert_has "menuentry: default=1 is a submenu: its first entry" "/boot/vmlinuz-$KVER${TAB}" "$(vf_boot_entry "$B/d1")"
betree dtitle "Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux $K30"
assert_has "menuentry: default by titles a>b" "/vmlinuz-$K30${TAB}/initrd.img-$K30${TAB}root=UUID=$U_ROOT ro console" "$(vf_boot_entry "$B/dtitle")"
betree did "gnulinux-advanced-$U_ROOT>gnulinux-$K30-recovery-$U_ROOT"
assert_has "menuentry: default by ids a>b" "/vmlinuz-$K30${TAB}/initrd.img-$K30${TAB}root=UUID=$U_ROOT ro single" "$(vf_boot_entry "$B/did")"
betree dlast "some other submenu>Debian GNU/Linux, with Linux $K30"
assert_has "menuentry: a>b with an unknown submenu: the last component as a title" "/vmlinuz-$K30${TAB}" "$(vf_boot_entry "$B/dlast")"
betree dsaved '${saved_entry}' "saved_entry=Debian GNU/Linux"
assert_eq "menuentry: saved_entry (a title) via grubenv" \
	"/boot/vmlinuz-$KVER${TAB}/boot/initrd.img-$KVER${TAB}$CMDLINE${TAB}menuentry /boot/grub/grub.cfg default=Debian GNU/Linux" "$(vf_boot_entry "$B/dsaved")"
betree dsavedid '${saved_entry}' "saved_entry=gnulinux-advanced-$U_ROOT>gnulinux-$K30-advanced-$U_ROOT" "other=1"
assert_has "menuentry: saved_entry (ids) via grubenv" "/vmlinuz-$K30${TAB}" "$(vf_boot_entry "$B/dsavedid")"
betree dsavednone '${saved_entry}'
assert_has "menuentry: \${saved_entry} without a grubenv is entry 0" "default=0" "$(vf_boot_entry "$B/dsavednone")"
betree dloose '${saved_entry}' "saved_entry=with Linux $K30 (recovery"
assert_has "menuentry: a partial title still finds its entry (local-boot's rule)" "/vmlinuz-$K30${TAB}/initrd.img-$K30${TAB}root=UUID=$U_ROOT ro single" "$(vf_boot_entry "$B/dloose")"
betree dmissing '${saved_entry}' "saved_entry=Windows 95"
assert_has "menuentry: an unknown default falls back to the first entry, and says so" \
	"/boot/vmlinuz-$KVER${TAB}/boot/initrd.img-$KVER${TAB}$CMDLINE${TAB}menuentry /boot/grub/grub.cfg default=Windows 95 not found, grub falls back to the first entry" "$(vf_boot_entry "$B/dmissing")"
betree dnext 0 "next_entry=1>2" "saved_entry=0"
assert_has "menuentry: a pending next_entry (grub-reboot) is what boots" "/vmlinuz-$K30${TAB}" "$(vf_boot_entry "$B/dnext")"
assert_eq "grubenv is 1024 bytes" 1024 "$(wc -c < "$B/dnext/boot/grub/grubenv")"
assert_eq "vf_grubenv_get: a value"          "1>2" "$(vf_grubenv_get "$B/dnext/boot/grub/grubenv" next_entry)"
assert_eq "vf_grubenv_get: an absent key"    ""    "$(vf_grubenv_get "$B/dnext/boot/grub/grubenv" kernelopts)"
assert_eq "vf_grubenv_get: an absent file"   ""    "$(vf_grubenv_get "$B/nosuch" saved_entry)"
# /boot on the root filesystem: grub paths carry /boot, unexpanded grub variables are dropped
mkdir -p "$B/rootboot/boot/grub"; : > "$B/rootboot/boot/vmlinuz-5.15.0-91-generic"; : > "$B/rootboot/boot/initrd.img-5.15.0-91-generic"
cat > "$B/rootboot/boot/grub/grub.cfg" <<'EOF'
set default="0"
menuentry "Ubuntu" --class ubuntu --id "gnulinux-simple-1" {
	linux	(hd0,gpt2)/boot/vmlinuz-5.15.0-91-generic root=/dev/mapper/vg0-root ro  quiet splash $vt_handoff
	initrd	/boot/microcode.cpio /boot/initrd.img-5.15.0-91-generic
}
menuentry 'no initrd here' {
	linux /boot/vmlinuz-5.15.0-91-generic root=/dev/sda1
}
EOF
assert_eq "menuentry: /boot on the root fs, (device) prefix, \$vars dropped, the last initrd image" \
	"/boot/vmlinuz-5.15.0-91-generic${TAB}/boot/initrd.img-5.15.0-91-generic${TAB}root=/dev/mapper/vg0-root ro quiet splash${TAB}menuentry /boot/grub/grub.cfg default=0" "$(vf_boot_entry "$B/rootboot")"
sed -i 's/set default="0"/set default="1"/' "$B/rootboot/boot/grub/grub.cfg"
assert_eq "menuentry: an entry without initrd reports -" \
	"/boot/vmlinuz-5.15.0-91-generic${TAB}-${TAB}root=/dev/sda1${TAB}menuentry /boot/grub/grub.cfg default=1" "$(vf_boot_entry "$B/rootboot")"
# no grub.cfg, no entries
mkdir -p "$B/empty/boot"
out=$(vf_boot_entry "$B/empty" 2>&1); rc=$?
assert_eq  "no grub.cfg: status 1" 1 "$rc"
assert_has "no grub.cfg: the reason" "no grub.cfg in the tree" "$out"
mkdir -p "$B/noentry/boot/grub"; printf '%s\n' 'set default="0"' 'set timeout=5' '### padding so that this is not mistaken for a stub' > "$B/noentry/boot/grub/grub.cfg"
out=$(vf_boot_entry "$B/noentry" 2>&1); rc=$?
assert_eq  "grub.cfg without entries: status 1" 1 "$rc"
assert_has "grub.cfg without entries: the reason" "no bootable menuentry in /boot/grub/grub.cfg" "$out"

# BLS (RHEL 8/9): loader/entries + grubenv
MID=4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f
KOPTS="root=/dev/mapper/rl-root ro resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap net.ifnames=0 biosdevname=0"
blstree() {   # NAME [grubenv lines...]
	local t=$B/$1 v; shift
	rm -rf "$t"; mkdir -p "$t/boot/grub2" "$t/boot/loader/entries"
	cp "$VFIX/grub-rhel9-bls.cfg" "$t/boot/grub2/grub.cfg"
	cp "$VFIX"/bls/*.conf "$t/boot/loader/entries/"
	for v in 427 503; do : > "$t/boot/vmlinuz-5.14.0-$v.el9.x86_64"; : > "$t/boot/initramfs-5.14.0-$v.el9.x86_64.img"; done
	[ $# -eq 0 ] || mkenv "$t/boot/grub2/grubenv" "$@"
}
blstree latest
assert_eq "bls: no saved_entry -> the newest, never the rescue entry" \
	"/boot/vmlinuz-5.14.0-503.el9.x86_64${TAB}/boot/initramfs-5.14.0-503.el9.x86_64.img${TAB}$KOPTS${TAB}bls $MID-5.14.0-503.el9.x86_64 (latest)" "$(vf_boot_entry "$B/latest")"
blstree saved "saved_entry=$MID-5.14.0-427.el9.x86_64" "kernelopts=$KOPTS "
assert_eq "bls: saved_entry=<machine-id>-<version>, options \$kernelopts from grubenv, \$tuned_* dropped" \
	"/boot/vmlinuz-5.14.0-427.el9.x86_64${TAB}/boot/initramfs-5.14.0-427.el9.x86_64.img${TAB}$KOPTS${TAB}bls $MID-5.14.0-427.el9.x86_64 (saved_entry)" "$(vf_boot_entry "$B/saved")"
blstree title "saved_entry=Rocky Linux (5.14.0-427.el9.x86_64) 9.4 (Blue Onyx)" "kernelopts=$KOPTS"
assert_has "bls: saved_entry as a title" "bls $MID-5.14.0-427.el9.x86_64 (saved_entry)" "$(vf_boot_entry "$B/title")"
blstree index "saved_entry=1" "kernelopts=$KOPTS"
assert_has "bls: saved_entry as an index into the list, newest first" "bls $MID-5.14.0-427.el9.x86_64 (saved_entry=1)" "$(vf_boot_entry "$B/index")"
blstree fallback "saved_entry=$MID-5.14.0-427.el9.x86_64"
assert_has "bls: \$kernelopts missing from grubenv -> grub.cfg's fallback kernelopts" \
	"${TAB}root=/dev/mapper/rl-root ro resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap fallback=1${TAB}" "$(vf_boot_entry "$B/fallback")"
blstree gone "saved_entry=$MID-5.14.0-162.el9.x86_64"
assert_has "bls: a saved_entry that names nothing -> the newest, and says so" \
	"bls $MID-5.14.0-503.el9.x86_64 (saved_entry=$MID-5.14.0-162.el9.x86_64 not found, grub falls back to the first entry)" "$(vf_boot_entry "$B/gone")"
blstree sortv; cp "$VFIX/bls/$MID-5.14.0-427.el9.x86_64.conf" "$B/sortv/boot/loader/entries/$MID-5.14.0-70.el9.x86_64.conf"
assert_has "bls: versions compare as versions (70 < 427 < 503)" "bls $MID-5.14.0-503.el9.x86_64 (latest)" "$(vf_boot_entry "$B/sortv")"
blstree nokernel; rm "$B/nokernel/boot/vmlinuz-5.14.0-503.el9.x86_64"
assert_has "bls: a missing kernel file is reported by its grub path" "/vmlinuz-5.14.0-503.el9.x86_64${TAB}/boot/initramfs-5.14.0-503.el9.x86_64.img${TAB}" "$(vf_boot_entry "$B/nokernel")"
# entries exist but grub.cfg has no blscfg: menuentry rules, unless the plan says bls=1
blstree nobls; cp "$VFIX/grub-debian11.cfg" "$B/nobls/boot/grub2/grub.cfg"
assert_has "loader/entries without blscfg in grub.cfg: the menuentry parser" "menuentry /boot/grub2/grub.cfg default=0" "$(vf_boot_entry "$B/nobls")"
assert_has "the same with [postfix] bls=1: BLS" "bls $MID-5.14.0-503.el9.x86_64 (latest)" "$(vf_boot_entry "$B/nobls" 1)"
blstree rescueonly; rm "$B/rescueonly"/boot/loader/entries/*5.14.0-*
out=$(vf_boot_entry "$B/rescueonly" 2>&1); rc=$?
assert_eq  "bls: only a rescue entry: status 1" 1 "$rc"
assert_has "bls: only a rescue entry: the reason" "no usable entry in /boot/loader/entries" "$out"

# the ESP's grub.cfg is a "configfile" stub: never parsed, followed to the real one
blstree stub "kernelopts=$KOPTS"; mkdir -p "$B/stub/boot/efi/EFI/rocky"; cp "$VFIX/grub-efi-stub.cfg" "$B/stub/boot/efi/EFI/rocky/grub.cfg"
assert_eq "stub: is a stub"         0 "$(vf_grubcfg_is_stub "$B/stub/boot/efi/EFI/rocky/grub.cfg"; echo $?)"
assert_eq "stub: the real one is not" 1 "$(vf_grubcfg_is_stub "$B/stub/boot/grub2/grub.cfg"; echo $?)"
assert_eq "stub: vf_grubcfg names the real grub.cfg" "$B/stub/boot/grub2/grub.cfg" "$(vf_grubcfg "$B/stub")"
# only reachable THROUGH the stub: a prefix none of the standard places have
rm -rf "$B/follow"; mkdir -p "$B/follow/boot/efi/EFI/debian" "$B/follow/boot/grub-alt"
printf '%s\n' "search.fs_uuid $U_BOOT root hd0,gpt2" "set prefix=(\$root)'/grub-alt'" "configfile \$prefix/grub.cfg" > "$B/follow/boot/efi/EFI/debian/grub.cfg"
cp "$VFIX/grub-debian11.cfg" "$B/follow/boot/grub-alt/grub.cfg"; : > "$B/follow/boot/vmlinuz-$KVER"; : > "$B/follow/boot/initrd.img-$KVER"
assert_eq "stub: followed by its prefix + configfile" "$B/follow/boot/grub-alt/grub.cfg" "$(vf_grubcfg "$B/follow")"
assert_eq "stub: the entry comes from the file it points to" \
	"/boot/vmlinuz-$KVER${TAB}/boot/initrd.img-$KVER${TAB}$CMDLINE${TAB}menuentry /boot/grub-alt/grub.cfg default=0" "$(vf_boot_entry "$B/follow")"
rm "$B/follow/boot/grub-alt/grub.cfg"
out=$(vf_boot_entry "$B/follow" 2>&1); rc=$?
assert_eq "stub pointing nowhere: status 1" 1 "$rc"
# a BLS tree through verify_run: every cmdline source is read, the default entry is the BLS one
blsrun() {   # NAME SNIPPET -> status (plan: bls=1, drivers as in the stand plan)
	local name=$1
	rm -rf "$W/$name.tree"; cp -R "$W/base" "$W/$name.tree"; mkrun "$W/$name.run"
	blstree "$name" "kernelopts=$KOPTS"
	rm -rf "$W/$name.tree/boot"; cp -R "$B/$name/boot" "$W/$name.tree/boot"
	mkdir -p "$W/$name.tree/boot/grub2/i386-pc"
	(
		RUN=$W/$name.run; T=$W/$name.tree
		sed -i 's/ bls=0 / bls=1 /' "$RUN/plan"
		vf_resolve_spec() { case $1 in UUID="$U_ROOT"|UUID="$U_BOOT"|UUID="$U_SW0"|UUID="$U_SW1"|/dev/mapper/rl-root) echo /dev/x;; *) return 1;; esac; }
		eval "$2"
		verify_run "$T"
	) > "$W/$name.run/out" 2>&1
	echo $?
}
rc=$(blsrun bls-green '')
assert_eq  "bls tree: exit 0" 0 "$rc"
assert_has "bls tree: default entry" "  [ OK ] default entry: kernel 5.14.0-503.el9.x86_64 (/boot/vmlinuz-5.14.0-503.el9.x86_64) [bls $MID-5.14.0-503.el9.x86_64 (latest)]" "$(o bls-green)"
assert_has "bls tree: every source counted (grub default x2, 3 entries, kernelopts, the entry)" "in 7 cmdline source(s)" "$(o bls-green)"
assert_has "bls tree: root= by LV path" "  [ OK ] root=/dev/mapper/rl-root -> /dev/x" "$(o bls-green)"
assert_has "bls tree: both initramfs images inspected, rescue skipped" "/boot/initramfs-5.14.0-427.el9.x86_64.img: driver(s)" "$(o bls-green)"
assert_eq  "bls tree: the rescue initramfs is not inspected" 0 "$(o bls-green | grep -c 'rescue.*driver')"
rc=$(blsrun bls-rdmd 'sed -i "s/^options root=/options rd.md.uuid=abc root=/" "$T/boot/loader/entries/'"$MID"'-0-rescue.conf"')
assert_eq  "bls tree, rd.md.uuid in the rescue entry: exit 3" 3 "$rc"
assert_has "bls tree: the source is named" "  [FAIL] /boot/loader/entries/$MID-0-rescue.conf: forbidden token 'rd.md.uuid=abc'" "$(o bls-rdmd)"
rc=$(blsrun bls-kopts 'mkenv "$T/boot/grub2/grubenv" "kernelopts=root=/dev/md126 ro"')
assert_eq  "bls tree, /dev/md in grubenv kernelopts: exit 3" 3 "$rc"
assert_has "bls tree: grubenv named" "  [FAIL] /boot/grub2/grubenv:kernelopts: forbidden token 'root=/dev/md126' (matches /dev/md)" "$(o bls-kopts)"

# --- (f) the UEFI variant ----------------------------------------------------------------------------
UEFI='sed -i "s/^label=dos firmware=bios bios_grub=- esp=-/label=gpt firmware=uefi bios_grub=- esp=5/; s/ grub=i386-pc / grub=x86_64-efi /; s/ fstab=4 / fstab=5 /; s| esp=- cmdline_forbid| esp=/dev/vda5 cmdline_forbid|" "$RUN/plan"
	echo "UUID=ABCD-1234 /boot/efi vfat umask=0077 0 1" >> "$T/etc/fstab"
	mkdir -p "$T/boot/efi/EFI/debian" "$T/boot/efi/EFI/BOOT"
	: > "$T/boot/efi/EFI/debian/shimx64.efi"; : > "$T/boot/efi/EFI/debian/grubx64.efi"; : > "$T/boot/efi/EFI/BOOT/BOOTX64.EFI"
	rm -r "$T/boot/grub/i386-pc"; vf_disk_head() { return 2; }'
rc=$(vrun uefi-ok "$UEFI")
assert_eq  "uefi: exit 0" 0 "$rc"
assert_has "uefi: loaders on the ESP" "  [ OK ] ESP (/boot/efi): EFI/debian/grubx64.efi EFI/debian/shimx64.efi" "$(o uefi-ok)"
assert_has "uefi: removable path"     "  [ OK ] ESP: removable path EFI/BOOT/BOOTX64.EFI is there" "$(o uefi-ok)"
assert_has "uefi: NVRAM not inspected on a BIOS-booted Live" "  [INFO] this Live did not boot through UEFI" "$(o uefi-ok)"
assert_has "uefi: green" " 0 warnings, 0 failures" "$(o uefi-ok)"
assert_eq  "uefi: the MBR is not asked about" 0 "$(o uefi-ok | grep -c 'MBR')"
fails uefi-noloader "$UEFI; rm \"\$T\"/boot/efi/EFI/debian/*.efi" "  [FAIL] ESP (/boot/efi) has no EFI/<id>/grubx64.efi or shimx64.efi"
fails uefi-nofstab "$UEFI; sed -i '/vfat/d' \"\$T/etc/fstab\"; sed -i 's/ fstab=5 / fstab=4 /' \"\$RUN/plan\"" "  [FAIL] uefi: no vfat entry for the ESP (/boot/efi) in etc/fstab"
warns uefi-noremovable "$UEFI; rm \"\$T/boot/efi/EFI/BOOT/BOOTX64.EFI\"" 1 "  [WARN] ESP has no EFI/BOOT/BOOTX64.EFI"
warns uefi-lowercase "$UEFI; mv \"\$T/boot/efi/EFI/BOOT\" \"\$T/boot/efi/EFI/boot\"; mv \"\$T/boot/efi/EFI/boot/BOOTX64.EFI\" \"\$T/boot/efi/EFI/boot/bootx64.efi\"" 0 \
	"  [ OK ] ESP: removable path EFI/BOOT/BOOTX64.EFI is there"
# a firmware change installs grub from the Live with --removable only: BOOTX64.EFI alone is the loader
warns uefi-fromlive "$UEFI; rm -r \"\$T/boot/efi/EFI/debian\"; sed -i 's/^label=gpt firmware=uefi.*/& grub_from_live=1/' \"\$RUN/plan\"" 0 \
	"  [ OK ] ESP (/boot/efi): EFI/BOOT/BOOTX64.EFI (removable install from the Live"
# NVRAM, from a recorded efibootmgr -v
EFI_OK="vf_efibootmgr() { cat '$VFIX/efibootmgr-v.txt'; }"
warns uefi-nvram "$UEFI; $EFI_OK" 0 \
	"  [ OK ] NVRAM: Boot0000 loads from the ESP (PARTUUID 5d2f6e6b-3a1c-4b7e-9d0f-1a2b3c4d5e6f)" \
	"  [ OK ] BootOrder starts with a network entry"
warns uefi-nvram-other "$UEFI; $EFI_OK; vf_partuuid() { echo 00000000-1111-4222-8333-444444444444; }" 1 \
	"  [WARN] no NVRAM boot entry points at the ESP /dev/vda5 (PARTUUID 00000000-1111-4222-8333-444444444444): the firmware will use the removable path"
warns uefi-localfirst "$UEFI; vf_efibootmgr() { sed 's/^BootOrder: .*/BootOrder: 0000,0004,0001/' '$VFIX/efibootmgr-v.txt'; }" 1 \
	"  [WARN] BootOrder does not start with a network (PXE) entry"
warns uefi-localasked "$UEFI; OPT[bootorder]=local; vf_efibootmgr() { sed 's/^BootOrder: .*/BootOrder: 0000,0004,0001/' '$VFIX/efibootmgr-v.txt'; }" 0 \
	"  [INFO] BootOrder starts with a local entry, as asked (bootorder=local)"
warns uefi-nopxe "$UEFI; vf_efibootmgr() { grep -v PXE '$VFIX/efibootmgr-v.txt'; }" 0 "  [INFO] no network boot entry in NVRAM: BootOrder not judged"
assert_eq "vf_efi_parse: the recorded output" "esp=Boot0000 pxe=1 first=0004 firstpxe=1" "$(vf_efi_parse 5D2F6E6B-3A1C-4B7E-9D0F-1A2B3C4D5E6F < "$VFIX/efibootmgr-v.txt")"
assert_eq "vf_efi_parse: another partition"    "esp=- pxe=1 first=0004 firstpxe=1" "$(vf_efi_parse 00000000-1111-4222-8333-444444444444 < "$VFIX/efibootmgr-v.txt")"
assert_eq "vf_efi_parse: no PARTUUID known"    "esp=- pxe=1 first=0004 firstpxe=1" "$(vf_efi_parse "" < "$VFIX/efibootmgr-v.txt")"
assert_eq "vf_efi_parse: nothing on stdin"     "esp=- pxe=0 first=- firstpxe=0" "$(vf_efi_parse x < /dev/null)"

# --- (g) small pure helpers --------------------------------------------------------------------------------
assert_eq "vf_grub_path: plain"            "/vmlinuz-1"      "$(vf_grub_path /vmlinuz-1)"
assert_eq "vf_grub_path: (device) prefix"  "/boot/vmlinuz-1" "$(vf_grub_path '(hd0,msdos1)/boot/vmlinuz-1')"
assert_eq "vf_grub_path: quotes"           "/grub2"          "$(vf_grub_path "(\$root)'/grub2'")"
assert_eq "vf_missing_tokens: all there"   ""                "$(vf_missing_tokens "net.ifnames=0 biosdevname=0" "ro biosdevname=0 quiet net.ifnames=0")"
assert_eq "vf_missing_tokens: whole words" "net.ifnames=0"   "$(vf_missing_tokens "net.ifnames=0 biosdevname=0" "ro xnet.ifnames=0 net.ifnames=01 biosdevname=0")"
assert_eq "vf_has_module: underscore for hyphen" 0 "$(vf_has_module "usr/lib/modules/x/kernel/drivers/net/bnxt-en.ko.zst" bnxt_en; echo $?)"
assert_eq "vf_has_module: hyphen for underscore" 0 "$(vf_has_module "lib/modules/x/megaraid_sas.ko" megaraid-sas; echo $?)"
assert_eq "vf_has_module: lsinitrd's long listing" 0 "$(vf_has_module "-rw-r--r--   1 root     root        12345 Jan  1  1970 usr/lib/modules/x/kernel/drivers/scsi/mpt3sas/mpt3sas.ko.xz" mpt3sas; echo $?)"
assert_eq "vf_has_module: not a prefix match"    1 "$(vf_has_module "lib/modules/x/virtio_blk_extra.ko" virtio_blk; echo $?)"
assert_eq "vf_has_module: not a suffix match"    1 "$(vf_has_module "lib/modules/x/xvirtio_blk.ko" virtio_blk; echo $?)"
assert_eq "vf_builtin: the captured modules.builtin has binfmt_elf, not virtio_blk" "0 1" \
	"$(vf_builtin "$W/base" "$KVER" binfmt-elf; a=$?; vf_builtin "$W/base" "$KVER" virtio_blk; echo "$a $?")"
assert_eq "vf_builtin: no module tree" 1 "$(vf_builtin "$W/base" 9.9.9 ext4; echo $?)"
assert_eq "vf_cmdline_sources: the Debian tree" \
	"/etc/default/grub:GRUB_CMDLINE_LINUX${TAB}console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0|/etc/default/grub:GRUB_CMDLINE_LINUX_DEFAULT${TAB}" \
	"$(vf_cmdline_sources "$W/base" | paste -sd'|' -)"
# the primary config per format
N=$W/net; rm -rf "$N"
mkdir -p "$N/etc/netplan" "$N/etc/systemd/network" "$N/etc/sysconfig/network-scripts" "$N/etc/NetworkManager/system-connections" "$N/etc/network/interfaces.d"
sed 's/enp3s0/eth0/' "$FIX/raw/netplan.yaml" > "$N/etc/netplan/01-netcfg.yaml"
cp "$FIX/raw/10-wired.network" "$N/etc/systemd/network/10-wired.network"
cp "$FIX/raw/eno1.nmconnection" "$N/etc/NetworkManager/system-connections/eno1.nmconnection"
: > "$N/etc/sysconfig/network-scripts/ifcfg-eth0"
printf '%s\n' "auto eth0" "iface eth0 inet static" > "$N/etc/network/interfaces.d/eth0"
np() { vf_net_primary "$N" "$@"; echo $?; }
assert_eq "net primary: interfaces.d names eth0"        0 "$(np interfaces eth0 "")"
assert_eq "net primary: interfaces, another name"       1 "$(np interfaces eth1 "")"
assert_eq "net primary: interfaces, eth0 is not eth00"  1 "$(np interfaces eth "")"
assert_eq "net primary: netplan key eth0:"              0 "$(np netplan eth0 "")"
assert_eq "net primary: netplan, not a key"             1 "$(np netplan eth9 "")"
assert_eq "net primary: networkd by Name= (no)"         1 "$(np networkd eth0 "")"
assert_eq "net primary: networkd by MACAddress="        0 "$(np networkd eth0 52:54:00:AA:BB:CC)"
assert_eq "net primary: networkd by Name="              0 "$(np networkd enp1s0 "")"
assert_eq "net primary: ifcfg-eth0 exists"              0 "$(np ifcfg eth0 "")"
assert_eq "net primary: ifcfg-eth1 does not"            1 "$(np ifcfg eth1 "")"
assert_eq "net primary: keyfile by interface-name (no)" 1 "$(np nm-keyfile eth0 "")"
assert_eq "net primary: keyfile by mac-address"         0 "$(np nm-keyfile eth0 3c:ec:ef:12:34:56)"
assert_eq "net primary: keyfile by interface-name"      0 "$(np keyfile eno1 "")"
assert_eq "net primary: unknown format"                 2 "$(np unknown eth0 "")"
assert_eq "vf_netcfg_files: every format's files" \
	"/etc/NetworkManager/system-connections/eno1.nmconnection /etc/netplan/01-netcfg.yaml /etc/network/interfaces.d/eth0 /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/systemd/network/10-wired.network" \
	"$(vf_netcfg_files "$N" | sed "s|^$N||" | LC_ALL=C sort | paste -sd' ' -)"
assert_eq "vf_bmc_fix: by name" "ip link set eth0 down; ip link set eth0 name eth0x; ip link set eth2 down; ip link set eth2 name eth0; ip link set eth0 up" "$(vf_bmc_fix eth0 aa:bb eth2)"
# subnets
assert_eq "co_in_cidr: inside /24"      0 "$(co_in_cidr 10.0.1.57 10.0.1.56/24; echo $?)"
assert_eq "co_in_cidr: outside /24"     1 "$(co_in_cidr 10.0.2.57 10.0.1.56/24; echo $?)"
assert_eq "co_in_cidr: /27 boundary in" 0 "$(co_in_cidr 46.4.5.30 46.4.5.6/27; echo $?)"
assert_eq "co_in_cidr: /27 boundary out" 1 "$(co_in_cidr 46.4.5.33 46.4.5.6/27; echo $?)"
assert_eq "co_in_cidr: /32"             1 "$(co_in_cidr 10.0.0.2 10.0.0.1/32; echo $?)"
assert_eq "co_in_cidr: leading zeros are decimal" 0 "$(co_in_cidr 10.0.08.9 10.0.8.1/24; echo $?)"
assert_eq "co_in_cidr: not an IPv4 address" 1 "$(co_in_cidr donor.example 10.0.0.1/8; echo $?)"
assert_eq "co_visible: through the seam" "0 1" "$(co_local_cidrs() { printf '%s\n' 127.0.0.1/8 10.0.1.56/24; }; co_visible 10.0.1.9; a=$?; co_visible 127.0.0.5; echo "$a $?")"

# --- (g2) raid=1 (crafted from the stand plan): the arrays, mdadm.conf, the initramfs, both disks -----------
MDSTAT_OK='Personalities : [raid1]
md4 : active raid1 vdb4[1] vda4[0]
      931600384 blocks super 1.2 [2/2] [UU]
      [=>...................]  resync =  5.3% (49643520/931600384) finish=78.2min speed=187900K/sec
      bitmap: 7/7 pages [28KB], 65536KB chunk

md3 : active raid1 vdb3[1] vda3[0]
      2093056 blocks super 1.2 [2/2] [UU]

md2 : active raid1 vdb2[1] vda2[0]
      2093056 blocks super 1.2 [2/2] [UU]
      	resync=DELAYED

md1 : active raid1 vdb1[1] vda1[0]
      1046528 blocks super 1.2 [2/2] [UU]

unused devices: <none>'
MDU1=11111111:22222222:33333333:44444444; MDU2=55555555:66666666:77777777:88888888; MDU3=99999999:aaaaaaaa:bbbbbbbb:cccccccc; MDU4=dddddddd:eeeeeeee:ffffffff:00000000
RAID='sed -i "s/^label=dos firmware=bios bios_grub=- esp=- .*/& raid=1/" "$RUN/plan"
	sed -i "/^currently=free$/a disk2=/dev/vdb id2=serial:XSRECIP1 size2=21474836480 ptuuid2=- head2=- geometry=21474836480 md=/dev/md1,/dev/md2,/dev/md3,/dev/md4 esp2=-\ncurrently2=free" "$RUN/plan"
	sed -i "/^\[lvm\]/i [md]\nmdadm --create /dev/md1 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=1 --uuid='$MDU1' /dev/vda1 /dev/vdb1\nmdadm --create /dev/md2 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=2 --uuid='$MDU2' /dev/vda2 /dev/vdb2\nmdadm --create /dev/md3 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=3 --uuid='$MDU3' /dev/vda3 /dev/vdb3\nmdadm --create /dev/md4 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=4 --uuid='$MDU4' /dev/vda4 /dev/vdb4" "$RUN/plan"
	sed -i "s/ cmdline_forbid=rd.md.uuid,rd.md=,\/dev\/md$/& md=\/dev\/md1,\/dev\/md2,\/dev\/md3,\/dev\/md4 esp2=-/" "$RUN/plan"
	plan_md_arrays "$RUN/plan" >> "$T/etc/mdadm/mdadm.conf"
	INITRD_LIST="$INITRD_LIST
etc/mdadm/mdadm.conf
usr/lib/modules/'"$KVER"'/kernel/drivers/md/raid1.ko"
	vf_mdstat() { printf "%s\n" "$MDSTAT_OK"; }
	vf_md_uuid() { case $1 in /dev/md1) echo '$MDU1';; /dev/md2) echo '$MDU2';; /dev/md3) echo '$MDU3';; /dev/md4) echo '$MDU4';; *) return 2;; esac; }'
rc=$(vrun raid-ok "$RAID")
assert_eq  "raid: exit 0" 0 "$rc"
assert_has "raid: green" "verify: 31 ok, 0 warnings, 0 failures" "$(o raid-ok)"
assert_has "raid: the md section"        "=== md arrays ===" "$(o raid-ok)"
assert_has "raid: an array in sync"      "  [ OK ] /dev/md1: both members in sync" "$(o raid-ok)"
assert_has "raid: an array resyncing is fine" "  [ OK ] /dev/md4: both members in, resync =  5.3% (49643520/931600384) finish=78.2min speed=187900K/sec (continues in the background, also after the boot)" "$(o raid-ok)"
assert_has "raid: a delayed resync is fine too"  "  [ OK ] /dev/md2: both members in, resync=DELAYED (continues in the background, also after the boot)" "$(o raid-ok)"
assert_has "raid: the UUID is the plan's" "  [ OK ] /dev/md4: UUID $MDU4 is the plan's (mdadm.conf and the initramfs find it)" "$(o raid-ok)"
assert_has "raid: mdadm.conf lists ours (the donor's stay commented out)" "  [ OK ] /etc/mdadm/mdadm.conf lists exactly this recipient's 4 array(s)" "$(o raid-ok)"
assert_has "raid: the initramfs can assemble" "  [ OK ] /boot/initrd.img-$KVER: mdadm, its mdadm.conf and raid1 are in (the arrays can be assembled at boot)" "$(o raid-ok)"
assert_has "raid: boot code on disk 1"   "  [ OK ] /dev/vda: GRUB boot code in the MBR" "$(o raid-ok)"
assert_has "raid: boot code on disk 2"   "  [ OK ] /dev/vdb: GRUB boot code in the MBR" "$(o raid-ok)"
fails raid-degraded "$RAID; vf_mdstat() { printf '%s\n' \"\$MDSTAT_OK\" | sed 's/^md4 : active raid1 vdb4\[1\] vda4\[0\]/md4 : active raid1 vda4[0]/; s/\[2\/2\] \[UU\]/[2\/1] [U_]/'; }" \
	"  [FAIL] /dev/md4 is degraded ([U_], 1 member(s)): both disks must be in before the first boot"
fails raid-missing "$RAID; vf_mdstat() { printf '%s\n' \"\$MDSTAT_OK\" | grep -v '^md2 '; }" \
	"  [FAIL] /dev/md2 is not running (apply made it, something stopped it)"
fails raid-failedmember "$RAID; vf_mdstat() { printf '%s\n' \"\$MDSTAT_OK\" | sed 's/vdb3\[1\]/vdb3[1](F)/'; }" \
	"  [FAIL] /dev/md3 has a failed member"
fails raid-uuid "$RAID; vf_md_uuid() { echo 00000000:00000000:00000000:00000001; }" \
	"  [FAIL] /dev/md1: UUID 00000000:00000000:00000000:00000001 is not the plan's $MDU1"
fails raid-conf-missing "$RAID; sed -i '/^ARRAY \/dev\/md3 /d' \"\$T/etc/mdadm/mdadm.conf\"" \
	"  [FAIL] /etc/mdadm/mdadm.conf lacks: ARRAY /dev/md3 metadata=1.2 name=fixture-debian:3 UUID=$MDU3"
fails raid-conf-stale "$RAID; sed -i 's/^# migrator: ARRAY \/dev\/md0 /ARRAY \/dev\/md0 /' \"\$T/etc/mdadm/mdadm.conf\"" \
	"  [FAIL] /etc/mdadm/mdadm.conf has ARRAY line(s) of arrays that are not here: ARRAY /dev/md0 metadata=1.2 UUID=21422b8e:6e58604b:368cc1d7:0699304b"
fails raid-noconf "$RAID; rm \"\$T/etc/mdadm/mdadm.conf\"" \
	"  [FAIL] no mdadm.conf in the tree: the initramfs would not know the arrays"
fails raid-initrd "$RAID; INITRD_LIST=\$(grep -v -e usr/sbin/mdadm -e raid1.ko <<< \"\$INITRD_LIST\")" \
	"  [FAIL] /boot/initrd.img-$KVER (default entry) lacks mdadm, raid1.ko: the md arrays would not be assembled, no root"
fails raid-mbr2 "$RAID; vf_disk_head() { case \$1 in /dev/vdb) printf 'nothing';; *) printf 'xx GRUB';; esac; }" \
	"  [FAIL] /dev/vdb: no GRUB boot code in the first 440 bytes"
warns raid-nomdstat "$RAID; vf_mdstat() { return 2; }" 1 \
	"  [WARN] no /proc/mdstat on this box: the arrays were not checked"
fails raid-rdmd "$RAID; sed -i 's/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"rd.md.uuid=21422b8e:6e58604b:368cc1d7:0699304b /' \"\$T/etc/default/grub\"" \
	"forbidden token 'rd.md.uuid=21422b8e:6e58604b:368cc1d7:0699304b' (matches rd.md.uuid): it names the donor's md arrays, which are not here (this recipient's arrays are found by UUID through mdadm.conf)"
# uefi + raid: the second ESP is looked at through its own seam, NVRAM wants an entry for it too
RAIDUEFI="$UEFI; $RAID; sed -i 's/^label=gpt firmware=uefi bios_grub=- esp=5 .*/& raid=1/; s/ esp2=-/ esp2=\/dev\/vdb5/g' \"\$RUN/plan\""
warns raid-uefi-ok "$RAIDUEFI; vf_esp_files() { [ \"\$1\" = /dev/vdb5 ] || return 2; printf '%s\n' EFI/BOOT/BOOTX64.EFI EFI/debian/grubx64.efi EFI/debian/shimx64.efi; }" 0 \
	"  [ OK ] second ESP /dev/vdb5: EFI/BOOT/BOOTX64.EFI EFI/debian/grubx64.efi EFI/debian/shimx64.efi"
fails raid-uefi-empty "$RAIDUEFI; vf_esp_files() { printf '%s\n' ''; }" \
	"  [FAIL] second ESP /dev/vdb5 carries no EFI loader: /dev/vdb could not boot on its own"
warns raid-uefi-absent "$RAIDUEFI; vf_esp_files() { return 2; }" 1 \
	"  [WARN] second ESP /dev/vdb5 is not on this box: not checked"
warns raid-uefi-nvram2 "$RAIDUEFI; $EFI_OK; vf_esp_files() { printf '%s\n' EFI/debian/grubx64.efi; }; vf_partuuid() { case \$1 in /dev/vdb5) echo 00000000-1111-4222-8333-444444444444;; *) echo 5d2f6e6b-3a1c-4b7e-9d0f-1a2b3c4d5e6f;; esac; }" 1 \
	"  [ OK ] NVRAM: Boot0000 loads from the ESP (PARTUUID 5d2f6e6b-3a1c-4b7e-9d0f-1a2b3c4d5e6f)" \
	"  [WARN] no NVRAM boot entry points at the second ESP /dev/vdb5 (PARTUUID 00000000-1111-4222-8333-444444444444)"

# --- (h) cutover ---------------------------------------------------------------------------------------------
# crun NAME MODE [SNIPPET]: cutover_run in a subshell with every seam recording into $RUN;
# the donor "answers" the first $ALIVE pings. Output -> $W/NAME.co/out, the status is echoed.
crun() {
	local name=$1 mode=$2 snip=${3:-}
	rm -rf "$W/$name.co"; mkrun "$W/$name.co"
	(
		RUN=$W/$name.co; YES=y; DONOR_HOST=192.0.2.10; ALIVE=2; PINGS=0
		state_set phase.verify "done"
		state_set verify.kernel "/boot/vmlinuz-$KVER"; state_set verify.initrd "/boot/initrd.img-$KVER"; state_set verify.cmdline "$CMDLINE"
		rrun_sh() { if [ -n "$DRY" ]; then echo "(dry) donor: $1"; else echo "$1" >> "$RUN/donor.cmd"; fi; }
		ssh_disconnect() { echo disconnect >> "$RUN/calls"; }
		co_ping() { PINGS=$((PINGS+1)); echo "$1" >> "$RUN/pings"; [ "$PINGS" -le "$ALIVE" ]; }
		co_boot() { echo "$*" >> "$RUN/boot.cmd"; }
		co_local_cidrs() { echo 10.0.1.56/24; }
		target_mount() { echo "mount $*" >> "$RUN/calls"; TARGET_MNT=$W/base; }
		target_umount() { echo umount >> "$RUN/calls"; }
		kexec() { :; }
		eval "$snip"
		cutover_run "$mode"
	) > "$W/$name.co/out" 2>&1
	echo $?
}
co() { cat "$W/$1.co/$2" 2>/dev/null; }
cst() { ( RUN=$W/$1.co; state_get "$2" ); }
NETDOWN='setsid nohup sh -c "sleep 2; for i in /sys/class/net/*; do n=\${i##*/}; [ \$n = lo ] || ip link set \$n down; done" >/dev/null 2>&1 </dev/null &'

rc=$(crun notverified netdown 'state_set phase.verify failed')
assert_eq  "cutover, not verified: exit 2" 2 "$rc"
assert_has "cutover, not verified: run verify first" "run verify first" "$(co notverified out)"
assert_eq  "cutover, not verified: the donor is not touched" "" "$(co notverified donor.cmd)$(co notverified boot.cmd)"
rc=$(crun forced netdown 'state_set phase.verify failed; OPT[force]=1')
assert_eq  "cutover, force=1: goes on" 0 "$rc"
assert_has "cutover, force=1: with a warning" "WARN: verify is not marked done: cutting over anyway (force=1)" "$(co forced out)"
rc=$(crun badmode sideways)
assert_eq  "cutover, unknown mode: exit 2" 2 "$rc"

rc=$(crun none none)
assert_eq  "cutover none: exit 0" 0 "$rc"
assert_has "cutover none: step 1" "1. take the donor 192.0.2.10 off the network" "$(co none out)"
assert_has "cutover none: step 3" "3. boot this recipient into the migrated system:  systemctl reboot" "$(co none out)"
assert_eq  "cutover none: nothing is called" "" "$(co none donor.cmd)$(co none boot.cmd)$(co none pings)"
assert_eq  "cutover none: state" "none" "$(cst none cutover.mode)"

rc=$(crun netdown netdown)
assert_eq  "cutover netdown: exit 0" 0 "$rc"
assert_eq  "cutover netdown: the donor command, detached and delayed" "$NETDOWN" "$(co netdown donor.cmd)"
assert_eq  "cutover netdown: the control channel is closed" "disconnect" "$(co netdown calls)"
assert_eq  "cutover netdown: alive twice, then three misses" "192.0.2.10 192.0.2.10 192.0.2.10 192.0.2.10 192.0.2.10" "$(co netdown pings | paste -sd' ' -)"
assert_has "cutover netdown: says the donor is gone" "donor is gone: 192.0.2.10 does not answer" "$(co netdown out)"
assert_eq  "cutover netdown: then, and only then, the reboot" "systemctl reboot" "$(co netdown boot.cmd)"
assert_eq  "cutover netdown: state mode" "netdown" "$(cst netdown cutover.mode)"
assert_ok  "cutover netdown: state time" test -n "$(cst netdown cutover.time)"
in_order "cutover netdown: order in the log" "$W/netdown.co/log" "donor is gone" "donor 192.0.2.10 is off the network"

rc=$(crun alive netdown 'ALIVE=99')
assert_eq  "donor keeps answering: exit 1" 1 "$rc"
assert_has "donor keeps answering: the reason" "donor still answers on 192.0.2.10: not rebooting (two hosts with one IP)" "$(co alive out | tail -1)"
assert_eq  "donor keeps answering: six pings, then it gives up" 6 "$(co alive pings | wc -l)"
assert_eq  "donor keeps answering: never boots" "" "$(co alive boot.cmd)"
assert_eq  "donor keeps answering: no cutover state" "" "$(cst alive cutover.mode)"
rc=$(crun flapping netdown 'co_ping() { PINGS=$((PINGS+1)); echo "$1" >> "$RUN/pings"; [ $((PINGS % 3)) -eq 0 ]; }')
assert_eq  "two misses, an answer, two misses...: never three in a row, exit 1" 1 "$rc"

rc=$(crun poweroff poweroff 'ALIVE=0')
assert_eq  "cutover poweroff: exit 0" 0 "$rc"
assert_eq  "cutover poweroff: the donor command" 'setsid nohup sh -c "sleep 2; poweroff" >/dev/null 2>&1 </dev/null &' "$(co poweroff donor.cmd)"
assert_eq  "cutover poweroff: three misses are enough" 3 "$(co poweroff pings | wc -l)"
assert_eq  "cutover poweroff: reboot" "systemctl reboot" "$(co poweroff boot.cmd)"
rc=$(crun rebootfallback netdown 'ALIVE=0; co_boot() { echo "$*" >> "$RUN/boot.cmd"; [ "$1" != systemctl ]; }')
assert_eq  "systemctl reboot fails: plain reboot" "systemctl reboot,reboot" "$(co rebootfallback boot.cmd | paste -sd, -)"
rc=$(crun donorrc netdown 'ALIVE=0; rrun_sh() { return 255; }')
assert_eq  "the donor command returns 255 (connection dropped): the ping check decides, exit 0" 0 "$rc"
assert_has "the donor command returns 255: warned" "WARN: the donor command returned 255" "$(co donorrc out)"

# the donor OS address is watched too, when this Live can see it
PIP='sed -i "s/primary_ip=-/primary_ip=10.0.1.77\/24/" "$RUN/donor.inv"; ALIVE=0'
rc=$(crun pip netdown "$PIP")
assert_eq  "primary IP in a local subnet: both addresses pinged" "192.0.2.10 192.0.2.10 192.0.2.10 10.0.1.77 10.0.1.77 10.0.1.77" "$(co pip pings | paste -sd' ' -)"
rc=$(crun pipfar netdown "${PIP/10.0.1.77/172.16.9.9}")
assert_eq  "primary IP in no local subnet: not pinged" "192.0.2.10 192.0.2.10 192.0.2.10" "$(co pipfar pings | paste -sd' ' -)"
assert_has "primary IP in no local subnet: says so" "the donor OS address 172.16.9.9 is in no subnet of this Live" "$(co pipfar out)"
rc=$(crun pipalive netdown "$PIP; co_ping() { echo \"\$1\" >> \"\$RUN/pings\"; [ \"\$1\" = 10.0.1.77 ]; }")
assert_eq  "primary IP still answers: exit 1" 1 "$rc"
assert_has "primary IP still answers: named" "donor still answers on 10.0.1.77" "$(co pipalive out | tail -1)"
assert_eq  "primary IP still answers: never boots" "" "$(co pipalive boot.cmd)"

# no donor connection: reconnect_donor when the driver provides it, else refuse
rc=$(crun reconnect netdown 'DONOR_HOST=; ALIVE=0; reconnect_donor() { echo reconnect >> "$RUN/calls"; DONOR_HOST=192.0.2.44; }')
assert_eq  "no connection: reconnect_donor is called" "reconnect,disconnect" "$(co reconnect calls | paste -sd, -)"
assert_eq  "no connection: the reconnected host is watched" "192.0.2.44" "$(co reconnect pings | sort -u)"
rc=$(crun noconnect netdown 'DONOR_HOST=; unset -f reconnect_donor')
assert_eq  "no connection, no reconnect_donor: exit 2" 2 "$rc"
assert_eq  "no connection, no reconnect_donor: nothing done" "" "$(co noconnect donor.cmd)$(co noconnect boot.cmd)"

# kexec: what verify resolved is what boots; the images leave the target before anything is switched
rc=$(crun kexec kexec)
assert_eq  "cutover kexec: exit 0" 0 "$rc"
assert_eq  "cutover kexec: mount ro, umount, then the donor" "mount ro,umount,disconnect" "$(co kexec calls | paste -sd, -)"
assert_eq  "cutover kexec: the donor's NICs go down (same as netdown)" "$NETDOWN" "$(co kexec donor.cmd)"
assert_eq  "cutover kexec: kexec -l with the verified kernel, initrd, cmdline, then systemctl kexec" \
	"kexec -s -l $W/kexec.co/kexec/vmlinuz-$KVER --initrd=$W/kexec.co/kexec/initrd.img-$KVER --command-line=$CMDLINE|systemctl kexec" "$(co kexec boot.cmd | paste -sd'|' -)"
assert_ok  "cutover kexec: kernel copied to tmpfs" test -f "$W/kexec.co/kexec/vmlinuz-$KVER"
assert_ok  "cutover kexec: initrd copied to tmpfs" test -f "$W/kexec.co/kexec/initrd.img-$KVER"
assert_eq  "cutover kexec: state mode" "kexec" "$(cst kexec cutover.mode)"
rc=$(crun kexecfallback kexec 'ALIVE=0; co_boot() { echo "$1 $2" >> "$RUN/boot.cmd"; case "$1 $2" in "kexec -s"|"systemctl kexec") return 1;; esac; }')
assert_eq  "kexec -s refused, systemctl kexec fails: kexec -c, then kexec -e" "kexec -s,kexec -c,systemctl kexec,kexec -e" "$(co kexecfallback boot.cmd | paste -sd, -)"
rc=$(crun kexecnoload kexec 'ALIVE=0; co_boot() { echo "$1 $2" >> "$RUN/boot.cmd"; return 1; }')
assert_eq  "kexec cannot load at all: exit 1" 1 "$rc"
assert_has "kexec cannot load at all: tells how to boot instead" "boot this box through the firmware instead (systemctl reboot)" "$(co kexecnoload out | tail -1)"
rc=$(crun kexecnostate kexec 'state_set verify.kernel ""')
assert_eq  "kexec without a verified entry: exit 2" 2 "$rc"
assert_eq  "kexec without a verified entry: before the donor is touched" "" "$(co kexecnostate donor.cmd)"
rc=$(crun kexecgone kexec 'target_mount() { TARGET_MNT=$W/nosuch; }')
assert_eq  "kexec, the kernel is not on the target any more: exit 1" 1 "$rc"
assert_eq  "kexec, the kernel is gone: before the donor is touched" "" "$(co kexecgone donor.cmd)"
rc=$(crun kexecalive kexec 'ALIVE=99')
assert_eq  "kexec, the donor keeps answering: exit 1, nothing loaded" "1:" "$rc:$(co kexecalive boot.cmd)"

# dry run: every step printed, none taken
rc=$(crun dry kexec 'DRY=y')
assert_eq  "cutover -n: exit 0" 0 "$rc"
assert_eq  "cutover -n: no seam is reached" "" "$(co dry donor.cmd)$(co dry boot.cmd)$(co dry pings)$(co dry calls)"
assert_has "cutover -n: the donor command" "(dry) donor: $NETDOWN" "$(co dry out)"
assert_has "cutover -n: the ping check" "(dry) would ping 192.0.2.10 until 3 pings in a row go unanswered" "$(co dry out)"
assert_has "cutover -n: kexec -l" "(dry) kexec -s -l $W/dry.co/kexec/vmlinuz-$KVER --initrd=$W/dry.co/kexec/initrd.img-$KVER --command-line=" "$(co dry out)"
assert_has "cutover -n: systemctl kexec" "(dry) systemctl kexec" "$(co dry out)"
assert_eq  "cutover -n: no state" "" "$(cst dry cutover.mode)"
assert_fail "cutover -n: nothing copied" test -e "$W/dry.co/kexec"
rc=$(crun drynotverified netdown 'DRY=y; state_set phase.verify failed; DONOR_HOST=; state_set donor.target root@192.0.2.10:22')
assert_eq  "cutover -n, not verified, not connected: still walks the steps" 0 "$rc"
assert_has "cutover -n, not verified: says a real run refuses" "(dry) verify is not marked done here: a real cutover refuses" "$(co drynotverified out)"
assert_has "cutover -n, not connected: would reconnect" "(dry) would reconnect to the donor 192.0.2.10" "$(co drynotverified out)"
assert_has "cutover -n: reboot" "(dry) systemctl reboot" "$(co drynotverified out)"
t_end
