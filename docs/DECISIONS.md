# 决策日志（DECISIONS）

规则（用户 2026-11-19 指示）：后续一切走推荐选项，但必须留痕——每个决策记录日期、内容、备选项、推荐理由、状态。本簿从项目启动即维护，回填了会话中已定的全部决策。

| # | 日期 | 决策 | 备选项（被否） | 推荐理由 | 状态 |
|---|------|------|----------------|----------|------|
| D1 | 11-18 | 项目范围：Linux→Linux 整机迁移先行，Windows 不做 | Windows 一并支持（厂商级工作量） | 用户的明确收缩（"在linux可以"）；砍掉 VSS/驱动注入/BCD 整条最重线 | 已定 |
| D2 | 11-18 | 基座：fork reloca.to 1.2（MIT），导入基线 commit a77ebeb | 自研整链；扩展 ReaR | 四路调研：目标重合度 ~80% 且生产验证；自研=重走所有坑；ReaR 救援内核绑源机，语义错位 | 已定 |
| D3 | 11-18 | virt-v2v 只作行为参考，不搬代码 | 移植其 OCaml 逻辑 | GPLv2+ 传染：翻译代码=衍生作品；reloca.to(MIT)+自研无此问题 | 已定 |
| D4 | 11-19 | E1 方案：自建最小 Debian bookworm Live（live-build），标记文件 `/etc/reloca-live-release` 兼容接受 `/etc/xserver-live-release` | 用 SystemRescueCD 改造；伪造 xserver 标记文件 | live-build 对 Debian 模式支持最好且 deb.debian.org 可达（实测 200/0.5s）；SystemRescueCD 为 Arch 系无 apt-get（require_full_live 需要它）；伪造标记是欺骗工具不可取 | 已定 |
| D5 | 11-19 | bootstrap 默认镜像从 `mirror.xserver.cloud/debian` 改为 `deb.debian.org/debian`，默认 codename trixie→bookworm | 保留 xserver 默认 | fork 后不再依赖 XServer 基础设施；Live 自带 release 文件时 MIRROR/CODENAME 由其提供 | 已定 |
| D6 | 11-19 | 验证环境：容器内 QEMU TCG 软件模拟双机（donor+recipient），不经 KVM | 要求用户提供 KVM VM；只做代码级单测 | 单台容器即可闭环端到端功能验证（用户只有一台机器）；真实性能/eBPF 实测留待后续 KVM VM | 已定 |
| D7 | 11-19 | Live 里直接烘焙 reloca.to 全部运行时依赖（partclone/xfsprogs/lvm2/mdadm/grub 双固件/sshd/rsync/lz4/zstd/pv/tmux），bootstrap 运行时 apt 仅作兜底 | 运行时才装（上游 Live 的做法） | 容器构建时可联网，烘焙比运行时装可靠且快；bootstrap_missing 检查通过即零依赖 | 已定 |
| D8 | 11-19 | rig 布局：recipient=2 盘（vda=Live 盘 + vdb=空目标盘），donor=2 盘（vda=Live 盘 + vdb=被迁系统盘）；同一 Live 镜像双角色复用 | donor 真盘直迁（在线模式优先） | 离线模式先闭环（上游默认全链路）；在线模式作为 rig 第二阶段 | 进行中 |
| D9 | 11-19 | 决策留痕制度：所有决策记入本簿（用户指示） | 只在会话里口头汇报 | 用户明确要求可追溯 | 常设 |
| D10 | 11-19 | rig 密钥处理：私钥不烘焙进 Live ISO；构建脚本只注入公钥（donor/recipient 的 root authorized_keys），私钥由 run 脚本 scp 进 recipient VM | 私钥烘焙进 ISO | ISO 可能被复制分发，私钥入镜像违背最小暴露；scp 一步成本可忽略 | 已定 |
| D11 | 11-19 | Live 经 ISO/CD-ROM 引导（`-boot order=d`），两侧真盘均为 vda（donor=vda 被迁盘、recipient=vda 空目标盘）；修订 D8 的"Live 装盘"布局 | Live 装到 vda 引导 | 省去 Live 磁盘镜像构建与引导配置；QEMU `-cdrom` 直接可用；D8 其余（同一 Live 双角色复用）不变 | 已定 |
| D12 | 11-19 | **教训+方案**：Ubuntu 容器上构建 Debian Live，live-build 不用 apt 跨套件安装（`-t bookworm` 曾把 libc6 半升级到 2.36，dpkg audit 爆炸，已完整恢复到 jammy 2.35）；改为从 Debian pool 下载 deb → `dpkg-deb -x /opt/lb` 零污染解包 → `LIVE_BUILD=/opt/lb/usr/share/live/build PATH=/opt/lb/usr/bin:$PATH` 调用（live-build 原生支持该 env） | `-t bookworm` apt 安装；沿用 jammy 的 3.0~a57 | 跨套件 apt 会连带升级 libc，已实证出事故；dpkg-deb -x 不碰 dpkg 数据库；3.0~a57 太老不支持 bookworm 构建 | 已定 |
