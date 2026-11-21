# migrator

把一台已经装好的 Linux 服务器，通过网络搬到另一台机器上，一条命令。
它不是磁盘镜像工具，也不是备份工具：先读清两端，写出一份你可以读、可以改的计划，
按源盘的 UUID 和特性把新盘摆好，逐个文件系统搬过去，在新系统的 chroot 里补齐
fstab / mdadm / initramfs / grub / 网络，验证它真的能启动，最后才切。**旧服务器全程只读。**

```sh
make install                    # 或 sh tools/install.sh（见下文"安装"）
migrator root@10.0.0.12         # 新机器上执行，参数是旧机器的地址
```

## 两种模式

**离线迁移（off-line）**：两端都跑在 Live 里，每个卷只搬一次，能跑多快就多快。
机器从离开自己的系统到新系统起来这段时间不提供服务。

**在线迁移（on-line）**：旧服务器继续跑自己的系统、继续服务用户。`migrator-agent`
一边复制一边盯着写入，逐轮只追变化的块，直到剩余量只剩几秒；然后文件系统被冻结
几秒，跑完最后一轮增量，新机器起来。冻结窗口是这个工具唯一"停机"的地方，所以它
宁可多跑几轮也不肯把窗口拉长——测出来本轮增量收不敛，它会直接说不冻。

## 它绝不做什么

- 绝不写旧服务器。不做 fsck、不做 resize，它是你的回滚点。
- 没让你看清楚盘上现在是什么、没让你照着屏幕把盘名和容量敲一遍，绝不清盘。
- 绝不用默认参数格式化：每个文件系统按源盘的 features 建，建完立刻校验。
- verify 不全绿，绝不重启新机器。
- 绝不动新机器上的其它盘。

## 支持范围

| | |
|---|---|
| 源系统 | Debian 10–13、Ubuntu 18.04–26.04、CentOS 7–10、Rocky / Alma / RHEL 8–10 |
| 布局 | 任意级别的 md RAID、LVM、LVM on md、普通 MBR/GPT 分区 |
| 文件系统 | ext2/3/4、XFS；swap 分区、逻辑卷与 swap 文件；ESP |
| 固件 | BIOS→BIOS、UEFI→UEFI，以及 UEFI↔BIOS 双向 |
| 磁盘 | 新盘可以比旧盘大，也可以比旧盘小 |
| 网络 | ifupdown、netplan、systemd-networkd、ifcfg、NetworkManager |

不支持：btrfs、ZFS、LUKS、NTFS、CentOS 6 及更老的 grub-legacy 系统、SUSE、Windows。

在线模式还要求旧机器上有 root，且内核能跟踪写入：有 eBPF 用 eBPF，最老到
CentOS 7 的 3.10 用 ftrace。

## 阶段

每个阶段都能用 `-s` 单独跑；已经完成的会被跳过，所以失败后可以原样重试。

```sh
migrator -s plan root@10.0.0.12   # 只读：两端盘点，写出计划
$EDITOR /run/migrator/plan        # 想改就改
migrator -s check                 # 校验改动
migrator -s apply                 # 分区、LVM、swap、mkfs（先问再做）
migrator -s transfer              # 搬数据
migrator -s postfix               # chroot 内：fstab、mdadm、initramfs、grub、网络
migrator -s verify                # 几十项检查；退出码 3 = 不要重启
migrator -s cutover               # 旧机器离网，新机器起来
```

`migrator -n` 是干跑：只打印计划和每条命令，两端都不改。

## 选项

每个开关、阶段和 `-o` 键都用 `migrator -h` 列全；不认识的键会被拒绝，所以打错字
不会静默失效。选项一次一个 `-o`，因为逗号属于值本身：

```sh
migrator -o compress=none -o converge=5 root@10.0.0.12
```

## 安装

仓库就是唯一的来源，没有厂商下载：

```sh
make install                                   # 装进 /usr/local，PREFIX= 可改
sh tools/install.sh                            # 从 MIGRATOR_URL 指的目录取 tarball
MIGRATOR_URL=file://$PWD/dist sh tools/install.sh
```

`tools/install.sh` 只认 `MIGRATOR_URL` 指向的目录（里面有 `SHA256SUMS` 和
`migrator-<ver>.tar.gz`），没有内置地址——发行物放在哪由部署方决定。

## 构建

```sh
make test         # shellcheck + 表测试：几秒钟，不需要 root
make agent        # 静态 agent（要 C 编译器和 libzstd 静态库）
make agent-test   # 用本机 loop 设备跑 agent（需要 root）
```

工具主体是 bash + 被 source 的库；agent（`agent/`）是一个运行时零依赖的 C 程序。
真机实验台在 `rig/`，可自包含引导 Live 的脚本在 `tools/live-entry.sh` / `tools/live-cycle.sh`。

## 文档

- [docs/wiki/README.md](docs/wiki/README.md) — 中文用户文档与维护者文档，含 SVG 与 Mermaid 图示
- `docs/DECISIONS.md` — 决策簿：每个决定的日期、内容、被否的备选、理由、状态
- `docs/DESIGN.md` — 设计与各阶段的边界
- `docs/HANDOFF.md` — 真机矩阵台账（含凭据，不随仓库分发）
- [docs/release/](docs/release/README.md) — 发布文案、发布说明与公告草案

## 来源与许可

本项目是 [reloca.to](https://reloca.to/) 1.2 的派生作品。上游材料依据 MIT 许可提供，
版权声明与许可全文完整保留在 [LICENSE-UPSTREAM](LICENSE-UPSTREAM) 中
（`Copyright (c) 2026 XServer`）。

本项目新增部分为专有材料，见 [LICENSE](LICENSE)。组合作品的对外分发、商业性再分发、
修改后发布与内部二次开发，均须取得版权方书面许可。名称与标识使用见
[TRADEMARK.md](TRADEMARK.md)，来源与许可范围说明见 [NOTICE](NOTICE)。
完整政策见 [docs/wiki/14-license.md](docs/wiki/14-license.md)。

上游的商标、域名、商店与联系方式不属于许可范围，本项目不使用。上游的历史变更记录见
`docs/CHANGELOG-upstream.md`。
