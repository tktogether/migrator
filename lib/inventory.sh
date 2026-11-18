#!/bin/bash
# lib/inventory.sh — what is on this machine (the recipient) or on the donor,
# as tab-separated records (docs/format.md). Sourced by bin/reloca.to for the
# functions, and streamed to the donor as a standalone script that needs only
# bash, mawk and the Live's own tools (no common.sh on the other side):
#
#   rsh bash -s -- --role donor [--raw /run/reloca.to/raw] [--modalias LIST] < lib/inventory.sh
#
# usage: inventory.sh --role donor|recipient [--raw DIR] [--modalias LIST] [--root DIR] [--mnt DIR]
#   --role recipient   this box, read-only: host disk part md pv vg lv fs swap nic
#   --role donor       the same, then: every md array read-only (refuses a resync),
#                      foreign arrays assembled read-only, vgchange -ay, the installed
#                      root found and mounted ro,noload / ro,norecovery with /boot and
#                      /boot/efi from its fstab, and os kernel fstab cmdline mdconf
#                      lvmconf swapfile netcfg collected; all unmounted at the end,
#                      arrays and VGs left active (the transfer needs them)
#   --raw DIR          keep every parsed command output as DIR/<command>.txt and the
#                      donor's config files under DIR/tree/<path> (fixtures)
#   --modalias LIST    comma-separated name=modalias pairs (the recipient's disk and NIC
#                      drivers): each donor kernel's modules.alias is matched against
#                      them, kernel.pci_drivers=name:module,... with "-" for no module
#   --root DIR         donor role on an already mounted (or unpacked) tree: no storage
#                      preparation, no discovery, no mounts (tests, fixtures)
#   --online           donor role on the RUNNING donor OS (on-line relocation): the
#                      tree is /, its root device from findmnt, every filesystem stays
#                      mounted as it is (rw), no mdadm --readonly, no vgchange, no
#                      probe mounts, nothing unmounted; host.online=1
#   --mnt DIR          mount base instead of /mnt/reloca.to/inv
#   -h, --help         this text
# Records on stdout, diagnostics on stderr. Nothing here writes to a block device;
# the donor's only writes are /run/reloca.to/md.conf and the --raw directory.
# exit: 0 ok · 2 usage · 4 the donor is unusable (resync in progress, no installed
#       root found): the reason is on stderr and the last stdout line is "# ERROR: ..."
#
# Functions the driver uses (sourced mode):
#   inventory_run ROLE        ROLE=both|donor|recipient -> $RUN/{recipient,donor}.inv
#                             (donor: streams this file over rsh; -o raw=DIR pulls the raw files)
#   inventory_collect ROLE    the collector: records on stdout (what --role runs)
#   inventory_summary FILE    one screen of the essentials of an inventory
#   inv_records FILE TYPE     records of one type    inv_field RECORD KEY   one value ("" if absent)
#   inv_lookup FILE TYPE MATCHKEY MATCHVAL FIELD     one field of the first matching record
# Pure parsers, stdin -> tab-separated key=value lines (tests feed them fixtures):
#   parse_lsblk_p parse_sfdisk_dump parse_dumpe2fs parse_xfs_db parse_blkid
#   parse_mdadm_export parse_mdadm_examine parse_fstab
#   netcfg_parse_ifcfg|keyfile|netplan|interfaces|networkd   netcfg_primary_<kind> ROOT
#   match_modalias ALIASES BUILTIN LIST      inv_donor_tree (INV_ROOT=DIR: the donor part)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- standalone fallbacks: the donor never sees common.sh -------------------------
declare -f say  >/dev/null || say()  { echo "$*" >&2; }
declare -f warn >/dev/null || warn() { echo "WARN: $*" >&2; }
declare -f die  >/dev/null || die()  { local c=1; case "$1" in [0-9]|[0-9][0-9]) c=$1; shift;; esac; echo "ERROR: $*" >&2; exit "$c"; }
declare -f have >/dev/null || have() { command -v "$1" >/dev/null 2>&1; }
declare -f log  >/dev/null || log()  { :; }
declare -f opt  >/dev/null || opt()  { echo "${2-}"; }
declare -f human >/dev/null || human() {
	awk -v b="$1" 'BEGIN{ split("B K M G T P", u, " "); i=1
		while (b >= 1024 && i < 6) { b /= 1024; i++ }
		if (i == 1) printf "%d%s\n", b, u[i]; else printf "%.1f%s\n", b, u[i] }'
}
: "${EX_PLAN:=4}" "${EX_ENV:=2}" "${EX_FAIL:=1}"

INV_RAW=${INV_RAW:-}                 # --raw DIR (empty: keep nothing)
INV_MNT=${INV_MNT:-/mnt/reloca.to/inv} # mount base on the donor
INV_ROOT=                            # the donor tree once mounted (or --root DIR)
INV_ROOT_DEV=-                       # device the donor root was found on
INV_ROOT_FS=; INV_CAND_FS=           # its filesystem type (and the runner-up's)
INV_MOUNTS=()                        # what this run mounted, in mount order
INV_MODALIAS=${INV_MODALIAS:-}       # --modalias LIST
INV_STANDALONE=
INV_PRIMARY_NIC=-
INV_ONLINE=${INV_ONLINE:-}             # --online: the donor's own running OS is the tree

# --- output primitives --------------------------------------------------------------
# The collector's stdout IS the inventory, so diagnostics never go there: stderr
# only (the driver re-emits the donor's stderr through say, tagged "donor:").
inv_note() { echo "inventory: $*" >&2; log "inventory: $*"; }
inv_warn() { echo "inventory: WARN: $*" >&2; log "inventory: WARN: $*"; WARNINGS=$((${WARNINGS:-0}+1)); }
# inv_fatal MSG: the donor cannot be inventoried. The reason travels on both
# streams: "# ERROR:" is the last stdout line (the driver reads it back from
# donor.inv), stderr is what the operator watching the donor sees.
inv_fatal() {
	echo "# ERROR: $*"
	inv_umount_all
	if [ -n "$INV_STANDALONE" ]; then echo "inventory: ERROR: $*" >&2; exit "$EX_PLAN"; fi
	die "$EX_PLAN" "$*"
}
# rec TYPE k=v k=v ...  one record: values may hold anything but a tab or a newline
rec() {
	local out=$1 a; shift
	for a in "$@"; do a=${a//$'\t'/ }; a=${a//$'\n'/ }; a=${a//$'\r'/}; out+=$'\t'$a; done
	printf '%s\n' "$out"
}
# cap NAME CMD...  run CMD for parsing; under --raw its stdout is also kept as
# NAME.txt (stderr as NAME.err) so a fixture can replay the parser on exactly
# what the tool printed. Returns CMD's status, not tee's.
cap() {
	local name=$1; shift
	local rc
	if [ -n "$INV_RAW" ]; then
		"$@" 2>"$INV_RAW/$name.err" | tee "$INV_RAW/$name.txt"
		rc=${PIPESTATUS[0]}
		[ -s "$INV_RAW/$name.err" ] || rm -f "$INV_RAW/$name.err"
		return "$rc"
	fi
	"$@" 2>/dev/null
}
rawname() { local n=${1#/dev/}; echo "${n//\//-}"; }
# raw_tree PATH...  copy donor files (paths inside the tree) to $INV_RAW/tree/<path>
raw_tree() {
	local f
	[ -n "$INV_RAW" ] || return 0
	for f in "$@"; do
		[ -f "$INV_ROOT$f" ] || continue
		if mkdir -p "$INV_RAW/tree/${f%/*}" 2>/dev/null; then cp -L "$INV_ROOT$f" "$INV_RAW/tree/$f" 2>/dev/null || true; fi
	done
}
# trim WORD: whitespace off both ends (values from sysfs/lsblk carry padding)
trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
sysval() { [ -r "$1" ] && trim "$(tr -d '\n\t' < "$1" 2>/dev/null)"; }

# --- key=value lines (records without the type; the parsers speak this) ------------
# kvget LINE KEY -> value, empty when absent. Fields are tab-separated and never
# empty, so the collapsing of consecutive tabs by read is harmless.
kvget() {
	local -a f=(); local x
	IFS=$'\t' read -ra f <<< "$1"
	for x in ${f[@]+"${f[@]}"}; do case $x in "$2="*) printf '%s\n' "${x#*=}"; return 0;; esac; done
	echo
}
inv_field()   { kvget "$1" "$2"; }   # a record's first field is its type: "disk" never matches "key="
inv_records() { awk -F'\t' -v t="$2" '$1==t' "$1"; }
inv_lookup() {   # FILE TYPE MATCHKEY MATCHVAL FIELD
	awk -F'\t' -v t="$2" -v mk="$3=" -v mv="$4" -v fk="$5=" '
	$1==t { ok=0
		for (i=2;i<=NF;i++) if (substr($i,1,length(mk))==mk && substr($i,length(mk)+1)==mv) ok=1
		if (ok) { for (i=2;i<=NF;i++) if (substr($i,1,length(fk))==fk) { print substr($i,length(fk)+1); exit } } }' "$1"
}

# ==================================================================================
# Parsers: stdin -> key=value lines. No root, no devices: tests drive them with
# recorded outputs under tests/fixtures/raw/.
# ==================================================================================
# lsblk -P: KEY="value" pairs; values escape " and \ as \xNN (older lsblk also
# spaces). A regex loop, never eval: a LABEL is attacker-controlled text.
parse_lsblk_p() {
	local line out k v re='^[[:space:]]*([A-Za-z:_-]+)="([^"]*)"(.*)$'
	while IFS= read -r line; do
		out=
		while [[ $line =~ $re ]]; do
			k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; line=${BASH_REMATCH[3]}
			k=${k,,}; k=${k//-/_}
			case $v in *\\x*) v=$(printf '%b' "$v");; esac
			out+=$'\t'"$k=$v"
		done
		[ -n "$out" ] && printf '%s\n' "${out#	}"
	done
	return 0
}
# blkid: "/dev/sda1: UUID="..." TYPE="ext4" ..." -> dev=/dev/sda1<TAB>uuid=...<TAB>type=...
parse_blkid() {
	local line dev rest
	while IFS= read -r line; do
		case $line in /dev/*:\ *) ;; *) continue;; esac
		dev=${line%%: *}; rest=${line#*: }
		printf 'dev=%s\t%s\n' "$dev" "$(printf '%s\n' "$rest" | parse_lsblk_p)"
	done
	return 0
}
# sfdisk -d: header "key: value" lines, then "DEV : start=N, size=N, type=T[, uuid=, name="", attrs="", bootable]".
# One "kind=header" line, then one "kind=part" line per partition with num= and
# ptype= (dos: 5/f/85 extended, numbers >4 logical). Old sfdisk wrote Id= for type=.
parse_sfdisk_dump() {
	local line hdr='kind=header' printed='' dev rest k v out num label='' ptype boot type
	local re_q='^([A-Za-z-]+)="([^"]*)"[[:space:]]*(,(.*))?$' re_p='^([A-Za-z-]+)=([^,]*)(,(.*))?$' re_b='^bootable[[:space:]]*(,(.*))?$'
	while IFS= read -r line; do
		case $line in
			''|'#'*) continue ;;
			*' : '*)
				[ -n "$printed" ] || { printf '%s\n' "$hdr"; printed=y; }
				dev=${line%% : *}; rest=${line#* : }
				out="kind=part"$'\t'"dev=$dev"; boot=0; type=
				while [ -n "$rest" ]; do
					rest=${rest#"${rest%%[! ]*}"}
					if [[ $rest =~ $re_q ]]; then k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[4]}
					elif [[ $rest =~ $re_p ]]; then k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[4]}
					elif [[ $rest =~ $re_b ]]; then boot=1; rest=${BASH_REMATCH[2]}; continue
					else case $rest in *,*) rest=${rest#*,};; *) rest=;; esac; continue
					fi
					v=$(trim "$v"); k=${k,,}
					[ "$k" = id ] && k="type"
					[ "$k" = type ] && type=$v
					# GPT has no boot flag; the legacy BIOS bootable attribute is its equivalent
					[ "$k" = attrs ] && case $v in *LegacyBIOSBootable*) boot=1;; esac
					out+=$'\t'"$k=$v"
				done
				num=${dev##*[!0-9]}
				ptype=primary
				if [ "$label" = dos ]; then
					case ${type,,} in 5|f|85|0x5|0xf|0x85) ptype=extended;; *) [ "${num:-0}" -gt 4 ] && ptype=logical;; esac
				fi
				printf '%s\tnum=%s\tbootable=%s\tptype=%s\n' "$out" "$num" "$boot" "$ptype" ;;
			*:*)
				k=${line%%:*}; v=$(trim "${line#*:}")
				[ "$k" = label ] && label=$v
				hdr+=$'\t'"$k=$v" ;;
		esac
	done
	[ -n "$printed" ] || printf '%s\n' "$hdr"
}
# dumpe2fs -h -> the fs record's ext fields. state: needs_recovery or anything
# but "clean" is dirty (the copy then gets partclone -I + e2fsck on the
# recipient); "clean with errors" is errors. masks keep the raw feature strings.
parse_dumpe2fs() {
	awk '
	{ i = index($0, ":"); if (i == 0) next
	  k = substr($0, 1, i-1); v = substr($0, i+1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
	  if (k == "Filesystem volume name") label = (v == "<none>" ? "" : v)
	  else if (k == "Filesystem UUID") uuid = v
	  else if (k == "Filesystem features") feat = v
	  else if (k == "Journal features") jfeat = (v == "(none)" ? "" : v)
	  else if (k == "Filesystem state") state = v
	  else if (k == "Inode count") icount = v
	  else if (k == "Free inodes") ifree = v
	  else if (k == "Block count") bcount = v
	  else if (k == "Free blocks") bfree = v
	  else if (k == "Block size") bs = v
	  else if (k == "Inode size") isz = v }
	END {
	  if (bs == "") exit 1
	  if (feat ~ /(^| )needs_recovery( |$)/) st = "dirty"
	  else if (state == "clean") st = "clean"
	  else if (state ~ /^clean with errors/) st = "errors"
	  else st = "dirty"
	  fl = feat; gsub(/ +/, ",", fl); jl = jfeat; gsub(/ +/, ",", jl); if (jl == "") jl = "-"
	  printf "uuid=%s\tlabel=%s\tfssize=%.0f\tused=%.0f\tinodes_used=%.0f\tinodes_total=%.0f\tstate=%s\tbs=%s\tisz=%s\tfeatures=%s\tjournal_features=%s\tmasks=features:%s|journal:%s\n",
	    uuid, label, bcount*bs, (bcount-bfree)*bs, icount-ifree, icount, st, bs, isz, fl, jl, feat, jfeat }'
}
# xfs_db -r -c version -c 'sb 0' -c 'p blocksize sectsize inodesize dirblklog dblocks
# fdblocks icount ifree versionnum features2 features_compat features_ro_compat
# features_incompat features_log_incompat' -> the fs record's xfs fields (state comes
# from xfs_logprint, uuid/label from blkid).
parse_xfs_db() {
	awk '
	/^versionnum \[/ { i = index($0, "= "); feat = substr($0, i+2); next }
	{ i = index($0, " = "); if (i == 0) next; val[substr($0, 1, i-1)] = substr($0, i+3) }
	END {
	  bs = val["blocksize"] + 0; if (bs == 0) exit 1
	  d = bs; for (i = 0; i < val["dirblklog"] + 0; i++) d *= 2
	  printf "fssize=%.0f\tused=%.0f\tinodes_used=%.0f\tinodes_total=%.0f\tbs=%d\tisz=%d\tssz=%d\tdirbs=%.0f\tfeatures=%s\tjournal_features=-\tmasks=versionnum=%s,features2=%s,compat=%s,ro_compat=%s,incompat=%s,log_incompat=%s\n",
	    val["dblocks"]*bs, (val["dblocks"]-val["fdblocks"])*bs, val["icount"]-val["ifree"], val["icount"], bs, val["inodesize"], val["sectsize"], d, feat,
	    val["versionnum"], val["features2"], val["features_compat"], val["features_ro_compat"], val["features_incompat"], val["features_log_incompat"] }'
}
# mdadm --detail --export -> level= devices= metadata= uuid= name= members=
parse_mdadm_export() {
	local line k v members="" level="" n="" meta="" uuid="" name=""
	while IFS= read -r line; do
		k=${line%%=*}; v=${line#*=}
		case $k in
			MD_LEVEL) level=$v;; MD_DEVICES) n=$v;; MD_METADATA) meta=$v;; MD_UUID) uuid=$v;; MD_NAME) name=$v;;
			MD_DEVICE_*_DEV) members+=",$v";;
		esac
	done
	printf 'level=%s\tdevices=%s\tmetadata=%s\tuuid=%s\tname=%s\tmembers=%s\n' "$level" "$n" "$meta" "$uuid" "$name" "${members#,}"
}
# mdadm --examine MEMBER -> the data offset in sectors (0 for 0.90 metadata, which has none)
parse_mdadm_examine() {
	local off
	off=$(sed -n 's/^[[:space:]]*Data Offset[[:space:]]*:[[:space:]]*\([0-9][0-9]*\) sectors.*/\1/p' | head -1)
	echo "${off:-0}"
}
# /etc/fstab -> spec= mount= type= opts= dump= pass= nofail= per entry
parse_fstab() {
	awk '
	/^[ \t]*#/ || NF < 2 { next }
	{ opts = (NF >= 4 ? $4 : "defaults")
	  nofail = ((("," opts ",") ~ /,nofail,/) ? 1 : 0)
	  printf "spec=%s\tmount=%s\ttype=%s\topts=%s\tdump=%s\tpass=%s\tnofail=%d\n", $1, $2, (NF >= 3 ? $3 : "-"), opts, (NF >= 5 ? $5 : 0), (NF >= 6 ? $6 : 0), nofail }'
}

# --- network config parsers: one file on stdin -> iface= mac= ip= gw= ... ----------
netcfg_parse_ifcfg() {   # ifcfg-X (shell-like KEY=value)
	awk '
	function mask2pfx(m,   a, i, o, c) { if (m ~ /^[0-9]+$/) return m; c = 0; split(m, a, "."); for (i = 1; i <= 4; i++) { o = a[i] + 0; while (o > 0) { if (o % 2) c++; o = int(o / 2) } } return c }
	/^[ \t]*#/ || !/=/ { next }
	{ i = index($0, "="); k = substr($0, 1, i-1); v = substr($0, i+1)
	  gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
	  if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
	  kv[k] = v }
	END {
	  ip = kv["IPADDR"]; if (ip == "") ip = kv["IPADDR0"]
	  pfx = kv["PREFIX"]; if (pfx == "") pfx = kv["PREFIX0"]
	  if (pfx == "" && kv["NETMASK"] != "") pfx = mask2pfx(kv["NETMASK"])
	  if (ip != "" && pfx != "" && ip !~ /\//) ip = ip "/" pfx
	  gw = kv["GATEWAY"]; if (gw == "") gw = kv["GATEWAY0"]
	  mac = tolower(kv["HWADDR"]); if (mac == "") mac = tolower(kv["MACADDR"])
	  printf "iface=%s\tmac=%s\tip=%s\tgw=%s\tbootproto=%s\tonboot=%s\tdefroute=%s\ttype=%s\tname=%s\n",
	    kv["DEVICE"], mac, ip, gw, tolower(kv["BOOTPROTO"]), tolower(kv["ONBOOT"]), tolower(kv["DEFROUTE"]), tolower(kv["TYPE"]), kv["NAME"] }'
}
netcfg_parse_keyfile() {   # NetworkManager *.nmconnection (ini)
	awk '
	/^[ \t]*[#;]/ || /^[ \t]*$/ { next }
	/^\[/ { sec = $0; gsub(/[][ \t]/, "", sec); next }
	/=/ { i = index($0, "="); k = substr($0, 1, i-1); v = substr($0, i+1)
	      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v); kv[sec "." k] = v }
	END {
	  iface = kv["connection.interface-name"]; type = kv["connection.type"]
	  mac = tolower(kv["ethernet.mac-address"]); if (mac == "") mac = tolower(kv["802-3-ethernet.mac-address"])
	  gw = kv["ipv4.gateway"]; ip = ""
	  a = kv["ipv4.address1"]; if (a == "") a = kv["ipv4.addresses1"]; if (a == "") a = kv["ipv4.address"]
	  if (a ~ /;/) { n = split(a, p, ";"); ip = p[1] "/" p[2]; if (gw == "" && n >= 3) gw = p[3] }
	  else if (a != "") { n = split(a, p, ","); ip = p[1]; if (gw == "" && n >= 2) gw = p[2] }
	  printf "iface=%s\tmac=%s\tip=%s\tgw=%s\tmethod=%s\ttype=%s\tid=%s\n", iface, mac, ip, gw, kv["ipv4.method"], type, kv["connection.id"] }'
}
# netplan yaml, grep-level: the keys under ethernets: are interfaces; below each,
# gateway4 / routes "to: default" + via / match macaddress / addresses / set-name.
# Indentation is whatever the file uses: the first key after ethernets: sets the
# interface level, the first line below an interface sets the property level.
netcfg_parse_netplan() {
	awk -v sq="'" '
	function flush() {
		if (iface != "") printf "iface=%s\tmac=%s\tip=%s\tgw=%s\tsetname=%s\tdhcp=%s\n", iface, mac, ip, gw, setname, dhcp
		iface = ""; mac = ""; ip = ""; gw = ""; setname = ""; dhcp = ""; wantvia = 0; wantaddr = 0; propind = 0 }
	function val(s,   v) { v = s; sub(/^-?[ \t]*[^:]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/"/, "", v); gsub(sq, "", v); return v }
	/^[ \t]*#/ || /^[ \t]*$/ { next }
	{ match($0, /^ */); ind = RLENGTH; line = $0; sub(/^ +/, "", line); sub(/[ \t]+$/, "", line) }
	!eth && line ~ /^ethernets:/ { eth = 1; ethind = ind; ifind = 0; next }
	eth && ind <= ethind { flush(); eth = 0 }
	eth && (ifind == 0 || ind == ifind) && line ~ /^[A-Za-z0-9_.:-]+:$/ { flush(); iface = line; sub(/:$/, "", iface); ifind = ind; next }
	eth && iface != "" && ind > ifind {
		if (propind == 0) propind = ind
		direct = (ind == propind)
		if (direct && line !~ /^- /) wantaddr = 0
		if (line ~ /^gateway4:/) gw = val(line)
		else if (direct && line ~ /^dhcp4:/) dhcp = tolower(val(line))
		else if (line ~ /^-?[ \t]*to:[ \t]*(default|0\.0\.0\.0\/0)([ \t]|$)/) wantvia = 1
		else if (wantvia && line ~ /^-?[ \t]*via:/) { gw = val(line); wantvia = 0 }
		else if (line ~ /^macaddress:/) mac = tolower(val(line))
		else if (direct && line ~ /^set-name:/) setname = val(line)
		else if (direct && line ~ /^addresses:/) {
			a = val(line)
			if (a ~ /^\[/) { gsub(/[][ ]/, "", a); split(a, arr, ","); if (ip == "" && arr[1] != "") ip = arr[1] }
			else wantaddr = 1 }
		else if (wantaddr && line ~ /^- /) { if (ip == "") ip = val("x: " substr(line, 3)) } }
	END { flush() }'
}
netcfg_parse_interfaces() {   # ifupdown: one line per "iface X" stanza (lo skipped)
	awk '
	function mask2pfx(m,   a, i, o, c) { if (m ~ /^[0-9]+$/) return m; c = 0; split(m, a, "."); for (i = 1; i <= 4; i++) { o = a[i] + 0; while (o > 0) { if (o % 2) c++; o = int(o / 2) } } return c }
	function flush() {
		if (iface != "" && iface != "lo") {
			if (ip != "" && ip !~ /\// && mask != "") ip = ip "/" mask2pfx(mask)
			printf "iface=%s\tfamily=%s\tmethod=%s\tmac=%s\tip=%s\tgw=%s\n", iface, fam, method, mac, ip, gw }
		iface = ""; fam = ""; method = ""; mac = ""; ip = ""; gw = ""; mask = "" }
	/^[ \t]*#/ || /^[ \t]*$/ { next }
	$1 == "iface" { flush(); iface = $2; fam = $3; method = $4; next }
	$1 == "auto" || $1 == "allow-hotplug" || $1 == "allow-auto" || $1 == "mapping" || $1 == "source" || $1 == "source-directory" { flush(); next }
	iface != "" {
		if ($1 == "address") ip = $2
		else if ($1 == "netmask") mask = $2
		else if ($1 == "gateway") gw = $2
		else if ($1 == "hwaddress") mac = tolower($NF) }
	END { flush() }'
}
netcfg_parse_networkd() {   # systemd-networkd *.network (ini)
	awk '
	/^[ \t]*[#;]/ || /^[ \t]*$/ { next }
	/^\[/ { sec = $0; gsub(/[][ \t]/, "", sec); dest = ""; next }
	/=/ { i = index($0, "="); k = substr($0, 1, i-1); v = substr($0, i+1)
	      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
	      if (sec == "Match" && k == "Name" && iface == "") { split(v, a, " "); iface = a[1] }
	      else if (sec == "Match" && k == "MACAddress" && mac == "") { split(v, a, " "); mac = tolower(a[1]) }
	      else if ((sec == "Network" || sec == "Address") && k == "Address" && ip == "") ip = v
	      else if (sec == "Network" && k == "Gateway" && gw == "") gw = v
	      else if (sec == "Route" && k == "Destination") dest = v
	      else if (sec == "Route" && k == "Gateway" && gw == "" && (dest == "" || dest == "0.0.0.0/0")) gw = v
	      else if (sec == "Network" && k == "DHCP") dhcp = tolower(v) }
	END { printf "iface=%s\tmac=%s\tip=%s\tgw=%s\tdhcp=%s\n", iface, mac, ip, gw, dhcp }'
}

# --- which config file names the primary NIC (the one with the default gateway) ---
# Each netcfg_primary_<kind> ROOT prints iface= mac= ip= gw= file= for the best
# candidate: a gateway wins, then a default-route flag, then a dhcp interface;
# a file explicitly not on boot / not the default route is ignored.
_netcfg_best() {   # SCORE LINE: keep the highest score (first wins on a tie)
	if [ "$1" -gt "${_NC_SCORE:-0}" ]; then _NC_SCORE=$1; _NC_BEST=$2; fi
}
_netcfg_emit() { [ -n "${_NC_BEST:-}" ] && printf '%s\n' "$_NC_BEST"; _NC_BEST=; _NC_SCORE=0; return 0; }
netcfg_primary_ifcfg() {
	local root=$1 f kv iface gw gwglobal score
	_NC_BEST=; _NC_SCORE=0
	gwglobal=$(sed -n 's/^GATEWAY=//p' "$root/etc/sysconfig/network" 2>/dev/null | tr -d '"' | head -1)
	for f in "$root"/etc/sysconfig/network-scripts/ifcfg-*; do
		[ -f "$f" ] || continue
		case ${f##*/} in ifcfg-lo|*.bak|*.orig|*~|*.rpmsave|*.rpmnew) continue;; esac
		kv=$(netcfg_parse_ifcfg < "$f")
		[ "$(kvget "$kv" type)" != loopback ] || continue
		iface=$(kvget "$kv" iface); [ -n "$iface" ] || iface=${f##*/ifcfg-}
		gw=$(kvget "$kv" gw)
		score=1
		[ "$(kvget "$kv" onboot)" = no ] && score=0
		[ "$(kvget "$kv" defroute)" = yes ] && score=$((score+2))
		[ "$(kvget "$kv" defroute)" = no ] && score=0
		[ "$(kvget "$kv" bootproto)" = dhcp ] && [ "$score" -gt 0 ] && score=$((score+1))
		[ -n "$gw" ] && score=$((score+4))
		[ "$score" -gt 0 ] || continue
		_netcfg_best "$score" "iface=$iface"$'\t'"mac=$(kvget "$kv" mac)"$'\t'"ip=$(kvget "$kv" ip)"$'\t'"gw=${gw:-$gwglobal}"$'\t'"file=${f#"$root"}"
	done
	_netcfg_emit
}
netcfg_primary_nm-keyfile() {
	local root=$1 f kv gw score
	_NC_BEST=; _NC_SCORE=0
	for f in "$root"/etc/NetworkManager/system-connections/*.nmconnection; do
		[ -f "$f" ] || continue
		kv=$(netcfg_parse_keyfile < "$f")
		case $(kvget "$kv" type) in ''|ethernet|802-3-ethernet|bond|bridge|vlan) ;; *) continue;; esac
		gw=$(kvget "$kv" gw); score=1
		[ "$(kvget "$kv" method)" = auto ] && score=2
		[ -n "$gw" ] && score=$((score+4))
		_netcfg_best "$score" "iface=$(kvget "$kv" iface)"$'\t'"mac=$(kvget "$kv" mac)"$'\t'"ip=$(kvget "$kv" ip)"$'\t'"gw=$gw"$'\t'"file=${f#"$root"}"
	done
	_netcfg_emit
}
netcfg_primary_netplan() {
	local root=$1 f kv iface gw score
	_NC_BEST=; _NC_SCORE=0
	for f in "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml; do
		[ -f "$f" ] || continue
		while IFS= read -r kv; do
			[ -n "$kv" ] || continue
			iface=$(kvget "$kv" setname); [ -n "$iface" ] || iface=$(kvget "$kv" iface)
			gw=$(kvget "$kv" gw); score=1
			case $(kvget "$kv" dhcp) in true|yes) score=2;; esac
			[ -n "$(kvget "$kv" ip)" ] && score=2
			[ -n "$gw" ] && score=$((score+4))
			_netcfg_best "$score" "iface=$iface"$'\t'"mac=$(kvget "$kv" mac)"$'\t'"ip=$(kvget "$kv" ip)"$'\t'"gw=$gw"$'\t'"file=${f#"$root"}"
		done < <(netcfg_parse_netplan < "$f")
	done
	_netcfg_emit
}
netcfg_primary_interfaces() {
	local root=$1 f kv gw score
	_NC_BEST=; _NC_SCORE=0
	for f in "$root"/etc/network/interfaces "$root"/etc/network/interfaces.d/*; do
		[ -f "$f" ] || continue
		while IFS= read -r kv; do
			[ -n "$kv" ] || continue
			[ "$(kvget "$kv" family)" = inet ] || continue
			gw=$(kvget "$kv" gw); score=1
			[ "$(kvget "$kv" method)" = dhcp ] && score=2
			[ -n "$gw" ] && score=$((score+4))
			_netcfg_best "$score" "iface=$(kvget "$kv" iface)"$'\t'"mac=$(kvget "$kv" mac)"$'\t'"ip=$(kvget "$kv" ip)"$'\t'"gw=$gw"$'\t'"file=${f#"$root"}"
		done < <(netcfg_parse_interfaces < "$f")
	done
	_netcfg_emit
}
netcfg_primary_networkd() {
	local root=$1 f kv gw score
	_NC_BEST=; _NC_SCORE=0
	for f in "$root"/etc/systemd/network/*.network; do
		[ -f "$f" ] || continue
		kv=$(netcfg_parse_networkd < "$f")
		gw=$(kvget "$kv" gw); score=1
		case $(kvget "$kv" dhcp) in yes|ipv4|true) score=2;; esac
		[ -n "$gw" ] && score=$((score+4))
		_netcfg_best "$score" "iface=$(kvget "$kv" iface)"$'\t'"mac=$(kvget "$kv" mac)"$'\t'"ip=$(kvget "$kv" ip)"$'\t'"gw=$gw"$'\t'"file=${f#"$root"}"
	done
	_netcfg_emit
}
# netcfg_detect ROOT -> ifcfg|nm-keyfile|netplan|interfaces|networkd|unknown, first
# kind that has a real interface configured (an interfaces file with only lo
# does not count: Debian ships one even under netplan/NM).
netcfg_has() {   # KIND ROOT
	local root=$2 f
	case $1 in
		ifcfg)      for f in "$root"/etc/sysconfig/network-scripts/ifcfg-*; do [ -f "$f" ] && [ "${f##*/}" != ifcfg-lo ] && return 0; done ;;
		nm-keyfile) for f in "$root"/etc/NetworkManager/system-connections/*.nmconnection; do [ -f "$f" ] && return 0; done ;;
		netplan)    for f in "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml; do [ -f "$f" ] && return 0; done ;;
		interfaces) for f in "$root"/etc/network/interfaces "$root"/etc/network/interfaces.d/*; do
		                [ -f "$f" ] && grep -qE '^[[:space:]]*iface[[:space:]]+' "$f" && [ -n "$(netcfg_parse_interfaces < "$f")" ] && return 0; done ;;
		networkd)   for f in "$root"/etc/systemd/network/*.network; do [ -f "$f" ] && return 0; done ;;
	esac
	return 1
}
netcfg_detect() {
	local k
	for k in ifcfg nm-keyfile netplan interfaces networkd; do netcfg_has "$k" "$1" && { echo "$k"; return 0; }; done
	echo unknown
}
netcfg_primary() {   # KIND ROOT -> the kv line, or nothing
	case $1 in ifcfg|nm-keyfile|netplan|interfaces|networkd) "netcfg_primary_$1" "$2";; esac
}
# netcfg_records ROOT PRIMARY_NIC: one netcfg record per config file of every
# kind present (netfix must see the leftovers too, not only the active kind),
# plus 70-persistent-net.rules, which pins names to MACs on old installs.
netcfg_records() {
	local root=$1 prim=$2 f kv iface mac seen p
	_nc_rec() {   # FILE KIND IFACE MAC
		local pr=0; [ -n "$3" ] && [ "$3" != - ] && [ "$3" = "$prim" ] && pr=1
		rec netcfg "file=$1" "kind=$2" "iface=${3:--}" "mac=${4:--}" "primary=$pr"
	}
	if netcfg_has ifcfg "$root"; then
		for f in "$root"/etc/sysconfig/network-scripts/ifcfg-*; do
			[ -f "$f" ] || continue; case ${f##*/} in ifcfg-lo) continue;; esac
			raw_tree "${f#"$root"}"; kv=$(netcfg_parse_ifcfg < "$f")
			iface=$(kvget "$kv" iface); [ -n "$iface" ] || iface=${f##*/ifcfg-}
			_nc_rec "${f#"$root"}" ifcfg "$iface" "$(kvget "$kv" mac)"
		done
		raw_tree /etc/sysconfig/network
	fi
	if netcfg_has nm-keyfile "$root"; then
		for f in "$root"/etc/NetworkManager/system-connections/*.nmconnection; do
			[ -f "$f" ] || continue; raw_tree "${f#"$root"}"; kv=$(netcfg_parse_keyfile < "$f")
			_nc_rec "${f#"$root"}" nm-keyfile "$(kvget "$kv" iface)" "$(kvget "$kv" mac)"
		done
	fi
	if netcfg_has netplan "$root"; then
		for f in "$root"/etc/netplan/*.yaml "$root"/etc/netplan/*.yml; do
			[ -f "$f" ] || continue; raw_tree "${f#"$root"}"; seen=
			while IFS= read -r kv; do
				[ -n "$kv" ] || continue
				iface=$(kvget "$kv" setname); [ -n "$iface" ] || iface=$(kvget "$kv" iface)
				_nc_rec "${f#"$root"}" netplan "$iface" "$(kvget "$kv" mac)"; seen=y
			done < <(netcfg_parse_netplan < "$f")
			[ -n "$seen" ] || _nc_rec "${f#"$root"}" netplan - -
		done
	fi
	if netcfg_has interfaces "$root"; then
		for f in "$root"/etc/network/interfaces "$root"/etc/network/interfaces.d/*; do
			[ -f "$f" ] || continue; raw_tree "${f#"$root"}"; seen=" "
			while IFS= read -r kv; do
				[ -n "$kv" ] || continue
				iface=$(kvget "$kv" iface); case $seen in *" $iface "*) continue;; esac; seen+="$iface "
				_nc_rec "${f#"$root"}" interfaces "$iface" "$(kvget "$kv" mac)"
			done < <(netcfg_parse_interfaces < "$f")
		done
	fi
	if netcfg_has networkd "$root"; then
		for f in "$root"/etc/systemd/network/*.network; do
			[ -f "$f" ] || continue; raw_tree "${f#"$root"}"; kv=$(netcfg_parse_networkd < "$f")
			_nc_rec "${f#"$root"}" networkd "$(kvget "$kv" iface)" "$(kvget "$kv" mac)"
		done
	fi
	p=/etc/udev/rules.d/70-persistent-net.rules
	if [ -f "$root$p" ]; then
		raw_tree "$p"; seen=
		while IFS= read -r kv; do
			iface=$(printf '%s\n' "$kv" | sed -n 's/.*NAME="\([^"]*\)".*/\1/p'); [ -n "$iface" ] || continue
			mac=$(printf '%s\n' "$kv" | sed -n 's/.*ATTR{address}=="\([^"]*\)".*/\1/p' | tr 'A-F' 'a-f')
			_nc_rec "$p" udev-persistent "$iface" "$mac"; seen=y
		done < <(grep -v '^[[:space:]]*#' "$root$p")
		[ -n "$seen" ] || _nc_rec "$p" udev-persistent - -
	fi
}

# --- modalias matching: is the recipient's driver in this donor kernel? ------------
# match_modalias ALIASES BUILTIN LIST: LIST = name=modalias,...; modules.alias lines
# are "alias <glob> <module>", so bash case does the matching. The bus prefix
# (pci:, virtio:, scsi:) narrows the 30k-line file with grep first. A driver
# absent from the aliases but present in modules.builtin is "builtin".
match_modalias() {
	local aliases=$1 builtin=$2 e name ma pat mod found out="" pre
	local -a entries
	IFS=, read -ra entries <<< "$3"
	for e in "${entries[@]}"; do
		[ -n "$e" ] || continue
		case $e in *=*) name=${e%%=*}; ma=${e#*=};; *) name=$e; ma=$e;; esac
		pre=${ma%%:*}; found=
		while read -r _ pat mod; do
			[ -n "$pat" ] || continue
			# shellcheck disable=SC2254  # the alias glob is the pattern, that is the point
			case $ma in $pat) found=$mod; break;; esac
		done < <(grep "^alias $pre:" "$aliases" 2>/dev/null)
		if [ -z "$found" ] && [ -r "$builtin" ] && grep -q "/$name\.ko" "$builtin" 2>/dev/null; then found=builtin; fi
		out+=",$name:${found:--}"
	done
	if [ -n "$out" ]; then echo "${out#,}"; else echo -; fi
}

# ==================================================================================
# Collectors (need root and the tools; the donor part also mounts)
# ==================================================================================
# sysfs_chain SYSDEV: drivers= and modalias= lists from the device upwards to the
# PCI function, so a virtio disk yields virtio_blk,virtio-pci and a SATA disk
# sd,ahci: all of them must be in the donor's initramfs.
sysfs_chain() {
	local p drivers="" aliases="" m
	p=$(readlink -f "$1" 2>/dev/null) || p=
	while [ -n "$p" ] && [ "$p" != / ] && [ "$p" != /sys ] && [ "$p" != /sys/devices ]; do
		[ -L "$p/driver" ] && drivers+=",$(basename "$(readlink "$p/driver")")"
		if [ -r "$p/modalias" ]; then
			m=$(cat "$p/modalias" 2>/dev/null); [ -n "$m" ] && aliases+=",$m"
			case $m in pci:*) break;; esac
		fi
		p=${p%/*}
	done
	printf 'drivers=%s\tmodalias=%s\n' "${drivers#,}" "${aliases#,}"
}
sysfs_pci_addr() {   # SYSDEV -> 0000:03:00.0 of the nearest PCI ancestor, or -
	local p; p=$(readlink -f "$1" 2>/dev/null) || p=
	while [ -n "$p" ] && [ "$p" != / ]; do
		case ${p##*/} in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-9a-f]) echo "${p##*/}"; return 0;; esac
		p=${p%/*}
	done
	echo -
}
inv_boot_nic() {   # -> "nic mac": BOOTIF= from pxelinux/iPXE, else /run/net-*.conf, else the default route
	local -a words=(); local w mac="" dev="" d
	read -ra words < /proc/cmdline 2>/dev/null || true
	for w in "${words[@]}"; do case $w in BOOTIF=*) mac=${w#BOOTIF=}; mac=${mac#01-}; mac=${mac//-/:};; esac; done
	mac=${mac,,}
	if [ -n "$mac" ]; then for d in /sys/class/net/*; do [ "$(cat "$d/address" 2>/dev/null)" = "$mac" ] && { dev=${d##*/}; break; }; done; fi
	# klibc ipconfig writes DEVICE='eth0' (quoted); the static path writes it bare
	[ -n "$dev" ] || dev=$(sed -n "s/^DEVICE='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" /run/net-*.conf 2>/dev/null | head -1)
	[ -n "$dev" ] || dev=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
	[ -n "$dev" ] && [ -z "$mac" ] && mac=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
	echo "${dev:--} ${mac:--}"
}
inv_ro_opts() {   # FSTYPE -> mount options that cannot write: no journal replay, ever
	case $1 in ext2|ext3|ext4) echo ro,noload;; xfs) echo ro,norecovery;; *) echo ro;; esac
}
inv_mount() {   # DEV DIR FSTYPE: read-only, remembered for the LIFO unmount
	mkdir -p "$2" 2>/dev/null || return 1
	mount -t "$3" -o "$(inv_ro_opts "$3")" "$1" "$2" 2>/dev/null || return 1
	INV_MOUNTS+=("$2")
}
inv_umount() {   # DIR (the most recent mount)
	local n=${#INV_MOUNTS[@]}
	umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
	[ "$n" -gt 0 ] && [ "${INV_MOUNTS[n-1]}" = "$1" ] && unset "INV_MOUNTS[n-1]"
	return 0
}
inv_umount_all() {
	local i
	for (( i=${#INV_MOUNTS[@]}-1; i>=0; i-- )); do
		umount "${INV_MOUNTS[$i]}" 2>/dev/null || umount -l "${INV_MOUNTS[$i]}" 2>/dev/null
	done
	INV_MOUNTS=()
	# --online and --root: a tree that was mounted before us (the running root!) is never unmounted
	[ -n "$INV_ROOT" ] && [ -z "$INV_ONLINE" ] && [ "$INV_ROOT" != / ] && [ "${INV_ROOT#"$INV_MNT"}" != "$INV_ROOT" ] && mountpoint -q "$INV_ROOT" 2>/dev/null && umount -R "$INV_ROOT" 2>/dev/null
	# only our own directories, and only once they are empty (unmounted)
	rmdir "$INV_MNT/root" "$INV_MNT/probe" "$INV_MNT" 2>/dev/null
	return 0
}
# inv_probe_os DEV FSTYPE -> "hostname PRETTY_NAME mtime=YYYY-MM-DD" when the
# filesystem holds an installed OS, else nothing. An already mounted fs is read
# where it is; anything else is mounted read-only, without journal replay, and
# unmounted right away.
inv_probe_os() {
	local dev=$1 fstype=$2 dir mounted="" hn pretty ts
	dir=$(findmnt -rno TARGET --source "$dev" 2>/dev/null | head -1)
	if [ -z "$dir" ]; then
		[ "$(id -u)" = 0 ] || return 0
		[ -z "$INV_ONLINE" ] || return 0      # a running donor: nothing is mounted for a look
		dir=$INV_MNT/probe
		inv_mount "$dev" "$dir" "$fstype" || return 0
		mounted=y
	fi
	if [ -e "$dir/etc/os-release" ] && { [ -e "$dir/sbin/init" ] || [ -L "$dir/sbin/init" ]; }; then
		hn=$(head -1 "$dir/etc/hostname" 2>/dev/null); : "${hn:=-}"
		pretty=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$dir/etc/os-release" 2>/dev/null | head -1)
		ts=$(stat -c %Y "$dir/var/log/wtmp" 2>/dev/null || stat -c %Y "$dir/etc" 2>/dev/null)
		echo "$hn ${pretty:-?} mtime=$(date -d "@${ts:-0}" +%F 2>/dev/null || echo -)"
	fi
	[ -n "$mounted" ] && inv_umount "$dir"
	return 0
}
inv_byid() {   # DEV -> first /dev/disk/by-id name of it (wwn-/nvme-eui. excluded: they are separate fields), or -
	local l
	for l in /dev/disk/by-id/*; do
		[ -L "$l" ] || continue
		case ${l##*/} in wwn-*|nvme-eui.*|dm-*|lvm-pv-*|md-*) continue;; esac
		[ "$(readlink -f "$l")" = "$1" ] && { echo "${l##*/}"; return 0; }
	done
	echo -
}
inv_md_uuid_norm() {   # lsblk's dashed member UUID -> mdadm's colon form
	local u=${1//-/}; u=${u//:/}; u=${u,,}
	if [ ${#u} -eq 32 ]; then echo "${u:0:8}:${u:8:8}:${u:16:8}:${u:24:8}"; else echo "$1"; fi
}
inv_resolve_spec() {   # fstab spec -> device on this Live, or -
	local s=$1 d="" n
	case $s in
		UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
			d=$(findfs "$s" 2>/dev/null) || d=/dev/disk/by-$(echo "${s%%=*}" | tr '[:upper:]' '[:lower:]')/${s#*=} ;;
		/dev/*)
			d=$s
			# the donor numbered its arrays; the Live's udev gave them md127...: try the name symlink
			if [ ! -b "$d" ]; then case $s in /dev/md[0-9]*) n=${s#/dev/md}; [ -b "/dev/md/$n" ] && d=/dev/md/$n;; esac; fi ;;
		*) echo -; return 0 ;;
	esac
	[ -b "$d" ] || { echo -; return 0; }
	case $d in /dev/disk/*|/dev/md/*) d=$(readlink -f "$d");; esac
	case $d in /dev/dm-[0-9]*) n=$(cat "/sys/block/${d#/dev/}/dm/name" 2>/dev/null); [ -n "$n" ] && [ -b "/dev/mapper/$n" ] && d=/dev/mapper/$n;; esac
	echo "$d"
}
inv_shvar() {   # KEY FILE -> the last KEY=value of a shell-style file, quotes stripped; 1 when unset
	local v
	v=$(sed -n "s/^[[:space:]]*$1=//p" "$2" 2>/dev/null | tail -1)
	[ -n "$v" ] || { grep -q "^[[:space:]]*$1=" "$2" 2>/dev/null && { echo; return 0; }; return 1; }
	case $v in \"*) v=${v#\"}; v=${v%%\"*};; \'*) v=${v#\'}; v=${v%%\'*};; *) v=${v%%[[:space:]]#*};; esac
	printf '%s\n' "$v"
}

# --- the storage snapshot every record type reads from --------------------------------
declare -gA LSB_LINE LSB_CHILDREN BLKID_LINE PV_VG
LSB_ORDER=(); PVS=; VGS=; LVS=
inv_gather() {
	local l n pk dev
	LSB_LINE=(); LSB_CHILDREN=(); BLKID_LINE=(); PV_VG=(); LSB_ORDER=()
	l=$(cap lsblk-P lsblk -b -P -o NAME,PATH,TYPE,SIZE,FSTYPE,UUID,PARTUUID,PARTTYPE,PARTLABEL,PARTFLAGS,LABEL,PKNAME,RM,RO,TRAN,MODEL,SERIAL,WWN,LOG-SEC,PHY-SEC,PTTYPE,PTUUID,HOTPLUG 2>/dev/null | parse_lsblk_p)
	# an lsblk without PARTFLAGS (util-linux < 2.26) still gives everything else
	[ -n "$l" ] || l=$(cap lsblk-P lsblk -b -P -o NAME,PATH,TYPE,SIZE,FSTYPE,UUID,PARTUUID,PARTTYPE,PARTLABEL,LABEL,PKNAME,RM,RO,TRAN,MODEL,SERIAL,WWN,LOG-SEC,PHY-SEC,PTTYPE,PTUUID,HOTPLUG | parse_lsblk_p)
	# CentOS 7 and the rest of that generation: util-linux 2.23 knows none of PATH,
	# PARTTYPE, PARTFLAGS, PTTYPE, PTUUID and refuses the whole request because of
	# them. Ask for what it does have and fill the rest in from blkid and the raw
	# partition table - an on-line donor runs its own old OS, this is its inventory.
	if [ -z "$l" ]; then
		inv_note "lsblk is too old for PATH/PTTYPE/PARTTYPE ($(lsblk --version 2>&1 | head -1)): asking for what it has and filling the rest in from blkid"
		l=$(cap lsblk-P-old lsblk -b -P -o NAME,KNAME,TYPE,SIZE,FSTYPE,UUID,PARTUUID,PARTLABEL,LABEL,PKNAME,RM,RO,TRAN,MODEL,SERIAL,WWN,LOG-SEC,PHY-SEC | parse_lsblk_p | inv_lsblk_fill)
	fi
	[ -n "$l" ] || inv_fatal "lsblk gave nothing (util-linux missing or too old?)"
	# a device with two parents (md member of two disks... no: an md over two
	# partitions) is printed once per parent: keep the first line, every parent
	while IFS= read -r l; do
		n=$(kvget "$l" name); pk=$(kvget "$l" pkname)
		[ -n "$n" ] || continue
		if [ -z "${LSB_LINE[$n]+x}" ]; then LSB_LINE[$n]=$l; LSB_ORDER+=("$n"); fi
		[ -n "$pk" ] && LSB_CHILDREN[$pk]+=" $n"
	done <<< "$l"
	while IFS= read -r l; do
		dev=$(kvget "$l" dev); [ -n "$dev" ] && BLKID_LINE[$dev]=$l
	done < <(cap blkid blkid -c /dev/null | parse_blkid)
	export LVM_SUPPRESS_FD_WARNINGS=1
	if have pvs; then
		PVS=$(cap pvs pvs --noheadings --units b --nosuffix --separator '|' -o pv_name,pv_uuid,vg_name,pv_size,pe_start | sed 's/^ *//')
		VGS=$(cap vgs vgs --noheadings --units b --nosuffix --separator '|' -o vg_name,vg_uuid,vg_size,vg_free,pv_count | sed 's/^ *//')
		LVS=$(cap lvs lvs --noheadings --units b --nosuffix --separator '|' -o lv_path,vg_name,lv_name,lv_uuid,lv_size,segtype | sed 's/^ *//')
		while IFS='|' read -r dev _ pk _; do [ -n "$dev" ] && PV_VG[$dev]=$pk; done <<< "$PVS"
	fi
	[ -r /proc/mdstat ] && cap proc-mdstat cat /proc/mdstat >/dev/null
	return 0
}
inv_descendants() {   # NAME -> every device below it, breadth first
	local -a queue=("$1"); local seen=" " n c
	while [ ${#queue[@]} -gt 0 ]; do
		n=${queue[0]}; queue=("${queue[@]:1}")
		for c in ${LSB_CHILDREN[$n]:-}; do
			case $seen in *" $c "*) continue;; esac
			seen+="$c "; echo "$c"; queue+=("$c")
		done
	done
}
inv_fstype_of() {   # NAME: blkid first (direct probe), lsblk's udev view second
	local l=${LSB_LINE[$1]:-} t; t=$(kvget "${BLKID_LINE[$(kvget "$l" path)]:-}" type)
	[ -n "$t" ] || t=$(kvget "$l" fstype)
	echo "$t"
}
inv_blk_or_lsblk() {   # NAME KEY: blkid value, else lsblk's
	local l=${LSB_LINE[$1]:-} v; v=$(kvget "${BLKID_LINE[$(kvget "$l" path)]:-}" "$2")
	[ -n "$v" ] || v=$(kvget "$l" "$2")
	echo "$v"
}
inv_skip_dev() { case $1 in loop*|zram*|ram[0-9]*|sr[0-9]*|fd[0-9]*|nbd*) return 0;; esac; return 1; }
# --- old util-linux: what lsblk cannot tell us, from blkid and the table itself -------
# inv_ptuuid_raw DEV PTTYPE: the partition table's own id, read from the device
# (blkid of that generation does not report PTUUID). dos: the four bytes at 440,
# which is exactly what sfdisk calls label-id. gpt: the disk GUID in the header
# at LBA 1 + 56, first three fields little endian, as everyone prints it.
inv_ptuuid_raw() {
	local dev=$1 w b
	case $2 in
		dos) w=$(od -An -tx4 -j440 -N4 "$dev" 2>/dev/null | tr -d ' \n'); [ -n "$w" ] && printf '%s\n' "$w" ;;
		gpt) b=$(od -An -tx1 -j568 -N16 "$dev" 2>/dev/null | tr -d ' \n')
		     [ ${#b} -eq 32 ] || return 0
		     printf '%s%s%s%s-%s%s-%s%s-%s-%s\n' "${b:6:2}" "${b:4:2}" "${b:2:2}" "${b:0:2}" \
		            "${b:10:2}" "${b:8:2}" "${b:14:2}" "${b:12:2}" "${b:16:4}" "${b:20:12}" ;;
	esac
}
# inv_lsblk_fill: key=value records in, the same plus path=, and for a disk
# pttype=/ptuuid=, for a partition parttype=/partflags= (blkid -p: PART_ENTRY_*)
inv_lsblk_fill() {
	local line name type path bk v
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		name=$(kvget "$line" name); type=$(kvget "$line" type)
		path=/dev/$name
		[ -b "$path" ] || { [ -b "/dev/mapper/$name" ] && path=/dev/mapper/$name; }
		line+=$'\t'"path=$path"
		bk=$(blkid -p -o export "$path" 2>/dev/null | tr '\n' '\t')
		case $type in
			disk)
				v=$(kvget "$bk" PTTYPE); line+=$'\t'"pttype=$v"
				line+=$'\t'"ptuuid=$(inv_ptuuid_raw "$path" "$v")" ;;
			part)
				v=$(kvget "$bk" PART_ENTRY_TYPE); line+=$'\t'"parttype=$v"
				line+=$'\t'"partflags=$(kvget "$bk" PART_ENTRY_FLAGS)"
				# a dos PARTUUID is <label-id>-<nn>, which util-linux synthesises only
				# from 2.25 on; without it a donor that says PARTUUID= in fstab or on
				# the kernel command line could not be resolved at all
				if [ -z "$(kvget "$line" partuuid)" ] && [ "$(kvget "$bk" PART_ENTRY_SCHEME)" = dos ]; then
					local par pid num pu
					par=$(kvget "$line" pkname); num=$(kvget "$bk" PART_ENTRY_NUMBER)
					pid=; [ -z "$par" ] || pid=$(inv_ptuuid_raw "/dev/$par" dos)
					if [ -n "$pid" ] && [ -n "$num" ]; then
						pu=$(printf '%s-%02d' "$pid" "$num")
						# the empty partuuid= is already in the record and kvget takes the
						# first match, so the value has to replace it, not follow it
						line=$(printf '%s' "$line" | sed "s|\tpartuuid=\t|\tpartuuid=$pu\t|; s|\tpartuuid=\$|\tpartuuid=$pu|")
					fi
				fi ;;
		esac
		printf '%s\n' "$line"
	done
}
# inv_lv_path DEV: lsblk and blkid name an LV /dev/mapper/<vg>-<lv> (dashes doubled);
# the lv records, the plan and format.md name it by its lv_path /dev/<vg>/<lv>, so
# the fs and swap records of an LV must carry that name too (anything else: DEV)
inv_lv_path() {
	local path vg lv
	case $1 in /dev/mapper/*) ;; *) printf '%s\n' "$1"; return 0;; esac
	while IFS='|' read -r path vg lv _; do
		[ -n "$path" ] && [ "/dev/mapper/${vg//-/--}-${lv//-/--}" = "$1" ] && { printf '%s\n' "$path"; return 0; }
	done <<< "$LVS"
	printf '%s\n' "$1"
}

# --- host -------------------------------------------------------------------------------
inv_emit_host() {
	local role=$1 hn live fw sb=0 v bootnic bootmac bootip gw ncpu ram awkv
	hn=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null); : "${hn:=-}"
	live=$({ sed -n 's/^BUILD_ID=//p' /etc/reloca-live-release 2>/dev/null; sed -n 's/^BUILD_ID=//p' /etc/xserver-live-release 2>/dev/null; } | head -1); : "${live:=-}"
	if [ -d /sys/firmware/efi ]; then fw=uefi; else fw=bios; fi
	if [ "$fw" = uefi ]; then
		# efivar layout: 4 bytes of attributes, then the value
		v=$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
		[ "$v" = 1 ] && sb=1
	fi
	cap proc-cmdline cat /proc/cmdline >/dev/null
	read -r bootnic bootmac <<< "$(inv_boot_nic)"
	bootip=-; gw=-
	[ "$bootnic" != - ] && bootip=$(ip -o -4 addr show dev "$bootnic" 2>/dev/null | awk '{print $4; exit}'); : "${bootip:=-}"
	gw=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'); : "${gw:=-}"
	ncpu=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo); : "${ncpu:=-}"
	ram=$(awk '/^MemTotal:/ {printf "%.0f\n", $2*1024; exit}' /proc/meminfo 2>/dev/null); : "${ram:=-}"
	case $(awk -W version 2>&1 | head -1) in mawk*) awkv=mawk;; GNU*) awkv=gawk;; *) awkv=other;; esac
	rec host "role=$role" "hostname=$hn" "live=$live" "fw=$fw" "secureboot=$sb" "bootnic=$bootnic" "bootmac=$bootmac" \
		"bootip=$bootip" "gw=$gw" "dmi_vendor=$(sysval /sys/class/dmi/id/sys_vendor)" "dmi_product=$(sysval /sys/class/dmi/id/product_name)" \
		"dmi_serial=$(sysval /sys/class/dmi/id/product_serial)" "dmi_uuid=$(sysval /sys/class/dmi/id/product_uuid)" "ncpu=$ncpu" "ram=$ram" "awk=$awkv" \
		"online=$([ -n "$INV_ONLINE" ] && echo 1 || echo 0)" "tar=$(have tar && echo 1 || echo 0)"
}

# --- disks: what they are and what is on them now (the WILL BE WIPED gate) ---------
inv_disk_usage() {   # NAME DEV: old-os > md > lvm > fs > parts > sig > free
	local n=$1 dev=$2 k l ft p os first="" nparts=0 sig
	for k in $n $(inv_descendants "$n"); do
		l=${LSB_LINE[$k]:-}; [ -n "$l" ] || continue
		p=$(kvget "$l" path); ft=$(inv_fstype_of "$k")
		[ "$(kvget "$l" type)" = part ] && nparts=$((nparts+1))
		case $ft in
			ext2|ext3|ext4|xfs|btrfs)
				os=$(inv_probe_os "$p" "$ft"); [ -n "$os" ] && { echo "old-os:$os"; return 0; }
				[ -n "$first" ] || first=fs:$ft ;;
			linux_raid_member) [ -n "$first" ] || first=md:$(inv_md_uuid_norm "$(inv_blk_or_lsblk "$k" uuid)") ;;
			LVM2_member) [ -n "$first" ] || first=lvm:${PV_VG[$p]:-?} ;;
			'') ;;
			*) [ -n "$first" ] || first=fs:$ft ;;
		esac
	done
	[ -n "$first" ] && { echo "$first"; return 0; }
	[ "$nparts" -gt 0 ] && { echo "parts:$nparts"; return 0; }
	sig=$(cap "wipefs-n-$(rawname "$dev")" wipefs -n "$dev" | awk 'NR>1 && $3!="" {print $3; exit}')
	if [ -n "$sig" ]; then echo "sig:$sig"; else echo free; fi
}
inv_emit_disks() {
	local n l dev chain drivers modalias v tran
	for n in "${LSB_ORDER[@]}"; do
		l=${LSB_LINE[$n]}
		[ "$(kvget "$l" type)" = disk ] || continue
		inv_skip_dev "$n" && continue
		dev=$(kvget "$l" path)
		chain=$(sysfs_chain "/sys/class/block/$n/device")
		drivers=$(kvget "$chain" drivers); modalias=$(kvget "$chain" modalias)
		v=$(kvget "$l" pttype); tran=$(kvget "$l" tran)
		rec disk "dev=$dev" "size=$(kvget "$l" size)" "lsec=$(kvget "$l" log_sec)" "psec=$(kvget "$l" phy_sec)" \
			"model=$(trim "$(kvget "$l" model)")" "serial=$(trim "$(kvget "$l" serial)")" "wwn=$(trim "$(kvget "$l" wwn)")" \
			"byid=$(inv_byid "$dev")" "tran=${tran:--}" "rm=$(kvget "$l" rm)" "ro=$(kvget "$l" ro)" \
			"pttype=${v:--}" "ptuuid=$(kvget "$l" ptuuid)" "drivers=${drivers:--}" "modalias=${modalias:--}" "usage=$(inv_disk_usage "$n" "$dev")"
	done
}
# --- partitions: sfdisk's dump (the plan rewrites it) merged with lsblk's view ---------
inv_emit_parts() {
	local n l dev line pdev pl fstype partuuid name
	for n in "${LSB_ORDER[@]}"; do
		l=${LSB_LINE[$n]}
		inv_skip_dev "$n" && continue
		case $(kvget "$l" type) in disk|raid*) ;; *) continue;; esac
		[ -n "$(kvget "$l" pttype)" ] || continue
		dev=$(kvget "$l" path)
		while IFS= read -r line; do
			[ "$(kvget "$line" kind)" = part ] || continue
			# util-linux 2.23 dumps the unused slots of a dos table as "start=0, size=0"
			case $(kvget "$line" size) in ''|0) continue;; esac
			pdev=$(kvget "$line" dev); pl=${LSB_LINE[${pdev#/dev/}]:-}
			[ -n "$pl" ] || pl=${LSB_LINE[$(basename "$(readlink -f "$pdev" 2>/dev/null)" 2>/dev/null)]:-}
			fstype=$(inv_fstype_of "${pdev#/dev/}")
			partuuid=$(kvget "$pl" partuuid); [ -n "$partuuid" ] || partuuid=$(kvget "$line" uuid)
			name=$(kvget "$line" name); [ -n "$name" ] || name=$(kvget "$pl" partlabel)
			rec part "dev=$pdev" "disk=$dev" "num=$(kvget "$line" num)" "start=$(kvget "$line" start)" "size=$(kvget "$line" size)" \
				"type=$(kvget "$line" type)" "bootable=$(kvget "$line" bootable)" "partuuid=$partuuid" "name=$name" \
				"fstype=${fstype:--}" "ptype=$(kvget "$line" ptype)"
		done < <(if have sfdisk; then cap "sfdisk-d-$(rawname "$dev")" sfdisk -d "$dev" | parse_sfdisk_dump; else inv_parts_sysfs "$n"; fi)
	done
}
# inv_parts_sysfs NAME: the same kind=part lines parse_sfdisk_dump makes, from
# sysfs and lsblk, for a donor without sfdisk (it lives in Debian's fdisk
# package, which a minimal install lacks; nothing is installed on an on-line
# donor). start/size from /sys, type/partuuid/label/flags from lsblk (dos:
# 0x80 = bootable; gpt: attribute bit 2 = LegacyBIOSBootable). A dos extended
# partition shows the 1 KiB the kernel gives it, not its real extent.
inv_parts_sysfs() {
	local n=$1 label p pname pl num type uuid name flags boot ptype start size
	label=$(kvget "${LSB_LINE[$n]}" pttype)
	for p in /sys/class/block/"$n"/"$n"*; do
		[ -r "$p/partition" ] || continue
		pname=${p##*/}; pl=${LSB_LINE[$pname]:-}; [ -n "$pl" ] || continue
		num=$(cat "$p/partition"); start=$(cat "$p/start" 2>/dev/null); size=$(cat "$p/size" 2>/dev/null)
		type=$(kvget "$pl" parttype); type=${type#0x}
		[ "$label" != gpt ] || type=${type^^}
		uuid=$(kvget "$pl" partuuid); name=$(kvget "$pl" partlabel); flags=$(kvget "$pl" partflags)
		boot=0
		case $label in
			dos) [ "${flags,,}" != 0x80 ] || boot=1 ;;
			gpt) [ $(( ${flags:-0} & 4 )) -eq 0 ] 2>/dev/null || boot=1 ;;
		esac
		ptype=primary
		if [ "$label" = dos ]; then
			case ${type,,} in 5|f|85) ptype=extended;; *) [ "${num:-0}" -gt 4 ] && ptype=logical;; esac
		fi
		printf 'kind=part\tdev=/dev/%s\tstart=%s\tsize=%s\ttype=%s\tuuid=%s\tname=%s\tnum=%s\tbootable=%s\tptype=%s\n' \
			"$pname" "$start" "$size" "$type" "$uuid" "$name" "$num" "$boot" "$ptype"
	done | sort -t$'\t' -k8,8n
}
# --- md ---------------------------------------------------------------------------------
inv_md_state() {   # NAME -> "state ro" from sysfs
	local s=/sys/block/$1/md st ro=0 a
	a=$(cat "$s/array_state" 2>/dev/null)
	case $a in readonly|read-auto) ro=1;; esac
	if [ "$(cat "$s/degraded" 2>/dev/null)" = 1 ]; then st=degraded
	elif [ -n "$(cat "$s/sync_action" 2>/dev/null)" ] && [ "$(cat "$s/sync_action" 2>/dev/null)" != idle ]; then st=resync
	elif [ "$a" = clean ] || [ "$a" = readonly ] || [ "$a" = read-auto ]; then st=clean
	else st=${a:-active}; fi
	echo "$st $ro"
}
inv_emit_md() {
	local n l dev kv members first size off st ro
	for n in "${LSB_ORDER[@]}"; do
		l=${LSB_LINE[$n]}
		case $n in md*) ;; *) continue;; esac
		[ -d "/sys/block/$n/md" ] || continue
		dev=$(kvget "$l" path)
		kv=$(cap "mdadm-detail-$n" mdadm --detail --export "$dev" | parse_mdadm_export)
		members=$(kvget "$kv" members); first=${members%%,*}
		size=$(blockdev --getsize64 "$dev" 2>/dev/null); [ -n "$size" ] || size=$(kvget "$l" size)
		off=0; [ -n "$first" ] && off=$(cap "mdadm-examine-$(rawname "$first")" mdadm --examine "$first" | parse_mdadm_examine)
		read -r st ro <<< "$(inv_md_state "$n")"
		rec md "dev=$dev" "level=$(kvget "$kv" level)" "uuid=$(kvget "$kv" uuid)" "name=$(kvget "$kv" name)" "metadata=$(kvget "$kv" metadata)" \
			"size=$size" "members=$members" "data_offset=$off" "state=$st" "ro=$ro"
	done
}
# --- LVM ---------------------------------------------------------------------------------
inv_emit_lvm() {
	local dev uuid vg size pe name free pvlist path lvname seg seen=" " segs
	[ -n "$PVS" ] && while IFS='|' read -r dev uuid vg size pe; do
		[ -n "$dev" ] && rec pv "dev=$dev" "uuid=$uuid" "vg=$vg" "size=$size" "pe_start=$pe"
	done <<< "$PVS"
	[ -n "$VGS" ] && while IFS='|' read -r name uuid size free _; do
		[ -n "$name" ] || continue
		pvlist=$(awk -F'|' -v v="$name" '$3==v {printf "%s%s", (n++?",":""), $1}' <<< "$PVS")
		rec vg "name=$name" "uuid=$uuid" "size=$size" "free=$free" "pvs=${pvlist:--}"
	done <<< "$VGS"
	# lvs prints one row per segment: one record per LV, segment types joined
	[ -n "$LVS" ] && while IFS='|' read -r path vg lvname uuid size seg; do
		[ -n "$path" ] || continue
		case $seen in *" $path "*) continue;; esac; seen+="$path "
		segs=$(awk -F'|' -v p="$path" '$1==p && !s[$6]++ {printf "%s%s", (n++?",":""), $6}' <<< "$LVS")
		rec lv "path=$path" "vg=$vg" "name=$lvname" "uuid=$uuid" "size=$size" "segtype=${segs:-$seg}"
	done <<< "$LVS"
	return 0
}
# --- filesystems: raw feature masks, so mkfs on the recipient can be checked ----------
inv_fs_ext() {   # DEV TYPE UUID LABEL
	local dev=$1 kv bs m min=-
	kv=$(cap "dumpe2fs-h-$(rawname "$dev")" dumpe2fs -h "$dev" | parse_dumpe2fs)
	[ -n "$kv" ] || { inv_warn "dumpe2fs -h $dev failed: features unknown"; inv_fs_other "$@"; return 0; }
	bs=$(kvget "$kv" bs)
	# resize2fs -P only reads; it refuses a filesystem that needs recovery (then min=-)
	m=$(cap "resize2fs-P-$(rawname "$dev")" resize2fs -P "$dev" | sed -n 's/.*: *\([0-9][0-9]*\)[^0-9]*$/\1/p' | tail -1)
	[ -n "$m" ] && [ -n "$bs" ] && min=$((m*bs))
	rec fs "dev=$dev" "type=$2" "uuid=$(kvget "$kv" uuid)" "label=$(kvget "$kv" label)" "fssize=$(kvget "$kv" fssize)" "used=$(kvget "$kv" used)" \
		"inodes_used=$(kvget "$kv" inodes_used)" "inodes_total=$(kvget "$kv" inodes_total)" "min=$min" "state=$(kvget "$kv" state)" \
		"bs=$bs" "isz=$(kvget "$kv" isz)" "features=$(kvget "$kv" features)" "journal_features=$(kvget "$kv" journal_features)" \
		"ssz=-" "dirbs=-" "masks=$(kvget "$kv" masks)" "volid=-"
}
inv_fs_xfs() {   # DEV TYPE UUID LABEL SIZE
	local dev=$1 kv state=- lp
	if ! have xfs_db; then
		inv_warn "xfs_db not installed (xfsprogs comes with bootstrap): $dev features and state unknown"
		inv_fs_other "$@"; return 0
	fi
	kv=$(cap "xfs_db-$(rawname "$dev")" xfs_db -r -c version -c 'sb 0' -c 'p blocksize sectsize inodesize dirblklog dblocks fdblocks icount ifree versionnum features2 features_compat features_ro_compat features_incompat features_log_incompat' "$dev" | parse_xfs_db)
	[ -n "$kv" ] || { inv_warn "xfs_db failed on $dev: features unknown"; inv_fs_other "$@"; return 0; }
	if have xfs_logprint; then
		lp=$(cap "xfs_logprint-t-$(rawname "$dev")" xfs_logprint -t "$dev")
		case $lp in *'<DIRTY>'*) state=dirty;; *'<CLEAN>'*) state=clean;; esac
	fi
	rec fs "dev=$dev" "type=xfs" "uuid=$3" "label=$4" "fssize=$(kvget "$kv" fssize)" "used=$(kvget "$kv" used)" \
		"inodes_used=$(kvget "$kv" inodes_used)" "inodes_total=$(kvget "$kv" inodes_total)" "min=-" "state=$state" \
		"bs=$(kvget "$kv" bs)" "isz=$(kvget "$kv" isz)" "features=$(kvget "$kv" features)" "journal_features=-" \
		"ssz=$(kvget "$kv" ssz)" "dirbs=$(kvget "$kv" dirbs)" "masks=$(kvget "$kv" masks)" "volid=-"
}
inv_fs_other() {   # DEV TYPE UUID LABEL SIZE: blkid/lsblk only (vfat, btrfs, ntfs, LUKS, ...)
	local volid=-
	# blkid prints the volume id as XXXX-XXXX; mkfs.vfat -i wants the eight hex digits
	[ "$2" = vfat ] && { volid=${3//-/}; volid=${volid:--}; }
	rec fs "dev=$1" "type=$2" "uuid=$3" "label=$4" "fssize=${5:--}" "used=-" "inodes_used=-" "inodes_total=-" "min=-" "state=-" \
		"bs=-" "isz=-" "features=-" "journal_features=-" "ssz=-" "dirbs=-" "masks=-" "volid=$volid"
}
inv_emit_fs() {
	local n l dev fstype uuid label size swaps=
	for n in "${LSB_ORDER[@]}"; do
		l=${LSB_LINE[$n]}
		inv_skip_dev "$n" && continue
		fstype=$(inv_fstype_of "$n"); [ -n "$fstype" ] || continue
		dev=$(inv_lv_path "$(kvget "$l" path)"); uuid=$(inv_blk_or_lsblk "$n" uuid); label=$(inv_blk_or_lsblk "$n" label); size=$(kvget "$l" size)
		case $fstype in
			linux_raid_member|LVM2_member) ;;
			swap) swaps+="$(rec swap "dev=$dev" "uuid=$uuid" "label=$label" "size=$size")"$'\n' ;;
			ext2|ext3|ext4) inv_fs_ext "$dev" "$fstype" "$uuid" "$label" "$size" ;;
			xfs) inv_fs_xfs "$dev" "$fstype" "$uuid" "$label" "$size" ;;
			*) inv_fs_other "$dev" "$fstype" "$uuid" "$label" "$size" ;;
		esac
	done
	[ -n "$swaps" ] && printf '%s' "$swaps"
	return 0
}
# --- NICs --------------------------------------------------------------------------------
inv_emit_nics() {
	local d n mac drv chain modalias pci speed link fw onboard
	for d in /sys/class/net/*; do
		n=${d##*/}; [ "$n" = lo ] && continue; [ -e "$d" ] || continue
		mac=$(cat "$d/address" 2>/dev/null); : "${mac:=-}"
		drv=-; modalias=-; pci=-
		if [ -e "$d/device" ]; then
			[ -L "$d/device/driver" ] && drv=$(basename "$(readlink "$d/device/driver")")
			chain=$(sysfs_chain "$d/device"); modalias=$(kvget "$chain" modalias); : "${modalias:=-}"
			pci=$(sysfs_pci_addr "$d/device")
		fi
		speed=$(cat "$d/speed" 2>/dev/null); case $speed in ''|-*|0) speed=-;; esac
		link=$(cat "$d/operstate" 2>/dev/null); case $link in up|down) ;; *) link=-;; esac
		fw=-; [ "$drv" != - ] && fw=$(modinfo -F firmware "$drv" 2>/dev/null | paste -sd, -); : "${fw:=-}"
		onboard=$(cat "$d/device/acpi_index" 2>/dev/null || cat "$d/device/index" 2>/dev/null); : "${onboard:=-}"
		rec nic "name=$n" "mac=$mac" "driver=$drv" "modalias=$modalias" "pci=$pci" "speed=$speed" "link=$link" "firmware=$fw" "onboard=$onboard"
	done
}

# ==================================================================================
# Donor: storage read-only first, then the installed system
# ==================================================================================
# Every array the Live's udev assembled is read-write: a resync could be running
# on it and would keep writing under the copy, and a degraded array that we
# read must never start one. So: refuse a resync in progress, mdadm --readonly
# the rest, assemble what udev skipped (foreign homehost) read-only from their
# own metadata, and only then activate LVM (device-mapper falls back to
# read-only tables on read-only PVs; lvm warns, we ignore).
inv_md_check_and_ro() {
	local md
	while read -r md; do
		[ -n "$md" ] || continue
		if awk -v m="$md" '$1==m {f=1; next} /^ *$/ {f=0} f && /(resync|recovery|reshape|check) *= *[0-9]/ {found=1} END {exit !found}' /proc/mdstat; then
			inv_fatal "resync in progress on /dev/$md: the donor must be quiet (wait for it to finish, then retry)"
		fi
		# already readonly (this runs twice: before and after the assemble pass) -> the
		# kernel answers a second STOP_ARRAY_RO with ENXIO, which is not a failure
		[ "$(cat "/sys/block/$md/md/array_state" 2>/dev/null)" = readonly ] && continue
		mdadm --readonly "/dev/$md" >/dev/null 2>&1 || inv_warn "mdadm --readonly /dev/$md failed (array_state $(cat "/sys/block/$md/md/array_state" 2>/dev/null)); nothing is mounted read-write, continuing"
	done < <(awk '/^md[0-9]+ *:/ {print $1}' /proc/mdstat 2>/dev/null)
}
inv_donor_prepare() {
	local run=${RUN:-/run/reloca.to}
	mkdir -p "$run" 2>/dev/null
	# LVM auto-activation holds the arrays open (EBUSY for --readonly): drop it first
	have vgchange && vgchange -an >/dev/null 2>&1
	inv_md_check_and_ro
	if have mdadm; then
		mdadm --examine --scan > "$run/md.conf" 2>/dev/null
		[ -s "$run/md.conf" ] && mdadm --assemble --scan --config="$run/md.conf" --run -o >/dev/null 2>&1
		inv_md_check_and_ro
	fi
	have vgchange && vgchange -ay >/dev/null 2>&1
	udevadm settle 2>/dev/null
	return 0
}
# inv_donor_find_root: every part/lvm/raid device with ext/xfs/btrfs that holds
# /etc/fstab and /sbin/init; the one with an os-release wins. Mounted at
# $INV_MNT/root, then /boot, /boot/efi (or /efi) from its fstab, read-only.
inv_donor_find_root() {
	local n l fstype dev root="" cand="" others="" mp spec type opts fstab
	INV_ROOT=$INV_MNT/root
	for n in "${LSB_ORDER[@]}"; do
		l=${LSB_LINE[$n]}
		inv_skip_dev "$n" && continue
		case $(kvget "$l" type) in part|lvm|raid*|crypt|disk) ;; *) continue;; esac
		fstype=$(inv_fstype_of "$n"); case $fstype in ext2|ext3|ext4|xfs|btrfs) ;; *) continue;; esac
		dev=$(kvget "$l" path)
		inv_mount "$dev" "$INV_ROOT" "$fstype" || continue
		if [ -e "$INV_ROOT/etc/fstab" ] && { [ -e "$INV_ROOT/sbin/init" ] || [ -L "$INV_ROOT/sbin/init" ]; }; then
			if [ -z "$root" ] && { [ -e "$INV_ROOT/etc/os-release" ] || [ -e "$INV_ROOT/usr/lib/os-release" ]; }; then root=$dev; INV_ROOT_FS=$fstype
			elif [ -z "$cand" ]; then cand=$dev; INV_CAND_FS=$fstype
			else others+=" $dev"; fi
		fi
		inv_umount "$INV_ROOT"
	done
	if [ -z "$root" ] && [ -n "$cand" ]; then root=$cand; INV_ROOT_FS=$INV_CAND_FS; cand=; fi
	[ -n "$root" ] || inv_fatal "no installed root filesystem found on the donor (a root holds /etc/fstab and /sbin/init); candidates: $(lsblk -rno PATH,FSTYPE 2>/dev/null | awk '$2!="" {printf "%s(%s) ", $1, $2}')"
	[ -n "$cand$others" ] && inv_warn "more than one root-like filesystem: using $root, ignoring$cand$others"
	inv_mount "$root" "$INV_ROOT" "$INV_ROOT_FS" || inv_fatal "cannot mount $root read-only at $INV_ROOT"
	INV_ROOT_DEV=$root
	inv_note "donor root $root ($INV_ROOT_FS) mounted at $INV_ROOT"
	fstab=$(parse_fstab < "$INV_ROOT/etc/fstab")
	for mp in /boot /boot/efi /efi; do
		read -r spec type opts <<< "$(awk -F'\t' -v m="mount=$mp" '{for (i=1;i<=NF;i++) if ($i==m) {s=$1; t=$3; o=$4} } END {if (s!="") {sub(/^spec=/,"",s); sub(/^type=/,"",t); sub(/^opts=/,"",o); print s, t, o}}' <<< "$fstab")"
		[ -n "${spec:-}" ] || continue
		[ -d "$INV_ROOT$mp" ] || { inv_warn "fstab mounts $mp but the directory is missing in the root"; continue; }
		case $opts in *bind*) continue;; esac
		dev=$(inv_resolve_spec "$spec")
		[ "$dev" != - ] || { inv_warn "$mp: $spec does not resolve on this Live; kernels/grub under $mp may be missing from the inventory"; continue; }
		if inv_mount "$dev" "$INV_ROOT$mp" "$type"; then inv_note "mounted $dev at $mp ($type, read-only)"
		else inv_warn "cannot mount $dev ($type) at $mp read-only"; fi
	done
	return 0
}
# --- the installed system (INV_ROOT = mounted tree, or --root DIR) ----------------------
inv_osrel() {   # KEY: os-release value, quotes stripped
	local f=$INV_ROOT/etc/os-release
	[ -r "$f" ] || f=$INV_ROOT/usr/lib/os-release
	inv_shvar "$1" "$f" 2>/dev/null || echo
}
inv_kernel_records() {
	local R=$INV_ROOT f ver initrd i aliases builtin pci
	for f in "$R"/boot/vmlinuz-*; do
		[ -f "$f" ] || continue
		ver=${f##*/vmlinuz-}
		# rescue kernels and leftovers of removed packages have no module tree
		[ -f "$R/lib/modules/$ver/modules.dep" ] || continue
		initrd=-
		for i in "/boot/initramfs-$ver.img" "/boot/initrd.img-$ver" "/boot/initrd-$ver.img" "/boot/initrd-$ver"; do [ -f "$R$i" ] && { initrd=$i; break; }; done
		aliases=-; [ -f "$R/lib/modules/$ver/modules.alias" ] && aliases=/lib/modules/$ver/modules.alias
		builtin=-; [ -f "$R/lib/modules/$ver/modules.builtin" ] && builtin=/lib/modules/$ver/modules.builtin
		raw_tree "$aliases" "$builtin"
		pci=-
		[ -n "$INV_MODALIAS" ] && [ "$aliases" != - ] && pci=$(match_modalias "$R$aliases" "$R$builtin" "$INV_MODALIAS")
		rec kernel "version=$ver" "vmlinuz=/boot/vmlinuz-$ver" "initrd=$initrd" "aliases=$aliases" "builtin=$builtin" "pci_drivers=$pci"
	done
}
inv_cmdline_records() {
	local R=$INV_ROOT f k v
	if [ -f "$R/etc/default/grub" ]; then
		raw_tree /etc/default/grub
		for k in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
			v=$(inv_shvar "$k" "$R/etc/default/grub") && rec cmdline source=grub-default "key=$k" "value=$v"
		done
	fi
	for f in "$R"/etc/default/grub.d/*.cfg; do
		[ -f "$f" ] || continue; raw_tree "${f#"$R"}"
		for k in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
			v=$(inv_shvar "$k" "$f") && rec cmdline "source=grub.d:${f##*/}" "key=$k" "value=$v"
		done
	done
	if [ -f "$R/etc/kernel/cmdline" ]; then
		raw_tree /etc/kernel/cmdline
		rec cmdline source=kernel-cmdline key=options "value=$(head -1 "$R/etc/kernel/cmdline")"
	fi
	for f in "$R"/boot/loader/entries/*.conf; do
		[ -f "$f" ] || continue; raw_tree "${f#"$R"}"
		rec cmdline "source=bls:${f##*/}" key=options "value=$(sed -n 's/^options[[:space:]]\{1,\}//p' "$f" | head -1)"
	done
	# grub2/grubenv is often a symlink into the ESP: the first readable one is the one grub uses
	for f in "$R"/boot/grub2/grubenv "$R"/boot/grub/grubenv "$R"/boot/efi/EFI/*/grubenv; do
		[ -f "$f" ] || continue; raw_tree "${f#"$R"}"
		v=$(sed -n 's/^kernelopts=//p' "$f" | head -1)
		[ -n "$v" ] && rec cmdline source=grubenv key=kernelopts "value=$v"
		break
	done
	return 0
}
inv_os_record() {   # FSTAB_KV NKERNELS CMDLINE_RECORDS
	local R=$INV_ROOT fstab=$1 nk=$2 cmdlines=$3 id like ver pretty family hn initramfs grub grubcfg=- bls=0 efidir=- selinux=- cloudinit=0
	local kind prim iface=- mac=- ip=- gw=- all ifnames biosdev mid f
	id=$(inv_osrel ID); like=$(inv_osrel ID_LIKE); ver=$(inv_osrel VERSION_ID); pretty=$(inv_osrel PRETTY_NAME)
	raw_tree /etc/os-release /usr/lib/os-release /etc/hostname /etc/machine-id /etc/selinux/config /etc/dracut.conf /etc/initramfs-tools/initramfs.conf /etc/initramfs-tools/modules
	case $id in
		debian|ubuntu) family=deb ;;
		rhel|centos|rocky|almalinux|ol|fedora) family=rhel ;;
		*) case " $like " in *debian*|*ubuntu*) family=deb;; *rhel*|*fedora*|*centos*) family=rhel;; *) family=unsupported;; esac ;;
	esac
	hn=$(head -1 "$R/etc/hostname" 2>/dev/null); [ -n "$hn" ] || hn=$(inv_shvar HOSTNAME "$R/etc/sysconfig/network" 2>/dev/null); : "${hn:=-}"
	if [ -x "$R/usr/bin/dracut" ] || [ -x "$R/usr/sbin/dracut" ] || [ -e "$R/etc/dracut.conf" ]; then initramfs=dracut
	elif [ -d "$R/etc/initramfs-tools" ]; then initramfs="initramfs-tools"
	else initramfs=-; fi
	if [ -d "$R/boot/grub2" ] || { [ -f "$R/boot/grub/grub.cfg" ] && grep -q '^### BEGIN' "$R/boot/grub/grub.cfg"; } || [ -f "$R/etc/default/grub" ]; then grub=grub2
	elif [ -f "$R/boot/grub/menu.lst" ] && [ ! -f "$R/boot/grub/grub.cfg" ]; then grub=grub1
	else grub=-; fi
	for f in "$R"/boot/grub2/grub.cfg "$R"/boot/grub/grub.cfg "$R"/boot/efi/EFI/*/grub.cfg; do [ -f "$f" ] && { grubcfg=${f#"$R"}; break; }; done
	for f in "$R"/boot/loader/entries/*.conf; do [ -f "$f" ] && { bls=1; break; }; done
	efidir=$(awk -F'\t' '{m=""; t=""; for (i=1;i<=NF;i++) { if ($i ~ /^mount=/) m=substr($i,7); if ($i ~ /^type=/) t=substr($i,6) } if (t=="vfat" && (m=="/boot/efi" || m=="/efi")) {print m; exit}}' <<< "$fstab"); : "${efidir:=-}"
	[ -f "$R/etc/selinux/config" ] && selinux=$(inv_shvar SELINUX "$R/etc/selinux/config" 2>/dev/null); : "${selinux:=-}"
	[ -f "$R/etc/cloud/cloud.cfg" ] && cloudinit=1
	kind=$(netcfg_detect "$R")
	prim=$(netcfg_primary "$kind" "$R")
	if [ -n "$prim" ]; then
		iface=$(kvget "$prim" iface); mac=$(kvget "$prim" mac); ip=$(kvget "$prim" ip); gw=$(kvget "$prim" gw)
		: "${iface:=-}" "${mac:=-}" "${ip:=-}" "${gw:=-}"
	fi
	INV_PRIMARY_NIC=$iface
	all=$(printf '%s\n' "$cmdlines" | while IFS= read -r f; do [ -n "$f" ] && inv_field "$f" value; done | tr '\n' ' ')
	case $all in *net.ifnames=0*) ifnames=kernel;; *) ifnames=predictable;; esac
	biosdev=0
	if [ -e "$R/usr/sbin/biosdevname" ] || [ -e "$R/sbin/biosdevname" ]; then case $all in *biosdevname=0*) biosdev=0;; *) biosdev=1;; esac; fi
	mid=$(head -1 "$R/etc/machine-id" 2>/dev/null); : "${mid:=-}"
	# mdadm in the donor OS: raid=1 postfix installs it when missing (the plan says so up front)
	mdadm=0; for f in "$R/usr/sbin/mdadm" "$R/sbin/mdadm"; do [ -e "$f" ] && mdadm=1; done
	rec os "root=$INV_ROOT_DEV" "id=$id" "like=$like" "version=$ver" "family=$family" "pretty=$pretty" "hostname=$hn" "initramfs=$initramfs" \
		"grub=$grub" "grubcfg=$grubcfg" "bls=$bls" "efidir=$efidir" "selinux=${selinux,,}" "cloudinit=$cloudinit" "netcfg=$kind" \
		"primary_nic=$iface" "primary_mac=${mac,,}" "primary_ip=$ip" "gw=$gw" "ifnames=$ifnames" "biosdevname=$biosdev" "machine_id=$mid" "kernels=$nk" "mdadm=$mdadm"
}
inv_fstab_records() {   # FSTAB_KV
	local l spec
	[ -n "$1" ] || return 0
	while IFS= read -r l; do
		[ -n "$l" ] || continue
		spec=$(kvget "$l" spec)
		rec fstab "spec=$spec" "dev=$(inv_resolve_spec "$spec")" "mount=$(kvget "$l" mount)" "type=$(kvget "$l" type)" \
			"opts=$(kvget "$l" opts)" "dump=$(kvget "$l" dump)" "pass=$(kvget "$l" pass)" "nofail=$(kvget "$l" nofail)"
	done <<< "$1"
}
inv_mdconf_record() {
	local R=$INV_ROOT f="" c lines n
	for c in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do [ -f "$R$c" ] && { f=$c; break; }; done
	[ -n "$f" ] || { rec mdconf file=- arrays=0 lines=-; return 0; }
	raw_tree "$f"
	lines=$(grep -E '^[[:space:]]*ARRAY[[:space:]]' "$R$f" | sed 's/^[[:space:]]*//' | paste -sd';' -)
	n=$(grep -cE '^[[:space:]]*ARRAY[[:space:]]' "$R$f")
	rec mdconf "file=$f" "arrays=$n" "lines=${lines:--}"
}
inv_lvmconf_record() {
	local R=$INV_ROOT f=/etc/lvm/lvm.conf filter=- gf=- udf=- df=0
	[ -f "$R/etc/lvm/devices/system.devices" ] && { df=1; raw_tree /etc/lvm/devices/system.devices; }
	if [ -f "$R$f" ]; then
		raw_tree "$f"
		filter=$(sed -n 's/^[[:space:]]*filter[[:space:]]*=[[:space:]]*//p' "$R$f" | head -1); : "${filter:=-}"
		gf=$(sed -n 's/^[[:space:]]*global_filter[[:space:]]*=[[:space:]]*//p' "$R$f" | head -1); : "${gf:=-}"
		udf=$(sed -n 's/^[[:space:]]*use_devicesfile[[:space:]]*=[[:space:]]*//p' "$R$f" | head -1); : "${udf:=-}"
	else
		f=-
	fi
	rec lvmconf "file=$f" "filter=$filter" "global_filter=$gf" "use_devicesfile=$udf" "devices_file=$df"
}
inv_swapfile_records() {   # FSTAB_KV
	local l spec size
	[ -n "$1" ] || return 0
	while IFS= read -r l; do
		[ -n "$l" ] || continue
		[ "$(kvget "$l" type)" = swap ] || continue
		spec=$(kvget "$l" spec); case $spec in /dev/*|UUID=*|LABEL=*|PARTUUID=*) continue;; /*) ;; *) continue;; esac
		size=$(stat -c %s "$INV_ROOT$spec" 2>/dev/null); : "${size:=-}"
		rec swapfile "path=$spec" "size=$size" "opts=$(kvget "$l" opts)"
	done <<< "$1"
}
# inv_donor_tree: the donor-only records from INV_ROOT, in format.md order
inv_donor_tree() {
	local fstab kernels cmdlines nk
	[ -d "$INV_ROOT" ] || inv_fatal "donor tree $INV_ROOT is not a directory"
	fstab=$(parse_fstab < "$INV_ROOT/etc/fstab" 2>/dev/null)
	raw_tree /etc/fstab
	kernels=$(inv_kernel_records)
	cmdlines=$(inv_cmdline_records)
	nk=$(printf '%s\n' "$kernels" | grep -c '^kernel')
	[ "$nk" -gt 0 ] || inv_warn "no kernel with a module tree under /boot and /lib/modules of the donor"
	inv_os_record "$fstab" "$nk" "$cmdlines"
	[ -n "$kernels" ] && printf '%s\n' "$kernels"
	inv_fstab_records "$fstab"
	[ -n "$cmdlines" ] && printf '%s\n' "$cmdlines"
	inv_mdconf_record
	inv_lvmconf_record
	inv_swapfile_records "$fstab"
	netcfg_records "$INV_ROOT" "$INV_PRIMARY_NIC"
}

# ==================================================================================
# Entry points
# ==================================================================================
# inventory_collect ROLE: the records of this box on stdout, format.md order.
inventory_collect() {
	local role=$1
	[ -n "$INV_RAW" ] && mkdir -p "$INV_RAW"
	if [ "$role" = donor ] && [ -n "$INV_ONLINE" ]; then
		# the running OS: its root is where it is, rw, with /boot and the ESP mounted by it
		INV_ROOT=/
		INV_ROOT_DEV=$(findmnt -rno SOURCE / 2>/dev/null | head -1); : "${INV_ROOT_DEV:=-}"
		INV_ROOT_FS=$(findmnt -rno FSTYPE / 2>/dev/null | head -1)
		[ -b "$INV_ROOT_DEV" ] || inv_fatal "online: the root is not on a block device ($INV_ROOT_DEV): nothing to copy block by block"
		inv_note "online: the running root $INV_ROOT_DEV ($INV_ROOT_FS) is the donor tree; /boot: $(findmnt -rno SOURCE /boot 2>/dev/null || echo 'not a mountpoint')"
	elif [ "$role" = donor ] && [ -z "$INV_ROOT" ]; then inv_donor_prepare; fi
	inv_gather
	echo "# reloca.to inventory role=$role date=$(date -u '+%Y-%m-%dT%H:%M:%SZ') host=$(cat /proc/sys/kernel/hostname 2>/dev/null)"
	inv_emit_host "$role"
	inv_emit_disks
	inv_emit_parts
	inv_emit_md
	inv_emit_lvm
	inv_emit_fs
	inv_emit_nics
	if [ "$role" = donor ]; then
		[ -n "$INV_ROOT" ] || inv_donor_find_root
		inv_donor_tree
		[ -n "$INV_ONLINE" ] || inv_umount_all
	fi
	return 0
}
# inv_modalias_list FILE: name=modalias pairs of the recipient's disk and NIC
# drivers, positionally paired (sysfs_chain lists both from the device up).
inv_modalias_list() {
	local r d m i out="" seen=" "
	local -a ds ms
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		case $r in nic*) [ "$(inv_field "$r" pci)" != - ] || continue;; esac
		d=$(inv_field "$r" drivers); [ -n "$d" ] || d=$(inv_field "$r" driver)
		m=$(inv_field "$r" modalias)
		case $m in ''|-) continue;; esac
		IFS=, read -ra ds <<< "$d"; IFS=, read -ra ms <<< "$m"
		for i in "${!ms[@]}"; do
			d=${ds[$i]:-${ms[$i]%%:*}}
			case $seen in *" $d=${ms[$i]} "*) continue;; esac
			seen+="$d=${ms[$i]} "; out+=",$d=${ms[$i]}"
		done
	done < <(awk -F'\t' '$1=="disk" || $1=="nic"' "$1" 2>/dev/null)
	echo "${out#,}"
}
inv_run_recipient() {   # RAWDIR
	INV_RAW=; [ -n "$1" ] && { INV_RAW=$1/recipient; rm -rf "$INV_RAW"; mkdir -p "$INV_RAW"; }
	mkdir -p "$RUN"
	say "inventory: this box -> $RUN/recipient.inv${INV_RAW:+ (raw files: $INV_RAW)}"
	inventory_collect recipient > "$RUN/recipient.inv" || die "$EX_PLAN" "inventory of this box failed: $(tail -1 "$RUN/recipient.inv" 2>/dev/null)"
	INV_RAW=
	say "inventory: recipient: $(grep -cv '^#' "$RUN/recipient.inv") records, $(inv_records "$RUN/recipient.inv" disk | wc -l) disks"
}
inv_run_donor() {   # RAWDIR
	local -a args=(); local list rc line
	[ -n "${DONOR_HOST:-}" ] || die "$EX_ENV" "not connected to a donor (ssh_connect first)"
	[ -n "$1" ] && args+=(--raw "$DONOR_RUN/raw")
	[ "${RELOCA_MODE:-$(state_get mode)}" != online ] || args+=(--online)
	list=$(inv_modalias_list "$RUN/recipient.inv")
	[ -n "$list" ] && args+=(--modalias "$list")
	mkdir -p "$RUN"
	say "inventory: donor $DONOR_HOST -> $RUN/donor.inv (streaming lib/inventory.sh: bash -s -- --role donor ${args[*]})"
	# stdout is the inventory; the donor's stderr comes back through the log, tagged
	rsh bash -s -- --role donor "${args[@]}" < "$RELOCA_LIB/inventory.sh" 2>&1 > "$RUN/donor.inv" \
		| while IFS= read -r line; do say "donor: $line"; done
	rc=${PIPESTATUS[0]}
	if [ "$rc" -ne 0 ]; then
		line=$(grep '^# ERROR: ' "$RUN/donor.inv" 2>/dev/null | tail -1); line=${line#\# ERROR: }
		[ "$rc" -eq 255 ] && die "$EX_ENV" "ssh to the donor failed during the inventory"
		die "$EX_PLAN" "donor inventory failed (exit $rc): ${line:-see the log}"
	fi
	if [ -n "$1" ]; then
		rm -rf "$1/donor"; mkdir -p "$1/donor"
		if rsh tar -C "$DONOR_RUN" -cf - raw | tar -C "$1/donor" --strip-components=1 -xf -; then
			say "inventory: donor raw files pulled to $1/donor"
		else warn "could not pull the donor's raw files from $DONOR_RUN/raw"; fi
	fi
	say "inventory: donor: $(grep -cv '^#' "$RUN/donor.inv") records, $(inv_records "$RUN/donor.inv" fs | wc -l) filesystems, $(inv_records "$RUN/donor.inv" kernel | wc -l) kernels"
}
# inventory_run ROLE (the driver): both = recipient first (its modaliases go to
# the donor), then the donor. A single role also prints the raw inventory on
# stdout (reloca.to inventory) and the summary on stderr.
inventory_run() {
	local role=${1:-both} rawdir
	rawdir=$(opt raw)
	case $role in
		both)      inv_run_recipient "$rawdir"; inv_run_donor "$rawdir"
		           inventory_summary "$RUN/recipient.inv" | while IFS= read -r line; do say "recipient: $line"; done
		           inventory_summary "$RUN/donor.inv" | while IFS= read -r line; do say "donor: $line"; done ;;
		recipient) inv_run_recipient "$rawdir"; cat "$RUN/recipient.inv"; inventory_summary "$RUN/recipient.inv" >&2 ;;
		donor)     inv_run_donor "$rawdir"; cat "$RUN/donor.inv"; inventory_summary "$RUN/donor.inv" >&2 ;;
		*)         die "$EX_FAIL" "inventory_run: unknown role '$role'" ;;
	esac
}
# inventory_summary FILE: the essentials on one screen
inventory_summary() {
	local f=$1 r
	_h() { case ${1:-} in ''|-) echo -;; *) human "$1";; esac; }
	[ -r "$f" ] || { echo "no inventory at $f"; return 1; }
	r=$(inv_records "$f" host | head -1)
	echo "host: $(inv_field "$r" hostname) role=$(inv_field "$r" role) live=$(inv_field "$r" live) fw=$(inv_field "$r" fw) secureboot=$(inv_field "$r" secureboot) boot=$(inv_field "$r" bootnic)/$(inv_field "$r" bootmac)/$(inv_field "$r" bootip) gw=$(inv_field "$r" gw) dmi=\"$(inv_field "$r" dmi_vendor) $(inv_field "$r" dmi_product)\" serial=$(inv_field "$r" dmi_serial) cpu=$(inv_field "$r" ncpu) ram=$(_h "$(inv_field "$r" ram)") awk=$(inv_field "$r" awk)"
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "disk: $(inv_field "$r" dev) $(_h "$(inv_field "$r" size)") $(inv_field "$r" lsec)/$(inv_field "$r" psec) \"$(inv_field "$r" model)\" byid=$(inv_field "$r" byid) pt=$(inv_field "$r" pttype) drivers=$(inv_field "$r" drivers) usage=$(inv_field "$r" usage)"
	done < <(inv_records "$f" disk)
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "md: $(inv_field "$r" dev) $(inv_field "$r" level) $(_h "$(inv_field "$r" size)") members=$(inv_field "$r" members) meta=$(inv_field "$r" metadata) offset=$(inv_field "$r" data_offset) state=$(inv_field "$r" state) ro=$(inv_field "$r" ro)"
	done < <(inv_records "$f" md)
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "vg: $(inv_field "$r" name) $(_h "$(inv_field "$r" size)") free=$(_h "$(inv_field "$r" free)") pvs=$(inv_field "$r" pvs)"
	done < <(inv_records "$f" vg)
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "lv: $(inv_field "$r" path) $(_h "$(inv_field "$r" size)") $(inv_field "$r" segtype)"
	done < <(inv_records "$f" lv)
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "fs: $(inv_field "$r" dev) $(inv_field "$r" type) $(_h "$(inv_field "$r" fssize)") used=$(_h "$(inv_field "$r" used)") min=$(_h "$(inv_field "$r" min)") state=$(inv_field "$r" state) uuid=$(inv_field "$r" uuid) label=$(inv_field "$r" label)"
	done < <(inv_records "$f" fs)
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "swap: $(inv_field "$r" dev) $(_h "$(inv_field "$r" size)") uuid=$(inv_field "$r" uuid)"
	done < <(inv_records "$f" swap)
	r=$(inv_records "$f" os | head -1)
	[ -n "$r" ] && echo "os: \"$(inv_field "$r" pretty)\" family=$(inv_field "$r" family) hostname=$(inv_field "$r" hostname) root=$(inv_field "$r" root) initramfs=$(inv_field "$r" initramfs) grub=$(inv_field "$r" grub) bls=$(inv_field "$r" bls) efidir=$(inv_field "$r" efidir) selinux=$(inv_field "$r" selinux) netcfg=$(inv_field "$r" netcfg) primary=$(inv_field "$r" primary_nic)/$(inv_field "$r" primary_mac)/$(inv_field "$r" primary_ip) gw=$(inv_field "$r" gw) ifnames=$(inv_field "$r" ifnames) kernels=$(inv_field "$r" kernels)"
	while IFS= read -r r; do [ -n "$r" ] || continue
		echo "kernel: $(inv_field "$r" version) initrd=$(inv_field "$r" initrd) pci_drivers=$(inv_field "$r" pci_drivers)"
	done < <(inv_records "$f" kernel)
	while IFS= read -r r; do [ -n "$r" ] || continue
		[ "$(inv_field "$r" pci)" != - ] || continue
		echo "nic: $(inv_field "$r" name) $(inv_field "$r" mac) $(inv_field "$r" driver) pci=$(inv_field "$r" pci) speed=$(inv_field "$r" speed) link=$(inv_field "$r" link) firmware=$(inv_field "$r" firmware)"
	done < <(inv_records "$f" nic)
	return 0
}
inventory_usage() {
	if [ -r "${BASH_SOURCE[0]:-}" ]; then awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
	else echo "usage: inventory.sh --role donor|recipient [--raw DIR] [--modalias LIST] [--root DIR] [--mnt DIR] [--online]"; fi
}
# inventory_main: the standalone form (bash -s on the donor, or bash lib/inventory.sh)
inventory_main() {
	local role=
	INV_STANDALONE=y
	set -u
	while [ $# -gt 0 ]; do
		case $1 in
			--role)     role=${2:-}; shift 2 ;;
			--raw)      INV_RAW=${2:-}; shift 2 ;;
			--modalias) INV_MODALIAS=${2:-}; shift 2 ;;
			--root)     INV_ROOT=${2:-}; shift 2 ;;
			--online)   INV_ONLINE=y; shift ;;
			--mnt)      INV_MNT=${2:-}; shift 2 ;;
			-h|--help)  inventory_usage; exit 0 ;;
			*)          echo "inventory.sh: unknown argument '$1'" >&2; inventory_usage >&2; exit 2 ;;
		esac
	done
	case $role in donor|recipient) ;; *) echo "inventory.sh: --role donor|recipient is required" >&2; exit 2;; esac
	[ "$(id -u)" = 0 ] || inv_warn "not root: device probes, feature masks and mounts will be incomplete"
	trap inv_umount_all EXIT
	inventory_collect "$role"
}
# Under "bash -s" $0 is "bash" and BASH_SOURCE[0] is empty; run as a script both
# name this file; sourced by the driver they differ and nothing runs.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then inventory_main "$@"; fi
