# arch-install

一个用于快速安装 Arch Linux 的自动化安装脚本。

该脚本面向 Arch Linux 官方 ISO 环境，通过交互方式完成磁盘选择、分区、系统安装以及基础配置。

## 功能特性

- 支持 UEFI 启动模式
- 自动检测运行环境
- 自动配置 Arch Linux 镜像源
- GPT 分区方案
- 自动创建：
  - EFI 分区
  - Swap 分区
  - Btrfs 根分区
- Btrfs 子卷布局：
  - `@`      根目录
  - `@home`  用户目录
  - `@snapshots` 快照目录
- 自动安装基础系统
- 自动生成 `fstab`
- 自动配置：
  - 时区
  - Locale
  - Hostname
  - NetworkManager
  - Bluetooth
  - TLP 电源管理
- 支持休眠恢复（Hibernate Resume）
- 集成 Snapper + grub-btrfs 快照启动
- 安装 GRUB 引导程序
- 自动记录安装日志


## 系统要求

运行环境：

- Arch Linux 官方安装 ISO
- x86_64 架构
- UEFI 启动模式
- 已连接互联网
- root 权限

脚本会检查必要环境，包括 Arch ISO、UEFI、网络以及安装所需命令。:contentReference[oaicite:1]{index=1}


## 使用方法

启动 Arch Linux ISO 后：

### 1. 获取脚本

例如：

```bash
curl -O https://example.com/install.sh