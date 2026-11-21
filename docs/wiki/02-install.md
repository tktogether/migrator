# 安装与构建

migrator 的全部代码以仓库为唯一来源，没有内置的厂商下载地址。安装方式取决于使用场景：

- 在已有仓库中构建并安装；
- 装发行版格式的 deb 包（仓库自带打包目录）；
- 在迁移 Live 上从自行托管的发布包安装；
- 构建迁移 Live，使其自带工具与依赖。

无论采用哪种方式，迁移命令都必须在完整迁移 Live 中执行。

## 最快的方式：一条命令

源码在 GitHub，三个免费镜像会同步它：jsDelivr、Gitee、GitHub raw。`tools/get.sh` 按这个顺序逐个试，第一个能用的就装。

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/tktogether/migrator@1.2/get.sh | sh
```

它按文件取源码树，打包成 `tools/install.sh` 认得的样子，然后交给它安装——所以在线安装与离线安装走的是同一段安装逻辑，只有一处需要维护。

需要指定来源、走代理或换安装目录时，改环境变量即可，不必改代码：

```sh
curl -fsSL .../get.sh | MIGRATOR_PROXY=https://your.proxy/ sh
curl -fsSL .../get.sh | sh -s -- --prefix /opt/migrator --ref 1.2
```

也可以先安装再直接运行，参数会原样交给 `migrator`：

```sh
curl -fsSL .../get.sh | sh -s -- -s plan root@192.168.1.111
```

## 1. 从仓库安装

![安装布局](assets/release-layout.svg)

在仓库根目录执行：

```sh
make install
```

默认安装到 `/usr/local`。可通过 `PREFIX` 改变前缀：

```sh
make install PREFIX=/opt/migrator
```

主程序按候选路径查找库目录：`$HERE/../lib`、`$HERE/../lib/migrator`、`$HERE/../share/migrator`、
`/usr/local/lib/migrator`、`/usr/lib/migrator`、`/usr/share/migrator`。源码树布局、
`/usr/local` 安装与发行版包布局都在其中，因此 `PREFIX=/opt/migrator` 也可以直接运行。
都不命中时程序报错退出，此时用 `MIGRATOR_LIB` 指定库目录。

安装内容：

| 路径 | 内容 |
|---|---|
| `$(PREFIX)/bin/migrator` | 主程序 |
| `$(PREFIX)/bin/migrator-agent` | 在线迁移使用的静态 agent |
| `$(PREFIX)/lib/migrator/*.sh` | 被主程序加载的库 |
| `$(PREFIX)/lib/migrator/VERSION` | 安装版本 |
| `$(PREFIX)/share/doc/migrator/` | `LICENSE`、`LICENSE-UPSTREAM`、`NOTICE`、`TRADEMARK.md` |

`make install` 依赖 `make agent`。`make agent` 需要 C 编译器和 libzstd 静态库；生成的是运行时零依赖的 x86_64 静态二进制。

安装版本号取 `git describe --always --dirty`，因此从 Git 工作区安装时通常显示提交标识；在没有 Git 信息时回退到 `VERSION` 文件。检查安装结果：

```sh
migrator -V
migrator -h
```

`-V` 输出主程序版本、库目录和 Live 构建标识。`-h` 列出全部选项、阶段和退出码。

## 2. 从 deb 安装

仓库带 `debian/` 打包目录，可以生成发行版格式的包：

```sh
make deb
```

`dpkg-buildpackage` 把成果放在仓库的上一级目录，例如 `migrator_1.2-1_all.deb` 与
`migrator-agent_1.2-1_amd64.deb`。安装时用 apt，让依赖一起装上：

```sh
sudo apt install ../migrator_1.2-1_all.deb ../migrator-agent_1.2-1_amd64.deb
```

| 包 | 架构 | 路径 | 内容 |
|---|---|---|---|
| `migrator` | all | `/usr/sbin/migrator` | 主程序 |
| `migrator` | all | `/usr/share/migrator/*.sh` | 被主程序加载的库 |
| `migrator` | all | `/usr/share/migrator/VERSION` | 安装版本 |
| `migrator` | all | `/usr/share/man/man8/migrator.8` | 手册页，`man migrator` |
| `migrator-agent` | any | `/usr/lib/migrator/migrator-agent` | 在线迁移使用的静态 agent |

两个包的版本互锁，升级时一并处理。`migrator` 依赖 `bash`、`coreutils`、`util-linux`、
`openssh-client`、`tar`、`gzip`、`awk`；`partclone`、`xfsprogs`、`mdadm`、`lvm2`、`zstd`、
`lz4`、`initramfs-tools` 等放在 `Recommends`，`qemu-system-x86`、`gdisk`、`grub2-common`
在 `Suggests`。工具在 bootstrap 阶段还会按缺失项用 apt 补齐，不必为了跑一次迁移先装满全部
工具。

进入发行版归档后安装方式为 `apt install migrator`。当前尚未提交归档，只能从本地包安装。

## 3. 从发布包安装

`tools/install.sh` 从 `MIGRATOR_URL` 指向的目录获取发布物。该目录必须包含：

- `SHA256SUMS`；
- 一个 `migrator-<ver>.tar.gz`，且 `SHA256SUMS` 只列出这一个 tarball。

压缩包内应包含 `migrator-<ver>/bin/migrator`、`migrator-<ver>/bin/migrator-agent`（可选）与 `migrator-<ver>/lib/`，另附许可与来源文件 `LICENSE`、`LICENSE-UPSTREAM`、`NOTICE`、`TRADEMARK.md`。

示例：

```sh
MIGRATOR_URL=file:///srv/migrator/releases sh tools/install.sh
MIGRATOR_URL=https://download.example.com/migrator sh tools/install.sh
```

安装器会下载 `SHA256SUMS` 与 tarball，校验 SHA-256，解压到临时目录，再以原子替换方式安装到：

| 路径 | 内容 |
|---|---|
| `$PREFIX/sbin/migrator` | 主程序 |
| `$PREFIX/sbin/migrator-agent` | agent（tarball 中存在时） |
| `$PREFIX/lib/migrator/` | 库与版本文件，旧目录整体替换 |
| `$PREFIX/share/doc/migrator/` | 许可与来源文件（tarball 中存在时） |

`$PREFIX` 默认为 `/usr/local`，可用 `MIGRATOR_PREFIX` 覆盖。

注意：`make install` 安装到 `$(PREFIX)/bin`，`tools/install.sh` 安装到 `$PREFIX/sbin`。两者的库目录相同，默认前缀下主程序会在 `/usr/local/lib/migrator` 查找库。非默认前缀存在与上文相同的库路径限制。

安装器还支持安装后直接运行：

```sh
MIGRATOR_URL=https://download.example.com/migrator \
  sh tools/install.sh -y -i /root/key root@10.0.0.12
```

`tools/install.sh` 只依赖 shell、`curl` 或 `wget`、`tar` 与 `sha256sum`。迁移 Live 的根文件系统位于内存，重启后安装内容丢失，因此每次启动 Live 后需要重新安装。

## 4. 构建 agent

```sh
make agent
```

产物为 `agent/migrator-agent`。该程序同时用于源端（`serve`）和目标端（`pull`），采用静态链接，源端不需要安装任何依赖。

在开发主机上验证 agent：

```sh
make agent-test
```

该测试需要 root、loop 设备和 `losetup`、`mkfs.ext4`、`sfdisk`。测试覆盖 ext4 整盘与分区、eBPF 与 ftrace 两种跟踪方式、块设备目标、cutover 轮询和不可冻结的 vfat 场景。该测试不修改真实磁盘，但会创建和销毁 loop 设备。

## 5. 构建迁移 Live

仓库提供两份构建脚本：

| 脚本 | 适用环境 | 说明 |
|---|---|---|
| `rig/build-live.sh` | 具备 mmdebstrap 的 Debian 系构建机 | 使用 mmdebstrap、live-boot、mksquashfs、xorriso 生成 BIOS 引导 ISO |
| `rig/build-live-debootstrap.sh` | 无 mmdebstrap、但有 root 与 debootstrap 的 Debian/Ubuntu 构建机 | 使用 debootstrap 生成同样结构的 ISO，并额外输出 `vmlinuz-live`、`initrd-live.img` 与 squashfs 供自包含引导使用 |

两份脚本都支持 `LIVE_PROFILE` / `PROFILE`：

- `slim`：不包含 QEMU，squashfs 使用 xz 压缩，适合 1 GiB 内存的目标端；无法执行试启动验证。
- `full`：包含 QEMU 与 QEMU 工具，squashfs 使用 zstd 压缩，可执行 `-o boottest=1`。

构建前需要先编译 agent，否则 ISO 中不会包含在线迁移所需的二进制。

简要步骤：

```sh
make agent
LIVE_PROFILE=slim bash rig/build-live.sh
```

或：

```sh
git archive HEAD > /tmp/migrator.tar.gz
BUILD_DIR=/data/live-build TARBALL=/tmp/migrator.tar.gz \
  PROFILE=slim bash rig/build-live-debootstrap.sh
```

产物位置、依赖包、构建约束与自包含引导方法见 [迁移 Live 构建](maintainers/live-build.md)。

## 6. 在迁移 Live 中准备工具

如果使用现成的迁移 Live，且其中未包含 migrator，可在 Live 中执行：

```sh
MIGRATOR_URL=file:///run/media/usb/migrator sh /path/to/install.sh
```

也可从仓库复制后执行 `make install`。安装后确认：

```sh
migrator -V
```

迁移开始前，工具会自动检查两端缺失的运行时工具，并从镜像安装。离线环境或不希望运行期安装时，使用 `-o offline=1`；此时缺失的工具只产生警告，核心工具缺失会导致后续阶段拒绝执行。

## 7. 版本一致性

离线模式要求两端使用同一次构建的 Live。`bootstrap` 阶段会比较 partclone、lz4 等工具版本；不一致时默认拒绝继续。只有确认兼容性后，才可使用 `-o force=1` 跳过该检查。

在线模式要求目标端的 `migrator-agent` 与源端运行的 agent 版本一致。agent 由目标端上传到源端的 `/run` 临时目录，版本不一致会被拒绝。

## 8. 常见安装问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `not a Live OS (no /etc/migrator-live-release)` | 当前系统不是完整迁移 Live | 启动迁移 Live 后再执行 |
| `this needs the full Live OS, not boot=base` | 使用了基础 Live | 改用完整 Live |
| `migrator: command not found` | 未安装或不在 `PATH` | 使用 `make install`，或把安装目录加入 `PATH` |
| `cannot log in ... without a terminal` | 非交互环境缺少密钥 | 使用 `-i KEYFILE`，或在执行前转发 SSH agent |
| `tool versions differ` | 两端 Live 构建不同 | 使用同一份 ISO；确认后才使用 `force=1` |

## 相关文档

- [快速开始](03-quickstart.md)
- [迁移模式](04-modes.md)
- [迁移 Live 构建](maintainers/live-build.md)
- [发布与安装布局](maintainers/release.md)
