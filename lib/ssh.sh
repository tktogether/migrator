#!/bin/bash
# lib/ssh.sh — the control channel to the donor, and the data channel it hands
# out to the transfer. Sourced by bin/migrator after common.sh; defines
# functions and defaults only, nothing runs at source time.
#
#   ssh_connect DONOR            master + auth chain + session key; DONOR = [user@]host[:port]
#   rsh CMD ARGS...              run a command on the donor through the master (args quoted)
#   rsh_sh 'pipeline'            run a shell pipeline on the donor under bash -o pipefail
#   rsh_fn FUNC[,HELPER...] ARGS run one of OUR bash functions on the donor (shipped via stdin)
#   rrun CMD... / rrun_sh '...'  same, for commands that CHANGE the donor: echoed, "(dry)" under -n
#   rpull REMOTE LOCAL           copy a file from the donor      rpush LOCAL REMOTE  copy one to it
#   ssh_require_full_live_donor  die unless the donor runs the full Live (bash, apt-get)
#   ssh_donor_mode               print online (the donor runs its own OS) or offline (a Live)
#   ssh_require_online_donor     die unless the donor's own OS can carry the agent (root, bash, findmnt)
#   ssh_guard_same_box           die when DONOR is this machine (nonce, DMI serial, boot MAC, expect=)
#   ssh_donor_serial             donor DMI product_serial, sanitised (may be empty)
#   ssh_start_data_sshd          image's sshd on the donor as the data channel (port 2222)
#   ssh_data_cmd                 print the ssh command prefix of ONE data connection
#   ssh_disconnect               close the master (registered in cleanup)
#   boot_nic_mac [local|donor]   MAC of the boot NIC   dmi_serial_of [local|donor]  DMI serial
#
# Globals set here: DONOR_USER DONOR_HOST DONOR_PORT (exported: cleanup snippets need
# them), SSH_DATA_PORT (2222), DONOR_RUN (/run/migrator on the donor), DONOR_AUTH_KEYS
# (the donor's authorized_keys; tests point it at a throwaway sshd's file).
# Read from the driver: RUN DRY YES SSH_KEYFILE OPT[data] OPT[cipher] OPT[expect].
# Exit codes: everything here refuses with EX_ENV (2): donor unreachable, no way to
# authenticate without a terminal, base Live, same machine, wrong donor.

: "${SSH_DATA_PORT:=2222}"
DONOR_USER=root
DONOR_HOST=
DONOR_PORT=22
# The donor's own state dir. Its RUN is always the default: only the recipient
# runs migrator with a possibly migrated RUN (tests).
# shellcheck disable=SC2034  # used by bootstrap.sh
DONOR_RUN=/run/migrator
: "${DONOR_AUTH_KEYS:=/root/.ssh/authorized_keys}"

# --- option sets ----------------------------------------------------------------
# Host keys are identical on every Live and known_hosts lives in tmpfs, so host
# key checking would only ever get in the way; keepalives are generous because
# a saturated link (transfer) must not look like a dead one to the master.
_ssh_setopts() {
	_SSH_BASE=(-o StrictHostKeyChecking=no -o "UserKnownHostsFile=$RUN/known_hosts" -o LogLevel=ERROR
	           -o ServerAliveInterval=15 -o ServerAliveCountMax=40 -o TCPKeepAlive=yes -o ConnectTimeout=20)
	_SSH_DEST=(-p "$DONOR_PORT" "$DONOR_USER@$DONOR_HOST")
}
_ssh_connected() { [ -n "$DONOR_HOST" ] || die "$EX_ENV" "not connected to a donor (ssh_connect first)"; }

# --- running things on the donor ----------------------------------------------
# rsh CMD ARGS...  Every argument is %q-quoted, so what runs on the donor is
# exactly the argv given here (the donor's login shell is bash). ControlMaster=auto
# plus the session key means a master that died mid-run is silently re-created
# without a prompt. A terminal on stdin is never meant for the remote command
# (-n); a pipe or file is passed through (rsh_fn, rpush, bash -s streams), so a
# caller inside a "while read" loop over stdin must add </dev/null itself.
rsh() {
	local -a key=() stdin=()
	_ssh_connected; _ssh_setopts
	[ -s "$RUN/id_ed25519" ] && key+=(-i "$RUN/id_ed25519")
	[ -n "${SSH_KEYFILE:-}" ] && key+=(-i "$SSH_KEYFILE")
	[ -t 0 ] && stdin=(-n)
	log "rsh: $*"
	ssh -S "$RUN/ssh.sock" -o ControlMaster=auto -o ControlPersist=yes -o BatchMode=yes "${stdin[@]}" \
		"${key[@]}" "${_SSH_BASE[@]}" "${_SSH_DEST[@]}" -- "$(printf '%q ' "$@")"
}
rsh_sh() { rsh bash -o pipefail -c "$1"; }
# rsh_fn FUNC[,HELPER,...] ARGS...  Ships the function bodies (declare -f) and a
# call through stdin to "bash -s": one implementation of boot_nic_mac & co. serves
# both sides, and nothing multi-line ever has to survive shell quoting.
rsh_fn() {
	local fns=${1//,/ } fn=${1%%,*}; shift
	log "rsh_fn: $fn $*"
	# shellcheck disable=SC2086  # fns is a deliberate word list
	{ declare -f $fns; printf '%q ' "$fn" "$@"; echo; } | rsh bash -s
}
# rrun / rrun_sh — like run()/run_sh() from common.sh but on the donor: echoed
# with "+ donor:" so the log stays a replayable runbook, and only printed under -n.
rrun() {
	local q; q=$(printf '%q ' "$@"); q=${q% }
	if [ -n "$DRY" ]; then echo "(dry) donor: $q"; log "(dry) donor: $q"; return 0; fi
	echo "+ donor: $q"; log "+ donor: $q"
	rsh "$@"
}
rrun_sh() {
	if [ -n "$DRY" ]; then echo "(dry) donor: $1"; log "(dry) donor: $1"; return 0; fi
	echo "+ donor: $1"; log "+ donor: $1"
	rsh_sh "$1"
}
# cat over the master instead of scp: one mechanism that works whatever sshd
# answers on :22 (openssh in the full Live, dropbear without sftp in base).
rpull() { rsh cat "$1" > "$2"; }
rpush() {
	if [ -n "$DRY" ]; then echo "(dry) donor: cat > $2  < $1"; log "(dry) donor: cat > $2 < $1"; return 0; fi
	log "rpush: $1 -> donor:$2"
	rsh_sh "cat > $(printf '%q' "$2")" < "$1"
}

# --- connecting ---------------------------------------------------------------------
# ssh_connect DONOR. Auth is whatever ssh finds first: a forwarded agent or the
# -i key work silently, otherwise ssh asks for the donor's root password — once,
# because right after the master is up a session key is generated and put into
# the donor's authorized_keys, and every later connection (rsh, data channel,
# a re-created master) is key-only BatchMode. Without a terminal there is nobody
# to type a password, so BatchMode is forced and a failure is explained.
ssh_connect() {
	local donor=$1 h
	[ -n "$donor" ] || die "$EX_ENV" "no DONOR given (want [user@]host[:port])"
	DONOR_USER=root; DONOR_PORT=22
	case $donor in *@*) DONOR_USER=${donor%%@*}; donor=${donor#*@};; esac
	case $donor in
		\[*\]:*) DONOR_PORT=${donor##*:}; h=${donor%:*}; DONOR_HOST=${h#[}; DONOR_HOST=${DONOR_HOST%]} ;;
		\[*\])   h=${donor#[}; DONOR_HOST=${h%]} ;;
		*:*:*)   DONOR_HOST=$donor ;;                         # bare IPv6 literal, default port
		*:*)     DONOR_PORT=${donor##*:}; DONOR_HOST=${donor%:*} ;;
		*)       DONOR_HOST=$donor ;;
	esac
	case $DONOR_PORT in ''|*[!0-9]*) die "$EX_ENV" "bad port in DONOR '$1'";; esac
	[ -n "$DONOR_HOST" ] || die "$EX_ENV" "bad DONOR '$1'"
	export DONOR_USER DONOR_HOST DONOR_PORT
	_ssh_setopts
	mkdir -p "$RUN"
	state_set donor.target "$DONOR_USER@$DONOR_HOST:$DONOR_PORT"   # later phases reconnect from this

	if ssh -S "$RUN/ssh.sock" -O check "${_SSH_DEST[@]}" >/dev/null 2>&1; then
		say "reusing the ssh master to $DONOR_USER@$DONOR_HOST:$DONOR_PORT"
	else
		rm -f "$RUN/ssh.sock"
		local -a auth=()
		[ -n "${SSH_KEYFILE:-}" ] && auth+=(-i "$SSH_KEYFILE")
		[ -s "$RUN/id_ed25519" ] && auth+=(-i "$RUN/id_ed25519")   # earlier run's session key: no prompt
		if [ -n "$YES" ] || ! is_tty; then auth+=(-o BatchMode=yes); fi
		say "connecting to $DONOR_USER@$DONOR_HOST:$DONOR_PORT (control master $RUN/ssh.sock)"
		if ! ssh -M -S "$RUN/ssh.sock" -o ControlPersist=yes -fN "${auth[@]}" "${_SSH_BASE[@]}" "${_SSH_DEST[@]}"; then
			if [ -n "$YES" ] || ! is_tty; then
				die "$EX_ENV" "cannot log in to $DONOR_USER@$DONOR_HOST:$DONOR_PORT without a terminal: pass -i KEYFILE or forward an agent (ssh -A) whose key the donor accepts"
			fi
			die "$EX_ENV" "cannot connect to $DONOR_USER@$DONOR_HOST:$DONOR_PORT"
		fi
	fi
	# cleanup runs snippets in a fresh "bash -c": the function must be exported
	# and depend only on exported variables (RUN, DONOR_*). Registered once,
	# however often the driver reconnects.
	if [ -z "${_SSH_CLEANUP_MASTER:-}" ]; then
		export -f ssh_disconnect
		cleanup_add ssh_disconnect
		_SSH_CLEANUP_MASTER=y
	fi

	if [ ! -s "$RUN/id_ed25519" ]; then
		rm -f "$RUN/id_ed25519.pub"
		ssh-keygen -t ed25519 -N '' -q -C "migrator-session@$(hostname)" -f "$RUN/id_ed25519" \
			|| die "$EX_ENV" "ssh-keygen failed for the session key $RUN/id_ed25519"
	fi
	chmod 600 "$RUN/id_ed25519"
	if _ssh_install_session_key "$(cat "$RUN/id_ed25519.pub")"; then
		_ssh_verify_key_login
		say "control channel up: master $RUN/ssh.sock, session key accepted by the donor"
	else
		say "control channel up: master $RUN/ssh.sock (dry run: session key not installed, key-only login not checked)"
	fi
}
# Idempotent append; returns 1 only under -n when the key is not there yet
# (nothing to verify then). The append goes through the master (authenticated
# by the operator), so this is the one and only step that depends on it.
_ssh_install_session_key() {
	local pub=$1 q f d
	if rsh grep -qxF "$pub" "$DONOR_AUTH_KEYS"; then
		log "session key already in the donor's authorized_keys"
		return 0
	fi
	if [ -n "$DRY" ]; then
		echo "(dry) donor: append the session public key to $DONOR_AUTH_KEYS"
		return 1
	fi
	q=$(printf '%q' "$pub"); f=$(printf '%q' "$DONOR_AUTH_KEYS"); d=$(printf '%q' "${DONOR_AUTH_KEYS%/*}")
	# sshd's StrictModes refuses a group/world-writable ~/.ssh: fix the modes too
	rsh_sh "umask 077; mkdir -p $d && echo $q >> $f && chmod 700 $d && chmod 600 $f" \
		|| die "$EX_ENV" "cannot add the session key to the donor's $DONOR_AUTH_KEYS"
}
_ssh_verify_key_login() {
	ssh -S none -o ControlMaster=no -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
		-i "$RUN/id_ed25519" "${_SSH_BASE[@]}" "${_SSH_DEST[@]}" -- true \
		|| die "$EX_ENV" "key-only login to $DONOR_USER@$DONOR_HOST:$DONOR_PORT with the session key failed after installing it"
}
ssh_disconnect() {
	[ -S "$RUN/ssh.sock" ] || return 0
	ssh -S "$RUN/ssh.sock" -O exit -o LogLevel=ERROR -o ConnectTimeout=10 -p "${DONOR_PORT:-22}" "${DONOR_USER:-root}@${DONOR_HOST:-donor}" >/dev/null 2>&1 || true
}

# --- who is on the other end -----------------------------------------------------
ssh_require_full_live_donor() {
	local rc id
	rsh sh -c 'test -r /etc/migrator-live-release || test -r /etc/xserver-live-release'; rc=$?
	[ $rc -ne 255 ] || die "$EX_ENV" "ssh command on $DONOR_HOST failed (master gone?)"
	[ $rc -eq 0 ] || die "$EX_ENV" "donor $DONOR_HOST is not a full Live OS (no /etc/migrator-live-release)"
	# the base Live is busybox only: no bash for rsh_fn, no apt-get for bootstrap
	rsh sh -c 'command -v bash >/dev/null && command -v apt-get >/dev/null' \
		|| die "$EX_ENV" "donor $DONOR_HOST runs the base Live (busybox only); boot it into the full Live"
	id=$(rsh sh -c 'sed -n "s/^BUILD_ID=//p" /etc/migrator-live-release 2>/dev/null; sed -n "s/^BUILD_ID=//p" /etc/xserver-live-release 2>/dev/null' | head -1)
	state_set donor.live "$id"
	say "donor Live build ${id:-?}, this box $(live_build_id)"
}

# on-line migration: the donor is not a Live at all but the running OS itself
ssh_donor_mode() {
	local rc
	rsh sh -c 'test -r /etc/migrator-live-release || test -r /etc/xserver-live-release'; rc=$?
	[ $rc -ne 255 ] || die "$EX_ENV" "ssh command on $DONOR_HOST failed (master gone?)"
	if [ $rc -eq 0 ]; then echo offline; else echo online; fi
}

# --- relay (E2, -o relay=USER@HOST[:SSHPORT]) ------------------------------------
# Both ends may sit behind NAT. The operator starts tools/relay-tunnel.sh on the
# DONOR (it forwards donor :22/:2222 onto the relay's :2222/:2223) and passes the
# relay as the donor argument ("migrator root@RELAY:2222 -o sshd-port=2223").
# This side forwards its own cutover port onto the relay's :2224 so the on-line
# poller (transfer.sh) reaches the recipient even though nobody can dial it.
relay_spec() {   # SPEC -> "user<TAB>host<TAB>port" of the relay; 2 = malformed
	local spec=$1 user= rest= host= port=
	rest=$spec
	case $spec in
		*@*) user=${spec%%@*}; rest=${spec#*@} ;;
		*)   user=root ;;
	esac
	host=$rest; port=22
	case $rest in
		*:*) port=${rest#*:}; host=${rest%:*} ;;
	esac
	case $port in ''|*[!0-9]*) return 2 ;; esac
	case $host in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
	[ -n "$user" ] || return 2
	printf '%s\n%s\n%s\n' "$user" "$host" "$port"
}
ssh_relay_start() {   # idempotent; needs -i KEYFILE — the relay must carry its pubkey
	local spec r_user r_host r_port key
	spec=$(opt relay)
	[ -n "$spec" ] || return 0
	[ -n "$DRY" ] && return 0
	relay_spec "$spec" || die "$EX_ENV" "bad -o relay=$spec (want USER@HOST[:SSHPORT])"
	[ -n "$(state_get relay.pid)" ] && kill -0 "$(state_get relay.pid)" 2>/dev/null && return 0
	key=${SSH_KEYFILE:-}
	[ -n "$key" ] || die "$EX_ENV" "-o relay needs -i KEYFILE: the relay must carry the same public key (this box forwards its cutover port through it)"
	{ read -r r_user; read -r r_host; read -r r_port; } < <(relay_spec "$spec")
	# Two sshd settings decide whether a reverse tunnel can exist at all, and
	# both fail silently from here: GatewayPorts no turns the -R into a
	# 127.0.0.1 listener nobody can reach, AllowTcpForwarding no refuses the
	# forward outright (Alpine ships that). Check them on the relay first.
	cfg=$(ssh -i "$key" -p "$r_port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=10 "$r_user@$r_host" \
		'sshd -T 2>/dev/null | grep -E "^(gatewayports|allowtcpforwarding) "' 2>/dev/null)
	case $(printf '%s\n' "$cfg" | awk '$1=="gatewayports"{print $2}') in
	clientspecified|yes) ;;
	*)	die "$EX_ENV" "relay $r_host would not publish the cutover port (GatewayPorts=$(printf '%s\n' "$cfg" | awk '$1=="gatewayports"{print $2}')): set 'GatewayPorts clientspecified' on the relay" ;;
	esac
	if [ "$(printf '%s\n' "$cfg" | awk '$1=="allowtcpforwarding"{print $2}')" = no ]; then
		die "$EX_ENV" "relay $r_host refuses port forwarding (AllowTcpForwarding no): set 'AllowTcpForwarding yes' on the relay"
	fi
	# The port must match what the cutover agent will listen on.  Under -o relay
	# transfer_online_run overrides cut_port with relay.cut_port (2224, below) and
	# hands that to the agent as --cutover RELAY:2224, so this box listens on 2224
	# too: forward the relay's 2224 onto 2224, NOT onto the direct-mode 2223.
	# Mapping it to 2223 leaves the poller dialling a port nothing listens on, and
	# the only symptom is a 180 s timeout after the donor is already frozen.
	nohup ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$key" -p "$r_port" \
		-R 0.0.0.0:2224:localhost:2224 "$r_user@$r_host" >"$RUN/relay.log" 2>&1 &
	echo $! > "$RUN/relay.pid"
	state_set relay.pid "$(cat "$RUN/relay.pid")"; state_set relay.host "$r_host"; state_set relay.cut_port 2224
	say "relay: cutover reverse tunnel up ($r_host :2224 -> this box :2224, pid $(cat "$RUN/relay.pid"))"
}

ssh_require_online_donor() {
	local facts
	# shellcheck disable=SC2016  # the $(...) expand on the donor, not here
	facts=$(rsh sh -c 'echo "uid=$(id -u) bash=$(command -v bash || echo -) findmnt=$(command -v findmnt || echo -) os=$(sed -n "s/^PRETTY_NAME=//p" /etc/os-release 2>/dev/null | tr -d "\"" | tr " " _) kernel=$(uname -r) arch=$(uname -m)"') \
		|| die "$EX_ENV" "cannot look at the donor $DONOR_HOST (ssh failed)"
	case $facts in *"uid=0 "*) ;; *) die "$EX_ENV" "online migration needs root on the donor ($facts)";; esac
	case $facts in *"bash=- "*) die "$EX_ENV" "the donor has no bash: the inventory needs it";; esac
	case $facts in *"findmnt=- "*) die "$EX_ENV" "the donor has no findmnt (util-linux): the agent needs it";; esac
	case $facts in *"arch=x86_64"*) ;; *) die "$EX_ENV" "online migration: the agent is built for x86_64, the donor is ${facts##*arch=}";; esac
	state_set donor.os "$(echo "$facts" | sed -n 's/.*os=\([^ ]*\).*/\1/p')"
	state_set donor.kernel "$(echo "$facts" | sed -n 's/.*kernel=\([^ ]*\).*/\1/p')"
	say "donor runs its own OS: $(state_get donor.os | tr _ ' ') ($(state_get donor.kernel)) - on-line migration"
}

# Self-contained on purpose (shipped to the donor with rsh_fn): only the "donor"
# branch uses anything from this file, and that branch never runs remotely.
# BOOTIF=01-<mac-with-dashes> is what pxelinux/iPXE hands the kernel; a Live
# booted some other way leaves only /run/net-<iface>.conf from the initramfs.
boot_nic_mac() {
	local side=${1:-local} w mac='' dev words
	if [ "$side" = donor ]; then rsh_fn boot_nic_mac local; return; fi
	read -ra words < /proc/cmdline 2>/dev/null
	for w in "${words[@]}"; do
		case $w in BOOTIF=*) mac=${w#BOOTIF=}; mac=${mac#01-}; mac=${mac//-/:};; esac
	done
	if [ -z "$mac" ]; then
		# klibc ipconfig writes DEVICE='eth0' (quoted); the static path writes it bare
		dev=$(sed -n "s/^DEVICE='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" /run/net-*.conf 2>/dev/null | head -1)
		# a running OS (on-line donor): the NIC of the default route
		[ -n "$dev" ] || dev=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
		[ -n "$dev" ] && mac=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
	fi
	echo "$mac" | tr '[:upper:]' '[:lower:]'
}
dmi_serial_of() {
	local side=${1:-local}
	if [ "$side" = donor ]; then rsh_fn dmi_serial_of local; return; fi
	tr -cd 'A-Za-z0-9-' < /sys/class/dmi/id/product_serial 2>/dev/null | head -c 64
	echo
}
ssh_donor_serial() { dmi_serial_of donor; }

# The nonce is the only proof that cannot lie: a hostname or an IP can point back
# at this box through a NAT or a typo, /etc/machine-id is the same on every Live
# (baked into the squashfs), but a random token written here a second ago can
# only be read back through the donor if the donor IS this filesystem.
ssh_guard_same_box() {
	local nonce theirs lser lmac dser dmac exp es em
	nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	mkdir -p "$RUN"; echo "$nonce" > "$RUN/nonce"
	theirs=$(rsh cat "$RUN/nonce" 2>/dev/null)
	[ "$theirs" != "$nonce" ] || die "$EX_ENV" "DONOR $DONOR_HOST is this machine (it reads back our $RUN/nonce)"
	lser=$(dmi_serial_of local); lmac=$(boot_nic_mac local)
	dser=$(dmi_serial_of donor); dmac=$(boot_nic_mac donor)
	state_set donor.serial "$dser"; state_set donor.boot_mac "$dmac"
	state_set recipient.serial "$lser"; state_set recipient.boot_mac "$lmac"
	say "identity: donor serial=${dser:-?} boot-mac=${dmac:-?} | recipient serial=${lser:-?} boot-mac=${lmac:-?}"
	# serial OR boot MAC must differ; two empty serials are equal, so on VMs
	# without -smbios serial= the boot MAC alone decides (the nonce already ran)
	[ "$lser" != "$dser" ] || [ "$lmac" != "$dmac" ] \
		|| die "$EX_ENV" "donor and recipient report the same DMI serial and boot MAC: DONOR is this machine"
	exp=$(opt expect)
	if [ -n "$exp" ]; then
		es=$(echo "$exp" | tr -cd 'A-Za-z0-9-')
		em=$(echo "$exp" | tr '[:upper:]-' '[:lower:]:')
		[ "$es" = "$dser" ] || [ "$em" = "$dmac" ] \
			|| die "$EX_ENV" "donor $DONOR_HOST (serial ${dser:-none}, boot MAC ${dmac:-none}) is not the expected $exp"
		say "donor matches expect=$exp"
	fi
}

# --- data channel -----------------------------------------------------------------
# Why a second sshd on 2222: every volume gets its own connection with a pinned
# fast cipher (aes128-gcm, AES-NI) and key-only auth, independent of whatever
# serves :22 (openssh in the full Live; dropbear, single-threaded, in base).
# Why not the master: every volume gets its own connection, so a master that dies
# cannot kill a three-hour copy. Password auth is off: only the session key gets in.
ssh_start_data_sshd() {
	local port alive kill_cmd
	port=$(opt sshd-port "$SSH_DATA_PORT"); SSH_DATA_PORT=$port
	_ssh_connected
	if [ "$(opt data ssh)" = raw ]; then
		say "data=raw: not starting sshd:$port on the donor (busybox nc carries the data)"
		return 0
	fi
	# shellcheck disable=SC2016  # $p expands on the donor, not here
	alive='p=$(cat /run/migrator-sshd.pid 2>/dev/null) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = sshd ]'
	if rsh_sh "$alive"; then
		say "data channel sshd:$port is already running on the donor"
	elif [ -n "$DRY" ]; then
		# rrun_sh under -n: the "(dry) donor:" line goes to the log as well, not only to the screen
		rrun_sh "/usr/sbin/sshd -p $port -o PermitRootLogin=yes -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o AuthorizedKeysFile=$DONOR_AUTH_KEYS -o PidFile=/run/migrator-sshd.pid"
		return 0
	else
		rrun_sh 'rm -f /run/migrator-sshd.pid; [ -s /etc/ssh/ssh_host_rsa_key ] && [ -s /etc/ssh/ssh_host_ecdsa_key ] && [ -s /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A' \
			|| die "$EX_ENV" "cannot prepare host keys on the donor"
		# /run/sshd is sshd's privilege separation dir; normally made by tmpfiles at boot
		# no ListenAddress: sshd then listens on both address families
		rrun_sh "mkdir -p /run/sshd && /usr/sbin/sshd -p $port -o PermitRootLogin=yes -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o AuthorizedKeysFile=$DONOR_AUTH_KEYS -o PidFile=/run/migrator-sshd.pid" \
			|| die "$EX_ENV" "cannot start sshd:$port on the donor"
		# sshd daemonises before it binds, so its exit status says nothing about
		# the port; the pidfile is written only once the listen sockets are up
		local up=
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			rsh test -s /run/migrator-sshd.pid && { up=y; break; }; sleep 1
		done
		[ -n "$up" ] || die "$EX_ENV" "sshd:$port did not come up on the donor (port busy? on the donor: kill \$(cat /run/migrator-sshd.pid), or -o sshd-port=N)"
	fi
	# only the pid WE recorded is ever killed, never "sshd" by name (the :22 server, the
	# operator's own sessions); the snippet is self-contained because cleanup
	# runs it in a fresh bash: it goes through the master, or straight in with the
	# session key when the master is gone.
	# shellcheck disable=SC2016  # $p expands on the donor, not here
	kill_cmd='p=$(cat /run/migrator-sshd.pid 2>/dev/null); [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = sshd ] && kill "$p"; rm -f /run/migrator-sshd.pid'
	if [ -z "${_SSH_CLEANUP_DATA:-}" ]; then
		cleanup_add "ssh -S $(printf '%q' "$RUN/ssh.sock") -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=$(printf '%q' "$RUN/known_hosts") -o LogLevel=ERROR -i $(printf '%q' "$RUN/id_ed25519") -p $DONOR_PORT $DONOR_USER@$DONOR_HOST -- $(printf '%q' "sh -c $(printf '%q' "$kill_cmd")")"
		_SSH_CLEANUP_DATA=y
	fi
	$(ssh_data_cmd) -o ConnectTimeout=20 -- true \
		|| die "$EX_ENV" "key-only login to the data channel root@$DONOR_HOST:$port failed"
	say "data channel: sshd:$port on $DONOR_HOST, cipher $(opt cipher aes128-gcm@openssh.com)"
}
# aes128-gcm@openssh.com: AES-NI on both ends, one AEAD pass; chacha20 is the
# fallback for CPUs without AES-NI (-o cipher=chacha20-poly1305@openssh.com).
ssh_data_cmd() {
	local cipher; cipher=$(opt cipher aes128-gcm@openssh.com)
	# on-line: no second sshd on somebody's production box - the donor's own :22 answers,
	# and the session key opens as many connections as we need. Each one is DIRECT
	# (ControlPath=none): a bulk stream multiplexed on the control master dies with it,
	# and the master gives up after ServerAliveInterval x CountMax of unanswered
	# keepalives - 600 s, which is exactly where the first Rocky transfer broke
	# ("the stream ended inside a data frame" at 620 s, pass 1 not even finished).
	if [ "${MIGRATOR_MODE:-$(state_get mode)}" = online ]; then
		echo "ssh -p $DONOR_PORT -c $cipher -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=$RUN/known_hosts -o LogLevel=ERROR -o IdentitiesOnly=yes -i $RUN/id_ed25519 -o ServerAliveInterval=15 -o ServerAliveCountMax=40 $DONOR_USER@$DONOR_HOST"
		return 0
	fi
	echo "ssh -p $SSH_DATA_PORT -c $cipher -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=$RUN/known_hosts -o LogLevel=ERROR -o IdentitiesOnly=yes -i $RUN/id_ed25519 -o ServerAliveInterval=15 -o ServerAliveCountMax=40 root@$DONOR_HOST"
}
