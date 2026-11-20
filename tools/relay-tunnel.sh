#!/bin/sh
# tools/relay-tunnel.sh — run ON THE DONOR, by the operator (E2). Forwards this
# donor's ssh (22) and data sshd (2222) onto a relay host the recipient can also
# reach, so a migration works when neither end can dial the other:
#
#   relay-tunnel.sh [-i KEYFILE] [-p RELAYSSHPORT] USER@RELAYHOST
#
# Forwards (fixed, MVP single-tenant relay):
#   RELAY:2222 -> donor:22    (control channel; the recipient passes root@RELAY:2222)
#   RELAY:2223 -> donor:2222  (data channel; the recipient passes -o sshd-port=2223)
# The relay's authorized_keys must carry the same public key as KEYFILE (the one
# the recipient later presents with -i). The tunnel retries every 5 s and logs
# to /run/migrator-relay.log; stop it with: kill $(cat /run/migrator-relay.pid)
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
KEY=; PORT=22
usage() { echo "usage: relay-tunnel.sh [-i KEYFILE] [-p RELAYSSHPORT] USER@RELAYHOST" >&2; exit 2; }
while getopts i:p: o; do
	case $o in
		i) KEY=$OPTARG ;;
		p) PORT=$OPTARG ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
SPEC=$1
case $SPEC in *@*) ;; *) usage ;; esac

[ -d /run ] || { echo "no /run (need a real system or the Live)" >&2; exit 2; }

# The recipient has to dial these ports on the relay from another machine, so the
# forwardings must bind the relay's wildcard address — and sshd only honours a
# bind address other than loopback when GatewayPorts is yes/clientspecified.  With
# the stock "no", ssh -R *succeeds* and listens on 127.0.0.1, which looks fine on
# the relay and is invisible from the recipient: the migration then hangs on the
# first ssh instead of failing.  Check it up front rather than debug that later.
RELAY_CFG=$(ssh ${KEY:+-i "$KEY"} -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
	-o ConnectTimeout=10 "$SPEC" 'sshd -T 2>/dev/null | grep -E "^(gatewayports|allowtcpforwarding) "' 2>/dev/null)
GP=$(printf '%s\n' "$RELAY_CFG" | awk '$1=="gatewayports"{print $2}')
ATF=$(printf '%s\n' "$RELAY_CFG" | awk '$1=="allowtcpforwarding"{print $2}')
case $GP in
	''|no)
		echo "relay $SPEC has GatewayPorts '${GP:-unknown}': -R would bind 127.0.0.1 and the recipient could never reach it." >&2
		echo "on the relay, once:" >&2
		echo "  printf 'GatewayPorts clientspecified\\n' > /etc/ssh/sshd_config.d/60-migrator-relay.conf && sshd -t && systemctl reload ssh" >&2
		echo "  (or set 'GatewayPorts clientspecified' in sshd_config if there is no sshd_config.d)" >&2
		exit 3
		;;
	clientspecified|yes) ;;
	*)	echo "relay $SPEC: unexpected GatewayPorts '$GP' (want clientspecified or yes)" >&2; exit 3 ;;
esac
# Some distributions ship sshd with forwarding switched off outright (Alpine's
# stock config does), and then -R is refused with "Server has disabled port
# forwarding" - the listener never appears and there is nothing to see on the
# relay. Same class of trap as GatewayPorts: check it before the run, not after.
if [ "$ATF" = no ]; then
	echo "relay $SPEC has AllowTcpForwarding no: sshd refuses every -R (no listener appears at all)." >&2
	echo "on the relay, once:" >&2
	echo "  sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config && sshd -t && systemctl reload ssh" >&2
	echo "  (Alpine: rc-service sshd restart)" >&2
	exit 3
fi

LOG=/run/migrator-relay.log; PID=/run/migrator-relay.pid
if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
	echo "a relay tunnel is already up (pid $(cat "$PID")); kill it first" >&2; exit 1
fi

(
	while :; do
		echo "$(date -Ins) tunnel (re)connecting" >> "$LOG"
		ssh -N -T \
			-o ExitOnForwardFailure=yes \
			-o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new -o BatchMode=yes \
			${KEY:+-i "$KEY"} -p "$PORT" \
			-R 0.0.0.0:2222:localhost:22 -R 0.0.0.0:2223:localhost:2222 \
			"$SPEC" >> "$LOG" 2>&1
		echo "$(date -Ins) tunnel dropped; retrying in 5s" >> "$LOG"
		sleep 5
	done
) &
echo $! > "$PID"
sleep 1
kill -0 "$(cat "$PID")" 2>/dev/null || { echo "the tunnel died immediately (see $LOG)" >&2; exit 1; }
echo "relay tunnel up: pid $(cat "$PID"); RELAY:2222 -> this donor :22, RELAY:2223 -> this donor :2222"
echo "on the recipient: migrator -y -i KEYFILE -o sshd-port=2223 root@RELAY:2222"
