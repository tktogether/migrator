#!/bin/bash
# tests/cases/inventory.sh — lib/inventory.sh: the driver's contract, every
# parser against recorded outputs under tests/fixtures/raw/ (mawk, no root),
# the modalias matcher, the donor-tree collector over a fake root built from
# the fixtures, the standalone form (--help, exit 4 with "# ERROR"), and, when
# the case runs as root, a real read-only inventory of the build host.
# Nothing here mounts, assembles or activates anything: the donor's storage
# preparation is exercised on the two-VM stand only.
# shellcheck disable=SC2016  # awk and sh -c snippets are meant to keep their $s
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/inventory.sh
. "$REPO/lib/inventory.sh"
LIB=$REPO/lib/inventory.sh
F=$REPO/tests/fixtures/raw

# --- (a) contract, silent sourcing --------------------------------------------------
for fn in inventory_run inventory_collect inventory_summary inv_records inv_field inv_lookup \
          parse_lsblk_p parse_sfdisk_dump parse_dumpe2fs parse_xfs_db parse_blkid parse_mdadm_export parse_mdadm_examine parse_fstab \
          netcfg_parse_ifcfg netcfg_parse_keyfile netcfg_parse_netplan netcfg_parse_interfaces netcfg_parse_networkd \
          netcfg_primary_ifcfg netcfg_primary_nm-keyfile netcfg_primary_netplan netcfg_primary_interfaces netcfg_primary_networkd \
          match_modalias inv_donor_tree; do
	if declare -F "$fn" >/dev/null; then _pass "defines $fn"; else _fail "defines $fn" "missing"; fi
done
out=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/inventory.sh"' _ "$REPO" 2>&1); rc=$?
assert_eq "inventory.sh sources cleanly"     0  "$rc"
assert_eq "inventory.sh is silent on source" "" "$out"

# --- record helpers -------------------------------------------------------------------
r=$(printf 'disk\tdev=/dev/sda\tsize=5\tusage=old-os:host Debian 12 mtime=2026-01-02\tlabel=')
assert_eq "inv_field plain"            /dev/sda "$(inv_field "$r" dev)"
assert_eq "inv_field value with spaces and =" "old-os:host Debian 12 mtime=2026-01-02" "$(inv_field "$r" usage)"
assert_eq "inv_field empty value"      ""       "$(inv_field "$r" label)"
assert_eq "inv_field absent key"       ""       "$(inv_field "$r" nothing)"
assert_eq "inv_field never matches the type" "" "$(inv_field "$r" disk)"
printf '# comment\n%s\ndisk\tdev=/dev/sdb\tsize=7\nfs\tdev=/dev/sda1\ttype=ext4\n' "$r" > "$RUN/mini.inv"
assert_eq "inv_records counts one type"  2 "$(inv_records "$RUN/mini.inv" disk | wc -l)"
assert_eq "inv_lookup finds a field"     7 "$(inv_lookup "$RUN/mini.inv" disk dev /dev/sdb size)"
assert_eq "inv_lookup: no match, no output" "" "$(inv_lookup "$RUN/mini.inv" disk dev /dev/sdz size)"
out=$(rec fs "dev=/dev/x" "$(printf 'label=a\tb\nc')")
assert_eq "rec sanitises tabs and newlines" "$(printf 'fs\tdev=/dev/x\tlabel=a b c')" "$out"

# --- (c) parsers over the fixtures ------------------------------------------------------
out=$(parse_lsblk_p < "$F/lsblk-P.txt")
assert_eq  "lsblk -P: one line per input line"     14 "$(printf '%s\n' "$out" | wc -l)"
l=$(printf '%s\n' "$out" | grep '^name=sdb	')
assert_eq  "lsblk -P: \\x20 and \\x22 decoded"     'Virtual disk "v2"' "$(kvget "$l" model)"
assert_eq  "lsblk -P: LOG-SEC -> log_sec"          512 "$(kvget "$l" log_sec)"
assert_eq  "lsblk -P: PHY-SEC -> phy_sec"          4096 "$(kvget "$l" phy_sec)"
l=$(printf '%s\n' "$out" | grep '^name=sda	')
assert_eq  "lsblk -P: model with plain spaces"     "WDC WD1003FZEX-00K3CA0" "$(kvget "$l" model)"
assert_eq  "lsblk -P: empty value"                 "" "$(kvget "$l" fstype)"
assert_eq  "lsblk -P: md printed once per parent"  2 "$(printf '%s\n' "$out" | grep -c '^name=md127	')"

out=$(parse_sfdisk_dump < "$F/sfdisk-d-dos.txt")
h=$(printf '%s\n' "$out" | head -1)
assert_eq  "sfdisk dos: header first"              header "$(kvget "$h" kind)"
assert_eq  "sfdisk dos: label-id"                  0x26a8e731 "$(kvget "$h" label-id)"
assert_eq  "sfdisk dos: sector-size"               512 "$(kvget "$h" sector-size)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/sda1	')
assert_eq  "sfdisk dos: start"                     2048 "$(kvget "$l" start)"
assert_eq  "sfdisk dos: size"                      997376 "$(kvget "$l" size)"
assert_eq  "sfdisk dos: type"                      83 "$(kvget "$l" type)"
assert_eq  "sfdisk dos: bootable"                  1 "$(kvget "$l" bootable)"
assert_eq  "sfdisk dos: primary"                   primary "$(kvget "$l" ptype)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/sda2	')
assert_eq  "sfdisk dos: type f is extended"        extended "$(kvget "$l" ptype)"
assert_eq  "sfdisk dos: not bootable"              0 "$(kvget "$l" bootable)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/sda5	')
assert_eq  "sfdisk dos: number 5 is logical"       logical "$(kvget "$l" ptype)"
assert_eq  "sfdisk dos: num"                       5 "$(kvget "$l" num)"
out=$(parse_sfdisk_dump < "$F/sfdisk-d-gpt.txt")
h=$(printf '%s\n' "$out" | head -1)
assert_eq  "sfdisk gpt: label"                     gpt "$(kvget "$h" label)"
assert_eq  "sfdisk gpt: label-id"                  1F2E3D4C-5B6A-4988-9A0B-1C2D3E4F5A6B "$(kvget "$h" label-id)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/nvme0n1p1	')
assert_eq  "sfdisk gpt: type GUID"                 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$(kvget "$l" type)"
assert_eq  "sfdisk gpt: uuid"                      A1B2C3D4-0001-4000-8000-000000000001 "$(kvget "$l" uuid)"
assert_eq  "sfdisk gpt: quoted name with spaces"   "EFI System Partition" "$(kvget "$l" name)"
assert_eq  "sfdisk gpt: nvme0n1p1 is number 1"     1 "$(kvget "$l" num)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/nvme0n1p2	')
assert_eq  "sfdisk gpt: quoted name with a comma"  "boot, with comma" "$(kvget "$l" name)"
assert_eq  "sfdisk gpt: every partition is primary" primary "$(kvget "$l" ptype)"
l=$(printf '%s\n' "$out" | grep 'dev=/dev/nvme0n1p3	')
assert_eq  "sfdisk gpt: LegacyBIOSBootable -> bootable" 1 "$(kvget "$l" bootable)"
assert_eq  "sfdisk gpt: attrs kept"                LegacyBIOSBootable "$(kvget "$l" attrs)"

l=$(parse_dumpe2fs < "$F/dumpe2fs-h.txt")
assert_eq  "dumpe2fs: uuid"                        5d2b1c1e-0d4e-4c0a-9b7e-7a1f2c3d4e5f "$(kvget "$l" uuid)"
assert_eq  "dumpe2fs: <none> label is empty"       "" "$(kvget "$l" label)"
assert_eq  "dumpe2fs: fssize = blocks * bs"        1073741824 "$(kvget "$l" fssize)"
assert_eq  "dumpe2fs: used = (blocks - free) * bs" 254038016 "$(kvget "$l" used)"
assert_eq  "dumpe2fs: inodes_used"                 336 "$(kvget "$l" inodes_used)"
assert_eq  "dumpe2fs: inodes_total"                65536 "$(kvget "$l" inodes_total)"
assert_eq  "dumpe2fs: bs"                          4096 "$(kvget "$l" bs)"
assert_eq  "dumpe2fs: isz (tab after the colon)"   256 "$(kvget "$l" isz)"
assert_eq  "dumpe2fs: needs_recovery -> dirty"     dirty "$(kvget "$l" state)"
assert_has "dumpe2fs: features comma list"         "has_journal,ext_attr,resize_inode,dir_index,filetype,needs_recovery,extent,64bit" "$(kvget "$l" features)"
assert_eq  "dumpe2fs: journal features"            journal_incompat_revoke,journal_64bit "$(kvget "$l" journal_features)"
assert_eq  "dumpe2fs: raw masks"                   "features:has_journal ext_attr resize_inode dir_index filetype needs_recovery extent 64bit flex_bg sparse_super large_file huge_file uninit_bg dir_nlink extra_isize|journal:journal_incompat_revoke journal_64bit" "$(kvget "$l" masks)"
l=$(sed 's/needs_recovery //; s/^Filesystem state:.*/Filesystem state:         clean/; s/^Journal features:.*/Journal features:         (none)/' "$F/dumpe2fs-h.txt" | parse_dumpe2fs)
assert_eq  "dumpe2fs: clean without needs_recovery" clean "$(kvget "$l" state)"
assert_eq  "dumpe2fs: (none) journal features -> -" - "$(kvget "$l" journal_features)"
l=$(sed 's/needs_recovery //; s/^Filesystem state:.*/Filesystem state:         clean with errors/' "$F/dumpe2fs-h.txt" | parse_dumpe2fs)
assert_eq  "dumpe2fs: clean with errors -> errors" errors "$(kvget "$l" state)"
assert_eq  "dumpe2fs: garbage input -> nothing"    "" "$(echo nonsense | parse_dumpe2fs)"

l=$(parse_xfs_db < "$F/xfs_db.txt")
assert_eq  "xfs_db: fssize = dblocks * bs"         314572800 "$(kvget "$l" fssize)"
assert_eq  "xfs_db: used"                          67256320 "$(kvget "$l" used)"
assert_eq  "xfs_db: inodes_used"                   3 "$(kvget "$l" inodes_used)"
assert_eq  "xfs_db: bs/ssz/isz/dirbs"              "4096 512 512 4096" "$(kvget "$l" bs) $(kvget "$l" ssz) $(kvget "$l" isz) $(kvget "$l" dirbs)"
assert_has "xfs_db: version names as features"     "V5,NLINK,DIRV2,ALIGN,LOGV2,EXTFLG,MOREBITS,ATTR2" "$(kvget "$l" features)"
assert_eq  "xfs_db: raw masks"                     "versionnum=0xb4a5,features2=0x18a,compat=0,ro_compat=0xf,incompat=0x2b,log_incompat=0" "$(kvget "$l" masks)"
l=$(sed 's/^dirblklog = 0/dirblklog = 2/' "$F/xfs_db.txt" | parse_xfs_db)
assert_eq  "xfs_db: dirbs = bs << dirblklog"       16384 "$(kvget "$l" dirbs)"

assert_eq  "mdadm --examine: data offset"          262144 "$(parse_mdadm_examine < "$F/mdadm-examine.txt")"
assert_eq  "mdadm --examine: 0.90 has none -> 0"   0 "$(grep -v 'Data Offset' "$F/mdadm-examine.txt" | parse_mdadm_examine)"
l=$(parse_mdadm_export < "$F/mdadm-detail-export.txt")
assert_eq  "mdadm --export: level"                 raid1 "$(kvget "$l" level)"
assert_eq  "mdadm --export: uuid"                  d2e3f4a5:b6c7d8e9:f0a1b2c3:d4e5f6a7 "$(kvget "$l" uuid)"
assert_eq  "mdadm --export: name"                  localhost:pv00 "$(kvget "$l" name)"
assert_eq  "mdadm --export: metadata"              1.2 "$(kvget "$l" metadata)"
assert_eq  "mdadm --export: members"               /dev/sda2,/dev/sdb2 "$(kvget "$l" members)"
assert_eq  "md uuid: lsblk dashes -> mdadm colons" d2e3f4a5:b6c7d8e9:f0a1b2c3:d4e5f6a7 "$(inv_md_uuid_norm d2e3f4a5-b6c7-d8e9-f0a1-b2c3d4e5f6a7)"

out=$(parse_fstab < "$F/fstab.txt")
assert_eq  "fstab: comments skipped, 8 entries"    8 "$(printf '%s\n' "$out" | wc -l)"
l=$(printf '%s\n' "$out" | grep '^spec=LABEL=DATA	')
assert_eq  "fstab: nofail detected"                1 "$(kvget "$l" nofail)"
assert_eq  "fstab: pass"                           2 "$(kvget "$l" pass)"
l=$(printf '%s\n' "$out" | grep '^spec=PARTUUID=')
assert_eq  "fstab: opts with commas kept"          umask=0077,shortname=winnt "$(kvget "$l" opts)"
assert_eq  "fstab: vfat ESP mount"                 /boot/efi "$(kvget "$l" mount)"
l=$(printf '%s\n' "$out" | grep '^spec=/swapfile	')
assert_eq  "fstab: swapfile type"                  swap "$(kvget "$l" type)"
assert_eq  "fstab: nofail=0 by default"            0 "$(kvget "$l" nofail)"
assert_eq  "resolve: UUID that does not exist -> -" - "$(inv_resolve_spec UUID=00000000-0000-0000-0000-000000000000)"
assert_eq  "resolve: swapfile path -> -"           - "$(inv_resolve_spec /swapfile)"
assert_eq  "resolve: tmpfs -> -"                   - "$(inv_resolve_spec tmpfs)"
assert_eq  "resolve: missing /dev/md0 -> -"        - "$(inv_resolve_spec /dev/md0)"

out=$(parse_blkid < "$F/blkid.txt")
l=$(printf '%s\n' "$out" | grep '^dev=/dev/nvme0n1p1	')
assert_eq  "blkid: vfat volume id as uuid"         1234-ABCD "$(kvget "$l" uuid)"
assert_eq  "blkid: type"                           vfat "$(kvget "$l" type)"
assert_eq  "blkid: PARTLABEL with spaces"          "EFI System Partition" "$(kvget "$l" partlabel)"
l=$(printf '%s\n' "$out" | grep '^dev=/dev/sda1	')
assert_eq  "blkid: raid member label with a colon" localhost:boot "$(kvget "$l" label)"

# --- network config parsers and the primary NIC per kind ------------------------------
l=$(netcfg_parse_ifcfg < "$F/ifcfg-eth0")
assert_eq  "ifcfg: iface/mac/ip/gw"  "eth0 00:25:90:ab:cd:ef 10.20.30.40/24 10.20.30.1" "$(kvget "$l" iface) $(kvget "$l" mac) $(kvget "$l" ip) $(kvget "$l" gw)"
l=$(netcfg_parse_ifcfg < "$F/ifcfg-eth1")
assert_eq  "ifcfg: NETMASK -> prefix, no gw"       "192.168.100.5/24 " "$(kvget "$l" ip) $(kvget "$l" gw)"
l=$(netcfg_parse_keyfile < "$F/eno1.nmconnection")
assert_eq  "keyfile: iface/mac/ip/gw"  "eno1 3c:ec:ef:12:34:56 185.10.20.30/26 185.10.20.1" "$(kvget "$l" iface) $(kvget "$l" mac) $(kvget "$l" ip) $(kvget "$l" gw)"
l=$(printf '[connection]\ntype=ethernet\n[ipv4]\nmethod=manual\naddresses1=10.1.1.5;24;10.1.1.1;\n' | netcfg_parse_keyfile)
assert_eq  "keyfile: legacy addresses1=ip;prefix;gw" "10.1.1.5/24 10.1.1.1" "$(kvget "$l" ip) $(kvget "$l" gw)"
out=$(netcfg_parse_netplan < "$F/netplan.yaml")
assert_eq  "netplan: one line per ethernet"        2 "$(printf '%s\n' "$out" | wc -l)"
l=$(printf '%s\n' "$out" | grep '^iface=ens1f0	')
assert_eq  "netplan: match macaddress (quoted, lowercased)" ac:1f:6b:11:22:33 "$(kvget "$l" mac)"
assert_eq  "netplan: addresses list item"          46.4.5.6/27 "$(kvget "$l" ip)"
assert_eq  "netplan: routes to default via"        46.4.5.1 "$(kvget "$l" gw)"
assert_eq  "netplan: set-name"                     ens1f0 "$(kvget "$l" setname)"
l=$(printf '%s\n' "$out" | grep '^iface=enp3s0	')
assert_eq  "netplan: dhcp interface, nameserver addresses not taken as ip" "true " "$(kvget "$l" dhcp) $(kvget "$l" ip)"
l=$(printf 'network:\n    version: 2\n    ethernets:\n        eth0:\n            addresses: [ "10.9.8.7/24" ]\n            gateway4: 10.9.8.1\n' | netcfg_parse_netplan)
assert_eq  "netplan: 4-space indent, inline list, gateway4" "eth0 10.9.8.7/24 10.9.8.1" "$(kvget "$l" iface) $(kvget "$l" ip) $(kvget "$l" gw)"
out=$(netcfg_parse_interfaces < "$F/interfaces")
assert_eq  "interfaces: lo skipped, 3 stanzas"     3 "$(printf '%s\n' "$out" | wc -l)"
l=$(printf '%s\n' "$out" | grep '^iface=eno1	family=inet	')
assert_eq  "interfaces: netmask -> prefix, gateway, hwaddress" "5.6.7.8/27 5.6.7.1 00:1b:21:aa:bb:cc" "$(kvget "$l" ip) $(kvget "$l" gw) $(kvget "$l" mac)"
l=$(printf '%s\n' "$out" | grep '^iface=eno2	')
assert_eq  "interfaces: dhcp stanza"               dhcp "$(kvget "$l" method)"
l=$(netcfg_parse_networkd < "$F/10-wired.network")
assert_eq  "networkd: Name/MACAddress/Address/[Route] Gateway" "enp1s0 52:54:00:aa:bb:cc 192.0.2.10/24 192.0.2.1" "$(kvget "$l" iface) $(kvget "$l" mac) $(kvget "$l" ip) $(kvget "$l" gw)"

# a tiny root per kind, made of the fixture files
N=$RUN/net; rm -rf "$N"
mkdir -p "$N/ifcfg/etc/sysconfig/network-scripts" "$N/nm/etc/NetworkManager/system-connections" "$N/np/etc/netplan" "$N/if/etc/network/interfaces.d" "$N/nd/etc/systemd/network"
cp "$F/ifcfg-eth0" "$F/ifcfg-eth1" "$F/ifcfg-lo" "$N/ifcfg/etc/sysconfig/network-scripts/"
cp "$F/eno1.nmconnection" "$N/nm/etc/NetworkManager/system-connections/"
cp "$F/netplan.yaml" "$N/np/etc/netplan/00-installer-config.yaml"
cp "$F/interfaces" "$N/if/etc/network/interfaces"
cp "$F/10-wired.network" "$N/nd/etc/systemd/network/"
l=$(netcfg_primary_ifcfg "$N/ifcfg")
assert_eq  "primary ifcfg: the one with GATEWAY"   "eth0 10.20.30.1 /etc/sysconfig/network-scripts/ifcfg-eth0" "$(kvget "$l" iface) $(kvget "$l" gw) $(kvget "$l" file)"
rm "$N/ifcfg/etc/sysconfig/network-scripts/ifcfg-eth0"; printf 'NETWORKING=yes\nGATEWAY=192.168.100.1\n' > "$N/ifcfg/etc/sysconfig/network"
l=$(netcfg_primary_ifcfg "$N/ifcfg")
assert_eq  "primary ifcfg: GATEWAY from /etc/sysconfig/network" "eth1 192.168.100.1" "$(kvget "$l" iface) $(kvget "$l" gw)"
l=$(netcfg_primary_nm-keyfile "$N/nm")
assert_eq  "primary keyfile"                       "eno1 185.10.20.1 3c:ec:ef:12:34:56" "$(kvget "$l" iface) $(kvget "$l" gw) $(kvget "$l" mac)"
l=$(netcfg_primary_netplan "$N/np")
assert_eq  "primary netplan: the one with the default route" "ens1f0 46.4.5.1 /etc/netplan/00-installer-config.yaml" "$(kvget "$l" iface) $(kvget "$l" gw) $(kvget "$l" file)"
l=$(netcfg_primary_interfaces "$N/if")
assert_eq  "primary interfaces: static with gateway" "eno1 5.6.7.1 5.6.7.8/27" "$(kvget "$l" iface) $(kvget "$l" gw) $(kvget "$l" ip)"
l=$(netcfg_primary_networkd "$N/nd")
assert_eq  "primary networkd"                      "enp1s0 192.0.2.1" "$(kvget "$l" iface) $(kvget "$l" gw)"
assert_eq  "netcfg_detect ifcfg"                   ifcfg      "$(netcfg_detect "$N/ifcfg")"
assert_eq  "netcfg_detect nm-keyfile"              nm-keyfile "$(netcfg_detect "$N/nm")"
assert_eq  "netcfg_detect netplan"                 netplan    "$(netcfg_detect "$N/np")"
assert_eq  "netcfg_detect interfaces"              interfaces "$(netcfg_detect "$N/if")"
assert_eq  "netcfg_detect networkd"                networkd   "$(netcfg_detect "$N/nd")"
mkdir -p "$N/lo/etc/network"; printf 'auto lo\niface lo inet loopback\n' > "$N/lo/etc/network/interfaces"
assert_eq  "netcfg_detect: interfaces with only lo is unknown" unknown "$(netcfg_detect "$N/lo")"

# --- (d) the modalias matcher --------------------------------------------------------
LIST='megaraid_sas=pci:v00001000d0000005Bsv00001028sd00001F38bc01sc04i00,virtio_blk=virtio:d00000002v00001AF4,virtio-pci=pci:v00001AF4d00001001sv00001AF4sd00000002bc01sc00i00,sd=scsi:t-0x00,bogus=pci:v0000DEADd0000BEEFsv00000000sd00000000bc00sc00i00,ext4=nothing:x'
out=$(match_modalias "$F/modules.alias" "$F/modules.builtin" "$LIST")
assert_eq  "modalias: megaraid_sas, virtio, scsi found; unrelated missed; builtin seen" \
	"megaraid_sas:megaraid_sas,virtio_blk:virtio_blk,virtio-pci:virtio_pci,sd:sd_mod,bogus:-,ext4:builtin" "$out"
assert_eq  "modalias: class-only ahci alias (bc01sc06i01)" "ahci:ahci" "$(match_modalias "$F/modules.alias" /nonexistent 'ahci=pci:v00008086d0000A282sv00001028sd000007A2bc01sc06i01')"
assert_eq  "modalias: empty list -> -"             - "$(match_modalias "$F/modules.alias" "$F/modules.builtin" '')"
assert_eq  "modalias: missing aliases file -> all -" "x:-" "$(match_modalias /nonexistent /nonexistent 'x=pci:v0')"

# --- the donor tree collector over a fake root built from the fixtures -------------------
T=$RUN/tree; rm -rf "$T"
K=4.18.0-513.el8.x86_64
mkdir -p "$T/etc/sysconfig/network-scripts" "$T/etc/default/grub.d" "$T/etc/kernel" "$T/boot/loader/entries" "$T/boot/grub2" \
	"$T/lib/modules/$K" "$T/etc/lvm/devices" "$T/etc/selinux" "$T/etc/cloud" "$T/sbin" "$T/usr/bin" "$T/etc/udev/rules.d" \
	"$T/etc/NetworkManager/system-connections" "$T/boot/efi/EFI/rocky" "$T/data"
cp "$F/fstab.txt" "$T/etc/fstab"
cp "$F/ifcfg-eth0" "$F/ifcfg-eth1" "$F/ifcfg-lo" "$T/etc/sysconfig/network-scripts/"
cp "$F/eno1.nmconnection" "$T/etc/NetworkManager/system-connections/"
printf 'NETWORKING=yes\n' > "$T/etc/sysconfig/network"
printf 'NAME="Rocky Linux"\nVERSION="8.9 (Green Obsidian)"\nID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="8.9"\nPRETTY_NAME="Rocky Linux 8.9 (Green Obsidian)"\n' > "$T/etc/os-release"
echo donor.example > "$T/etc/hostname"; echo 0123456789abcdef0123456789abcdef > "$T/etc/machine-id"
touch "$T/sbin/init" "$T/usr/bin/dracut"; chmod +x "$T/usr/bin/dracut"
printf 'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX="crashkernel=auto resume=/dev/mapper/centos-swap rd.md.uuid=d2e3f4a5:b6c7d8e9:f0a1b2c3:d4e5f6a7 net.ifnames=0 biosdevname=0"\nGRUB_CMDLINE_LINUX_DEFAULT='"'"'quiet'"'"'\n' > "$T/etc/default/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=ttyS0,115200"\n' > "$T/etc/default/grub.d/50-serial.cfg"
printf 'root=/dev/mapper/centos-root ro\n' > "$T/etc/kernel/cmdline"
printf 'title Rocky Linux (%s) 8.9\nversion %s\nlinux /vmlinuz-%s\ninitrd /initramfs-%s.img $tuned_initrd\noptions $kernelopts $tuned_params\nid rocky-20240101-%s\n' "$K" "$K" "$K" "$K" "$K" > "$T/boot/loader/entries/0123456789abcdef0123456789abcdef-$K.conf"
printf '# GRUB Environment Block\nsaved_entry=0123456789abcdef0123456789abcdef-%s\nkernelopts=root=/dev/mapper/centos-root ro crashkernel=auto resume=/dev/mapper/centos-swap net.ifnames=0\nboot_success=0\n' "$K" > "$T/boot/grub2/grubenv"
printf '### BEGIN /etc/grub.d/00_header ###\n' > "$T/boot/grub2/grub.cfg"
touch "$T/boot/vmlinuz-$K" "$T/boot/initramfs-$K.img" "$T/boot/vmlinuz-0-rescue-0123456789abcdef0123456789abcdef"
touch "$T/lib/modules/$K/modules.dep"; cp "$F/modules.alias" "$F/modules.builtin" "$T/lib/modules/$K/"
printf '# mdadm.conf written out by anaconda\nMAILADDR root\nAUTO +imsm +1.x -all\nARRAY /dev/md/boot level=raid1 num-devices=2 UUID=c1c9c2a9:6b6f1a0e:12ff4e5c:1a0f4b2b\nARRAY /dev/md/pv00 level=raid1 num-devices=2 UUID=d2e3f4a5:b6c7d8e9:f0a1b2c3:d4e5f6a7\n' > "$T/etc/mdadm.conf"
printf 'devices {\n\t# filter = [ "a|.*|" ]\n\tglobal_filter = [ "a|^/dev/md|", "r|.*|" ]\n\tuse_devicesfile = 1\n}\n' > "$T/etc/lvm/lvm.conf"; touch "$T/etc/lvm/devices/system.devices"
printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' > "$T/etc/selinux/config"
touch "$T/etc/cloud/cloud.cfg"
truncate -s 1048576 "$T/swapfile"
printf '# PCI device 0x8086:0x1521 (igb)\nSUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="00:25:90:AB:CD:EF", ATTR{type}=="1", KERNEL=="eth*", NAME="eth0"\n' > "$T/etc/udev/rules.d/70-persistent-net.rules"

INV_ROOT=$T; INV_ROOT_DEV=/dev/mapper/centos-root
INV_MODALIAS='megaraid_sas=pci:v00001000d0000005Bsv00001028sd00001F38bc01sc04i00,igb=pci:v00008086d00001521sv00008086sd00000001bc02sc00i00'
inv_donor_tree > "$RUN/donor-tree.inv" 2> "$RUN/donor-tree.err"; rc=$?
INV_ROOT=; INV_ROOT_DEV=-; INV_MODALIAS=
assert_eq  "donor tree: exit 0"                    0 "$rc"
assert_eq  "donor tree: no warnings"               "" "$(cat "$RUN/donor-tree.err")"
assert_eq  "donor tree: record order"              "os kernel fstab cmdline mdconf lvmconf swapfile netcfg" "$(cut -f1 "$RUN/donor-tree.inv" | uniq | tr '\n' ' ' | sed 's/ $//')"
os=$(inv_records "$RUN/donor-tree.inv" os)
assert_eq  "os: root"                              /dev/mapper/centos-root "$(inv_field "$os" root)"
assert_eq  "os: id/like/version"                   "rocky|rhel centos fedora|8.9" "$(inv_field "$os" id)|$(inv_field "$os" like)|$(inv_field "$os" version)"
assert_eq  "os: family rhel"                       rhel "$(inv_field "$os" family)"
assert_eq  "os: pretty"                            "Rocky Linux 8.9 (Green Obsidian)" "$(inv_field "$os" pretty)"
assert_eq  "os: hostname"                          donor.example "$(inv_field "$os" hostname)"
assert_eq  "os: initramfs dracut"                  dracut "$(inv_field "$os" initramfs)"
assert_eq  "os: grub2 + grubcfg"                   "grub2 /boot/grub2/grub.cfg" "$(inv_field "$os" grub) $(inv_field "$os" grubcfg)"
assert_eq  "os: bls"                               1 "$(inv_field "$os" bls)"
assert_eq  "os: efidir from fstab"                 /boot/efi "$(inv_field "$os" efidir)"
assert_eq  "os: selinux"                           enforcing "$(inv_field "$os" selinux)"
assert_eq  "os: cloudinit"                         1 "$(inv_field "$os" cloudinit)"
assert_eq  "os: netcfg ifcfg wins over keyfile"    ifcfg "$(inv_field "$os" netcfg)"
assert_eq  "os: primary nic/mac/ip/gw"             "eth0 00:25:90:ab:cd:ef 10.20.30.40/24 10.20.30.1" "$(inv_field "$os" primary_nic) $(inv_field "$os" primary_mac) $(inv_field "$os" primary_ip) $(inv_field "$os" gw)"
assert_eq  "os: ifnames=kernel from net.ifnames=0" kernel "$(inv_field "$os" ifnames)"
assert_eq  "os: biosdevname absent -> 0"           0 "$(inv_field "$os" biosdevname)"
assert_eq  "os: machine_id"                        0123456789abcdef0123456789abcdef "$(inv_field "$os" machine_id)"
assert_eq  "os: kernels counts only kernels with modules" 1 "$(inv_field "$os" kernels)"
k=$(inv_records "$RUN/donor-tree.inv" kernel)
assert_eq  "kernel: one record (rescue kernel skipped)" 1 "$(printf '%s\n' "$k" | wc -l)"
assert_eq  "kernel: version/vmlinuz/initrd"        "$K /boot/vmlinuz-$K /boot/initramfs-$K.img" "$(inv_field "$k" version) $(inv_field "$k" vmlinuz) $(inv_field "$k" initrd)"
assert_eq  "kernel: aliases/builtin paths"         "/lib/modules/$K/modules.alias /lib/modules/$K/modules.builtin" "$(inv_field "$k" aliases) $(inv_field "$k" builtin)"
assert_eq  "kernel: pci_drivers from --modalias"   "megaraid_sas:megaraid_sas,igb:-" "$(inv_field "$k" pci_drivers)"
assert_eq  "fstab: 8 records"                      8 "$(inv_records "$RUN/donor-tree.inv" fstab | wc -l)"
assert_eq  "fstab: nofail"                         1 "$(inv_lookup "$RUN/donor-tree.inv" fstab spec LABEL=DATA nofail)"
assert_eq  "fstab: unresolvable UUID -> dev=-"     - "$(inv_lookup "$RUN/donor-tree.inv" fstab spec UUID=5d2b1c1e-0d4e-4c0a-9b7e-7a1f2c3d4e5f dev)"
assert_eq  "fstab: swapfile spec -> dev=-"         - "$(inv_lookup "$RUN/donor-tree.inv" fstab spec /swapfile dev)"
assert_eq  "cmdline: 6 sources"                    6 "$(inv_records "$RUN/donor-tree.inv" cmdline | wc -l)"
assert_eq  "cmdline: grub-default GRUB_CMDLINE_LINUX (double quotes stripped)" "crashkernel=auto resume=/dev/mapper/centos-swap rd.md.uuid=d2e3f4a5:b6c7d8e9:f0a1b2c3:d4e5f6a7 net.ifnames=0 biosdevname=0" "$(inv_lookup "$RUN/donor-tree.inv" cmdline key GRUB_CMDLINE_LINUX value)"
assert_eq  "cmdline: single quotes stripped too"   quiet "$(awk -F'\t' '$1=="cmdline" && $2=="source=grub-default" && $3=="key=GRUB_CMDLINE_LINUX_DEFAULT" {sub(/^value=/,"",$4); print $4}' "$RUN/donor-tree.inv")"
assert_eq  "cmdline: grub.d file"                  "\$GRUB_CMDLINE_LINUX_DEFAULT console=ttyS0,115200" "$(inv_lookup "$RUN/donor-tree.inv" cmdline source grub.d:50-serial.cfg value)"
assert_eq  "cmdline: /etc/kernel/cmdline"          "root=/dev/mapper/centos-root ro" "$(inv_lookup "$RUN/donor-tree.inv" cmdline source kernel-cmdline value)"
assert_eq  "cmdline: BLS options"                  "\$kernelopts \$tuned_params" "$(inv_lookup "$RUN/donor-tree.inv" cmdline source "bls:0123456789abcdef0123456789abcdef-$K.conf" value)"
assert_eq  "cmdline: grubenv kernelopts"           "root=/dev/mapper/centos-root ro crashkernel=auto resume=/dev/mapper/centos-swap net.ifnames=0" "$(inv_lookup "$RUN/donor-tree.inv" cmdline source grubenv value)"
m=$(inv_records "$RUN/donor-tree.inv" mdconf)
assert_eq  "mdconf: file and count"                "/etc/mdadm.conf 2" "$(inv_field "$m" file) $(inv_field "$m" arrays)"
assert_has "mdconf: ARRAY lines joined with ;"     "UUID=c1c9c2a9:6b6f1a0e:12ff4e5c:1a0f4b2b;ARRAY /dev/md/pv00" "$(inv_field "$m" lines)"
m=$(inv_records "$RUN/donor-tree.inv" lvmconf)
assert_eq  "lvmconf: commented filter ignored, global_filter raw, devicesfile" "- [ \"a|^/dev/md|\", \"r|.*|\" ] 1 1" "$(inv_field "$m" filter) $(inv_field "$m" global_filter) $(inv_field "$m" use_devicesfile) $(inv_field "$m" devices_file)"
m=$(inv_records "$RUN/donor-tree.inv" swapfile)
assert_eq  "swapfile: path/size/opts"              "/swapfile 1048576 sw" "$(inv_field "$m" path) $(inv_field "$m" size) $(inv_field "$m" opts)"
assert_eq  "netcfg: 4 records (2 ifcfg, keyfile, udev; no lo)" 4 "$(inv_records "$RUN/donor-tree.inv" netcfg | wc -l)"
assert_eq  "netcfg: primary ifcfg-eth0"            "1 00:25:90:ab:cd:ef" "$(inv_lookup "$RUN/donor-tree.inv" netcfg file /etc/sysconfig/network-scripts/ifcfg-eth0 primary) $(inv_lookup "$RUN/donor-tree.inv" netcfg file /etc/sysconfig/network-scripts/ifcfg-eth0 mac)"
assert_eq  "netcfg: ifcfg-eth1 not primary"        0 "$(inv_lookup "$RUN/donor-tree.inv" netcfg file /etc/sysconfig/network-scripts/ifcfg-eth1 primary)"
assert_eq  "netcfg: keyfile record"                "nm-keyfile eno1" "$(inv_lookup "$RUN/donor-tree.inv" netcfg file /etc/NetworkManager/system-connections/eno1.nmconnection kind) $(inv_lookup "$RUN/donor-tree.inv" netcfg file /etc/NetworkManager/system-connections/eno1.nmconnection iface)"
assert_eq  "netcfg: udev-persistent iface/mac"     "eth0 00:25:90:ab:cd:ef" "$(inv_lookup "$RUN/donor-tree.inv" netcfg kind udev-persistent iface) $(inv_lookup "$RUN/donor-tree.inv" netcfg kind udev-persistent mac)"
# a Debian-style tree: deb family, initramfs-tools, interfaces, predictable names
D=$RUN/deb; rm -rf "$D"; mkdir -p "$D/etc/network" "$D/etc/initramfs-tools" "$D/boot/grub" "$D/etc/default" "$D/sbin" "$D/usr/sbin"
printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$D/etc/os-release"
printf 'UUID=1 / ext4 errors=remount-ro 0 1\n' > "$D/etc/fstab"; cp "$F/interfaces" "$D/etc/network/interfaces"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_CMDLINE_LINUX=""\n' > "$D/etc/default/grub"; touch "$D/usr/sbin/biosdevname"
INV_ROOT=$D; inv_donor_tree > "$RUN/deb.inv" 2>/dev/null; INV_ROOT=
os=$(inv_records "$RUN/deb.inv" os)
assert_eq  "deb tree: family/initramfs/netcfg/primary" "deb initramfs-tools interfaces eno1" "$(inv_field "$os" family) $(inv_field "$os" initramfs) $(inv_field "$os" netcfg) $(inv_field "$os" primary_nic)"
assert_eq  "deb tree: predictable names, biosdevname present" "predictable 1" "$(inv_field "$os" ifnames) $(inv_field "$os" biosdevname)"
assert_eq  "deb tree: empty GRUB_CMDLINE_LINUX still a record" "" "$(inv_lookup "$RUN/deb.inv" cmdline key GRUB_CMDLINE_LINUX value)"
assert_eq  "deb tree: no mdadm.conf -> file=-"     "- 0" "$(inv_lookup "$RUN/deb.inv" mdconf arrays 0 file) $(inv_lookup "$RUN/deb.inv" mdconf arrays 0 arrays)"
assert_eq  "deb tree: kernels=0 warns, no kernel records" 0 "$(inv_records "$RUN/deb.inv" kernel | wc -l)"

# --- (e) the standalone form ------------------------------------------------------------
out=$(bash "$LIB" --help 2>&1); rc=$?
assert_eq  "--help exits 0"                        0 "$rc"
assert_has "--help prints the usage"               "usage: inventory.sh --role donor|recipient" "$out"
assert_has "--help lists --raw"                    "--raw DIR" "$out"
out=$(bash "$LIB" 2>&1); rc=$?
assert_eq  "no --role exits 2"                     2 "$rc"
out=$(bash "$LIB" --role bogus 2>&1); rc=$?
assert_eq  "bad --role exits 2"                    2 "$rc"
out=$(bash "$LIB" --frob 2>&1); rc=$?
assert_eq  "unknown flag exits 2"                  2 "$rc"
# the "bash -s" form: BASH_SOURCE is empty, the script must still run its main
out=$(bash -s -- --help < "$LIB" 2>&1); rc=$?
assert_eq  "bash -s --help exits 0"                0 "$rc"
assert_has "bash -s --help prints usage"           "usage: inventory.sh" "$out"
# a donor tree that is not there: exit 4, reason on stderr and as the last stdout line
bash "$LIB" --role donor --root "$RUN/nonexistent" > "$RUN/sa.out" 2> "$RUN/sa.err"; rc=$?
assert_eq  "standalone donor, missing tree: exit 4" 4 "$rc"
assert_has "standalone: last stdout line is # ERROR" "# ERROR: donor tree $RUN/nonexistent is not a directory" "$(tail -1 "$RUN/sa.out")"
assert_has "standalone: reason on stderr too"      "ERROR: donor tree" "$(cat "$RUN/sa.err")"
assert_has "standalone: host record was still produced" "$(printf 'host\trole=donor')" "$(cat "$RUN/sa.out")"
# the fake tree through the standalone form with --raw: records plus the raw copies
bash "$LIB" --role donor --root "$T" --raw "$RUN/raw" --modalias 'sd=scsi:t-0x00' > "$RUN/sa2.out" 2> "$RUN/sa2.err"; rc=$?
assert_eq  "standalone donor --root: exit 0"       0 "$rc"
assert_fail "standalone donor --root: no # ERROR"  grep -q '^# ERROR' "$RUN/sa2.out"
assert_eq  "standalone donor --root: os record"    rhel "$(inv_lookup "$RUN/sa2.out" os id rocky family)"
assert_eq  "standalone donor --root: modalias matched" "sd:sd_mod" "$(inv_lookup "$RUN/sa2.out" kernel version "$K" pci_drivers)"
assert_ok  "raw: lsblk-P.txt kept"                 test -s "$RUN/raw/lsblk-P.txt"
assert_ok  "raw: proc-cmdline.txt kept"            test -s "$RUN/raw/proc-cmdline.txt"
assert_ok  "raw: tree/etc/fstab copied"            test -s "$RUN/raw/tree/etc/fstab"
assert_ok  "raw: tree/etc/os-release copied"       test -s "$RUN/raw/tree/etc/os-release"
assert_ok  "raw: tree/etc/default/grub copied"     test -s "$RUN/raw/tree/etc/default/grub"
assert_ok  "raw: grub.d copied"                    test -s "$RUN/raw/tree/etc/default/grub.d/50-serial.cfg"
assert_ok  "raw: BLS entry copied"                 test -s "$RUN/raw/tree/boot/loader/entries/0123456789abcdef0123456789abcdef-$K.conf"
assert_ok  "raw: grubenv copied"                   test -s "$RUN/raw/tree/boot/grub2/grubenv"
assert_ok  "raw: mdadm.conf copied"                test -s "$RUN/raw/tree/etc/mdadm.conf"
assert_ok  "raw: lvm.conf copied"                  test -s "$RUN/raw/tree/etc/lvm/lvm.conf"
assert_ok  "raw: ifcfg copied"                     test -s "$RUN/raw/tree/etc/sysconfig/network-scripts/ifcfg-eth0"
assert_ok  "raw: modules.alias copied"             test -s "$RUN/raw/tree/lib/modules/$K/modules.alias"
assert_ok  "raw: modules.builtin copied"           test -s "$RUN/raw/tree/lib/modules/$K/modules.builtin"
assert_fail "raw: empty .err files are not kept"   sh -c 'for f in "$1"/*.err; do [ -e "$f" ] && [ ! -s "$f" ] && exit 0; done; exit 1' _ "$RUN/raw"

# --- (b) a real read-only inventory of this box (root only) -------------------------------
if [ "$(id -u)" != 0 ]; then
	skip "inventory_collect recipient on the build host" "not root"
else
	timeout 120 bash -c '. "$1/lib/common.sh"; . "$1/lib/inventory.sh"; inventory_collect recipient' _ "$REPO" > "$RUN/host.inv" 2> "$RUN/host.err"; rc=$?
	assert_eq  "inventory_collect recipient exits 0 (under 120 s)" 0 "$rc"
	h=$(inv_records "$RUN/host.inv" host)
	assert_eq  "host: exactly one record"          1 "$(printf '%s\n' "$h" | wc -l)"
	assert_eq  "host: role=recipient"              recipient "$(inv_field "$h" role)"
	case $(inv_field "$h" fw) in bios|uefi) _pass "host: fw=bios|uefi";; *) _fail "host: fw=bios|uefi" "got '$(inv_field "$h" fw)'";; esac
	case $(inv_field "$h" secureboot) in 0|1) _pass "host: secureboot=0|1";; *) _fail "host: secureboot=0|1" "got '$(inv_field "$h" secureboot)'";; esac
	case $(inv_field "$h" ram) in ''|*[!0-9]*) _fail "host: ram numeric" "got '$(inv_field "$h" ram)'";; *) _pass "host: ram numeric";; esac
	case $(inv_field "$h" awk) in mawk|gawk) _pass "host: awk named";; *) _fail "host: awk named" "got '$(inv_field "$h" awk)'";; esac
	assert_eq  "host: hostname is this box's"      "$(cat /proc/sys/kernel/hostname)" "$(inv_field "$h" hostname)"
	d=$(inv_records "$RUN/host.inv" disk | head -1)
	if [ -z "$d" ]; then
		skip "disk records" "this box has no block disk (container?)"
	else
		case $(inv_field "$d" size) in ''|*[!0-9]*) _fail "disk: size numeric" "got '$(inv_field "$d" size)'";; *) _pass "disk: size numeric";; esac
		case $(inv_field "$d" drivers) in ''|-) _fail "disk: drivers non-empty" "got '$(inv_field "$d" drivers)'";; *) _pass "disk: drivers non-empty";; esac
		case $(inv_field "$d" modalias) in pci:*|*,pci:*) _pass "disk: modalias chain ends in pci:";; *) _fail "disk: modalias chain ends in pci:" "got '$(inv_field "$d" modalias)'";; esac
		case $(inv_field "$d" usage) in free|old-os:*|md:*|lvm:*|fs:*|parts:*|sig:*) _pass "disk: usage is a known form";; *) _fail "disk: usage is a known form" "got '$(inv_field "$d" usage)'";; esac
	fi
	# shape: known types only, every field key=value, a fixed field count per type
	assert_ok  "every record: known type, every field key=value" \
		awk -F'\t' '/^#/ {next} { if ($1 !~ /^(host|disk|part|md|pv|vg|lv|fs|swap|nic)$/) bad++; for (i=2;i<=NF;i++) if ($i !~ /^[a-z_]+=/) bad++ } END {exit bad>0}' "$RUN/host.inv"
	assert_ok  "every record: field count consistent per type" \
		awk -F'\t' '/^#/ {next} { if ($1 in n && n[$1]!=NF) bad++; n[$1]=NF } END {exit bad>0}' "$RUN/host.inv"
	assert_ok  "every record: no tab-free violation (no empty fields)" \
		awk -F'\t' '/^#/ {next} { for (i=1;i<=NF;i++) if ($i=="") bad++ } END {exit bad>0}' "$RUN/host.inv"
	assert_eq  "record order follows format.md" "$(cut -f1 "$RUN/host.inv" | grep -v '^#' | uniq | tr '\n' ' ' | sed 's/ $//')" \
		"$(cut -f1 "$RUN/host.inv" | grep -v '^#' | uniq | awk '{o["host"]=1;o["disk"]=2;o["part"]=3;o["md"]=4;o["pv"]=5;o["vg"]=6;o["lv"]=7;o["fs"]=8;o["swap"]=9;o["nic"]=10; print o[$1], $1}' | sort -n | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//')"
	n=$(inv_records "$RUN/host.inv" nic | wc -l)
	if [ "$n" -gt 0 ]; then _pass "nic: at least one record"; else _fail "nic: at least one record" "none"; fi
	assert_ok  "nic: every mac looks like a mac"   awk -F'\t' '$1=="nic" { for (i=2;i<=NF;i++) if ($i ~ /^mac=/ && $i !~ /^mac=([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/ && $i != "mac=-") bad++ } END {exit bad>0}' "$RUN/host.inv"
	for f in $(inv_records "$RUN/host.inv" fs | while IFS= read -r r; do inv_field "$r" type; done | sort -u); do
		case $f in ext[234]) r=$(inv_records "$RUN/host.inv" fs | grep "	type=$f	" | head -1)
			assert_has "fs $f: raw masks recorded"   "features:" "$(inv_field "$r" masks)"
			case $(inv_field "$r" state) in clean|dirty|errors) _pass "fs $f: state known";; *) _fail "fs $f: state known" "got '$(inv_field "$r" state)'";; esac ;;
		esac
	done
	out=$(inventory_summary "$RUN/host.inv")
	assert_has "inventory_summary prints the hostname" "$(cat /proc/sys/kernel/hostname)" "$out"
	assert_has "inventory_summary prints a disk line" "disk: /dev/" "$out"
	# the modalias list handed to the donor: name=modalias pairs from disk and nic records
	out=$(inv_modalias_list "$RUN/host.inv")
	case $out in ''|*[!A-Za-z0-9_=:,.*-]*) _fail "inv_modalias_list: name=modalias pairs" "got '$out'";; *=*:*) _pass "inv_modalias_list: name=modalias pairs";; *) _fail "inv_modalias_list: name=modalias pairs" "got '$out'";; esac
	# the driver's entry point for this side, with -o raw=DIR
	OPT[raw]=$RUN/rawdir
	( inventory_run recipient > "$RUN/run.out" 2> "$RUN/run.err" ); rc=$?
	OPT[raw]=
	assert_eq  "inventory_run recipient exits 0"   0 "$rc"
	assert_ok  "inventory_run: \$RUN/recipient.inv written" test -s "$RUN/recipient.inv"
	assert_has "inventory_run: raw inventory on stdout" "$(printf 'host\trole=recipient')" "$(cat "$RUN/run.out")"
	assert_has "inventory_run: summary on stderr"  "host: $(cat /proc/sys/kernel/hostname)" "$(cat "$RUN/run.err")"
	assert_ok  "inventory_run: -o raw=DIR keeps recipient/lsblk-P.txt" test -s "$RUN/rawdir/recipient/lsblk-P.txt"
	# the standalone form, as it runs on a donor (recipient role: no storage changes)
	timeout 120 bash "$LIB" --role recipient > "$RUN/sa3.out" 2> "$RUN/sa3.err"; rc=$?
	assert_eq  "standalone --role recipient exits 0" 0 "$rc"
	assert_eq  "standalone: same record types as sourced" "$(cut -f1 "$RUN/host.inv" | grep -v '^#' | uniq | tr '\n' ' ')" "$(cut -f1 "$RUN/sa3.out" | grep -v '^#' | uniq | tr '\n' ' ')"
	assert_fail "standalone: nothing but records and # lines on stdout" grep -qvE '^(#|host|disk|part|md|pv|vg|lv|fs|swap|nic)' "$RUN/sa3.out"
fi

t_end
