# arch-install 实现清单

配套文档：[ARCHITECTURE.md](ARCHITECTURE.md)（结构设计与接口约定）。

状态图例：`[ ]` 待做 · `[~]` 进行中 · `[x]` 已完成
优先级：**P0** = 必须先做（缺了整个流程跑不通） · **P1** = 常用，第二梯队 · **P2** = 可选，按需补

> 软件安装脚本不在本次交付范围内，本文件即为待实现的完整清单。

---

## 阶段 0 · 项目骨架

目标：目录建好，`install.sh` / `setup.sh` 能跑（哪怕只打印帮助），lint 可执行。

- [ ] `lib/bootstrap.sh` — 仓库根定位、bash 版本校验、lib 按序加载、全局 trap
- [ ] `lib/log.sh` — 从现有 `install.sh` 抽出日志与颜色（保留 `NO_COLOR`/`TERM=dumb` 与日志剥离 ANSI）
- [ ] `lib/error.sh` — 抽出 `on_error` / `on_interrupt`，新增 `register_cleanup`
- [ ] `lib/config.sh` — 默认值表、环境变量、配置文件解析、优先级合并、`config_dump`
- [ ] `lib/ui.sh` — `ask` / `ask_yes_no` / `ask_secret` / `ask_choice` / `select_multi` / `confirm_destructive`，全部支持非交互回退
- [ ] `lib/check.sh` — 迁移现有 7 个检查函数（root/archiso/architecture/uefi/secure_boot/network/time）
- [ ] `lib/pkg.sh` — `pkg_installed` / `pkg_install` / `pkg_install_aur` / `aur_helper` / `pacstrap_base`
- [ ] `lib/system.sh` — `chroot_run` / `chroot_write` / `svc_enable` / `user_exists` / `write_file` / `sed_inplace`
- [ ] `lib/disk.sh` — 迁移盘枚举/校验/分区/格式化/挂载（`get_partition_name` 等）
- [ ] `lib/state.sh` — `state_mark` / `state_is_done` / `state_list` / `state_clear`
- [ ] `lib/component.sh` — 组件发现/元数据解析/依赖解析/调度执行（先留 `TODO` 空实现）
- [ ] `install.sh` — 重写为薄调度器：参数解析 + 按序执行 stages + 续跑
- [ ] `setup.sh` — 重写为组件入口：参数解析 + 菜单/列表（阶段 2 前先打印帮助）
- [ ] `bootstrap.sh` — 下载 tarball 到工作目录并转发到 `install.sh` / `setup.sh`
- [ ] `scripts/lint.sh` — shellcheck + `#@` 元数据头校验 + 文件名/id/分类一致性校验
- [ ] `docs/COMPONENT-SPEC.md` — 把 ARCHITECTURE 第 7 节展开成组件开发规范（含完整示例组件）
- [ ] `components/_template.sh` — 新组件模板
- [ ] `.editorconfig` / `.shellcheckrc` — 统一格式与 lint 规则
- [ ] 验收：在干净 ISO 里 `./install.sh --list-stages`、`./setup.sh --list` 正常输出；`scripts/lint.sh` 全绿

---

## 阶段 1 · 系统安装脚本迁移

目标：行为与现在的 `install.sh` **完全等价**，只是拆成 stages。

- [ ] `stages/00-preflight.sh` — 环境检查（含 Secure Boot 警告文案，保持原话术）
- [ ] `stages/10-mirrors.sh` — 写入固定的中国镜像列表并按序探测可用性（无 reflector；全部不可达才失败）
- [ ] `stages/20-disk.sh` — 列盘（路径/容量/型号/序列号）→ 选盘 → 校验 → 布局预览 → 输入 `YES`
- [ ] `stages/30-partition.sh` — `sgdisk --zap-all` → 1G ESP(ef00) + Btrfs root(8300) → `partprobe` → 等待分区节点 → `mkfs`
- [ ] `stages/40-mount.sh` — 严格顺序：临时挂载 → 建 `@`/`@home` → 卸载 → 挂 `@` → `mkdir` → 挂 `@home` → 挂 ESP(umask=0077) → 校验
- [ ] `stages/50-pacstrap.sh` — `pacstrap -K`，CPU microcode 自动识别（Intel/AMD）
- [ ] `stages/60-fstab.sh` — `genfstab -U` 并回显
- [ ] `stages/70-system-config.sh` — chroot 内时区/locale/hostname/hosts/NetworkManager/timesyncd/bluetooth/tlp
- [ ] `stages/80-user.sh` — 建用户（wheel + bash）→ 用户密码 → sudoers → root 密码
- [ ] `stages/90-bootloader.sh` — GRUB 安装（`--bootloader-id=Arch`）+ `GRUB_DISABLE_OS_PROBER` 开关 + `grub-mkconfig` + 可选启动顺序重排
- [ ] `stages/99-finish.sh` — sync / `umount -R` / 总结（含双系统与 Windows 时钟偏移提示）
- [ ] 每个 stage 支持单独重跑：`./install.sh --from 30-partition`
- [ ] 回归验证：VM 里跑一次完整安装，与原脚本行为逐项比对
- [ ] 验收：Same-behavior checklist 全过；磁盘布局、包列表、生成文件与旧版一致

**必须保持的既有取舍**（README 已对外承诺，迁移时不得回退）：

- [ ] 仅 UEFI；不识别/不写入 Windows 盘；os-prober 仅只读检测
- [ ] 不建 swap、不配置休眠（hibernate）
- [ ] 不创建 `/.snapshots` 子卷（留给 snapper 自建）
- [ ] 系统安装阶段不装任何独显驱动
- [ ] 不修改 GRUB 内核参数（保留发行版默认 `loglevel=3 quiet`）
- [ ] 环境变量 `MIRROR_COUNTRY` / `ENABLE_OS_PROBER` 继续可用（镜像改为固定列表后不再有 `MIRROR_AGE` / `MIRROR_PROTOCOL`）

---

## 阶段 2 · 组件框架

目标：`setup.sh` 能发现、列出、解释、按依赖安装组件；幂等与 dry-run 可用。

- [ ] `component_discover` — 扫描 `components/*/*.sh`，解析 `#@` 元数据头
- [ ] 元数据校验 — 缺字段 / id 重名 / 分类与目录不符 / deps 指向不存在 → 报错
- [ ] `component_list` — 表格输出：id、名称、分类、是否已装（`--list`）
- [ ] `component_resolve_deps` — 拓扑排序 + 循环依赖检测 + `conflicts` 冲突检测
- [ ] `component_run` — root 检查 → AUR helper 自动补装 → `check` → `install` → `post` → 落状态
- [ ] 幂等：`component_check` 返回 0 即 `[SKIP]`；`--force` 强制重跑
- [ ] `--dry-run` — 只打印将要执行的包安装与文件写入，不落盘
- [ ] `--keep-going` — 单组件失败不中断整批，最后汇总失败列表
- [ ] 状态：`/var/lib/arch-install/components/<id>.done` + `pending-reboot` 汇总
- [ ] 交互菜单 — 按分类浏览 → 多选 → 依赖展开预览 → 确认 → 执行
- [ ] 预设 `--preset` 与配置文件 `ARCH_COMPONENTS` 读取
- [ ] 失败提示 — 组件 id、日志路径、可直接复制的重试命令
- [ ] 验收：用一个假组件（只写文件、`check` 检测该文件）验证：首次装→跳过→`--force` 重跑→`--dry-run` 不落盘

---

## 阶段 3 · 组件清单

以下为全部待实现组件。包名仅为参考，实施时以官方仓库 / AUR 的实际名称为准。

### 00-base · 基础系统增强（18）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `aur-helper` | yay / paru，AUR 组件的前置 | P0 |
| [ ] | `zram` | zram-generator，内存压缩兜底（替代 swap） | P0 |
| [ ] | `mirror-reflector-timer` | reflector 定时刷新镜像 + hook | P1 |
| [ ] | `pacman-tuning` | 并行下载、Color、ILoveCandy、`--needed` | P1 |
| [ ] | `maintenance-timers` | paccache 清理、btrfs scrub、日志限额 | P1 |
| [ ] | `fstrim-timer` | 定期 TRIM（与 `discard=async` 二选一说明） | P1 |
| [ ] | `ntp-chrony` | chrony 替代 systemd-timesyncd | P1 |
| [ ] | `firewall-ufw` | ufw + 基础规则 | P1 |
| [ ] | `firewall-firewalld` | firewalld（与 ufw 互斥） | P2 |
| [ ] | `shell-zsh` | zsh + 补全 + starship/p10k + 设为默认 shell | P1 |
| [ ] | `shell-fish` | fish + 配置（与 zsh 二选一，不冲突） | P2 |
| [ ] | `sysctl-tuning` | 文件句柄、swap 倾向、网络参数 | P1 |
| [ ] | `man-docs` | man-db、中文 manpage | P2 |
| [ ] | `ssh-gpg` | ssh key 生成/导入、gpg、agent | P1 |
| [ ] | `firmware-fwupd` | fwupd + 固件更新 | P2 |
| [ ] | `snapshot-snapper` | snapper + grub-btrfs + 定时快照（**必须让 snapper 自建 `/.snapshots`**） | P1 |
| [ ] | `swapfile` | 可选 swapfile（仅当需要 hibernate；默认不装） | P2 |
| [ ] | `dotfiles` | 拉取并链接个人 dotfiles（仓库地址可配） | P2 |

### 10-hardware · 硬件与驱动（17）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `audio-pipewire` | pipewire + wireplumber + alsa-ucm-conf + sof-firmware | P0 |
| [ ] | `bluetooth` | bluez + 自动开启 + 省电/断连修复 | P0 |
| [ ] | `intel-vaapi` | intel-media-driver + libva-utils，核显硬解 | P1 |
| [ ] | `power-tlp` | TLP 笔记本电源管理 + 配置 | P1 |
| [ ] | `power-profiles-daemon` | 与 TLP 互斥的替代方案 | P2 |
| [ ] | `nvidia-open` | nvidia-open + utils + settings + prime，追加 `nvidia-drm.modeset=1` | P1 |
| [ ] | `nvidia-legacy` | Pascal 及更老显卡的旧版驱动（AUR，参考 `nvidia-580xx-dkms`） | P2 |
| [ ] | `gpu-switch` | 混合显卡切换（envycontrol / optimus-manager） | P2 |
| [ ] | `gpu-tuning-nvidia` | 独显性能模式、持久化、`prime-run` 校验 | P2 |
| [ ] | `fan-control-legion` | Legion 风扇/性能模式（LenovoLegionLinux 类内核模块或 AUR 工具） | P2 |
| [ ] | `keyboard-backlight` | 键盘背光控制与 udev 权限 | P2 |
| [ ] | `battery-threshold` | 联想养护模式充电阈值 | P2 |
| [ ] | `touchpad-libinput` | 手势与轻触点击配置 | P1 |
| [ ] | `fingerprint-fprintd` | fprintd + 指纹录入（先检测硬件是否存在，无则跳过） | P2 |
| [ ] | `webcam-ir-howdy` | IR 摄像头人脸解锁 | P2 |
| [ ] | `printer-cups` | CUPS + 打印/扫描 | P2 |
| [ ] | `tablet-wacom` | 数位板 | P2 |

### 20-desktop · 桌面环境 / 窗口管理器（20）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `kde-plasma` | Plasma + 基础 KDE 应用 | P0 |
| [ ] | `gnome` | GNOME + 基础扩展 | P1 |
| [ ] | `hyprland` | Hyprland + 依赖 | P1 |
| [ ] | `niri` | niri 滚动平铺 WM | P2 |
| [ ] | `sway` | sway（i3 兼容 Wayland） | P2 |
| [ ] | `xfce` | 轻量桌面 | P2 |
| [ ] | `dm-sddm` | SDDM + 主题 | P0 |
| [ ] | `dm-gdm` | GDM | P2 |
| [ ] | `dm-greetd` | greetd + tuigreet（适合 WM 用户） | P2 |
| [ ] | `wayland-portal` | xdg-desktop-portal 对应后端（kde/hyprland/gnome） | P0 |
| [ ] | `fonts-desktop` | 通用字体 + emoji + Nerd Font | P0 |
| [ ] | `theme-icons` | 图标/光标/GTK-Qt 主题 | P2 |
| [ ] | `xdg-defaults` | xdg-user-dirs、默认应用关联 | P1 |
| [ ] | `terminal-emulator` | kitty / alacritty / wezterm 选一 | P1 |
| [ ] | `file-manager` | Dolphin / Nautilus / yazi | P1 |
| [ ] | `statusbar-waybar` | waybar（WM 用户） | P2 |
| [ ] | `screenshot-tools` | grim/slurp（Wayland）、spectacle（KDE） | P1 |
| [ ] | `clipboard-tools` | wl-clipboard + cliphist | P2 |
| [ ] | `notifications` | dunst / mako | P2 |
| [ ] | `lockscreen` | hyprlock / swaylock / 桌面自带 | P2 |

### 30-i18n · 中文环境（7）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `locale-zh` | 启用 zh_CN.UTF-8、中文 manpage | P0 |
| [ ] | `fonts-cjk` | noto-fonts-cjk + emoji + 思源/文泉驿 | P0 |
| [ ] | `fontconfig-zh` | 中文优先与日韩字形区分规则 | P0 |
| [ ] | `fcitx5` | fcitx5 + chinese-addons + 拼音 + 皮肤 | P0 |
| [ ] | `im-env` | 输入法环境变量（`/etc/environment`、`/etc/profile.d`） | P0 |
| [ ] | `fcitx5-rime` | 中州韵 + 雾凇拼音方案 | P1 |
| [ ] | `ibus-pinyin` | ibus + libpinyin（备选方案） | P2 |

### 40-dev · 开发环境（15）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `dev-git` | git + 用户配置 + 凭证缓存 | P1 |
| [ ] | `cc-toolchain` | gcc/clang/cmake/make/ninja/gdb | P1 |
| [ ] | `shell-tools` | ripgrep/fd/fzf/bat/eza/zoxide/tmux/jq | P1 |
| [ ] | `editor-neovim` | neovim + 配置（LazyVim 等） | P1 |
| [ ] | `editor-vscode` | code（含中文语言包） | P1 |
| [ ] | `lang-python` | python + uv/pipx/poetry | P1 |
| [ ] | `lang-nodejs` | fnm/nvm + node + pnpm | P1 |
| [ ] | `lang-rust` | rustup + toolchain | P1 |
| [ ] | `lang-go` | go | P2 |
| [ ] | `lang-java` | jdk-openjdk | P2 |
| [ ] | `containers-docker` | docker + compose + 用户组 + 镜像加速 | P1 |
| [ ] | `containers-podman` | podman + podman-compose + distrobox | P2 |
| [ ] | `virt-libvirt` | libvirt + qemu + virt-manager + 用户组 | P2 |
| [ ] | `dev-database` | postgresql/mysql/redis（按需） | P2 |
| [ ] | `dev-dotfiles` | 开发相关 dotfiles 链接 | P2 |

### 50-gaming · 游戏与性能（13）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `steam` | Steam + multilib + 32 位库 | P1 |
| [ ] | `gamemode` | gamemode | P1 |
| [ ] | `mangohud` | MangoHud + goverlay | P1 |
| [ ] | `lutris` | Lutris | P2 |
| [ ] | `wine` | wine-staging / wine-ge（含中文 locale 支持） | P2 |
| [ ] | `proton-ge` | Proton-GE 下载与安装 | P2 |
| [ ] | `gamescope` | gamescope 合成器 | P2 |
| [ ] | `heroic` | Heroic Games Launcher（Epic/GOG） | P2 |
| [ ] | `controller-xpadneo` | Xbox 手柄蓝牙驱动 | P2 |
| [ ] | `controller-dualsense` | DualSense 增强（AUR） | P2 |
| [ ] | `discord` | Discord（含 Wayland 屏幕共享注意项） | P2 |
| [ ] | `emulator-retroarch` | RetroArch 及核心 | P2 |
| [ ] | `cpu-governor` | CPU 调度器/性能模式脚本 | P2 |

### 60-apps · 日常软件（20）

| | id | 说明 | 优先级 |
| --- | --- | --- | --- |
| [ ] | `browser-firefox` | Firefox + 中文语言包 + 硬件加速 | P1 |
| [ ] | `browser-chromium` | Chromium | P1 |
| [ ] | `browser-brave` | Brave（AUR） | P2 |
| [ ] | `office-libreoffice` | LibreOffice + 中文语言包 | P1 |
| [ ] | `office-wps` | WPS Office（AUR，需处理字体/输入法） | P2 |
| [ ] | `media-mpv` | mpv + 硬件解码配置 | P1 |
| [ ] | `media-vlc` | VLC | P2 |
| [ ] | `image-viewer` | imv / gwenview / feh | P2 |
| [ ] | `archive-tools` | 7zip/unrar/ark/zip | P1 |
| [ ] | `download-aria2` | aria2 + AriaNg/motrix | P2 |
| [ ] | `torrent-qbittorrent` | qBittorrent | P2 |
| [ ] | `chat-qq` | linuxqq | P2 |
| [ ] | `chat-wechat` | 微信（AUR，容器/兼容层方案） | P2 |
| [ ] | `chat-telegram` | Telegram Desktop | P2 |
| [ ] | `mail-thunderbird` | Thunderbird | P2 |
| [ ] | `note-obsidian` | Obsidian | P2 |
| [ ] | `cloud-rclone` | rclone + 云盘挂载/同步 | P2 |
| [ ] | `remote-desktop-rustdesk` | RustDesk / todesk | P2 |
| [ ] | `ocr-tesseract` | tesseract + 中文语言包（截图取字） | P2 |
| [ ] | `flatpak-runtime` | flatpak + Flathub（含中文字体接入） | P2 |

**小计**：18 + 17 + 20 + 7 + 15 + 13 + 20 = **110 个组件**

---

## 阶段 4 · 预设与配置

- [ ] `config/arch-install.conf.example` — 系统安装 + 组件选择全量注释模板
- [ ] `config/presets/minimal.conf` — 能上网、能用中文、无桌面
- [ ] `config/presets/laptop-y9000p.conf` — 本项目目标机型（核显 + 可选独显、TLP、蓝牙、键盘灯、风扇、中文）
- [ ] `config/presets/full-desktop.conf` — KDE + 中文 + 开发 + 常用软件
- [ ] `--preset` / `ARCH_COMPONENTS` / `ARCH_SKIP_COMPONENTS` 生效
- [ ] 环境变量别名兼容（`MIRROR_*`、`ENABLE_OS_PROBER`）

---

## 阶段 5 · 分发与文档

- [ ] `bootstrap.sh` 支持两种用法：`bootstrap.sh install` / `bootstrap.sh setup`
- [ ] `scripts/build-release.sh` — 拼接 lib + stages 输出自包含单文件 `install.sh`（保留旧的 `curl -O` 体验）
- [ ] README 重写：
  - [ ] 新目录结构说明
  - [ ] `install.sh`（ISO）与 `setup.sh`（装好后）两条使用路径
  - [ ] 组件清单表与 `--list` 输出示例
  - [ ] 配置文件与预设用法
  - [ ] 保留现有的 BIOS/Secure Boot/VMD 章节与双系统说明
  - [ ] 把「安装独显驱动」「启用快照」两节改成 `./setup.sh --install nvidia-open` / `--install snapshot-snapper`
- [ ] `docs/COMPONENT-SPEC.md` 补完整示例（一个真实可跑的组件）

---

## 阶段 6 · 质量保障（可选但推荐）

- [ ] `scripts/lint.sh` 接入 CI：shellcheck + 元数据校验 + 命名规范
- [ ] `scripts/test-vm.sh` — QEMU 无人值守安装冒烟测试
- [ ] 组件冒烟：`./setup.sh --dry-run --all` 全组件预演无报错
- [ ] 在真实 Y9000P 2022 上完整走一遍：系统安装 → 预设组件 → 重启 → 验证核显/蓝牙/中文输入法/电源
- [ ] 失败场景回归：断网、Secure Boot 开启、选到 live 盘、目标盘已挂载

---

## 建议的实施顺序

1. **阶段 0 → 1** 先把系统安装拆完并验证行为等价（这是一次纯重构，风险可控、可立即回归）
2. **阶段 2** 做组件框架 + 用一个假组件验证幂等/依赖/dry-run
3. **阶段 3 的 P0**：`aur-helper`、`zram`、`audio-pipewire`、`bluetooth`、`locale-zh`、`fonts-cjk`、`fontconfig-zh`、`fcitx5`、`im-env`、`kde-plasma`、`dm-sddm`、`wayland-portal`、`fonts-desktop`
   → 到此为止已经是一套「装完即用」的中文桌面
4. **阶段 3 的 P1** 按需补齐；**P2** 有空再加
5. **阶段 4/5** 收尾文档与预设
