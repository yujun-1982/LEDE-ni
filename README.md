# lede

OpenWrt 25.12+（master 分支，apk 包管理）x86/64 定制固件的构建配置仓库。

官方 OpenWrt 源码保持不动，所有定制通过 `seed.config` + `files/` overlay + 额外 feed 注入。

## 构建

```bash
git clone https://github.com/yujun-1982/lede.git
cd lede
./build.sh                       # 准备源码树、feed、.config、overlay
cd openwrt && make -j$(nproc) V=s
```

产物（PVE 用 `qm importdisk` 导入的就是它）：

```
openwrt/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz
```

## 配置概要

| 项 | 值 |
|---|---|
| 架构 | x86/64，generic |
| Rootfs | squashfs（只读 + journaling overlay） |
| 分区 | Kernel 256 MiB / Rootfs 1024 MiB |
| 引导 | GRUB，串口控制台开启 @115200，`quiet loglevel=0`，timeout `0`，无 EFI |
| 镜像格式 | 仅 gzip 压缩的 `.img.gz`（不出 ext4 / EFI / VDI / QCOW2 / VMDK） |
| LAN | `br-lan` 桥接（成员口 `eth0`）静态 `10.10.10.2/24` |
| root 密码 | 空 |
| 主题 | Argon + Argon 设置页（`files/etc/config/luci` 指定 mediaurlbase） |
| 语言 | 简体中文（`luci.main.lang='zh_cn'` + 7 个 `luci-i18n-*-zh-cn`） |
| 分流 | 官方 nftables flow offloading（`files/etc/config/firewall` 的 lan zone） |

## 插件

| 组件 | 来源 | 说明 |
|---|---|---|
| `luci-theme-argon` | `jerrykuku/luci-theme-argon` master | 单包仓库，**不能**当 feed 注册，build 脚本直接 clone 到 `package/feeds/argon/` |
| `luci-app-argon-config` | `jerrykuku/luci-app-argon-config` master | **独立仓库**（主题仓库里没有它），同样直接 clone。提供 系统 → Argon 设置 |
| `luci-app-passwall` | `xiaorouji/luci-app-passwall` + `xiaorouji/openwrt-passwall-packages` | 需要两个 feed |
| `luci-app-softether` | 官方 `luci` feed | 界面在 **状态 → SoftEther 状态**；VPN 二进制 `softethervpn5-*` 来自 `packages` feed |
| `softethervpn5-server` | 官方 `packages` feed | **服务端**。`luci-app-softether` 只依赖 client，所以必须显式勾选。开机后需自行 `/etc/init.d/softethervpn-server enable && start` |
| `luci-app-timecontrol` | `sirpdboy/luci-app-timecontrol` | 上网时间控制 |
| OpenClash | `files/root/precompiled-pkgs/*.apk` | 含闭源 mihomo 核心 |
| NinjaDesktop Lite | `files/root/precompiled-pkgs/*.apk` | 桌面环境 |

两个 `.apk` 由 `files/etc/uci-defaults/99-install-pkgs` 在**首次开机**时安装。它们的运行时依赖（`ruby`、`ruby-yaml`、`unzip`、`ca-bundle`、`dnsmasq-full` 等）已经全部写进 `seed.config` 编进镜像，所以**没有网络也能装**。若某个插件开机后不见了，看 `/tmp/uci-defaults-99-install-pkgs.log`——失败时脚本会保留 `/root/precompiled-pkgs` 并打印重试命令。

## 安全提醒

订阅链接、密码、API token 一律**不要提交进本仓库**。放 GitHub Secrets，构建时注入。

## 已知未包含的东西

25.12 的 LuCI 换成了 ucode/JS 架构，以下几项在裸装上会让 Web 界面出问题。当前仓库**按需求保持干净、未包含它们**，出问题时再按需加：

1. `CONFIG_PACKAGE_uhttpd-mod-ucode=y` — 缺了没有 `uhttpd_ucode.so`，uhttpd 会静默忽略 ucode handler。
2. `files/etc/config/uhttpd` 覆盖 — 去掉 `luci-compat` 注入的 `lua_prefix`，改用 `ucode_prefix`。
3. `luci.main.resourcebase '/luci-static/resources'` — 不设则 `luci.js` 会被解析到站点根目录而 404。
4. `rpcd` 的 `timeout` 默认 30 秒，慢页面加载期间会话会过期。

简体中文语言包和 Argon 设置页**已经包含**，不在此列。
