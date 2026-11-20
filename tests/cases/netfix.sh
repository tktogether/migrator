#!/bin/bash
# tests/cases/netfix.sh — lib/netfix.sh: the pure rewriters on the recorded samples
# of tests/fixtures/raw (ifupdown, netplan, networkd, ifcfg, NetworkManager keyfile)
# and on small inline ones (aliases, vlans, bridges, bonds, globs, .link files), the
# MAC pass in its three forms (known donor MAC, the donor's other hardware MACs
# inside the primary NIC's config, unknown donor MAC), and netfix_run end to end
# over throwaway trees with the [network] section of real fixture plans: rename +
# MAC + udev pin + the list-only warnings, idempotence and -n. No chroot, no
# device, no mount: netfix only edits files under $TARGET_MNT.
# shellcheck disable=SC2016,SC2030,SC2031,SC2094  # snippets handed to eval keep their $s; RUN/DRY/TARGET_MNT change in subshells on purpose; "cmd < f | diff f -" only reads f
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
RAW=$FIX/raw
W=$RUN/nf-work; mkdir -p "$W"
TAB=$(printf '\t')
NEWMAC=52:54:00:cc:dd:01
lines() { paste -sd'|' -; }

# --- (a) contract ---------------------------------------------------------------------------------
for fn in netfix_run nf_interfaces_rename nf_netplan_rename nf_networkd_rename nf_ifcfg_rename nf_keyfile_rename \
          nf_route_rename nf_mac_rewrite nf_mac_list nf_is_primary nf_udev_rules; do
	if declare -F "$fn" >/dev/null; then _pass "defines $fn"; else _fail "defines $fn" "missing"; fi
done

# --- (b) ifupdown ------------------------------------------------------------------------------------
nf_interfaces_rename eno1 eth0 < "$RAW/interfaces" > "$W/if.out"
assert_eq "interfaces: allow-hotplug and both iface stanzas renamed" "allow-hotplug eth0|iface eth0 inet static|iface eth0 inet6 static" "$(grep 'eth0' "$W/if.out" | lines)"
assert_eq "interfaces: exactly those three lines changed" "3" "$(diff "$RAW/interfaces" "$W/if.out" | grep -c '^>')"
assert_eq "interfaces: eno2 and lo untouched" "auto lo|iface lo inet loopback|auto eno2|iface eno2 inet dhcp" "$(grep -E ' (lo|eno2)( |$)' "$W/if.out" | lines)"
assert_eq "interfaces: renaming twice equals once" "$(cat "$W/if.out")" "$(nf_interfaces_rename eno1 eth0 < "$W/if.out")"
cat > "$W/if2.in" <<'EOF'
auto eno1 eno1:0 eno1.100
iface eno1 inet manual
iface eno1:0 inet static
	address 192.0.2.4/24
iface eno1.100 inet static
	vlan-raw-device eno1
	post-up ip route add 10.0.0.0/8 via 192.0.2.1 dev eno1
	up ip addr add 192.0.2.9/32 dev eno1:0
auto br0
iface br0 inet static
	bridge_ports eno1 eno10
	bridge-ports eno1.100
allow-auto bond0
iface bond0 inet manual
	bond-slaves eno1 eno2
	bond-primary eno1
iface eno10 inet dhcp
# auto eno1 stays a comment
	dns-search eno1
EOF
cat > "$W/if2.want" <<'EOF'
auto eth0 eth0:0 eth0.100
iface eth0 inet manual
iface eth0:0 inet static
	address 192.0.2.4/24
iface eth0.100 inet static
	vlan-raw-device eth0
	post-up ip route add 10.0.0.0/8 via 192.0.2.1 dev eth0
	up ip addr add 192.0.2.9/32 dev eth0:0
auto br0
iface br0 inet static
	bridge_ports eth0 eno10
	bridge-ports eth0.100
allow-auto bond0
iface bond0 inet manual
	bond-slaves eth0 eno2
	bond-primary eth0
iface eno10 inet dhcp
# auto eno1 stays a comment
	dns-search eno1
EOF
assert_eq "interfaces: aliases (X:N), vlans (X.N), bridge_ports, bond-slaves, vlan-raw-device, up/post-up commands; eno10, comments and other options untouched" \
	"$(cat "$W/if2.want")" "$(nf_interfaces_rename eno1 eth0 < "$W/if2.in")"
assert_eq "interfaces: MAC of the renamed stanza (hwaddress ether), case kept" "${TAB}hwaddress ether 52:54:00:CC:DD:01" "$(nf_mac_rewrite 00:1b:21:aa:bb:cc $NEWMAC eth0 < "$W/if.out" | grep hwaddress)"
assert_eq "interfaces: scope is the stanza: another iface's MAC stays" "$(cat "$RAW/interfaces")" "$(nf_mac_rewrite 00:1b:21:aa:bb:cc $NEWMAC eno2 < "$RAW/interfaces")"
assert_eq "interfaces: hwaddress SETS a MAC, so an unknown donor MAC does not touch it" "" "$(nf_mac_list '*' $NEWMAC eno1 < "$RAW/interfaces")"

# --- (c) netplan ------------------------------------------------------------------------------------------
nf_netplan_rename ens1f0 eth0 < "$RAW/netplan.yaml" > "$W/np.out"
assert_eq "netplan: key renamed with its indentation" "    eth0:" "$(sed -n 10p "$W/np.out")"
assert_eq "netplan: set-name removed" "0" "$(grep -c 'set-name' "$W/np.out")"
assert_eq "netplan: only those two lines differ" "10c10|13d12" "$(diff "$RAW/netplan.yaml" "$W/np.out" | grep '^[0-9]' | lines)"
assert_eq "netplan: the other NIC's block untouched" "$(sed -n '6,9p' "$RAW/netplan.yaml")" "$(sed -n '6,9p' "$W/np.out")"
assert_eq "netplan: match macaddress replaced in the primary block (quotes and case kept)" '        macaddress: "52:54:00:CC:DD:01"' "$(nf_mac_rewrite ac:1f:6b:11:22:33 $NEWMAC eth0 < "$W/np.out" | grep macaddress)"
assert_eq "netplan: unknown donor MAC: the match of the primary block is what gets replaced" "ac:1f:6b:11:22:33" "$(nf_mac_list '*' $NEWMAC eth0 < "$W/np.out")"
assert_eq "netplan: ... not another block's" "" "$(nf_mac_list '*' $NEWMAC enp3s0 < "$W/np.out")"
assert_eq "netplan: renaming twice equals once" "$(cat "$W/np.out")" "$(nf_netplan_rename ens1f0 eth0 < "$W/np.out")"
cat > "$W/np2.in" <<'EOF'
network:
  version: 2
  ethernets:
    "eno1":
      dhcp4: false   # static below
      set-name: lan0
      macaddress: aa:bb:cc:00:00:01
    id1:
      match: {macaddress: "aa:bb:cc:00:00:02"}
      set-name: eno1
    eno10: {dhcp4: true}
  bonds:
    bond0:
      interfaces: [eno1, eno10]
      addresses:
        - 192.0.2.5/24
  bridges:
    br0:
      interfaces:
        - eno1
        - "eno1"
        - eno10
      addresses:
      - eno1
  vlans:
    eno1.100:
      id: 100
      link: eno1
EOF
cat > "$W/np2.want" <<'EOF'
network:
  version: 2
  ethernets:
    "eth0":
      dhcp4: false   # static below
      macaddress: aa:bb:cc:00:00:01
    id1:
      match: {macaddress: "aa:bb:cc:00:00:02"}
    eno10: {dhcp4: true}
  bonds:
    bond0:
      interfaces: [eth0, eno10]
      addresses:
        - 192.0.2.5/24
  bridges:
    br0:
      interfaces:
        - eth0
        - "eth0"
        - eno10
      addresses:
      - eno1
  vlans:
    eno1.100:
      id: 100
      link: eth0
EOF
assert_eq "netplan: quoted key, set-name of the block and 'set-name: OLD' elsewhere dropped, interfaces: [..] and '- OLD' lists, link:; eno10 and other lists untouched" \
	"$(cat "$W/np2.want")" "$(nf_netplan_rename eno1 eth0 < "$W/np2.in")"
nf_netplan_rename eno1 eth0 < "$W/np2.in" > "$W/np2.out"
assert_eq "netplan: macaddress outside match: SETS a MAC: a known MAC follows, an unknown one is left" "      macaddress: $NEWMAC|" \
	"$(nf_mac_rewrite aa:bb:cc:00:00:01 $NEWMAC eth0 < "$W/np2.out" | grep -m1 macaddress)|$(nf_mac_list '*' $NEWMAC eth0 < "$W/np2.out")"
assert_eq "netplan: flow-style match: {macaddress: ..} is a match" "aa:bb:cc:00:00:02" "$(nf_mac_list '*' $NEWMAC id1 < "$W/np2.out")"

# --- (d) systemd-networkd ------------------------------------------------------------------------------------
nf_networkd_rename enp1s0 eth0 < "$RAW/10-wired.network" > "$W/nd.out"
assert_eq "networkd: [Match] Name= renamed, nothing else" "2c2|Name=eth0" "$(diff "$RAW/10-wired.network" "$W/nd.out" | grep '^[0-9]' | lines)|$(sed -n 2p "$W/nd.out")"
assert_eq "networkd: [Match] MACAddress= replaced" "MACAddress=$NEWMAC" "$(nf_mac_rewrite 52:54:00:AA:BB:CC $NEWMAC < "$W/nd.out" | grep MACAddress)"
assert_eq "networkd: old MAC is matched case-insensitively, other lines intact" "1" "$(nf_mac_rewrite 52:54:00:AA:BB:CC $NEWMAC < "$W/nd.out" | diff "$W/nd.out" - | grep -c '^>')"
assert_eq "networkd: a name inside a list" "Name=eth1 eth0" "$(printf '[Match]\nName=eth1 enp1s0\n' | nf_networkd_rename enp1s0 eth0 | tail -1)"
assert_eq "networkd: a glob that covered the old name gains the new one" "Name=en* eth0" "$(printf '[Match]\nName=en*\n' | nf_networkd_rename enp1s0 eth0 | tail -1)"
assert_eq "networkd: a glob that covers both stays" "Name=e*" "$(printf '[Match]\nName=e*\n' | nf_networkd_rename enp1s0 eth0 | tail -1)"
assert_eq "networkd: a glob that never covered the old name stays" "Name=wl*" "$(printf '[Match]\nName=wl*\n' | nf_networkd_rename enp1s0 eth0 | tail -1)"
assert_eq "networkd: Name= outside [Match]/[Link] is not an interface match" "[NetDev]|Name=enp1s0" "$(printf '[NetDev]\nName=enp1s0\n' | nf_networkd_rename enp1s0 eth0 | lines)"
printf '[Match]\nMACAddress=52:54:00:aa:bb:cc\n\n[Link]\nName=lan0\nMACAddress=02:00:00:00:00:01\n' > "$W/pin.link"
assert_eq ".link: [Link] Name= renamed; [Match] MACAddress= is a match, [Link] MACAddress= a set one" "[Match]|MACAddress=$NEWMAC||[Link]|Name=eth0|MACAddress=02:00:00:00:00:01" \
	"$(nf_networkd_rename lan0 eth0 < "$W/pin.link" | nf_mac_rewrite '*' $NEWMAC | lines)"
assert_ok   "is_primary networkd: by [Match] Name="   eval 'nf_is_primary networkd eth0 < "$W/nd.out"'
assert_fail "is_primary networkd: another name"       eval 'nf_is_primary networkd eth1 < "$W/nd.out"'

# --- (e) ifcfg -----------------------------------------------------------------------------------------------
sed 's/eth0/eno1/' "$RAW/ifcfg-eth0" > "$W/ifcfg-eno1"
nf_ifcfg_rename eno1 eth0 < "$W/ifcfg-eno1" > "$W/ifcfg.out"
assert_eq "ifcfg: DEVICE and NAME renamed (quotes kept), UUID commented out" 'NAME="eth0"|# migrator: UUID="b3f2a6c1-1d2e-4f3a-9b8c-7d6e5f4a3b2c"|DEVICE="eth0"' "$(sed -n '7,9p' "$W/ifcfg.out" | lines)"
assert_eq "ifcfg: three lines changed" "3" "$(diff "$W/ifcfg-eno1" "$W/ifcfg.out" | grep -c '^>')"
assert_eq "ifcfg: HWADDR replaced, upper case kept" "HWADDR=52:54:00:CC:DD:01" "$(nf_mac_rewrite 00:25:90:ab:cd:ef $NEWMAC < "$W/ifcfg.out" | grep HWADDR)"
assert_eq "ifcfg: renaming twice equals once" "$(cat "$W/ifcfg.out")" "$(nf_ifcfg_rename eno1 eth0 < "$W/ifcfg.out")"
assert_eq "ifcfg: another NIC's file untouched" "$(cat "$RAW/ifcfg-eth1")" "$(nf_ifcfg_rename eno1 eth0 < "$RAW/ifcfg-eth1")"
assert_eq "ifcfg: alias and vlan devices, PHYSDEV; a free-text NAME stays" "DEVICE=eth0:1|DEVICE=eth0.100|PHYSDEV=eth0|NAME='System eno1'" \
	"$(printf "DEVICE=eno1:1\n" | nf_ifcfg_rename eno1 eth0)|$(printf "DEVICE=eno1.100\n" | nf_ifcfg_rename eno1 eth0)|$(printf "PHYSDEV=eno1\n" | nf_ifcfg_rename eno1 eth0)|$(printf "NAME='System eno1'\n" | nf_ifcfg_rename eno1 eth0)"
# the donor already is eth0: no rename pass, the MAC pass still runs
assert_eq "ifcfg: donor already eth0 with the old MAC in HWADDR: MAC replaced, nothing else" "11c11|HWADDR=52:54:00:CC:DD:01" \
	"$(nf_mac_rewrite 00:25:90:AB:CD:EF $NEWMAC < "$RAW/ifcfg-eth0" | diff "$RAW/ifcfg-eth0" - | grep '^[0-9]')|$(nf_mac_rewrite 00:25:90:AB:CD:EF $NEWMAC < "$RAW/ifcfg-eth0" | grep HWADDR)"
assert_eq "ifcfg: unknown donor MAC: HWADDR is a match and is replaced" "00:25:90:ab:cd:ef|HWADDR=52:54:00:CC:DD:01" "$(nf_mac_list '*' $NEWMAC < "$RAW/ifcfg-eth0")|$(nf_mac_rewrite '*' $NEWMAC < "$RAW/ifcfg-eth0" | grep HWADDR)"
assert_eq "ifcfg: MACADDR= (a spoofed MAC) is never touched, known or unknown" "MACADDR=00:25:90:AB:CD:EF|MACADDR=00:25:90:AB:CD:EF" \
	"$(echo 'MACADDR=00:25:90:AB:CD:EF' | nf_mac_rewrite 00:25:90:ab:cd:ef $NEWMAC)|$(echo 'MACADDR=00:25:90:AB:CD:EF' | nf_mac_rewrite '*' $NEWMAC)"
assert_eq "mac: a commented line is not rewritten" "# HWADDR=00:25:90:AB:CD:EF" "$(echo '# HWADDR=00:25:90:AB:CD:EF' | nf_mac_rewrite 00:25:90:ab:cd:ef $NEWMAC)"
assert_eq "mac: the new MAC already there is not listed" "" "$(echo "HWADDR=$NEWMAC" | nf_mac_list '*' $NEWMAC)"
assert_eq "mac: a longer hex run is not a MAC" "HWADDR=80:00:02:08:fe:80:00:00:00:00" "$(echo 'HWADDR=80:00:02:08:fe:80:00:00:00:00' | nf_mac_rewrite 80:00:02:08:fe:80 $NEWMAC)"
assert_ok   "is_primary ifcfg: DEVICE= (quoted)"  eval 'nf_is_primary ifcfg eth0 < "$RAW/ifcfg-eth0"'
assert_fail "is_primary ifcfg: another device"    eval 'nf_is_primary ifcfg eth0 < "$RAW/ifcfg-eth1"'
assert_eq "route-X: 'dev OLD' follows the rename" "10.0.0.0/8 via 192.0.2.1 dev eth0|ADDRESS0=10.0.0.0" "$(printf '10.0.0.0/8 via 192.0.2.1 dev eno1\nADDRESS0=10.0.0.0\n' | nf_route_rename eno1 eth0 | lines)"

# --- (f) NetworkManager keyfile ---------------------------------------------------------------------------------
nf_keyfile_rename eno1 eth0 < "$RAW/eno1.nmconnection" > "$W/kf.out"
assert_eq "keyfile: interface-name renamed, id= untouched" "id=eno1|interface-name=eth0" "$(grep -e '^id=' -e '^interface-name=' "$W/kf.out" | lines)"
assert_eq "keyfile: one line changed" "5c5" "$(diff "$RAW/eno1.nmconnection" "$W/kf.out" | grep '^[0-9]')"
assert_eq "keyfile: mac-address replaced, upper case kept" "mac-address=52:54:00:CC:DD:01" "$(nf_mac_rewrite 3c:ec:ef:12:34:56 $NEWMAC < "$W/kf.out" | grep '^mac-address')"
assert_eq "keyfile: cloned-mac-address (spoofed) and the blacklist are not matches" "cloned-mac-address=3C:EC:EF:12:34:56|mac-address-blacklist=3C:EC:EF:12:34:56" \
	"$(printf 'cloned-mac-address=3C:EC:EF:12:34:56\nmac-address-blacklist=3C:EC:EF:12:34:56\n' | nf_mac_rewrite 3c:ec:ef:12:34:56 $NEWMAC | lines)"
assert_ok   "is_primary keyfile: interface-name="  eval 'nf_is_primary keyfile eth0 < "$W/kf.out"'
assert_fail "is_primary keyfile: before the rename" eval 'nf_is_primary keyfile eth0 < "$RAW/eno1.nmconnection"'

# --- (g) the udev pin ------------------------------------------------------------------------------------------------
nf_udev_rules "eth0:52:54:00:CC:DD:01,eth1x:b0:83:fe:00:00:02" > "$W/udev.out"
assert_eq "udev: one rule per pin, MAC in lower case (sysfs is)" \
	'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="52:54:00:cc:dd:01", ATTR{type}=="1", NAME="eth0"|SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="b0:83:fe:00:00:02", ATTR{type}=="1", NAME="eth1x"' \
	"$(grep -v '^#' "$W/udev.out" | lines)"
assert_has "udev: the header says it is best-effort" "EEXIST" "$(grep '^#' "$W/udev.out")"

# --- (h) netfix_run end to end -----------------------------------------------------------------------------------------
# mk DIR CASE: state dir with the fixture's plan + inventories and an empty target tree DIR/t
mk() {
	rm -rf "$1"; mkdir -p "$1/t/etc/udev/rules.d"
	cp "$FIX/$2/expected.plan" "$1/plan"; cp "$FIX/$2/donor.inv" "$FIX/$2/recipient.inv" "$1/"
}
# nfrun DIR [SNIPPET]: netfix_run on DIR/t in a subshell; output -> DIR/out, status echoed
nfrun() { ( RUN=$1; TARGET_MNT=$1/t; PF_PLAN=; PF_DIR=; PF_WARNS=(); eval "${2:-}"; netfix_run ) > "$1/out" 2>&1; echo $?; }
treesum() { ( cd "$1" && { find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -type f -printf '%p %s %T@\n' | sort; } | sha256sum | cut -c1-64 ); }
files() { ( cd "$1" && find . -type f | grep -v '^\./var/lib/migrator\.to/' | sort | sed 's|^\./||' | xargs ); }

# ifupdown (the stand plan: ens3/-/interfaces): an interfaces.d file, the donor's udev rules, other places naming ens3
D=$W/e-if; mk "$D" stand-debian-md-ext4-bios
mkdir -p "$D/t/etc/network/interfaces.d" "$D/t/etc/iptables" "$D/t/etc/default" "$D/t/etc/sysctl.d"
cp "$FIX/stand-debian-md-ext4-bios/raw/tree/etc/network/interfaces" "$D/t/etc/network/interfaces"
printf 'iface ens3 inet6 auto\n\thwaddress ether 52:54:00:AB:CD:01\n' > "$D/t/etc/network/interfaces.d/v6"
printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="52:54:00:ab:cd:01", NAME="ens3"\n' > "$D/t/etc/udev/rules.d/70-persistent-net.rules"
printf -- '-A INPUT -i ens3 -j ACCEPT\n' > "$D/t/etc/iptables/rules.v4"
printf 'INTERFACESv4="ens3"\n' > "$D/t/etc/default/isc-dhcp-server"
printf 'net.ipv6.conf.ens30.accept_ra = 0\n' > "$D/t/etc/sysctl.d/10-x.conf"
printf 'ip link set ens3 mtu 9000\n' > "$D/t/etc/rc.local"
cp -a "$D/t" "$D/pristine"
rc=$(nfrun "$D")
assert_eq "e2e ifupdown: exits 0" 0 "$rc"
assert_eq "e2e ifupdown: interfaces renamed" "auto eth0|iface eth0 inet dhcp" "$(grep -E '^(auto|iface) e' "$D/t/etc/network/interfaces" | lines)"
assert_eq "e2e ifupdown: interfaces.d renamed; the donor's hardware MAC inside the primary stanza follows (donor MAC '-' in the plan)" \
	"iface eth0 inet6 auto|${TAB}hwaddress ether 52:54:00:CC:DD:01" "$(lines < "$D/t/etc/network/interfaces.d/v6")"
assert_eq "e2e ifupdown: the donor's udev rules are replaced by ours" "1 0" "$(grep -c 'ATTR{address}=="52:54:00:cc:dd:01".*NAME="eth0"' "$D/t/etc/udev/rules.d/70-persistent-net.rules") $(grep -c 'ens3' "$D/t/etc/udev/rules.d/70-persistent-net.rules")"
assert_ok "e2e ifupdown: ... and kept as the original" cmp -s "$D/pristine/etc/udev/rules.d/70-persistent-net.rules" "$D/t/var/lib/migrator/orig/etc/udev/rules.d/70-persistent-net.rules"
for f in /etc/iptables/rules.v4 /etc/default/isc-dhcp-server /etc/rc.local; do
	assert_has "e2e ifupdown: list-only WARN for $f" "WARN: $f mentions ens3" "$(cat "$D/out")"
	assert_ok  "e2e ifupdown: $f is not edited" cmp -s "$D/pristine$f" "$D/t$f"
done
assert_eq "e2e ifupdown: ens30 is another word: no WARN for sysctl.d" "0" "$(grep -c 'sysctl.d/10-x.conf mentions' "$D/out")"
assert_has "e2e ifupdown: summary line" "network: ens3 -> eth0 (interfaces), mac -> $NEWMAC, pin=1 rules" "$(tail -1 "$D/out")"
assert_eq "e2e ifupdown: state netfix.done" "1" "$(RUN=$D state_get netfix.done)"
before=$(treesum "$D/t"); rc=$(nfrun "$D")
assert_eq "e2e ifupdown, second run: no diff, tree untouched" "0 0 same" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED)"
# -n on a fresh copy
rm -rf "$D/t"; cp -a "$D/pristine" "$D/t"; before=$(treesum "$D/t"); rm -f "$D/state"
rc=$(nfrun "$D" 'DRY=y')
assert_eq "e2e ifupdown, -n: diffs shown, tree byte-identical, no state" "0 3 same -" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED) $(RUN=$D state_get netfix.done)-"
# pin=0: the donor's rules go, ours are not written
rc=$(nfrun "$D" 'sed -i "s/ pin=1$/ pin=0/" "$RUN/plan"')
assert_eq "e2e ifupdown, pin=0: the donor's udev rules are removed (original kept), summary says 0 rules" "0 gone kept pin=0 rules" \
	"$rc $([ -e "$D/t/etc/udev/rules.d/70-persistent-net.rules" ] && echo there || echo gone) $([ -e "$D/t/var/lib/migrator/orig/etc/udev/rules.d/70-persistent-net.rules" ] && echo kept || echo lost) $(tail -1 "$D/out" | grep -o 'pin=.*')"

# netplan (the ubuntu plan: enp1s0/52:54:00:11:22:33/netplan)
D=$W/e-np; mk "$D" ubuntu-nvme-uefi-to-bios-vm; mkdir -p "$D/t/etc/netplan"
cat > "$D/t/etc/netplan/00-installer-config.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    enp1s0:
      match:
        macaddress: 52:54:00:11:22:33
      set-name: enp1s0
      addresses: [10.0.0.37/24]
    enp2s0:
      match:
        macaddress: 52:54:00:11:22:34
      dhcp4: true
EOF
chmod 0600 "$D/t/etc/netplan/00-installer-config.yaml"
rc=$(nfrun "$D")
assert_eq "e2e netplan: exits 0" 0 "$rc"
assert_eq "e2e netplan: key -> eth0, set-name gone, its match MAC -> the recipient's; the second NIC's block untouched" \
	"    eth0:|      match:|        macaddress: $NEWMAC|      addresses: [10.0.0.37/24]|    enp2s0:|      match:|        macaddress: 52:54:00:11:22:34|      dhcp4: true" "$(sed -n '4,$p' "$D/t/etc/netplan/00-installer-config.yaml" | lines)"
assert_eq "e2e netplan: written in place, mode 0600 kept" "600" "$(stat -c %a "$D/t/etc/netplan/00-installer-config.yaml")"
assert_has "e2e netplan: summary" "network: enp1s0 -> eth0 (netplan), mac -> $NEWMAC, pin=1 rules" "$(tail -1 "$D/out")"
before=$(treesum "$D/t"); rc=$(nfrun "$D")
assert_eq "e2e netplan, second run: no diff" "0 0 same" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED)"

# networkd, donor MAC unknown (crafted from the stand plan)
D=$W/e-nd; mk "$D" stand-debian-md-ext4-bios; sed -i 's|^donor=ens3/-/interfaces |donor=enp1s0/-/networkd |' "$D/plan"
mkdir -p "$D/t/etc/systemd/network"; cp "$RAW/10-wired.network" "$D/t/etc/systemd/network/"
printf '[Match]\nName=enp9s0\nMACAddress=02:11:22:33:44:55\n' > "$D/t/etc/systemd/network/20-other.network"
rc=$(nfrun "$D")
assert_eq "e2e networkd: Name= renamed, the pinned MAC (unknown to the plan) replaced" "0 Name=eth0|MACAddress=$NEWMAC" "$rc $(sed -n '2,3p' "$D/t/etc/systemd/network/10-wired.network" | lines)"
assert_has "e2e networkd: ... with a WARN that lists it" "10-wired.network pins eth0 to 52:54:00:aa:bb:cc" "$(cat "$D/out")"
assert_eq "e2e networkd: another NIC's file untouched" "Name=enp9s0|MACAddress=02:11:22:33:44:55" "$(sed -n '2,3p' "$D/t/etc/systemd/network/20-other.network" | lines)"
before=$(treesum "$D/t"); rc=$(nfrun "$D")
assert_eq "e2e networkd, second run: no diff, no WARN about a pinned MAC" "0 0 same 0" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED) $(grep -c 'pins eth0' "$D/out")"

# ifcfg (the centos7 plan: eno1/3c:ec:ef:11:22:33/ifcfg, 4 recipient NICs): the file moves with its routes
D=$W/e-ifcfg; mk "$D" centos7-md-lvm-xfs-bios; N=$D/t/etc/sysconfig/network-scripts; mkdir -p "$N"
printf 'TYPE=Ethernet\nBOOTPROTO=none\nNAME=eno1\nUUID=b3f2a6c1-1d2e-4f3a-9b8c-7d6e5f4a3b2c\nDEVICE=eno1\nONBOOT=yes\nHWADDR=3C:EC:EF:11:22:33\nIPADDR=10.0.0.21\nPREFIX=24\n' > "$N/ifcfg-eno1"
printf 'DEVICE=eno1:1\nIPADDR=10.0.0.22\n' > "$N/ifcfg-eno1:1"
printf 'DEVICE=eno2\nHWADDR=3C:EC:EF:11:22:34\nMACADDR=02:00:00:00:00:02\nONBOOT=no\n' > "$N/ifcfg-eno2"
printf '10.9.0.0/16 via 10.0.0.1 dev eno1\n' > "$N/route-eno1"
cp "$RAW/ifcfg-lo" "$N/ifcfg-lo"; printf 'DEVICE=eno1\n' > "$N/ifcfg-eno1.bak"
cp -a "$D/t" "$D/pristine"
rc=$(nfrun "$D")
assert_eq "e2e ifcfg: exits 0" 0 "$rc"
assert_eq "e2e ifcfg: ifcfg-eno1* and route-eno1 moved to eth0; eno2, lo and the .bak stay" \
	"etc/sysconfig/network-scripts/ifcfg-eno1.bak etc/sysconfig/network-scripts/ifcfg-eno2 etc/sysconfig/network-scripts/ifcfg-eth0 etc/sysconfig/network-scripts/ifcfg-eth0:1 etc/sysconfig/network-scripts/ifcfg-lo etc/sysconfig/network-scripts/route-eth0 etc/udev/rules.d/70-persistent-net.rules" "$(files "$D/t")"
assert_eq "e2e ifcfg: the moved file: DEVICE/NAME renamed, UUID commented, HWADDR replaced" \
	"TYPE=Ethernet|BOOTPROTO=none|NAME=eth0|# migrator: UUID=b3f2a6c1-1d2e-4f3a-9b8c-7d6e5f4a3b2c|DEVICE=eth0|ONBOOT=yes|HWADDR=B0:83:FE:00:00:01|IPADDR=10.0.0.21|PREFIX=24" "$(lines < "$N/ifcfg-eth0")"
assert_eq "e2e ifcfg: alias file and route file" "DEVICE=eth0:1|IPADDR=10.0.0.22|10.9.0.0/16 via 10.0.0.1 dev eth0" "$(cat "$N/ifcfg-eth0:1" "$N/route-eth0" | lines)"
assert_ok "e2e ifcfg: the original ifcfg-eno1 is kept" cmp -s "$D/pristine/etc/sysconfig/network-scripts/ifcfg-eno1" "$D/t/var/lib/migrator/orig/etc/sysconfig/network-scripts/ifcfg-eno1"
assert_ok "e2e ifcfg: the second NIC's file is not edited" cmp -s "$D/pristine/etc/sysconfig/network-scripts/ifcfg-eno2" "$N/ifcfg-eno2"
assert_has "e2e ifcfg: WARN: it still names a donor NIC the recipient lacks" "ifcfg-eno2 still names 3c:ec:ef:11:22:34" "$(cat "$D/out")"
assert_has "e2e ifcfg: WARN: MACADDR= left as is" "ifcfg-eno2 sets a spoofed MAC" "$(cat "$D/out")"
assert_eq "e2e ifcfg: four udev rules (eth0 + eth1x..eth3x)" "4 eth0 eth1x eth2x eth3x" "$(grep -c '^SUBSYSTEM' "$D/t/etc/udev/rules.d/70-persistent-net.rules") $(sed -n 's/.*NAME="\(.*\)"$/\1/p' "$D/t/etc/udev/rules.d/70-persistent-net.rules" | xargs)"
assert_has "e2e ifcfg: summary" "network: eno1 -> eth0 (ifcfg), mac -> b0:83:fe:00:00:01, pin=4 rules" "$(tail -1 "$D/out")"
before=$(treesum "$D/t"); rc=$(nfrun "$D")
assert_eq "e2e ifcfg, second run: no diff, nothing moved again" "0 0 same" "$rc $(grep -c '^@@' "$D/out") $([ "$before" = "$(treesum "$D/t")" ] && echo same || echo CHANGED)"

# NetworkManager keyfile (the rocky9 plan: eno1/d0:94:66:aa:bb:01/nm-keyfile)
D=$W/e-kf; mk "$D" rocky9-lvm-xfs-uefi; N=$D/t/etc/NetworkManager/system-connections; mkdir -p "$N"
sed 's/3C:EC:EF:12:34:56/D0:94:66:AA:BB:01/' "$RAW/eno1.nmconnection" > "$N/eno1.nmconnection"; chmod 0600 "$N/eno1.nmconnection"
rc=$(nfrun "$D")
assert_eq "e2e keyfile: interface-name and mac-address follow, id and file name stay, mode 0600 kept" "0 id=eno1|interface-name=eth0|mac-address=B4:96:91:00:00:01 600" \
	"$rc $(grep -e '^id=' -e '^interface-name=' -e '^mac-address=' "$N/eno1.nmconnection" | lines) $(stat -c %a "$N/eno1.nmconnection")"

# the donor's primary NIC already is eth0: no rename pass, the MAC pass runs
D=$W/e-eth0; mk "$D" centos7-md-lvm-xfs-bios; sed -i 's|^donor=eno1/3c:ec:ef:11:22:33/ifcfg |donor=eth0/00:25:90:ab:cd:ef/ifcfg |' "$D/plan"
N=$D/t/etc/sysconfig/network-scripts; mkdir -p "$N"; cp "$RAW/ifcfg-eth0" "$RAW/ifcfg-eth1" "$N/"
rc=$(nfrun "$D")
assert_eq "e2e eth0 -> eth0: only HWADDR changes (UUID stays, file not moved)" "0 11c11 HWADDR=B0:83:FE:00:00:01 1" \
	"$rc $(diff "$RAW/ifcfg-eth0" "$N/ifcfg-eth0" | grep '^[0-9]') $(grep HWADDR "$N/ifcfg-eth0") $(grep -c '^UUID=' "$N/ifcfg-eth0")"
assert_ok "e2e eth0 -> eth0: ifcfg-eth1 untouched" cmp -s "$RAW/ifcfg-eth1" "$N/ifcfg-eth1"
assert_eq "e2e eth0 -> eth0: no list-only warnings (the name did not change)" "0" "$(grep -c 'mentions eth0' "$D/out")"

# primary NIC unknown: WARN, configs left alone, the pin is still written
D=$W/e-unk; mk "$D" stand-debian-md-ext4-bios; sed -i 's|^donor=ens3/-/interfaces |donor=-/-/unknown |' "$D/plan"
mkdir -p "$D/t/etc/network"; cp "$FIX/stand-debian-md-ext4-bios/raw/tree/etc/network/interfaces" "$D/t/etc/network/interfaces"
rc=$(nfrun "$D")
assert_eq "e2e unknown NIC: exits 0, interfaces untouched, pin written" "0 same 1" \
	"$rc $(cmp -s "$FIX/stand-debian-md-ext4-bios/raw/tree/etc/network/interfaces" "$D/t/etc/network/interfaces" && echo same || echo CHANGED) $(grep -c '^SUBSYSTEM' "$D/t/etc/udev/rules.d/70-persistent-net.rules")"
assert_has "e2e unknown NIC: the WARN" "WARN: primary NIC unknown: network configs left untouched (pass -o nic=)" "$(cat "$D/out")"
assert_has "e2e unknown NIC: summary" "network: - -> eth0 (unknown), mac -> $NEWMAC, pin=1 rules" "$(tail -1 "$D/out")"
D=$W/e-badmac; mk "$D" stand-debian-md-ext4-bios; sed -i 's| mac=52:54:00:cc:dd:01 | mac=- |' "$D/plan"
assert_eq "a plan without the recipient's boot MAC: exit 4" 4 "$(nfrun "$D")"

t_end
