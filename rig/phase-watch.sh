#!/bin/bash
# rig/phase-watch.sh — runs on the build host; records the in-VM migration's
# current phase + last log line + rc into /root/rig/phase.txt every 45 s.
KEY=/root/rig/rig_ed25519
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -i $KEY"
while :; do
	P=$(ssh $SSHOPTS -p 2255 root@127.0.0.1 \
		"grep -aE '=== ' /root/reloca-run.log 2>/dev/null | tail -1 | cut -c1-60; tail -1 /root/reloca-run.log 2>/dev/null | cut -c1-100; rc=\$(cat /root/reloca.rc 2>/dev/null); echo RC=\$rc" 2>/dev/null | tr '\n' ' ')
	echo "$(date +%H:%M:%S) $P" > /root/rig/phase.txt
	sleep 45
done
