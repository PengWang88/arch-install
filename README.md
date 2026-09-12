# arch-install

一个用于快速部署 Arch Linux 的自动化安装脚本，适配 **拯救者 Y9000P 2022（Legion）双硬盘 Windows + Arch Linux 双系统** 场景：

* 一块 NVMe SSD 装 **Windows**（保持原样，脚本**完全不碰**这块盘）
* 另一块 NVMe SSD 装 **Arch Linux**（脚本只在这块盘上分区/格式化）

两块盘各自拥有独立的 EFI 分区和引导程序，互不干扰；开机可按 F12 选盘，或直接进 Arch 的 GRUB 菜单选择 Windows（通过 os-prober 自动检测，只读不改写 Windows 盘）。

> ⚠️ 注意：该脚本会对**所选的目标磁盘**进行分区和格式化操作，请确认备份数据后再使用。**脚本不做任何 Windows 分区识别**——选盘完全由你负责，务必对照磁盘列表（型号/容量/序列号）确认选对盘再输入 `YES`。

---

## ✨ 功能特性

### 系统安装

* 支持 UEFI 启动模式
* 自动检测 Arch Linux 安装环境
* 自动配置 pacman 镜像源：写入固定的中国镜像列表（不再调用 reflector 做联网测速排序），按序探测并自动剔除不可达的源
* GPT 分区方案，全部落在**目标盘**上：
  * 1 GiB EFI 分区
  * Btrfs 根分区（占剩余全部空间）
* **不创建 swap 分区、不使用 swapfile**：系统不使用磁盘交换空间，因此**不支持休眠到磁盘（hibernate）**；日常挂起（suspend-to-RAM / s2idle）不受影响。若需要内存紧张时的兜底，可在装好后自行启用 `zram`（见下文）
* 自动识别 / 拒绝：非 UEFI、非官方 ISO、架构不符、目标盘仍被占用等情况

### 双系统 / 双硬盘支持

* 目标盘与 Windows 盘完全隔离：只在目标盘创建 ESP 并安装 GRUB
* os-prober 自动把 **Windows Boot Manager** 加进 Arch 的 GRUB 菜单（可选关闭，见下方开关）
* Secure Boot 状态检测与提示（GRUB 未签名，开启时需在 BIOS 关闭）
* 选盘前打印全量磁盘列表（路径/容量/型号/序列号），选错盘的风险由人工承担——脚本不识别 Windows 分区
* 装完可选把 Arch 设为第一启动项（也可保持 F12 手动选盘）

### Y9000P 2022 硬件适配

* **不安装任何独立显卡驱动**：系统使用内核自带的 Intel 核显驱动（i915）+ `linux-firmware`。RTX 独显不会被驱动，保持空闲不耗电；需要时见 [安装独显驱动](#安装独显驱动可选)
* Alder Lake 声卡固件：`sof-firmware` + `alsa-ucm-conf`（已有）
* Intel 无线/蓝牙：`linux-firmware` + `bluez`（已有）
* TLP 电源管理（已有）

### Btrfs 文件系统布局

```
/
├── @             # 根
└── @home         # 用户目录
```

布局是**快照就绪**的，但安装时**不启用快照**：`/.snapshots` 子卷不会被创建。若以后想用 Snapper + grub-btrfs 从 GRUB 菜单启动历史快照，见 [安装后启用快照](#安装后启用快照)。

### 系统配置

自动完成：时区（Asia/Shanghai）、Locale、主机名、用户创建、sudo、NetworkManager、systemd-timesyncd、蓝牙、TLP。**不修改 GRUB 内核参数**（保留发行版默认的 `loglevel=3 quiet`）。

### 安装日志 / 彩色进度

全程日志写入 `/tmp/arch-install-<时间戳>.log`，失败时自动提示日志路径。终端状态提示自动着色：`[OK ]` 绿、`[INFO]` 青、`[WARN]` 黄、`[FAIL]` 红加粗（仅在交互式终端生效，且不会污染日志文件）；可用 `NO_COLOR=1` 或 `TERM=dumb` 关闭彩色。

---

## 🔧 可调开关（环境变量，均有默认值）

| 变量 | 默认 | 说明 |
| ---- | ---- | ---- |
| `ENABLE_OS_PROBER` | `1` | 在 Arch GRUB 菜单里加入 Windows 入口。`0` = 完全独立，只靠 F12 选盘 |

示例：`ENABLE_OS_PROBER=0 ./install.sh`

### 关于镜像源

`install.sh` 中的 `MIRROR_URLS` 数组是**唯一**的镜像配置入口，默认按顺序使用：

```
mirrors.ustc.edu.cn → mirrors.aliyun.com → mirrors.nju.edu.cn
→ mirrors.huaweicloud.com → mirrors.cloud.tencent.com
→ mirrors.cernet.edu.cn → mirrors.tuna.tsinghua.edu.cn
```

安装时脚本会逐个请求 `core/os/x86_64/core.db` 探测可用性，只把能正常响应的源写入 `/etc/pacman.d/mirrorlist`（原文件备份为 `mirrorlist.iso-backup`）。因此某个源被网络屏蔽（例如返回 403）时会自动跳过，而不是让整个安装失败。想增删或调整优先级，直接改这个数组即可。

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

* 磁盘选择——脚本会打印所有磁盘（路径/容量/型号/序列号），**由你对照确认哪块是装 Arch 的盘**（例如 `/dev/nvme0n1`）；输入盘符后会再显示一次该盘现状与将要创建的分区布局，要求输入 `YES` 确认
* ⚠️ 脚本不识别盘上是否有 Windows，**选错盘 = 该盘数据全部丢失**。拿不准就先在 Live 环境执行 `lsblk -o NAME,SIZE,MODEL,FSTYPE` 自己核对
* 用户名 / 密码
* 是否把 Arch 设为第一启动项

### 4. 安装完成后重启

移除安装 U 盘后重启：

* 若选择了「Arch 设为第一启动项」→ 直接进 GRUB，菜单里有 Arch 和 Windows Boot Manager
* 否则按 **F12** 选盘：`Arch` 进 Arch，`Windows Boot Manager` 进 Windows

---

## ⚙️ 分区方案（仅目标盘）

| 分区 | 文件系统 | 大小 | 用途 |
| ---- | ---- | ---- | ---- |
| EFI  | FAT32 | 1 GiB | Arch 自己的 UEFI 引导 |
| Root | Btrfs | 剩余全部 | 系统数据（含 @、@home 子卷） |

> 本方案**没有 swap 分区**。因此：不支持休眠到磁盘；内存不足时由内核 OOM killer 直接回收。若希望有内存压缩兜底，可在装好系统后启用 zram（**不需要** swap 分区或 swapfile）：
>
> ```bash
> sudo pacman -S zram-generator
> sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
> [zram0]
> zram-size = ram / 2
> EOF
> sudo systemctl daemon-reload && sudo systemctl start systemd-zram-setup@zram0.service
> ```

---

## 🔧 安装后的系统组件与常用操作

脚本会自动配置：Linux Kernel、GRUB、os-prober（Windows 入口）、NetworkManager、Bluetooth、TLP。**不安装任何独立显卡驱动，也不安装/配置 Snapper 与 grub-btrfs。**

```bash
# 如果 GRUB 菜单里没有 Windows 入口，重新生成一次
# （grub-mkconfig 会自动调用 os-prober）：
sudo grub-mkconfig -o /boot/grub/grub.cfg

# 如果 Windows 与 Arch 时间相差 8 小时（Windows 管理员命令行执行一次）：
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

### 安装独显驱动（可选）

脚本刻意**不碰独显**：装完直接用 Intel 核显（i915）就已经有完整桌面、视频和 Wayland 支持，RTX 独显不被驱动、保持空闲。需要独显跑游戏 / CUDA 时再手动装：

```bash
# 1) 装驱动（RTX 20 系 / GTX 16 系及更新适用）
sudo pacman -Syu
sudo pacman -S nvidia-open nvidia-utils nvidia-settings nvidia-prime

# 2) 追加 DRM KMS 内核参数（混合显卡下 Wayland / rootless Xorg 需要）
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet nvidia-drm.modeset=1"|' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg

# 3) 重建 initramfs 并重启
sudo mkinitcpio -P
sudo reboot

# 4) 验证
nvidia-smi
prime-run glxinfo | grep "OpenGL renderer"   # 应显示 NVIDIA
```

> * 需要 Turing（RTX 20 / GTX 16）及更新的显卡；更老的 Pascal（GTX 10 系）要用 AUR 的 `nvidia-580xx-dkms`。
> * 装驱动后**必须重启**，DRM KMS 参数只在启动时生效；务必先 `grub-mkconfig` 再重启。
> * 混合显卡下默认仍由核显输出，用 `prime-run <命令>` 让指定程序跑在独显上。
> * 想撤销：`sudo pacman -Rns nvidia-open nvidia-utils nvidia-settings nvidia-prime`，并删掉上面那段内核参数后重新 `grub-mkconfig`。不装驱动时系统没有 nouveau，也不会与 NVIDIA 模块冲突。

### 安装后启用快照

脚本不配置快照，但 Btrfs 布局（`@` / `@home`）是快照就绪的。需要时在 Arch 里执行：

```bash
sudo pacman -S snapper grub-btrfs inotify-tools

# 让 snapper 自己创建 /.snapshots 子卷（该目录必须尚不存在！）
sudo snapper --no-dbus -c root create-config /
sudo chmod 750 /.snapshots

# 定时快照与自动清理（可选）
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

# 让 GRUB 菜单出现快照启动项
sudo systemctl enable --now grub-btrfsd.service
sudo grub-mkconfig -o /boot/grub/grub.cfg

# 使用：
sudo snapper list                        # 查看快照
sudo snapper create -d "Before update"   # 手动快照
sudo snapper rollback <编号>              # 回滚
```

> ⚠️ `snapper create-config` 在 `/.snapshots` 已存在时会失败（`File exists`）。所以**不要**手动预建该目录——本安装脚本也刻意不创建它。

---

## 📁 项目结构

**当前**（单文件版本，可正常使用）：

```
arch-install
├── install.sh              # 自动安装脚本（双硬盘双系统适配）
├── README.md               # 使用说明
└── docs/
    ├── ARCHITECTURE.md     # 重构后的目标架构设计
    └── ROADMAP.md          # 实现清单（分阶段 + 组件清单）
```

**目标结构**（重构进行中）：项目将拆成 **系统安装脚本 + 组件/软件安装脚本** 两层：

```
arch-install
├── install.sh              # 入口①：系统安装（Arch ISO 环境，root）
├── setup.sh                # 入口②：组件安装与管理（已装好的系统）
├── bootstrap.sh            # 引导：拉取仓库后调用上面两个入口
├── lib/                    # 共享库：日志/配置/交互/pacman/磁盘/组件框架
├── stages/                 # 系统安装各阶段（检测→镜像→分区→挂载→pacstrap→配置→引导）
├── components/             # 组件脚本，按分类存放，放入即自动发现
│   ├── 00-base/            #   基础系统增强（AUR helper、zram、快照、防火墙…）
│   ├── 10-hardware/        #   硬件与驱动（NVIDIA、蓝牙、声卡、风扇、键盘灯…）
│   ├── 20-desktop/         #   桌面环境 / 窗口管理器（KDE、GNOME、Hyprland…）
│   ├── 30-i18n/            #   中文环境（字体、fontconfig、fcitx5…）
│   ├── 40-dev/             #   开发环境（语言运行时、容器、编辑器…）
│   ├── 50-gaming/          #   游戏与性能（Steam、gamemode、MangoHud…）
│   └── 60-apps/            #   常用日常软件（浏览器、办公、影音、聊天…）
├── config/                 # 配置模板与预设组合
└── docs/
```

设计目标、目录职责、组件接口约定见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)；
分阶段实现清单与 110 个组件清单见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。

重构完成后的用法预览：

```bash
./setup.sh --list                       # 列出全部组件及安装状态
./setup.sh --install nvidia-open,fcitx5 # 按 id 安装（自动解析依赖）
./setup.sh --preset laptop-y9000p       # 按预设组合安装
./setup.sh                              # 交互式菜单
```

---

## ❓ 常见问题

### 会动我的 Windows 盘吗？

不会。脚本只分区/格式化**所选目标盘**，Windows 盘连 ESP 都不会被写入；os-prober 对 Windows 盘只做只读检测。唯一的风险是**手动选错盘**——脚本不识别盘上内容，选盘时请务必自己核对（这是你唯一需要小心的地方）。

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
4. 脚本不再安装任何独显驱动，所以不会出现 `target not found: nvidia` 这类错误；若手动装驱动时遇到，见 [安装独显驱动](#安装独显驱动可选)

---

## 📝 免责声明

本项目用于自动化 Arch Linux 安装流程。由于 Arch Linux 更新频繁，脚本可能受到软件包变化、官方安装流程变化、硬件差异影响。建议在正式使用前先进行测试；破坏性操作前务必确认磁盘选择。

---

## 📄 License

MIT License
