# migrator 中文文档

本目录是 migrator 的用户文档与维护者文档。内容按主题分页，面向两类读者：

- 需要在两台 Linux 主机之间完成整机迁移的操作人员；
- 需要构建迁移 Live、维护代码或运行测试的维护者。

仓库中已有的 `README.md`、`docs/DESIGN.md`、`docs/DECISIONS.md` 保留原貌，作为项目说明与决策留痕；本目录另行成文，不复制其中的口语化表述和连续实测记录。

## 阅读路径

| 目标 | 建议顺序 |
|---|---|
| 第一次使用 | [01 产品概览](01-overview.md) → [02 安装与构建](02-install.md) → [03 快速开始](03-quickstart.md) |
| 选择迁移方式 | [04 迁移模式](04-modes.md) → [09 传输与一致性](09-transfer-and-consistency.md) |
| 审核迁移计划 | [05 阶段与执行流程](05-stages.md) → [07 计划文件](07-plan-file.md) |
| 查询命令行参数 | [06 选项参考](06-options.md) |
| 处理网络与固件 | [08 网络与固件](08-network-and-firmware.md) |
| 验收与切换 | [10 验证与验收](10-verify-and-acceptance.md) |
| 排查故障 | [11 故障排查](11-troubleshooting.md) → [12 常见问题](12-faq.md) |
| 安全与合规评审 | [13 安全与信任边界](13-security.md) → [14 许可与再分发政策](14-license.md) |
| 参与开发与测试 | [维护者文档](maintainers/README.md) |

## 页面索引

### 用户文档

1. [产品概览](01-overview.md)：能力、边界、支持范围与术语。
2. [安装与构建](02-install.md)：从源码安装、从发布包安装、构建 agent 与 Live。
3. [快速开始](03-quickstart.md)：在线、离线与中继三种场景的操作步骤。
4. [迁移模式](04-modes.md)：在线、离线、中继的差异、冻结语义与选择依据。
5. [阶段与执行流程](05-stages.md)：阶段划分、幂等性、退出码、日志与清理。
6. [选项参考](06-options.md)：全部 `-o` 键、默认值、适用模式与限制。
7. [计划文件](07-plan-file.md)：计划文件的节、字段、校验规则与编辑方法。
8. [网络与固件](08-network-and-firmware.md)：网卡命名、MAC、IP 配置、BIOS/UEFI 与 Secure Boot。
9. [传输与一致性](09-transfer-and-consistency.md)：块级/文件级复制、在线增量、冻结与预检。
10. [验证与验收](10-verify-and-acceptance.md)：验证项、试启动、切换模式与验收清单。
11. [故障排查](11-troubleshooting.md)：按症状定位原因与处理步骤。
12. [常见问题](12-faq.md)：能力边界、停机、容量、回滚与恢复。
13. [安全与信任边界](13-security.md)：源主机只读承诺、密钥、中继、日志与发布物。
14. [许可与再分发政策](14-license.md)：上游 MIT 材料、本项目新增部分的专有许可、允许与禁止的行为。

### 维护者文档

- [维护者文档索引](maintainers/README.md)
- [代码结构与数据流](maintainers/architecture.md)
- [清单记录格式](maintainers/inventory-format.md)
- [QEMU 实验台](maintainers/rig.md)
- [迁移 Live 构建](maintainers/live-build.md)
- [测试体系](maintainers/testing.md)
- [发布与安装布局](maintainers/release.md)

## 图示索引

### SVG

| 图示 | 使用页面 | 内容 |
|---|---|---|
| [overview-pipeline.svg](assets/overview-pipeline.svg) | 01、05 | 八阶段迁移流水线与源端只读 |
| [modes-topology.svg](assets/modes-topology.svg) | 04 | 离线、在线、中继三种拓扑 |
| [relay-topology.svg](assets/relay-topology.svg) | 03、04 | 中继端口与控制、数据、切换通道 |
| [online-timeline.svg](assets/online-timeline.svg) | 04、09 | 全量、增量、冻结、预检与最终窗口 |
| [plan-map.svg](assets/plan-map.svg) | 07 | 计划的输入、分段与校验 |
| [nic-rewrite.svg](assets/nic-rewrite.svg) | 08 | 网卡名、MAC 与 IP 的处理边界 |
| [firmware-matrix.svg](assets/firmware-matrix.svg) | 08 | BIOS/UEFI 四种组合 |
| [verify-gate.svg](assets/verify-gate.svg) | 10 | 九项检查与切换门禁 |
| [boottest-overlay.svg](assets/boottest-overlay.svg) | 10 | QEMU 叠加盘试启动 |
| [architecture-layers.svg](assets/architecture-layers.svg) | 维护者：架构 | 代码分层与状态 |
| [rig-topology.svg](assets/rig-topology.svg) | 维护者：实验台 | QEMU 双机拓扑与端口 |
| [live-media.svg](assets/live-media.svg) | 维护者：Live 构建 | ISO 与分区介质引导 |
| [release-layout.svg](assets/release-layout.svg) | 02、维护者：发布 | 两种安装路径与许可文件 |

### Mermaid

Mermaid 图直接写在页面中，支持 GitHub、GitLab 与部分 Markdown 渲染器；纯文本环境下会显示为代码块。

| 页面 | 内容 |
|---|---|
| [03 快速开始](03-quickstart.md) | 场景选择 |
| [05 阶段与执行流程](05-stages.md) | 阶段状态与重试 |
| [06 选项参考](06-options.md) | 选项分组 |
| [09 传输与一致性](09-transfer-and-consistency.md) | 复制方式选择、收敛循环 |
| [11 故障排查](11-troubleshooting.md) | 退出码与阶段分流 |
| [13 安全与信任边界](13-security.md) | 控制、数据与切换通道 |
| [14 许可与再分发政策](14-license.md) | 许可范围 |
| [维护者：代码结构](maintainers/architecture.md) | 数据流、agent 时序 |
| [维护者：清单格式](maintainers/inventory-format.md) | 记录关系 |
| [维护者：实验台](maintainers/rig.md) | 运行时序 |
| [维护者：测试](maintainers/testing.md) | 测试流程 |
| [维护者：发布](maintainers/release.md) | 发布流程 |

## 文档约定

- 源主机称为“源端”或“donor”，目标主机称为“目标端”或“recipient”。
- “迁移 Live”指带有 `/etc/migrator-live-release` 标记的完整迁移环境；基础 Live（仅有 busybox）不满足要求。
- 命令示例中的主机名、设备名、路径均为占位值，执行前应替换为实际值。
- 选项写作 `-o key=value`；表中的键名带等号，便于与命令行对照。
- 退出码以 [05 阶段与执行流程](05-stages.md) 中的表为准。
- 文中的“块级复制”指按文件系统镜像传输；“文件级复制”指按目录树传输。

## 文档维护

修改选项、阶段或计划格式时，应同时更新：

- `bin/migrator` 的使用说明；
- [06 选项参考](06-options.md)；
- [07 计划文件](07-plan-file.md)（涉及计划格式时）；
- 维护者文档中的测试与构建说明（涉及流程时）。

`tests/cases/options.sh` 会检查 `-h` 是否覆盖全部选项；若仓库中存在 `docs/migrator.md`，还会检查该文件是否覆盖全部选项。当前文档以 `docs/wiki/` 为准，因此该检查在缺少 `docs/migrator.md` 时跳过。
