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
| root 密码 | `111111`（见"安全提醒"） |
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
| `softethervpn5-server` | 官方 `packages` feed | **服务端**。`luci-app-softether` 只依赖 client，所以必须显式勾选。开机自启由 `files/etc/uci-defaults/97-enable-softethervpn-server` 处理；注意 init 脚本名是 `softethervpnserver`，**没有连字符** |
| `luci-app-timecontrol` | `sirpdboy/luci-app-timecontrol` | 上网时间控制 |
| OpenClash | `files/root/precompiled-pkgs/*.apk` | 含闭源 mihomo 核心 |
| NinjaDesktop Lite | `files/root/precompiled-pkgs/*.apk` | 桌面环境 |

两个 `.apk` 由 `files/etc/uci-defaults/99-install-pkgs` 在**首次开机**时安装。它们的运行时依赖（`ruby`、`ruby-yaml`、`unzip`、`ca-bundle`、`dnsmasq-full` 等）已经全部写进 `seed.config` 编进镜像，所以**没有网络也能装**。若某个插件开机后不见了，看 `/tmp/uci-defaults-99-install-pkgs.log`——失败时脚本会保留 `/root/precompiled-pkgs` 并打印重试命令。

## SoftEther 服务端开机自启

`files/etc/uci-defaults/97-enable-softethervpn-server` 在首次开机时 `enable` + `start`，
并检查 `/etc/rc.d/` 里的启动链接是否真的建立，结果写到 `/tmp/uci-defaults-97-softethervpn.log`。
包本身只装脚本不自启，所以这一步是必须的。

两点要知道：

1. **443 端口冲突**。uhttpd 默认配置里 `list listen_https 0.0.0.0:443`，而 SoftEther 新建
   `vpn_server.config` 时默认也用 443。刷机后先确认占用情况：
   `netstat -ltnp | grep -E ':(443|5555|992)\b'`。
   要挪开 SoftEther：`vpncmd` 连本机 → `ServerPortNum` 改成别的端口。
2. **首次开机没有管理密码**，也没有虚拟 hub。要建 hub 和用户才能连：
   `vpncmd` → `ServerCertCreate`/`HubCreate`/`UserCreate`，或用 SecureConsoleServer。
   另外 `files/etc/config/network` 按清单只定义了 `br-lan`，没有 wan 口和端口转发规则，
   所以外网目前连不进来，需要从 LAN 侧访问或自行补防火墙规则。

## 安全提醒

订阅链接、API token 一律**不要提交进本仓库**，放 GitHub Secrets 构建时注入。

例外（用户明确要求）：root 密码 `111111` 以 SHA-512 crypt 哈希的形式写在
`files/etc/uci-defaults/98-set-root-password` 里。本仓库是 **public**，`111111` 属于弱口令，
哈希可被离线爆破，所以这套固件**不要直接暴露到公网**；要改密码就重新生成哈希替换该文件里的 `HASH=`。

## 已知未包含的东西

25.12 的 LuCI 换成了 ucode/JS 架构。之前在 25.12 裸装上出过问题的几项，现在的状态：

1. ~~`CONFIG_PACKAGE_uhttpd-mod-ucode=y`~~、~~`files/etc/config/uhttpd` 覆盖（`lua_prefix` → `ucode_prefix`）~~
   —— 刷机实测**不需要**：镜像里只有 `uhttpd_ubus.so`，但 ucode dispatcher 正常工作
   （响应头 `x-luci-login-required` 由它添加，`/cgi-bin/luci/admin/translations/zh-cn` 返回 200）。
2. `luci.main.resourcebase '/luci-static/resources'` —— **这个才是真凶，已加入 `files/etc/config/luci`**。
   不设时 index 里发出的是 `<script src="/luci.js">` → 404（文件实际在
   `/luci-static/resources/luci.js`），于是所有 JS 视图永远停在"加载视图中…"。
3. `rpcd` 的 `timeout` 默认 30 秒，慢页面加载期间会话会过期 —— 仍未包含。

简体中文语言包和 Argon 设置页**已经包含**，不在此列。

中文的启用方式有个坑：`luci-i18n-*-zh-cn` 在 Kconfig 里是**没有提示语（promptless）的隐藏 tristate**，
在 seed.config 里逐个写 `CONFIG_PACKAGE_luci-i18n-xxx-zh-cn=y` 会被 `make defconfig` 静默丢弃，
只能靠主开关 `CONFIG_LUCI_LANG_zh_Hans=y` 点亮。build.sh Step 6 与 CI 都会在 defconfig 之后
逐条断言这些符号，被丢掉就直接报错，不会再产出"少功能但构建成功"的固件。
