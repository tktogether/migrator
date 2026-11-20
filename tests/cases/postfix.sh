#!/bin/bash
# tests/cases/postfix.sh — lib/postfix.sh without a chroot, a mount or a device:
# the pure rewriters on recorded files (the REAL Debian 11 tree the stand captured,
# tests/fixtures/raw/fstab.txt, the fixture plans' [identity]), the pf_apply/pf_new/
# pf_remove contract (diff, backup once, same inode, -n writes nothing, nothing
# outside the target), and postfix_run ROOT end to end over a throwaway copy of the
# captured tree with real fixture plans: the chroot entry points are replaced by
# recorders, grub-install/efibootmgr/dd/mkswap by shims first on PATH (chroot,
# mount and umount shims only prove they were never called). Covers bios (stand
# plan), /dev/md0 -> UUID (debian-md-ext4-bios), uefi -> bios with the Live's grub
# (ubuntu-nvme-uefi-to-bios-vm), a crafted uefi -> uefi plan with and without a
# UEFI-booted Live, idempotence, -n, rhel (BLS/grubenv/dracut/grub2/autorelabel), the dry outline,
# and postfix_record. Everything that can die runs in a subshell.
# shellcheck disable=SC2016,SC2030,SC2031,SC2317  # snippets handed to eval keep their $s; RUN/PATH/DRY change in subshells on purpose; helpers are called through assert_*
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO/lib/plan.sh"
# shellcheck source=lib/target.sh
. "$REPO/lib/target.sh"
# shellcheck source=lib/postfix.sh
. "$REPO/lib/postfix.sh"
# shellcheck source=lib/netfix.sh
. "$REPO/lib/netfix.sh"
FIX=$REPO/tests/fixtures
TREE=$FIX/stand-debian-md-ext4-bios/raw/tree
MIGRATOR_LIB=$REPO/lib; export MIGRATOR_LIB
W=$RUN/pf-work; mkdir -p "$W"
TAB=$(printf '\t')

# --- (a) contract, silent sourcing ---------------------------------------------------------
for fn in postfix_run postfix_record pf_apply pf_new pf_remove pf_followups pf_is_uefi_live \
          pf_fstab_rewrite pf_mdadm_conf_rewrite pf_cmdline_rewrite pf_grub_default_rewrite pf_lvm_conf_rewrite \
          pf_modules_rewrite pf_initramfs_conf_rewrite pf_resume_rewrite pf_efi_labelled pf_efi_order_new \
          pf_step_fstab pf_step_mdadm pf_step_cmdline pf_step_lvm pf_step_network pf_step_initramfs \
          pf_step_bootloader pf_step_swapfiles pf_step_cloudinit pf_step_sysctl; do
	if declare -F "$fn" >/dev/null; then _pass "defines $fn"; else _fail "defines $fn" "missing"; fi
done
out=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; . "$1/lib/target.sh"; . "$1/lib/postfix.sh"; . "$1/lib/netfix.sh"' _ "$REPO" 2>&1); rc=$?
assert_eq "postfix.sh sources cleanly"     0  "$rc"
assert_eq "postfix.sh is silent on source" "" "$out"

# --- shims: nothing of this host is ever touched ---------------------------------------------
# first on PATH; each logs its argv to $SHIM_LOG. chroot/mount/umount must never run at all.
SHIM=$W/shim; mkdir -p "$SHIM"
for b in grub-install mkswap update-grub update-initramfs; do
	printf '#!/bin/bash\necho "%s $*" >> "$SHIM_LOG"\necho "live: %s $*" >> "$SEQ_LOG"\n' "$b" "$b" > "$SHIM/$b"
done
for b in chroot mount umount; do
	printf '#!/bin/bash\necho "UNEXPECTED %s $*" >> "$SHIM_LOG"\nexit 1\n' "$b" > "$SHIM/$b"
done
cat > "$SHIM/dd" <<'EOF'
#!/bin/bash
# logs, and makes the (sparse) file the real dd would have written
echo "dd $*" >> "$SHIM_LOG"
of=; count=0
for a in "$@"; do case $a in of=*) of=${a#of=};; count=*) count=${a#count=};; esac; done
[ -n "$of" ] && truncate -s "$((count * 1048576))" "$of"
EOF
cat > "$SHIM/efibootmgr" <<'EOF'
#!/bin/bash
# a firmware in a file: $EFI_STATE holds what "efibootmgr" prints
echo "efibootmgr $*" >> "$SHIM_LOG"
[ -r "$EFI_STATE" ] || exit 2
order=$(sed -n 's/^BootOrder: //p' "$EFI_STATE")
setorder() { sed -i "s/^BootOrder: .*/BootOrder: $1/" "$EFI_STATE"; }
case "$1" in
	'') ;;
	-b) sed -i "/^Boot$2/d" "$EFI_STATE"; setorder "$(echo "$order" | tr ',' '\n' | grep -vx "$2" | paste -sd, -)" ;;
	-c) label=; while [ $# -gt 0 ]; do [ "$1" = -L ] && label=$2; shift; done
	    printf 'Boot0004* %s\n' "$label" >> "$EFI_STATE"; setorder "0004,$order" ;;
	-o) setorder "$2" ;;
esac
cat "$EFI_STATE"
EOF
chmod +x "$SHIM"/*
export PATH="$SHIM:$PATH"
assert_eq "shims come first on PATH" "$SHIM/grub-install $SHIM/chroot $SHIM/dd" "$(command -v grub-install) $(command -v chroot) $(command -v dd)"

# the chroot entry points of lib/target.sh, replaced by recorders
# dnf/yum in the recorder: DNF_FAIL=1 makes it fail, DNF_MAKES_EFI=<vendor> makes it drop the
# loaders of shim-x64 + grub2-efi-x64 onto the ESP the way the packages do, and what it
# "installed" answers rpm -q afterwards (RPM_INSTALLED); NO_DNF=1 is a CentOS 7 (yum only)
target_chroot() {
	echo "chroot: $*" >> "$RUN/chroot.log"; echo "chroot: $*" >> "$RUN/seq.log"
	case "$*" in
		update-grub) [ -f "$TARGET_MNT/etc/default/grub.d/99-migrator-osprober.cfg" ] && echo "note: os-prober is off during update-grub" >> "$RUN/chroot.log";;
		"dnf -y --setopt=install_weak_deps=False install "*|"yum -y install "*)
			[ -z "${DNF_FAIL:-}" ] || return 1
			if [ -n "${DNF_MAKES_EFI:-}" ]; then
				mkdir -p "$TARGET_MNT/boot/efi/EFI/$DNF_MAKES_EFI" "$TARGET_MNT/boot/efi/EFI/BOOT"
				: > "$TARGET_MNT/boot/efi/EFI/$DNF_MAKES_EFI/shimx64.efi"; : > "$TARGET_MNT/boot/efi/EFI/$DNF_MAKES_EFI/grubx64.efi"; : > "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
			fi
			RPM_INSTALLED="${RPM_INSTALLED:-} ${*#* install }";;
	esac
	[ -z "$DRY" ] || echo "(dry) chroot $*"
	return 0
}
target_chroot_sh() { echo "chroot-sh: $1" >> "$RUN/chroot.log"; [ -z "$DRY" ] || echo "(dry) chroot sh -c $1"; return 0; }
target_chroot_q()  {
	echo "chroot-q: $*" >> "$RUN/chroot.log"
	case "$*" in
		"rpm -q "*) case " ${RPM_INSTALLED:-} " in *" $3 "*) return 0;; *) return 1;; esac;;
		"sh -c command -v dnf") [ -z "${NO_DNF:-}" ]; return $?;;
	esac
	return 0
}
# the UUID of the filesystem under the target's /boot (a stub grub.cfg on a new ESP names it)
pf_fs_uuid_of() { echo b0070000-0000-4000-8000-0000000000c9; }
target_mount()  { echo "UNEXPECTED target_mount $*" >> "$RUN/chroot.log"; return 1; }
target_umount() { echo "UNEXPECTED target_umount" >> "$RUN/chroot.log"; return 0; }
pf_chroot_ready() { return 0; }
pf_is_uefi_live() { return 1; }
pf_live_grub_ready() { return 0; }

# --- helpers -----------------------------------------------------------------------------------
# mk DIR CASE: a state dir with the fixture's plan and inventories, and a throwaway target
# tree at DIR/t (the captured Debian 11 tree + the directories a real root has); DIR/pristine
# keeps the tree as it was
mk() {
	local d=$1 c=$2
	rm -rf "$d"; mkdir -p "$d"
	cp "$FIX/$c/expected.plan" "$d/plan"; cp "$FIX/$c/donor.inv" "$FIX/$c/recipient.inv" "$d/"
	cp -a "$TREE" "$d/t"
	mkdir -p "$d/t/boot/grub" "$d/t/var/lib" "$d/t/root" "$d/t/etc/udev/rules.d" "$d/t/etc/sysctl.d" "$d/t/etc/iptables"
	sed -i 's/^MODULES=most/MODULES=dep/' "$d/t/etc/initramfs-tools/initramfs.conf"
	printf '(hd0)\t/dev/sda\n(hd1)\t/dev/sdb\n' > "$d/t/boot/grub/device.map"
	printf '*filter\n-A INPUT -i ens3 -p tcp --dport 22 -j ACCEPT\nCOMMIT\n' > "$d/t/etc/iptables/rules.v4"
	cp -a "$d/t" "$d/pristine"
}
# pfrun DIR [SNIPPET]: postfix_run DIR/t in a subshell with RUN=DIR (SNIPPET eval'd first);
# stdout+stderr -> DIR/out, status echoed
# (the EXIT trap is set as the driver has it: a subshell does not inherit common.sh's)
pfrun() {
	(
		trap run_cleanup EXIT
		RUN=$1; SHIM_LOG=$1/live.log; SEQ_LOG=$1/seq.log; export SHIM_LOG SEQ_LOG
		: > "$1/chroot.log"; : > "$1/live.log"; : > "$1/seq.log"
		eval "${2:-}"
		postfix_run "$1/t"
	) > "$1/out" 2>&1
	echo $?
}
# changed DIR: every file that differs between DIR/pristine and DIR/t (our own bookkeeping apart)
changed() {
	( cd "$1" && { cd pristine && find . -type f; cd ../t && find . -type f; } | sort -u | grep -v '^\./var/lib/migrator\.to/' | while IFS= read -r f; do
		cmp -s "pristine/$f" "t/$f" || echo "${f#./}"
	done | xargs )
}
# treesum DIR: content, size and mtime of every file of the tree
treesum() { ( cd "$1" && { find . -type f -print0 | sort -z | xargs -0 sha256sum; find . \( -type f -o -type l \) -printf '%p %s %T@\n' | sort; } | sha256sum | cut -c1-64 ); }
in_order() {   # NAME FILE PATTERN...: every pattern appears (fixed string), each after the previous one
	local name=$1 f=$2 pat last=0 n; shift 2
	for pat in "$@"; do
		n=$(awk -v p="$pat" -v s="$last" 'NR > s && index($0, p) { print NR; exit }' "$f")
		[ -n "$n" ] || { _fail "$name" "'$pat' not found after line $last"; return 0; }
		last=$n
	done
	_pass "$name"
}
ident() { plan_section "$FIX/$1/expected.plan" identity > "$W/ident.$1"; echo "$W/ident.$1"; }

# --- (b) pure: fstab -----------------------------------------------------------------------------
I=$(ident stand-debian-md-ext4-bios)
assert_eq "fstab: stand plan (every UUID keep) changes nothing" "$(cat "$TREE/etc/fstab")" "$(pf_fstab_rewrite "$I" < "$TREE/etc/fstab")"
I=$(ident debian-md-ext4-bios)
cat > "$W/fstab.md" <<'EOF'
# /etc/fstab of web1
UUID=0d9e8f7a-2222-4b1c-8a3d-5e6f7a8b9c01 /     ext4 errors=remount-ro 0 1
/dev/md0   /boot   ext4	defaults   0 2
UUID=3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02 none swap sw 0 0
EOF
pf_fstab_rewrite "$I" < "$W/fstab.md" > "$W/fstab.md.out"
assert_eq "fstab: /dev/md0 -> UUID=, the rest of the line and its spacing kept" \
	"UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50   /boot   ext4${TAB}defaults   0 2" "$(sed -n 3p "$W/fstab.md.out")"
assert_eq "fstab: nothing else changed" "3c3" "$(diff "$W/fstab.md" "$W/fstab.md.out" | grep '^[0-9]')"
printf '%s\n' "/dev/md0${TAB}-> UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50" "LABEL=DATA${TAB}remove" "/dev/mapper/centos-root${TAB}keep" \
	"UUID=A1B2-C3D4${TAB}+ /boot/efi vfat umask=0077 0 1" "UUID=FFFF-0000${TAB}+ /boot vfat defaults 0 2" > "$W/ident.mix"
pf_fstab_rewrite "$W/ident.mix" < "$FIX/raw/fstab.txt" > "$W/fstab.mix.out"
assert_has "fstab: a removed entry is commented out with its original line" \
	"# migrator: removed (no target): LABEL=DATA              /data                   ext4    defaults,nofail 0 2" "$(cat "$W/fstab.mix.out")"
assert_eq "fstab: /dev/md0 /srv rewritten in place" "UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50                /srv                    ext4    defaults        1 2" "$(grep ' /srv ' "$W/fstab.mix.out")"
assert_eq "fstab: unknown specs and comments untouched" "$(grep -v -e '^LABEL=DATA' -e '^/dev/md0' "$FIX/raw/fstab.txt")" "$(grep -v -e 'LABEL=DATA' -e ' /srv ' "$W/fstab.mix.out")"
assert_eq "fstab: '+' entry is not added when the mount point is taken (/boot/efi, /boot)" "0" "$(grep -c -e '^UUID=A1B2-C3D4' -e '^UUID=FFFF-0000' "$W/fstab.mix.out")"
printf '%s\n' "UUID=A1B2-C3D4${TAB}+ /boot/efi vfat umask=0077 0 1" > "$W/ident.add"
pf_fstab_rewrite "$W/ident.add" < "$TREE/etc/fstab" > "$W/fstab.add.out"
assert_eq "fstab: '+' entry appended" "UUID=A1B2-C3D4 /boot/efi vfat umask=0077 0 1" "$(tail -1 "$W/fstab.add.out")"
assert_eq "fstab: '+' entry appended once (second pass adds nothing)" "1" "$(pf_fstab_rewrite "$W/ident.add" < "$W/fstab.add.out" | grep -c '/boot/efi')"
assert_eq "fstab: rewriting twice equals rewriting once" "$(cat "$W/fstab.mix.out")" "$(pf_fstab_rewrite "$W/ident.mix" < "$W/fstab.mix.out")"
assert_eq "fstab: no identity file, no change" "$(cat "$FIX/raw/fstab.txt")" "$(pf_fstab_rewrite "" < "$FIX/raw/fstab.txt")"
printf '%s\n' "UUID=aaa${TAB}-> UUID=bbb" "resume=UUID=ccc${TAB}remove" "resume=/dev/sda2${TAB}-> resume=UUID=ddd" > "$W/ident.res"
assert_eq "resume: spec follows the fstab row"      "RESUME=UUID=bbb" "$(echo 'RESUME=UUID=aaa' | pf_resume_rewrite "$W/ident.res")"
assert_eq "resume: follows the resume= token"      "RESUME=UUID=ddd" "$(echo 'RESUME=/dev/sda2' | pf_resume_rewrite "$W/ident.res")"
assert_eq "resume: a swap that did not move"        "RESUME=none"     "$(echo 'RESUME=UUID=ccc' | pf_resume_rewrite "$W/ident.res")"
assert_eq "resume: anything else untouched"         "RESUME=auto"     "$(echo 'RESUME=auto' | pf_resume_rewrite "$W/ident.res")"

# --- (c) pure: mdadm.conf, lvm.conf ------------------------------------------------------------------
pf_mdadm_conf_rewrite "" < "$TREE/etc/mdadm/mdadm.conf" > "$W/mdadm.out"
assert_eq "mdadm: no active ARRAY line left" "0" "$(grep -c '^ARRAY' "$W/mdadm.out")"
assert_eq "mdadm: both ARRAY lines commented, text kept" \
	"# migrator: ARRAY /dev/md0 metadata=1.2 UUID=21422b8e:6e58604b:368cc1d7:0699304b|# migrator: ARRAY /dev/md1 metadata=1.2 UUID=af3c7edd:88ed4780:b9ebe855:da9d6a1a" \
	"$(grep '^# migrator: ARRAY' "$W/mdadm.out" | paste -sd'|' -)"
assert_eq "mdadm: other lines intact" "$(grep -v '^ARRAY' "$TREE/etc/mdadm/mdadm.conf")" "$(grep -v '^# migrator: ARRAY' "$W/mdadm.out")"
assert_eq "mdadm: idempotent" "$(cat "$W/mdadm.out")" "$(pf_mdadm_conf_rewrite "" < "$W/mdadm.out")"
assert_eq "lvm.conf: the stock file (every filter commented) is untouched" "$(sha256sum < "$TREE/etc/lvm/lvm.conf")" "$(pf_lvm_conf_rewrite < "$TREE/etc/lvm/lvm.conf" | sha256sum)"
printf 'devices {\n\tfilter = [ "a|^/dev/md.*|", "r|.*|" ]\n\tglobal_filter = [ "a|x|",\n\t\t"r|.*|" ]\n\t# filter = [ "a|.*|" ]\n\tobtain_device_list_from_udev = 1\n}\n' > "$W/lvm.in"
pf_lvm_conf_rewrite < "$W/lvm.in" > "$W/lvm.out"
assert_eq "lvm.conf: active filter and (multi-line) global_filter commented, indentation kept" \
	"${TAB}# migrator: filter = [ \"a|^/dev/md.*|\", \"r|.*|\" ]|${TAB}# migrator: global_filter = [ \"a|x|\",|${TAB}${TAB}# migrator: \"r|.*|\" ]" \
	"$(grep 'migrator' "$W/lvm.out" | paste -sd'|' -)"
assert_eq "lvm.conf: the rest intact" "$(grep -v 'filter = \|"r|' "$W/lvm.in"; echo; grep '# filter' "$W/lvm.in")" "$(grep -v 'migrator' "$W/lvm.out" | grep -v '# filter'; echo; grep '# filter' "$W/lvm.out")"
assert_eq "lvm.conf: idempotent" "$(cat "$W/lvm.out")" "$(pf_lvm_conf_rewrite < "$W/lvm.out")"

# --- (d) pure: kernel command line ----------------------------------------------------------------------
NET='net.ifnames=0 biosdevname=0'
I=$(ident centos7-md-lvm-xfs-bios)
C7='rd.md.uuid=9b8a7c6d:5e4f3a2b:1c0d9e8f:7a6b5c4d rd.md.uuid=2e3f4a5b:6c7d8e9f:0a1b2c3d:4e5f6a7b rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet'
assert_eq "cmdline: a CentOS line loses only its rd.md tokens" "rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet" "$(pf_cmdline_rewrite "$C7" strip "$I" "" "")"
assert_eq "cmdline: ... and gains the network tokens" "rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet $NET" "$(pf_cmdline_rewrite "$C7" full "$I" "$NET" "")"
assert_eq "cmdline: rd.md=/rd.md.conf= go even when the table does not list them" "ro quiet" "$(pf_cmdline_rewrite 'ro rd.md=0 rd.md.conf=1 rd.md.uuid=xx quiet' strip /dev/null "" "")"
printf '%s\n' "root=/dev/md1${TAB}-> root=UUID=aaa" "resume=/dev/sdb9${TAB}remove" "/dev/md3${TAB}-> UUID=ccc" "rd.md.uuid=keepme${TAB}keep" > "$W/ident.cmd"
assert_eq "cmdline: root= by the table, resume= removed, spacing of the rest kept" "root=UUID=aaa ro  quiet" "$(pf_cmdline_rewrite 'root=/dev/md1 ro  quiet resume=/dev/sdb9' strip "$W/ident.cmd" "" "")"
assert_eq "cmdline: resume=<spec> follows the spec's fstab row" "resume=UUID=ccc" "$(pf_cmdline_rewrite 'resume=/dev/md3' strip "$W/ident.cmd" "" "")"
assert_eq "cmdline: an explicit keep in the table wins" "rd.md.uuid=keepme" "$(pf_cmdline_rewrite 'rd.md.uuid=keepme' strip "$W/ident.cmd" "" "")"
assert_eq "cmdline: conflicting net.ifnames=1 replaced" "quiet $NET" "$(pf_cmdline_rewrite 'net.ifnames=1 quiet biosdevname=1' full /dev/null "$NET" "")"
assert_eq "cmdline: strip drops the conflict and adds nothing" "quiet" "$(pf_cmdline_rewrite 'quiet net.ifnames=1' strip /dev/null "$NET" "")"
assert_eq "cmdline: tokens already there are not doubled" "biosdevname=0 quiet net.ifnames=0" "$(pf_cmdline_rewrite 'biosdevname=0 quiet net.ifnames=0' full /dev/null "$NET" "")"
assert_eq "cmdline: console= appended when absent" "quiet $NET console=ttyS1,57600" "$(pf_cmdline_rewrite 'quiet' full /dev/null "$NET" "ttyS1,57600")"
assert_eq "cmdline: console= not doubled" "console=ttyS0,115200 $NET" "$(pf_cmdline_rewrite 'console=ttyS0,115200' full /dev/null "$NET" "ttyS0,115200")"
assert_eq "cmdline: an empty line gets the tokens" "$NET" "$(pf_cmdline_rewrite '' full /dev/null "$NET" "")"
assert_eq "cmdline: an untouched line comes back byte for byte" "  a   b " "$(pf_cmdline_rewrite '  a   b ' strip /dev/null "" "")"
assert_eq "cmdline: a shell variable in the value is just a token" "\$GRUB_CMDLINE_LINUX_DEFAULT quiet" "$(pf_cmdline_rewrite '$GRUB_CMDLINE_LINUX_DEFAULT quiet' strip /dev/null "$NET" "")"

# /etc/default/grub of the captured tree; the context the driver sets
PF_IDENT=$(ident stand-debian-md-ext4-bios); PF_ADD=$NET; PF_CONSOLE=
pf_grub_default_rewrite main < "$TREE/etc/default/grub" > "$W/grub.out"
assert_eq "grub: GRUB_CMDLINE_LINUX gained the tokens, kept its consoles and quotes" \
	'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0"' "$(grep '^GRUB_CMDLINE_LINUX=' "$W/grub.out")"
assert_eq "grub: GRUB_CMDLINE_LINUX_DEFAULT untouched" 'GRUB_CMDLINE_LINUX_DEFAULT=""' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$W/grub.out")"
assert_eq "grub: exactly one line changed" "1" "$(diff "$TREE/etc/default/grub" "$W/grub.out" | grep -c '^>')"
assert_eq "grub: idempotent" "$(cat "$W/grub.out")" "$(pf_grub_default_rewrite main < "$W/grub.out")"
PF_IDENT=$W/ident.cmd
printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT='quiet net.ifnames=1 rd.md.uuid=1:2'" 'GRUB_CMDLINE_LINUX=root=/dev/md1' 'GRUB_FORCE_PARTUUID=abcd0123-01' \
	'export GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=ttyS0"   # appended' 'GRUB_CMDLINE_LINUX="broken' > "$W/grub.in"
pf_grub_default_rewrite dropin keep "432b9631-01 432b9631-02" < "$W/grub.in" > "$W/grub.dropin"
assert_eq "grub: single quotes kept, _DEFAULT only stripped (identity applies to both)" "GRUB_CMDLINE_LINUX_DEFAULT='quiet'" "$(sed -n 1p "$W/grub.dropin")"
assert_eq "grub: an unquoted value gets quotes when it grows" 'GRUB_CMDLINE_LINUX="root=UUID=aaa net.ifnames=0 biosdevname=0"' "$(sed -n 2p "$W/grub.dropin")"
assert_eq "grub: GRUB_FORCE_PARTUUID that is no partition of the target is commented out" '# migrator: GRUB_FORCE_PARTUUID=abcd0123-01' "$(sed -n 3p "$W/grub.dropin")"
assert_eq "grub: a dropin appending to \$GRUB_CMDLINE_LINUX inherits the tokens, comment kept" 'export GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=ttyS0"   # appended' "$(sed -n 4p "$W/grub.dropin")"
assert_eq "grub: a value that does not end on its line is left alone" 'GRUB_CMDLINE_LINUX="broken' "$(sed -n 5p "$W/grub.dropin")"
assert_eq "grub: GRUB_FORCE_PARTUUID of the target stays" 'GRUB_FORCE_PARTUUID=432B9631-02' "$(echo 'GRUB_FORCE_PARTUUID=432B9631-02' | pf_grub_default_rewrite dropin keep "432b9631-01 432b9631-02")"
assert_eq "grub: ... unless the plan rewrote a PARTUUID" '# migrator: GRUB_FORCE_PARTUUID=432B9631-02' "$(echo 'GRUB_FORCE_PARTUUID=432B9631-02' | pf_grub_default_rewrite dropin comment "432b9631-01 432b9631-02")"
PF_IDENT=/dev/null
assert_eq "grub: main without the variable gains it" "GRUB_TIMEOUT=1|GRUB_CMDLINE_LINUX=\"$NET\"" "$(echo 'GRUB_TIMEOUT=1' | pf_grub_default_rewrite main | paste -sd'|' -)"
assert_eq "grub: a dropin without the variable does not" "GRUB_TIMEOUT=1" "$(echo 'GRUB_TIMEOUT=1' | pf_grub_default_rewrite dropin)"
assert_eq "kernel/cmdline: the file is the command line" "root=UUID=x ro $NET" "$(echo 'root=UUID=x ro' | pf_kernel_cmdline_rewrite)"
( PF_PLAN=$FIX/stand-debian-md-ext4-bios/expected.plan; pf_target_partuuids ) > "$W/pu.dos"
assert_eq "partuuids of a dos target: <label-id>-NN" "432b9631-01 432b9631-02 432b9631-03 432b9631-04" "$(xargs < "$W/pu.dos")"
( PF_PLAN=$FIX/ubuntu-nvme-uefi-to-bios-vm/expected.plan; pf_target_partuuids ) > "$W/pu.gpt"
assert_has "partuuids of a gpt target: the uuid= of every partition" "11111111-aaaa-4bbb-8ccc-000000000003" "$(cat "$W/pu.gpt")"
printf '%s\n' "PARTUUID=abc-03${TAB}-> UUID=x" > "$W/ident.pu"
pu_changed() { ( PF_IDENT=$1; pf_partuuid_changed ); }
assert_ok   "partuuid_changed: a rewritten PARTUUID= spec"  pu_changed "$W/ident.pu"
assert_fail "partuuid_changed: not for the stand plan"      pu_changed "$(ident stand-debian-md-ext4-bios)"

# --- (e) pure: initramfs-tools ------------------------------------------------------------------------------
pf_modules_rewrite virtio_blk,virtio_pci,virtio_net < "$TREE/etc/initramfs-tools/modules" > "$W/modules.out"
assert_eq "modules: header + one line per driver appended" "# migrator: storage/network drivers of the recipient|virtio_blk|virtio_pci|virtio_net" "$(tail -4 "$W/modules.out" | paste -sd'|' -)"
assert_eq "modules: the original lines stay" "$(cat "$TREE/etc/initramfs-tools/modules")" "$(head -n -4 "$W/modules.out")"
assert_eq "modules: idempotent" "$(cat "$W/modules.out")" "$(pf_modules_rewrite virtio_blk,virtio_pci,virtio_net < "$W/modules.out")"
assert_eq "modules: virtio-blk already listed counts as virtio_blk" "virtio-blk|# migrator: storage/network drivers of the recipient|virtio_pci" "$(echo 'virtio-blk' | pf_modules_rewrite virtio_blk,virtio_pci | paste -sd'|' -)"
assert_eq "modules: driver=- adds nothing" "raid1" "$(echo 'raid1' | pf_modules_rewrite -)"
assert_eq "initramfs.conf: MODULES=dep -> most (quoted too), others untouched" "MODULES=most|MODULES=\"most\" # x|MODULES=list|BUSYBOX=auto" "$(printf 'MODULES=dep\nMODULES="dep" # x\nMODULES=list\nBUSYBOX=auto\n' | pf_initramfs_conf_rewrite | paste -sd'|' -)"

# --- (f) pure: efibootmgr parsers -----------------------------------------------------------------------------
printf 'BootCurrent: 0003\nTimeout: 1 seconds\nBootOrder: 0003,0001,0000,0002\nBoot0000* Debian GNU/Linux 11 (bullseye)\tHD(1,GPT,x)/File(\\EFI\\debian\\shimx64.efi)\nBoot0001* UEFI: PXE IPv4 Intel(R) I350\nBoot0002  EFI Shell\nBoot0003* UEFI PXEv4 (MAC:525400123456)\nBoot000A* Debian GNU/Linux 11 (bullseye) old\n' > "$W/efi.txt"
assert_eq "efi: entries with exactly this label" "0000" "$(pf_efi_labelled 'Debian GNU/Linux 11 (bullseye)' < "$W/efi.txt" | xargs)"
assert_eq "efi: an inactive entry is found too" "0002" "$(pf_efi_labelled 'EFI Shell' < "$W/efi.txt")"
assert_eq "efi: new entry goes after the leading network entries, deleted ones drop out" "0003,0001,0004,0002" "$(pf_efi_order_new 0004 0000 < "$W/efi.txt")"
assert_eq "efi: no leading network entry -> the new one is first" "0004,0002,0001" "$(printf 'BootOrder: 0002,0001\nBoot0001* UEFI: PXE IPv4\nBoot0002* ubuntu\n' | pf_efi_order_new 0004)"
assert_eq "efi: only network entries -> appended" "0001,0004" "$(printf 'BootOrder: 0001\nBoot0001* EFI Network\n' | pf_efi_order_new 0004)"
assert_eq "efi: no BootOrder -> nothing" "" "$(printf 'Boot0001* x\n' | pf_efi_order_new 0004)"

# --- (g) pf_new / pf_apply / pf_remove ----------------------------------------------------------------------------
A=$W/apply; mkdir -p "$A/t/etc" "$A/run"
(
	RUN=$A/run; TARGET_MNT=$A/t; DRY=
	printf 'one\ntwo\n' > "$A/t/etc/f"; chmod 0600 "$A/t/etc/f"; ino=$(stat -c %i "$A/t/etc/f")
	printf 'one\ntwo\n' | pf_apply /etc/f > "$A/same.out"
	echo "identical: out=[$(cat "$A/same.out")] backup=$([ -e "$A/t/var/lib/migrator/orig/etc/f" ] && echo y || echo n)"
	printf 'one\n2\n' | pf_apply /etc/f > "$A/chg.out"
	echo "changed: content=$(paste -sd, "$A/t/etc/f") inode=$([ "$(stat -c %i "$A/t/etc/f")" = "$ino" ] && echo same || echo new) mode=$(stat -c %a "$A/t/etc/f") backup=$(paste -sd, "$A/t/var/lib/migrator/orig/etc/f") bmode=$(stat -c %a "$A/t/var/lib/migrator/orig/etc/f")"
	printf 'one\n3\n' | pf_apply "$A/t/etc/f" > /dev/null
	echo "again: content=$(paste -sd, "$A/t/etc/f") backup=$(paste -sd, "$A/t/var/lib/migrator/orig/etc/f")"
	printf 'x\n' | pf_new /etc/sub/new.conf 0640 > "$A/new.out"
	echo "new: content=$(cat "$A/t/etc/sub/new.conf") mode=$(stat -c %a "$A/t/etc/sub/new.conf") backup=$([ -e "$A/t/var/lib/migrator/orig/etc/sub/new.conf" ] && echo y || echo n)"
	printf 'y\n' | pf_new /etc/sub/new.conf 0640 > /dev/null
	echo "new-again: content=$(cat "$A/t/etc/sub/new.conf") backup=$([ -e "$A/t/var/lib/migrator/orig/etc/sub/new.conf" ] && echo y || echo n)"
	printf '' | pf_new /etc/empty.conf 0644
	echo "empty-new: $([ -e "$A/t/etc/empty.conf" ] && echo created || echo absent)"
	DRY=y
	printf 'dry\n' | pf_apply /etc/f > "$A/dry.out"; printf 'dry\n' | pf_new /etc/dry.conf 0644 >> "$A/dry.out"; pf_remove /etc/f >> "$A/dry.out"
	echo "dry: content=$(paste -sd, "$A/t/etc/f") new=$([ -e "$A/t/etc/dry.conf" ] && echo created || echo absent)"
	DRY=
	pf_remove /etc/sub/new.conf > /dev/null; pf_remove /etc/f > "$A/rm.out"; pf_remove /etc/nothing
	echo "removed: f=$([ -e "$A/t/etc/f" ] && echo there || echo gone) backup=$(paste -sd, "$A/t/var/lib/migrator/orig/etc/f") created=$([ -e "$A/t/etc/sub/new.conf" ] && echo there || echo gone)"
	# an absolute symlink is followed INSIDE the target; a path leading out of it is refused
	mkdir -p "$A/t/usr/lib" "$A/outside"; echo inner > "$A/t/usr/lib/real.conf"; ln -s /usr/lib/real.conf "$A/t/etc/link.conf"
	echo changed | pf_apply /etc/link.conf > /dev/null
	echo "symlink: target=$(cat "$A/t/usr/lib/real.conf") still-link=$([ -L "$A/t/etc/link.conf" ] && echo y || echo n) backup=$(cat "$A/t/var/lib/migrator/orig/usr/lib/real.conf")"
	echo keep > "$A/outside/x"; ln -s "../../outside" "$A/t/etc/out"
	echo evil | pf_apply /etc/out/x > "$A/esc.out" 2>&1
	echo "escape: outside=$(cat "$A/outside/x")"
	_pf_edit /etc/link.conf false > "$A/edit.out" 2>&1
	echo "failed-rewriter: target=$(cat "$A/t/usr/lib/real.conf")"
	_pf_edit /etc/link.conf true > "$A/edit2.out" 2>&1
	echo "emptying-rewriter: target=$(cat "$A/t/usr/lib/real.conf")"
) > "$A/result" 2>&1
assert_has "pf_apply: identical content is a no-op (no diff, no backup)" "identical: out=[] backup=n" "$(cat "$A/result")"
assert_has "pf_apply: written in place (same inode, mode kept), original backed up with its mode" "changed: content=one,2 inode=same mode=600 backup=one,two bmode=600" "$(cat "$A/result")"
assert_has "pf_apply: prints a unified diff labelled with the in-target path" "--- a/etc/f" "$(cat "$A/chg.out")"
assert_has "pf_apply: diff hunk"                     "+2"                "$(cat "$A/chg.out")"
assert_has "pf_apply: the diff is in the log too"    "+++ b/etc/f"       "$(cat "$A/run/log")"
assert_has "pf_apply: a second change never overwrites the backup" "again: content=one,3 backup=one,two" "$(cat "$A/result")"
assert_has "pf_new: a new file gets its mode and no backup" "new: content=x mode=640 backup=n" "$(cat "$A/result")"
assert_has "pf_new: diff of a new file is against /dev/null" "--- /dev/null" "$(cat "$A/new.out")"
assert_has "pf_new: a file we created is never 'backed up' as an original" "new-again: content=y backup=n" "$(cat "$A/result")"
assert_has "pf_new: empty content creates nothing" "empty-new: absent" "$(cat "$A/result")"
assert_has "pf_*: -n prints the diff and writes nothing" "dry: content=one,3 new=absent" "$(cat "$A/result")"
assert_has "pf_apply: -n diff"                       "+dry"              "$(cat "$A/dry.out")"
assert_has "pf_remove: -n says so"                   "(dry) would remove /etc/f" "$(cat "$A/dry.out")"
assert_has "pf_remove: removes, keeps the first original" "removed: f=gone backup=one,two created=gone" "$(cat "$A/result")"
assert_has "pf_apply: an absolute symlink is followed inside the target" "symlink: target=changed still-link=y backup=inner" "$(cat "$A/result")"
assert_has "pf_apply: a path that leaves the target is refused" "escape: outside=keep" "$(cat "$A/result")"
assert_has "pf_apply: ... with a warning" "resolves outside the target" "$(cat "$A/esc.out")"
assert_has "_pf_edit: a failing rewriter leaves the file alone" "failed-rewriter: target=changed" "$(cat "$A/result")"
assert_has "_pf_edit: so does one that returns nothing" "emptying-rewriter: target=changed" "$(cat "$A/result")"

# --- (h) the stand plan, end to end: bios, md -> one disk, ens3 -> eth0 ---------------------------------------------
D=$W/stand; mk "$D" stand-debian-md-ext4-bios
rc=$(pfrun "$D")
assert_eq "stand: postfix_run exits 0" 0 "$rc"
assert_eq "stand: nothing of the host was called (chroot/mount/umount shims, target_mount)" "0" "$(cat "$D/live.log" "$D/chroot.log" | grep -c UNEXPECTED)"
for s in fstab mdadm "kernel cmdline" lvm network initramfs bootloader swapfiles cloud-init sysctl; do
	assert_has "stand: step '$s' announced" "--- $s" "$(cat "$D/out")"
done
in_order "stand: steps run in order" "$D/out" "--- fstab" "--- mdadm" "--- kernel cmdline" "--- lvm" "--- network" "--- initramfs" "--- bootloader" "--- swapfiles" "--- cloud-init" "--- sysctl" "postfix done"
assert_eq "stand: fstab unchanged (every UUID kept)" "$(cat "$TREE/etc/fstab")" "$(cat "$D/t/etc/fstab")"
assert_eq "stand: mdadm.conf has no ARRAY" "0" "$(grep -c '^ARRAY' "$D/t/etc/mdadm/mdadm.conf")"
assert_eq "stand: mdadm.conf keeps the rest" "$(grep -v '^ARRAY' "$TREE/etc/mdadm/mdadm.conf")" "$(grep -v '^# migrator: ARRAY' "$D/t/etc/mdadm/mdadm.conf")"
assert_eq "stand: device.map removed, original kept" "gone (hd0)" "$([ -e "$D/t/boot/grub/device.map" ] && echo there || echo gone) $(head -1 "$D/t/var/lib/migrator/orig/boot/grub/device.map" | cut -f1)"
assert_eq "stand: GRUB_CMDLINE_LINUX" 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0"' "$(grep '^GRUB_CMDLINE_LINUX=' "$D/t/etc/default/grub")"
assert_eq "stand: GRUB_CMDLINE_LINUX_DEFAULT untouched" 'GRUB_CMDLINE_LINUX_DEFAULT=""' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$D/t/etc/default/grub")"
assert_eq "stand: GRUB_DISABLE_OS_PROBER is not written permanently" "0" "$(grep -rl 'GRUB_DISABLE_OS_PROBER' "$D/t/etc" | wc -l)"
assert_eq "stand: grub.d/init-select.cfg untouched" "$(cat "$TREE/etc/default/grub.d/init-select.cfg")" "$(cat "$D/t/etc/default/grub.d/init-select.cfg")"
assert_eq "stand: lvm.conf untouched (lvm_filter=keep)" "$(sha256sum < "$TREE/etc/lvm/lvm.conf")" "$(sha256sum < "$D/t/etc/lvm/lvm.conf")"
assert_eq "stand: initramfs modules once each" "1 1 1" "$(grep -c '^virtio_blk$' "$D/t/etc/initramfs-tools/modules") $(grep -c '^virtio_pci$' "$D/t/etc/initramfs-tools/modules") $(grep -c '^virtio_net$' "$D/t/etc/initramfs-tools/modules")"
assert_eq "stand: MODULES=dep -> most" "MODULES=most" "$(grep '^MODULES=' "$D/t/etc/initramfs-tools/initramfs.conf")"
assert_eq "stand: the exact chroot sequence" \
	"chroot: update-initramfs -u -k all|chroot: grub-install --target=i386-pc --recheck /dev/vda|chroot: update-grub|note: os-prober is off during update-grub|chroot-q: sh -c command -v debconf-set-selections|chroot-q: dpkg-query -W grub-pc|chroot-sh: echo 'grub-pc grub-pc/install_devices multiselect /dev/vda' | debconf-set-selections" \
	"$(paste -sd'|' "$D/chroot.log")"
assert_eq "stand: nothing ran from the Live (no grub-install, dd, efibootmgr)" "" "$(cat "$D/live.log")"
assert_eq "stand: the temporary os-prober cfg is gone" "gone" "$([ -e "$D/t/etc/default/grub.d/99-migrator-osprober.cfg" ] && echo there || echo gone)"
assert_eq "stand: interfaces renamed to eth0" "auto eth0|iface eth0 inet dhcp" "$(grep -E '^(auto|iface) e' "$D/t/etc/network/interfaces" | paste -sd'|' -)"
assert_eq "stand: lo untouched" "auto lo|iface lo inet loopback" "$(grep -E ' lo( |$)' "$D/t/etc/network/interfaces" | paste -sd'|' -)"
assert_eq "stand: udev pin for eth0 at the recipient's MAC" \
	'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="52:54:00:cc:dd:01", ATTR{type}=="1", NAME="eth0"' "$(grep '^SUBSYSTEM' "$D/t/etc/udev/rules.d/70-persistent-net.rules")"
assert_has "stand: netfix summary" "network: ens3 -> eth0 (interfaces), mac -> 52:54:00:cc:dd:01, pin=1 rules" "$(cat "$D/out")"
assert_has "stand: list-only WARN for the iptables file" "WARN: /etc/iptables/rules.v4 mentions ens3" "$(cat "$D/out")"
assert_eq "stand: ... which is never edited" "$(cat "$D/pristine/etc/iptables/rules.v4")" "$(cat "$D/t/etc/iptables/rules.v4")"
assert_eq "stand: sysctl arp_notify" "net.ipv4.conf.all.arp_notify = 1" "$(grep -v '^#' "$D/t/etc/sysctl.d/99-migrator.conf")"
assert_eq "stand: no cloud-init file (cloudinit=keep)" "absent" "$([ -e "$D/t/etc/cloud/cloud.cfg.d/99-migrator.cfg" ] && echo there || echo absent)"
for f in etc/default/grub etc/mdadm/mdadm.conf etc/network/interfaces etc/initramfs-tools/modules etc/initramfs-tools/initramfs.conf boot/grub/device.map; do
	assert_ok "stand: original of /$f kept under var/lib/migrator/orig" cmp -s "$D/pristine/$f" "$D/t/var/lib/migrator/orig/$f"
done
assert_eq "stand: unchanged files have no backup (fstab, lvm.conf)" "absent absent" "$([ -e "$D/t/var/lib/migrator/orig/etc/fstab" ] && echo there || echo absent) $([ -e "$D/t/var/lib/migrator/orig/etc/lvm/lvm.conf" ] && echo there || echo absent)"
assert_eq "stand: files it created are listed, not backed up" "/etc/sysctl.d/99-migrator.conf /etc/udev/rules.d/70-persistent-net.rules" "$(sort "$D/t/var/lib/migrator/created" | xargs)"
assert_eq "stand: every file postfix touched" \
	"boot/grub/device.map etc/default/grub etc/initramfs-tools/initramfs.conf etc/initramfs-tools/modules etc/mdadm/mdadm.conf etc/network/interfaces etc/sysctl.d/99-migrator.conf etc/udev/rules.d/70-persistent-net.rules" \
	"$(changed "$D")"
assert_eq "stand: state: phase.postfix, netfix.done" "done 1" "$(RUN=$D state_get phase.postfix) $(RUN=$D state_get netfix.done)"
assert_has "stand: diffs were printed" "@@" "$(cat "$D/out")"
assert_has "stand: the diff names the in-target path" "+++ b/etc/default/grub" "$(cat "$D/out")"
assert_has "stand: the log carries the diffs" "+GRUB_CMDLINE_LINUX=" "$(cat "$D/log")"

# idempotence: a second run prints no diff and leaves every file (content, size, mtime) alone
before=$(treesum "$D/t"); cp "$D/chroot.log" "$D/chroot.log.1"
rc=$(pfrun "$D")
assert_eq "stand, second run: exits 0" 0 "$rc"
assert_eq "stand, second run: no diff hunks" "0" "$(grep -c '^@@' "$D/out")"
assert_eq "stand, second run: no file changed (sha256, size, mtime of the whole tree)" "$before" "$(treesum "$D/t")"
assert_eq "stand, second run: the same chroot sequence" "$(cat "$D/chroot.log.1")" "$(cat "$D/chroot.log")"
assert_has "stand, second run: says nothing changed" "postfix done: 0 file(s) changed" "$(cat "$D/out")"

# --- (i) -n with ROOT: diffs, (dry) commands, a byte-identical tree ------------------------------------------------------
D=$W/dry; mk "$D" stand-debian-md-ext4-bios
before=$(treesum "$D/t")
rc=$(pfrun "$D" 'DRY=y')
assert_eq "dry: exits 0" 0 "$rc"
assert_eq "dry: the tree is byte-identical" "$before" "$(treesum "$D/t")"
assert_eq "dry: no var/lib/migrator in the tree" "absent" "$([ -e "$D/t/var/lib/migrator" ] && echo there || echo absent)"
assert_eq "dry: diffs printed (grub, mdadm, interfaces, modules, initramfs.conf, udev, sysctl)" "7" "$(grep -c '^@@' "$D/out")"
assert_has "dry: chroot commands shown" "(dry) chroot update-initramfs -u -k all" "$(cat "$D/out")"
assert_has "dry: device.map" "(dry) would remove /boot/grub/device.map" "$(cat "$D/out")"
assert_has "dry: the closing line" "(dry) postfix: 8 file(s) would change, nothing was written" "$(cat "$D/out")"
assert_eq "dry: no phase marker" "" "$(RUN=$D state_get phase.postfix)"

# --- (j) /dev/md0 -> UUID (debian-md-ext4-bios), a by-id disk for debconf, -o console= ---------------------------------------
D=$W/md; mk "$D" debian-md-ext4-bios
cp "$W/fstab.md" "$D/t/etc/fstab"; cp "$W/fstab.md" "$D/pristine/etc/fstab"
sed -i 's/\tbyid=-\t/\tbyid=virtio-XSREC0\t/' "$D/recipient.inv"
mkdir -p "$D/t/etc/initramfs-tools/conf.d"; printf 'RESUME=UUID=3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02\n' > "$D/t/etc/initramfs-tools/conf.d/resume"
rc=$(pfrun "$D" 'OPT[console]=ttyS1,115200')
assert_eq "md: exits 0" 0 "$rc"
assert_eq "md: /boot line's first field rewritten" "UUID=6f1c9e2a-1111-4c3b-9d2e-0a1b2c3d4e50   /boot   ext4${TAB}defaults   0 2" "$(grep '/boot' "$D/t/etc/fstab")"
assert_eq "md: and nothing else in fstab" "1" "$(diff "$D/pristine/etc/fstab" "$D/t/etc/fstab" | grep -c '^>')"
assert_ok "md: fstab original kept" cmp -s "$D/pristine/etc/fstab" "$D/t/var/lib/migrator/orig/etc/fstab"
assert_eq "md: conf.d/resume of a kept swap untouched" "RESUME=UUID=3c4d5e6f-3333-4a2b-9c1d-7e8f9a0b1c02" "$(cat "$D/t/etc/initramfs-tools/conf.d/resume")"
assert_has "md: -o console= appended" "console=tty0 net.ifnames=0 biosdevname=0 console=ttyS1,115200\"" "$(grep '^GRUB_CMDLINE_LINUX=' "$D/t/etc/default/grub")"
assert_has "md: debconf gets the by-id name of the recipient disk" "multiselect /dev/disk/by-id/virtio-XSREC0' | debconf-set-selections" "$(cat "$D/chroot.log")"

# --- (k) rhel: BLS + grubenv, dracut per kernel, grub2-mkconfig into the real cfg, no grub2-install on uefi, autorelabel ----------
# mkenv FILE [key=value...]: a grubenv the way grub2-editenv writes it (1024 bytes, # padding)
mkenv() {
	local f=$1 n; shift
	{ echo "# GRUB Environment Block"; [ $# -eq 0 ] || printf '%s\n' "$@"; } > "$f"
	n=$(wc -c < "$f"); [ "$n" -le 1024 ] || { echo "mkenv: $n bytes do not fit the 1024-byte block" >&2; return 1; }
	head -c $((1024 - n)) /dev/zero | tr '\0' '#' >> "$f"
}
# mkrhel DIR CASE: the captured Debian tree dressed as the fixture's rhel system: BLS entries
# and grubenv, a real /boot/grub2/grub.cfg + an ESP stub, a RHEL /etc/default/grub, the
# donor's network config, modules of its kernels, LVM devices file; Debian-only bits dropped
mkrhel() {
	local d=$1 c=$2 ver
	mk "$d" "$c"
	rm -rf "$d/t/etc/initramfs-tools" "$d/t/etc/network" "$d/t/etc/mdadm" "$d/t/boot/grub"
	mkdir -p "$d/t/boot/loader/entries" "$d/t/boot/grub2" "$d/t/etc/lvm/devices" "$d/t/etc/dracut.conf.d" "$d/t/etc/sysconfig/network-scripts" "$d/t/etc/NetworkManager/system-connections"
	cp "$FIX"/raw/verify/bls/*.conf "$d/t/boot/loader/entries/"
	# the recorded entries are post-migration ones (verify's); the donor's lack the eth0 tokens
	sed -i 's/ net\.ifnames=0 biosdevname=0//' "$d/t"/boot/loader/entries/*.conf
	cp "$FIX/raw/verify/grub-rhel9-bls.cfg" "$d/t/boot/grub2/grub.cfg"
	mkenv "$d/t/boot/grub2/grubenv" "saved_entry=4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f-5.14.0-503.el9.x86_64" "kernelopts=root=/dev/mapper/rl-root ro crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap rd.md.uuid=9b8a7c6d:5e4f3a2b:1c0d9e8f:7a6b5c4d" "boot_success=0"
	printf '%s\n' 'GRUB_TIMEOUT=5' 'GRUB_DISTRIBUTOR="$(sed '"'"'s, release .*$,,g'"'"' /etc/system-release)"' 'GRUB_DEFAULT=saved' 'GRUB_DISABLE_SUBMENU=true' 'GRUB_TERMINAL_OUTPUT="console"' \
		'GRUB_CMDLINE_LINUX="crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap"' 'GRUB_DISABLE_RECOVERY="true"' 'GRUB_ENABLE_BLSCFG=true' > "$d/t/etc/default/grub"
	printf '# LVM uses devices listed in this file.\nVERSION=1.1.2\nIDTYPE=sys_wwid IDNAME=naa.6d0946606e5ad1002a1f2b3c4d5e6f70 DEVNAME=/dev/sda3 PVID=abc PART=3\n' > "$d/t/etc/lvm/devices/system.devices"
	mkdir -p "$d/t/etc/selinux"; printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' > "$d/t/etc/selinux/config"
	while IFS= read -r ver; do mkdir -p "$d/t/lib/modules/$ver"; : > "$d/t/lib/modules/$ver/modules.dep"; done < <(pl_records "$d/donor.inv" kernel | while IFS= read -r r; do pl_field "$r" version; done)
	# the ESP of a uefi system: the packages' shim + grub and a stub grub.cfg pointing at /boot/grub2
	mkdir -p "$d/t/boot/efi/EFI/rocky" "$d/t/boot/efi/EFI/BOOT"; : > "$d/t/boot/efi/EFI/rocky/shimx64.efi"; : > "$d/t/boot/efi/EFI/rocky/grubx64.efi"; : > "$d/t/boot/efi/EFI/BOOT/BOOTX64.EFI"
	cp "$FIX/raw/verify/grub-efi-stub.cfg" "$d/t/boot/efi/EFI/rocky/grub.cfg"
	rm -rf "$d/pristine"; cp -a "$d/t" "$d/pristine"
}
# uefi Rocky 9: the fixture's plan (nm-keyfile on eno1, 2 kernels, devices file, enforcing)
D=$W/rhel; mkrhel "$D" rocky9-lvm-xfs-uefi
# the donor's keyfile, pinned to the donor's MAC (the plan's [network] donor=eno1/d0:94:66:aa:bb:01/nm-keyfile)
sed 's/^mac-address=.*/mac-address=D0:94:66:AA:BB:01/' "$FIX/raw/eno1.nmconnection" > "$D/t/etc/NetworkManager/system-connections/eno1.nmconnection"
rc=$(pfrun "$D")
assert_eq  "rhel uefi: postfix_run exits 0" 0 "$rc"
assert_eq  "rhel uefi: nothing of the host was called" "0" "$(cat "$D/live.log" "$D/chroot.log" | grep -c UNEXPECTED)"
in_order "rhel uefi: steps in order, selinux before sysctl" "$D/out" "--- fstab" "--- mdadm" "--- kernel cmdline" "--- lvm" "--- network" "--- initramfs" "--- bootloader" "--- swapfiles" "--- cloud-init" "--- selinux" "--- sysctl" "postfix done"
assert_eq  "rhel uefi: dracut per donor kernel, grub2-mkconfig into the REAL grub.cfg, no grub2-install, nothing of initramfs-tools/update-grub" \
	"chroot: dracut --force /boot/initramfs-5.14.0-427.13.1.el9_4.x86_64.img 5.14.0-427.13.1.el9_4.x86_64|chroot: dracut --force /boot/initramfs-5.14.0-362.24.1.el9_3.x86_64.img 5.14.0-362.24.1.el9_3.x86_64|chroot: env GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg" \
	"$(grep '^chroot: ' "$D/chroot.log" | paste -sd'|' -)"
assert_eq  "rhel uefi: dracut drop-in" "$(printf '%s\n' '# migrator: this system was migrated; the recipient needs these drivers in every initramfs' 'add_drivers+=" mpt3sas bnxt_en "' '# the command line comes from the boot entry, never baked into the image' 'hostonly_cmdline="no"' '# the udev pin of eth0 (netfix) must act before the network comes up in the initramfs' 'install_items+=" /etc/udev/rules.d/70-persistent-net.rules "')" "$(cat "$D/t/etc/dracut.conf.d/90-migrator.conf")"
assert_eq  "rhel uefi: the literal BLS options line gets the eth0 tokens, root=/resume=/rd.lvm.lv and \$tuned_params kept" \
	'options root=/dev/mapper/rl-root ro resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap $tuned_params net.ifnames=0 biosdevname=0' \
	"$(grep '^options' "$D/t/boot/loader/entries/4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f-5.14.0-503.el9.x86_64.conf")"
assert_eq  "rhel uefi: the \$kernelopts BLS line is left alone" 'options $kernelopts $tuned_params' "$(grep '^options' "$D/t/boot/loader/entries/4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f-5.14.0-427.el9.x86_64.conf")"
assert_eq  "rhel uefi: grubenv kernelopts rewritten (rd.md.uuid gone, eth0 tokens), block still 1024 bytes of # padding" \
	"kernelopts=root=/dev/mapper/rl-root ro crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap net.ifnames=0 biosdevname=0 1024 1" \
	"$(grep '^kernelopts=' "$D/t/boot/grub2/grubenv") $(wc -c < "$D/t/boot/grub2/grubenv") $(tail -c 1 "$D/t/boot/grub2/grubenv" | grep -c '#')"
assert_eq  "rhel uefi: saved_entry kept in grubenv" "saved_entry=4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f-5.14.0-503.el9.x86_64" "$(grep '^saved_entry=' "$D/t/boot/grub2/grubenv")"
assert_has "rhel uefi: /etc/default/grub carries the eth0 tokens" 'GRUB_CMDLINE_LINUX="crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap net.ifnames=0 biosdevname=0"' "$(cat "$D/t/etc/default/grub")"
assert_fail "rhel uefi: LVM devices file removed" test -e "$D/t/etc/lvm/devices/system.devices"
assert_ok   "rhel uefi: /.autorelabel created" test -e "$D/t/.autorelabel"
assert_has "rhel uefi: the SELinux follow-up (two boots)" "SELinux: the first boot relabels every file and reboots once by itself (two boots" "$(RUN=$D state_get postfix.followups)"
assert_has "rhel uefi: keyfile moved to eth0 with the recipient's MAC" "interface-name=eth0" "$(cat "$D/t/etc/NetworkManager/system-connections/eno1.nmconnection")"
assert_eq  "rhel uefi: ... MAC" "B4:96:91:00:00:01" "$(sed -n 's/^mac-address=//p' "$D/t/etc/NetworkManager/system-connections/eno1.nmconnection" | tr 'a-f' 'A-F')"
assert_eq  "rhel uefi: efibootmgr not called on a bios-booted Live" "" "$(cat "$D/live.log")"
assert_eq  "rhel uefi: idempotent (second run changes nothing)" "0" "$(pfrun "$D" >/dev/null; grep -c '^@@' "$D/out")"
# a grubenv that would overflow is left alone with a warning
D=$W/rhel-env; mkrhel "$D" rocky9-lvm-xfs-uefi
# 25 (header) + 39 + 950 + 1 = 1015 bytes fit; the rewrite adds 28 (" net.ifnames=0 biosdevname=0") -> 1043: overflow
mkenv "$D/t/boot/grub2/grubenv" "kernelopts=root=/dev/mapper/rl-root ro $(head -c 950 /dev/zero | tr '\0' 'x')"
rc=$(pfrun "$D")
assert_eq  "rhel, grubenv overflow: still exits 0" 0 "$rc"
assert_has "rhel, grubenv overflow: warned, file untouched" "rewriting /boot/grub2/grubenv failed (pf_grubenv_rewrite): the file is left untouched" "$(cat "$D/out")"
assert_eq  "rhel, grubenv overflow: 1024 bytes as before" 1024 "$(wc -c < "$D/t/boot/grub2/grubenv")"
# bios CentOS 7 (no BLS): grub2-install on the disk, mkconfig to /boot/grub2/grub.cfg, ifcfg -> eth0
D=$W/rhel-bios; mkrhel "$D" centos7-md-lvm-xfs-bios
rm -rf "$D/t/boot/loader"; cp "$FIX/raw/ifcfg-eth0" "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"; sed -i 's/^NAME="eth0"/NAME="eno1"/; s/^DEVICE=.*/DEVICE="eno1"/' "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"
grep -q '^DEVICE=' "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1" || echo 'DEVICE="eno1"' >> "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"
echo 'HWADDR=3C:EC:EF:11:22:33' >> "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"
rc=$(pfrun "$D")
assert_eq  "rhel bios: exits 0" 0 "$rc"
assert_eq  "rhel bios: grub2-install then mkconfig, dracut for both el7 kernels" \
	"chroot: dracut --force /boot/initramfs-3.10.0-1160.118.1.el7.x86_64.img 3.10.0-1160.118.1.el7.x86_64|chroot: dracut --force /boot/initramfs-3.10.0-1160.el7.x86_64.img 3.10.0-1160.el7.x86_64|chroot: grub2-install --target=i386-pc --recheck /dev/sda|chroot: env GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg" \
	"$(grep '^chroot: ' "$D/chroot.log" | paste -sd'|' -)"
assert_ok   "rhel bios: ifcfg-eno1 became ifcfg-eth0" test -f "$D/t/etc/sysconfig/network-scripts/ifcfg-eth0"
assert_fail "rhel bios: ifcfg-eno1 gone" test -e "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"
assert_has "rhel bios: HWADDR is the recipient's boot MAC" "HWADDR=B0:83:FE:00:00:01" "$(tr 'a-f' 'A-F' < "$D/t/etc/sysconfig/network-scripts/ifcfg-eth0")"
assert_has "rhel bios: kernel cmdline rd.md.uuid dropped from /etc/default/grub" 'GRUB_CMDLINE_LINUX="' "$(cat "$D/t/etc/default/grub")"
assert_eq  "rhel bios: no rd.md token left" 0 "$(grep -c 'rd\.md' "$D/t/etc/default/grub")"
# --- (k2) rhel firmware change uefi -> bios: grub2-pc by dnf in the chroot, then grub2-install as on any bios rhel ----
D=$W/rhel-u2b; mkrhel "$D" rocky9-uefi-to-bios
sed 's/^mac-address=.*/mac-address=D0:94:66:AA:BB:01/' "$FIX/raw/eno1.nmconnection" > "$D/t/etc/NetworkManager/system-connections/eno1.nmconnection"
# a grubenv symlinked into the ESP (RHEL 8 style): a BIOS grub cannot follow it there
mkdir -p "$D/t/boot/efi/EFI/rocky"; mv "$D/t/boot/grub2/grubenv" "$D/t/boot/efi/EFI/rocky/grubenv"; ln -s ../efi/EFI/rocky/grubenv "$D/t/boot/grub2/grubenv"
rm -rf "$D/pristine"; cp -a "$D/t" "$D/pristine"
rc=$(pfrun "$D" 'RPM_INSTALLED="grub2-tools grub2-efi-x64"')
assert_eq  "rhel uefi->bios: exits 0" 0 "$rc"
assert_eq  "rhel uefi->bios: rpm -q both, dnf installs the missing ones, then grub2-install + mkconfig" \
	"chroot-q: rpm -q grub2-pc|chroot-q: rpm -q grub2-pc-modules|chroot-q: sh -c command -v dnf|chroot: dnf -y --setopt=install_weak_deps=False install grub2-pc grub2-pc-modules|chroot-q: rpm -q grub2-pc|chroot-q: rpm -q grub2-pc-modules|chroot: grub2-install --target=i386-pc --recheck /dev/sda|chroot: env GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg" \
	"$(grep -v 'dracut' "$D/chroot.log" | paste -sd'|' -)"
assert_eq  "rhel uefi->bios: nothing of the Live's grub, no apt" "0" "$(grep -c 'grub-install\|apt-get' "$D/live.log" "$D/chroot.log" | awk -F: '{ s += $2 } END { print s }')"
assert_ok   "rhel uefi->bios: grubenv is a regular file now" test -f "$D/t/boot/grub2/grubenv" -a ! -L "$D/t/boot/grub2/grubenv"
assert_eq  "rhel uefi->bios: ... with the rewritten block (1024 bytes, kernelopts without rd.md)" "1024 0" "$(wc -c < "$D/t/boot/grub2/grubenv") $(grep -c 'rd\.md' "$D/t/boot/grub2/grubenv")"
assert_has "rhel uefi->bios: says the packages come by dnf" "firmware change: grub2 for BIOS (grub2-pc grub2-pc-modules) is installed into the target by dnf" "$(cat "$D/out")"
assert_has "rhel uefi->bios: the follow-up names the leftovers" "grub2 for BIOS (grub2-pc grub2-pc-modules) was installed by dnf; the uefi packages (grub2-efi-x64, shim-x64) stay and may be removed" "$(RUN=$D state_get postfix.followups)"
assert_has "rhel uefi->bios: BLS entries carry the eth0 tokens" "net.ifnames=0 biosdevname=0" "$(grep '^options' "$D/t/boot/loader/entries/4f1c2d3e4a5b4c6d8e7f9a0b1c2d3e4f-5.14.0-503.el9.x86_64.conf")"
# a second run: the packages are there (rpm -q), no dnf
rc=$(pfrun "$D" 'RPM_INSTALLED="grub2-tools grub2-efi-x64 grub2-pc grub2-pc-modules"')
assert_eq  "rhel uefi->bios, second run: exits 0" 0 "$rc"
assert_eq  "rhel uefi->bios, second run: no dnf, grub2-install again" "0 1" "$(grep -c 'dnf -y' "$D/chroot.log") $(grep -c 'grub2-install' "$D/chroot.log")"
assert_eq  "rhel uefi->bios: the yum branch is never taken where dnf exists" 0 "$(grep -c 'yum' "$D/chroot.log")"
assert_has "rhel uefi->bios, second run: says they are there" "grub2-pc is in the target" "$(cat "$D/out")"
# dnf fails (no repositories reachable): the disk is written, so a die with the manual path
D=$W/rhel-u2b-fail; mkrhel "$D" rocky9-uefi-to-bios
rc=$(pfrun "$D" 'DNF_FAIL=1')
assert_eq  "rhel uefi->bios, dnf fails: exit $EX_FAIL" "$EX_FAIL" "$rc"
assert_has "rhel uefi->bios, dnf fails: the manual path" "installing grub2-pc grub2-pc-modules into the target failed: the BIOS boot code cannot be set up. By hand: 'rescue', chroot <root>, check /etc/resolv.conf and the repositories (dnf repolist; a RHEL without a subscription needs a reachable repo or the rpms by hand), dnf -y install grub2-pc grub2-pc-modules, then repeat 'migrator -s postfix'" "$(cat "$D/out")"
assert_eq  "rhel uefi->bios, dnf fails: no grub2-install" 0 "$(grep -c grub2-install "$D/chroot.log")"

# --- (k3) rhel firmware change bios -> uefi (CentOS 7, yum): shim + grub2-efi onto the NEW ESP, a stub grub.cfg, mkconfig to /boot/grub2 ----
D=$W/rhel-b2u; mkrhel "$D" centos7-bios-to-uefi
rm -rf "$D/t/boot/loader" "$D/t/boot/efi"; mkdir -p "$D/t/boot/efi"    # a bios donor: no BLS, and the new ESP is empty
cp "$FIX/raw/ifcfg-eth0" "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"; sed -i 's/^NAME="eth0"/NAME="eno1"/; s/^DEVICE=.*/DEVICE="eno1"/' "$D/t/etc/sysconfig/network-scripts/ifcfg-eno1"
rm -rf "$D/pristine"; cp -a "$D/t" "$D/pristine"
rc=$(pfrun "$D" 'NO_DNF=1; DNF_MAKES_EFI=centos; RPM_INSTALLED="grub2-tools grub2-pc"')
assert_eq  "rhel bios->uefi: exits 0" 0 "$rc"
assert_eq  "rhel bios->uefi: yum (no dnf on el7) installs the three, no grub2-install, mkconfig to /boot/grub2/grub.cfg" \
	"chroot-q: rpm -q grub2-efi-x64|chroot-q: rpm -q shim-x64|chroot-q: rpm -q efibootmgr|chroot-q: sh -c command -v dnf|chroot: yum -y install grub2-efi-x64 shim-x64 efibootmgr|chroot-q: rpm -q grub2-efi-x64|chroot-q: rpm -q shim-x64|chroot-q: rpm -q efibootmgr|chroot: env GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg" \
	"$(grep -v 'dracut' "$D/chroot.log" | paste -sd'|' -)"
assert_eq  "rhel bios->uefi: the stub grub.cfg on the new ESP hands over to /boot/grub2 by the UUID of /boot" \
	"$(printf '%s\n' 'search --no-floppy --fs-uuid --set=dev b0070000-0000-4000-8000-0000000000c9' 'set prefix=($dev)/grub2' 'export $prefix' 'configfile $prefix/grub.cfg')" "$(cat "$D/t/boot/efi/EFI/centos/grub.cfg")"
assert_has "rhel bios->uefi: the stub is noted" "/boot/efi/EFI/centos/grub.cfg: a stub handing over to /boot/grub2/grub.cfg (filesystem b0070000-0000-4000-8000-0000000000c9)" "$(cat "$D/out")"
assert_eq  "rhel bios->uefi: the new ESP's fstab line, the rhel way" "UUID=C5F3-802F /boot/efi vfat umask=0077,shortname=winnt 0 2" "$(grep '/boot/efi' "$D/t/etc/fstab")"
assert_has "rhel bios->uefi: the follow-up names the leftovers" "shim and grub2 for UEFI (grub2-efi-x64 shim-x64 efibootmgr) were installed by dnf; grub2-pc stays and may be removed" "$(RUN=$D state_get postfix.followups)"
assert_eq  "rhel bios->uefi: no 'no grubx64.efi' warning (the packages put it there)" 0 "$(grep -c 'nothing of centos to load' "$D/out")"
assert_eq  "rhel bios->uefi: efibootmgr not called on a bios-booted Live" "" "$(cat "$D/live.log")"
assert_ok   "rhel bios->uefi: ifcfg-eno1 became ifcfg-eth0" test -f "$D/t/etc/sysconfig/network-scripts/ifcfg-eth0"
# the same run on a UEFI-booted Live: the NVRAM entry points at the shim of the new vendor directory
D=$W/rhel-b2u-nvram; mkrhel "$D" centos7-bios-to-uefi
rm -rf "$D/t/boot/loader" "$D/t/boot/efi"; mkdir -p "$D/t/boot/efi"; rm -rf "$D/pristine"; cp -a "$D/t" "$D/pristine"
cp "$FIX/raw/verify/efibootmgr-v.txt" "$D/efi.state"
rc=$(pfrun "$D" 'NO_DNF=1; DNF_MAKES_EFI=centos; RPM_INSTALLED="grub2-tools grub2-pc"; EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }')
assert_eq  "rhel bios->uefi on a UEFI Live: exits 0" 0 "$rc"
assert_has "rhel bios->uefi on a UEFI Live: NVRAM entry with the new shim" 'efibootmgr -c -d /dev/sda -p 4 -L CentOS Linux 7 (Core) -l \EFI\centos\shimx64.efi' "$(cat "$D/live.log")"
# the stub is not rewritten when the packages (or a previous run) left a grub.cfg on the ESP
rc=$(pfrun "$D" 'NO_DNF=1; RPM_INSTALLED="grub2-tools grub2-pc grub2-efi-x64 shim-x64 efibootmgr"; EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }')
assert_eq  "rhel bios->uefi, second run: exits 0, no yum, stub untouched" "0 0 0" "$rc $(grep -c 'yum -y' "$D/chroot.log") $(grep -c '^@@' "$D/out")"

# --- (k4) the dry outline of a rhel firmware change ----
D=$W/rhel-u2b-dry; mk "$D" rocky9-uefi-to-bios
( RUN=$D; DRY=y; pf_target_present() { return 1; }; postfix_run ) > "$D/out" 2>&1; rc=$?
assert_eq  "rhel uefi->bios dry outline: exit 0" 0 "$rc"
assert_has "rhel uefi->bios dry outline: dnf line" "(dry)   bootloader: firmware change: chroot dnf -y --setopt=install_weak_deps=False install grub2-pc grub2-pc-modules (the target's own repositories; yum where there is no dnf)" "$(cat "$D/out")"
assert_has "rhel uefi->bios dry outline: grub2-install line" "(dry)   bootloader: chroot grub2-install --target=i386-pc (/dev/sda), grub2-mkconfig -o /boot/grub2/grub.cfg" "$(cat "$D/out")"
D=$W/rhel-b2u-dry; mk "$D" centos7-bios-to-uefi
( RUN=$D; DRY=y; pf_target_present() { return 1; }; postfix_run ) > "$D/out" 2>&1; rc=$?
assert_eq  "rhel bios->uefi dry outline: exit 0" 0 "$rc"
assert_has "rhel bios->uefi dry outline: dnf line" "(dry)   bootloader: firmware change: chroot dnf -y --setopt=install_weak_deps=False install grub2-efi-x64 shim-x64 efibootmgr (the target's own repositories; yum where there is no dnf)" "$(cat "$D/out")"
assert_has "rhel bios->uefi dry outline: stub + mkconfig line" "(dry)   bootloader: no grub2-install on uefi (the signed shim/grub of the packages); a stub grub.cfg on the new ESP handing over to /boot/grub2/grub.cfg; chroot grub2-mkconfig -o /boot/grub2/grub.cfg; NVRAM entry with shimx64.efi" "$(cat "$D/out")"
# -n on a mounted tree: the dnf line is spoken, nothing is run
D=$W/rhel-b2u-dryroot; mkrhel "$D" centos7-bios-to-uefi; rm -rf "$D/t/boot/loader" "$D/t/boot/efi"; mkdir -p "$D/t/boot/efi"
rc=$(pfrun "$D" 'DRY=y')
assert_eq  "rhel bios->uefi -n ROOT: exit 0" 0 "$rc"
assert_has "rhel bios->uefi -n ROOT: dry dnf line" "(dry) chroot rpm -q grub2-efi-x64 shim-x64 efibootmgr || dnf -y --setopt=install_weak_deps=False install <the missing ones> (yum where there is no dnf)" "$(cat "$D/out")"
assert_eq  "rhel bios->uefi -n ROOT: no stub written, nothing installed" "0 0" "$(find "$D/t/boot/efi" -mindepth 1 | wc -l) $(grep -c 'install' "$D/chroot.log")"

# dracut on a deb donor: the initramfs step follows the tool, the bootloader the family
D=$W/dracut; mk "$D" stand-debian-md-ext4-bios; sed -i 's/ initramfs=initramfs-tools / initramfs=dracut /' "$D/plan"
while IFS= read -r ver; do mkdir -p "$D/t/lib/modules/$ver"; [ -f "$D/t/lib/modules/$ver/modules.dep" ] || : > "$D/t/lib/modules/$ver/modules.dep"; done < <(pl_records "$D/donor.inv" kernel | while IFS= read -r r; do pl_field "$r" version; done)
rc=$(pfrun "$D")
assert_eq  "dracut on deb: exits 0" 0 "$rc"
assert_eq  "dracut on deb: dracut, then grub-install + update-grub as on any deb" "chroot: dracut --force /boot/initrd.img-5.10.0-32-amd64 5.10.0-32-amd64|chroot: grub-install --target=i386-pc --recheck /dev/vda|chroot: update-grub" "$(grep '^chroot: ' "$D/chroot.log" | grep -v update-initramfs | paste -sd'|' -)"
assert_eq  "dracut on deb: update-initramfs not called" 0 "$(grep -c update-initramfs "$D/chroot.log")"
# the dry outline of an rhel plan
D=$W/rhel-dry; mk "$D" rocky9-lvm-xfs-uefi
( RUN=$D; DRY=y; pf_target_present() { return 1; }; postfix_run ) > "$D/out" 2>&1; rc=$?
assert_eq  "rhel dry outline: exit 0" 0 "$rc"
assert_has "rhel dry outline: dracut line" "(dry)   initramfs: /etc/dracut.conf.d/90-migrator.conf (add_drivers mpt3sas bnxt_en, hostonly_cmdline=no); chroot dracut --force per donor kernel (2)" "$(cat "$D/out")"
assert_has "rhel dry outline: no grub2-install on uefi" "(dry)   bootloader: no grub2-install on uefi (the signed shim/grub of the packages stay); chroot grub2-mkconfig into the real grub.cfg; NVRAM entry with shimx64.efi" "$(cat "$D/out")"
assert_has "rhel dry outline: BLS + grubenv" "(dry)   kernel cmdline: also BLS entries (boot/loader/entries/*.conf) and grubenv kernelopts" "$(cat "$D/out")"
assert_has "rhel dry outline: autorelabel" "(dry)   selinux: /.autorelabel (the first boot relabels and reboots once)" "$(cat "$D/out")"
D=$W/family; mk "$D" stand-debian-md-ext4-bios; sed -i 's/^family=deb /family=suse /' "$D/plan"
assert_eq "unknown family: exit 4" 4 "$(pfrun "$D")"
D=$W/grubkind; mk "$D" stand-debian-md-ext4-bios; sed -i 's/ grub=i386-pc / grub=arm64-efi /' "$D/plan"
assert_eq "unknown grub target: exit 4" 4 "$(pfrun "$D")"
D=$W/noplan; mkdir -p "$D/t/etc"
assert_eq "no plan: exit 2" 2 "$(pfrun "$D")"
D=$W/noroot; mk "$D" stand-debian-md-ext4-bios
( RUN=$D; postfix_run "$D/nowhere" ) > "$D/out" 2>&1; rc=$?
assert_eq "ROOT that is no tree: exit 2" 2 "$rc"
( RUN=$D; pf_chroot_ready() { return 1; }; postfix_run "$D/t" ) > "$D/out" 2>&1; rc=$?
assert_eq "ROOT without /proc bound: exit 2" 2 "$rc"
assert_has "ROOT without /proc bound: tells how to bind" "mount --rbind" "$(tail -1 "$D/out")"
assert_eq "ROOT without /proc bound: nothing changed" "$(treesum "$D/pristine")" "$(treesum "$D/t")"
# without ROOT: the real phase needs transfer; -n without the target on the disk prints the outline
( RUN=$D; postfix_run ) > "$D/out" 2>&1; rc=$?
assert_eq "no ROOT, transfer not done: exit 2" 2 "$rc"
assert_has "no ROOT, transfer not done: says so" "run transfer first" "$(tail -1 "$D/out")"
: > "$D/chroot.log"
( RUN=$D; DRY=y; postfix_run ) > "$D/out" 2>&1; rc=$?
assert_eq "dry, no ROOT, target not written: exit 0" 0 "$rc"
assert_has "dry outline: header" "(dry) postfix would:" "$(cat "$D/out")"
assert_has "dry outline: the bootloader line from the plan" "chroot grub-install --target=i386-pc (/dev/vda), chroot update-grub" "$(cat "$D/out")"
assert_has "dry outline: the network line from the plan" "network: ens3/-/interfaces -> eth0 @ 52:54:00:cc:dd:01, pin=1" "$(cat "$D/out")"
assert_eq "dry outline: nothing mounted, no chroot" "" "$(cat "$D/chroot.log")"

# --- (l) uefi -> bios: grub from the Live, netplan, cloud-init, a swapfile -------------------------------------------------------------
D=$W/u2b; mk "$D" ubuntu-nvme-uefi-to-bios-vm
sed -i 's/^\(swapfile\tpath=\/swapfile\tsize=\)[0-9]*/\18388608/' "$D/donor.inv"
rm -f "$D/t/etc/network/interfaces"; mkdir -p "$D/t/etc/netplan" "$D/t/etc/cloud/cloud.cfg.d"; echo 'users: [default]' > "$D/t/etc/cloud/cloud.cfg"
cat > "$D/t/etc/netplan/00-installer-config.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    enp1s0:
      match:
        macaddress: "52:54:00:11:22:33"
      set-name: enp1s0
      addresses: [10.0.0.37/24]
      gateway4: 10.0.0.1
EOF
cat >> "$D/t/etc/fstab" <<'EOF'
/swapfile none swap sw 0 0
EOF
printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=tty1"\nGRUB_FORCE_PARTUUID=11111111-AAAA-4BBB-8CCC-000000000003\n' > "$D/t/etc/default/grub.d/50-cloudimg-settings.cfg"
rm -rf "$D/pristine"; cp -a "$D/t" "$D/pristine"
rc=$(pfrun "$D" 'target_chroot_q() { echo "chroot-q: $*" >> "$RUN/chroot.log"; case "$1" in dpkg-query) return 1;; esac; return 0; }')
assert_eq "uefi->bios: exits 0" 0 "$rc"
assert_eq "uefi->bios: nothing unexpected ran" "0" "$(cat "$D/live.log" "$D/chroot.log" | grep -c UNEXPECTED)"
assert_has "uefi->bios: grub-install ran from the LIVE with the target's /boot" "grub-install --target=i386-pc --boot-directory=$D/t/boot --recheck /dev/vda" "$(cat "$D/live.log")"
assert_eq "uefi->bios: chroot runs update-initramfs and update-grub only; debconf skipped quietly (no grub-pc)" \
	"chroot: update-initramfs -u -k all|chroot: update-grub|note: os-prober is off during update-grub|chroot-q: sh -c command -v debconf-set-selections|chroot-q: dpkg-query -W grub-pc" "$(paste -sd'|' "$D/chroot.log")"
in_order "uefi->bios: initramfs, then grub from the Live, then update-grub" "$D/seq.log" "chroot: update-initramfs" "live: grub-install --target=i386-pc" "chroot: update-grub"
assert_has "uefi->bios: the manual follow-up is printed" "apt install grub-pc && apt purge grub-efi-amd64 in the migrated OS" "$(cat "$D/out")"
assert_has "uefi->bios: follow-ups header" "manual follow-ups after the first boot of the migrated OS (1):" "$(cat "$D/out")"
assert_has "uefi->bios: and kept in state" "apt install grub-pc && apt purge grub-efi-amd64" "$(RUN=$D state_get postfix.followups)"
assert_eq "uefi->bios: netplan key renamed, set-name gone, match MAC replaced" \
	'    eth0:|      match:|        macaddress: "52:54:00:cc:dd:01"|      addresses: [10.0.0.37/24]' "$(sed -n '4,7p' "$D/t/etc/netplan/00-installer-config.yaml" | paste -sd'|' -)"
assert_eq "uefi->bios: cloud-init network config disabled" "network: {config: disabled}|preserve_hostname: true" "$(grep -v '^#' "$D/t/etc/cloud/cloud.cfg.d/99-migrator.cfg" | paste -sd'|' -)"
assert_eq "uefi->bios: swapfile recreated (files method): dd, mkswap" "dd if=/dev/zero of=$D/t/swapfile bs=1M count=8 conv=fsync|mkswap $D/t/swapfile" "$(grep -e '^dd' -e '^mkswap' "$D/live.log" | paste -sd'|' -)"
assert_eq "uefi->bios: swapfile size and mode" "8388608 600" "$(stat -c '%s %a' "$D/t/swapfile")"
assert_eq "uefi->bios: dropin _DEFAULT untouched, GRUB_FORCE_PARTUUID of the target kept" "$(cat "$D/pristine/etc/default/grub.d/50-cloudimg-settings.cfg")" "$(cat "$D/t/etc/default/grub.d/50-cloudimg-settings.cfg")"
before=$(treesum "$D/t")
rc=$(pfrun "$D" 'target_chroot_q() { return 1; }')
assert_eq "uefi->bios, second run: no diff hunks, tree untouched, swapfile not rewritten" "0 0 same 0" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED) $(grep -c '^dd' "$D/live.log")"
# grub for that firmware missing in the Live and nothing to install it with -> exit 2 before grub runs
D=$W/u2b-nogrub; mk "$D" ubuntu-nvme-uefi-to-bios-vm
rc=$(pfrun "$D" 'pf_live_grub_ready() { return 1; }')
assert_eq "uefi->bios without grub in the Live: exit 2" 2 "$rc"
assert_eq "uefi->bios without grub in the Live: grub-install not attempted" "0" "$(grep -c '^grub-install' "$D/live.log")"
assert_eq "uefi->bios without grub in the Live: the os-prober cfg does not outlive the failure" "gone" "$([ -e "$D/t/etc/default/grub.d/99-migrator-osprober.cfg" ] && echo there || echo gone)"

# --- (m) uefi -> uefi (crafted from the stand plan): two chroot grub-installs, NVRAM only on a UEFI Live ------------------------------------
mkuefi() {
	mk "$1" stand-debian-md-ext4-bios
	sed -i -e 's/ grub=i386-pc / grub=x86_64-efi /' -e 's/^label=dos firmware=bios bios_grub=- esp=- /label=gpt firmware=uefi bios_grub=- esp=1 /' "$1/plan"
	mkdir -p "$1/t/boot/efi/EFI/debian" "$1/t/boot/efi/EFI/BOOT"; : > "$1/t/boot/efi/EFI/debian/shimx64.efi"; : > "$1/t/boot/efi/EFI/debian/grubx64.efi"
	printf 'BootCurrent: 0003\nTimeout: 1 seconds\nBootOrder: 0003,0001,0000,0002\nBoot0000* Debian GNU/Linux 11 (bullseye)\nBoot0001* UEFI: PXE IPv4 Intel(R) I350\nBoot0002* EFI Shell\nBoot0003* UEFI PXEv4 (MAC:525400123456)\n' > "$1/efi.state"
}
D=$W/uefi; mkuefi "$D"
rc=$(pfrun "$D" 'EFI_STATE=$RUN/efi.state; export EFI_STATE')
assert_eq "uefi: exits 0" 0 "$rc"
assert_eq "uefi: grub-install twice in the chroot (plain, then --removable), then update-grub; no debconf for grub-pc" \
	"chroot: update-initramfs -u -k all|chroot: grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-nvram|chroot: grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-nvram --removable|chroot: update-grub|note: os-prober is off during update-grub" \
	"$(paste -sd'|' "$D/chroot.log")"
assert_eq "uefi: efibootmgr is not called on a Live that did not boot through UEFI" "" "$(cat "$D/live.log")"
assert_has "uefi: ... and says why" "no NVRAM entry is written" "$(cat "$D/out")"
D=$W/uefi-nvram; mkuefi "$D"
rc=$(pfrun "$D" 'EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }')
assert_eq "uefi, UEFI Live: exits 0" 0 "$rc"
assert_eq "uefi, UEFI Live: old entry deleted, new one created on the ESP, PXE entries stay first" \
	'efibootmgr |efibootmgr -b 0000 -B|efibootmgr -c -d /dev/vda -p 1 -L Debian GNU/Linux 11 (bullseye) -l \EFI\debian\shimx64.efi|efibootmgr |efibootmgr -o 0003,0001,0004,0002' "$(paste -sd'|' "$D/live.log")"
assert_eq "uefi, UEFI Live: the resulting BootOrder" "BootOrder: 0003,0001,0004,0002" "$(grep '^BootOrder' "$D/efi.state")"
D=$W/uefi-local; mkuefi "$D"; rm -f "$D/t/boot/efi/EFI/debian/shimx64.efi"
rc=$(pfrun "$D" 'EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }; OPT[bootorder]=local')
assert_eq "uefi, bootorder=local: grubx64.efi without shim, BootOrder left to efibootmgr (new entry first)" \
	'0|efibootmgr -c -d /dev/vda -p 1 -L Debian GNU/Linux 11 (bullseye) -l \EFI\debian\grubx64.efi|0|BootOrder: 0004,0003,0001,0002' \
	"$rc|$(grep -e ' -c ' "$D/live.log")|$(grep -c -e ' -o ' "$D/live.log")|$(grep '^BootOrder' "$D/efi.state")"
D=$W/uefi-fail; mkuefi "$D"; rm -f "$D/efi.state"
rc=$(pfrun "$D" 'EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }')
assert_eq "uefi, efibootmgr fails: a WARN, not a failure" "0" "$rc"
assert_has "uefi, efibootmgr fails: the warning is repeated at the end" "efibootmgr cannot read the boot entries" "$(sed -n '/postfix warnings/,$p' "$D/out")"
# bios -> uefi: the Live's grub writes the removable loader, grub-pc is told to stay away
D=$W/b2u; mkuefi "$D"; sed -i 's/ compress=lz4$/ compress=lz4 grub_from_live=1/' "$D/plan"; rm -rf "$D/t/boot/efi/EFI/debian"; : > "$D/t/boot/efi/EFI/BOOT/BOOTX64.EFI"
rc=$(pfrun "$D" 'EFI_STATE=$RUN/efi.state; export EFI_STATE; pf_is_uefi_live() { return 0; }')
assert_eq "bios->uefi: exits 0" 0 "$rc"
assert_has "bios->uefi: grub-install from the Live, removable, no NVRAM" "grub-install --target=x86_64-efi --efi-directory=$D/t/boot/efi --boot-directory=$D/t/boot --removable --no-nvram --recheck" "$(cat "$D/live.log")"
assert_eq "bios->uefi: no grub-install in the chroot" "0" "$(grep -c 'chroot: grub-install' "$D/chroot.log")"
assert_has "bios->uefi: grub-pc/install_devices emptied" "'grub-pc grub-pc/install_devices multiselect ' 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections" "$(cat "$D/chroot.log")"
assert_has "bios->uefi: the manual follow-up" "apt install grub-efi-amd64 && apt purge grub-pc" "$(RUN=$D state_get postfix.followups)"
assert_has "bios->uefi: the NVRAM entry points at the removable loader" '-l \EFI\BOOT\BOOTX64.EFI' "$(grep -e ' -c ' "$D/live.log")"

# --- (n) lvm: devices file and filter (crafted from the stand plan) --------------------------------------------------------------------------
D=$W/lvm; mk "$D" stand-debian-md-ext4-bios
sed -i 's/ lvm_devices_file=keep lvm_filter=keep / lvm_devices_file=delete lvm_filter=neutralise /' "$D/plan"
mkdir -p "$D/t/etc/lvm/devices"; echo 'IDTYPE=sys_wwid IDNAME=naa.5000 DEVNAME=/dev/sda2 PVID=x' > "$D/t/etc/lvm/devices/system.devices"
cp "$W/lvm.in" "$D/t/etc/lvm/lvm.conf"
rc=$(pfrun "$D")
assert_eq "lvm: exits 0, system.devices removed (original kept), filters commented" "0 gone IDTYPE=sys_wwid 0 3" \
	"$rc $([ -e "$D/t/etc/lvm/devices/system.devices" ] && echo there || echo gone) $(cut -d' ' -f1 "$D/t/var/lib/migrator/orig/etc/lvm/devices/system.devices") $(grep -c '^[[:space:]]*\(global_\)\?filter' "$D/t/etc/lvm/lvm.conf") $(grep -c 'migrator' "$D/t/etc/lvm/lvm.conf")"

# --- (n2) raid=1: mdadm into the target, mdadm.conf = our arrays, grub on both disks ---------------------------------------
pf_mdadm_conf_rewrite "$W/arrays.none" < "$TREE/etc/mdadm/mdadm.conf" > "$W/mdadm-r0.out" 2>/dev/null
printf 'ARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b\nARRAY /dev/md3 metadata=1.2 name=web1:3 UUID=7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e\n' > "$W/arrays"
pf_mdadm_conf_rewrite "$W/arrays" < "$TREE/etc/mdadm/mdadm.conf" > "$W/mdadm-r.out"
assert_eq "raid rewriter: the donor's ARRAY lines are commented out" "2" "$(grep -c '^# migrator: ARRAY /dev/md[01] ' "$W/mdadm-r.out")"
assert_eq "raid rewriter: ours appended, in order" "ARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b|ARRAY /dev/md3 metadata=1.2 name=web1:3 UUID=7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e" "$(grep '^ARRAY' "$W/mdadm-r.out" | paste -sd'|' -)"
assert_eq "raid rewriter: the rest of the file intact" "$(grep -v '^ARRAY' "$TREE/etc/mdadm/mdadm.conf")" "$(grep -v '^ARRAY' "$W/mdadm-r.out" | grep -v '^# migrator: ARRAY')"
assert_eq "raid rewriter: idempotent" "$(cat "$W/mdadm-r.out")" "$(pf_mdadm_conf_rewrite "$W/arrays" < "$W/mdadm-r.out")"
assert_eq "raid rewriter: a line of ours already there stays in place, is not duplicated" "1 ARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b" \
	"$(printf 'DEVICE partitions\nARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b\nMAILADDR root\n' | pf_mdadm_conf_rewrite "$W/arrays" | grep -c '/dev/md1 ') $(printf 'DEVICE partitions\nARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b\nMAILADDR root\n' | pf_mdadm_conf_rewrite "$W/arrays" | sed -n 2p)"
assert_eq "raid rewriter: without arrays = the old behaviour" "$(pf_mdadm_conf_rewrite "" < "$TREE/etc/mdadm/mdadm.conf")" "$(cat "$W/mdadm-r0.out")"
assert_eq "pf_md_conf_new: header + the lines" "MAILADDR root|HOMEHOST <system>|ARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b|ARRAY /dev/md3 metadata=1.2 name=web1:3 UUID=7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e" "$(pf_md_conf_new "$W/arrays" | grep -v '^#' | grep . | paste -sd'|' -)"
assert_eq "plan_md_arrays: one ARRAY line per [md] line of the plan" "ARRAY /dev/md1 metadata=1.2 name=web1:1 UUID=1f2e3d4c:5b6a7988:9a0b1c2d:3e4f5a6b|ARRAY /dev/md2 metadata=1.2 name=web1:2 UUID=8cdd67b2:a490888e:139944df:c3e3bdd9|ARRAY /dev/md3 metadata=1.2 name=web1:3 UUID=7a8b9c0d:1e2f3a4b:5c6d7e8f:9a0b1c2e" "$(plan_md_arrays "$FIX/raid1-md-bios/expected.plan" | paste -sd'|' -)"
# the bios mirror end to end over the captured tree, mdadm present in the target
D=$W/raid; mk "$D" raid1-md-bios; mkdir -p "$D/t/usr/sbin"; : > "$D/t/usr/sbin/mdadm"
rc=$(pfrun "$D")
assert_eq  "raid: postfix_run exits 0" 0 "$rc"
assert_eq  "raid: nothing of the host was called" "0" "$(cat "$D/live.log" "$D/chroot.log" | grep -c UNEXPECTED)"
assert_has "raid: mdadm found, no apt" "mdadm is in the target" "$(cat "$D/out")"
assert_eq  "raid: no apt-get in the chroot" 0 "$(grep -c apt-get "$D/chroot.log")"
assert_eq  "raid: mdadm.conf carries exactly our 3 arrays" "$(plan_md_arrays "$D/plan")" "$(grep '^ARRAY' "$D/t/etc/mdadm/mdadm.conf")"
assert_eq  "raid: the donor's 2 arrays commented out" 2 "$(grep -c '^# migrator: ARRAY' "$D/t/etc/mdadm/mdadm.conf")"
assert_has "raid: says so" "mdadm.conf: 3 ARRAY line(s) of this recipient's arrays" "$(cat "$D/out")"
assert_eq  "raid: grub-install on both disks, update-grub once" "chroot: grub-install --target=i386-pc --recheck /dev/vda|chroot: grub-install --target=i386-pc --recheck /dev/vdb|chroot: update-grub" "$(grep -E 'grub-install|update-grub' "$D/chroot.log" | grep -v '^note' | paste -sd'|' -)"
assert_has "raid: debconf names both disks" "grub-pc grub-pc/install_devices multiselect /dev/vda, /dev/vdb" "$(cat "$D/chroot.log")"
assert_has "raid: the resync follow-up" "md RAID1: the resync of /dev/md1 /dev/md2 /dev/md3 continues in the background after the boot (cat /proc/mdstat); both disks carry the bootloader" "$(RUN=$D state_get postfix.followups)"
assert_eq  "raid: no /dev/md spec is left in fstab (the tree's own are UUIDs already)" 0 "$(grep -c '^/dev/md' "$D/t/etc/fstab")"
assert_eq  "raid: idempotent (second run changes nothing)" "0" "$(pfrun "$D" >/dev/null; grep -c '^@@' "$D/out")"
# mdadm missing in the target: apt in the chroot (recorded; the recorder "installs" it)
D=$W/raid-apt; mk "$D" raid1-md-bios
rc=$(pfrun "$D" 'target_chroot() { echo "chroot: $*" >> "$RUN/chroot.log"; case "$*" in *"install -y --no-install-recommends mdadm"*) mkdir -p "$TARGET_MNT/usr/sbin"; : > "$TARGET_MNT/usr/sbin/mdadm";; esac; return 0; }')
assert_eq  "raid, no mdadm: exits 0" 0 "$rc"
assert_has "raid, no mdadm: says it installs" "the donor OS has no mdadm: installing it into the target" "$(cat "$D/out")"
assert_eq  "raid, no mdadm: apt-get update, then install, services kept down" "chroot: apt-get -o Acquire::Retries=2 update|chroot: apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends mdadm" "$(grep apt-get "$D/chroot.log" | paste -sd'|' -)"
assert_fail "raid, no mdadm: policy-rc.d removed afterwards" test -e "$D/t/usr/sbin/policy-rc.d"
assert_eq  "raid, no mdadm: mdadm.conf written" 3 "$(grep -c '^ARRAY' "$D/t/etc/mdadm/mdadm.conf")"
D=$W/raid-apt-fail; mk "$D" raid1-md-bios
rc=$(pfrun "$D" 'target_chroot() { echo "chroot: $*" >> "$RUN/chroot.log"; case "$*" in *"install -y"*) return 100;; esac; return 0; }')
assert_eq  "raid, apt fails: exit 1" 1 "$rc"
assert_has "raid, apt fails: the manual way out" "apt-get install mdadm failed in the target: the arrays cannot be assembled at boot. By hand: 'rescue', chroot <root>, apt-get install mdadm" "$(cat "$D/out")"
# a dry run over the raid plan prints the outline (no target on the disk)
D=$W/raid-dry; mk "$D" raid1-md-bios
rc=$( ( RUN=$D; DRY=y; pf_target_present() { return 1; }; postfix_run ) > "$D/out" 2>&1; echo $? )
assert_eq  "raid, dry outline: exit 0" 0 "$rc"
assert_has "raid, dry outline: mdadm line" "(dry)   mdadm: install mdadm into the target when missing (donor mdadm=-), mdadm.conf = the ARRAY lines of /dev/md1 /dev/md2 /dev/md3" "$(cat "$D/out")"
assert_has "raid, dry outline: bootloader on both" "(dry)   bootloader: chroot grub-install --target=i386-pc (/dev/vda and /dev/vdb), chroot update-grub" "$(cat "$D/out")"
# uefi + raid (crafted): the second ESP is filled through its own step, dry run only (it mounts a device)
D=$W/raid-uefi; mkuefi "$D"
sed -i 's/^label=gpt firmware=uefi bios_grub=- esp=1 .*/& raid=1/; /^currently=free$/a disk2=\/dev\/vdb id2=serial:XSRECIP1 size2=21474836480 ptuuid2=- head2=- geometry=21474836480 md=\/dev\/md2,\/dev\/md4 esp2=\/dev\/vdb1\ncurrently2=free' "$D/plan"
sed -i 's/ esp=\/dev\/vda1$/ esp=\/dev\/vda1 raid=1 disk2=\/dev\/vdb esp2=\/dev\/vdb1 mdadm=1/; s/^\(family=deb .* esp=-\)$/\1 raid=1 disk2=\/dev\/vdb esp2=\/dev\/vdb1 mdadm=1/' "$D/plan"
sed -i '/^\[lvm\]/i [md]\nmdadm --create /dev/md2 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=2 --uuid=11111111:22222222:33333333:44444444 /dev/vda2 /dev/vdb2\nmdadm --create /dev/md4 --run --level=1 --raid-devices=2 --metadata=1.2 --data-offset=8M --homehost=fixture-debian --name=4 --uuid=55555555:66666666:77777777:88888888 /dev/vda4 /dev/vdb4' "$D/plan"
mkdir -p "$D/t/usr/sbin"; : > "$D/t/usr/sbin/mdadm"
rc=$(pfrun "$D" 'DRY=y; EFI_STATE=$RUN/efi.state; export EFI_STATE')
assert_eq  "raid uefi, dry: exits 0" 0 "$rc"
assert_has "raid uefi, dry: the second ESP step" "(dry) would mount /dev/vdb1 at /run/migrator-esp2, copy /boot/efi onto it, grub-install --target=x86_64-efi --efi-directory=/run/migrator-esp2 (+ --removable) into it, and register it in NVRAM" "$(cat "$D/out")"
assert_has "raid uefi, dry: the ESP follow-up" "the second ESP (/dev/vdb1) is a copy made now" "$(cat "$D/out")"
assert_eq  "raid uefi, dry: mdadm.conf diff shows our two arrays" "2" "$(grep -c '^+ARRAY /dev/md[24] ' "$D/out")"

# --- (o) postfix_record -----------------------------------------------------------------------------------------------------------------------
D=$W/stand
( RUN=$D; postfix_record "$D/t" ) > "$D/rec.out" 2>&1; rc=$?
assert_eq "record: exits 0" 0 "$rc"
rec=$(find "$D/t/root" -maxdepth 1 -type d -name 'migrator-*' | head -1)
assert_has "record: root/migrator-<YYYYmmdd-HHMMSS>/" "migrator-20" "$(basename "${rec:-none}")"
assert_eq "record: the directory is 0700" "700" "$(stat -c %a "$rec")"
assert_eq "record: plan, log, state and both inventories are there" "donor.inv log plan recipient.inv state" "$(find "$rec" -type f -printf '%f\n' | sort | xargs)"
assert_ok "record: the plan is the plan" cmp -s "$D/plan" "$rec/plan"
assert_eq "record: the stamp's keys" "date donor_serial recipient_serial plan_sha256 donor_machine_id migrator_version record" "$(cut -d= -f1 "$D/t/etc/migrator-migrated" | xargs)"
assert_eq "record: serials, plan hash, the DONOR OS machine-id" "XS-STAND-DONOR XS-456 $(sha256sum "$D/plan" | cut -c1-64) bd7b8aa0e92940cf983a3aa8925fb464" \
	"$(sed -n 's/^donor_serial=//p' "$D/t/etc/migrator-migrated") $(sed -n 's/^recipient_serial=//p' "$D/t/etc/migrator-migrated") $(sed -n 's/^plan_sha256=//p' "$D/t/etc/migrator-migrated") $(sed -n 's/^donor_machine_id=//p' "$D/t/etc/migrator-migrated")"
( RUN=$D; postfix_record "$D/t" ) >> "$D/rec.out" 2>&1
assert_eq "record: called twice, still one record directory" "1" "$(find "$D/t/root" -maxdepth 1 -type d -name 'migrator-*' | wc -l)"
( RUN=$D; DRY=y; rm -f "$D/t/etc/migrator-migrated"; postfix_record "$D/t" ) > "$D/rec.dry" 2>&1
assert_eq "record: not under -n" "absent" "$([ -e "$D/t/etc/migrator-migrated" ] && echo there || echo absent)"
assert_eq "record: nothing unexpected ran" "0" "$(cat "$D/chroot.log" "$D/live.log" | grep -c UNEXPECTED)"

t_end
