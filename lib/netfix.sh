#!/bin/bash
# lib/netfix.sh — the network of the migrated system follows the machine: the
# recipient boots with net.ifnames=0 biosdevname=0 (postfix puts that on the
# kernel command line), so its boot NIC is eth0, and the donor's config for its
# primary NIC must say eth0 and must not name the donor's MAC any more. Sourced
# after postfix.sh (it writes through pf_new/pf_apply/pf_remove); defines
# functions only.
#
#   netfix_run     postfix step 5, the target mounted at $TARGET_MNT. From [network]:
#                  donor=<nic>/<mac|->/<kind> target=eth0 mac=<boot MAC> pin=1|0 pins=name:mac,...
#
# Two INDEPENDENT passes over every config file found (whatever the detected kind:
# /etc/network/interfaces{,.d/*}, /etc/netplan/*.yaml, /etc/systemd/network/*.{network,link},
# /etc/sysconfig/network-scripts/ifcfg-*, /etc/NetworkManager/system-connections/*):
#   rename   the donor's primary NIC name -> eth0 (skipped only when it already is eth0,
#            or when the primary NIC is unknown)
#   MAC      ALWAYS: the MAC the primary config pins -> the recipient's boot MAC; the
#            MACs of the donor's NICs inside the primary NIC's config likewise; with an
#            unknown donor MAC, whatever MAC the primary config matches on.
#            MACADDR= / cloned-mac-address= (a spoofed MAC) are never touched.
# then the udev pin (70-persistent-net.rules, best-effort) and a list of other
# places that still mention the old name (firewall rules, rc.local: never edited).
#
# Pure rewriters (stdin -> stdout; tests/cases/netfix.sh drives them on tests/fixtures/raw):
#   nf_interfaces_rename OLD NEW   ifupdown: auto/allow-*/iface/mapping, bridge_ports,
#                                  bond-slaves, vlan-raw-device, up/down commands; OLD:N, OLD.VLAN
#   nf_netplan_rename OLD NEW      the key under ethernets, set-name dropped, interfaces:/link: references
#   nf_networkd_rename OLD NEW     [Match] Name= lists (a glob that covered OLD gains NEW), [Link] Name=
#   nf_ifcfg_rename OLD NEW        DEVICE/NAME/PHYSDEV, UUID commented out
#   nf_keyfile_rename OLD NEW      interface-name=
#   nf_route_rename OLD NEW        route-X / rule-X bodies ("dev OLD")
#   nf_mac_rewrite OLDMAC NEWMAC [SCOPE]   HWADDR= mac-address= macaddress: hwaddress MACAddress=;
#                                  OLDMAC "*" = any MAC a config MATCHES on; SCOPE = the netplan
#                                  key / ifupdown iface whose block alone is rewritten
#   nf_mac_list OLDMAC NEWMAC [SCOPE]      the MACs nf_mac_rewrite would replace, one per line
#   nf_is_primary KIND NAME        0 when the ifcfg/keyfile/networkd file on stdin configures NAME
#   nf_udev_rules PINS             the 70-persistent-net.rules text

# shellcheck disable=SC2015,SC2016  # "A && B || continue" guards on purpose; $1/$2 inside the awk programs are awk fields

# --- rename ------------------------------------------------------------------------
nf_interfaces_rename() {   # OLD NEW
	awk -v old="$1" -v new="$2" '
	function ren(tok,   l) {
		l = length(old)
		if (tok == old) return new
		if (substr(tok, 1, l) == old && substr(tok, l + 1, 1) ~ /[:.]/) return new substr(tok, l + 1)
		return tok
	}
	function rewrite(s,   out) {
		out = ""
		while (match(s, /[^ \t]+/)) {
			out = out substr(s, 1, RSTART - 1) ren(substr(s, RSTART, RLENGTH))
			s = substr(s, RSTART + RLENGTH)
		}
		return out s
	}
	$1 ~ /^(auto|allow-[a-z0-9_-]+|iface|mapping|bridge[_-]ports|bond[_-]slaves|slaves|bond[_-]primary|vlan[_-]raw[_-]device|pre-up|up|post-up|pre-down|down|post-down)$/ { print rewrite($0); next }
	{ print }'
}
# netplan, string level (no YAML parser in the Live): indentation is preserved.
# set-name goes: it would rename the NIC back to the donor's name.
nf_netplan_rename() {   # OLD NEW
	awk -v old="$1" -v new="$2" -v sq="'" '
	function keyis(s, name,   t, c) {
		t = s; sub(/^[ \t]+/, "", t)
		c = substr(t, 1, 1); if (c == "\"" || c == sq) t = substr(t, 2)
		if (substr(t, 1, length(name)) != name) return 0
		t = substr(t, length(name) + 1)
		c = substr(t, 1, 1); if (c == "\"" || c == sq) t = substr(t, 2)
		return (t ~ /^:([ \t]|$)/)
	}
	function value(s,   v, c) {
		v = s; sub(/^-?[ \t]*[^:]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
		c = substr(v, 1, 1); if (c == "\"" || c == sq) v = substr(v, 2, length(v) - 2)
		return v
	}
	function item(s,   v, c) {
		v = s; sub(/^-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
		c = substr(v, 1, 1); if (c == "\"" || c == sq) v = substr(v, 2, length(v) - 2)
		return v
	}
	function after(s, from,   head, tail, p) {     # the first OLD at or after column FROM -> NEW
		head = substr(s, 1, from - 1); tail = substr(s, from); p = index(tail, old)
		if (!p) return s
		return head substr(tail, 1, p - 1) new substr(tail, p + length(old))
	}
	function names(s,   out, tok) {
		out = ""
		while (match(s, /[A-Za-z0-9_.:-]+/)) {
			tok = substr(s, RSTART, RLENGTH); if (tok == old) tok = new
			out = out substr(s, 1, RSTART - 1) tok; s = substr(s, RSTART + RLENGTH)
		}
		return out s
	}
	{
		line = $0; body = line; sub(/^[ \t]+/, "", body)
		if (body == "" || substr(body, 1, 1) == "#") { print; next }
		match(line, /^[ \t]*/); i = RLENGTH
		if (sect != "" && i <= sectind) sect = ""
		if (inblk && i <= blkind) inblk = 0
		if (inlist && !(substr(body, 1, 1) == "-" && i >= listind)) inlist = 0
		if (sect == "" && body ~ /^(ethernets|bonds|bridges|vlans|wifis|tunnels|vrfs|modems):[ \t]*(#.*)?$/) {
			sect = body; sub(/:.*$/, "", sect); sectind = i; print; next
		}
		if (sect == "ethernets") {
			if (!inblk && keyis(line, old)) { inblk = 1; blkind = i; print after(line, 1); next }
			if (body ~ /^set-name:/ && (inblk || value(body) == old)) next
		}
		if (body ~ /^interfaces:/) {
			p = index(line, ":")
			if (substr(line, p + 1) ~ /\[/) line = substr(line, 1, p) names(substr(line, p + 1))
			else { inlist = 1; listind = i }
			print line; next
		}
		if (inlist && substr(body, 1, 1) == "-") { if (item(body) == old) line = after(line, index(line, "-") + 1); print line; next }
		if (body ~ /^link:/ && value(body) == old) line = after(line, index(line, ":") + 1)
		print line
	}'
}
nf_networkd_rename() {   # OLD NEW
	local old=$1 new=$2 line sec='' pre val out w hit
	local -a words
	local re='^([[:space:]]*Name[[:space:]]*=[[:space:]]*)(.*)$'
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in \[*\]*) sec=${line%%]*}; sec=${sec#[};; esac
		if { [ "$sec" = Match ] || [ "$sec" = Link ]; } && [[ $line =~ $re ]]; then
			pre=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; out=; hit=
			read -ra words <<< "$val"
			for w in "${words[@]}"; do
				if [ "$w" = "$old" ]; then w=$new; hit=y
				elif [ "$sec" = Match ] && [[ $w == *[\*\?\[]* && $w != '!'* ]]; then
					# a glob (en*) that covered the old name and misses the new one
					# shellcheck disable=SC2053  # $w IS a pattern here
					if [[ $old == $w && $new != $w && " ${words[*]} " != *" $new "* ]]; then w="$w $new"; hit=y; fi
				fi
				out="${out:+$out }$w"
			done
			if [ -n "$hit" ]; then printf '%s%s\n' "$pre" "$out"; continue; fi
		fi
		printf '%s\n' "$line"
	done
}
nf_ifcfg_rename() {   # OLD NEW
	awk -v old="$1" -v new="$2" -v sq="'" '
	function val(s,   v, c) {
		v = s; sub(/^[^=]*=/, "", v); sub(/[ \t]+$/, "", v)
		c = substr(v, 1, 1); if (c == "\"" || c == sq) v = substr(v, 2, length(v) - 2)
		return v
	}
	function setval(s, nv,   k, c, q) {
		k = s; sub(/=.*$/, "", k)
		c = substr(s, length(k) + 2, 1); q = (c == "\"" || c == sq) ? c : ""
		return k "=" q nv q
	}
	function ren(v,   l) {
		l = length(old)
		if (v == old) return new
		if (substr(v, 1, l) == old && substr(v, l + 1, 1) ~ /[:.]/) return new substr(v, l + 1)
		return v
	}
	{ lines[NR] = $0 }
	END {
		for (i = 1; i <= NR; i++) {
			s = lines[i]
			if (s ~ /^[ \t]*(DEVICE|NAME|PHYSDEV)=/) {
				v = val(s); nv = ren(v)
				if (nv != v) { lines[i] = setval(s, nv); if (s ~ /^[ \t]*DEVICE=/) hit = 1 }
			}
		}
		# the connection UUID belongs to the old profile: NetworkManager makes a new one
		for (i = 1; i <= NR; i++) { s = lines[i]; if (hit && s ~ /^[ \t]*UUID=/) s = "# migrator: " s; print s }
	}'
}
nf_keyfile_rename() {   # OLD NEW
	awk -v old="$1" -v new="$2" '
	{ v = $0; sub(/[ \t\r]+$/, "", v)
	  if (v == "interface-name=" old) print "interface-name=" new; else print }'
}
nf_route_rename() {   # OLD NEW: whole-word tokens of route-X / rule-X files
	awk -v old="$1" -v new="$2" '
	/^[ \t]*#/ { print; next }
	{
		s = $0; out = ""
		while (match(s, /[^ \t=]+/)) {
			tok = substr(s, RSTART, RLENGTH); if (tok == old) tok = new
			out = out substr(s, 1, RSTART - 1) tok; s = substr(s, RSTART + RLENGTH)
		}
		print out s
	}'
}

# --- MAC -----------------------------------------------------------------------------
# Lines that carry a MAC, and what the MAC means there:
#   match  HWADDR=  mac-address=  [Match] MACAddress=/PermanentMACAddress=  netplan match: macaddress:
#   set    ifupdown "hwaddress ether", netplan macaddress: outside match:, [Link] MACAddress=
#   never  MACADDR=, cloned-mac-address= (a deliberately spoofed MAC), comments
# A known OLDMAC is replaced in match and set lines (a config that set the NIC's
# own MAC keeps doing exactly that); "*" replaces only what a config matches on.
_NF_AWK_MAC='
function keyis(s, name,   t, c) {
	t = s; sub(/^[ \t]+/, "", t)
	c = substr(t, 1, 1); if (c == "\"" || c == sq) t = substr(t, 2)
	if (substr(t, 1, length(name)) != name) return 0
	t = substr(t, length(name) + 1)
	c = substr(t, 1, 1); if (c == "\"" || c == sq) t = substr(t, 2)
	return (t ~ /^:([ \t]|$)/)
}
function swap(s,   out, cur, b, a, n) {
	out = ""
	while (match(s, macre)) {
		cur = substr(s, RSTART, RLENGTH)
		b = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""; a = substr(s, RSTART + RLENGTH, 1)
		# part of something longer (an IPv6 address, a 20-byte IPoIB address) is not a MAC
		if (b !~ /[0-9A-Fa-f:]/ && a !~ /[0-9A-Fa-f:]/ && ((any && tolower(cur) != lnew) || (!any && tolower(cur) == lold))) {
			if (mode == "list") print tolower(cur)
			n = lnew; if (cur ~ /[A-F]/ && cur !~ /[a-f]/) n = toupper(lnew)
			cur = n
		}
		out = out substr(s, 1, RSTART - 1) cur
		s = substr(s, RSTART + RLENGTH)
	}
	return out s
}
BEGIN {
	h = "[0-9A-Fa-f][0-9A-Fa-f]"; macre = h ":" h ":" h ":" h ":" h ":" h
	any = (old == "*"); lold = tolower(old); lnew = tolower(new)
}
{
	line = $0; body = line; sub(/^[ \t]+/, "", body)
	if (body != "" && substr(body, 1, 1) != "#" && substr(body, 1, 1) != ";") {
		match(line, /^[ \t]*/); i = RLENGTH
		if (substr(body, 1, 1) == "[" && index(body, "]")) sec = substr(body, 2, index(body, "]") - 2)
		if (inmatch && i <= matchind) inmatch = 0
		if (inblk && i <= blkind) inblk = 0
		if (scope != "") {
			if (!inblk && keyis(line, scope)) { inblk = 1; blkind = i }
			if ($1 ~ /^(iface|auto|mapping|source|source-directory|allow-[a-z0-9_-]+)$/) stanza = ($1 == "iface" && $2 == scope)
		}
		if (body ~ /^match:[ \t]*(#.*)?$/) { inmatch = 1; matchind = i }
		kind = ""
		if (body ~ /^HWADDR=/ || body ~ /^mac-address=/) kind = "match"
		else if (body ~ /^(Permanent)?MACAddress[ \t]*=/) kind = (sec == "Match") ? "match" : "set"
		else if (body ~ /^macaddress:/) kind = inmatch ? "match" : "set"
		else if (body ~ /^match:[ \t]*\{.*macaddress:/) kind = "match"
		else if (body ~ /^hwaddress[ \t]/) kind = "set"
		if (kind != "" && (scope == "" || inblk || stanza) && (kind == "match" || !any)) line = swap(line)
	}
	if (mode != "list") print line
}'
nf_mac_rewrite() { awk -v old="$1" -v new="$2" -v scope="${3:-}" -v mode=rewrite -v sq="'" "$_NF_AWK_MAC"; }
nf_mac_list()    { awk -v old="$1" -v new="$2" -v scope="${3:-}" -v mode=list -v sq="'" "$_NF_AWK_MAC"; }

# nf_is_primary KIND NAME: does the single-NIC config on stdin belong to NAME?
nf_is_primary() {
	awk -v kind="$1" -v name="$2" -v sq="'" '
	function val(s,   v, c) {
		v = s; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
		c = substr(v, 1, 1); if (c == "\"" || c == sq) v = substr(v, 2, length(v) - 2)
		return v
	}
	/^[ \t]*[#;]/ { next }
	/^[ \t]*\[/ { sec = $0; gsub(/[][ \t]/, "", sec); next }
	kind == "ifcfg" && /^[ \t]*DEVICE=/ { if (val($0) == name) hit = 1 }
	kind == "keyfile" && /^interface-name=/ { if (val($0) == name) hit = 1 }
	kind == "networkd" && (sec == "Match" || sec == "Link") && /^[ \t]*Name[ \t]*=/ { n = split(val($0), w, /[ \t]+/); for (j = 1; j <= n; j++) if (w[j] == name) hit = 1 }
	END { exit !hit }'
}

# --- udev pin ----------------------------------------------------------------------------
nf_udev_rules() {   # PINS = name:mac,name:mac,...
	local p name mac
	printf '%s\n' \
		'# migrator: written by the migration, replaces the rules of the donor machine.' \
		'# Pins the interface names the migrated config relies on to the MACs of THIS' \
		'# machine. Best-effort: udev renames NICs in parallel, and when the kernel has' \
		'# already given eth0 to another NIC the rename fails with EEXIST; on a box with' \
		'# one NIC the rule changes nothing (net.ifnames=0 already makes it eth0).'
	for p in ${1//,/ }; do
		name=${p%%:*}; mac=${p#*:}
		[ -n "$name" ] && [ "$mac" != "$p" ] && [ -n "$mac" ] || continue
		printf 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="%s", ATTR{type}=="1", NAME="%s"\n' "${mac,,}" "$name"
	done
}

# ==============================================================================
# the step
# ==============================================================================
# every managed config in the target as "kind<TAB>path-in-target"
_nf_files() {
	local t=$TARGET_MNT f
	[ -f "$t/etc/network/interfaces" ] && printf 'interfaces\t%s\n' /etc/network/interfaces
	for f in "$t"/etc/network/interfaces.d/*; do [ -f "$f" ] && printf 'interfaces\t%s\n' "${f#"$t"}"; done
	for f in "$t"/etc/netplan/*.yaml; do [ -f "$f" ] && printf 'netplan\t%s\n' "${f#"$t"}"; done
	for f in "$t"/etc/systemd/network/*.network "$t"/etc/systemd/network/*.link; do [ -f "$f" ] && printf 'networkd\t%s\n' "${f#"$t"}"; done
	for f in "$t"/etc/sysconfig/network-scripts/ifcfg-*; do
		case $f in *'~'|*.bak|*.orig|*.rpmnew|*.rpmorig|*.rpmsave) continue;; esac
		[ -f "$f" ] && printf 'ifcfg\t%s\n' "${f#"$t"}"
	done
	for f in "$t"/etc/NetworkManager/system-connections/*; do [ -f "$f" ] && printf 'keyfile\t%s\n' "${f#"$t"}"; done
	return 0
}
# _nf_pipe FILTER ARGS...: $NF_CUR through a pure rewriter; a rewriter that fails or
# empties the content is skipped (and said so), the content stays as it was
_nf_pipe() {
	if "$@" < "$NF_CUR" > "$NF_CUR.next" && { [ -s "$NF_CUR.next" ] || [ ! -s "$NF_CUR" ]; }; then mv -f "$NF_CUR.next" "$NF_CUR"
	else rm -f "$NF_CUR.next"; pf_warn "network: $1 failed on $NF_REL: that rewrite was skipped"; fi
}
# ifcfg-OLD, ifcfg-OLD:0, ifcfg-OLD.100 -> the same file for NEW ("" when the name is not OLD's)
_nf_ifcfg_newname() {   # PATH OLD NEW
	local dir base suffix
	dir=$(dirname "$1"); base=$(basename "$1")
	case $base in
		"ifcfg-$2") suffix= ;;
		"ifcfg-$2":[0-9]*|"ifcfg-$2".[0-9]*) suffix=${base#"ifcfg-$2"} ;;
		*) return 0 ;;
	esac
	printf '%s\n' "$dir/ifcfg-$3$suffix"
}

netfix_run() {
	local plan=${PF_PLAN:-$RUN/plan} inv=${PF_DIR:-$RUN}/donor.inv t=$TARGET_MNT
	local donor old oldmac kind new newmac pin pins rest rel k m f dest scope found nrules=0 pre
	local -a files=() dmacs=() mentions=()
	donor=$(plan_get "$plan" network donor); new=$(plan_get "$plan" network target)
	newmac=$(plan_get "$plan" network mac); pin=$(plan_get "$plan" network pin); pins=$(plan_get "$plan" network pins)
	old=${donor%%/*}; rest=${donor#*/}; oldmac=${rest%%/*}; kind=${rest#*/}
	if [ "$rest" = "$donor" ]; then oldmac=-; kind=unknown; fi
	[ "$kind" != "$rest" ] || kind=unknown
	: "${new:=eth0}"
	newmac=${newmac,,}; oldmac=${oldmac,,}
	[[ $newmac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || die "$EX_PLAN" "[network] mac='$newmac' in $plan is not a MAC address"
	[[ $oldmac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || oldmac=
	case $old in ''|-) old=; pf_warn "primary NIC unknown: network configs left untouched (pass -o nic=)";; esac
	# the MACs of the donor's own NICs (its hardware, as its Live saw it)
	while IFS= read -r m; do
		m=${m,,}
		[[ $m =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] && [ "$m" != "$newmac" ] && [ "$m" != "$oldmac" ] && dmacs+=("$m")
	done < <(pl_records "$inv" nic 2>/dev/null | while IFS= read -r rest; do pl_field "$rest" mac; done)

	mapfile -t files < <(_nf_files)
	mkdir -p "$RUN"
	NF_CUR=$RUN/netfix.cur
	for f in "${files[@]}"; do
		k=${f%%$'\t'*}; rel=${f#*$'\t'}; NF_REL=$rel
		cat "$t$rel" > "$NF_CUR" 2>/dev/null || continue
		dest=$rel
		# (a) rename: the donor's primary NIC -> $new
		if [ -n "$old" ] && [ "$old" != "$new" ]; then
			case $k in
				interfaces) _nf_pipe nf_interfaces_rename "$old" "$new" ;;
				netplan)    _nf_pipe nf_netplan_rename "$old" "$new" ;;
				networkd)   _nf_pipe nf_networkd_rename "$old" "$new" ;;
				keyfile)    _nf_pipe nf_keyfile_rename "$old" "$new" ;;
				ifcfg)      _nf_pipe nf_ifcfg_rename "$old" "$new"
				            m=$(_nf_ifcfg_newname "$rel" "$old" "$new"); [ -z "$m" ] || dest=$m ;;
			esac
		fi
		# (b) MAC, always: what the primary config pinned ...
		[ -z "$oldmac" ] || _nf_pipe nf_mac_rewrite "$oldmac" "$newmac"
		# ... and, inside the primary NIC's own config, the donor's hardware MACs and
		# (donor MAC unknown) whatever MAC the config matches on
		if [ -n "$old" ]; then
			scope=; found=
			case $k in
				interfaces|netplan) scope=$new; found=y ;;
				*) nf_is_primary "$k" "$new" < "$NF_CUR" && found=y ;;
			esac
			if [ -n "$found" ]; then
				for m in "${dmacs[@]}"; do _nf_pipe nf_mac_rewrite "$m" "$newmac" "$scope"; done
				if [ -z "$oldmac" ]; then
					pre=$(nf_mac_list '*' "$newmac" "$scope" < "$NF_CUR" | sort -u | xargs)
					if [ -n "$pre" ]; then
						pf_warn "network: $rel pins $new to $pre (the donor's MAC was not in the plan): replaced with $newmac"
						_nf_pipe nf_mac_rewrite '*' "$newmac" "$scope"
					fi
				fi
			fi
		fi
		if grep -qiE '^[[:space:]]*(MACADDR|cloned-mac-address)=' "$NF_CUR"; then
			pf_warn "network: $rel sets a spoofed MAC (MACADDR=/cloned-mac-address=): left as is, check that it is still wanted on the recipient"
		fi
		for m in "${dmacs[@]}" ${oldmac:+"$oldmac"}; do
			if grep -v '^[[:space:]]*[#;]' "$NF_CUR" | grep -qiF -- "$m"; then
				pf_warn "network: $rel still names $m, a NIC of the donor that the recipient does not have (not the primary NIC's config: left as is)"
			fi
		done
		if [ "$dest" != "$rel" ]; then
			# ifcfg-OLD -> ifcfg-NEW: the new file is written, the old one removed
			pf_new "$dest" "$(stat -c %a "$t$rel" 2>/dev/null || echo 0644)" < "$NF_CUR"
			pf_remove "$rel"
		else
			pf_apply "$rel" < "$NF_CUR"
		fi
	done
	# route-OLD / rule-OLD travel with ifcfg-OLD
	if [ -n "$old" ] && [ "$old" != "$new" ]; then
		for k in route route6 rule rule6; do
			rel=/etc/sysconfig/network-scripts/$k-$old
			[ -f "$t$rel" ] || continue
			NF_REL=$rel; cat "$t$rel" > "$NF_CUR"
			_nf_pipe nf_route_rename "$old" "$new"
			pf_new "/etc/sysconfig/network-scripts/$k-$new" "$(stat -c %a "$t$rel" 2>/dev/null || echo 0644)" < "$NF_CUR"
			pf_remove "$rel"
		done
	fi
	rm -f "$NF_CUR" "$NF_CUR.next"

	# (c) the pin: the donor's rules name the donor's MACs either way
	if [ "$pin" = 1 ]; then
		[ -n "$pins" ] || pins="$new:$newmac"
		pf_new /etc/udev/rules.d/70-persistent-net.rules 0644 < <(nf_udev_rules "$pins")
		nrules=$(nf_udev_rules "$pins" | grep -c '^SUBSYSTEM')
	else
		pf_remove /etc/udev/rules.d/70-persistent-net.rules
	fi

	# (d) list only: places that still say the old name and that nobody should edit blindly
	if [ -n "$old" ] && [ "$old" != "$new" ]; then
		mapfile -t mentions < <(
			cd "$t" 2>/dev/null || exit 0
			for f in etc/iptables* etc/nftables* etc/rc.local etc/sysctl.d etc/sysctl.conf etc/NetworkManager/dispatcher.d etc/ufw etc/firewalld etc/shorewall*; do
				[ -e "$f" ] && grep -rIlwF -- "$old" "$f" 2>/dev/null
			done
			for f in etc/default/*; do
				[ -f "$f" ] && grep -IlwF -- "$old" "$f" 2>/dev/null
			done
			true
		)
		for f in "${mentions[@]}"; do pf_warn "/$f mentions $old (not edited: adjust it to $new by hand if it names the NIC)"; done
	fi

	say "network: ${old:--} -> $new ($kind), mac -> $newmac, pin=$nrules rules"
	[ -n "$DRY" ] || state_set netfix.done 1
}
