# arch-install

一个用于快速部署 Arch Linux 的自动化安装脚本，适配 **拯救者 Y9000P 2022（Legion）双硬盘 Windows + Arch Linux 双系统** 场景：

* 一块 NVMe SSD 装 **Windows**（保持原样，脚本**完全不碰**这块盘）
* 另一块 NVMe SSD 装 **Arch Linux**（脚本只在这块盘上分区/格式化）

两块盘各自拥有独立的 EFI 分区和引导程序，互不干扰；开机可按 F12 选盘，或直接进 Arch 的 GRUB 菜单选择 Windows（通过 os-prober 自动检测，只读不改写 Windows 盘）。

> ⚠️ 注意：该脚本会对**所选的目标磁盘**进行分区和格式化操作，请确认备份数据后再使用。选盘时脚本会自动标注哪块盘含有 Windows（NTFS），并要求额外确认，防止误删。

---

## ✨ 功能特性

### 系统安装

* 支持 UEFI 启动模式
* 自动检测 Arch Linux 安装环境
* 自动配置 pacman 镜像源（默认中国区，可用 `MIRROR_COUNTRY` 覆盖）
* GPT 分区方案，全部落在**目标盘**上：
  * 1 GiB EFI 分区
  * Swap 分区（可交互指定大小，休眠建议 ≥ 内存）
  * Btrfs 根分区
* 自动识别 / 拒绝：非 UEFI、非官方 ISO、架构不符、目标盘仍被占用等情况

### 双系统 / 双硬盘支持

* 目标盘与 Windows 盘完全隔离：只在目标盘创建 ESP 并安装 GRUB
* os-prober 自动把 **Windows Boot Manager** 加进 Arch 的 GRUB 菜单（可选关闭，见下方开关）
* Secure Boot 状态检测与提示（GRUB 未签名，开启时需在 BIOS 关闭）
* Windows 盘误选防护：检测到盘上有 NTFS/FAT 分区时会醒目警告并要求输入 `ERASE` 才继续
* 磁盘列表自动标注「哪块盘有 Windows 数据」
* 装完可选把 Arch 设为第一启动项（也可保持 F12 手动选盘）

### Y9000P 2022 硬件适配（默认开启，均可开关）

* **NVIDIA 独显驱动**：`nvidia-open nvidia-utils nvidia-settings nvidia-prime`（RTX 3060 / 3070 Ti；上游自 590 驱动起（2025-12）已用开源内核模块 `nvidia-open` 取代闭源 `nvidia` 包，适用于 Turing / RTX 20 及更新显卡）
* 内核参数追加 `nvidia-drm.modeset=1`（混合显卡 KMS / Wayland 需要）
* NVIDIA 电源管理由驱动内置处理（560+ 起 DRM 默认开启，不再需要旧的 `nvidia-suspend` 等 systemd 单元）
* Alder Lake 声卡固件：`sof-firmware` + `alsa-ucm-conf`（已有）
* Intel 无线/蓝牙：`linux-firmware` + `bluez`（已有）
* TLP 电源管理（已有）

### Btrfs 文件系统布局

```
/
├── @             # 根（Snapper 首次配置时自动在 @ 内创建 .snapshots 子卷存放快照）
└── @home         # 用户目录
```

`.snapshots` 子卷**不预先创建**，由 `snapper create-config` 在安装时自动生成（位于根子卷 @ 之内，开机即挂载为 `/.snapshots`）；配合 grub-btrfs 可从 GRUB 菜单直接启动历史快照。

### 系统配置

自动完成：时区（Asia/Shanghai）、Locale、主机名、用户创建、sudo、NetworkManager、systemd-timesyncd、蓝牙、TLP、休眠 resume（`resume=UUID=…`）、Snapper 定时快照。

### 安装日志 / 彩色进度

全程日志写入 `/tmp/arch-install-<时间戳>.log`，失败时自动提示日志路径。终端状态提示自动着色：`[OK ]` 绿、`[INFO]` 青、`[WARN]` 黄、`[FAIL]` 红加粗（仅在交互式终端生效，且不会污染日志文件）；可用 `NO_COLOR=1` 或 `TERM=dumb` 关闭彩色。

---

## 🔧 可调开关（环境变量，均有默认值）

| 变量 | 默认 | 说明 |
| ---- | ---- | ---- |
| `ENABLE_OS_PROBER` | `1` | 在 Arch GRUB 菜单里加入 Windows 入口。`0` = 完全独立，只靠 F12 选盘 |
| `INSTALL_NVIDIA` | `1` | 安装 NVIDIA 驱动（`nvidia-open` 开源内核模块 + `nvidia-utils` 等；安装失败会自动跳过、不中断安装） |
| `NVIDIA_DRM_MODESET` | `1` | 追加 `nvidia-drm.modeset=1` 内核参数 |
| `MIRROR_COUNTRY` | `CN` | reflector 镜像源国家 |
| `MIRROR_AGE` / `MIRROR_PROTOCOL` | `12` / `https` | reflector 参数 |

示例：`ENABLE_OS_PROBER=0 INSTALL_NVIDIA=0 ./install.sh`

---

## 📦 系统要求

* **Windows 先安装并验证好**在盘 A 上（出厂即装好最佳）
* Arch Linux 官方 ISO（UEFI 方式启动）
* x86_64 架构、UEFI 启动模式
* 已连接互联网、以 root 运行
* 两块 NVMe SSD 均能被系统识别

---

## 🔧 BIOS / 启动介质准备（Y9000P 2022 必读）

1. **关闭 Secure Boot**（F2 进 BIOS → Security / Boot）
   * 出厂 Win11 默认开启，而 Arch 的 GRUB 未签名，不关则装完无法启动 Arch。
   * 关闭不影响现有 Windows 启动。
2. **确认 ISO 里能看到两块 NVMe**
   * 用 Arch ISO 启动后先执行 `lsblk`。若一块/两块内置 NVMe 都不见，通常是 BIOS 存储模式处于 **Intel VMD / RST**：
     * 到 BIOS 中把存储模式从 VMD/RST 改为 **AHCI**；
     * **切换前**必须先让 Windows 适配 AHCI，否则 Windows 会蓝屏：
       1. Windows 管理员命令行执行 `bcdedit /set {current} safeboot minimal`
       2. 重启进 BIOS 改 AHCI → 保存重启（会进入安全模式）
       3. 管理员命令行执行 `bcdedit /deletevalue {current} safeboot`
       4. 再重启一次，Windows 恢复正常
3. （可选）BIOS 显卡模式：混合模式（Hybrid）日常更省电；脚本两种模式都兼容。

> 如果 Windows 与 Arch 谁先装：**推荐 Windows 先装**。脚本全程不写 Windows 盘，因此顺序其实不关键。

---

## 🚀 使用方法

### 1. 启动 Arch Linux ISO（UEFI 模式）

```bash
ping archlinux.org   # 确认网络
```

### 2. 下载安装脚本

```bash
curl -O https://raw.githubusercontent.com/PengWang88/arch-install/main/install.sh
chmod +x install.sh
```

### 3. 运行安装程序

```bash
./install.sh
```

按提示完成：

* 磁盘选择——**对照磁盘列表的自动标注，选「无 Windows 数据」的那块 SSD**（例如 `/dev/nvme1n1`）
* 若误选到含 Windows 的盘，脚本会要求输入 `ERASE` 才会继续
* Swap 大小（休眠请给 ≥ 内存大小）
* 用户名 / 密码
* 是否把 Arch 设为第一启动项

### 4. 安装完成后重启

移除安装 U 盘后重启：

* 若选择了「Arch 设为第一启动项」→ 直接进 GRUB，菜单里有 Arch（含快照项）和 Windows Boot Manager
* 否则按 **F12** 选盘：`Arch` 进 Arch，`Windows Boot Manager` 进 Windows

---

## ⚙️ 分区方案（仅目标盘）

| 分区 | 文件系统 | 大小 | 用途 |
| ---- | ---- | ---- | ---- |
| EFI  | FAT32 | 1 GiB | Arch 自己的 UEFI 引导 |
| Swap | swap  | 交互指定 | 交换空间 / 休眠（resume=UUID） |
| Root | Btrfs | 剩余全部 | 系统数据（含 @、@home 子卷；`@/.snapshots` 由 Snapper 自动创建） |

---

## 🔧 安装后的系统组件与常用操作

脚本会自动配置：Linux Kernel、GRUB、os-prober（Windows 入口）、NetworkManager、Bluetooth、TLP、Snapper、grub-btrfs、NVIDIA 驱动、休眠 resume。

```bash
# 如果 GRUB 菜单里没有 Windows 入口，重新生成一次：
sudo os-prober && sudo grub-mkconfig -o /boot/grub/grub.cfg

# 独显程序（混合显卡下用核显输出，独显跑负载）：
prime-run <command>

# 快照：
sudo snapper list                        # 查看快照
sudo snapper create -d "Before update"   # 手动快照
sudo snapper rollback <编号>              # 回滚

# 如果 Windows 与 Arch 时间相差 8 小时（Windows 管理员命令行执行一次）：
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

---

## 📁 项目结构

```
arch-install
├── install.sh     # 自动安装脚本（双硬盘双系统适配）
└── README.md      # 使用说明
```

---

## ❓ 常见问题

### 会动我的 Windows 盘吗？

不会。脚本只分区/格式化**所选目标盘**；Windows 盘连 ESP 都不会被写入。os-prober 对 Windows 盘只做只读检测。唯一的风险是**手动选错盘**——脚本已加双重防护（列表标注 + 二次 `ERASE` 确认）。

### 为什么 Arch 起不来 / "Verification failed"？

Secure Boot 未关闭。参考上文 BIOS 准备第 1 步。

### ISO 里 lsblk 看不到内置 NVMe？

BIOS 存储模式处于 VMD/RST，需切到 AHCI（切换步骤见上，先让 Windows 进安全模式一次）。

### 双系统时间相差 8 小时？

见上文注册表命令（Linux 默认硬件时钟按 UTC 处理）。

### 想让两块盘完全独立、不用 GRUB 菜单选 Windows？

`ENABLE_OS_PROBER=0 ./install.sh`，之后只用 F12 选盘即可。

### 是否支持 BIOS Legacy 启动？

不支持，仅 UEFI。

### 是否会清空磁盘？

会清空**所选目标盘**，请提前备份。

### 安装失败怎么办？

1. 检查网络、ISO 是否最新
2. 确认 UEFI 启动、Secure Boot 状态
3. 查看日志（脚本运行时会打印日志路径，也可在失败提示中找到）
4. 若失败信息包含 `target not found: nvidia` 或其它 NVIDIA 包缺失：见下方 NVIDIA 常见问题（上游包名已于 2025-12 变更，脚本已适配，通常换镜像重试即可）

---

### 报错 `error: target not found: nvidia`？

Arch 上游在 2025-12 的 590 驱动更新中移除了闭源的 `nvidia` 包，改用开源内核模块 `nvidia-open`（官方支持 Turing / RTX 20 及以上；RTX 30/40/50 与 GTX 16 系均适用）。本脚本已同步改用 `nvidia-open nvidia-utils nvidia-settings nvidia-prime`：

* 若安装时仍报 `target not found: nvidia*`，说明所选镜像的 `extra` 仓库数据过期或不完整，先刷新镜像再重试：
  `reflector --country CN --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist`
  脚本此时会自动跳过 NVIDIA 继续完成安装（日志会给出 WARN 及后续补救命令），不会中断整个安装。
* 若显卡是 Pascal（GTX 10 系）或更老：`nvidia-open` 不支持，需要 AUR 的 `nvidia-580xx-dkms`（可先 `INSTALL_NVIDIA=0 ./install.sh` 完成安装后再手动装）。

---

## 📝 免责声明

本项目用于自动化 Arch Linux 安装流程。由于 Arch Linux 更新频繁，脚本可能受到软件包变化、官方安装流程变化、硬件差异影响。建议在正式使用前先进行测试；破坏性操作前务必确认磁盘选择。

---

## 📄 License

MIT License
