#!/bin/bash
# tests/cases/transfer.sh — lib/transfer.sh: the driver's contract, the exact
# pipeline strings (pure builders), the partclone progress parser on a recorded
# sample, swapfile excludes, the count/size comparison of two trees, a dry run
# over a fake plan, the refusals, the watchdog on a pipeline that never moves,
# and — when this host is root with partclone, lz4 and sshd — an end-to-end
# loopback: a throwaway sshd on 127.0.0.1:2398 plays the donor's data channel,
# an ext4 image made with mkfs.ext4 -d is streamed through the real
# "ssh | lz4 -d | partclone.extfs -r" chain into a second image (no loop
# devices, no block devices). Missing dev tools SKIP, never fail.
# shellcheck disable=SC2016  # the single-quoted snippets expand inside lib_sh's own bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
LIB=$REPO/lib/transfer.sh; export LIB
CONTRACT="transfer_run transfer_probe transfer_block transfer_files tx_remote_block_cmd tx_local_block_cmd tx_remote_files_cmd tx_local_files_cmd tx_progress_parse tx_verify_files tx_swap_excludes tx_vol_state"; export CONTRACT
FIX=$REPO/tests/fixtures/raw

[ -r "$LIB" ] || { skip "lib/transfer.sh" "not written yet"; t_end; }

# lib_sh 'snippet': a fresh bash with the libs the driver sources before
# transfer.sh (common, ssh, plan), then the snippet — nothing of this case around
lib_sh() { bash -c '. "$REPO/lib/common.sh"; . "$REPO/lib/ssh.sh"; . "$REPO/lib/plan.sh"; . "$LIB"; eval "$1"' _ "$1"; }
lib_missing() { bash -c '. "$REPO/lib/common.sh"; . "$REPO/lib/ssh.sh"; . "$REPO/lib/plan.sh"; . "$LIB"; for f in $CONTRACT; do declare -F "$f" >/dev/null || printf "%s " "$f"; done' _; }

# --- (a) contract -------------------------------------------------------------------
lib_sh 'true' > "$RUN/src.out" 2>&1; rc=$?
assert_eq "transfer.sh sources cleanly"     0  "$rc"
assert_eq "transfer.sh is silent on source" "" "$(cat "$RUN/src.out")"
lib_missing > "$RUN/missing" 2>/dev/null
assert_eq "transfer.sh defines the driver's contract functions" "" "$(sed 's/ $//' "$RUN/missing")"

# --- (b) pure builders: the exact strings that go over the wire ---------------------
S='echo ${PIPESTATUS[0]} > /run/reloca-src.status'
assert_eq "block ext4 lz4 (clean)" \
	"bash -o pipefail -c 'partclone.extfs -c -s /dev/sda2 -o - -q -a1 -L /run/reloca-src.log | lz4 -c; $S'" \
	"$(lib_sh 'tx_remote_block_cmd ext4 /dev/sda2 "" lz4')"
assert_eq "block ext4 lz4 (dirty: -I)" \
	"bash -o pipefail -c 'partclone.extfs -c -s /dev/sda2 -o - -q -a1 -I -L /run/reloca-src.log | lz4 -c; $S'" \
	"$(lib_sh 'tx_remote_block_cmd ext4 /dev/sda2 -I lz4')"
assert_eq "block xfs zstd" \
	"bash -o pipefail -c 'partclone.xfs -c -s /dev/centos/root -o - -q -a1 -L /run/reloca-src.log | zstd -T0 --fast=3 -q -c; $S'" \
	"$(lib_sh 'tx_remote_block_cmd xfs /dev/centos/root "" zstd')"
assert_eq "block ext3 none" \
	"bash -o pipefail -c 'partclone.extfs -c -s /dev/md0 -o - -q -a1 -L /run/reloca-src.log | cat; $S'" \
	"$(lib_sh 'tx_remote_block_cmd ext3 /dev/md0 "" none')"
assert_eq "block raw sink appended" \
	"bash -o pipefail -c 'partclone.extfs -c -s /dev/md0 -o - -q -a1 -L /run/reloca-src.log | lz4 -c | busybox nc 192.168.77.2 31234; $S'" \
	"$(lib_sh 'tx_remote_block_cmd ext4 /dev/md0 "" lz4 "busybox nc 192.168.77.2 31234"')"
assert_eq "local block ext4 lz4" \
	"lz4 -d -c | partclone.extfs -r -s - -o /dev/sda3 -L /run/reloca.to/vol-3.log -f 10 -B" \
	"$(lib_sh 'tx_local_block_cmd ext4 /dev/sda3 lz4 /run/reloca.to/vol-3.log')"
assert_eq "local block: -f follows the poll interval" \
	"lz4 -d -c | partclone.extfs -r -s - -o /dev/sda3 -L /tmp/l -f 2 -B" \
	"$(RELOCA_POLL_S=2 lib_sh 'tx_local_block_cmd ext4 /dev/sda3 lz4 /tmp/l')"
assert_eq "local block xfs zstd" \
	"zstd -d -q -c | partclone.xfs -r -s - -o /dev/rl/root -L /run/reloca.to/vol-rl-root.log -f 10 -B" \
	"$(lib_sh 'tx_local_block_cmd xfs /dev/rl/root zstd /run/reloca.to/vol-rl-root.log')"
assert_eq "local block none" \
	"cat | partclone.extfs -r -s - -o /dev/sda1 -L /run/reloca.to/vol-1.log -f 10 -B" \
	"$(lib_sh 'tx_local_block_cmd ext2 /dev/sda1 none /run/reloca.to/vol-1.log')"
touch "$RUN/img"
assert_eq "local block onto a regular file uses -O (overwrite)" \
	"lz4 -d -c | partclone.extfs -r -s - -O $RUN/img -L /tmp/l -f 10 -B" \
	"$(lib_sh "tx_local_block_cmd ext4 $RUN/img lz4 /tmp/l")"
assert_eq "files ext4 lz4 with two excludes" \
	"bash -o pipefail -c 'cd /mnt/reloca.to/src/3 && tar --one-file-system --numeric-owner --xattrs --xattrs-include=\\* --sparse --exclude=./swapfile --exclude=./var/swap -cf - . | lz4 -c; $S'" \
	"$(lib_sh 'tx_remote_files_cmd /mnt/reloca.to/src/3 lz4 "--exclude=./swapfile --exclude=./var/swap"')"
assert_eq "files zstd no excludes" \
	"bash -o pipefail -c 'cd /mnt/reloca.to/src/centos-root && tar --one-file-system --numeric-owner --xattrs --xattrs-include=\\* --sparse -cf - . | zstd -T0 --fast=3 -q -c; $S'" \
	"$(lib_sh 'tx_remote_files_cmd /mnt/reloca.to/src/centos-root zstd ""')"
assert_eq "esp vfat none: no xattrs" \
	"bash -o pipefail -c 'cd /mnt/reloca.to/src/1 && tar --one-file-system --numeric-owner --sparse -cf - . | cat; $S'" \
	"$(lib_sh 'tx_remote_files_cmd /mnt/reloca.to/src/1 none "" vfat')"
assert_eq "files raw sink appended" \
	"bash -o pipefail -c 'cd /mnt/reloca.to/src/3 && tar --one-file-system --numeric-owner --xattrs --xattrs-include=\\* --sparse -cf - . | lz4 -c | busybox nc 10.0.0.2 30001; $S'" \
	"$(lib_sh 'tx_remote_files_cmd /mnt/reloca.to/src/3 lz4 "" "" "busybox nc 10.0.0.2 30001"')"
assert_eq "local files lz4" \
	"lz4 -d -c | tar -C /mnt/reloca.to/dst/3 --numeric-owner --xattrs --xattrs-include=\\* -xpf -" \
	"$(lib_sh 'tx_local_files_cmd /mnt/reloca.to/dst/3 lz4')"
assert_eq "local files zstd" \
	"zstd -d -q -c | tar -C /mnt/reloca.to/dst/3 --numeric-owner --xattrs --xattrs-include=\\* -xpf -" \
	"$(lib_sh 'tx_local_files_cmd /mnt/reloca.to/dst/3 zstd')"
assert_eq "local esp vfat: no -p, no owner, no xattrs" \
	"cat | tar -C /mnt/reloca.to/dst/1 --numeric-owner --no-same-owner --no-same-permissions -xf -" \
	"$(lib_sh 'tx_local_files_cmd /mnt/reloca.to/dst/1 none vfat')"
assert_fail "block btrfs is refused by the builder" lib_sh 'tx_remote_block_cmd btrfs /dev/x "" lz4'
assert_eq "compress=gzip builds a gzip pipeline (the fallback every base system has)" \
	"bash -o pipefail -c 'partclone.extfs -c -s /dev/x -o - -q -a1 -L /run/reloca-src.log | gzip -1 -c; echo \${PIPESTATUS[0]} > /run/reloca-src.status'" \
	"$(lib_sh 'tx_remote_block_cmd ext4 /dev/x "" gzip')"
assert_eq "decompress=gzip" "gzip -d -c" "$(lib_sh 'tx_decomp gzip')"
assert_fail "compress=bzip2 is refused by the builder" lib_sh 'tx_remote_block_cmd ext4 /dev/x "" bzip2'
assert_fail "local builder refuses vfat block" lib_sh 'tx_local_block_cmd vfat /dev/x lz4 /tmp/l'
# the remote string survives ssh's "join argv with spaces, hand it to bash":
# evaluating it locally through the same route yields the same argv
out=$(lib_sh 'r=$(tx_remote_block_cmd ext4 /dev/sda2 "" none); bash -c "echo $(printf %q "$r")"')
assert_eq "remote string survives %q quoting as one argument" "$(lib_sh 'tx_remote_block_cmd ext4 /dev/sda2 "" none')" "$out"

# --- (c) progress parser on a recorded partclone.extfs -r stderr ------------------
assert_eq "parser: newest fragment of the recorded restore" "100.00 919.59MB/min 00:00:00" "$(lib_sh "tx_progress_parse $FIX/partclone-restore.err")"
tr '\r' '\n' < "$FIX/partclone-restore.err" | grep 'Completed:' | sed -n 4p | tr '\n' '\r' > "$RUN/midway"
assert_eq "parser: a mid-run fragment (rate without the Rate: prefix)" "32.16 985.66MB/min 00:00:06" "$(lib_sh "tx_progress_parse $RUN/midway")"
head -c 300 "$FIX/partclone-restore.err" > "$RUN/header"
assert_fail "parser: header only, nothing yet" lib_sh "tx_progress_parse $RUN/header"
assert_fail "parser: missing file" lib_sh "tx_progress_parse $RUN/nonexistent"
printf 'Elapsed: 00:00:01, Remaining: 00:01:39, Completed:   1.00%%,   0.00byte/min,' > "$RUN/first"
assert_eq "parser: the very first fragment" "1.00 0.00byte/min 00:01:39" "$(lib_sh "tx_progress_parse $RUN/first")"
assert_eq "block progress: pct of the total" "32.16 985.66MB/min 00:00:06 34518" "$(lib_sh "tx_block_progress $RUN/midway 107333")"
assert_eq "log bytes: Space in use x block size" "18166784" "$(printf 'Space in use:  18.2 MB = 17741 Blocks\nBlock size:   1024 Byte\n' > "$RUN/pl.log"; lib_sh "tx_log_bytes $RUN/pl.log")"
assert_eq "vol id: partition number" 3 "$(lib_sh 'tx_vol_id "$(printf "src=/dev/sda2\tnum=3")"')"
assert_eq "vol id: LV without a number" centos-root "$(lib_sh 'tx_vol_id "$(printf "src=/dev/centos/root\tnum=-")"')"
assert_eq "fmt_time" "5s|12m 34s|2h 05m" "$(lib_sh 'echo "$(tx_fmt_time 5)|$(tx_fmt_time 754)|$(tx_fmt_time 7500)"')"

# --- (d) swapfile excludes: longest mount prefix wins ------------------------------
mkdir -p "$RUN/sw"
printf 'host\trole=donor\nswapfile\tpath=/swapfile\tsize=1073741824\topts=\nswapfile\tpath=/var/swap\tsize=536870912\topts=\nswapfile\tpath=/srv/x/swap\tsize=100\topts=\n' > "$RUN/sw/donor.inv"
printf '[target]\ndata=ssh compress=lz4\n[volumes]\nsrc=/dev/sda1\tfs=ext4\tmethod=files\tmount=/\tnum=1\nsrc=/dev/sda2\tfs=ext4\tmethod=files\tmount=/var\tnum=2\nsrc=/dev/sda3\tfs=swap\tmethod=mkswap\tmount=swap\tnum=3\n' > "$RUN/sw/plan"
assert_eq "excludes for /"    "swapfile 1073741824|srv/x/swap 100" "$(RUN=$RUN/sw lib_sh 'tx_swap_excludes /' | tr '\n' '|' | sed 's/|$//')"
assert_eq "excludes for /var" "swap 536870912" "$(RUN=$RUN/sw lib_sh 'tx_swap_excludes /var')"
assert_eq "excludes without an inventory: none" "" "$(RUN=$RUN/nowhere lib_sh 'tx_swap_excludes /')"

# --- (e) tx_verify_files on two local trees (the donor side runs locally) ---------
mkdir -p "$RUN/vf/a/d1/d2" "$RUN/vf/b"
for i in 1 2 3 4 5 6 7 8 9 10; do echo "file $i" > "$RUN/vf/a/f$i"; done
dd if=/dev/urandom of="$RUN/vf/a/d1/d2/big" bs=1k count=300 status=none
cp -a "$RUN/vf/a/." "$RUN/vf/b/"
V='TX_SRC_RUN="bash -o pipefail -c"'
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b" 2>&1); rc=$?
assert_eq  "identical trees: ok"                 0 "$rc"
assert_has "identical trees: counts reported"    "entries: donor 14, here 14 (ok" "$out"
assert_has "identical trees: sizes reported"     "apparent size: donor" "$out"
case "$out" in *WARN*) _fail "identical trees: no WARN" "$out";; *) _pass "identical trees: no WARN";; esac
rm -f "$RUN/vf/b/f1" "$RUN/vf/b/f2" "$RUN/vf/b/f3"
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b" 2>&1); rc=$?
assert_eq  "3 entries short: within ±5, ok"      0 "$rc"
rm -f "$RUN/vf/b/f4" "$RUN/vf/b/f5" "$RUN/vf/b/f6"
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b" 2>&1); rc=$?
assert_eq  "6 entries short: die"                1 "$rc"
assert_has "6 entries short: says so"            "entry count differs: donor 14, here 8 (allowed ±5)" "$out"
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b 1" 2>&1); rc=$?
assert_eq  "6 short with 1 extra allowed: ok"    0 "$rc"
cp -a "$RUN/vf/a/." "$RUN/vf/b/"; rm -f "$RUN/vf/b/d1/d2/big"
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b" 2>&1); rc=$?
assert_eq  "one big file missing: count ok, size WARN, exit 0" 0 "$rc"
assert_has "one big file missing: WARN text"     "WARN: apparent size differs by more than 1%" "$out"
out=$(lib_sh "$V; tx_verify_files $RUN/vf/a $RUN/vf/b 0 307200" 2>&1); rc=$?
case "$out" in *"apparent size differs"*) _fail "excluded bytes are taken off the donor's size" "$out";; *) _pass "excluded bytes are taken off the donor's size";; esac

# --- (f) a dry run over a fake plan: every pipeline printed, no state touched ------
P=$RUN/dry; mkdir -p "$P"
{
	echo '[target]'
	echo 'disk=/dev/sda id=serial:X size=1000204886016 lsec=512 psec=4096 ptuuid=- head=-'
	echo 'label=dos firmware=bios bios_grub=- esp=- driver=ahci data=ssh compress=lz4'
	echo '[volumes]'
	printf 'src=/dev/sda3\tkind=swap\tfs=swap\tsize=4294967296\tused=-\tmethod=mkswap\ttarget=/dev/sda2\ttsize=4294967296\tmount=swap\tnum=2\tnotes=-\n'
	printf 'src=/dev/sda2\tkind=part\tfs=ext4\tsize=494738079744\tused=42949672960\tmethod=block\ttarget=/dev/sda3\ttsize=994833334272\tmount=/\tnum=3\tnotes=elastic,dirty,grow\n'
	printf 'src=/dev/centos/root\tkind=lv\tfs=xfs\tsize=1990583123968\tused=161061273600\tmethod=files\ttarget=/dev/centos/root\ttsize=985686605824\tmount=/srv\tnum=-\tnotes=100%%FREE\n'
	printf 'src=/dev/sda1\tkind=esp\tfs=vfat\tsize=627900416\tused=12582912\tmethod=esp\ttarget=/dev/sda1\ttsize=629145600\tmount=/boot/efi\tnum=1\tnotes=-\n'
	echo '[mkfs]'
	echo 'mkfs.xfs -f -m crc=1 /dev/centos/root'
} > "$P/plan"
printf 'swapfile\tpath=/srv/swap\tsize=1073741824\topts=\n' > "$P/donor.inv"
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; transfer_run' 2>&1); rc=$?
assert_eq  "dry: exit 0"                          0 "$rc"
assert_has "dry: apply not done is tolerated"     "(dry) apply is not marked done" "$out"
assert_has "dry: probe skipped"                   "(dry) probe skipped" "$out"
assert_has "dry: status line per volume"          "vol 2/4: /dev/sda2 -> /dev/sda3 (block, 460.8G)" "$out"
assert_has "dry: mkswap volume needs nothing"     "nothing to stream: apply made /dev/sda2" "$out"
assert_has "dry: donor block pipeline verbatim"   "(dry) donor: bash -o pipefail -c 'partclone.extfs -c -s /dev/sda2 -o - -q -a1 -I -L /run/reloca-src.log | lz4 -c; echo \${PIPESTATUS[0]} > /run/reloca-src.status'" "$out"
assert_has "dry: local block chain over sshd:2222" "-p 2222 -c aes128-gcm@openssh.com -o ControlMaster=no" "$out"
assert_has "dry: local block chain"               "bash -o pipefail -c lz4\\ -d\\ -c\\ \\|\\ partclone.extfs\\ -r\\ -s\\ -\\ -o\\ /dev/sda3\\ -L\\ $P/vol-3.log\\ -f\\ 10\\ -B 2>$P/vol-3.progress" "$out"
assert_has "dry: dirty ext -> e2fsck -f -y"       "(dry) e2fsck -f -y /dev/sda3" "$out"
assert_has "dry: grow -> resize2fs"               "(dry) resize2fs /dev/sda3" "$out"
assert_has "dry: donor ro mount (xfs norecovery, private)" "(dry) donor: mount -t xfs -o ro,norecovery /dev/centos/root /mnt/reloca.to/src/centos-root && mount --make-private /mnt/reloca.to/src/centos-root" "$out"
assert_has "dry: recipient mount"                 "(dry) mount -t xfs /dev/centos/root /mnt/reloca.to/dst/centos-root" "$out"
assert_has "dry: recipient mount made private"    "(dry) mount --make-private /mnt/reloca.to/dst/centos-root" "$out"
assert_has "dry: swapfile on /srv excluded"       "--exclude=./swap -cf - ." "$out"
assert_has "dry: files pipeline verbatim"         "(dry) donor: bash -o pipefail -c 'cd /mnt/reloca.to/src/centos-root && tar --one-file-system --numeric-owner --xattrs --xattrs-include=\\* --sparse --exclude=./swap -cf - . | lz4 -c; echo \${PIPESTATUS[0]} > /run/reloca-src.status'" "$out"
assert_has "dry: esp pipeline without xattrs"     "(dry) donor: bash -o pipefail -c 'cd /mnt/reloca.to/src/1 && tar --one-file-system --numeric-owner --sparse -cf - . | lz4 -c;" "$out"
assert_has "dry: esp extracted without ownership" "tar\\ -C\\ /mnt/reloca.to/dst/1\\ --numeric-owner\\ --no-same-owner\\ --no-same-permissions\\ -xf\\ -" "$out"
assert_has "dry: umounts printed"                 "(dry) umount /mnt/reloca.to/dst/centos-root" "$out"
assert_has "dry: donor umount printed"            "(dry) donor: umount /mnt/reloca.to/src/centos-root" "$out"
assert_has "dry: ends without streaming"          "(dry) transfer: 4 volumes printed, nothing streamed" "$out"
n=$(grep -c '^vol\.' "$P/state" 2>/dev/null); assert_eq "dry: no vol.* state written" 0 "${n:-0}"
assert_eq  "dry: phase transfer not marked"       "" "$(RUN=$P lib_sh 'state_get phase.transfer')"
assert_ok  "dry: the log holds the donor pipeline verbatim" grep -qF "(dry) donor: bash -o pipefail -c 'partclone.extfs -c -s /dev/sda2 -o - -q -a1 -I -L /run/reloca-src.log | lz4 -c; echo \${PIPESTATUS[0]} > /run/reloca-src.status'" "$P/log"
# -o compress=/data= override the plan; raw prints the listener and warns
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[compress]=zstd; OPT[data]=raw; transfer_run' 2>&1); rc=$?
assert_eq  "dry raw: exit 0"                      0 "$rc"
assert_has "dry raw: trusted-LAN warning"         "data=raw: plain TCP (busybox nc)" "$out"
assert_has "dry raw: listener line"               "(dry) busybox nc -l -p 3" "$out"
assert_has "dry raw: donor sends to our nc"       "| zstd -T0 --fast=3 -q -c | busybox nc " "$out"
# a volume done earlier is skipped, -o redo=N repeats it
RUN=$P lib_sh 'vol_state_set /dev/sda2 done'
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; transfer_run' 2>&1)
assert_has "done volume is skipped"               "vol 2/4: /dev/sda2 -> /dev/sda3 (block): done earlier, skipped (-o redo=3 repeats it)" "$out"
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[redo]=3; transfer_run' 2>&1)
assert_has "redo=3 repeats the done volume"       "vol 2/4: /dev/sda2 -> /dev/sda3 (block, 460.8G)" "$out"
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[redo]=/dev/sda2; transfer_run' 2>&1)
assert_has "redo=SRC repeats the done volume"     "vol 2/4: /dev/sda2 -> /dev/sda3 (block, 460.8G)" "$out"
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[redo]=all; transfer_run' 2>&1)
assert_has "redo=all repeats the done volume"     "vol 2/4: /dev/sda2 -> /dev/sda3 (block, 460.8G)" "$out"
# the "earlier attempt failed" refresh of a files volume must look at the state
# BEFORE transfer_run marks it running (stand phase B caught the always-refresh)
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[redo]=all; transfer_run' 2>&1)
case "$out" in *"earlier attempt"*) _fail "fresh files volume is not re-made" "saw 'earlier attempt'";; *) _pass "fresh files volume is not re-made";; esac
RUN=$P lib_sh 'vol_state_set /dev/centos/root failed'
out=$(RUN=$P DRY=y lib_sh 'DONOR_HOST=10.0.0.12; OPT[redo]=all; transfer_run' 2>&1)
assert_has "failed files volume is re-made first"  "earlier attempt failed" "$out"
RUN=$P lib_sh 'vol_state_set /dev/centos/root pending'


# --- (g) refusals --------------------------------------------------------------------
Q=$RUN/refuse; mkdir -p "$Q"; cp "$P/plan" "$Q/plan"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; transfer_run' 2>&1); rc=$?
assert_eq  "apply not done: exit 2"               2 "$rc"
assert_has "apply not done: says so"              "run 'reloca.to -s apply' first" "$out"
RUN=$Q lib_sh 'phase_done apply'
out=$(RUN=$Q lib_sh 'transfer_run' 2>&1); rc=$?
assert_eq  "no donor: exit 2"                     2 "$rc"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; OPT[data]=udp; transfer_run' 2>&1); rc=$?
assert_eq  "data=udp: exit 4"                     4 "$rc"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; OPT[compress]=bzip2; transfer_run' 2>&1); rc=$?
assert_eq  "compress=bzip2: exit 4"               4 "$rc"
assert_has "compress=bzip2: names what it wants"  "want lz4, zstd, gzip or none" "$out"
printf '[target]\ndata=ssh compress=lz4\n[volumes]\nsrc=/dev/sda9\tkind=part\tfs=ext4\tsize=1\tused=-\tmethod=rsync\ttarget=/dev/sda9\ttsize=1\tmount=/x\tnum=9\tnotes=-\n' > "$Q/plan"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; RELOCA_PROBE_S=0; tx_require_tools() { :; }; transfer_run' 2>&1); rc=$?
assert_eq  "unknown method: exit 4"               4 "$rc"
assert_has "unknown method: names it"             "unknown method 'rsync'" "$out"
printf '[target]\ndata=ssh compress=lz4\n[volumes]\n' > "$Q/plan"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; transfer_run' 2>&1); rc=$?
assert_eq  "empty [volumes]: exit 4"              4 "$rc"
printf '[target]\ndata=ssh compress=lz4\n[volumes]\nsrc=/dev/sda1\tfs=ext4\tsize=1\tused=-\tmethod=block\ttarget=/dev/sda1\tnum=1\tnotes=-\n' > "$Q/plan"
out=$(RUN=$Q lib_sh 'DONOR_HOST=10.0.0.12; have() { return 1; }; transfer_run' 2>&1); rc=$?
assert_eq  "missing tools: exit 2"                2 "$rc"
assert_has "missing tools: names partclone"       "missing on this box: partclone.extfs" "$out"

# --- (h) watchdog: a pipeline that never progresses is killed, the volume fails ----
W=$RUN/wd; mkdir -p "$W"
printf '[target]\ndata=ssh compress=none\n[volumes]\nsrc=/dev/fake\tkind=part\tfs=ext4\tsize=1048576\tused=524288\tmethod=block\ttarget=/dev/fake2\ttsize=1048576\tmount=/\tnum=5\tnotes=-\n' > "$W/plan"
RUN=$W lib_sh 'phase_done apply'
# stands in for "ssh ... -n -- REMOTE": runs REMOTE locally
printf '#!/bin/bash\nwhile [ "$1" != -- ]; do shift; done; shift\nexec bash -c "$1"\n' > "$W/fakessh"; chmod 0755 "$W/fakessh"
t0=$(date +%s)
out=$(RUN=$W RELOCA_WATCHDOG_S=3 RELOCA_POLL_S=1 RELOCA_PROBE_S=0 lib_sh '
	DONOR_HOST=127.0.0.1
	ssh_data_cmd() { echo "$RUN/fakessh"; }
	rsh() { return 0; }                         # rm -f of the status files, cat of the status
	tx_require_tools() { :; }
	tx_remote_block_cmd() { echo "sleep 300"; }  # a donor that sends nothing
	tx_local_block_cmd() { echo "cat > /dev/null"; }
	transfer_run' 2>&1); rc=$?
t1=$(date +%s)
assert_eq  "watchdog: exit 1"                     1 "$rc"
assert_has "watchdog: reason"                     "no progress for 3s (watchdog); pipeline killed" "$out"
assert_has "watchdog: names the volume and the redo command" "volume /dev/fake (5) failed" "$out"
assert_has "watchdog: redo hint"                  "reloca.to -o redo=5 -s transfer" "$out"
assert_eq  "watchdog: state failed"               failed "$(RUN=$W lib_sh 'tx_vol_state /dev/fake')"
assert_eq  "watchdog: rc recorded"                1 "$(RUN=$W lib_sh 'tx_state_get vol./dev/fake.rc')"
assert_eq  "watchdog: state file has the key"     "vol./dev/fake=failed" "$(grep '^vol./dev/fake=' "$W/state")"
assert_ok  "watchdog: failure record names the volume" grep -q '^exit=1 phase=.* volume=/dev/fake ' "$W/failure"
assert_ok  "watchdog: fired within 15 s (not the 300 s sleep)" test $((t1 - t0)) -lt 15
assert_fail "watchdog: pgid file removed"         test -e "$W/tx.pgid"
assert_has "watchdog: summary holds the failure"  "failed" "$(cat "$W/summary")"

# --- (i) end-to-end loopback: sshd on 127.0.0.1:2398 as the donor's data channel ---
e2e_reason=
[ "$(id -u)" = 0 ] || e2e_reason="not root"
for t in partclone.extfs lz4 mkfs.ext4 e2fsck ssh-keygen; do command -v "$t" >/dev/null 2>&1 || e2e_reason="${e2e_reason:-}${e2e_reason:+, }$t missing"; done
[ -x /usr/sbin/sshd ] || e2e_reason="${e2e_reason:-}${e2e_reason:+, }/usr/sbin/sshd missing"
if [ -z "$e2e_reason" ] && { command -v ss >/dev/null 2>&1 && ss -Hltn 2>/dev/null | grep -q ':2398 '; }; then e2e_reason="port 2398 busy"; fi
if [ -n "$e2e_reason" ]; then
	skip "e2e loopback block transfer" "$e2e_reason"
else
	E=$(mktemp -d /root/.reloca-e2e.XXXXXX); chmod 700 "$E"; mkdir -p "$E/run"
	ssh-keygen -q -t ed25519 -N '' -f "$E/hostkey"
	ssh-keygen -q -t ed25519 -N '' -f "$E/run/id_ed25519"
	cp "$E/run/id_ed25519.pub" "$E/authorized_keys"; chmod 600 "$E/authorized_keys"
	/usr/sbin/sshd -f /dev/null -h "$E/hostkey" -p 2398 -o ListenAddress=127.0.0.1 -o "AuthorizedKeysFile=$E/authorized_keys" \
		-o PermitRootLogin=yes -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
		-o StrictModes=no -o UsePAM=no -o "PidFile=$E/sshd.pid" -E "$E/sshd.log" 2>/dev/null
	up=; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$E/sshd.pid" ] && { up=y; break; }; sleep 1; done
	if [ -z "$up" ]; then
		skip "e2e loopback block transfer" "throwaway sshd did not start: $(tail -1 "$E/sshd.log" 2>/dev/null)"
		rm -rf "$E"
	else
		mkdir -p "$E/tree/etc" "$E/tree/var/log"
		echo mail2 > "$E/tree/etc/hostname"
		dd if=/dev/urandom of="$E/tree/var/log/big" bs=1M count=40 status=none
		truncate -s 64M "$E/a.img"; mkfs.ext4 -q -F -d "$E/tree" "$E/a.img"
		truncate -s 64M "$E/b.img"
		{
			echo '[target]'
			echo 'label=dos firmware=bios bios_grub=- esp=- driver=ahci data=ssh compress=lz4'
			echo '[volumes]'
			printf 'src=%s\tkind=part\tfs=ext4\tsize=67108864\tused=18874368\tmethod=block\ttarget=%s\ttsize=67108864\tmount=/\tnum=7\tnotes=-\n' "$E/a.img" "$E/b.img"
		} > "$E/run/plan"
		RUN=$E/run lib_sh 'phase_done apply'
		out=$(RUN=$E/run TX_RSTATUS=$E/src.status TX_RLOG=$E/src.log RELOCA_POLL_S=1 RELOCA_PRINT_S=0 RELOCA_PROBE_S=1 \
			lib_sh 'DONOR_HOST=127.0.0.1; DONOR_PORT=2398; SSH_DATA_PORT=2398; export DONOR_HOST DONOR_PORT; transfer_run' 2>&1); rc=$?
		assert_eq  "e2e: exit 0"                     0 "$rc"
		assert_has "e2e: probe printed an estimate"  "estimated total: 18.0M at " "$out"
		assert_has "e2e: donor pipeline verbatim"    "+ donor: bash -o pipefail -c 'partclone.extfs -c -s $E/a.img -o - -q -a1 -L $E/src.log | lz4 -c; echo \${PIPESTATUS[0]} > $E/src.status'" "$out"
		assert_has "e2e: local chain over the data sshd" "ssh -p 2398 -c aes128-gcm@openssh.com -o ControlMaster=no" "$out"
		assert_has "e2e: restore onto a file uses -O" "partclone.extfs\\ -r\\ -s\\ -\\ -O\\ $E/b.img" "$out"
		assert_ok  "e2e: partclone log has the success marker" grep -q 'successfully restored' "$E/run/vol-7.log"
		assert_ok  "e2e: donor status file says 0"   grep -qx 0 "$E/src.status"
		assert_ok  "e2e: donor log written"          grep -q 'successfully cloned' "$E/src.log"
		assert_has "e2e: summary line with bytes"    "vol 1/1 ($E/a.img): restored " "$out"
		assert_ok  "e2e: a progress line was printed" grep -q "vol 1/1 ($E/a.img): .*%), .*ETA " <<< "$out"
		assert_ok  "e2e: progress fragments were collected" grep -q 'Completed: 100.00%' "$E/run/vol-7.progress"
		assert_eq  "e2e: progress reader sees 100%"  "100.00" "$(RUN=$E/run lib_sh "tx_block_progress $E/run/vol-7.progress 18874368" | cut -d' ' -f1)"
		assert_has "e2e: post-copy e2fsck -n"        "+ e2fsck -n $E/b.img" "$out"
		assert_ok  "e2e: images identical"           cmp -s "$E/a.img" "$E/b.img"
		assert_eq  "e2e: state done"                 'done' "$(RUN=$E/run lib_sh "tx_vol_state $E/a.img")"
		assert_eq  "e2e: bytes recorded = partclone's space in use" "$(RUN=$E/run lib_sh "tx_log_bytes $E/run/vol-7.log")" "$(RUN=$E/run lib_sh "tx_state_get vol.$E/a.img.bytes")"
		assert_ok  "e2e: bytes are plausible (> 40 MB of data)" test "$(RUN=$E/run lib_sh "tx_state_get vol.$E/a.img.bytes")" -gt 41943040
		assert_eq  "e2e: phase transfer done"        'done' "$(RUN=$E/run lib_sh 'state_get phase.transfer')"
		assert_ok  "e2e: the log holds the donor pipeline verbatim" grep -qF "+ donor: bash -o pipefail -c 'partclone.extfs -c -s $E/a.img" "$E/run/log"
		assert_ok  "e2e: the log holds the local chain" grep -qF "| bash -o pipefail -c lz4\\ -d\\ -c\\ \\|\\ partclone.extfs" "$E/run/log"
		assert_has "e2e: summary file"               "transfer: done" "$(cat "$E/run/summary")"
		assert_fail "e2e: pgid file removed"         test -e "$E/run/tx.pgid"
		# a second run streams nothing: the volume is done
		out=$(RUN=$E/run TX_RSTATUS=$E/src.status TX_RLOG=$E/src.log RELOCA_PROBE_S=0 \
			lib_sh 'DONOR_HOST=127.0.0.1; DONOR_PORT=2398; SSH_DATA_PORT=2398; export DONOR_HOST DONOR_PORT; transfer_run' 2>&1); rc=$?
		assert_eq  "e2e rerun: exit 0"               0 "$rc"
		assert_has "e2e rerun: skipped as done"      "done earlier, skipped (-o redo=7 repeats it)" "$out"
		assert_fail "e2e rerun: nothing streamed"    grep -q '^+ donor: bash' <<< "$out"
		# -o redo=7 with data=raw: the same image again over busybox nc (the
		# listener here, the donor's command through the control master);
		# the watchdog is capped so a regression cannot hang the suite
		if command -v busybox >/dev/null 2>&1 && busybox nc 2>&1 | grep -q -- '-l'; then
			truncate -s 0 "$E/b.img"; truncate -s 64M "$E/b.img"
			out=$(RUN=$E/run TX_RSTATUS=$E/src.status TX_RLOG=$E/src.log RELOCA_POLL_S=1 RELOCA_PRINT_S=0 RELOCA_PROBE_S=0 RELOCA_WATCHDOG_S=40 \
				lib_sh 'DONOR_HOST=127.0.0.1; DONOR_PORT=2398; SSH_DATA_PORT=2398; export DONOR_HOST DONOR_PORT; OPT[redo]=7; OPT[data]=raw; transfer_run' 2>&1); rc=$?
			assert_eq  "e2e raw: exit 0"                 0 "$rc"
			assert_has "e2e raw: trusted-LAN warning"    "data=raw: plain TCP" "$out"
			assert_has "e2e raw: listener printed"       "+ busybox nc -l -p 3" "$out"
			assert_has "e2e raw: donor sends to our nc"  "| lz4 -c | busybox nc 127.0.0.1 3" "$out"
			assert_ok  "e2e raw: images identical again" cmp -s "$E/a.img" "$E/b.img"
			assert_ok  "e2e raw: success marker"         grep -q 'successfully restored' "$E/run/vol-7.log"
			assert_eq  "e2e raw: state done"             'done' "$(RUN=$E/run lib_sh "tx_vol_state $E/a.img")"
			assert_fail "e2e raw: no listener left"      pgrep -f "busybox nc -l -p 3[0-9]* -w 120"
		else
			skip "e2e raw (busybox nc) transfer" "busybox nc not available"
		fi
		ssh -S "$E/run/ssh.sock" -O exit -o LogLevel=ERROR -p 2398 root@127.0.0.1 >/dev/null 2>&1 || true
		kill "$(cat "$E/sshd.pid")" 2>/dev/null
		[ "$T_FAIL" -eq 0 ] && rm -rf "$E" || echo "  (kept $E for inspection)"
	fi
fi

t_end
