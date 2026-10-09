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
| root 密码 | **空**（本仓库不再写入密码；Web 界面直接进，SSH 密码登录会被 dropbear 拒绝，见"安全提醒"） |
| 主题 | Argon + Argon 设置页（`files/etc/uci-defaults/96-set-luci-ui` 设 mediaurlbase） |
| 语言 | 简体中文（`luci.main.lang='zh_cn'`，翻译包由 `CONFIG_LUCI_LANG_zh_Hans` 点亮，见下） |
| 分流 | 官方 nftables flow offloading（`files/etc/config/firewall` 的 lan zone） |
| SoftEther | 服务端二进制已装，**默认不自启**（首次开机脚本显式 disable）；客户端不装；配置落在 `/etc/softethervpn-server`，并把自动保存间隔从 86400 秒压到 300 秒 |
| Web 管理 | HTTP 80；443 已配置但**实际不监听**——镜像内没有证书生成器（`px5g`/`openssl` CLI 都没有），详见"SoftEther 服务端"一节 |

## 插件

| 组件 | 来源 | 说明 |
|---|---|---|
| `luci-theme-argon` | `jerrykuku/luci-theme-argon` master | 单包仓库，**不能**当 feed 注册，build 脚本直接 clone 到 `package/feeds/argon/` |
| `luci-app-argon-config` | `jerrykuku/luci-app-argon-config` master | **独立仓库**（主题仓库里没有它），同样直接 clone。提供 系统 → Argon 设置 |
| `luci-app-passwall` | `xiaorouji/luci-app-passwall` + `xiaorouji/openwrt-passwall-packages` | 需要两个 feed |
| `luci-app-softether-service` | **本仓库自带**（`package/`，以 `src-link custom` 注册为 feed） | 菜单 **VPN → SoftEther VPN Service**：显示运行状态/PID/开机自启，提供启动、停止、重启、自启开关 |
| `softethervpn5-server` | 官方 `packages` feed | **服务端**。没有任何 LuCI 应用会拉它，必须显式勾选。**默认不自启**，见"SoftEther 服务端"一节；注意 init 脚本名是 `softethervpnserver`，**没有连字符** |
| WireGuard | 官方 `packages` feed | **只装组件，不预配置**：`kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard`。本仓库的 LuCI Master 版本里**没有** `luci-app-wireguard`，入口就是 `luci-proto-wireguard` 提供的"WireGuard 隧道"接口类型（网络 → 接口）。不预置接口/密钥/防火墙规则，理由见下 |

上游的 `luci-app-softether` **已刻意移除**：它唯一的页面列的是 SoftEther **客户端**的虚拟网卡和账号
（helper 里全是 `vpncmd localhost /client ...`），对服务端部署没有意义；而且在 LuCI Master 下它用
`fs.exec_direct()` 请求 `/cgi-bin/cgi-exec`，被 rpcd 以 **403（Access to command denied by ACL）** 拒绝，
页面就永远停在"正在加载账号信息"。我们自己的页面改用 ubus 的 `fs.exec()` 与 `service list`，
并且每个分支都带 `.catch()`，不会再出现无限加载。

WireGuard 故意**不预置任何接口、密钥或防火墙规则**：本仓库是 public 的，而 WireGuard 的私钥一旦泄漏
就等于隧道失守， site-specific 的密钥不该进版本库。刷完机在 web UI 里新建，或者命令行生成一对密钥：

```sh
wg genkey | tee privatekey | wg pubkey > publickey
```
| `luci-app-timecontrol` | `sirpdboy/luci-app-timecontrol` | 上网时间控制。**需要本仓库补一个菜单父节点**，见下 |

### 为什么要有 `files/usr/share/luci/menu.d/99-custom-menu-parents.json`

`luci-app-timecontrol` 的 menu.d 只声明了子节点 `admin/control/timecontrol`，**从不声明父节点
`admin/control`**。旧的 Lua dispatcher 会自动补出中间层级，LuCI Master 的 ucode dispatcher 不会，
于是"管控"这一项在菜单里完全不出现（页面本身是能直达的，`/cgi-bin/luci/admin/control/timecontrol/basic`
正常渲染）。本仓库补一个只声明父节点的 menu.d 文件把它接回来。

排查时注意一个坑：LuCI 把整棵菜单树缓存在**客户端会话数据**里（`ui.menu.load()` →
`session.getLocalData('menu')`），服务端已经修好了浏览器也可能看不见。判断依据是直接请求
`/cgi-bin/luci/admin/menu` 这个 JSON 端点看服务端返回；要让界面刷新就
`ui.menu.flushCache()` 后重载，或者重新登录一次。
| OpenClash | `files/root/precompiled-pkgs/*.apk` | 含闭源 mihomo 核心 |
| NinjaDesktop Lite | `files/root/precompiled-pkgs/*.apk` | 桌面环境 |

两个 `.apk` 由 `files/etc/uci-defaults/99-install-pkgs` 在**首次开机**时安装。它们的运行时依赖（`ruby`、`ruby-yaml`、`unzip`、`ca-bundle`、`dnsmasq-full` 等）已经全部写进 `seed.config` 编进镜像，所以**没有网络也能装**。若某个插件开机后不见了，看 `/tmp/uci-defaults-99-install-pkgs.log`——失败时脚本会保留 `/root/precompiled-pkgs` 并打印重试命令。

## SoftEther 服务端：默认不自启

装 `softethervpn5-server` 时镜像里会留下 `/etc/rc.d/S91softethervpnserver` 这个启动链接，
所以**默认是会自启的**。`files/etc/uci-defaults/97-softethervpn-server-no-autostart` 在首次
开机时把它 `disable` 掉并记录状态，日志在 `/tmp/uci-defaults-97-softethervpn.log`。
`disable` 单独就够，是因为 uci-defaults 由 `/etc/init.d/boot` 执行、而它的 rc.d 链接是
**S10boot**，rcorder 按顺序走，走到 S91 时链接已经没了。脚本不会 `start`，也不会去 `stop`
已在运行的进程。带配置升级（sysupgrade）时 uci-defaults 会再跑一次，自启又会被关掉，
需要自启就在页面上重新点"设为开机自启"。
`softethervpn5-client` 也在 `seed.config` 里显式关掉，镜像里不再装客户端。

要跑服务端就在 **VPN → SoftEther VPN Service** 页面上点"启动"或"设为开机自启"，
或者命令行：`/etc/init.d/softethervpnserver start`（`enable` 是自启）。init 脚本名
**没有连字符**，`softethervpn-server` 那个不存在。

三点要知道：

1. **443**：不自启时 SoftEther 不会占 443。若你手工启动服务端，它新建 `vpn_server.config`
   时默认监听 443/992/1194/5555，会和 uhttpd 的 `listen_https` 撞。确认占用：
   `netstat -ltnp | grep -E ':(443|5555|992)\b'`；改端口用 `vpncmd` 连本机 → `ServerPortNum`。
2. **HTTPS 目前仍然不可用，原因不是端口**。镜像里没有证书生成器——`/usr/sbin/px5g` 和
   `openssl` 命令行都不存在（只有 `libopenssl3`/`libmbedtls` 这些库），所以
   `/etc/init.d/uhttpd` 的 `generate_keys()` 什么也生成不出来，`/etc/uhttpd.crt`/`.key`
   不存在，uhttpd 只挂 80 端口。要让 HTTPS 开箱可用，在 `seed.config` 里加
   `CONFIG_PACKAGE_px5g-mbedtls=y` 重新构建即可（当前按决定保持不变）。
3. **没有虚拟 hub 和用户**。root 是空密码（Web 界面直接进），服务端首次启动仍要
   `vpncmd` → `ServerPasswordSet`/`HubCreate`/`UserCreate` 才能连。另外
   `files/etc/config/network` 按清单只定义了 `br-lan`，没有 wan 口和端口转发规则，
   所以外网目前连不进来，需要从 LAN 侧访问或自行补防火墙规则。

## SoftEther 配置持久化（本仓库覆盖了它的 init 脚本）

上游包自带的 `/etc/init.d/softethervpnserver` 把数据目录放在 `/var/softethervpn`，而这套镜像里
**`/var` 是指向 `/tmp` 的符号链接（tmpfs）**，并且它只是把 `vpn_server.config` 软链到包里那个
空的占位文件（`files/dummy`）。结果就是：新建的监听端口、虚拟 HUB、用户、管理密码全写在内存里，
**一重启就没了**。

本仓库用 `files/etc/init.d/softethervpnserver` 覆盖它（`files/` 是整文件替换，正好是这里想要的
效果），把数据目录换成可写 overlay 上的真实目录 **`/etc/softethervpn-server`**：

- `vpnserver` 以**实体副本**放在该目录（它只是个 12 KiB 的桩，真代码在 `libsoftethervpn-server.so`），
  因为 vpnserver 是按"自己所在目录"去找 `hamcore.se2` 和 `vpn_server.config` 的，软链会被解析回
  `/usr/libexec`（只读）。每次启动都用 `cmp` 校验并刷新副本，包升级后不会留下旧的桩。
- `hamcore.se2`(5 MiB)、`lang.config` 用符号链接指回 `/usr/libexec/softethervpn`，不往闪存档里塞。
- 首次启动写入空配置；若旧的 `/var/softethervpn/vpn_server.config` 里已有内容，会自动搬过来。
- `97-softethervpn-server-no-autostart` 顺手把 `/etc/softethervpn-server` 加进
  `/etc/sysupgrade.conf`，带配置升级时配置一起保留。

注意四点：

1. **改动只在三种时机写盘，其中"自动保存"默认是 24 小时。** 真机验证过：`HubCreate` 之后
   `vpn_server.config` 的 md5/大小/mtime 全不变，而运行中的服务已能看到新 HUB —— SoftEther 5.x
   把改动留在内存，写盘时机只有三个：收到管理命令 `Flush`、进程**优雅停止**、以及配置项
   `AutoSaveConfigSpan` 到期（出厂默认 **86400 秒 = 24 小时**）。所以**硬重启（Proxmox 的"重启"就是
   硬 reset，不走 ACPI 关机）或断电会直接丢掉这一天之内的改动** —— 这就是"刷了新固件、重启几次配置又没了"
   的真实原因。本仓库的处理：
   - `files/usr/libexec/softethervpn-set-autosave` 走服务端自己的 `ConfigGet` → 改一个数 →
     `ConfigSet` → `Flush` 通道（`vpn_server.config` 里带哈希字段，**不能手改文件**），把间隔压到
     服务端允许的下限 **300 秒**（实测填 60 会被抬回 300）；
   - `97-softethervpn-server-no-autostart` 在首次开机时短暂启动服务端完成上面这轮压缩，然后停掉
     （不改变"默认不自启"）；带配置升级时 uci-defaults 会再跑一次，老设备的 86400 也会被改过来；
   - init 脚本 `stop_service()` 里先 `Flush` 再让 procd 杀进程，所以 `stop`/`restart`/正常 `reboot`
     立刻落盘；
   - 页面有"保存配置到磁盘"按钮，命令行为 `vpncmd localhost:5555 /server /CMD Flush`。
   合计效果：**硬重启最多丢 5 分钟**，正常重启/关机不丢。已实测确认：08:03:51 `HubCreate zztimer`
   后磁盘文件仍是旧的 20287 字节、里面查不到这个名字，之后**我没有执行任何 `Flush`**，到 08:09
   文件自己涨到 26515 字节并含该 HUB；紧接一次 `reboot`（同样没 Flush）起来后 `HubList`
   仍是 `DEFAULT` / `zzspan` / `zztimer`。
2. **设了服务端管理密码之后，Flush 需要密码。** init 脚本和 helper 都会读
   `/etc/softethervpn-server/management.password`（首行为密码，权限请保持 600，属 root，**绝不要提交进仓库**）：
   `printf '%s\n' '你的密码' > /etc/softethervpn-server/management.password && chmod 600 /etc/softethervpn-server/management.password`。
   没这个文件时它们照旧静默跳过（未设密码的服务端不需要）。注意 300 秒的自动保存是服务端内部行为，
   不需要任何凭据，所以即使忘了写这个文件，最坏也只是丢 5 分钟。
3. 在服务端上直接 `apk add --upgrade softethervpn5-server` 会用上游脚本覆盖我们这份，
   升级后需要重新刷本仓库的镜像（或手工恢复）；另外 SoftEther 若开启日志，日志也落在
   `/etc/softethervpn-server`，长期大量写日志会消耗闪存，建议只在排障时开。
4. `vpncmd` 的正确形式是 `vpncmd localhost:5555 /server /CMD <命令>`；取/灌整份配置用
   `/OUT:文件 /CMD ConfigGet` 和 `printf '文件路径\n' | vpncmd … /CMD ConfigSet`（`ConfigSet` 的
   路径是交互输入的，`/IN:` 无效）；`HubCreate` 会交互式询问 HUB 密码，脚本化时喂换行走默认值。

## 安全提醒

订阅链接、API token 一律**不要提交进本仓库**，放 GitHub Secrets 构建时注入。

本镜像的 root 是**空密码**（出厂镜像里 `/etc/shadow` 的 root 字段为空：`root:::0:99999:7:::`，
仓库不再写入任何密码）。后果要知道清楚：

- Web 界面可以空密码直接登录；
- **SSH 用密码登录会失败**——dropbear 即使 `PasswordAuth`/`RootPasswordAuth` 为 `on`，也默认拒绝空密码。
  要用 SSH 就在 系统 → 管理权 里先设一个密码，或给 dropbear 增加 `-B`（允许空密码）；
- 因此这套固件同样**不要直接暴露到公网**；SoftEther 服务端的管理密码也必须单独用
  `ServerPasswordSet` 设置，不能指望 root 的口令。

## 已知未包含的东西

25.12 的 LuCI 换成了 ucode/JS 架构。之前在 25.12 裸装上出过问题的几项，现在的状态：

1. ~~`CONFIG_PACKAGE_uhttpd-mod-ucode=y`~~、~~`files/etc/config/uhttpd` 覆盖（`lua_prefix` → `ucode_prefix`）~~
   —— 刷机实测**不需要**：镜像里只有 `uhttpd_ubus.so`，但 ucode dispatcher 正常工作
   （响应头 `x-luci-login-required` 由它添加，`/cgi-bin/luci/admin/translations/zh-cn` 返回 200）。
2. `luci.main.resourcebase '/luci-static/resources'` —— **这个才是真凶**。不设时 index 里发出的
   是 `<script src="/luci.js">` → 404（文件实际在 `/luci-static/resources/luci.js`），
   于是所有 JS 视图永远停在"加载视图中…"。
   注意它本来**就是 luci-base 打包默认值里的第 4 行**——是我们自己把它弄丢的：
   原先仓库里有 `files/etc/config/luci` 这个 overlay 文件，而 **overlay 是整文件替换、不是合并**，
   于是连带删掉了 `ubuspath`、`config internal 'sauth'`（`sessionpath`/`sessiontime`）、
   `ccache`、`apply`（`rollback`/`holdoff`/`timeout`/`display`）等默认项。
   现在改成 `files/etc/uci-defaults/96-set-luci-ui`，只用 `uci set` 改 `lang` 和 `mediaurlbase`
   两项，其余保留上游默认，脚本会把 `resourcebase`/`ubuspath`/`sauth` 的现值打印到
   `/tmp/uci-defaults-96-set-luci-ui.log` 以便核对。

   **通用教训**：`files/etc/config/<x>` 会完整替换 `<x>` 包自带的那份。要改配置优先用 uci-defaults
   里的 `uci set`；确实需要整文件覆盖时，先把打包默认抄全再改。
   （`files/etc/config/network` 是有意整份覆盖的，实测安全：`config_generate` 的守卫是
   `[ -s network -a -s system ] && exit 0`，而 `system` 首次开机才生成，所以它照常跑、
   只是跳过 network 生成。）
3. `rpcd` 的 `timeout` 默认 30 秒，慢页面加载期间会话会过期 —— 仍未包含。

简体中文语言包和 Argon 设置页**已经包含**，不在此列。

中文的启用方式有个坑：`luci-i18n-*-zh-cn` 在 Kconfig 里是**没有提示语（promptless）的隐藏 tristate**，
在 seed.config 里逐个写 `CONFIG_PACKAGE_luci-i18n-xxx-zh-cn=y` 会被 `make defconfig` 静默丢弃，
只能靠主开关 `CONFIG_LUCI_LANG_zh_Hans=y` 点亮。build.sh Step 6 与 CI 都会在 defconfig 之后
逐条断言这些符号，被丢掉就直接报错，不会再产出"少功能但构建成功"的固件。
