#!/bin/bash
# Shared helpers for migrator: sourced by bin/migrator and by every lib/*.sh.
# Nothing here touches disks or the network; it only defines how the tool
# talks (say/warn/die), how it runs commands (run: echo first, then execute,
# or only echo under -n), how it keeps state in $RUN, and how it cleans up.
#
# Globals the driver sets before sourcing:
#   MIGRATOR_LIB  directory holding the libs (this file's directory)
#   RUN           state directory, default /run/migrator (tmpfs: gone on reboot)
#   DRY           y = print commands only (-n)     YES  y = never prompt (-y)
#   ROLE_TAG      text shown on every line, e.g. "destination"
#   OPT           associative array of -o key=value options
#
# Exit codes (the ONE table; docs and the panel contract quote it):
# shellcheck disable=SC2034  # used by the libs that source this file
EX_OK=0       # done
EX_FAIL=1     # runtime failure (something we tried did not work)
EX_ENV=2      # usage / environment / identity: not full Live, apt or ssh failed, wrong donor
EX_VERIFY=3   # verify failed: the recipient was written, do NOT reboot it
EX_PLAN=4     # plan infeasible or an edited plan rejected: nothing was written

: "${RUN:=/run/migrator}"
: "${DRY:=}"
: "${YES:=}"
: "${ROLE_TAG:=}"
declare -gA OPT 2>/dev/null || declare -A OPT
WARNINGS=0
CLEANUP_CMDS=()

# --- output -----------------------------------------------------------------
_tag() { if [ -n "$ROLE_TAG" ]; then echo "[migrator $ROLE_TAG]"; else echo "[migrator]"; fi; }
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log()  { mkdir -p "$RUN" 2>/dev/null; echo "$(_ts) $*" 2>/dev/null >> "$RUN/log" || true; }
say()  { echo "$(_tag) $*"; log "$*"; }
# warnings go to both streams (startup-task keeps only stdout on the console);
# plain writes, not tee /dev/stderr: tee would reopen a redirected stderr file
# with O_TRUNC and wipe everything logged before
warn() { local m; m="$(_tag) WARN: $*"; echo "$m" >&2; echo "$m"; log "WARN: $*"; WARNINGS=$((WARNINGS+1)); }
# die [CODE] MESSAGE — records the failure for the task template, then exits.
# The last stdout line is always the reason: that is what the operator (and
# the panel, through /run/migrator/failure) gets to see.
die() {
	local code=$EX_FAIL
	case "$1" in [0-9]|[0-9][0-9]) code=$1; shift;; esac
	log "ERROR(exit $code): $*"
	mkdir -p "$RUN" 2>/dev/null
	# 先静默再写：顺序反了会先打开 $RUN/failure（可能失败，报错漏到终端），
	# 之后才把标准错误丢给 /dev/null
	printf 'exit=%s phase=%s volume=%s reason=%s log=%s\n' \
		"$code" "${PHASE:-}" "${VOLUME:-}" "$*" "$RUN/log" 2>/dev/null > "$RUN/failure" || true
	echo "$(_tag) ERROR: $*" >&2
	echo "$(_tag) ERROR: $*"
	exit "$code"
}
have() { command -v "$1" >/dev/null 2>&1; }

# --- running commands ---------------------------------------------------------
# run CMD ARGS...  Echo the exact command with "+ " (or "(dry) " under -n) so
# the log doubles as a runbook the operator can replay by hand, then run it.
# Returns the command's status; callers decide whether that is fatal.
run() {
	local q; q=$(printf '%q ' "$@"); q=${q% }
	if [ -n "$DRY" ]; then echo "(dry) $q"; log "(dry) $q"; return 0; fi
	echo "+ $q"; log "+ $q"
	"$@"
}
# run_sh 'shell pipeline'  — same, for pipelines; runs under bash -o pipefail.
run_sh() {
	if [ -n "$DRY" ]; then echo "(dry) $1"; log "(dry) $1"; return 0; fi
	echo "+ $1"; log "+ $1"
	bash -o pipefail -c "$1"
}
# must CMD...  run and die on failure.
must() { run "$@" || die "command failed ($?): $*"; }
must_sh() { run_sh "$1" || die "command failed ($?): $1"; }

# --- options, prompts ---------------------------------------------------------
opt() { local v=${OPT[$1]-}; if [ -n "$v" ]; then echo "$v"; else echo "${2-}"; fi; }
# Every key -o understands, by the mode it belongs to. This list is the whole
# reference: the usage header, docs/migrator.md and the table on migrator are
# checked against it by the test suite, so none of the four can drift.
# A key that is not here is a typo, and a typo has to fail: "-o maxest=600"
# used to be accepted and do nothing, and the run then froze the donor for a
# window the operator believed he had raised. Keys are spelled with hyphens;
# an underscore is accepted and normalised, so scripts written before the
# spelling settled keep working.
MIGRATOR_OPTS_BOTH="boot-part bootorder boottest cipher cloudinit compress console cutover donor-nic driver expect force fsck label mode nic nic-pin offline raid raw redo relay root"
MIGRATOR_OPTS_OFFLINE="data sshd-port watchdog"
MIGRATOR_OPTS_ONLINE="chunk converge cutover-port dpkg-wait max-est passes patience precheck precheck-cow precheck-dir settle stall tracker verify-hash"
# opt_check — refuse unknown -o keys, naming the near miss when there is one
opt_check() {
	local k n c all="$MIGRATOR_OPTS_BOTH $MIGRATOR_OPTS_OFFLINE $MIGRATOR_OPTS_ONLINE" hint
	for k in "${!OPT[@]}"; do
		case " $all " in *" $k "*) continue ;; esac
		n=$(printf '%s' "$k" | tr -d '_-' | tr '[:upper:]' '[:lower:]'); hint=
		for c in $all; do [ "$(printf '%s' "$c" | tr -d '-')" = "$n" ] && { hint=" (did you mean $c=?)"; break; }; done
		die "$EX_ENV" "unknown option -o $k$hint; 'migrator -h' lists every key, so a typo is refused instead of ignored"
	done
	# "-o compress=none,patience=600" is not two options: the comma stays in the
	# value, and some values really do take one (driver=mod1,mod2,
	# console=ttyS0,115200), so the comma cannot be a separator. Without this
	# the run would quietly use "none,patience=600" as the compressor.
	local v rest cand
	for k in "${!OPT[@]}"; do
		v=${OPT[$k]}
		case $v in *,*=*) ;; *) continue ;; esac
		rest=${v#*,}; cand=${rest%%=*}; cand=${cand//_/-}
		case " $all " in *" $cand "*) ;; *) continue ;; esac
		die "$EX_ENV" "-o $k=$v: each option is passed on its own, not joined by commas (a comma belongs to the value, as in driver=mod1,mod2): use -o $k=${v%%,*} -o $cand=${rest#*=}"
	done
}
# low_mem_defaults — a 1 GiB Live cannot also hold the pre-check COW and a
# chroot rebuild next to the migration itself; on small RAM drop precheck (and
# the boot test, which has its own guard) unless the operator insists (D23)
low_mem_defaults() {
	local mt
	mt=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
	[ -n "$mt" ] && [ "$mt" -lt 1536 ] || return 0
	if [ -z "${OPT[precheck]:-}" ]; then
		OPT[precheck]=0
		warn "low memory (${mt} MiB): precheck disabled (force with -o precheck=1)"
	fi
	if [ -z "${OPT[boottest]:-}" ]; then OPT[boottest]=0; fi
}
is_tty() { [ -t 0 ] && [ -t 1 ]; }
# confirm PROMPT [EXPECTED]
#   -y answers yes to everything (unattended). Without a terminal and without
#   -y there is nobody to ask, so refuse rather than guess. When EXPECTED is
#   given the operator must type exactly that (e.g. "sda 894"), read off the
#   screen, so a reflex "y" cannot pick the wrong disk.
confirm() {
	local prompt=$1 expected=${2-} a
	[ -n "$YES" ] && return 0
	is_tty || die "$EX_ENV" "no terminal to confirm '$prompt' (use -y to answer yes to everything)"
	if [ -n "$expected" ]; then
		read -rp "$(_tag) $prompt  Type exactly '$expected' to continue: " a
		[ "$a" = "$expected" ] || die "$EX_ENV" "confirmation did not match, aborting"
	else
		read -rp "$(_tag) $prompt [y/N] " a
		[ "$a" = y ] || [ "$a" = Y ] || die "$EX_ENV" "aborted by operator"
	fi
}

# --- state ($RUN/state: key=value, one per line, last write wins) --------------
# keys may hold any character (vol./dev/sda2, tool.partclone.extfs): exact
# prefix matching, no regex
state_set() { mkdir -p "$RUN"; { awk -v k="$1=" 'index($0,k)!=1' "$RUN/state" 2>/dev/null; echo "$1=$2"; } > "$RUN/state.new" && mv -f "$RUN/state.new" "$RUN/state"; }
state_get() { awk -v k="$1=" 'index($0,k)==1 {print substr($0, length(k)+1)}' "$RUN/state" 2>/dev/null | tail -1; }
phase_done() { state_set "phase.$1" "done"; }
phase_is_done() { [ "$(state_get "phase.$1")" = "done" ]; }
vol_state_set() { state_set "vol.$1" "$2"; }     # pending|running|done|failed
vol_state_get() { state_get "vol.$1"; }

# --- locking ------------------------------------------------------------------
# One migrator per Live: a second instance mid-transfer would race on state.
lock() {
	mkdir -p "$RUN"
	exec {LOCKFD}>"$RUN/lock"
	flock -n "$LOCKFD" || die "$EX_ENV" "another migrator is running (lock $RUN/lock); use 'migrator -s attach'"
}
# unlock: before exec'ing something that must take the lock itself (tmux)
unlock() { [ -n "${LOCKFD:-}" ] && exec {LOCKFD}>&-; LOCKFD=; }

# --- cleanup ------------------------------------------------------------------
# cleanup_add 'shell snippet': registered snippets run LIFO on exit, whatever
# the exit reason. Libs register umounts, setro reverts, remote teardown.
cleanup_add() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
	local i
	for (( i=${#CLEANUP_CMDS[@]}-1; i>=0; i-- )); do
		log "cleanup: ${CLEANUP_CMDS[$i]}"
		bash -c "${CLEANUP_CMDS[$i]}" >/dev/null 2>&1 || true
	done
	CLEANUP_CMDS=()
}
trap run_cleanup EXIT

# --- environment --------------------------------------------------------------
live_release_file() {   # marker file of a full Live: ours first, upstream's kept for compatibility (D4)
	if   [ -r /etc/migrator-live-release ];  then echo /etc/migrator-live-release
	elif [ -r /etc/xserver-live-release ]; then echo /etc/xserver-live-release
	else echo; fi
}
require_full_live() {
	local rf; rf=$(live_release_file)
	[ -n "$rf" ] || die "$EX_ENV" "not a Live OS (no /etc/migrator-live-release)"
	if ! { have systemctl && have bash && have apt-get; }; then die "$EX_ENV" "this needs the full Live OS, not boot=base"; fi
}
live_build_id() { local rf; rf=$(live_release_file); [ -n "$rf" ] && sed -n 's/^BUILD_ID=//p' "$rf" 2>/dev/null; return 0; }
migrator_version() {
	local v=dev
	[ -r "$MIGRATOR_LIB/VERSION" ] && v=$(cat "$MIGRATOR_LIB/VERSION")
	echo "$v"
}

# --- formatting ---------------------------------------------------------------
# human BYTES -> 1.5G / 512M / 3T  (mawk-safe: no printf %'d, no gensub)
human() {
	awk -v b="$1" 'BEGIN{
		split("B K M G T P", u, " "); i=1;
		while (b >= 1024 && i < 6) { b /= 1024; i++ }
		if (i == 1) printf "%d%s\n", b, u[i]; else printf "%.1f%s\n", b, u[i] }'
}
# bytes "1G" / "512M" / "2T" / "4096" -> integer bytes (binary units)
bytes() {
	awk -v s="$1" 'BEGIN{
		n=s+0; u=toupper(substr(s, length(n"")+1));
		if (u=="K"||u=="KIB") n*=1024; else if (u=="M"||u=="MIB") n*=1024^2;
		else if (u=="G"||u=="GIB") n*=1024^3; else if (u=="T"||u=="TIB") n*=1024^4;
		printf "%.0f\n", n }'
}
