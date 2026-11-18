#!/bin/bash
# tests/cases/relay.sh — E2: the -o relay surface, the spec parser and the
# cutover-port override wiring (pure functions; no network).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
M=$REPO/bin/reloca.to

# the parser (lib/ssh.sh is functions-only; common.sh carries the registry)
. "$REPO/lib/common.sh"
. "$REPO/lib/ssh.sh"

out=$(relay_spec 'root@relay.example.com'); rc=$?
assert_eq "plain host parses"            0 "$rc"
assert_eq "plain host user"     "root"   "$(printf '%s' "$out" | sed -n 1p)"
assert_eq "plain host name"     "relay.example.com" "$(printf '%s' "$out" | sed -n 2p)"
assert_eq "plain host port"     "22"     "$(printf '%s' "$out" | sed -n 3p)"

out=$(relay_spec 'admin@relay.example.com:2222'); rc=$?
assert_eq "user+port parses"              0 "$rc"
assert_eq "user+port user"      "admin"   "$(printf '%s' "$out" | sed -n 1p)"
assert_eq "user+port host"      "relay.example.com" "$(printf '%s' "$out" | sed -n 2p)"
assert_eq "user+port port"      "2222"    "$(printf '%s' "$out" | sed -n 3p)"

out=$(relay_spec 'relay.example.com'); rc=$?
assert_eq "bare host defaults to root"    0 "$rc"

relay_spec 'relay.example.com:x' >/dev/null 2>&1; rc=$?
assert_eq "non-numeric port refused"      2 "$rc"
relay_spec '@relay.example.com' >/dev/null 2>&1; rc=$?
assert_eq "empty user refused"            2 "$rc"
relay_spec 'u@re!lay' >/dev/null 2>&1; rc=$?
assert_eq "bad host characters refused"   2 "$rc"

# the driver accepts -o relay=... and documents it
out=$(bash "$M" -o relay=root@relay.example.com -V 2>&1); rc=$?
assert_eq "-o relay= is accepted"         0 "$rc"
usage=$(bash "$M" -h 2>&1)
case "$usage" in *"relay="*) _pass "the usage header documents relay=" ;; *) _fail "the usage header documents relay=" "missing" ;; esac

# ssh_relay_start refuses a relay without -i, before spawning anything
RUN=$RUN; SSH_KEYFILE=
declare -A OPT=( [relay]='root@relay.example.com' )
export RUN
out=$(ssh_relay_start 2>&1); rc=$?
assert_eq "relay without -i exits 2"      2 "$rc"
assert_has "it says the relay needs -i"   "-o relay needs -i KEYFILE" "$out"
assert_fail "no pidfile was written"      test -e "$RUN/relay.pid"

t_end
