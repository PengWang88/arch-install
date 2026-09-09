# arch-install

一个用于快速部署 Arch Linux 的自动化安装脚本。

本项目基于 Arch Linux 官方安装环境，通过交互式流程完成磁盘分区、系统安装、基础服务配置以及引导安装，目标是在保持 Arch Linux 灵活性的同时，减少重复的手动安装步骤。

> ⚠️ 注意：该脚本会对目标磁盘进行分区和格式化操作，请确认备份重要数据后再使用。

---

## ✨ 功能特性

### 系统安装

* 支持 UEFI 启动模式
* 自动检测 Arch Linux 安装环境
* 自动配置 Arch Linux 镜像源
* GPT 分区方案
* 自动创建 EFI 分区
* 自动创建 Swap 分区
* 自动创建 Btrfs 根文件系统

### Btrfs 文件系统布局

默认使用 Btrfs 子卷：

```
/
├── @
├── @home
└── @snapshots
```

支持：

* 根目录快照
* 用户目录独立管理
* Snapper 快照管理
* grub-btrfs 快照启动

### 系统配置

自动完成：

* 时区配置
* Locale 配置
* Hostname 设置
* 用户创建
* 网络配置
* NetworkManager 安装
* Bluetooth 配置
* TLP 电源管理
* Hibernate Resume 配置

### 引导配置

自动安装：

* GRUB Bootloader
* EFI 启动项
* 快照启动菜单

### 安装日志

安装过程会保存日志，方便排查安装问题。

---

## 📦 系统要求

运行环境：

* Arch Linux 官方 ISO
* x86_64 架构
* UEFI 启动模式
* 已连接互联网
* root 权限

推荐：

* 单块 SSD / NVMe 磁盘
* 支持 UEFI 的现代电脑

---

## 🚀 使用方法

### 1. 启动 Arch Linux ISO

从 U 盘启动 Arch Linux 安装环境。

确认网络连接：

```bash
ping archlinux.org
```

---

### 2. 下载安装脚本

```bash
curl -O https://raw.githubusercontent.com/PengWang88/arch-install/main/install.sh
```

添加执行权限：

```bash
chmod +x install.sh
```

---

### 3. 运行安装程序

```bash
./install.sh
```

根据提示完成：

* 磁盘选择
* 分区确认
* 用户配置
* 系统参数设置

---

### 4. 安装完成后重启

```bash
reboot
```

移除安装 U 盘后进入新的 Arch Linux 系统。

---

## 📁 项目结构

```
arch-install
├── install.sh     # 自动安装脚本
└── README.md      # 使用说明
```

---

## ⚙️ 分区方案

默认方案：

| 分区   | 文件系统  | 用途        |
| ---- | ----- | --------- |
| EFI  | FAT32 | UEFI 引导   |
| Swap | swap  | 交换空间 / 休眠 |
| Root | Btrfs | 系统数据      |

---

## 🔧 安装后的系统组件

脚本会自动配置：

* Linux Kernel
* GRUB
* NetworkManager
* Bluetooth
* TLP
* Snapper
* grub-btrfs

---

## ❓ 常见问题

### 是否支持 BIOS Legacy 启动？

目前主要面向 UEFI 环境。

---

### 是否会清空磁盘？

会。

安装过程中会重新分区目标磁盘，请提前备份数据。

---

### 是否支持多系统安装？

默认安装流程针对单系统部署。

如果需要保留已有系统，请自行修改分区方案。

---

### 安装失败怎么办？

请检查：

1. 网络是否正常
2. ISO 是否为最新版本
3. 是否使用 UEFI 启动
4. 查看安装日志

---

## 📝 免责声明

本项目用于自动化 Arch Linux 安装流程。

由于 Arch Linux 更新频繁，脚本可能受到：

* 软件包变化
* 官方安装流程变化
* 硬件差异

影响。

建议在正式使用前先进行测试。

---

## 📄 License

MIT License
