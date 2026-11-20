#!/bin/bash
# lib/transfer.sh — stream every volume of the plan from the donor onto this
# box: partclone for block volumes, tar for file volumes, over the data channel
# lib/ssh.sh hands out (sshd:2222 on the donor, one connection per volume) or
# over raw busybox nc when the plan says data=raw. One volume at a time, state
# per volume in $RUN/state (resume, -o redo=N), progress on the screen and to
# a watchdog that kills a stalled pipeline. Needs common.sh,
# ssh.sh and plan.sh (pl_field, pl_has, plan_section, plan_get) sourced first.
#
#   transfer_run                 driver entry: every [volumes] row in plan order
#                                (mode=online in $RUN/state: transfer_online_run instead)
#   transfer_online_run          on-line migration: the ESP by tar first (it is never frozen),
#                                then every block volume in one "migrator-agent pull" session
#                                (passes, fsfreeze, final delta; the donor stays frozen and
#                                polls this box for the cutover), then fsck/grow on the copies
#   transfer_probe COMP EST      5 s of zeros through the channel -> rate, ETA line
#   transfer_block ROW           one block volume (partclone), then fsck/grow here
#   transfer_files ROW [vfat]    one file volume (tar), then count/size checks
#   tx_remote_block_cmd FS SRC FLAGS COMP [SINK]     the donor's pipeline (pure)
#   tx_local_block_cmd FS DST COMP LOG               this side's pipeline (pure)
#   tx_remote_files_cmd SRCDIR COMP EXCLUDES [vfat] [SINK]
#   tx_local_files_cmd DSTDIR COMP [vfat]
#   tx_progress_parse FILE       newest partclone fragment -> "PCT RATE REMAINING"
#   tx_verify_files SRCDIR DSTDIR [EXTRA_ENTRIES] [EXTRA_BYTES]  count/size compare
#   tx_swap_excludes MOUNT       "relpath size" of the donor's swapfiles on that volume
#   tx_vol_state SRC             pending|running|done|failed of a volume (slash-safe state_get)
#
# What is written where: this box's target devices (partclone -r, tar -x, e2fsck
# -y, resize2fs, xfs_growfs), $RUN/vol-N.{log,progress,remote.err,rc}. On the
# donor only /run/migrator-src.{status,log} and read-only mounts under
# /mnt/migrator/src/N (rule 4: the donor's disks are never written). Every
# pipeline is echoed with "+ donor:" / "+ " and logged verbatim: the log is the
# runbook the operator replays by hand when the tool is not trusted.
#
# Success of a block volume = ssh 0 AND the local chain 0 AND the donor's
# partclone status 0 AND "successfully restored" in $RUN/vol-N.log AND the
# post-copy check (e2fsck -n / xfs_repair -n, or the full e2fsck -f -y when the
# donor's fs was dirty or -o fsck=full). Of a file volume = tar 0 on both sides
# (donor 1 accepted when its stderr is only "socket ignored" lines) AND the
# entry counts within a few entries AND the apparent sizes within 1% (WARN).
# A failed volume is redone from zero: partclone overwrites, a file volume is
# re-mkfs'ed from the [mkfs] line (or emptied) before tar runs again.
#
# Knobs: -o data=ssh|raw compress=lz4|zstd|none redo=N|SRC|all watchdog=MIN
# fsck=quick|full. Test overrides (seconds): MIGRATOR_WATCHDOG_S,
# MIGRATOR_POLL_S, MIGRATOR_PRINT_S, MIGRATOR_PROBE_S; TX_RSTATUS/TX_RLOG migrate the
# donor's status/log files; TX_SRC_RUN runs the donor side of tx_verify_files.
# Exit codes: EX_ENV (2) apply not done / no donor / tools missing; EX_PLAN (4)
# unknown method or data=/compress= value; EX_FAIL (1) a volume failed (the
# message names it and the redo command).

TX_MNT=${TX_MNT:-/mnt/migrator}
: "${TX_RSTATUS:=/run/migrator-src.status}"
: "${TX_RLOG:=/run/migrator-src.log}"
: "${TX_POLL_S:=${MIGRATOR_POLL_S:-10}}"     # how often the pipeline is looked at
: "${TX_PRINT_S:=${MIGRATOR_PRINT_S:-30}}"   # progress line at most this often
: "${TX_PROBE_S:=${MIGRATOR_PROBE_S:-5}}"    # 0 = no ETA probe
: "${TX_SRC_RUN:=rsh_sh}"                  # runs a shell line on the donor (tests: a local runner)
TX_DATA=ssh; TX_COMP=lz4
TX_SRC=; TX_VID=; TX_ORD=0; TX_N=0
TX_PID=; TX_RPID=; TX_RC_SSH=; TX_RC_LOCAL=; TX_RC_REMOTE=
_TX_CLEANUP_LOCAL=; _TX_CLEANUP_DONOR=

# --- pure builders (tests assert these strings) --------------------------------
tx_partclone() { case $1 in ext2|ext3|ext4) echo partclone.extfs;; xfs) echo partclone.xfs;; *) return 1;; esac; }
# gzip is the fallback nobody has to install: it is in every base system, lz4 and
# zstd are not (a minimal Rocky has neither). It costs CPU and is worth it when the
# wire is the bottleneck - which it is on a cross-DC move.
tx_comp()      { case $1 in lz4) echo "lz4 -c";; zstd) echo "zstd -T0 --fast=3 -q -c";; gzip) echo "gzip -1 -c";; none) echo cat;; *) return 1;; esac; }
tx_decomp()    { case $1 in lz4) echo "lz4 -d -c";; zstd) echo "zstd -d -q -c";; gzip) echo "gzip -d -c";; none) echo cat;; *) return 1;; esac; }
tx_ro_opts()   { case $1 in ext2|ext3|ext4) echo ro,noload;; xfs) echo ro,norecovery;; *) echo ro;; esac; }
# The donor's whole command is ONE argument to ssh: "bash -o pipefail -c '...'".
# -a1 = CRC32 per block (partclone 0.3.x spells it -a1/--checksum-mode=1; the
# "-aX 1" of the help text is a placeholder and is rejected). -I only for a
# dirty donor fs: it is copied as is and its journal replayed on the copy here.
# ${PIPESTATUS[0]} is partclone's own status, written for us to read back.
tx_remote_block_cmd() {   # FS SRC FLAGS COMP [SINK]
	local pc comp flags=${3:+$3 } sink=${5:+ | $5}
	pc=$(tx_partclone "$1") || return 1
	comp=$(tx_comp "$4") || return 1
	printf "bash -o pipefail -c '%s -c -s %s -o - -q -a1 %s-L %s | %s%s; echo \${PIPESTATUS[0]} > %s'\n" \
		"$pc" "$2" "$flags" "$TX_RLOG" "$comp" "$sink" "$TX_RSTATUS"
}
# -f N: a progress fragment every N s on stderr (the caller collects them),
# N = the poll interval (10 s); partclone's progress thread sleeps N seconds
# between refreshes and is joined at the end, so a volume ends up to N s
# late. -B: without the per-block detail. A regular file as DST (images,
# tests) needs --overwrite (-O); a block device takes -o.
tx_local_block_cmd() {   # FS DST COMP LOG
	local pc dec o=-o
	pc=$(tx_partclone "$1") || return 1
	dec=$(tx_decomp "$3") || return 1
	[ -f "$2" ] && o=-O
	echo "$dec | $pc -r -s - $o $2 -L $4 -f $TX_POLL_S -B"
}
# tar exit 1 means warnings. These are expected on a real tree and do not mean
# data was lost: sockets cannot be archived, --one-file-system reports every
# mount it skipped, and FUSE/squashfs mounts have no xattrs. Anything else is a
# real warning and fails the volume (D25: lxcfs/snap mounts on an 18.04 donor).
tx_tar_warn_ok() {   # FILE -> 0 when only those warnings
	local f=$1
	[ -s "$f" ] || return 0
	! grep -vE 'socket ignored|directory is on a different filesystem; not dumped|Cannot flistxattr: Operation not supported' "$f" | grep -q '[^[:space:]]'
}
# virtual/pseudo filesystems that must never enter a file copy (the block method
# never sees them); explicit excludes keep tar from warning about them too.
# TX_EXCL_DIRS is the single source: tar gets --exclude words, the count check
# in tx_verify_files prunes the same trees (plus sockets, which tar ignores)
TX_EXCL_DIRS='dev proc sys run boot/efi snap var/lib/lxcfs'
TX_TAR_EXCLUDES=$(printf '%s\n' $TX_EXCL_DIRS | sed 's|^|--exclude=./|' | tr '\n' ' ')
# tar reads the donor's read-only mount; xattrs carry ACLs and SELinux labels
# (Debian's tar has no --acls/--selinux); the ESP (vfat) has neither owners nor
# xattrs. EXCLUDES = ready "--exclude=./path" words (quoted by the caller).
tx_remote_files_cmd() {   # SRCDIR COMP EXCLUDES [vfat] [SINK]
	local comp x=" $TX_TAR_EXCLUDES${3:+ $3}" xattrs=' --xattrs --xattrs-include=\*' sink=${5:+ | $5}
	[ "${4:-}" = vfat ] && xattrs=
	comp=$(tx_comp "$2") || return 1
	printf "bash -o pipefail -c 'cd %s && tar --one-file-system --numeric-owner%s --sparse%s -cf - . | %s%s; echo \${PIPESTATUS[0]} > %s'\n" \
		"$1" "$xattrs" "$x" "$comp" "$sink" "$TX_RSTATUS"
}
tx_local_files_cmd() {   # DSTDIR COMP [vfat]
	local dec
	dec=$(tx_decomp "$2") || return 1
	if [ "${3:-}" = vfat ]; then echo "$dec | tar -C $1 --numeric-owner --no-same-owner --no-same-permissions -xf -"
	else echo "$dec | tar -C $1 --numeric-owner --xattrs --xattrs-include=\\* -xpf -"; fi
}
# partclone rewrites one line with \r; fragments look like
#   Elapsed: 00:00:03, Remaining: 00:00:06, Completed:  32.16%, 985.66MB/min,
# (the final one says "Rate: 919.59MB/min"). The newest fragment wins.
tx_progress_parse() {   # FILE -> "PCT RATE REMAINING" (rate/remaining "-" when absent); 1 = nothing yet
	[ -s "$1" ] || return 1
	tr '\r' '\n' < "$1" | awk '
		/Completed:/ { line = $0 }
		END {
			if (line == "") exit 1
			pct = line; sub(/.*Completed: */, "", pct); sub(/%.*/, "", pct)
			rate = "-"; if (match(line, /[0-9.]+[A-Za-z]*\/min/)) rate = substr(line, RSTART, RLENGTH)
			rem = "-";  if (match(line, /Remaining: [0-9:]+/)) rem = substr(line, RSTART + 11, RLENGTH - 11)
			print pct, rate, rem }'
}
# the volume's id for mount points, logs and -o redo=: the partition number,
# or the source's name for LVs (num=-): /dev/centos/root -> centos-root
tx_vol_id() {   # ROW
	local num src
	num=$(pl_field "$1" num); src=$(pl_field "$1" src)
	case $num in ''|-) src=${src#/dev/}; echo "${src//\//-}";; *) echo "$num";; esac
}
tx_redo_wants() {   # VID SRC -> 0 when -o redo= names this volume (or all)
	local r; r=$(opt redo)
	[ -n "$r" ] || return 1
	[ "$r" = all ] && return 0
	pl_has "$r" "$1" || pl_has "$r" "$2"
}
# common.sh's state_get is "sed s/^KEY=//p" and cannot read a key with "/" in
# it (vol./dev/sda2=done); the vol.* keys are read here with another delimiter
# until that is fixed in common.sh (writing through state_set works).
tx_state_get() { sed -n "s|^$1=||p" "$RUN/state" 2>/dev/null | tail -1; }
tx_vol_state() { tx_state_get "vol.$1"; }   # pending|running|done|failed|""
tx_watchdog_s() { if [ -n "${MIGRATOR_WATCHDOG_S:-}" ]; then echo "$MIGRATOR_WATCHDOG_S"; else echo $(( $(opt watchdog 15) * 60 )); fi; }
tx_fmt_time() {   # SECONDS -> 2h 05m / 12m 30s / 45s
	awk -v s="$1" 'BEGIN { s = int(s); if (s >= 3600) printf "%dh %02dm\n", s / 3600, (s % 3600) / 60; else if (s >= 60) printf "%dm %02ds\n", s / 60, s % 60; else printf "%ds\n", s }'
}
# the donor's swapfiles that live on the volume mounted at MOUNT: "relpath size"
# per line. A swapfile belongs to the volume with the longest mount prefix,
# so /var/swap is /var's when /var is its own volume, else /'s.
tx_swap_excludes() {   # MOUNT
	local plan=$RUN/plan inv=$RUN/donor.inv rec path size m best rel
	[ -r "$inv" ] && [ -r "$plan" ] || return 0
	local -a mounts=()
	while read -r rec; do m=$(pl_field "$rec" mount); case $m in /*) mounts+=("$m");; esac; done < <(plan_section "$plan" volumes)
	while read -r rec; do
		path=$(pl_field "$rec" path); size=$(pl_field "$rec" size)
		[ -n "$path" ] || continue
		best=
		for m in "${mounts[@]}"; do
			case $path in "$m"/*|"$m") ;; *) [ "$m" = / ] || continue;; esac
			[ ${#m} -gt ${#best} ] && best=$m
		done
		[ "$best" = "$1" ] || continue
		if [ "$1" = / ]; then rel=${path#/}; else rel=${path#"$1"/}; fi
		echo "$rel ${size:-0}"
	done < <(pl_records "$inv" swapfile)
}
# "Space in use: 18.2 MB = 17741 Blocks" x "Block size: 1024 Byte" from a partclone log
tx_log_bytes() {   # LOG -> bytes partclone copied (0 when unknown)
	awk '/^Space in use:/ { b = $(NF-1) } /^Block size:/ { bs = $3 } END { printf "%.0f\n", b * bs }' "$1" 2>/dev/null
}

# --- failure, status line, cleanup -----------------------------------------------------
# tx_status DETAIL: the last word on the transfer, one line in $RUN/summary (what
# "migrator -s attach" and a script read after the phase; verify overwrites it)
tx_status() { mkdir -p "$RUN" 2>/dev/null; printf '%s\n' "$1" > "$RUN/summary" 2>/dev/null || true; }
# tx_fail MSG: the volume is marked failed and the run stops; the message
# names the volume and the exact command that repeats just this volume.
tx_fail() {
	tx_status "transfer: vol $TX_ORD/$TX_N $TX_SRC failed: $*"
	rm -f "$RUN/tx.pgid"
	if [ -n "$TX_SRC" ] && [ -z "$DRY" ]; then
		vol_state_set "$TX_SRC" failed
		state_set "vol.$TX_SRC.finished" "$(date +%s)"; state_set "vol.$TX_SRC.rc" 1
	fi
	die "$EX_FAIL" "volume $TX_SRC (${TX_VID:-?}) failed: $*; fix the cause, then: migrator -o redo=${TX_VID:-N} -s transfer"
}
tx_must()    { run "$@" || tx_fail "command failed ($?): $*"; }
tx_must_sh() { run_sh "$1" || tx_fail "command failed ($?): $1"; }
# the ssh prefix cleanup snippets use to reach the donor: the master when it is
# there, the session key straight in when it is gone (same as ssh.sh's own)
tx_ssh_cleanup_prefix() {
	echo "ssh -S $(printf '%q' "$RUN/ssh.sock") -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=$(printf '%q' "$RUN/known_hosts") -o LogLevel=ERROR -i $(printf '%q' "$RUN/id_ed25519") -p ${DONOR_PORT:-22} ${DONOR_USER:-root}@$DONOR_HOST"
}
# Registered once each (never under -n: nothing was mounted or started), and
# run whatever the exit reason: a pipeline still running is killed by its own
# process group (never by name), our mounts are undone on both sides. The
# donor side only umounts what we mounted under /mnt/migrator/src.
tx_register_cleanup_local() {
	[ -z "$_TX_CLEANUP_LOCAL" ] && [ -z "$DRY" ] || return 0
	cleanup_add "p=\$(cat $(printf '%q' "$RUN/tx.pgid") 2>/dev/null); [ -n \"\$p\" ] && kill -TERM -- -\$p; rm -f $(printf '%q' "$RUN/tx.pgid")"
	cleanup_add "for d in $TX_MNT/dst/*; do mountpoint -q \"\$d\" && umount \"\$d\"; rmdir \"\$d\" 2>/dev/null; done; true"
	_TX_CLEANUP_LOCAL=y
}
tx_register_cleanup_donor() {
	[ -z "$_TX_CLEANUP_DONOR" ] && [ -z "$DRY" ] || return 0
	cleanup_add "$(tx_ssh_cleanup_prefix) -- $(printf '%q' "for d in $TX_MNT/src/*; do mountpoint -q \"\$d\" && umount \"\$d\"; rmdir \"\$d\" 2>/dev/null; done; true")"
	_TX_CLEANUP_DONOR=y
}

# --- running a pipeline under the watchdog ---------------------------------------
# tx_stream VID REMOTE LOCAL TOTAL PROGRESS_FN [ARGS...]
#   data=ssh: "ssh:2222 donor -- REMOTE 2>vol-N.remote.err | bash -o pipefail -c LOCAL 2>vol-N.progress"
#   data=raw: "busybox nc -l" here feeding LOCAL, then REMOTE (its "| busybox nc IP PORT"
#             sink filled in here) through the control master
# Started in its own session (setsid) so the watchdog can kill the whole
# chain by process group; polled every TX_POLL_S; PROGRESS_FN ARGS prints
# "PCT RATE ETA DONE" (or nothing); no change for tx_watchdog_s -> killed and
# the volume fails. Leaves the statuses for tx_collect; under -n only prints.
tx_stream() {
	local vid=$1 remote=$2 local_=$3 total=$4 fn=$5; shift 5
	local err=$RUN/vol-$vid.remote.err prog=$RUN/vol-$vid.progress rcf=$RUN/vol-$vid.rc wrapper sshc
	if [ "$TX_DATA" = raw ]; then tx_stream_raw "$vid" "$remote" "$local_" "$total" "$fn" "$@"; return; fi
	sshc=$(ssh_data_cmd)
	wrapper="$sshc -n -- $(printf '%q' "$remote") 2>$(printf '%q' "$err") | bash -o pipefail -c $(printf '%q' "$local_") 2>$(printf '%q' "$prog")"
	if [ -n "$DRY" ]; then
		echo "(dry) donor: $remote"; log "(dry) donor: $remote"
		echo "(dry) $wrapper"; log "(dry) $wrapper"
		return 0
	fi
	rrun rm -f "$TX_RSTATUS" "$TX_RLOG" || tx_fail "cannot reach the donor through the control channel"
	echo "+ donor: $remote"; log "+ donor: $remote"
	echo "+ $wrapper"; log "+ $wrapper"
	rm -f "$rcf" "$RUN/tx.pgid"; : > "$prog"; : > "$err"
	tx_register_cleanup_local
	# $$ inside the new session is its leader = the process group to kill;
	# both PIPESTATUS values land in the rc file for tx_collect
	setsid --wait bash -o pipefail -c "echo \$\$ > $(printf '%q' "$RUN/tx.pgid"); $wrapper; echo \"\${PIPESTATUS[0]} \${PIPESTATUS[1]}\" > $(printf '%q' "$rcf")" </dev/null &
	TX_PID=$!; TX_RPID=
	tx_watch "$total" "$fn" "$@"
}
tx_stream_raw() {
	local vid=$1 remote=$2 local_=$3 total=$4 fn=$5; shift 5
	local err=$RUN/vol-$vid.remote.err prog=$RUN/vol-$vid.progress rcf=$RUN/vol-$vid.rc port myip listen
	port=$((30000 + RANDOM % 10000))
	myip=$(ip -o route get "$DONOR_HOST" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1)
	[ -n "$myip" ] || [ -z "$DRY" ] || myip='<my-ip>'
	[ -n "$myip" ] || tx_fail "cannot tell my own address towards $DONOR_HOST for the nc listener"
	remote="${remote/ | busybox nc IP PORT;/ | busybox nc $myip $port;}"
	listen="busybox nc -l -p $port -w 120"
	sink="bash -o pipefail -c $(printf '%q' "$local_") 2>$(printf '%q' "$prog")"
	if [ -n "$DRY" ]; then
		echo "(dry) $listen | $sink  &"; log "(dry) $listen | $sink &"
		echo "(dry) donor: $remote"; log "(dry) donor: $remote"
		return 0
	fi
	rrun rm -f "$TX_RSTATUS" "$TX_RLOG" || tx_fail "cannot reach the donor through the control channel"
	echo "+ $listen | $sink  &"; log "+ $listen | $sink &"
	rm -f "$rcf" "$RUN/tx.pgid"; : > "$prog"; : > "$err"
	tx_register_cleanup_local
	# nc's stdin must never hit EOF: busybox nc half-closes the socket on it
	# and the donor's nc takes that as "done" mid-stream; a fifo held open
	# read-write on fd 7 keeps it waiting (measure-channel.sh found this). The
	# "<&7" belongs to nc itself: on the pipeline it would land on the sink.
	[ -p "$RUN/tx.hold" ] || mkfifo "$RUN/tx.hold"
	setsid --wait bash -o pipefail -c "echo \$\$ > $(printf '%q' "$RUN/tx.pgid"); exec 7<>$(printf '%q' "$RUN/tx.hold"); $listen <&7 | $sink; echo \"0 \${PIPESTATUS[1]}\" > $(printf '%q' "$rcf")" </dev/null &
	TX_PID=$!
	sleep 1
	echo "+ donor: $remote"; log "+ donor: $remote"
	rsh_sh "$remote" </dev/null 2>"$err" &
	TX_RPID=$!
	tx_watch "$total" "$fn" "$@"
}
tx_watch() {   # TOTAL PROGRESS_FN ARGS...
	local total=$1 fn=$2; shift 2
	local wd t0 now last_change last_print=0 last='' cur pct rate eta dn s
	wd=$(tx_watchdog_s); t0=$(date +%s); last_change=$t0
	while kill -0 "$TX_PID" 2>/dev/null; do
		for (( s = 0; s < TX_POLL_S; s++ )); do kill -0 "$TX_PID" 2>/dev/null || break; sleep 1; done
		kill -0 "$TX_PID" 2>/dev/null || break
		now=$(date +%s)
		cur=$("$fn" "$@" 2>/dev/null)
		if [ -n "$cur" ] && [ "$cur" != "$last" ]; then last=$cur; last_change=$now; fi
		if [ -n "$cur" ] && [ $((now - last_print)) -ge "$TX_PRINT_S" ]; then
			read -r pct rate eta dn <<< "$cur"
			say "vol $TX_ORD/$TX_N ($TX_SRC): $(human "$dn")/$(human "$total") ($pct%), $rate, ETA $eta"
			last_print=$now
		fi
		if [ $((now - last_change)) -ge "$wd" ]; then
			warn "no progress for $(tx_fmt_time $((now - last_change))): killing the pipeline"
			tx_kill_pipeline
			tx_fail "no progress for $(tx_fmt_time "$wd") (watchdog); pipeline killed"
		fi
	done
	wait "$TX_PID" 2>/dev/null
	[ -z "$TX_RPID" ] || { wait "$TX_RPID" 2>/dev/null; TX_RC_SSH=$?; }
	rm -f "$RUN/tx.pgid"
	return 0
}
tx_kill_pipeline() {
	local p; p=$(cat "$RUN/tx.pgid" 2>/dev/null)
	if [ -n "$p" ]; then kill -TERM -- "-$p" 2>/dev/null; sleep 2; kill -KILL -- "-$p" 2>/dev/null; fi
	[ -n "$TX_PID" ] && kill -TERM "$TX_PID" 2>/dev/null
	[ -n "$TX_RPID" ] && kill -TERM "$TX_RPID" 2>/dev/null
	wait "$TX_PID" 2>/dev/null; [ -z "$TX_RPID" ] || wait "$TX_RPID" 2>/dev/null
	rm -f "$RUN/tx.pgid"
}
# tx_collect VID: the three statuses of the finished pipeline into TX_RC_*
tx_collect() {
	local vid=$1 a b
	read -r a b < "$RUN/vol-$vid.rc" 2>/dev/null || { a='?'; b='?'; }
	if [ "$TX_DATA" = raw ]; then TX_RC_LOCAL=${b:-?}; else TX_RC_SSH=${a:-?}; TX_RC_LOCAL=${b:-?}; fi
	TX_RC_REMOTE=$(rsh cat "$TX_RSTATUS" 2>/dev/null | tr -cd '0-9' | head -c 4)
	[ -n "$TX_RC_REMOTE" ] || TX_RC_REMOTE='?'
	log "vol $vid: ssh rc=$TX_RC_SSH local rc=$TX_RC_LOCAL donor status=$TX_RC_REMOTE"
}
# progress readers: "PCT RATE ETA DONE" or nothing yet
tx_block_progress() {   # PROGFILE TOTAL
	local p pct rate rem
	p=$(tx_progress_parse "$1") || return 0
	read -r pct rate rem <<< "$p"
	echo "$pct $rate $rem $(awk -v p="$pct" -v t="$2" 'BEGIN { printf "%.0f\n", t * p / 100 }')"
}
tx_files_progress() {   # DSTDIR TOTAL T0
	local used now
	used=$(df --output=used -B1 "$1" 2>/dev/null | tail -1 | tr -cd '0-9')
	[ -n "$used" ] || return 0
	now=$(date +%s)
	awk -v u="$used" -v t="$2" -v dt="$((now - $3))" 'BEGIN {
		pct = (t > 0) ? 100 * u / t : 0; if (pct > 100) pct = 100
		rate = (dt > 0) ? u / dt : 0
		eta = (rate > 0 && t > u) ? (t - u) / rate : 0
		printf "%.2f %.1fMB/s %s %d\n", pct, rate / 1e6, (eta > 0) ? sprintf("%dm %02ds", eta / 60, eta % 60) : "-", u }'
}

# --- the volumes -----------------------------------------------------------------
tx_require_tools() {   # ROWS... -> die EX_ENV (warn under -n) when this box lacks a tool
	local row method fs missing='' t
	local -a need=()
	for row in "$@"; do
		method=$(pl_field "$row" method); fs=$(pl_field "$row" fs)
		case $method in
			block) need+=("$(tx_partclone "$fs" 2>/dev/null || echo "partclone.$fs")")
			       case $fs in ext*) need+=(e2fsck resize2fs);; xfs) need+=(xfs_repair xfs_growfs);; esac ;;
			files|esp) need+=(tar mountpoint) ;;
		esac
	done
	case $TX_COMP in lz4) need+=(lz4);; zstd) need+=(zstd);; esac
	[ "$TX_DATA" = raw ] && need+=(busybox ip)
	for t in "${need[@]}"; do have "$t" || case " $missing " in *" $t "*) ;; *) missing="$missing $t";; esac; done
	[ -n "$missing" ] || return 0
	if [ -n "$DRY" ]; then warn "missing on this box:$missing (bootstrap installs them: apt-get install partclone xfsprogs)"; return 0; fi
	die "$EX_ENV" "missing on this box:$missing (bootstrap installs them: apt-get install partclone xfsprogs)"
}
# transfer_probe COMP EST: 5 s of zeros from the donor through the compressor
# and the channel; zeros are the compressor's ceiling rather than the disk's
# rate, so the ETA is a lower bound. Under data=raw the control master carries
# the probe (there is no sshd:2222 then).
transfer_probe() {
	local comp=$1 est=$2 remote dec t0 t1 n rate secs
	if [ -n "$DRY" ]; then say "(dry) probe skipped"; return 0; fi
	[ "$TX_PROBE_S" -gt 0 ] 2>/dev/null || return 0
	remote="timeout $TX_PROBE_S dd if=/dev/zero bs=4M status=none | $(tx_comp "$comp")"
	dec=$(tx_decomp "$comp")
	say "probing the data channel for $TX_PROBE_S s: donor: $remote | $dec | wc -c"
	t0=$(date +%s.%N)
	if [ "$TX_DATA" = raw ]; then n=$(rsh_sh "$remote" </dev/null 2>/dev/null | bash -c "$dec" | wc -c)
	else n=$($(ssh_data_cmd) -n -- "$remote" 2>/dev/null | bash -c "$dec" | wc -c); fi
	t1=$(date +%s.%N)
	read -r rate secs <<< "$(awk -v n="$n" -v a="$t0" -v b="$t1" -v e="$est" 'BEGIN { t = b - a; if (t <= 0) t = 0.001; r = n / t; printf "%.0f %.0f\n", r / 1e6, (r > 0) ? e / r : 0 }')"
	[ "${rate:-0}" -gt 0 ] || { warn "probe got nothing through the data channel (${n:-0} bytes); no ETA"; return 0; }
	say "channel ~${rate} MB/s (zeros through $comp: the compressor ceiling, the disks may be slower)"
	say "estimated total: $(human "$est") at $rate MB/s ≈ $(tx_fmt_time "$secs"); a failed volume restarts from zero"
	state_set transfer.probe_mbps "$rate"
}

transfer_block() {   # ROW
	local row=$1 src target fs notes used size total vid flags='' remote local_ log bytes sink=''
	src=$(pl_field "$row" src); target=$(pl_field "$row" target); fs=$(pl_field "$row" fs)
	notes=$(pl_field "$row" notes); used=$(pl_field "$row" used); size=$(pl_field "$row" size)
	vid=$(tx_vol_id "$row"); log=$RUN/vol-$vid.log
	tx_partclone "$fs" >/dev/null || tx_fail "no block copier for fs=$fs (block method is ext2/3/4 and xfs only)"
	if pl_has "$notes" dirty; then
		flags=-I
		say "  $src is not clean on the donor: copied as is (partclone -I), the journal is replayed on the copy here"
	fi
	case $used in ''|-|*[!0-9]*) total=$size;; *) total=$used;; esac
	[ "$TX_DATA" = raw ] && sink="busybox nc IP PORT"
	remote=$(tx_remote_block_cmd "$fs" "$src" "$flags" "$TX_COMP" "$sink")
	local_=$(tx_local_block_cmd "$fs" "$target" "$TX_COMP" "$log")
	rm -f "$log"
	tx_stream "$vid" "$remote" "$local_" "$total" tx_block_progress "$RUN/vol-$vid.progress" "$total"
	if [ -n "$DRY" ]; then tx_block_after "$fs" "$target" "$notes" "$vid"; return 0; fi
	tx_collect "$vid"
	if [ "$TX_RC_SSH" != 0 ] || [ "$TX_RC_LOCAL" != 0 ] || [ "$TX_RC_REMOTE" != 0 ]; then
		tx_fail "pipeline: ssh rc=$TX_RC_SSH, local chain rc=$TX_RC_LOCAL, donor partclone status=$TX_RC_REMOTE (see $RUN/vol-$vid.remote.err, $log)$(tx_tail_hint "$RUN/vol-$vid.remote.err")"
	fi
	grep -q 'successfully restored' "$log" 2>/dev/null || tx_fail "partclone did not report a successful restore (see $log)"
	bytes=$(tx_log_bytes "$log")
	state_set "vol.$src.bytes" "${bytes:-0}"
	say "vol $TX_ORD/$TX_N ($src): restored $(human "${bytes:-0}") onto $target"
	tx_block_after "$fs" "$target" "$notes" "$vid"
}
tx_tail_hint() { local l; l=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 | cut -c1-120); [ -n "$l" ] && echo "; donor said: $l"; return 0; }
# tx_block_after FS DST NOTES VID: the copy is checked here, never the donor.
# ext: e2fsck -n on a clean copy, e2fsck -f -y (0/1/2 ok) when the donor's fs
# was dirty or -o fsck=full, and always before resize2fs (it insists). xfs:
# a rw mount + umount replays the journal (dirty), xfs_repair -n checks,
# xfs_growfs grows a mounted fs.
tx_block_after() {
	local fs=$1 dst=$2 notes=$3 vid=$4 fixed='' rc mnt
	mnt=$TX_MNT/dst/$vid
	case $fs in
		ext2|ext3|ext4)
			if pl_has "$notes" dirty || [ "$(opt fsck quick)" = full ]; then
				tx_e2fsck_fix "$dst"; fixed=y
			else
				run e2fsck -n "$dst"; rc=$?
				[ $rc -eq 0 ] || tx_fail "e2fsck -n $dst exit $rc: the copy is not clean (rerun with -o fsck=full to repair it)"
			fi
			if pl_has "$notes" grow; then
				[ -n "$fixed" ] || tx_e2fsck_fix "$dst"
				tx_must resize2fs "$dst"
			fi ;;
		xfs)
			if pl_has "$notes" dirty; then
				say "  replaying the xfs log of $dst (mount rw, umount)"
				tx_must mkdir -p "$mnt"; tx_must mount -t xfs "$dst" "$mnt"; tx_must umount "$mnt"; run rmdir "$mnt"
			fi
			tx_must xfs_repair -n "$dst"
			if pl_has "$notes" grow; then
				tx_must mkdir -p "$mnt"; tx_must mount -t xfs "$dst" "$mnt"
				tx_must xfs_growfs "$mnt"
				tx_must umount "$mnt"; run rmdir "$mnt"
			fi ;;
	esac
}
tx_e2fsck_fix() {   # DST: 0 clean, 1/2 corrected; 4+ is a failure
	local rc; run e2fsck -f -y "$1"; rc=$?
	[ $rc -le 2 ] || tx_fail "e2fsck -f -y $1 exit $rc: errors left on the copy"
}

transfer_files() {   # ROW [vfat]
	local row=$1 mode=${2:-} src target fs mount notes used size total vid sdir ddir excl='' nx=0 xbytes=0 rel sz
	local remote local_ t0 nsock bytes prev sink=''
	src=$(pl_field "$row" src); target=$(pl_field "$row" target); fs=$(pl_field "$row" fs)
	mount=$(pl_field "$row" mount); notes=$(pl_field "$row" notes); used=$(pl_field "$row" used); size=$(pl_field "$row" size)
	vid=$(tx_vol_id "$row"); sdir=$TX_MNT/src/$vid; ddir=$TX_MNT/dst/$vid
	[ "$mode" = vfat ] || case $fs in ext2|ext3|ext4|xfs) ;; *) tx_fail "files method on fs=$fs: ext2/3/4 or xfs expected";; esac
	case $used in ''|-|*[!0-9]*) total=$size;; *) total=$used;; esac
	while read -r rel sz; do
		[ -n "$rel" ] || continue
		excl="${excl:+$excl }--exclude=$(printf '%q' "./$rel")"; nx=$((nx + 1)); xbytes=$((xbytes + sz))
		say "  swapfile /$rel is excluded (postfix recreates it)"
	done < <(tx_swap_excludes "$mount")
	# the state BEFORE this attempt: transfer_run has already marked the volume
	# running, so reading $RUN/state here would always look like a crashed attempt
	prev=${TX_PREV-$(tx_vol_state "$src")}
	if [ -n "${TX_SRC_DIR:-}" ]; then
		# on-line: the donor's own mount of the volume is read where it is, nothing is mounted there
		sdir=$TX_SRC_DIR
	else
		# donor: read-only, no journal replay, private so the mount cannot leak into
		# a service's namespace (the make-private trap of docs/DEVLOG.md)
		tx_register_cleanup_donor
		rrun mkdir -p "$sdir" || tx_fail "cannot mkdir $sdir on the donor"
		rrun_sh "mount -t $fs -o $(tx_ro_opts "$fs") $src $sdir && mount --make-private $sdir" || tx_fail "cannot mount $src read-only on the donor"
	fi
	# here: the fresh fs apply made; a leftover of a failed attempt is re-made first
	[ "$TX_DATA" = raw ] && sink="busybox nc IP PORT"
	case $prev in failed|running) tx_refresh_target "$target";; esac
	tx_register_cleanup_local
	tx_must mkdir -p "$ddir"
	tx_must mount -t "$fs" "$target" "$ddir"
	tx_must mount --make-private "$ddir"
	case $prev in failed|running) tx_empty_dir "$ddir" "$target";; esac
	remote=$(tx_remote_files_cmd "$sdir" "$TX_COMP" "$excl" "$mode" "$sink")
	local_=$(tx_local_files_cmd "$ddir" "$TX_COMP" "$mode")
	t0=$(date +%s)
	tx_stream "$vid" "$remote" "$local_" "$total" tx_files_progress "$ddir" "$total" "$t0"
	if [ -n "$DRY" ]; then
		echo "(dry) verify: find -xdev | wc -l and du -sx --apparent-size on both sides"
		run umount "$ddir"; run rmdir "$ddir"
		[ -n "${TX_SRC_DIR:-}" ] || { rrun umount "$sdir"; rrun rmdir "$sdir"; }
		return 0
	fi
	tx_collect "$vid"
	nsock=$(grep -c 'socket ignored' "$RUN/vol-$vid.remote.err" 2>/dev/null || true)
	if [ "$TX_RC_REMOTE" = 1 ] && tx_tar_warn_ok "$RUN/vol-$vid.remote.err"; then
		say "  donor tar exit 1: only expected warnings ($nsock sockets skipped), accepted"
		TX_RC_REMOTE=0
	fi
	if [ "$TX_RC_SSH" != 0 ] || [ "$TX_RC_LOCAL" != 0 ] || [ "$TX_RC_REMOTE" != 0 ]; then
		tx_fail "pipeline: ssh rc=$TX_RC_SSH, local tar rc=$TX_RC_LOCAL, donor tar status=$TX_RC_REMOTE (see $RUN/vol-$vid.remote.err)$(tx_tail_hint "$RUN/vol-$vid.remote.err")"
	fi
	tx_verify_files "$sdir" "$ddir" $((nx + ${nsock:-0})) "$xbytes"
	bytes=$(df --output=used -B1 "$ddir" 2>/dev/null | tail -1 | tr -cd '0-9')
	state_set "vol.$src.bytes" "${bytes:-0}"
	say "vol $TX_ORD/$TX_N ($src): $(human "${bytes:-0}") on $target"
	# LIFO: the destination was mounted last
	tx_must umount "$ddir"; run rmdir "$ddir"
	[ -n "${TX_SRC_DIR:-}" ] && return 0
	rrun umount "$sdir" || warn "umount $sdir on the donor failed (cleanup retries it)"
	rrun rmdir "$sdir" || true
}
# a failed file volume is redone into a fresh fs: the plan's [mkfs] line for
# the target (same UUID/label/features as apply used), else the tree is emptied
# once it is mounted (tx_empty_dir)
tx_mkfs_line_for() { plan_section "$RUN/plan" mkfs | awk -v t="$1" '$NF == t { print; exit }'; }
tx_refresh_target() {   # TARGET
	local line; line=$(tx_mkfs_line_for "$1")
	if [ -n "$line" ]; then say "  earlier attempt failed: re-making $1 before the copy"; tx_must_sh "$line"; return 0; fi
	warn "earlier attempt failed and no [mkfs] line for $1: the tree is emptied instead"
}
tx_empty_dir() {   # DIR TARGET: everything but lost+found, only when no mkfs line re-made TARGET
	[ -z "$(tx_mkfs_line_for "$2")" ] || return 0
	tx_must_sh "find $(printf '%q' "$1") -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +"
}
# tx_find_count_cmd DIR: the donor-side entry count must see exactly the set tar
# copies -- the pruned trees and no sockets (tar ignores them). Counting the raw
# tree made the pseudofs mountpoints, /snap and lxcfs's cgroup stubs (thousands on
# a container host) count on the donor and nowhere else.
tx_find_count_cmd() {
	local s=${1%/} f i
	f="find $(printf '%q' "${s:-/}") -xdev \\("
	for i in $TX_EXCL_DIRS; do f="$f -path $(printf '%q' "$s/$i") -o"; done
	printf '%s' "${f% -o} \\) -prune -o ! -type s -print | wc -l"
}
# tx_verify_files SRCDIR DSTDIR [EXTRA_ENTRIES] [EXTRA_BYTES]: entry counts must
# agree within 5 + EXTRA_ENTRIES (excluded swapfiles), the
# apparent sizes within 1% after EXTRA_BYTES (the swapfiles) is taken off the
# donor's; used blocks differ by design (sparse files, journal) — WARN only.
# The donor side runs through $TX_SRC_RUN (rsh_sh; a local runner in tests).
tx_verify_files() {
	local s=$1 d=$2 extra=${3:-0} xbytes=${4:-0} sc dc ss ds su du diff allowed q
	q=$(printf '%q' "$s")
	sc=$($TX_SRC_RUN "$(tx_find_count_cmd "$s")" </dev/null | tr -cd '0-9')
	dc=$(find "$d" -xdev 2>/dev/null | wc -l)
	[ -n "$sc" ] || tx_fail "cannot count entries under $s on the donor"
	diff=$((sc - dc)); [ $diff -lt 0 ] && diff=$((-diff))
	allowed=$((5 + extra))
	[ $diff -le $allowed ] || tx_fail "entry count differs: donor $sc, here $dc (allowed ±$allowed): the copy is incomplete"
	say "  entries: donor $sc, here $dc (ok, ±$allowed allowed)"
	ss=$($TX_SRC_RUN "du -sx --apparent-size -B1 $q | cut -f1" </dev/null | tr -cd '0-9')
	ds=$(du -sx --apparent-size -B1 "$d" 2>/dev/null | cut -f1)
	ss=$(( ${ss:-0} - xbytes )); [ $ss -lt 0 ] && ss=0
	if [ "$ss" -gt 0 ] && ! awk -v a="$ss" -v b="${ds:-0}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= a / 100) }'; then
		warn "apparent size differs by more than 1%: donor $(human "$ss"), here $(human "${ds:-0}")"
	else
		say "  apparent size: donor $(human "$ss"), here $(human "${ds:-0}") (ok)"
	fi
	su=$($TX_SRC_RUN "df --output=used -B1 $q | tail -1" </dev/null | tr -cd '0-9')
	du=$(df --output=used -B1 "$d" 2>/dev/null | tail -1 | tr -cd '0-9')
	if [ -n "$su" ] && [ -n "$du" ] && ! awk -v a="$su" -v b="$du" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= a / 10) }'; then
		warn "used bytes differ by more than 10%: donor $(human "$su"), here $(human "$du") (sparse files and journal size explain some of it)"
	fi
	return 0
}

# --- the on-line files volumes: GNU tar incremental passes -------------------------------
# A volume that does not fit its target (method=files) is copied by files while
# the donor runs: level 0 = the whole tree (before the agent's block passes),
# then incremental levels (--listed-incremental: files changed by mtime/ctime
# since the snapshot, directory membership for the deletions), the last one
# from the FROZEN filesystem. The passes before the freeze are ordinary
# sessions over the master; the last one cannot be - a new login on a frozen
# root hangs - so two idle sessions ("bash -s" with their stdin held open on
# fifos, fds TX_OL_*) are opened before the freeze: one carries the archive,
# the other the small text commands (tar's exit status, find/du for the
# count check). The agent runs the freeze and calls back here through its
# --before-freeze / --after-freeze hooks ($RUN/ol-hook.sh).
#   tx_ol_files_pass LEVEL kind     one pass over every files row of $RUN/ol.files
#   tx_ol_sessions_open/close       the idle sessions (fds 7/8 archive, 9/10 commands)
#   tx_ol_cmd 'line'                run a command line on the donor through the idle command session
#   tx_ol_hook before|after         what the agent's hooks call
TX_OL_MAXPASS=${TX_OL_MAXPASS:-5}
TX_OL_SMALL=${TX_OL_SMALL:-67108864}   # a pass under this many bytes is "caught up"
tx_ol_tar_create() {   # SRCDIR SNAP LEVEL EXCLUDES -> the donor's command line (archive on stdout, rc into SNAP.rc)
	local pre=''; [ "$3" != 0 ] || pre="rm -f $(printf '%q' "$2"); "
	printf '%scd %s && tar --one-file-system --numeric-owner --sparse --xattrs --xattrs-include=\\* --listed-incremental=%s %s-cf - .; echo $? > %s.rc' \
		"$pre" "$(printf '%q' "$1")" "$(printf '%q' "$2")" "${4:+$4 }" "$(printf '%q' "$2")"
}
tx_ol_tar_extract() {   # DSTDIR -> this side's command line (archive on stdin)
	echo "tar -C $(printf '%q' "$1") --listed-incremental=/dev/null --numeric-owner --xattrs --xattrs-include=\\* -xpf -"
}
tx_ol_rows() { cat "$RUN/ol.files" 2>/dev/null; }
# tx_ol_files_pass LEVEL KIND: KIND = live (an ordinary session) | frozen (the idle sessions);
# the bytes moved land in TX_OL_BYTES (no subshell: a failure dies right here)
TX_OL_BYTES=0
tx_ol_files_pass() {
	local level=$1 kind=$2 row src target mount vid sdir ddir snap excl rel sz remote local_ t0 bytes rc nsock total=0 comp dec idx vin vout
	comp=$(tx_comp "$TX_COMP"); dec=$(tx_decomp "$TX_COMP")
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		src=$(pl_field "$row" src); target=$(pl_field "$row" target); mount=$(pl_field "$row" mount); vid=$(tx_vol_id "$row"); idx=$(pl_field "$row" olidx)
		sdir=$(tx_vol_state "$src.srcdir"); ddir=$TX_MNT/dst/$vid; snap=$DONOR_RUN/tar.snap.$vid
		TX_SRC=$src; TX_VID=$vid
		# shellcheck disable=SC2034  # what die() records in $RUN/failure
		VOLUME=$src
		excl=$TX_TAR_EXCLUDES
		while read -r rel sz; do [ -n "$rel" ] || continue; excl="${excl:+$excl }--exclude=$(printf '%q' "./$rel")"; done < <(tx_swap_excludes "$mount")
		# the target is mounted for the passes only: a dm-snapshot (pre-check) needs it unmounted
		if ! mountpoint -q "$ddir" 2>/dev/null; then
			tx_must mkdir -p "$ddir"
			tx_must mount -t "$(pl_field "$row" fs)" "$target" "$ddir"
			tx_must mount --make-private "$ddir"
		fi
		remote="{ $(tx_ol_tar_create "$sdir" "$snap" "$level" "$excl"); } | $comp"
		local_="$dec | tee >(wc -c > $(printf '%q' "$RUN/ol-$vid-$level.bytes")) | $(tx_ol_tar_extract "$ddir")"
		say "  files $src level $level ($kind): donor: $remote"
		log "+ donor: $remote"; log "+ $local_"
		t0=$(date +%s.%N)
		if [ "$kind" = frozen ]; then
			# the archive session of this volume for this freeze round: the command in, "exit" so the stream ends, the archive out
			local round; round=$(cat "$RUN/ol.round" 2>/dev/null || echo 1)
			vin=TX_OL_TAR_IN_${idx}_$round; vout=TX_OL_TAR_OUT_${idx}_$round
			if [ -z "${!vin:-}" ] || [ -z "${!vout:-}" ]; then tx_fail "files $src: no idle archive session (index $idx)"; fi
			printf '%s; exit\n' "$remote" >&"${!vin}"
			bash -o pipefail -c "$local_" <&"${!vout}" 2> "$RUN/ol-$vid-$level.err"; rc=$?
		else
			rsh_sh "$remote" </dev/null 2> "$RUN/ol-$vid-$level.rerr" | bash -o pipefail -c "$local_" 2> "$RUN/ol-$vid-$level.err"; rc=${PIPESTATUS[1]}
		fi
		[ "$rc" -eq 0 ] || tx_fail "files $src level $level: extraction failed ($rc; see $RUN/ol-$vid-$level.err)$(tx_tail_hint "$RUN/ol-$vid-$level.err")"
		if [ "$kind" = frozen ]; then TX_RC_REMOTE=$(tx_ol_cmd "cat $(printf '%q' "$snap.rc")" | tr -cd '0-9')
		else TX_RC_REMOTE=$(rsh cat "$snap.rc" </dev/null 2>/dev/null | tr -cd '0-9'); fi
		# tar 1 = warnings: sockets ignored, "file changed as we read it" on a live tree; both fine before the freeze
		if [ "$TX_RC_REMOTE" = 1 ]; then
			if [ "$kind" = frozen ]; then
				nsock=$(grep -c 'socket ignored' "$RUN/ol.tar.err.$idx.$round" 2>/dev/null || true)
				tx_tar_warn_ok "$RUN/ol.tar.err.$idx.$round" || tx_fail "files $src: the final tar on the frozen tree warned beyond the expected lines (see $RUN/ol.tar.err.$idx.$round)"
				: "${nsock:=0}"
			fi
			TX_RC_REMOTE=0
		fi
		[ "$TX_RC_REMOTE" = 0 ] || tx_fail "files $src level $level: the donor's tar exited $TX_RC_REMOTE (see $RUN/ol-$vid-$level.rerr)"
		bytes=$(tr -cd '0-9' < "$RUN/ol-$vid-$level.bytes" 2>/dev/null); : "${bytes:=0}"
		total=$((total + bytes))
		say "  files $src level $level: $(human "$bytes") in $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }') s"
		state_set "vol.$src.ol_level" "$level"; state_set "vol.$src.ol_bytes_$level" "$bytes"
	done < <(tx_ol_rows)
	TX_OL_BYTES=$total
}
tx_ol_sessions_open() {   # ROUNDS: archive sessions per files volume (one per freeze: 2 with a pre-check)
	local f i n row r rounds=${1:-1}
	# tar -x reads to EOF, not to the end-of-archive marker: the archive session of a
	# volume is single-use, its remote bash exits right after the final pass (EOF).
	# Each session: ssh's stdin/stdout are fifos; our ends are held open (fds exported
	# by name, the hook inherits them) so the remote bash waits for its command instead
	# of seeing EOF. Open order: ssh first (blocks on its stdin fifo until we open the
	# write end), our write end, then our read end.
	n=0
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		i=$(pl_field "$row" olidx)
		for (( r = 1; r <= rounds; r++ )); do
			for f in "tar.in.$i.$r" "tar.out.$i.$r"; do rm -f "$RUN/ol.$f"; mkfifo "$RUN/ol.$f" || die "$EX_FAIL" "mkfifo $RUN/ol.$f"; done
			$(ssh_data_cmd) -- 'bash -s' < "$RUN/ol.tar.in.$i.$r" > "$RUN/ol.tar.out.$i.$r" 2> "$RUN/ol.tar.err.$i.$r" &
			printf -v "TX_OL_TAR_PID_${i}_$r" '%s' "$!"
			eval "exec {TX_OL_TAR_IN_${i}_$r}> \"\$RUN/ol.tar.in.$i.$r\" {TX_OL_TAR_OUT_${i}_$r}< \"\$RUN/ol.tar.out.$i.$r\""
			export "TX_OL_TAR_IN_${i}_$r" "TX_OL_TAR_OUT_${i}_$r" "TX_OL_TAR_PID_${i}_$r"
			n=$((n + 1))
		done
	done < <(tx_ol_rows)
	echo 1 > "$RUN/ol.round"
	for f in cmd.in cmd.out; do rm -f "$RUN/ol.$f"; mkfifo "$RUN/ol.$f" || die "$EX_FAIL" "mkfifo $RUN/ol.$f"; done
	$(ssh_data_cmd) -- 'bash -s' < "$RUN/ol.cmd.in" > "$RUN/ol.cmd.out" 2> "$RUN/ol.cmd.err" &
	TX_OL_CMD_PID=$!
	exec {TX_OL_CMD_IN}> "$RUN/ol.cmd.in"
	exec {TX_OL_CMD_OUT}< "$RUN/ol.cmd.out"
	export TX_OL_CMD_IN TX_OL_CMD_OUT TX_OL_CMD_PID
	[ "$(tx_ol_cmd 'echo alive')" = alive ] || die "$EX_ENV" "the idle command session to the donor does not answer"
	say "$n archive session(s) and a command session to the donor are open for the final files pass (they survive the freeze)"
}
tx_ol_sessions_close() {
	local row i v r
	[ -n "${TX_OL_CMD_IN:-}" ] || return 0
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		i=$(pl_field "$row" olidx)
		for r in 1 2; do
			v=TX_OL_TAR_IN_${i}_$r; [ -z "${!v:-}" ] || eval "exec {$v}>&-"
			v=TX_OL_TAR_OUT_${i}_$r; [ -z "${!v:-}" ] || eval "exec {$v}<&-"
			v=TX_OL_TAR_PID_${i}_$r; [ -z "${!v:-}" ] || wait "${!v}" 2>/dev/null
			rm -f "$RUN/ol.tar.in.$i.$r" "$RUN/ol.tar.out.$i.$r"
		done
	done < <(tx_ol_rows)
	exec {TX_OL_CMD_IN}>&- {TX_OL_CMD_OUT}<&-
	wait "${TX_OL_CMD_PID:-}" 2>/dev/null
	rm -f "$RUN/ol.cmd.in" "$RUN/ol.cmd.out"
	TX_OL_CMD_IN=; TX_OL_CMD_OUT=
}
# tx_ol_cmd LINE: one command line through the idle command session; its output, then its rc
tx_ol_cmd() {
	local l rc=1 mark="__OL_END__ $RANDOM$RANDOM"
	printf '%s; echo "%s $?"\n' "$1" "$mark" >&"$TX_OL_CMD_IN"
	while IFS= read -r -u "$TX_OL_CMD_OUT" l; do
		case $l in "$mark "*) rc=${l#"$mark "}; break;; *) printf '%s\n' "$l";; esac
	done
	return "$rc"
}
# the agent's hooks land here (bash $RUN/ol-hook.sh before|after sources the libs and calls this)
# A donor whose dpkg is mid-transaction has a torn package database, and freezing
# copies it as-is: the recipient then comes up half-configured (initramfs-tools
# unpacked but never configured) and its own first apt call refuses with "dpkg was
# interrupted".  That is not a corner case - unattended-upgrades holds that lock
# for hours on a slow guest while it rebuilds initramfs, which is exactly what the
# R16 run on .115 froze into (D34).  Wait for it to settle, and refuse instead of
# freezing a tree that cannot boot cleanly.
tx_ol_wait_dpkg() {
	local limit waited=0 busy
	limit=$(( $(opt dpkg-wait 600) ))
	[ "$limit" -gt 0 ] || return 0
	while :; do
		busy=
		if command -v fuser >/dev/null 2>&1 && fuser -s /var/lib/dpkg/lock-frontend 2>/dev/null; then
			busy="a package transaction holds the dpkg lock"
		elif [ -n "$(timeout 15 dpkg --audit 2>/dev/null)" ]; then
			busy="dpkg --audit reports unfinished work"
		fi
		[ -n "$busy" ] || return 0
		[ "$waited" -lt "$limit" ] || die "$EX_ENV" "donor: $busy, still after ${limit}s.  Freezing now would copy a torn package database and the recipient would come up half-configured.  Let it finish, or stop it on the donor (systemctl stop unattended-upgrades; dpkg --configure -a).  -o dpkg-wait=SECONDS raises the wait, 0 skips this check"
		[ "$waited" -ne 0 ] || say "donor: $busy - waiting up to ${limit}s for it to settle before the freeze"
		sleep 10; waited=$((waited + 10))
	done
}
tx_ol_hook() {
	local what=$1 level prev bytes n=0 row src ddir sdir
	case $what in
		before)
			[ -s "$RUN/ol.files" ] || return 0
			tx_ol_wait_dpkg
			# incremental passes until a pass is small or stops shrinking: the tree is then
			# close to the donor's and the last pass under the freeze stays short
			prev=; level=$(( $(cat "$RUN/ol.level" 2>/dev/null || echo 0) + 1 ))
			while :; do
				tx_ol_files_pass "$level" live; bytes=$TX_OL_BYTES
				n=$((n + 1))
				[ "$bytes" -gt "$TX_OL_SMALL" ] || { say "  files: level $level moved $(human "$bytes"): caught up"; break; }
				[ "$n" -lt "$TX_OL_MAXPASS" ] || { say "  files: $n passes, still $(human "$bytes") per pass: going to the freeze with that"; break; }
				[ -z "$prev" ] || [ "$bytes" -lt $((prev * 8 / 10)) ] || { say "  files: the passes stopped shrinking ($(human "$prev") -> $(human "$bytes")): going to the freeze"; break; }
				prev=$bytes; level=$((level + 1))
			done
			echo "$level" > "$RUN/ol.level" ;;
		precheck)
			transfer_precheck
			echo 2 > "$RUN/ol.round" ;;
		after)
			level=$(( $(cat "$RUN/ol.level" 2>/dev/null || echo 0) + 1 ))
			[ -s "$RUN/ol.files" ] || return 0
			tx_ol_files_pass "$level" frozen; bytes=$TX_OL_BYTES
			echo "$level" > "$RUN/ol.level"
			say "  files: the final level $level from the frozen tree moved $(human "$bytes")"
			# the count check against the frozen tree, through the command session
			while IFS= read -r row; do
				[ -n "$row" ] || continue
				src=$(pl_field "$row" src); ddir=$TX_MNT/dst/$(tx_vol_id "$row"); sdir=$(tx_vol_state "$src.srcdir")
				TX_SRC_RUN=tx_ol_cmd tx_verify_files "$sdir" "$ddir" "$(tx_swap_excludes "$(pl_field "$row" mount)" | wc -l)" "$(tx_swap_excludes "$(pl_field "$row" mount)" | awk '{ s += $2 } END { printf "%.0f\n", s }')"
			done < <(tx_ol_rows) ;;
	esac
}

# --- the pre-check: postfix + verify on dm-snapshots of the consistent copies ---------------
# After the first freeze round the copies equal the donor at that instant. Each
# target with a filesystem gets a dm-snapshot (COW on a loop over a sparse file
# in $RUN - tmpfs, only what postfix writes is kept), $RUN/target.map makes
# target_mount take the snapshots, the copy's post-steps (fsck, xfs log replay,
# grow) run on them, then postfix and verify on that tree. Whatever they say
# is what the real postfix/verify will say after the last freeze - learned
# while the donor is thawed and serving. The snapshots are dropped, the state
# keys they set are reset. Any failure is fatal here (pull thaws and stops):
# nothing on the donor changed, the copy is intact, the operator fixes and
# runs transfer again. -o precheck=0 skips it, precheck-cow=SIZE (2G) sizes the COW.
TX_PC_N=0
# the COW files: /run is a small tmpfs on the Live (it filled up and invalidated the
# snapshot in the first attempt); the Live's root tmpfs has room, -o precheck-dir= elsewhere
TX_PC_DIR=${TX_PC_DIR:-/var/tmp/migrator}
transfer_precheck_cleanup() {
	local i
	target_umount 2>/dev/null
	for (( i = TX_PC_N - 1; i >= 0; i-- )); do
		dmsetup remove "migrator-pc-$i" 2>/dev/null || { sleep 1; dmsetup remove "migrator-pc-$i" 2>/dev/null; }
		[ -z "$(cat "$RUN/precheck-$i.loop" 2>/dev/null)" ] || losetup -d "$(cat "$RUN/precheck-$i.loop")" 2>/dev/null
		rm -f "$TX_PC_DIR/precheck-$i.cow" "$RUN/precheck-$i.loop"
	done
	rm -f "$RUN/target.map"
	# what postfix/verify marked: the real ones come after the last freeze
	[ "$(state_get phase.postfix)" != "done" ] || state_set phase.postfix precheckd
	[ "$(state_get phase.verify)" != "done" ] || state_set phase.verify precheckd
	rm -f "$RUN/summary"
}
transfer_precheck() {
	local plan=$RUN/plan row target mount fs notes vid sectors cow loop snap t0 cowsize free
	cowsize=$(opt precheck-cow 2G); TX_PC_DIR=$(opt precheck-dir "$TX_PC_DIR")
	t0=$(date +%s)
	say "pre-check: postfix and verify on dm-snapshots of the copies (the donor is thawed meanwhile; COW files under $TX_PC_DIR)"
	modprobe dm-snapshot 2>/dev/null || true
	have dmsetup || die "$EX_ENV" "pre-check: no dmsetup on this box (dmsetup package)"
	# the files volumes' targets are mounted between their passes: a snapshot origin must be free
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		mount=$TX_MNT/dst/$(tx_vol_id "$row")
		! mountpoint -q "$mount" 2>/dev/null || tx_must umount "$mount"
	done < <(tx_ol_rows)
	mkdir -p "$TX_PC_DIR" || die "$EX_FAIL" "pre-check: cannot create $TX_PC_DIR"
	free=$(df --output=avail -B1 "$TX_PC_DIR" 2>/dev/null | tail -1 | tr -cd '0-9')
	[ "${free:-0}" -ge $((512 * 1024 * 1024)) ] || die "$EX_ENV" "pre-check: only $(human "${free:-0}") free under $TX_PC_DIR for the snapshots' COW (postfix writes an initramfs and more there): -o precheck-dir=DIR with room, or -o precheck=0"
	trap transfer_precheck_cleanup EXIT
	: > "$RUN/target.map"
	TX_PC_N=0
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		mount=$(pl_field "$row" mount); target=$(pl_field "$row" target); fs=$(pl_field "$row" fs); notes=$(pl_field "$row" notes); vid=$(tx_vol_id "$row")
		case $mount in /*) ;; *) continue;; esac
		[ -b "$target" ] || continue
		sectors=$(blockdev --getsz "$target") || die "$EX_FAIL" "pre-check: blockdev --getsz $target"
		cow=$TX_PC_DIR/precheck-$TX_PC_N.cow
		truncate -s "$cowsize" "$cow" || die "$EX_FAIL" "pre-check: cannot make the COW file $cow"
		loop=$(losetup --show -f "$cow") || die "$EX_FAIL" "pre-check: losetup $cow"
		echo "$loop" > "$RUN/precheck-$TX_PC_N.loop"
		snap=/dev/mapper/migrator-pc-$TX_PC_N
		run dmsetup create "migrator-pc-$TX_PC_N" --table "0 $sectors snapshot $target $loop N 8" || die "$EX_FAIL" "pre-check: dm-snapshot of $target failed (dm-snapshot module? dmsetup?)"
		TX_PC_N=$((TX_PC_N + 1))
		udevadm settle 2>/dev/null; [ -b "$snap" ] || sleep 1
		printf '%s\t%s\n' "$target" "$snap" >> "$RUN/target.map"
		case $(pl_field "$row" method) in
			block) [ "$fs" != xfs ] || pl_has "$notes" dirty || notes="${notes:+$notes,}dirty"
			       say "  pre-check: $mount = snapshot of $target ($fs): the copy's checks and grow on the snapshot"
			       tx_block_after "$fs" "$snap" "$notes" "$vid" ;;
			*)     say "  pre-check: $mount = snapshot of $target ($fs)" ;;
		esac
	done < <(plan_section "$plan" volumes)
	[ "$TX_PC_N" -gt 0 ] || die "$EX_FAIL" "pre-check: no mounted volume in the plan"
	TARGET_MNT=/mnt/migrator/precheck
	target_mount rw binds
	PF_PRECHECK=1 postfix_run "$TARGET_MNT"
	VF_PRECHECK=1 verify_run "$TARGET_MNT"
	trap - EXIT
	transfer_precheck_cleanup
	say "pre-check passed in $(( $(date +%s) - t0 )) s: postfix and verify are green on the copy as of the first freeze; catching up and freezing again"
}

# --- the on-line phase ------------------------------------------------------------------
# One agent session carries every block volume: pass 1 in full, then only the
# chunks written since (the donor keeps running), fsfreeze, the final delta; the
# donor stays frozen and polls this box for the cutover command (cutover_run).
# The ESP (vfat, never frozen, hardly ever written) goes first by tar over the
# master. Everything that writes to a copy (e2fsck, resize2fs, xfs_growfs) runs
# after the final delta: a delta would clobber it. Knobs (-o): chunk=64K
# passes=8 converge=10 max-est=100 tracker=auto|bpf|ftrace verify-hash=1
# cutover-port=2223 stall=300 compress=auto|zstd[:LEVEL]|none patience=1800.
transfer_online_run() {
	local plan=$RUN/plan comp acomp t i n row src target method fs notes vid st agent out rc line fmode cut_host cut_port
	local -a rows=() blocks=() vols=()
	[ -n "${DONOR_HOST:-}" ] || die "$EX_ENV" "not connected to a donor (the driver connects before transfer)"
	[ -s "$plan" ] || die "$EX_ENV" "no plan at $plan: run 'migrator -s plan DONOR' first"
	[ "$(plan_get "$plan" target mode)" = online ] || die "$EX_PLAN" "the plan is not an on-line one ([target] has no mode=online): plan again against the running donor"
	agent=${MIGRATOR_AGENT:-$(state_get agent.path)}
	# an empty or truncated file still has +x: the shell then runs it as an empty
	# script, exits 0 without a word and nothing is frozen (seen on .111, 2026-11-19)
	[ -n "$agent" ] && [ -x "$agent" ] && [ -n "$("$agent" version 2>/dev/null)" ] \
		|| die "$EX_ENV" "migrator-agent at '${agent:-unset}' does not run (missing, empty or truncated?): reinstall it from the Live's own build"
	# Two different things are compressed two different ways here.
	# Block volumes: the agent compresses THE PAYLOAD OF EACH FRAME with zstd
	# (statically linked in, so the donor needs nothing installed). A stream
	# compressor on the session itself cannot work - the session is interactive and
	# lz4/zstd/gzip all hold a short write in their buffer, so "ok hello" never
	# arrives (seen with gzip, 2026-10-21). Measured on a 9.4 GiB XFS root:
	# none 19.3 s / 1984 MiB on the wire, zstd:1 15.5 s / 1319 MiB (1.5x),
	# zstd:3 17.8 s / 1265 MiB - level 1 wins on a fast link, while on a 100 Mbit
	# one level 3 won (85 s frozen instead of 100). Which is why the level is not
	# guessed: compress=auto (the default) has the donor report the seconds it
	# spent compressing, so the agent knows what that cpu produces and what the
	# link took, climbs while the cpu stays ahead and the data compresses, and
	# comes back down when it does not. -o compress=zstd:N pins it.
	# File volumes: their tar passes are one-shot pipelines, so an ordinary
	# external compressor works; TX_COMP picks whatever the donor already has.
	acomp=$(opt compress auto)
	case $acomp in auto|none|zstd|zstd:[0-9]|zstd:1[0-9]) ;; *) die "$EX_PLAN" "compress=$acomp: on-line wants auto, none or zstd[:LEVEL] (the agent compresses each frame; lz4/gzip are off-line stream compressors)";; esac
	comp=none
	for t in zstd lz4 gzip; do [ "$(state_get "donor.tool.$t")" = 1 ] && { comp=$t; break; }; done
	TX_DATA=ssh; TX_COMP=$comp
	mapfile -t rows < <(plan_section "$plan" volumes)
	n=${#rows[@]}; [ "$n" -gt 0 ] || die "$EX_PLAN" "no [volumes] rows in $plan"
	local -a files=() esp_tar=()
	for row in "${rows[@]}"; do
		method=$(pl_field "$row" method); src=$(pl_field "$row" src)
		case $method in
			block) blocks+=("$row") ;;
			files) files+=("$row") ;;
			# the ESP: exact bytes by the agent when it fits its slot (no tar on the donor needed,
			# nothing mounted there; vfat cannot be frozen, it hardly ever changes); tar otherwise
			esp)   [ "$src" = - ] || { if [ "$(pl_field "$row" size)" -le "$(pl_field "$row" tsize)" ]; then blocks+=("$row"); else esp_tar+=("$row"); fi; } ;;
			mkswap|pv) ;;
			*) die "$EX_PLAN" "volume $src: unknown method '$method'" ;;
		esac
	done
	if [ ${#esp_tar[@]} -gt 0 ] && [ "$(state_get donor.tool.tar)" = 0 ]; then die "$EX_ENV" "the ESP $(pl_field "${esp_tar[0]}" src) is bigger than its slot and the donor has no tar to copy it by files: install tar on the donor"; fi
	if [ ${#files[@]} -gt 0 ] && [ "$(state_get donor.tool.tar)" = 0 ]; then die "$EX_ENV" "the files method needs tar on the donor (none there): install tar on the donor, or plan with a disk the volumes fit on"; fi
	tx_require_tools "${rows[@]}"
	say "transfer (on-line): $n volumes, ${#blocks[@]} block volume(s) by migrator-agent (frames: $acomp), file volumes by tar (stream: $comp), tracker=$(opt tracker auto), chunk=$(opt chunk 64K), converge=$(opt converge 10) s, passes<=$(opt passes 8)"
	# the ESP(s) first: tar from where the donor mounts them (nothing is mounted on the donor)
	TX_N=$n
	for (( i = 0; i < n; i++ )); do
		row=${rows[i]}; src=$(pl_field "$row" src); target=$(pl_field "$row" target); method=$(pl_field "$row" method); vid=$(tx_vol_id "$row")
		TX_ORD=$((i + 1)); TX_SRC=$src; TX_VID=$vid
		# shellcheck disable=SC2034  # what die() records in $RUN/failure
		VOLUME=$src
		case $method in
			mkswap|pv) say "vol $TX_ORD/$n: $src -> $target ($method): nothing to stream, apply made $target"
			           [ -n "$DRY" ] || { vol_state_set "$src" 'done'; state_set "vol.$src.rc" 0; } ;;
			esp) if [ "$src" = - ]; then say "vol $TX_ORD/$n: the empty ESP $target ($(pl_field "$row" notes)): postfix fills it"; continue; fi
			     if [ "$(pl_field "$row" size)" -le "$(pl_field "$row" tsize)" ]; then say "vol $TX_ORD/$n: $src -> $target (esp): exact bytes by the agent with the block volumes"; continue; fi
			     if [ "$(tx_vol_state "$src")" = 'done' ] && ! tx_redo_wants "$vid" "$src"; then say "vol $TX_ORD/$n: $src ($method): done earlier, skipped"; continue; fi
			     say "vol $TX_ORD/$n: $src -> $target (esp, by tar from the donor's mount, before the freeze)"
			     TX_SRC_DIR=$(rsh findmnt -rno TARGET --source "$src" 2>/dev/null </dev/null | head -1)
			     [ -n "$TX_SRC_DIR" ] || TX_SRC_DIR=$(inv_lookup "$RUN/donor.inv" fstab dev "$src" mount)
			     if [ -z "$TX_SRC_DIR" ] || [ "$TX_SRC_DIR" = - ]; then TX_SRC_DIR=; tx_fail "the ESP $src is not mounted on the donor and its fstab says nothing: cannot copy it on-line"; fi
			     [ -n "$DRY" ] || { vol_state_set "$src" running; state_set "vol.$src.started" "$(date +%s)"; }
			     TX_PREV=$(tx_vol_state "$src")
			     transfer_files "$row" vfat
			     TX_SRC_DIR=; unset TX_PREV
			     [ -n "$DRY" ] || { vol_state_set "$src" 'done'; state_set "vol.$src.finished" "$(date +%s)"; state_set "vol.$src.rc" 0; } ;;
		esac
	done
	TX_SRC=; TX_VID=; unset VOLUME
	if [ ${#blocks[@]} -eq 0 ] && [ ${#files[@]} -eq 0 ]; then say "transfer (on-line): nothing to stream; done"; [ -n "$DRY" ] || phase_done transfer; return 0; fi
	# the files volumes: their targets mounted, the donor's source dirs found, level 0 now
	: > "$RUN/ol.files"
	local -a also=()
	for row in "${files[@]}"; do
		src=$(pl_field "$row" src); target=$(pl_field "$row" target); fs=$(pl_field "$row" fs); vid=$(tx_vol_id "$row")
		case $fs in ext2|ext3|ext4|xfs) ;; *) die "$EX_PLAN" "files method on $src: fs=$fs, want ext2/3/4 or xfs";; esac
		local sdir; sdir=$(rsh findmnt -rno TARGET --source "$src" 2>/dev/null </dev/null | head -1)
		[ -n "$sdir" ] || die "$EX_ENV" "files volume $src is not mounted on the donor: nothing to copy by files"
		vol_state_set "$src.srcdir" "$sdir"
		also+=(--freeze-also "$sdir")
		printf '%s\tolidx=%d\n' "$row" "${#also[@]}" >> "$RUN/ol.files"
		say "  files: $src (mounted at $sdir on the donor) -> $target by tar incremental passes"
		if [ -z "$DRY" ]; then
			tx_register_cleanup_local
			tx_must mkdir -p "$TX_MNT/dst/$vid"
			tx_must mount -t "$fs" "$target" "$TX_MNT/dst/$vid"
			tx_must mount --make-private "$TX_MNT/dst/$vid"
			vol_state_set "$src" running; state_set "vol.$src.started" "$(date +%s)"
		fi
	done
	local precheck; precheck=$(opt precheck 1)
	if [ ${#files[@]} -gt 0 ] || [ "$precheck" = 1 ]; then
		if [ -n "$DRY" ]; then say "(dry) files: level 0 of every files volume, then incremental passes before the freeze and one after it; precheck=$precheck"
		else
			[ ${#files[@]} -eq 0 ] || { tx_ol_files_pass 0 live; tx_ol_sessions_open "$([ "$precheck" = 1 ] && echo 2 || echo 1)"; }
			echo 1 > "$RUN/ol.round"; rm -f "$RUN/ol.level"
			cat > "$RUN/ol-hook.sh" <<EOF
#!/bin/bash
# the agent's hooks (generated by transfer_online_run): before|after the freeze = the files passes, precheck = postfix+verify on snapshots
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
for f in common ssh bootstrap inventory plan apply transfer target postfix netfix verify; do . "$MIGRATOR_LIB/\$f.sh"; done
# the libs reset these at source time: the donor of THIS run, verbatim; the options the hook reads
DONOR_USER=$DONOR_USER; DONOR_HOST=$DONOR_HOST; DONOR_PORT=$DONOR_PORT; export DONOR_USER DONOR_HOST DONOR_PORT
MIGRATOR_MODE=online; ROLE_TAG=destination; TX_COMP=$TX_COMP; TX_MNT=$TX_MNT; _ssh_setopts
OPT[precheck-cow]=$(opt precheck-cow 2G); OPT[precheck-dir]=$(opt precheck-dir /var/tmp/migrator); OPT[fsck]=$(opt fsck quick)
tx_ol_hook "\$1"
EOF
		fi
	fi
	[ ${#blocks[@]} -gt 0 ] || say "transfer (on-line): no block volumes: the agent only freezes and runs the files passes"
	# the agent session: every block volume at once
	i=0
	for row in "${blocks[@]}"; do
		i=$((i + 1)); src=$(pl_field "$row" src); target=$(pl_field "$row" target)
		vols+=(--vol "$i=$src=$target")
		say "  vol $i: $src -> $target ($(pl_field "$row" fs), $(human "$(pl_field "$row" size)"))"
	done
	cut_port=$(opt cutover-port 2223)
	# shellcheck disable=SC2016  # SSH_CONNECTION expands on the donor: "client_ip client_port server_ip server_port"
	cut_host=$(rsh_sh 'echo "$SSH_CONNECTION"' </dev/null 2>/dev/null | awk '{print $1}')
	if [ -n "$(opt relay)" ]; then
		# E2: the donor cannot dial this box; the poller goes back through the
		# relay, onto the reverse tunnel ssh_relay_start put up at connect time
		cut_host=$(state_get relay.host); cut_port=$(state_get relay.cut_port)
		say "cutover poller: through the relay ($cut_host:$cut_port)"
	fi
	[ -n "$cut_host" ] || cut_host=$(ip -o route get "$DONOR_HOST" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')
	[ -n "$cut_host" ] || die "$EX_ENV" "cannot tell which address of this box the donor sees (SSH_CONNECTION empty): -o cutover-port= and a reachable address are needed for the cutover poller"
	if [ -n "$YES" ] || ! is_tty; then fmode=auto; else fmode=ask; fi
	local remote sshcmd
	# D41: not `serve` but `attach`. The donor's session (the tracker's bitmap, the
	# freeze) must outlive this ssh channel: a flapping link used to end the run and
	# the next one re-copied from zero. serve --listen detaches from the session and
	# holds the state; attach is one client of it, so the pull can come back after a
	# dropped connection and resume the pass where the copy stopped.
	remote="$DONOR_RUN/agent attach $DONOR_RUN/agent.sock"
	sshcmd="$(ssh_data_cmd) -- $(printf '%q' "bash -o pipefail -c $(printf '%q' "$remote")")"
	local -a args=(pull --ssh "$sshcmd" "${vols[@]}" "${also[@]}" --chunk "$(opt chunk 64K)" --passes "$(opt passes 8)" --converge "$(opt converge 10)" --max-est "$(opt max-est 100)"
		--tracker "$(opt tracker auto)" --settle "$(opt settle 1000)" --stall "$(opt stall 300)" --compress "$acomp"
		--patience "$(opt patience 1800)" --freeze "$fmode" --cutover "$cut_host:$cut_port")
	[ "$(opt verify-hash 0)" != 1 ] || args+=(--verify)
	[ ${#files[@]} -eq 0 ] || args+=(--before-freeze "bash $RUN/ol-hook.sh before" --after-freeze "bash $RUN/ol-hook.sh after")
	[ "$precheck" != 1 ] || args+=(--precheck "bash $RUN/ol-hook.sh precheck")
	out=$RUN/online.out
	echo "+ donor: $remote"; log "+ donor: $remote"
	echo "+ $agent $(printf '%q ' "${args[@]}")"; log "+ $agent $(printf '%q ' "${args[@]}")"
	if [ -n "$DRY" ]; then say "(dry) transfer (on-line): nothing streamed, the donor is not frozen"; return 0; fi
	! declare -f apply_fingerprint_check >/dev/null || apply_fingerprint_check
	for row in "${blocks[@]}"; do src=$(pl_field "$row" src); vol_state_set "$src" running; state_set "vol.$src.started" "$(date +%s)"; done
	tx_status "transfer (on-line): ${#blocks[@]} block volumes through migrator-agent"
	"$agent" "${args[@]}" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
	sed 's/^/agent: /' "$out" >> "$RUN/log" 2>/dev/null || true
	tx_ol_sessions_close
	line=$(grep '^RESULT ' "$out" | tail -1)
	if [ "$rc" -ne 0 ] || [ "${line#RESULT }" = "${line#RESULT ok}" ]; then
		for row in "${blocks[@]}" "${files[@]}"; do src=$(pl_field "$row" src); vol_state_set "$src" failed; done
		for row in "${files[@]}"; do umount "$TX_MNT/dst/$(tx_vol_id "$row")" 2>/dev/null; done
		die "$EX_FAIL" "on-line transfer failed (migrator-agent exit $rc; the donor is not frozen): see $out and $RUN/log; fix the cause and run 'migrator -s transfer' again"
	fi
	# the files volumes are complete (their last pass ran under the freeze): unmount, done
	for row in "${files[@]}"; do
		src=$(pl_field "$row" src); vid=$(tx_vol_id "$row")
		! mountpoint -q "$TX_MNT/dst/$vid" 2>/dev/null || tx_must umount "$TX_MNT/dst/$vid"; run rmdir "$TX_MNT/dst/$vid"
		state_set "vol.$src.bytes" "$(df --output=used -B1 "$(pl_field "$row" target)" 2>/dev/null | tail -1 | tr -cd '0-9')"
		vol_state_set "$src" 'done'; state_set "vol.$src.finished" "$(date +%s)"; state_set "vol.$src.rc" 0
	done
	line=$(grep '^CUTOVER ' "$out" | tail -1)
	state_set online.cutover_host "$(echo "$line" | sed -n 's/.*host=\([^ ]*\).*/\1/p')"
	state_set online.cutover_port "$(echo "$line" | sed -n 's/.*port=\([^ ]*\).*/\1/p')"
	state_set online.cutover_token "$(echo "$line" | sed -n 's/.*token=\([^ ]*\).*/\1/p')"
	state_set online.frozen 1; state_set online.frozen_at "$(date +%s)"
	[ -n "$(state_get online.cutover_token)" ] || die "$EX_FAIL" "the agent reported no cutover token (see $out): the donor is frozen without a poller; thaw it by hand (fsfreeze -u) and retry"
	say "the donor's filesystems are FROZEN from now on; it polls $cut_host:$cut_port for the cutover command ('migrator -s cutover'; rollback: '-o cutover=rollback')"
	# only now anything may write to the copies: the checks and the grows
	i=0
	for row in "${blocks[@]}"; do
		i=$((i + 1)); src=$(pl_field "$row" src); target=$(pl_field "$row" target); fs=$(pl_field "$row" fs); notes=$(pl_field "$row" notes); vid=$(tx_vol_id "$row")
		TX_SRC=$src; TX_VID=$vid
		# shellcheck disable=SC2034
		VOLUME=$src
		# a frozen xfs keeps a log that wants replay (no unmount record on freeze):
		# mount rw + umount on the copy first, as for a dirty donor; a frozen ext4
		# is clean (needs_recovery is cleared by the freeze), e2fsck -n suffices
		[ "$fs" != xfs ] || pl_has "$notes" dirty || notes="${notes:+$notes,}dirty"
		say "vol $i/${#blocks[@]} ($src): checking the copy on $target$(pl_has "$notes" grow && echo ', then growing it')"
		tx_block_after "$fs" "$target" "$notes" "$vid"
		state_set "vol.$src.bytes" "$(pl_field "$row" size)"
		vol_state_set "$src" 'done'; state_set "vol.$src.finished" "$(date +%s)"; state_set "vol.$src.rc" 0
	done
	TX_SRC=; TX_VID=; unset VOLUME
	if [ "$(plan_get "$plan" target raid)" = 1 ] && declare -F md_sync_resume_plan >/dev/null; then
		say "md: resuming the resync of $(plan_get "$plan" target md | tr ',' ' ') (background; cat /proc/mdstat)"
		md_sync_resume_plan "$plan"
	fi
	phase_done transfer
	tx_status "transfer (on-line): done, $n volumes, donor frozen"
	say "transfer done (on-line): $n volumes; ${line#CUTOVER }; $(grep '^RESULT ' "$out" | tail -1)"
}

# --- the phase ------------------------------------------------------------------------
transfer_run() {
	local plan=$RUN/plan data comp i n row src target method fs size used vid st pending=0 est=0 total skipped=0
	local -a rows=()
	if [ "${MIGRATOR_MODE:-$(state_get mode)}" = online ]; then
		if ! phase_is_done apply; then
			if [ -n "$DRY" ]; then say "(dry) apply is not marked done in $RUN/state; continuing"
			else die "$EX_ENV" "run 'migrator -s apply' first (phase apply is not done in $RUN/state)"; fi
		fi
		transfer_online_run; return
	fi
	if ! phase_is_done apply; then
		if [ -n "$DRY" ]; then say "(dry) apply is not marked done in $RUN/state; continuing"
		else die "$EX_ENV" "run 'migrator -s apply' first (phase apply is not done in $RUN/state)"; fi
	fi
	[ -n "${DONOR_HOST:-}" ] || die "$EX_ENV" "not connected to a donor (the driver connects before transfer)"
	[ -s "$plan" ] || die "$EX_ENV" "no plan at $plan: run 'migrator -s plan DONOR' first"
	data=$(opt data "$(plan_get "$plan" target data)"); data=${data:-ssh}
	comp=$(opt compress "$(plan_get "$plan" target compress)"); comp=${comp:-lz4}
	case $data in ssh|raw) ;; *) die "$EX_PLAN" "data=$data: want ssh or raw";; esac
	tx_comp "$comp" >/dev/null || die "$EX_PLAN" "compress=$comp: want lz4, zstd, gzip or none"
	TX_DATA=$data; TX_COMP=$comp
	# raid=1: the arrays apply made must be running (a cleanup or a Live reboot stops them)
	! declare -F md_assemble_plan >/dev/null || [ "$(plan_get "$plan" target raid)" != 1 ] || md_assemble_plan "$plan"
	mapfile -t rows < <(plan_section "$plan" volumes)
	n=${#rows[@]}; [ "$n" -gt 0 ] || die "$EX_PLAN" "no [volumes] rows in $plan"
	tx_require_tools "${rows[@]}"
	[ "$data" = raw ] && warn "data=raw: plain TCP (busybox nc), no encryption, no integrity beyond partclone's CRC: trusted LANs only (the M0 measurement decides its use)"
	say "transfer: $n volumes, data=$data compress=$comp, watchdog $(tx_fmt_time "$(tx_watchdog_s)") (repeat one volume: -o redo=N)"
	for row in "${rows[@]}"; do
		src=$(pl_field "$row" src); method=$(pl_field "$row" method); vid=$(tx_vol_id "$row")
		case $method in block|files) ;; esp) [ "$src" != - ] || continue;; *) continue;; esac
		[ "$(tx_vol_state "$src")" = 'done' ] && ! tx_redo_wants "$vid" "$src" && continue
		used=$(pl_field "$row" used); size=$(pl_field "$row" size)
		case $used in ''|-|*[!0-9]*) total=$size;; *) total=$used;; esac
		pending=$((pending + 1)); est=$((est + total))
	done
	[ $pending -gt 0 ] && transfer_probe "$comp" "$est"
	tx_status "transfer: start, $n volumes ($pending to stream, $(human "$est"))"
	for (( i = 0; i < n; i++ )); do
		row=${rows[i]}
		src=$(pl_field "$row" src); target=$(pl_field "$row" target); method=$(pl_field "$row" method)
		fs=$(pl_field "$row" fs); size=$(pl_field "$row" size); vid=$(tx_vol_id "$row")
		TX_ORD=$((i + 1)); TX_N=$n; TX_SRC=$src; TX_VID=$vid
		# shellcheck disable=SC2034  # what die() records in $RUN/failure
		VOLUME=$src
		st=$(tx_vol_state "$src")
		if [ "$st" = 'done' ] && ! tx_redo_wants "$vid" "$src"; then
			say "vol $TX_ORD/$n: $src -> $target ($method): done earlier, skipped (-o redo=$vid repeats it)"
			skipped=$((skipped + 1)); continue
		fi
		say "vol $TX_ORD/$n: $src -> $target ($method, $(human "$size"))"
		TX_PREV=$st        # what transfer_files decides the refresh by (pending|failed|running|"")
		if [ -z "$DRY" ]; then
			vol_state_set "$src" running; state_set "vol.$src.started" "$(date +%s)"
			! declare -f apply_fingerprint_check >/dev/null || apply_fingerprint_check
		fi
		case $method in
			mkswap|pv) say "  nothing to stream: apply made $target" ;;
			block)     transfer_block "$row" ;;
			# an ESP without a donor side (src=-): esp-new (bios donor -> uefi recipient) or
			# esp-mirror (raid=1, the second disk's): apply made the empty vfat, postfix fills it
			esp)       if [ "$src" = - ]; then say "  nothing to stream: apply made the empty ESP $target ($(pl_field "$row" notes)), postfix fills it"; else transfer_files "$row" vfat; fi ;;
			files)     transfer_files "$row" ;;
			*)         die "$EX_PLAN" "volume $src: unknown method '$method' (block, files, esp, mkswap, pv)" ;;
		esac
		if [ -z "$DRY" ]; then
			vol_state_set "$src" 'done'; state_set "vol.$src.finished" "$(date +%s)"; state_set "vol.$src.rc" 0
		fi
	done
	TX_SRC=; TX_VID=; unset VOLUME TX_PREV
	# raid=1: every block of the copy is on both members already; the initial resync apply
	# paused (it would have competed with the copy for the same disks) runs from here on
	if [ "$(plan_get "$plan" target raid)" = 1 ] && declare -F md_sync_resume_plan >/dev/null; then
		say "md: resuming the resync of $(plan_get "$plan" target md | tr ',' ' ') (background; cat /proc/mdstat)"
		md_sync_resume_plan "$plan"
	fi
	if [ -n "$DRY" ]; then say "(dry) transfer: $n volumes printed, nothing streamed"; return 0; fi
	phase_done transfer
	tx_status "transfer: done, $n volumes"
	say "transfer done: $n volumes ($skipped skipped as done earlier)"
}
