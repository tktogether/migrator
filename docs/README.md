# migrator — 任意两台 Linux 主机间的整机迁移

Fork 自 [reloca.to](https://github.com/Vitalium/reloca.to) 1.2（MIT，XServer 出品）并按四大扩展点改造的通用主机迁移系统：物理机 / VPS / 内网机之间自由迁移，Linux→Linux（x86_64）先行。设计文档见 `docs/DESIGN.md`，全部决策见 `docs/DECISIONS.md`（D1–D17），调研证据见 workspace `research/FINDINGS.md`。

## Fork 相对上游的改动

| 扩展 | 内容 | 代码位置 | 状态 |
|---|---|---|---|
| **E1 去 XServer 化** | 自有 Live 标记 `/etc/reloca-live-release`（兼容接受上游标记）；bootstrap 默认镜像 deb.debian.org/bookworm；自建 Debian bookworm Live（手搓：mmdebstrap + live-boot + squashfs + xorriso），烘焙全部运行时依赖与工具本体 | `lib/common.sh` `live_release_file()`、`lib/bootstrap.sh`、`lib/ssh.sh`、`lib/inventory.sh`、`bin/reloca.to`（8 处触点）+ `rig/build-live.sh` | ✅ 已实现；ISO 316M 实测可引导 |
| **E4 试启动验证** | `-o boottest=1`：verify 全绿后用 qcow2 overlay 把目标盘在 qemu 里试启动（direct kernel boot + 串口断言 multi-user），目标盘零写入；qemu 缺失/小内存优雅降级 | `lib/verify.sh`（verify_boottest_*、vf_boottest_* seams）、`lib/bootstrap.sh`（boottest 工具组） | ✅ 实现并在真机跑通（D20）；slim Live 按内存门控自动跳过（D23） |
| **E2 中继模式** | `-o relay=USER@HOST[:SSHPORT]`：donor 侧 `tools/relay-tunnel.sh` 反向隧道（中继:2222/2223 ← donor:22/2222），recipient 以 `root@RELAY:2222 -o sshd-port=2223` 迁移；recipient 的 cutover 反向隧道走中继（在线 poller 可达）。传输层零改动 | `lib/ssh.sh`（relay_spec/ssh_relay_start）、`lib/transfer.sh`（poller 覆盖）、`tools/relay-tunnel.sh` | ✅ 已实现，解析与接线 17 断言全绿；rig 中继拓扑 E2E 待跑 |
| **E3 状态持久化** | 跨 run 多轮增量 + 字节级续传：agent 位图落盘 + 目标端检查点令牌 + 失效降级全量（migratekit 不变量） | `agent/tracker.c` `agent/main.c` `lib/transfer.sh` | 📐 设计定稿（D16），实现排 M3 |

测试基线：`tests/run.sh` 2302 断言，2 失败与上游纯净树完全一致（环境性 mawk 差异），**零回归**；新增 relay.sh 17 断言全绿。

## 快速开始（QEMU rig，单机即可做端到端验证）

容器/构建机上（root，8G+ 可用盘，能访问 deb.debian.org）：

```bash
make agent                       # agent/reloca-agent（静态 C 二进制）
bash rig/build-live.sh           # → ~/rig/migrator-live.iso + ~/rig/rig_ed25519（密钥对）
bash rig/build-donor.sh          # → ~/rig/donor-disk.raw（最小 Debian + 服务/负载）
setsid nohup bash rig/run-offline.sh > ~/rig/run-offline.log 2>&1 &
                                 # 双 VM 迁移（QEMU TCG，无需 KVM）
bash rig/verify-target.sh        # 独立启动迁移后的盘：断言 hostname/负载哈希/服务
RELOCA_EXTRA_OPTS="-o boottest=1" bash rig/run-offline.sh   # 带 E4 试启动的迁移
bash rig/clean.sh                # 清理全部 rig 进程
```

真机两台时（无 rig）：目标机引导 Live ISO 后运行
`reloca.to -y [-o relay=...] -i KEY [-d DISK] root@DONOR[:2222]`，donor 侧见 `tools/relay-tunnel.sh` 头注释。

## rig 历史坑位（新环境部署前必读，D17）

1. bookworm 可预测网卡命名会把 eth0→ens3：Live APPEND 与 donor grub 都已加 `net.ifnames=0 biosdevname=0`；
2. `/dev/console` 归最后一个 `console=` 所有：串口调试时 `console=ttyS0` 必须放最后；
3. TCG 慢引导会撞 systemd 默认 90s 服务超时：APPEND 已带 `systemd.default_timeout_start_sec=600`；
4. mmdebstrap 会把构建机 hostname 泄漏进镜像：build-live.sh 已显式覆盖；
5. `pkill -f` 的模式若出现在同一条命令行里会自杀：清理一律走 `rig/clean.sh`。

## 路线图（M0–M4，见 DESIGN.md）

- ✅ M1=E1（自建 Live，316M ISO 双角色实测可引导） · ✅ M2 代码=E2（中继，17 断言） · ✅ M4 代码=E4（boottest，契约 20/20）
- ✅ M0 验收（D20，真机双 VM 在线模式）：plan→check→apply→在线 transfer（3 轮收敛，8.22G，冻结 0.63s）→postfix（双内核 initramfs、grub i386-pc）→verify（19 ok，E4 boottest 到 multi-user）→cutover=poweroff→**独立固件引导成功**（systemd running、eth0 DHCP、SSH/数据/swap 在位）。同轮修复 verify.sh 三处缺陷（boottest serial 变量、ANSI 色码/内存、netplan+NM 误判）
- ✅ E4 实测轮（Live 内置 qemu，boottest 真机跑通；slim profile 下按 MemTotal/可用内存门控自动跳过）
- ✅ **1C/1G 收端**（D23）：slim Live（444M ISO，去 qemu + xz + zram + `reloca.ip=`）在 .117（1C/955MiB/40G/UEFI）完成 13.18G 迁移、UEFI 独立引导，7 服务全绿
- ✅ **2G BIOS→UEFI 无人工**（D24）：修复 plan 的固件判定（改用 inventory `host.fw`）后，`grub_from_live=1` 生效，postfix 从 Live 装 UEFI grub/NVRAM，verify 19 ok，目标 UEFI 启动
- ✅ **四机任意互传矩阵（主要方向）**：.115→.117（1G 收端）、.115→.116（2G/UEFI）、.116→.117（40G/40G UEFI→UEFI）、.116→.111（40G→30G 缩容 + UEFI→BIOS + 1G，D27）、**.117 LVM→.116（D28：verify 21 ok、冻结 1.63s、独立引导）**。file 方法、缩容、LVM 源均已闭环；多盘→单盘与单盘→双盘 RAID1 未验证
- ✅ cutover poller 闭环（D27）：systemd-run 瞬态服务（d4b638b）在 .116→.111 上首次实测存活并连回，rollback thaw 成功；同轮修掉四个交付级缺陷（条目计数口径、mawk 科学计数、FITHAW EINVAL、postfix 重建被剪挂载点，015cb8f/68d4da2/796f341/d8d6b66）。⚠ 宿主 TK-Nas 内存不足会 OOM 杀 qemu（D26），开跑前先降 VM 内存/少开 VM；现存机器：.111/.117 已是迁移系统，.116 原系统，.115 原系统在线（重建最终 Live 中）
- ⏳ E2 中继拓扑 E2E（需第三台可达机） · ⏳ 离线模式真机轮（需 donor 引导进 Live）
- 📐 M3=E3：按 D16 实现（agent 位图持久化 + 检查点令牌 + 降级全量）
- 📐 上游边界项：btrfs/ZFS/LUKS/Arch/SUSE（上游明确不支持，按需另立项）
