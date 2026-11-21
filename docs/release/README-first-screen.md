<!--
草案：用于替换根 README.md 的首屏。发布前请核对版本、支持范围与文档链接。
本文案假设放置于仓库根目录，因此链接以仓库根为基准。
-->

# migrator

在任意两台 Linux 主机之间迁移完整系统。

migrator 读取源端与目标端的状态，生成一份可以审核、可以编辑的迁移计划。它按源磁盘的布局与文件系统特性重建目标盘，逐卷复制数据，再在目标系统的 chroot 中修正 fstab、mdadm、initramfs、GRUB 与网络配置。验证通过后执行切换。源主机磁盘全程只读。

## 主要特性

- **计划可审核**：写入磁盘前生成文本计划，记录目标分区表、LVM 命令、格式化参数、复制方式与配置改写。
- **源端只读**：不对源端磁盘执行 fsck、resize 或写入，可作为回滚依据。
- **两种复制模式**：离线单次复制；在线多轮增量，仅冻结窗口内暂停写入。
- **跨固件迁移**：BIOS 与 UEFI 双向，deb 系与 rhel 系均有实现路径。
- **多磁盘与 RAID**：支持 md RAID、LVM、LVM on md；支持两块目标磁盘组成 md RAID1。
- **缩容与扩容**：块级复制保持原容量；文件级复制允许目标卷小于源卷；目标更大时自动扩容。
- **切换前验证**：检查引导项、initramfs、fstab、内核命令行、文件系统特性、引导器、网络与 RAID；可选 QEMU 试启动。
- **受限网络**：支持通过中继主机连接两端。
- **单租户中继**：固定端口 2222、2223、2224，配置预检。

## 快速开始

目标主机启动到完整迁移 Live，源主机满足对应模式的前提。

在线迁移：

```sh
DONOR=root@10.0.0.12
migrator -y -i /root/migrator-key -d /dev/sda "$DONOR"
```

离线迁移：

1. 将源主机启动到同一迁移 Live；
2. 在目标主机执行同一命令。

中继迁移：

```sh
# 源主机
/usr/local/sbin/relay-tunnel.sh -i /root/migrator-key root@relay.example

# 目标主机
migrator -y -i /root/migrator-key \
  -o relay=root@relay.example \
  -o sshd-port=2223 \
  root@relay.example:2222
```

需要逐步审核时，可单独执行各阶段：

```sh
migrator -s plan "$DONOR"
cp /run/migrator/plan /root/plan.review
vi /run/migrator/plan
migrator -s check
migrator -s apply
migrator -s transfer
migrator -s postfix
migrator -s verify
migrator -s cutover
```

## 支持范围

| 项目 | 范围 |
|---|---|
| 源系统 | Debian 10–13、Ubuntu 18.04–26.04、CentOS 7–10、Rocky Linux / AlmaLinux / RHEL 8–10 |
| 架构 | x86_64 |
| 布局 | 普通分区、md RAID、LVM、LVM on md |
| 文件系统 | ext2/3/4、XFS；swap 分区、逻辑卷、swap 文件；ESP |
| 分区表 | MBR、GPT，可在两者之间转换 |
| 固件 | BIOS↔BIOS、UEFI↔UEFI、BIOS↔UEFI、UEFI↔BIOS |
| 网络配置 | ifupdown、netplan、systemd-networkd、ifcfg、NetworkManager |
| 复制模式 | 离线、在线、中继 |

不支持：btrfs、ZFS、LUKS、NTFS、F2FS、reiserfs、Windows、SUSE、Arch Linux、CentOS 6 及更老的 grub-legacy 系统。一个 LVM 卷组只能位于一个物理卷。

## 安装

从仓库安装：

```sh
make install
```

从自行托管的发布包安装：

```sh
MIGRATOR_URL=https://download.example.com/migrator sh tools/install.sh
```

`tools/install.sh` 要求目标目录包含 `SHA256SUMS` 与一个 `migrator-<ver>.tar.gz`，并校验 SHA-256。仓库不内置厂商下载地址。

构建迁移 Live：

```sh
make agent
LIVE_PROFILE=slim bash rig/build-live.sh
```

或使用 debootstrap 版本：

```sh
git archive HEAD > /tmp/migrator.tar.gz
BUILD_DIR=/data/live-build TARBALL=/tmp/migrator.tar.gz \
  PROFILE=slim bash rig/build-live-debootstrap.sh
```

## 文档

- [中文文档](docs/wiki/README.md)：安装、快速开始、迁移模式、阶段、选项、计划、网络、验证、故障排查、FAQ、安全。
- [维护者文档](docs/wiki/maintainers/README.md)：代码结构、清单格式、实验台、Live 构建、测试、发布。
- `docs/DESIGN.md`：设计文档。
- `docs/DECISIONS.md`：决策记录。
- `docs/release/`：发布文案。

## 已知限制

- 目标磁盘容量不小于 20 GiB，且不得为可移动或 USB 磁盘。
- 块级复制要求目标卷不小于源卷；缩容需要文件级复制。
- 目标端 Secure Boot 仅在源端为 UEFI 且 ESP 有 shim 时可用。
- 网络配置保留源端 IP、网关与 DNS；跨网段迁移后需要人工调整。
- 增量传输可跨越传输进程的中断；任一端整机重启后需要重新开始。
- 目标端多网卡名称分配属于尽力而为。

## 来源与许可

本项目是 [reloca.to](https://reloca.to/) 1.2 的派生作品。派生自上游的材料依据 MIT 许可提供，原始版权声明与许可全文保留在 [LICENSE-UPSTREAM](LICENSE-UPSTREAM) 中。本项目新增部分依据 [LICENSE](LICENSE) 中的专有条款提供。

组合作品的对外分发、商业性再分发、修改后发布与内部二次开发，均须取得版权方书面许可。名称与标识使用见 [TRADEMARK.md](TRADEMARK.md)。上游商标、域名、商店与联系方式不属于许可范围，本项目不使用。

上游变更记录见 `docs/CHANGELOG-upstream.md`。
