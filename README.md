# reloca.to

**English** · [Українська](README.uk.md) · [Русский](README.ru.md)

Move an installed Linux server from one machine to another over the network,
with one command. Not a disk image and not a backup tool: it reads both
machines, writes a plan you can read and edit, lays out the new disks with the
same UUIDs, copies every filesystem, fixes the copy up in a chroot (fstab,
mdadm, initramfs drivers, grub, network), verifies that it will boot, and only
then cuts over. **The old server is only ever read.**

```sh
curl -fsSL reloca.to | bash      # on the new server, booted into a Live OS
reloca.to root@10.0.0.12         # the address of the old one
```

Written at [XServer](https://xserver.cloud/) for our own migrations between
data centres, then given away: <https://reloca.to>.

## Two modes

**Off-line relocation.** Both machines run a Live OS. Every volume is copied
once, as fast as the disks and the link allow. The server is out of service
from the moment it leaves its own system until the new one boots.

**On-line relocation.** The old server keeps running its own system and serving
its users. `reloca-agent` copies the volumes while they are being written to and
watches every write as it goes; pass after pass only the changed blocks follow,
until what is still pending would take a few seconds. Then the filesystems are
frozen for exactly those seconds, the last delta passes, and the new server
comes up. Measured on the test bench with a shaped link:

| link | first pass | convergence | freeze window | whole move |
|---|---|---|---|---|
| 10 GbE | 15 s, 147 MiB/s | on the third pass | 1.7 s | 223 s |
| 400 Mbit, 20 ms | 41 s, 66 MiB/s | on the fourth pass | 8.7 s | 341 s |
| 100 Mbit, 30 ms, 0.05% loss | 185 s, 14.9 MiB/s | does not converge | 100 s | 953 s |

The third row is the case where the server writes faster than the link carries.
The agent measures both rates, predicts that the deltas cannot shrink, and says
so instead of grinding: it either takes the window on offer or refuses to freeze
at all, leaving the old server untouched.

## What it never does

- Never writes to the old server. No fsck, no resize. It stays your rollback.
- Never wipes a disk before you have read what is on it now and typed its name
  and size from the screen.
- Never formats with defaults: every filesystem is created with the source's
  features and verified right after mkfs.
- Never reboots the new server without a green verify.
- Never touches the other disks of the new server.

## What is supported

| | |
|---|---|
| Source systems | Debian 10–13, Ubuntu 18.04–26.04, CentOS 7–10, Rocky / Alma / RHEL 8–10 |
| Layouts | md RAID of any level, LVM, LVM on md, plain MBR/GPT partitions |
| Filesystems | ext2/3/4, XFS; swap partitions, logical volumes and swap files; ESP |
| Firmware | BIOS → BIOS, UEFI → UEFI, and UEFI ↔ BIOS either way |
| Disks | the new disk may be larger or smaller than the old one |
| Network | ifupdown, netplan, systemd-networkd, ifcfg, NetworkManager |

Not supported: btrfs, ZFS, LUKS, NTFS, CentOS 6 and other grub-legacy systems,
SUSE, Windows.

On-line relocation also needs root on the running server and a kernel that can
track writes: eBPF where it exists, ftrace as far back as CentOS 7's 3.10.

## The phases

Each one can be run on its own with `-s`; finished work is skipped, so a phase
can be retried after a failure.

```sh
reloca.to -s plan root@10.0.0.12   # read-only: inventory both sides, write the plan
$EDITOR /run/reloca.to/plan        # edit it if you like
reloca.to -s check                 # re-validate the edits
reloca.to -s apply                 # partition, LVM, swap, mkfs (asks first)
reloca.to -s transfer              # copy the volumes
reloca.to -s postfix               # chroot: fstab, mdadm, initramfs, grub, network
reloca.to -s verify                # dozens of checks; exit 3 means do not reboot
reloca.to -s cutover               # the old server leaves the network, the new one boots
```

`reloca.to -n` is a dry run: it prints the plan and every command and changes
nothing, on either machine.

## Options

Every flag, phase and `-o` key is listed at <https://reloca.to/options/> and in
`reloca.to -h`. Options are passed one `-o` each, because a comma belongs to the
value:

```sh
reloca.to -o compress=none -o converge=5 root@10.0.0.12
```

## Build from source

```sh
make test         # shellcheck and the table tests: seconds, no root
make agent        # the static agent (needs a C compiler and libzstd)
make agent-test   # the agent against loop devices of this host (needs root)
make install      # into /usr/local, or PREFIX=/opt/reloca make install
```

The tool itself is bash with sourced libraries; the agent (`agent/`) is one C
binary with no dependencies at run time. The operator manual is at
<https://reloca.to> in English, Ukrainian and Russian, together with the full
[option reference](https://reloca.to/options/). It is kept there rather than in
this repository because that is where each release is published, so it never
describes a version other than the current one.

## Reporting a migration that went wrong

Open an issue with the plan (`/run/reloca.to/plan`), the log
(`/run/reloca.to/log`) and what the verify said. Unusual layouts and old
distributions are exactly what makes this tool better, and the old server is
untouched in every case, so there is something to compare against.

## Licence

MIT, see [LICENSE](LICENSE).
