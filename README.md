# migrator

migrator 把一台已安装的 Linux 服务器迁移到另一台机器。磁盘布局、文件系统、文件、服务配置与引导设置都在迁移范围内，数据经网络直接传输，不需要中间存储。

本页给出一次迁移的最短路径。选项、阶段、限制与排错见 [docs/wiki/](docs/wiki/README.md)。

## 三步完成一次迁移

以下命令都在目标主机上执行，目标主机指承接迁移结果的新机器。

### 第 1 步 进入迁移 Live

迁移命令只在迁移 Live 中执行。`apply` 会清空目标盘，在运行中的系统上执行会破坏该系统。以 root 执行一条命令，它在本机构建迁移 Live、写入引导项并重启：

```sh
curl -fsSL https://gitee.com/tktogether/migrator/raw/master/tools/live-boot.sh | bash
```

脚本在重启之前打印登录用的私钥，请先复制到其他设备。重启后确认已进入迁移 Live：

```sh
cat /etc/migrator-live-release
```

该命令要求根文件系统或独立的 `/boot` 位于非 LVM 分区，内存不少于 1536 MiB，可用空间不少于 3 GiB。条件不满足时，脚本在下载任何内容之前说明原因。已经有镜像、已有构建产物或没有控制台时，见[快速开始](docs/wiki/03-quickstart.md)第 0 步。

### 第 2 步 准备源端访问

源主机需要允许 root 使用密钥登录：

```sh
ssh-keygen -t ed25519 -N '' -f /root/migrator-key
ssh-copy-id -i /root/migrator-key.pub root@10.0.0.12
ssh -i /root/migrator-key root@10.0.0.12 true && echo ok
```

### 第 3 步 执行迁移

```sh
migrator -y -i /root/migrator-key -d /dev/sda root@10.0.0.12
```

`-d` 指定承接新系统的磁盘。首次使用建议去掉 `-y`，在清空目标盘之前核对磁盘名称与容量。

工具先读取两端状态并生成迁移计划，随后按计划创建分区与文件系统、传输数据、在目标系统的 chroot 环境中修补配置、验证，最后切换。源主机运行自身系统时为在线模式，源主机也在迁移 Live 中时为离线模式，无需指定。验证未全部通过时工具拒绝切换，退出码为 3。

## 支持范围

| 项目 | 范围 |
|---|---|
| 源系统 | Debian 10–13、Ubuntu 18.04–26.04、CentOS 7–10、Rocky Linux、AlmaLinux、RHEL 8–10 |
| 磁盘布局 | 普通 MBR/GPT 分区、任意级别的 md RAID、LVM、LVM on md |
| 文件系统 | ext2、ext3、ext4、XFS；swap 分区、swap 逻辑卷、swap 文件；EFI 系统分区 |
| 固件 | BIOS 与 UEFI 之间的四种组合 |
| 网络配置 | ifupdown、netplan、systemd-networkd、`ifcfg`、NetworkManager |

btrfs、ZFS、LUKS、NTFS、CentOS 6 及更早的系统、SUSE、Windows 不支持。完整清单与关键限制见[产品概览](docs/wiki/01-overview.md)。

## 文档

| 要了解 | 阅读 |
|---|---|
| 完成一次迁移的完整步骤 | 本页，或[快速开始](docs/wiki/03-quickstart.md) |
| 产品边界与支持范围 | [产品概览](docs/wiki/01-overview.md) |
| 安装工具、构建迁移 Live | [安装与构建](docs/wiki/02-install.md) |
| 在线、离线与中继的取舍 | [迁移模式](docs/wiki/04-modes.md) |
| 分阶段执行与审核计划 | [阶段与执行流程](docs/wiki/05-stages.md)、[计划文件](docs/wiki/07-plan-file.md) |
| 命令行参数 | [选项参考](docs/wiki/06-options.md) |
| 迁移后验收与回滚 | [验证与验收](docs/wiki/10-verify-and-acceptance.md) |
| 排查故障 | [故障排查](docs/wiki/11-troubleshooting.md) |
| 决策记录 | [docs/DECISIONS.md](docs/DECISIONS.md) |

## 构建与测试

| 目标 | 作用 |
|---|---|
| `make test` | shellcheck 与表测试，数秒，不需要 root |
| `make agent` | 构建静态链接的 agent，需要 C 编译器与 libzstd 静态库 |
| `make agent-test` | 在本机 loop 设备上运行 agent，需要 root |
| `make install` | 安装到 `/usr/local`，`PREFIX` 可改 |
| `make deb` | 生成 `migrator` 与 `migrator-agent` 两个 deb 包，需要 dpkg-dev |

代码由 bash 脚本与被 source 的库组成，`agent/` 是 C 程序，运行时无外部依赖。`rig/` 是物理机测试环境，`tools/live-boot.sh` 在目标机上完成构建与引导。维护者文档见 [docs/wiki/maintainers/](docs/wiki/maintainers/README.md)。

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
