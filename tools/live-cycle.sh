#!/bin/bash
# live-cycle.sh — put a machine into the migrator Live and come back to it,
# over ssh only. No console, no ISO to attach, no mounting: the artefacts are
# copied to a filesystem of the target, a grub entry is written for them, the
# machine is rebooted, and this script waits until the Live answers.
#
#   tools/live-cycle.sh -H root@192.168.8.111 -S root@192.168.8.117:/root
#
# What it does, in order:
#   1. reads the target's address and default gateway (for migrator.ip=)
#   2. copies vmlinuz-live, initrd-live.img and live/filesystem.squashfs from
#      -S HOST:DIR (or uses -f DIR when the artefacts are already local)
#   3. copies tools/live-entry.sh to the target and runs it there
#   4. reboots, then polls ssh until /etc/migrator-live-release answers
#   5. asserts the three things that decide whether the Live is really up:
#      the release file, swap on zram, and the target disk released by toram
#
# usage: live-cycle.sh -H [USER@]HOST -S [USER@]SRC:DIR | -f DIR  [-i SPEC] [-k KEY] [-s] [-n] [-t SECS]
#   -H HOST   the machine to boot into the Live (ssh)
#   -S SRC:DIR  where the artefacts live, reachable over ssh (e.g. the build host)
#   -f DIR      ...or a local directory that already has them
#   -i SPEC     migrator.ip=IP/PREFIX,GW,DNS (default: the address the target has
#               now, its default gateway, and 114.114.114.114)
#   -k KEY      ssh private key (default $SSH_KEY or ~/.ssh/id_ed25519)
#   -s          make the entry the persistent default (for a run that wipes the
#               disk); without it the entry is one shot, so a plain reboot from
#               the Live returns to the installed system
#   -t SECS     how long to wait for the Live (default 300)
#   -n          dry run: print the plan, copy and reboot nothing
#
# exit: 0 the Live answered · 1 failed (no answer, or the wait timed out) ·
#       2 usage / prerequisites
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOST=; SRC_HOST=; SRC_DIR=; LOCAL=; SPEC=; PERSIST=; DRY=; WAIT=300
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
SSHOPTS=${SSHOPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes}

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2086
rs() { ssh -i "$KEY" $SSHOPTS -o ConnectTimeout=8 "$@"; }

while getopts "H:S:f:i:k:st:nh" o; do
	case $o in
		H) HOST=$OPTARG;;
		S) SRC_HOST=${OPTARG%%:*}; SRC_DIR=${OPTARG#*:};;
		f) LOCAL=$OPTARG;;
		i) SPEC=$OPTARG;;
		k) KEY=$OPTARG;;
		s) PERSIST=1;;
		t) WAIT=$OPTARG;;
		n) DRY=1;;
		h) usage 0;;
		*) usage 2;;
	esac
done
[ -n "$HOST" ] || usage 2
[ -n "$SRC_HOST" ] || [ -n "$LOCAL" ] || die "give -S HOST:DIR (artefacts over ssh) or -f DIR (already local)"
[ -r "$KEY" ] || die "$KEY: no such key (the Live bakes in the matching public key)"

# --- 1. where the target is, and how it reaches the world ------------------------
say "== $HOST"
# the interface is not always eth0: Ubuntu names it ens2/enp0s3/... — take the one
# carrying the default route, and only fall back to "first global address"
IF=$(rs "$HOST" "ip -4 -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1); exit}'")
[ -n "${IF:-}" ] || IF=$(rs "$HOST" "ip -4 -o addr show scope global 2>/dev/null | awk '{print \$2; exit}'")
ADDR=$(rs "$HOST" "ip -4 -o addr show dev ${IF:-eth0} 2>/dev/null | awk '{print \$4}' | head -1") || die "cannot ssh $HOST"
[ -n "$ADDR" ] || die "no IPv4 address on ${IF:-eth0} of $HOST"
say "   interface ${IF:-eth0}"
GW=$(rs "$HOST" "ip route show default | awk '/default/ {print \$3; exit}'")
[ -n "$SPEC" ] || SPEC="$ADDR,${GW:-192.168.8.1},114.114.114.114"
say "   address $ADDR, gateway ${GW:-?}, boot line migrator.ip=$SPEC"
rs "$HOST" 'cat /etc/migrator-live-release 2>/dev/null' | grep -q . && say "   NOTE: this already looks like the Live"
FREE=$(rs "$HOST" "df -B1 --output=avail /boot 2>/dev/null | tail -1 | tr -d ' '")
[ -n "$FREE" ] && say "   /boot free: $(numfmt --to=iec "$FREE" 2>/dev/null || echo "$FREE")"

# --- 2. the artefacts ------------------------------------------------------------
if [ -z "$LOCAL" ]; then
	say "== artefacts from $SRC_HOST:$SRC_DIR"
	rs "$SRC_HOST" "for f in vmlinuz-live initrd-live.img live/live/filesystem.squashfs; do [ -f '$SRC_DIR/'\$f ] || { echo \"missing: \$f\" >&2; exit 1; }; done" \
		|| die "$SRC_HOST:$SRC_DIR: want vmlinuz-live, initrd-live.img and live/live/filesystem.squashfs"
	BYTES=$(rs "$SRC_HOST" "stat -c %s '$SRC_DIR/vmlinuz-live' '$SRC_DIR/initrd-live.img' '$SRC_DIR/live/live/filesystem.squashfs' | awk '{s+=\$1} END {print s+0}'" 2>/dev/null)
	[ -n "${BYTES:-}" ] && [ "$BYTES" -gt 0 ] || die "$SRC_HOST:$SRC_DIR: cannot size the artefacts"
	say "   $(numfmt --to=iec "$BYTES") to copy"
	[ "$BYTES" -lt "$FREE" ] || die "$HOST/boot has $FREE bytes, the artefacts need $BYTES"
else
	for f in "$LOCAL/vmlinuz-live" "$LOCAL/initrd-live.img"; do
		[ -f "$f" ] || die "$f: missing"
	done
	SQ=$LOCAL/live/live/filesystem.squashfs; [ -f "$SQ" ] || SQ=$LOCAL/live/filesystem.squashfs
	[ -f "$SQ" ] || die "$LOCAL: no live/filesystem.squashfs (or live/live/...)"
fi

if [ -n "$DRY" ]; then
	say "== dry run: would copy the artefacts, write /etc/grub.d/41_migrator-live on $HOST,"
	say "   run live-entry.sh ${PERSIST:+-s }-i $SPEC, reboot, and poll ssh for up to ${WAIT}s"
	exit 0
fi

# --- 3. copy, then write the entry ------------------------------------------------
if [ -z "$LOCAL" ]; then
	# stream through this machine: no temporary 444 MB copy on the Windows side
	# shellcheck disable=SC2086
	ssh -i "$KEY" $SSHOPTS "$SRC_HOST" "cd '$SRC_DIR' && tar -cf - vmlinuz-live initrd-live.img live/live/filesystem.squashfs" \
		| rs "$HOST" "set -e; rm -rf /root/.live-stage; mkdir -p /root/.live-stage; tar -xf - -C /root/.live-stage" \
		|| die "copy failed"
	rs "$HOST" "set -e; mkdir -p /root/live && mv -f /root/.live-stage/live/live/filesystem.squashfs /root/live/ && mv -f /root/.live-stage/vmlinuz-live /root/.live-stage/initrd-live.img /root/ && rm -rf /root/.live-stage && ls -lh /root/vmlinuz-live /root/initrd-live.img /root/live/filesystem.squashfs" || die "copy failed"
else
	# shellcheck disable=SC2086
	tar -cf - -C "$LOCAL" vmlinuz-live initrd-live.img live | rs "$HOST" "tar -xf - -C /root" || die "copy failed"
fi

# the tool itself, so the target runs exactly what the repo carries
rs "$HOST" "cat > /root/live-entry.sh" < "$(dirname "$0")/live-entry.sh" || die "could not copy live-entry.sh"
say "== writing the grub entry and rebooting"
rs "$HOST" "sed -i 's/\r\$//' /root/live-entry.sh; bash /root/live-entry.sh ${PERSIST:+-s} -i '$SPEC' -f /root" || die "live-entry.sh failed on $HOST"

rs "$HOST" 'nohup sh -c "sleep 2; reboot" > /dev/null 2>&1 &' > /dev/null 2>&1 &
sleep 1

# --- 4. wait for the Live --------------------------------------------------------
say "== waiting for the Live (up to ${WAIT}s)"
i=0; REL=
while [ "$i" -lt "$WAIT" ]; do
	REL=$(rs "$HOST" 'cat /etc/migrator-live-release 2>/dev/null' 2>/dev/null) || REL=
	[ -n "$REL" ] && break
	i=$(( i + 10 ))
	sleep 10
done
[ -n "$REL" ] || die "no answer after ${WAIT}s (the installed system may still be up, or the Live did not start: check the console once)"

# --- 5. is it really the Live? ---------------------------------------------------
say ""
say "== Live is up"
printf '%s\n' "$REL" | sed 's/^/   /'
say "   kernel: $(rs "$HOST" 'uname -r')"
say "   swap:   $(rs "$HOST" 'swapon --show=NAME,SIZE --noheadings | tr "\n" " "')"
say "   memory: $(rs "$HOST" 'free -m | awk "/Mem:/ {print \$2\" MiB total, \"\$7\" MiB available\"}"')"
DISK=$(rs "$HOST" 'findmnt -no SOURCE,TARGET -S /dev/sda 2>/dev/null | tr "\n" " "')
if [ -n "$DISK" ]; then
	say "   WARNING: /dev/sda still mounted ($DISK): toram did not release it, apply would wipe the Live"
	exit 1
fi
say "   /dev/sda:          free (toram released it)"
say "   tool:              $(rs "$HOST" 'v=$(cat /usr/local/lib/migrator/VERSION /usr/share/migrator/VERSION 2>/dev/null | head -1); echo "${v:--}"')"
say ""
say "next (from here, no console):"
say "  ssh -i $KEY root@${ADDR%%/*} 'migrator -y -i /root/rig-key -d <disks> -o mode=online -o cutover=rollback root@<DONOR>'"
exit 0
