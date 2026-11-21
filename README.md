# migrator

migrator 用于将一台已安装的 Linux 服务器迁移到另一台机器。数据通过网络直接传输，
不需要中间存储。

迁移在新机器上执行，参数为旧机器的地址：

```sh
make install                    # 见「安装」
migrator root@10.0.0.12         # 在新机器上执行，参数是旧机器的地址
```

传输以文件系统为单位，因此新磁盘可以小于旧磁盘，两端的扇区布局也不需要一致。

迁移按阶段执行。plan 阶段读取两端的磁盘与文件系统信息，生成迁移计划并保存到
`/run/migrator/plan`。计划是纯文本文件，内容包括磁盘布局、各文件系统的创建参数，
以及每个卷采用块级复制还是文件级复制。计划可以手动修改，修改后用 `-s check`
校验。

确认后，migrator 按计划创建分区与文件系统、传输数据，随后在新系统的 chroot
环境中重建 fstab、mdadm、initramfs、grub 与网络配置。verify 阶段全部通过后，
才允许重启新机器。

## 两种模式

**离线模式**：两台机器都引导进入 Live 环境，旧机器不运行自身系统。每个卷只传输
一次，速度仅受网络与磁盘限制。

**在线模式**：旧机器继续运行并提供服务。`migrator-agent` 跟踪旧机器上的磁盘写入，
逐轮只传输发生变化的块；当剩余数据量可以在数秒内传完时，冻结文件系统，完成最后
一轮传输。文件系统冻结是整个过程中唯一的中断点，通常持续数秒。如果某一轮的增量
无法收敛，migrator 不执行冻结，继续下一轮。

## 操作边界

- 不写入旧机器的任何块设备；不运行 fsck，不执行 resize，不删除临时文件。
- 文件系统按源盘的 features 创建，不使用 mkfs 默认值；创建完成后立即回读校验。
- verify 未全部通过时，不重启新机器。
- 只操作 `-d` 指定的磁盘，新机器上的其他磁盘不受影响。
- 清除磁盘前，先列出其现有分区、文件系统与容量，并要求用户手动输入磁盘名称确认。

## 支持范围

| 项 | 范围 |
|---|---|
| 源系统 | Debian 10–13、Ubuntu 18.04–26.04、CentOS 7–10、Rocky / Alma / RHEL 8–10 |
| 布局 | 任意级别的 md RAID、LVM、LVM on md、普通 MBR/GPT 分区 |
| 文件系统 | ext2/3/4、XFS；swap 分区、逻辑卷与 swap 文件；ESP |
| 固件 | BIOS→BIOS、UEFI→UEFI、UEFI↔BIOS 双向 |
| 磁盘 | 新盘可以比旧盘大，也可以比旧盘小 |
| 网络 | ifupdown、netplan、systemd-networkd、ifcfg、NetworkManager |

不支持 btrfs、ZFS、LUKS、NTFS、CentOS 6 及更早的 grub-legacy 系统、SUSE、
Windows。

在线模式有两个额外前提：旧机器上具有 root 权限；内核能够跟踪块写入——有 eBPF
时使用 eBPF，CentOS 7 的 3.10 使用 ftrace。

## 阶段

各阶段均可用 `-s` 单独执行。已完成的阶段会被跳过，因此某阶段失败后可以直接重试。

```sh
migrator -s plan root@10.0.0.12   # 只读：读取两端信息，生成计划
$EDITOR /run/migrator/plan        # 按需修改
migrator -s check                 # 校验计划
migrator -s apply                 # 分区、LVM、swap、mkfs（先确认再执行）
migrator -s transfer              # 传输数据
migrator -s postfix               # chroot 内：fstab、mdadm、initramfs、grub、网络
migrator -s verify                # 数十项检查，退出码 3 表示不要重启
migrator -s cutover               # 旧机器下线，新机器启动
```

`migrator -n` 为演练模式：只打印计划与将要执行的命令，不修改两端。

## 选项

`migrator -h` 列出全部开关、阶段与 `-o` 键。不支持的键会直接报错，不会静默忽略。
`-o` 每次只能指定一个键值对，因为逗号属于值的一部分：

```sh
migrator -o compress=none -o converge=5 root@10.0.0.12
```

## 安装

在已有系统上从仓库安装：

```sh
curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/get.sh | sh
```

从源码树安装或从发布包安装：

```sh
make install                                   # 装到 /usr/local/sbin，PREFIX= 可改
sh tools/install.sh                            # 从 MIGRATOR_URL 指向的目录取 tarball
MIGRATOR_URL=file://$PWD/dist sh tools/install.sh
```

`tools/install.sh` 只使用 `MIGRATOR_URL`，没有内置下载地址；该目录中需要有
`SHA256SUMS` 和 `migrator-<ver>.tar.gz`。发行物的存放位置由部署方决定。

## 构建

```sh
make test         # shellcheck + 表测试，几秒，不需要 root
make agent        # 静态 agent，需要 C 编译器和 libzstd 静态库
make agent-test   # 在本机 loop 设备上运行 agent，需要 root
make deb          # 生成 migrator 与 migrator-agent 两个 deb 包，需要 dpkg-dev
```

主体由 bash 脚本与若干被 source 的库组成。`agent/` 是一个 C 程序，运行时无外部
依赖，静态链接后可直接放入 Live 环境。`rig/` 是物理机测试环境；
`tools/live-entry.sh` 与 `tools/live-cycle.sh` 用于将一台机器引导至 Live 环境。

## 文档

- [docs/wiki/](docs/wiki/README.md)：用户文档与维护者文档，14 章，含 13 张 SVG 图示
- `docs/DECISIONS.md`：决策簿，每个决定的日期、内容、被否的备选、理由与状态
- `docs/DESIGN.md`：设计与各阶段的边界
- [docs/release/](docs/release/README.md)：公告、发布说明、首屏文案

## 来源与许可

本项目是 [reloca.to](https://reloca.to/) 1.2 的派生作品。上游材料依 MIT 许可提供，
版权声明与许可全文完整保留在 [LICENSE-UPSTREAM](LICENSE-UPSTREAM) 中
（`Copyright (c) 2026 XServer`）。

本项目新增的部分与上游材料合在一起，整体依 GPL-3.0-or-later 分发，全文见
[LICENSE](LICENSE)。可以再分发与修改，修改后的版本应以相同许可提供。名称与标识的使用
见 [TRADEMARK.md](TRADEMARK.md)，该政策不限制 GPL 授予的权利；来源与许可范围的说明见
[NOTICE](NOTICE)，完整政策见 [docs/wiki/14-license.md](docs/wiki/14-license.md)。

上游的商标、域名、商店与联系方式不属于许可范围，本项目不使用。上游的历史变更
记录在 `docs/CHANGELOG-upstream.md`。
