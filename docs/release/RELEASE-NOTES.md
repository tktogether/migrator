# migrator 1.2 发布说明

## 版本信息

| 项目 | 内容 |
|---|---|
| 仓库版本 | `1.2`（`VERSION` 文件） |
| 构建版本 | `git describe --always --dirty`；无 Git 信息时为 `1.2` |
| 发布日期 | 2026-11-20 |
| 许可 | 双许可：上游材料 MIT；本项目新增部分专有 |

本发布说明对应当前仓库 HEAD。安装后的实际版本字符串以 `migrator -V` 为准。

## 概要

本版本提供 Linux 主机之间的整机迁移能力，覆盖离线复制、在线增量复制与中继拓扑。迁移过程以可审核的文本计划为中心，目标盘写入前执行校验与指纹门禁，目标系统启动前执行只读验证，验证通过后才允许切换。

## 主要能力

### 迁移流程

- 两端只读清单采集；
- 纯函数式计划生成；
- 计划重新校验；
- 目标盘擦除、分区、md/LVM 重建、格式化与特性掩码校验；
- 块级与文件级复制；
- chroot 内修正 fstab、mdadm、LVM、cmdline、initramfs、GRUB、网络、cloud-init；
- 只读验证与可选 QEMU 试启动；
- 源端离线确认后切换。

### 复制模式

- **离线**：两端均为迁移 Live，每卷复制一次；
- **在线**：源端继续运行，通过 eBPF 或 ftrace 跟踪写入，多轮增量后冻结；
- **中继**：两端位于 NAT 后时，通过第三台主机转发控制与数据通道。

### 存储与引导

- ext2、ext3、ext4、XFS；
- MBR 与 GPT；
- md RAID、LVM、LVM on md；
- swap 分区、swap 逻辑卷、swap 文件；
- BIOS 与 UEFI 双向切换；
- 两块目标磁盘组成 md RAID1（仅 deb 系）；
- 缩容与扩容；
- 多盘源端到单盘目标端。

### 运行控制

- 阶段可单独执行；
- 阶段幂等，可失败后重试；
- 卷级跳过与 `-o redo=` 重做；
- `-n` 空运行；
- `-y` 无人值守；
- tmux 断线保护；
- 统一退出码与失败记录；
- 完整可重放日志。

### 验证

- 引导项、内核与 initrd；
- initramfs 驱动与 LVM devices 文件；
- fstab、swap 与 `RESUME=`；
- 内核命令行；
- 文件系统特性掩码；
- BIOS/UEFI 引导器与 NVRAM；
- 网络配置中的网卡名与 MAC；
- RAID1 阵列与 mdadm 配置；
- 可选 QEMU 叠加盘试启动。

## 兼容范围

| 项目 | 范围 |
|---|---|
| 源系统 | Debian 10–13、Ubuntu 18.04–26.04、CentOS 7–10、Rocky Linux / AlmaLinux / RHEL 8–10 |
| 架构 | x86_64 |
| 文件系统 | ext2/3/4、XFS |
| 分区表 | MBR、GPT |
| 固件 | BIOS、UEFI |
| 网络配置 | ifupdown、netplan、systemd-networkd、ifcfg、NetworkManager |
| 目标磁盘 | 单盘；或两块盘组成 md RAID1（仅 deb 系） |

不支持：

- btrfs、ZFS、LUKS、NTFS、F2FS、reiserfs；
- Windows、SUSE、Arch Linux；
- CentOS 6 及更老的 grub-legacy 系统；
- 一个卷组跨多个物理卷；
- 目标端 Secure Boot 已启用且源端为 BIOS；
- 新建独立 `/boot` 槽位（`boot-part=`）；
- 跨迁移 Live 重启的增量续传。

## 重要行为说明

1. **源端磁盘只读**。在线模式会向源端 root 的 `authorized_keys` 追加一次性会话公钥，并在 `/run` 放置临时 agent。公钥不会自动删除。
2. **在线冻结窗口**。冻结后源端根文件系统不可写，不能通过 SSH 登录。应使用 `cutover` 或 `cutover=rollback`。目标端 1800 秒未轮询时源端自动解冻。
3. **网络地址保留**。工具只改写网卡名称与 MAC，保留源端 IP、网关与 DNS。跨网段迁移后需要人工调整。
4. **验证失败禁止重启**。退出码 3 表示目标盘已写入但验证未通过。
5. **日志为临时状态**。`/run/migrator` 位于内存文件系统，重启后丢失。验证通过后会在目标系统中保留迁移记录。
6. **工具版本一致性**。离线模式要求两端 Live 构建一致；不一致时默认拒绝，只有确认后才可使用 `force=1`。

## 安装

从仓库安装：

```sh
make install
```

从自行托管的发布包安装：

```sh
MIGRATOR_URL=https://download.example.com/migrator sh tools/install.sh
```

发布包目录必须包含 `SHA256SUMS` 与一个 `migrator-<ver>.tar.gz`。仓库不内置厂商下载地址。发布包与安装目录应同时包含 `LICENSE`、`LICENSE-UPSTREAM`、`NOTICE` 与 `TRADEMARK.md`。

构建迁移 Live：

```sh
make agent
LIVE_PROFILE=slim bash rig/build-live.sh
```

或在无 mmdebstrap 的构建机上：

```sh
git archive HEAD > /tmp/migrator.tar.gz
BUILD_DIR=/data/live-build TARBALL=/tmp/migrator.tar.gz \
  PROFILE=slim bash rig/build-live-debootstrap.sh
```

## 验证状态

本版本在以下方向完成过端到端验证：

- 在线模式从源端原系统到目标系统独立启动；
- 离线模式两端 Live；
- BIOS 与 UEFI 双向切换；
- LVM 源、LVM on md；
- 目标端缩容；
- 多盘源端到单盘目标端；
- 单盘源端到双盘 md RAID1；
- 中继拓扑的控制、数据与切换通道；
- 1 GiB 内存目标端；
- 可选 QEMU 试启动。

具体环境与结果记录保留在内部决策文档与实验记录中，不随发布物分发。发布前应针对本次变更范围重新执行相应验证。

## 升级与兼容

- 项目已整体更名为 `migrator`，内部标识、环境变量、路径、瞬态单元名与握手字符串均使用新名称；
- 旧的 `/etc/xserver-live-release` 仍被兼容读取；
- 旧的环境变量名、路径名与命令名不作为兼容接口；
- 计划格式随版本演进，旧计划应重新生成，不应跨版本直接使用；
- 迁移 Live 必须从对应源码版本重建，不支持在旧 Live 上注入新脚本作为正式交付方式。

## 来源与许可

本项目是 reloca.to 1.2 的派生作品。派生自上游的材料依据 MIT 许可提供，原始版权声明与许可全文保留在 `LICENSE-UPSTREAM` 中。

本项目新增部分依据 `LICENSE` 中的专有条款提供。组合作品的对外分发、商业性再分发、修改后发布与内部二次开发，均须取得版权方书面许可。名称与标识使用见 `TRADEMARK.md`，许可范围说明见 `NOTICE`。

上游的商标、域名、商店与联系方式不属于许可范围，本项目不使用。上游变更记录作为存档保留在 `docs/CHANGELOG-upstream.md`。

MIT 许可不可撤销。在本许可调整之前已依据 MIT 许可合法分发的副本，其接收方仍享有该许可授予的权利。

## 相关文档

- [产品概览](../wiki/01-overview.md)
- [安装与构建](../wiki/02-install.md)
- [快速开始](../wiki/03-quickstart.md)
- [迁移模式](../wiki/04-modes.md)
- [已知限制与常见问题](../wiki/12-faq.md)
- [维护者文档](../wiki/maintainers/README.md)
