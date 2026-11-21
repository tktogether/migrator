# 维护者文档

本目录面向参与代码、测试、构建与发布的人员。用户操作说明见上级 [中文文档](../README.md)。

## 代码结构

| 路径 | 职责 |
|---|---|
| `bin/migrator` | 命令行入口、阶段调度、tmux、锁、身份打印 |
| `lib/common.sh` | 输出、命令执行、选项注册、状态、锁、清理、退出码 |
| `lib/ssh.sh` | SSH 控制通道、数据通道、身份校验、中继 |
| `lib/bootstrap.sh` | 两端工具检查与安装、agent 分发、版本一致性 |
| `lib/inventory.sh` | 两端只读清单采集与解析器；可独立流式执行 |
| `lib/plan.sh` | 纯规划核心、计划生成、计划校验 |
| `lib/apply.sh` | 目标盘擦除、分区、md/LVM、格式化、指纹 |
| `lib/transfer.sh` | 离线与在线传输、fsck/扩容、预检、agent 驱动 |
| `lib/target.sh` | 目标树的挂载、卸载与 chroot |
| `lib/postfix.sh` | 目标系统配置修补、文件改写、引导器安装 |
| `lib/netfix.sh` | 网卡重命名与 MAC 改写 |
| `lib/verify.sh` | 只读验证、试启动、切换 |
| `agent/` | 静态 C agent：serve、pull、写追踪、冻结、轮询 |
| `tools/` | 安装器、自包含引导、中继隧道、agent 测试 |
| `rig/` | QEMU 实验台、Live 与 donor 构建、端到端脚本 |
| `tests/` | shellcheck 与表驱动测试 |

## 核心不变量

修改代码时应保持以下不变量：

1. **源端磁盘只读**。任何新功能都不得写入源端块设备。
2. **计划是纯函数**。`plan_compute` 不访问磁盘、不读取 `$RUN`、不依赖环境变量；它只接收两份清单与选项。
3. **写入目标盘前必须通过 `plan_check`**。`apply` 不得绕过计划校验。
4. **验证失败不得切换**。退出码 3 必须阻止 `cutover`，除非显式 `force=1`。
5. **阶段幂等**。重复执行不得产生重复写入、重复格式化或重复配置。
6. **状态可丢失**。`/run/migrator` 是临时状态；重启后允许从头执行，不依赖持久状态。
7. **退出码唯一**。只在 `lib/common.sh` 定义，文档与测试引用同一张表。
8. **选项注册唯一**。新增选项必须同时更新注册表、使用说明、文档与测试。
9. **日志可重放**。命令以 `+ ` / `+ donor: ` 前缀完整记录。
10. **无内置下载地址**。发布物由部署方托管，安装器只使用 `MIGRATOR_URL`。

## 开发入口

| 任务 | 阅读 |
|---|---|
| 理解整体设计 | [代码结构与数据流](architecture.md) |
| 修改清单解析 | [清单记录格式](inventory-format.md) |
| 运行或扩展测试 | [测试体系](testing.md) |
| 构建迁移 Live | [迁移 Live 构建](live-build.md) |
| 复现端到端问题 | [QEMU 实验台](rig.md) |
| 生成发布物 | [发布与安装布局](release.md) |

## 修改约定

### 新增 `-o` 选项

1. 在 `lib/common.sh` 的 `MIGRATOR_OPTS_*` 注册表中加入键名；
2. 在 `bin/migrator` 的使用说明中加入同一键名；
3. 在读取处使用 `opt key default`，不要直接读环境变量；
4. 更新 [选项参考](../06-options.md)；
5. 在 `tests/cases/options.sh` 的覆盖范围内验证；
6. 非法值应在对应阶段以退出码 2 或 4 拒绝，不得静默忽略。

### 新增阶段

1. 在 `bin/migrator` 的 `case $CMD` 中加入阶段；
2. 定义 `phase_*` 入口，并调用 `phase_done`；
3. 前置条件缺失时以退出码 2 拒绝；
4. 在 `cmd_all` 中按顺序接入；
5. 更新 [阶段与执行流程](../05-stages.md) 与退出码说明；
6. 增加至少一个表驱动测试或 seam 测试。

### 修改计划格式

1. 在 `lib/plan.sh` 的 `pc_emit` 中输出新字段；
2. 在 `plan_check` 中加入对应校验；
3. 更新全部 `tests/fixtures/*/expected.plan`；
4. 更新 [计划文件](../07-plan-file.md)；
5. 确认 `apply`、`postfix`、`verify` 对旧计划的行为。

### 修改传输方式

1. 保持 `transfer_run` 对 `block`、`files`、`esp`、`mkswap`、`pv` 的分派；
2. 失败必须留下可重做的卷状态；
3. 写入目标设备前必须经过指纹检查；
4. 在线模式必须保留冻结、轮询与解冻路径；
5. 更新 [传输与一致性](../09-transfer-and-consistency.md)。

### 重命名标识

项目曾从上游名称整体迁移到 `migrator`。再次改名时至少检查：

- `bin/migrator` 与 `agent/migrator-agent` 的文件名、安装路径；
- `MIGRATOR_*` 环境变量；
- `/run/migrator`、`/mnt/migrator`、`/var/lib/migrator`；
- `/etc/migrator-migrated`、`/etc/migrator-live-release`；
- 瞬态单元名 `migrator-poller-*`；
- 两端握手字符串 `MIGRATOR-POLL` 及其解析偏移；
- 正则与路径中的带点名称；
- 测试夹具：夹具是证据，不应随意修改；若必须修改，应只改与改名相关的字段，并核对清单哈希；
- 文档中的链接与命令。

改名后必须执行完整测试，并核对 `-h` 的选项列表。

## 相关文档

- [代码结构与数据流](architecture.md)
- [测试体系](testing.md)
- [QEMU 实验台](rig.md)
- [迁移 Live 构建](live-build.md)
- [发布与安装布局](release.md)
