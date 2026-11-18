#!/bin/bash
# rig/build-live.sh — build the migrator rescue Live ISO (D4/D7).
# Runs on a Debian/Ubuntu build host (the test container). Produces:
#   $HOME/rig/migrator-live.iso   bootable ISO (BIOS/UEFI hybrid)
#   $HOME/rig/rig_ed25519(.pub)   rig ssh keypair (generated once, reused)
# The repo tree stays clean: everything build-local goes under $HOME/rig/build.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${RIG_OUT:-$HOME/rig}
mkdir -p "$OUT"
BUILD=$OUT/build
rm -rf "$BUILD"; mkdir -p "$BUILD"

# rig ssh keypair: generated once, injected into the Live (pubkey -> /root/.ssh)
KEY=$OUT/rig_ed25519
if [ ! -f "$KEY" ]; then
	ssh-keygen -q -t ed25519 -N '' -C migrator-rig -f "$KEY"
fi
install -d -m0700 "$BUILD/config/includes.chroot/root/.ssh"
install -m0600 "$KEY.pub" "$BUILD/config/includes.chroot/root/.ssh/authorized_keys"

# marker file (D4/D5): BUILD_ID for live_build_id, CODENAME/MIRROR for bootstrap
SHORT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)
install -d "$BUILD/config/includes.chroot/etc"
cat > "$BUILD/config/includes.chroot/etc/reloca-live-release" <<EOF
BUILD_ID=migrator-$SHORT-$(date +%Y%m%d)
CODENAME=bookworm
MIRROR=http://deb.debian.org/debian
EOF

# the tool itself, installed exactly like tools/install.sh does (D7)
install -d -m0755 "$BUILD/config/includes.chroot/usr/local/sbin"
install -d -m0755 "$BUILD/config/includes.chroot/usr/local/lib/reloca.to"
install -m0755 "$REPO/bin/reloca.to" "$BUILD/config/includes.chroot/usr/local/sbin/reloca.to"
if [ -x "$REPO/agent/reloca-agent" ]; then
	install -m0755 "$REPO/agent/reloca-agent" "$BUILD/config/includes.chroot/usr/local/sbin/reloca-agent"
else
	echo "WARN: bin/reloca-agent missing (make agent first); on-line mode will lack the agent" >&2
fi
install -m0644 "$REPO"/lib/*.sh "$BUILD/config/includes.chroot/usr/local/lib/reloca.to/"
[ -f "$REPO/lib/VERSION" ] && install -m0644 "$REPO/lib/VERSION" "$BUILD/config/includes.chroot/usr/local/lib/reloca.to/" || true

# live-build (Debian bookworm)
cd "$BUILD"
lb config noauto \
	--distribution bookworm \
	--archive-areas "main contrib non-free non-free-firmware" \
	--mode debian \
	--binary-images iso-hybrid \
	--bootappend-live "boot=live components" \
	--debian-installer none \
	--iso-volume migrator-live \
	--iso-application migrator-rescue \
	--iso-publisher "migrator; https://example.invalid; migrator" \
	"$@" 2>&1 | tail -5
lb build 2>&1 | tail -20

ISO=$BUILD/live-image-amd64.hybrid.iso
[ -s "$ISO" ] || { echo "FAIL: no ISO produced (see $BUILD/log)" >&2; exit 1; }
cp -f "$ISO" "$OUT/migrator-live.iso"
echo "OK: $OUT/migrator-live.iso ($(du -h "$OUT/migrator-live.iso" | cut -f1))"
