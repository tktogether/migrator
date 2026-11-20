#!/bin/bash
# live-kexec.sh — reboot THIS server (the migration source, usually at another
# hosting provider where XServer's PXE is not available) into XServer Live OS
# through kexec, keeping its IP address. Nothing on the disks is touched: the
# Live runs from RAM. Afterwards migrator on the destination connects to it.
#
#   curl -fsSL migrator/live | bash             # on the source, as root
#   curl -fsSL migrator/live | bash -s -- -n    # show what would happen
#
# usage: live-kexec.sh [-n] [-y] [-v] [-i IFACE] [-p PASSWORD] [-a PUBKEY] [-d DNS[,DNS]] [-c CMDLINE] [-u URL]
#   -n          dry run: detect, download, build the command line, do not kexec
#   -y          do not ask for confirmation
#   -v          verbose: flavour choice, checksums, the kernel command line, the kexec calls
#   -i IFACE    network interface to carry over (default: the one with the default route)
#   -p PASSWORD root password of the Live (default: generated and printed)
#   -a PUBKEY   ssh public key (file or "ssh-ed25519 AAAA…") for root of the Live, so the
#               destination can log in without the password (Live builds that know authorized_key=)
#   -d DNS      resolver(s) for the Live (default: from /etc/resolv.conf, then 1.1.1.1 8.8.8.8)
#   -c CMDLINE  extra kernel parameters (default: the console= of the running kernel)
#   -u URL      the Live artefacts: a directory holding kernel, image, rootfs and
#               SHA256SUMS. There is no built-in source - the Live is yours to host.
#               This is the kexec path into a Live OS whose initramfs understands
#               root=<URL>/rootfs; our own Live (rig/build-live-debootstrap.sh) does.
# env: MIGRATOR_LIVE_URL (same as -u), MIGRATOR_KEXEC_URL (a static kexec binary for
#      systems without kexec-tools)
# exit: 0 kexec issued (or dry run) · 1 failure · 2 cannot run here (not root, no kexec,
#       no network facts, too little RAM, unsupported interface)
#
# What the Live needs on its command line (XServer Live OS initramfs):
#   ip=IP::GW:MASK:HOST::none:DNS0:DNS1   static network (initramfs-tools ipconfig format)
#   BOOTIF=01-<mac-with-dashes>           which NIC: by MAC, so its name in the Live does not matter
#   root=URL/rootfs                        the squashfs the Live unpacks into tmpfs
#   password=…                             root password (startup-task), console=…
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

DRY=; YES=; VERB=; IFACE=; PASSWORD=; PUBKEY=; DNS=; EXTRA=; URL=${MIGRATOR_LIVE_URL:-}
KEXEC_URL=${MIGRATOR_KEXEC_URL:-}
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }
while getopts "nyvi:p:a:d:c:u:h" o; do
	case $o in
		n) DRY=y ;; y) YES=y ;; v) VERB=y ;; i) IFACE=$OPTARG ;; p) PASSWORD=$OPTARG ;; a) PUBKEY=$OPTARG ;; d) DNS=$OPTARG ;;
		c) EXTRA=$OPTARG ;; u) URL=$OPTARG ;; h) usage 0 ;; *) usage 2 ;;
	esac
done
shift $((OPTIND-1))
say()  { echo "[migrator live] $*"; }
vsay() { [ -z "$VERB" ] || say "$@"; }    # details: only with -v
die()  { local c=1; case "$1" in [0-9]) c=$1; shift;; esac; echo "[migrator live] ERROR: $*" >&2; exit "$c"; }
run()  { if [ -n "$DRY" ]; then echo "(dry) $*"; else [ -z "$VERB" ] || echo "+ $*"; "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -n "$URL" ] || die 2 "no Live artefacts: pass -u URL or set MIGRATOR_LIVE_URL (a directory holding kernel, image, rootfs, SHA256SUMS)"

[ "$(id -u)" = 0 ] || die 2 "run as root"
for t in ip awk sed sha256sum; do have "$t" || die 2 "$t is missing"; done
if have curl; then fetch() { curl -fsSL -o "$2" "$1"; }
elif have wget; then fetch() { wget -q -O "$2" "$1"; }
else die 2 "neither curl nor wget found"; fi

# --- can this kernel kexec, and with what --------------------------------------
[ -e /sys/kernel/kexec_loaded ] || die 2 "this kernel has no kexec support (CONFIG_KEXEC); boot the Live another way (ISO, PXE)"
[ "$(cat /sys/kernel/kexec_loaded 2>/dev/null)" = 0 ] || vsay "a kexec image is already loaded; it will be replaced"
mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
mem_mb=$((mem_kb / 1024))
[ "$mem_mb" -ge 1024 ] || die 2 "only ${mem_mb} MiB RAM: the Live unpacks ~400 MiB into memory and needs at least 1 GiB (1.5 GiB recommended)"
[ "$mem_mb" -ge 1536 ] || say "WARN: ${mem_mb} MiB RAM is tight for the Live (1.5 GiB recommended)"
KEXEC=$(command -v kexec || true)

# --- network facts of the interface that will carry the Live --------------------
[ -n "$IFACE" ] || IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[ -n "$IFACE" ] || die 2 "no default route: pass -i IFACE"
[ -d "/sys/class/net/$IFACE" ] || die 2 "no such interface: $IFACE"
# the Live configures one plain NIC by MAC; a bond/bridge/vlan has no NIC of its own
kind=$(ip -o -d link show dev "$IFACE" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(bond|bridge|vlan|team|macvlan|tun|tap|veth)$/) print $i }' | head -1)
[ -z "$kind" ] || die 2 "$IFACE is a $kind: the Live needs a physical interface; pass -i <nic> (its address must be reachable from the destination)"
[ -e "/sys/class/net/$IFACE/device" ] || say "WARN: $IFACE has no device behind it (virtual?): the Live may not find it by MAC"
MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null); MAC=${MAC,,}
if [ -z "$MAC" ] || [ "$MAC" = 00:00:00:00:00:00 ]; then die 2 "$IFACE has no MAC address"; fi
CIDR=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk '{ print $4; exit }')
[ -n "$CIDR" ] || die 2 "$IFACE has no IPv4 address"
IPADDR=${CIDR%/*}; PREFIX=${CIDR#*/}
GW=$(ip -o -4 route show default dev "$IFACE" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i+1); exit } }')
[ -n "$GW" ] || GW=$(ip -o -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i+1); exit } }')
[ -n "$GW" ] || die 2 "no default gateway on $IFACE"
MASK=$(awk -v p="$PREFIX" 'BEGIN { for (i = 0; i < 4; i++) { b = (p >= 8) ? 255 : (p > 0 ? 256 - 2^(8 - p) : 0); p -= 8; printf "%s%d", (i ? "." : ""), b } }')
if [ -z "$DNS" ]; then
	DNS=$(awk '/^nameserver/ && $2 !~ /^127\./ && $2 !~ /:/ { print $2 }' /etc/resolv.conf 2>/dev/null | head -2 | paste -sd, -)
fi
DNS0=${DNS%%,*}; DNS1=${DNS#*,}; [ "$DNS1" != "$DNS" ] || DNS1=
[ -n "$DNS0" ] || DNS0=1.1.1.1
[ -n "$DNS1" ] || DNS1=8.8.8.8
# serial console of the running kernel is worth keeping (BMC / hoster console)
if [ -z "$EXTRA" ]; then
	EXTRA=$(tr ' ' '\n' < /proc/cmdline | grep '^console=' | paste -sd' ' -)
fi
case " $EXTRA " in *" console=tty0 "*|*" console=tty1 "*) ;; *) EXTRA="console=tty0${EXTRA:+ $EXTRA}";; esac
# the screen: a GPU driver of this OS (mgag200, ast, vmwgfx, i915, ...) switches
# the output off on its way out, and the Live's firmware framebuffer is then no
# longer shown - a frozen console, or "no signal". xsdrm makes the Live load
# its own driver for the GPU and set a mode again (Live builds before 20261114
# ignore it). simpledrm/efifb leave the firmware framebuffer as it was.
GPU_DRV=
for c in /sys/class/drm/card[0-9]*; do
	case ${c##*/} in *-*) continue ;; esac          # connectors: card0-VGA-1
	[ -e "$c/device/driver" ] || continue
	d=$(basename "$(readlink -f "$c/device/driver")")
	case $d in simple-framebuffer|simpledrm|efi-framebuffer|vesa-framebuffer) ;; *) GPU_DRV=$d ;; esac
done
if [ -n "$GPU_DRV" ]; then EXTRA="$EXTRA xsdrm"; vsay "screen: $GPU_DRV here, the Live loads its own GPU driver (xsdrm)"
else vsay "screen: firmware framebuffer, kept as it is"; fi

# --- the Live ------------------------------------------------------------------
WORK=$(mktemp -d /run/migrator-live.XXXXXX 2>/dev/null) || WORK=$(mktemp -d /tmp/migrator-live.XXXXXX) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# which build: the PXE flavour (boot.xserver.cloud/live) is cut down for XServer's
# own hardware; the ISO flavour (FLAVOR=iso in release) carries the drivers and
# firmware of foreign servers (Hyper-V, QLogic, Realtek, ...)
fetch "$URL/release" "$WORK/release" 2>/dev/null || true
BUILD=$(sed -n 's/^BUILD_ID=//p' "$WORK/release" 2>/dev/null)
FLAVOR=$(sed -n 's/^FLAVOR=//p' "$WORK/release" 2>/dev/null); FLAVOR=${FLAVOR:-pxe}
modalias=$(cat "/sys/class/net/$IFACE/device/modalias" 2>/dev/null)
if [ "$FLAVOR" != iso ]; then
	case $modalias in
		vmbus:*) die 2 "$IFACE is a Hyper-V/Azure NIC (vmbus) and the $FLAVOR Live build has no hv_vmbus: use the ISO build (-u URL of it)" ;;
		pci:v00001077*) say "WARN: QLogic FastLinQ NIC: the $FLAVOR Live build has no qed firmware, the network may not come up (the ISO build has it)" ;;
		pci:v000010EC*) say "WARN: Realtek NIC: some RTL8168/8125 need rtl_nic firmware the $FLAVOR Live build lacks (the ISO build has it)" ;;
	esac
	[ -d /sys/bus/vmbus ] && [ "${modalias#vmbus:}" = "$modalias" ] && say "WARN: Hyper-V guest and the $FLAVOR Live build has no hv_vmbus: storage may be invisible (use the ISO build)"
fi
# --- the command line ----------------------------------------------------------
if [ -z "$PASSWORD" ]; then
	PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
fi
HOSTNAME_LIVE=source.migrator
CMDLINE="ip=$IPADDR::$GW:$MASK:$HOSTNAME_LIVE::none:$DNS0:$DNS1 BOOTIF=01-${MAC//:/-} root=$URL/rootfs password=$PASSWORD $EXTRA"
if [ -n "$PUBKEY" ]; then
	[ -r "$PUBKEY" ] && PUBKEY=$(head -1 "$PUBKEY")
	case $PUBKEY in ssh-*|ecdsa-*) ;; *) die 2 "-a: not an ssh public key" ;; esac
	# base64 keeps the spaces of the key line out of the command line
	CMDLINE="$CMDLINE authorized_key=$(printf '%s' "$PUBKEY" | base64 -w0)"
fi

# --- what the operator sees: one box, asked before anything is downloaded ------
# box drawing on a UTF-8 terminal, plain ASCII elsewhere; the password in bold
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) TL=┌ TR=┐ ML=├ MR=┤ BL=└ BR=┘ H=─ V=│ ;;
	*) TL=+ TR=+ ML=+ MR=+ BL=+ BR=+ H=- V='|' ;;
esac
B=; N=; [ -t 1 ] && { B=$'\e[1m'; N=$'\e[0m'; }
TITLE="XServer Live OS ${BUILD:-?}"; [ "$FLAVOR" != iso ] || TITLE="$TITLE (ISO build)"
NOTE="Reboots this server into RAM; disks untouched."
ROWS=("interface|$IFACE  $MAC" "address|$IPADDR/$PREFIX" "gateway|$GW" "dns|$DNS0  $DNS1"
	"hostname|$HOSTNAME_LIVE" "-" "password|$PASSWORD" "ssh|ssh root@$IPADDR" "then|migrator $IPADDR on the destination")
W=50
for t in "$TITLE" "$NOTE"; do [ $(( ${#t} + 4 )) -le "$W" ] || W=$(( ${#t} + 4 )); done
for r in "${ROWS[@]}"; do v=${r#*|}; [ $(( ${#v} + 15 )) -le "$W" ] || W=$(( ${#v} + 15 )); done
hr()   { local s; printf -v s '%*s' "$W" ''; printf '  %s%s%s\n' "$1" "${s// /$H}" "$2"; }
text() { printf '  %s  %-*s%s\n' "$V" $(( W - 2 )) "$1" "$V"; }
kv()   { printf '  %s  %-10s %s%-*s%s%s\n' "$V" "$1" "${3:-}" $(( W - 13 )) "$2" "${3:+$N}" "$V"; }
echo
hr "$TL" "$TR"; text "$TITLE"; text "$NOTE"; hr "$ML" "$MR"
for r in "${ROWS[@]}"; do
	case $r in
		-) hr "$ML" "$MR" ;;
		password\|*) kv password "${r#*|}" "$B" ;;
		*) kv "${r%%|*}" "${r#*|}" ;;
	esac
done
hr "$BL" "$BR"
echo
vsay "kernel command line: $CMDLINE"
if [ -z "$DRY" ] && [ -z "$YES" ]; then
	# under "curl ... | bash" stdin is the script itself: the question goes to
	# the terminal the operator sits at; none (a task, a pipe) means -y is needed
	if [ -t 0 ]; then exec 3<&0
	elif ! { exec 3</dev/tty; } 2>/dev/null; then die 2 "no terminal to confirm (use -y)"; fi
	read -rp "Proceed with the kexec now? [y/N] " -u 3 a; exec 3<&-
	[ "$a" = y ] || [ "$a" = Y ] || { echo "Aborted, nothing changed."; exit 1; }
fi

# --- download and check the Live -------------------------------------------------
if [ -n "$VERB" ]; then say "downloading the Live ${BUILD:-?} ($FLAVOR flavour) from $URL"
else printf 'Downloading the Live... '; fi
fetch "$URL/kernel" "$WORK/kernel" || { [ -n "$VERB" ] || echo; die "cannot download $URL/kernel"; }
fetch "$URL/image"  "$WORK/image"  || { [ -n "$VERB" ] || echo; die "cannot download $URL/image"; }
if fetch "$URL/SHA256SUMS" "$WORK/SHA256SUMS" 2>/dev/null && [ -s "$WORK/SHA256SUMS" ]; then
	(cd "$WORK" && grep -E ' (kernel|image)$' SHA256SUMS | sha256sum -c --quiet) || { [ -n "$VERB" ] || echo; die "checksum mismatch for the downloaded kernel/image"; }
	SUMS=ok
else
	SUMS=
fi
if [ ! -s "$WORK/kernel" ] || [ ! -s "$WORK/image" ]; then [ -n "$VERB" ] || echo; die "empty kernel or image"; fi
[ -n "$VERB" ] || echo "done"
if [ -n "$SUMS" ]; then vsay "kernel and image verified against SHA256SUMS"
else say "WARN: no SHA256SUMS at $URL, downloads not verified"; fi

# kexec binary: the distribution's package, else a static one from migrator.
# systemctl kexec execs /usr/sbin/kexec itself, so the static one lands there.
if [ -z "$KEXEC" ]; then
	if have apt-get; then
		vsay "installing kexec-tools (load_kexec=false: your reboot behaviour is not changed)"
		if [ -z "$DRY" ]; then
			echo "kexec-tools kexec-tools/load_kexec boolean false" | debconf-set-selections 2>/dev/null || true
			DEBIAN_FRONTEND=noninteractive apt-get install -y -q kexec-tools >/dev/null 2>&1 || true
		else echo "(dry) apt-get install -y kexec-tools"; fi
	elif have dnf; then run dnf install -y -q kexec-tools >/dev/null 2>&1 || true
	elif have yum; then run yum install -y -q kexec-tools >/dev/null 2>&1 || true
	fi
	KEXEC=$(command -v kexec || true)
fi
if [ -z "$KEXEC" ] && [ -n "$DRY" ]; then
	echo "(dry) fetch $KEXEC_URL -> /usr/sbin/kexec (no kexec-tools here)"; KEXEC=/usr/sbin/kexec
elif [ -z "$KEXEC" ]; then
	[ -n "$KEXEC_URL" ] || die 2 "no kexec on this system: install kexec-tools, or set MIGRATOR_KEXEC_URL to a static kexec binary"
	vsay "no kexec-tools: fetching a static kexec from $KEXEC_URL"
	fetch "$KEXEC_URL" "$WORK/kexec" || die 2 "no kexec on this system and $KEXEC_URL is unreachable"
	# tried from its final place: /run (initramfs-tools mounts it noexec) and a
	# hardened /tmp refuse to execute anything
	install -m 755 "$WORK/kexec" /usr/sbin/kexec || die 2 "cannot install /usr/sbin/kexec"
	/usr/sbin/kexec --version >/dev/null 2>&1 || { rm -f /usr/sbin/kexec; die 2 "the downloaded kexec does not run here"; }
	KEXEC=/usr/sbin/kexec
	# systemd-shutdown execs its build-time kexec path (/sbin/kexec on older
	# builds) and, before v255, falls back to a PLAIN REBOOT when that exec
	# fails - the box would come back in its own OS; on a split /sbin make
	# sure both names exist
	if [ ! -L /sbin ] && [ -d /sbin ] && [ ! -e /sbin/kexec ]; then ln -s /usr/sbin/kexec /sbin/kexec 2>/dev/null || true; fi
fi
if [ -n "$DRY" ]; then
	echo "Dry run: checked and downloaded, not loading, not rebooting (-v shows the details)."
	exit 0
fi

# kexec_file_load (-s) is the one Secure Boot lockdown allows for a signed
# kernel; the classic syscall is the fallback on kernels without it. Without
# -v the first one's complaint is shown only when the fallback fails too.
if run "$KEXEC" -s -l "$WORK/kernel" --initrd="$WORK/image" --command-line="$CMDLINE" 2>"$WORK/kexec-s.err"; then :
else
	[ -z "$VERB" ] || cat "$WORK/kexec-s.err" >&2
	run "$KEXEC" -c -l "$WORK/kernel" --initrd="$WORK/image" --command-line="$CMDLINE" \
		|| { [ -n "$VERB" ] || cat "$WORK/kexec-s.err" >&2; die "kexec cannot load the Live kernel (lockdown? try with Secure Boot disabled)"; }
fi
rm -rf "$WORK"; trap - EXIT     # the segments live in kernel memory now
echo "Rebooting into the Live. Reconnect in ~1 min: ssh root@$IPADDR"
sync
# systemd stops services and unmounts filesystems before the jump — clean
# journals on the disks migrator is about to read; a bare kexec -e only when
# there is no systemd to do that
if [ -d /run/systemd/system ] && have systemctl; then
	systemctl kexec 2>/dev/null || { sleep 2; exec "$KEXEC" -e; }
else
	exec "$KEXEC" -e
fi
