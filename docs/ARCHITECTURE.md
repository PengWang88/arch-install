# arch-install 架构设计

把现在的单文件 `install.sh`（856 行，一次性做完「ISO 检测 → 分区 → pacstrap → 配置 → GRUB」）
拆成 **两个入口 + 共享库 + 阶段脚本 + 插件式组件脚本** 四层结构。

核心原则：**系统安装（破坏性、一次性、ISO 内）** 与 **组件安装（幂等、可反复、装好后）**
彻底分离，前者是后者的前置，后者互不依赖。

---

## 1. 设计目标

| 目标 | 说明 |
| ---- | ---- |
| 职责分离 | ISO 安装流程 vs. 装好系统后的软件装配，两条独立入口 |
| 可组合 | 组件脚本按需挑选，支持单个 / 分类 / 预设组合 / 全量 |
| 幂等 | 任何组件脚本重复执行安全；已安装则跳过（`--force` 可强制重跑） |
| 零额外依赖 | 纯 bash + 官方仓库工具；不依赖 whiptail/dialog/python |
| 可脚本化 | 所有交互都能用命令行参数 + 配置文件绕过（无人值守） |
| 可发现 | 往 `components/<分类>/` 丢一个 `.sh` 就自动出现在菜单与 `--list` 里 |
| 可回退 | 每个阶段/组件独立可重跑；失败即停并给出下一步命令 |
| 可测试 | 组件有 `check` 阶段，支持 `--dry-run`，便于 VM 验证 |

---

## 2. 目录结构

```
arch-install/
├── install.sh                      # 入口①：系统安装（Arch ISO 环境，root）
├── setup.sh                        # 入口②：组件安装与管理（已装好的系统）
├── bootstrap.sh                    # 引导：拉取仓库 tarball 后调用上面两个入口之一
├── README.md
├── LICENSE
│
├── lib/                            # 共享库（两个入口都 source，不含业务流程）
│   ├── bootstrap.sh                #   统一加载器：探测运行环境 + 按序 source 其余 lib
│   ├── config.sh                   #   默认值 / 环境变量 / 配置文件解析与优先级
│   ├── log.sh                      #   日志分级、颜色、日志文件 tee
│   ├── error.sh                    #   trap、die、错误上下文、可选中止清理
│   ├── ui.sh                       #   提问 / 确认 / 选择 / 密码 / 菜单 / 进度
│   ├── check.sh                    #   环境断言（root/archiso/arch/uefi/secureboot/net/time）
│   ├── pkg.sh                      #   pacman / pacstrap / AUR helper 封装，包存在性判断
│   ├── system.sh                   #   arch-chroot 执行、systemd 单元、用户组、文件写入
│   ├── disk.sh                     #   块设备枚举、校验、分区、格式化、挂载
│   ├── state.sh                    #   安装状态记录与查询（断点续跑 / 组件已装判定）
│   └── component.sh                #   组件框架：发现、元数据校验、依赖解析、调度执行
│
├── stages/                         # 系统安装各阶段（仅 install.sh 调用，ISO 内运行）
│   ├── 00-preflight.sh             #   环境检查（root/archiso/arch/uefi/secureboot/网络/时间）
│   ├── 10-mirrors.sh               #   固定中国镜像列表 + 可用性探测
│   ├── 20-disk.sh                  #   列盘 / 选盘 / 校验 / 二次确认
│   ├── 30-partition.sh             #   GPT 分区（1G ESP + Btrfs root）+ 格式化
│   ├── 40-mount.sh                 #   btrfs 子卷 @、@home 创建与挂载
│   ├── 50-pacstrap.sh              #   基础包安装（含 CPU microcode 自动识别）
│   ├── 60-fstab.sh                 #   genfstab
│   ├── 70-system-config.sh         #   chroot：时区/locale/hostname/hosts/服务启用
│   ├── 80-user.sh                  #   用户创建、密码、sudoers
│   ├── 90-bootloader.sh            #   GRUB 安装、os-prober、UEFI 启动顺序
│   └── 99-finish.sh                #   同步、卸载、安装总结与后续提示
│
├── components/                     # 组件（仅 setup.sh 调用，装好的系统内运行）
│   ├── _template.sh                #   新组件模板（含元数据头与生命周期函数骨架）
│   ├── 00-base/                    #   基础系统增强
│   ├── 10-hardware/                #   硬件与驱动
│   ├── 20-desktop/                 #   桌面环境 / 窗口管理器
│   ├── 30-i18n/                    #   中文环境
│   ├── 40-dev/                     #   开发环境
│   ├── 50-gaming/                  #   游戏与性能
│   └── 60-apps/                    #   日常软件
│
├── config/
│   ├── arch-install.conf.example   #   全局配置模板（系统安装 + 组件选择）
│   └── presets/                    #   预设组合，直接 --preset 使用
│       ├── minimal.conf
│       ├── laptop-y9000p.conf
│       └── full-desktop.conf
│
├── scripts/                        # 开发/维护脚本（终端用户不需要）
│   ├── lint.sh                     #   shellcheck + 元数据头校验 + 命名规范校验
│   ├── build-release.sh            #   可选：拼接出单文件发行版 install.sh
│   └── test-vm.sh                  #   可选：QEMU 里跑无人值守安装冒烟测试
│
└── docs/
    ├── ARCHITECTURE.md             #   本文件
    ├── ROADMAP.md                  #   实现清单（分阶段 + 组件清单）
    └── COMPONENT-SPEC.md           #   组件开发规范（写组件前必读）
```

**文件数对比**：现在 2 个 → 重构后约 147 个（其中组件脚本 110 个，占大头且可增量补充，
不必一次写完，按 [ROADMAP.md](ROADMAP.md) 的 P0/P1/P2 分批做）。

> 阶段脚本刻意保持「一个阶段一个文件」的粒度，便于单独重跑与阅读；
> 如果觉得太碎，可以把 `30-partition.sh` + `40-mount.sh` 合并为 `30-disk-layout.sh`。

---

## 3. 运行环境边界

这是整个设计最重要的一条分界线：

| | `install.sh`（系统安装） | `setup.sh`（组件安装） |
| --- | --- | --- |
| 运行环境 | Arch ISO live 环境 | 已安装并启动的 Arch |
| 权限 | 必须 root | root（`sudo ./setup.sh`） |
| 破坏性 | 会格式化目标盘 | 只装包/写配置，不做破坏性操作 |
| 幂等 | 否（一次性流程，支持断点续跑） | 是（核心要求） |
| 依赖 | `arch-chroot`/`pacstrap`/`sgdisk`/`btrfs` | `pacman` + 可选 AUR helper |
| 状态目录 | `/tmp/arch-install-state/` | `/var/lib/arch-install/` |
| 日志 | `/tmp/arch-install-<ts>.log` | `/var/log/arch-install/<ts>.log` |

组件脚本**不要求**能在 chroot 内运行。系统安装阶段只装「让机器能起来并联网的最小集合」，
其余一切（桌面、驱动、中文、开发、游戏、日常软件）都在 `setup.sh` 里按需装配。

---

## 4. 入口设计

### 4.1 `install.sh` — 系统安装

```bash
./install.sh                      # 全交互（保持现有体验）
./install.sh --config my.conf     # 读配置文件，减少提问
./install.sh --disk /dev/nvme1n1 --hostname legion --user peng --yes
./install.sh --from 30-partition  # 从指定阶段续跑（失败后重试）
./install.sh --dry-run            # 只打印将要执行的操作
./install.sh --list-stages
```

流程：`lib/bootstrap.sh` → 解析参数/配置 → 按序执行 `stages/*.sh` → `99-finish.sh` 总结。

每个阶段脚本导出一个 `stage_run` 函数，由 `install.sh` 统一调度（打点、计时、失败中断、
记录完成状态以便 `--from` 续跑）。

### 4.2 `setup.sh` — 组件安装

```bash
./setup.sh                                  # 交互式菜单（分类 → 组件多选）
./setup.sh --list                           # 列出全部组件及安装状态
./setup.sh --list hardware                  # 只看某个分类
./setup.sh --info nvidia-open               # 组件详情（包、依赖、是否需要重启）
./setup.sh --install nvidia-open,fcitx5     # 按 id 安装（自动解析依赖、拓扑排序）
./setup.sh --category hardware              # 交互式挑选某分类
./setup.sh --preset laptop-y9000p           # 按预设组合安装
./setup.sh --all                            # 全量安装
./setup.sh --check nvidia-open              # 只检查是否已安装（退出码 0/1）
./setup.sh --reboot-check                   # 列出「装了但还没重启」的组件
./setup.sh --force nvidia-open              # 忽略已装标记，强制重跑
./setup.sh --dry-run --install kde          # 预演
./setup.sh --yes                            # 不提问（配合 --install）
```

---

## 5. 共享库（lib/）职责与接口

| 文件 | 职责 | 主要对外接口 |
| ---- | ---- | ---- |
| `bootstrap.sh` | 定位仓库根目录、校验 bash 版本、按依赖顺序 source 其余 lib、设置 `set -Eeuo pipefail`、安装全局 trap | `ARCH_INSTALL_ROOT`、`arch_install::load` |
| `config.sh` | 配置优先级：CLI 参数 > 环境变量 > `--config` 文件 > `config/arch-install.conf` > 内置默认值 | `config_get`、`config_set`、`config_load_file`、`config_dump` |
| `log.sh` | 四级日志 + 颜色（`NO_COLOR`/`TERM=dumb` 关闭）+ 日志文件 tee + 退出时剥离 ANSI | `info` `ok` `warn` `die` `log_cmd` |
| `error.sh` | `ERR`/`INT`/`EXIT` trap、失败行号与日志路径提示、可选清理钩子 | `on_error`、`register_cleanup` |
| `ui.sh` | 交互原语，全部支持「非交互回退到默认值」 | `ask`、`ask_yes_no`、`ask_secret`、`ask_choice`、`select_multi`、`confirm_destructive` |
| `check.sh` | 纯断言函数，失败即 `die`，不产生副作用 | `require_root`、`require_archiso`、`require_uefi`、`require_network`、`check_time`、`check_secure_boot` |
| `pkg.sh` | 包管理封装：先探测已装避免重复下载；AUR 统一走 helper | `pkg_installed`、`pkg_install`、`pkg_install_aur`、`aur_helper`、`pacstrap_base` |
| `system.sh` | chroot 与系统层操作 | `chroot_run`、`chroot_write`、`svc_enable`、`user_exists`、`write_file`、`sed_inplace` |
| `disk.sh` | 块设备操作，全部经过校验 | `list_disks`、`validate_disk`、`is_live_device`、`partition_gpt`、`make_filesystems`、`mount_layout` |
| `state.sh` | 状态文件读写（组件已装、阶段已完成） | `state_mark`、`state_is_done`、`state_list`、`state_clear` |
| `component.sh` | 组件框架（见第 7 节） | `component_discover`、`component_meta`、`component_resolve_deps`、`component_run`、`component_list` |

lib 之间不循环依赖，加载顺序固定：`log → error → config → ui → check → pkg → system → disk → state → component`。

---

## 6. 阶段脚本（stages/）

每个 `stages/NN-name.sh` 只是一个可 `source` 的文件，定义 `stage_run`，不自己解析参数、不自己
初始化日志。现有 `install.sh` 的映射关系：

| 现 `install.sh` 函数 | 迁移到 |
| ---- | ---- |
| `setup_color` `init_logging` `log`/`info`/`ok`/`warn`/`die` `on_error` `on_interrupt` `get_version` | `lib/log.sh`、`lib/error.sh` |
| `require_command` `check_root` `check_archiso` `check_architecture` `check_uefi` `check_secure_boot` `check_network` `check_time` | `lib/check.sh` + `stages/00-preflight.sh` |
| `write_mirrorlist` `mirror_is_reachable` `setup_mirrors` | `stages/10-mirrors.sh` |
| `get_live_device` `list_disks` `validate_disk` `is_live_device` `select_disk` `confirm_disk` | `lib/disk.sh` + `stages/20-disk.sh` |
| `cleanup_disk_state` `assert_disk_unused` `get_partition_name` `partition_disk` | `lib/disk.sh` + `stages/30-partition.sh` |
| `mount_filesystems` | `stages/40-mount.sh` |
| `get_microcode_package` `install_base_system` | `stages/50-pacstrap.sh` |
| `generate_fstab` | `stages/60-fstab.sh` |
| `configure_system` | `stages/70-system-config.sh` |
| `create_user` | `stages/80-user.sh` |
| `install_grub` `reorder_boot_entries` | `stages/90-bootloader.sh` |
| `finish_installation` | `stages/99-finish.sh` |
| `main` | `install.sh`（调度器） |

迁移要求：**行为等价**。特别要保留现有这些刻意的取舍（README 已承诺）：
不建 swap、不配置快照、不装独显驱动、脚本不识别 Windows 分区、仅 UEFI、
btrfs 布局 `@` / `@home` 且 `/.snapshots` 留空。

---

## 7. 组件模型（components/）

### 7.1 文件命名

`components/<分类目录>/<id>.sh`，`id` 小写、用 `-` 连接、全局唯一，且必须与 `#@id` 一致
（`scripts/lint.sh` 会校验）。分类目录前缀 `00-`~`60-` 只用于排序展示。

### 7.2 元数据头

组件文件顶部用 `#@` 注释声明元数据 —— **可被 grep/awk 解析，无需 source 就能列清单**：

```bash
#!/usr/bin/env bash
#@id:          nvidia-open
#@name:        NVIDIA 专有驱动（Turing / RTX 20 系及更新）
#@category:    hardware
#@deps:        base-devel
#@conflicts:   nvidia-legacy
#@reboot:      yes
#@root:        yes
#@aur:         no
#@desc:        nvidia-open + utils + settings + prime，并追加 DRM KMS 内核参数
```

| 字段 | 必需 | 说明 |
| ---- | ---- | ---- |
| `id` | ✅ | 唯一标识，用于 `--install <id>` |
| `name` | ✅ | 菜单显示名 |
| `category` | ✅ | 必须等于所在目录名 |
| `desc` | ✅ | 一句话说明 |
| `deps` | ❌ | 逗号分隔的其他组件 id，框架拓扑排序 |
| `conflicts` | ❌ | 互斥组件，同时选中则报错 |
| `reboot` | ❌ | `yes` 表示装完需要重启（`--reboot-check` 汇总提醒） |
| `root` | ❌ | `yes`（默认）表示必须 root |
| `aur` | ❌ | `yes` 表示需要 AUR helper，缺失时自动先装 `yay` |

### 7.3 生命周期函数

```bash
component_check()   { ... }   # 必需。返回 0 = 已安装（跳过），1 = 未安装。
                              # 这是幂等的唯一权威依据，状态文件只是快取。
component_install() { ... }   # 必需。实际安装动作，失败即 return 非 0。
component_post()    { ... }   # 可选。启用服务、写配置、提示重启等收尾。
```

约定：

* 组件文件被 `source` 时**不允许**有顶层副作用（只允许注释、变量赋值、函数定义）。
* 组件只能通过 `lib/pkg.sh`、`lib/system.sh` 操作宿主，不自己调裸 `pacman`（便于 dry-run 与日志）。
* 组件不提问、不 `exit`；需要用户输入时用 `lib/ui.sh`，`--yes` 下走默认值。
* 组件不互相调用，跨组件协调一律通过 `deps` 表达。

### 7.4 框架行为

`lib/component.sh::component_run <id>` 依次做：
1. 解析元数据并校验（id/分类匹配、deps 存在、conflicts 冲突检测）
2. 检查 `root` 要求；`aur=yes` 且无 helper 时自动先装 `yay`
3. 跑 `component_check`；已装且未 `--force` → 打印 `[SKIP]` 并返回
4. `--dry-run` → 只打印将要执行的动作，不落盘
5. 执行 `component_install` → `component_post`
6. 成功写 `/var/lib/arch-install/components/<id>.done`（含时间戳与版本）
7. 若 `reboot=yes`，写入待重启列表

失败时：打印失败组件 id、日志路径、可直接复制重试的命令，然后中止（除非 `--keep-going`）。

### 7.5 状态与幂等

```
/var/lib/arch-install/
├── components/<id>.done      # 组件完成标记
├── pending-reboot            # 需要重启的组件列表
└── install.json              # 系统安装信息（磁盘、布局、时间）
```

两个用途：`--list` 快速显示状态；`setup.sh` 无参数时提示「有 N 个组件等重启」。
真正的幂等判定始终以 `component_check()` 为准，避免状态文件与实际系统漂移。

---

## 8. 配置系统

优先级从高到低：**命令行参数 > 环境变量 > `--config` 指定文件 > `config/arch-install.conf` > 内置默认值**。
`config/arch-install.conf.example` 是纯 shell 变量文件（`key=value`，可被 `source`）：

```bash
# ---- 系统安装 ----
ARCH_HOSTNAME="archlinux"
ARCH_TIMEZONE="Asia/Shanghai"
ARCH_LOCALES=(en_US.UTF-8 zh_CN.UTF-8)
ARCH_LANG="en_US.UTF-8"
ARCH_DISK=""                       # 留空则交互选择
ARCH_EFI_SIZE="1G"
ARCH_BTRFS_OPTS="noatime,compress=zstd:3,discard=async"
ARCH_MIRROR_COUNTRY="CN"
ARCH_MIRROR_URLS="ustc aliyun nju huaweicloud tencent cernet tuna"
ARCH_ENABLE_OS_PROBER=1

# ---- 组件 ----
ARCH_COMPONENTS=(zram fcitx5 kde-plasma nvidia-open)
ARCH_SKIP_COMPONENTS=()
```

兼容性：现有 `MIRROR_COUNTRY` / `ENABLE_OS_PROBER` 等环境变量继续识别（作为 `ARCH_*` 的别名），
不破坏已有用法。镜像源改为固定列表后，`MIRROR_AGE` / `MIRROR_PROTOCOL` 不再需要（已移除）。

预设放 `config/presets/*.conf`，只声明 `ARCH_COMPONENTS`，用 `--preset <名>` 加载。

---

## 9. 分发方式

拆成多文件后，README 里 `curl -O install.sh` 的单文件用法失效，需要明确分发策略：

| 方式 | 场景 | 命令 |
| ---- | ---- | ---- |
| 引导脚本（推荐） | ISO 内，无 git | `curl -fsSL .../bootstrap.sh \| bash` → 下载 tarball 到 `/root/arch-install` 并调用 `install.sh` |
| git clone | 有 git 的环境 | `git clone ... && cd arch-install && ./install.sh` |
| 单文件发行版（可选） | 想要旧体验 | `scripts/build-release.sh` 把 lib + stages 拼接成一个自包含 `install.sh` |
| 组件侧 | 装好系统后 | `bootstrap.sh setup` → clone 到 `/opt/arch-install` 并调用 `setup.sh` |

---

## 10. 安全与可靠性

保留并强化现有设计：

* 所有破坏性操作前打印目标盘现状与将创建的分区布局，要求输入 `YES`（`ui.sh::confirm_destructive`）。
* `lib/disk.sh` 拒绝：非块设备、非 `disk` 类型、承载 live ISO 的盘、仍有挂载点的盘。
* 系统安装的 `--yes` **不**跳过磁盘确认（需要额外的 `--i-know-what-im-doing` 才行）。
* 组件安装不做破坏性操作；配置类改动先备份为 `*.bak.<时间戳>`。
* 全程日志落盘，失败时最后一行给出日志路径与重试命令。
* `scripts/lint.sh` 在提交前跑 `shellcheck`；CI（可选）跑 lint + `--dry-run` 冒烟。

---

## 11. 非目标（明确不做）

* 不支持 BIOS/Legacy 启动（维持仅 UEFI）。
* 不识别、不写入、不修改 Windows 盘（os-prober 仅只读检测）。
* 不建 swap 分区、不配置休眠（需要的话由组件 `zram` 或可选 `swapfile` 组件提供）。
* 组件脚本不负责 chroot 内安装（不做 `/mnt` 前缀适配）。
* 不托管第三方 dotfiles 内容本身，只做「拉取并链接」。
