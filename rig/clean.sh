#!/bin/bash
# rig/clean.sh — stop every rig artefact: runner instances, qemu VMs, in-VM tmux.
# Lives on the container; safe to call from any ssh session (patterns live in the
# file, never in the caller's command line).
P1=run-offline; P2=verify-target
pkill -f "rig/$P1.sh" 2>/dev/null
pkill -f "rig/$P2.sh" 2>/dev/null
sleep 1
KEY=/root/rig/rig_ed25519
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=8 -i $KEY"
for port in 2255 2233 2266; do
	timeout 15 ssh $SSHOPTS -p $port root@127.0.0.1 "tmux kill-server 2>/dev/null; pkill -f 'migrator[.]to'; pkill -f 'relay-tunnel[.]sh'; true" >/dev/null 2>&1
done
for p in donor recipient target; do
	[ -f /root/rig/$p.pid ] && kill "$(cat /root/rig/$p.pid)" 2>/dev/null && rm -f /root/rig/$p.pid
done
pkill -9 qemu-system 2>/dev/null
sleep 1
pgrep qemu-system >/dev/null && echo "WARN: qemu still alive" || echo "clean: no runner, no qemu"
