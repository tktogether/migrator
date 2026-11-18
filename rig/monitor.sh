#!/bin/bash
# rig/monitor.sh — detached watchdog on the build host: polls the in-VM rc file,
# records the outcome + tail of the migration log to /root/rig/e2e-status.txt, and
# leaves the VMs untouched either way. Survives ssh session drops (run detached).
KEY=/root/rig/rig_ed25519
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -i $KEY"
STATUS=/root/rig/e2e-status.txt
: > "$STATUS"
while :; do
	R=$(ssh $SSHOPTS -p 2255 root@127.0.0.1 "cat /root/reloca.rc 2>/dev/null" 2>/dev/null)
	if [ -n "$R" ]; then
		{
			echo "$(date -Ins) reloca.rc=$R"
			ssh $SSHOPTS -p 2255 root@127.0.0.1 "grep -aE '===|ERROR|verified|summary' /root/reloca-run.log; tail -5 /root/reloca-run.log" 2>&1
		} >> "$STATUS"
		break
	fi
	sleep 60
done
