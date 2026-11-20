> 上游变更记录（保留原样，仅存档）。
> 本文件来自 reloca.to 1.2（MIT，Copyright (c) 2026 XServer），其中的链接、版本号与
> 商店描述指向上游，与本项目的发行物无关。本项目的变更见 git 历史与 docs/DECISIONS.md。

# Changelog

What each release of reloca.to brought, newest first. The same notes are
at the bottom of <https://reloca.to/>.

## 1.2 — 2026-11-14

- The one command on the old server (`curl -fsSL reloca.to/live | bash`) now shows a single box: the network settings, the Live's root password and the ssh line. It asks before downloading anything; `-v` shows the kernel command line and the other details.
- The screen comes back after the jump into the Live: when the old system drove the GPU with its own driver (Matrox on Dell and HP, ASPEED on Supermicro, VMware and others), the Live loads its own driver instead of leaving the console frozen or showing no signal.

## 1.1 — 2026-10-23

- **On-line relocation**: the old server keeps serving while it is copied. Only the changed blocks follow, pass after pass, and the filesystems are frozen for the last seconds instead of the whole move.
- Compression and convergence are decided from measurements: the zstd level follows the donor's cpu and the link rate, and the agent says how many passes and minutes a shorter freeze would cost before it spends them.
- A pre-check runs the fix-up and the verify on a snapshot of the copy while the old server still works, so a target that would not boot is found before the cutover.
- On-line support for CentOS 7 and the RHEL family (ftrace on the 3.10 kernel, SELinux enforcing), and md RAID1 on the new server.
- Firmware change UEFI to BIOS and back for the RPM family.
- Every option is now listed at [reloca.to/options](https://reloca.to/options/), and `-o` keys are spelled with hyphens (an underscore is still accepted).

## 1.0 — 2026-10-15

- The first public release: one command on the new server moves a Linux system from another machine, both booted into XServer Live OS.
- Inventory of both sides, a plan you can read and edit, partitioning with the same UUIDs and features, the volumes over an encrypted channel, the fix-up in a chroot, dozens of checks before the reboot, then the cutover.
- Three ways to bring the old server into the Live: one command through kexec, an ISO through the provider's console, or the XServer panel.
- Two disks on the new server become md RAID1 with `-o raid=1`; the root travels block by block or file by file, whichever fits.

