# 设计文档：通用 Linux 主机迁移系统（暂名 migrator）

日期：2026-11-19（设计定稿）
状态：已获用户批准（用户三连授权："你去充分探索吧" → "够你今晚就把项目做出来" → "/goal 尽可能完整的完成整个项目"，并确认 Linux→Linux 先行；approaches 已在对话中摊开并由用户选定）

## 意图与 why

云厂商迁移上云服务（AWS MGN / 阿里 SMC）能把一台主机的全部文件与服务迁走，但目标端绑定自家云。用户要的是**任意两台 Linux 主机之间的自由迁移**（物理机 / VPS / 内网机，双向），完整迁移文件与服务，迁移后可直接引导。

## 目标 / 非目标 / 反目标

- **目标**：Linux→Linux 整机迁移（x86_64 先行）；运行中源机在线多轮增量同步；NAT 后双机可达（中继）；迁移计划可预览可编辑（dry-run）；还原后自动验证（引导测试）；跨 run 可续。
- **非目标**（本期）：Windows 源/目标；btrfs/ZFS/LUKS/NTFS 文件系统；Arch/SUSE 发行版；K8s 工作负载编排。
- **反目标**（做了即失败）：源机被写入任何持久数据；停机窗口不可预期；迁移静默损坏数据（宁可重传不可错传）；需要用户理解内核细节才能操作。

## 约束

1. **基座为 migrator fork（MIT）**，上游 github.com/Vitalium/migrator 1.2（commit a77ebeb 为导入基线）。上游仅 3 commits / 0 star / bus factor 1 → fork 后自主演进，不依赖上游。
2. 真实验证环境：一台 Incus 容器（Ubuntu 22.04，8.2G 可用盘，无 KVM）→ 用 QEMU TCG 软件模拟双机做端到端功能验证；真实性能与 eBPF 实测需要后续 KVM VM。
3. 参考项目只读参考、不搬代码：virt-v2v（GPLv2+ 传染红线）；migratekit/vjailbreak（工程模式）；ReaR（布局格式思想）。

## Approaches（已选定）

- **A. 自研整链**（原方案：Agent + 稀疏镜像中间表示 + 自编排）——否：migrator 已生产验证同样能力（在线 eBPF/ftrace 增量、纯函数计划生成、跨固件引导修复、五套网络体系），自研等于重走它踩过的所有坑。
- **B. fork migrator + 四大扩展**（选定）——成本最低、风险集中且明确。
- **C. 扩展现成灾备框架（ReaR 等）**——否：救援 ISO 绑定源机内核，与"目标端救援"语义错位。
- E1–E4 扩展的详细论证与 file:line 证据见调研报告（workspace research/FINDINGS.md）。

## 已定的 how

1. **E1 自建救援环境**（首个阻塞项：XServer Live 不可获得）：最小 Debian bookworm Live（live-build），自带 virtio/nvme 全模块内核 + migrator 全部运行时依赖（partclone/lvm2/mdadm/grub 双固件/sshd/rsync/lz4/zstd）+ migrator 工具本体；代码侧以 `/etc/migrator-live-release` 标记替代对 `/etc/xserver-live-release` 的硬检查（require_full_live / live_build_id / set_roles / bootstrap 镜像变量）。
2. **验证 rig**：容器内 QEMU TCG 双机——donor VM（debootstrap 最小 Debian + 测试数据/服务）与 recipient VM（引导自建 Live、挂空目标盘），经 slirp 端口转发互达 ssh；先跑离线模式全链路，后跑在线模式。
3. **E2 中继**：agent 传输已抽象为 `pull --ssh CMD` 命令流 → transport 接口化，实现 ssh -R 反向隧道（先行）与中转机模式；cutover 信令（源机外拨）已有，保持。
4. **E3 状态持久化**：借 migratekit 检查点令牌模式——chunk bitmap/epoch 落盘目标端检查点文件；锚点缺失/失效一律降级全量；目标盘被本地改写（postfix）后主动作废增量链。
5. **E4 QEMU 试启动验证档**：verify 之后可选深度档——目标盘快照喂 QEMU（SeaBIOS/OVMF）+ serial console 断言"内核起来 + sshd 监听"。

## 留给实现者的决策空间

Live 的体积/包清单微调；rig 的网络拓扑细节；E2 传输接口的函数签名；E3 检查点文件格式；E4 断言脚本的判定阈值。均不影响设计骨架。

## 分期（= 验收标准）

- M0：rig 里跑通 migrator（fork 后）第一次完整离线迁移，donor 数据在目标机验证可引导。
- M1=E1：全部绑定点脱离 XServer Live；自建 Live ISO 可在任意 QEMU/真机引导并完成迁移。
- M2=E2：双端均在 NAT 后（模拟：slirp 隔离网络）仍可完成迁移。
- M3=E3：迁移中断后可跨 run 续跑；增量锚点失效自动降级全量。
- M4=E4：verify 增加 QEMU 试启动档；产出验证报告。
