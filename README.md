# Kwrt 京东云亚瑟（JDCloud RE-SS-01）定制固件

基于 **kiddin9/Kwrt 25.12** 分支，用 GitHub Actions 在线编译。

| 项目 | 值 |
|---|---|
| 机型 | JDCloud RE-SS-01（亚瑟 AX1800 Pro） |
| 平台 | qualcommax / ipq60xx，IPQ6000，aarch64_cortex-a53 |
| 内核 | Linux 6.12（LiBwrt `openwrt-6.x` `25.12-nss` 分支，带 NSS 补丁） |
| WiFi | **无**（驱动 / 固件 / 校准数据 / hostapd 全剥离） |
| USB | **有**（USB3.0 dwc3 + QUSB2/IPQ806X PHY + 存储 + 网卡 + 4G 模块） |
| 硬件加速 | NSS 满血（ECM + crypto 卸载 + 内核 crypto 引擎） |
| 包管理 | **opkg**（已禁用 apk，ssr-plus 只在 opkg 源里） |
| 预装 | luci-app-ssr-plus（含中文） |
| 主机名 | Kwrt |
| 默认管理 IP | 10.0.0.1（Kwrt 官方改过，原为 192.168.1.1） |

---

## 一、三步开编

**不需要 fork Kwrt。** 这是一个独立配置仓库，构建时工作流会自动从上游
`kiddin9/Kwrt` 的 `25.12` 分支稀疏拉取 `devices/` 基础设施（几十秒），
再用本仓库的文件覆盖上去。所以仓库里只需放这几个文件：

```
.github/workflows/build-jdcloud-re-ss-01.yml     编译工作流
devices/qualcommax_ipq60xx/.config               核心配置
devices/qualcommax_ipq60xx/diy.sh                去掉 WiFi
```

### 1. 推到你的仓库
```sh
git clone https://github.com/jjyjul-cmyk/JDCloud-RE-SS-01.git
cd JDCloud-RE-SS-01
# 把上面三个文件按同样路径放进来（保持目录结构）
git add -A
git commit -m "Kwrt for JDCloud RE-SS-01: 无WiFi + USB + NSS + ssr-plus"
git push
```

### 2. 触发编译
`push` 到 `main` 且改动了 `devices/**` 或 workflow 时会**自动开始编译**。
也可以手动：`Actions` → `Build Kwrt for JDCloud RE-SS-01` → `Run workflow`。

### 3. 下载产物
编译约 **1.5～3 小时**（ssr-plus 要编 Go 系的 xray-core，这是最慢的一环）。
完成后在 Artifacts 里下载 `Kwrt-jdcloud-re-ss-01`，保留 30 天。

> 不需要配置任何 Secret。工作流已去掉官方的依赖服务器上传、Telegram 推送等步骤。
>
> 第一次跑之前建议先去 `Settings → Actions → General` 确认
> Workflow permissions 至少是 `Read repository contents`。

### 为什么不用 fork
fork Kwrt 会连带 3000+ 次提交的完整 OpenWrt 源码树，仓库巨大、同步麻烦、
还容易和上游 devices/ 冲突。独立仓库模式下：
- 你只维护 `qualcommax_ipq60xx` 下的两个配置文件，干净；
- 上游 `devices/common/diy.sh` 的构建 hack 每次构建自动取最新，不用手动跟进；
- 合并规则是 `cp -rn`（不覆盖已存在文件），**你仓库里的文件永远优先**。

---

## 二、刷机

产物在 `openwrt/bin/targets/qualcommax/ipq60xx/`：

| 文件 | 用途 |
|---|---|
| `*jdcloud_re-ss-01-squashfs-factory.bin` | 首次刷入（Hugo Uboot 或 原厂 CDT + GPT Uboot 环境下刷） |
| `*jdcloud_re-ss-01-squashfs-sysupgrade.bin` | 已在 OpenWrt 时升级用，不保留配置 |

亚瑟是 eMMC 机型，首次刷入后第一次开机约 5 分钟，之后重启约 15 秒。
默认 `root` / 空密码，管理地址 `http://10.0.0.1`。

刷完**务必**对照同目录的 **`验收清单.md`** 逐项验证——编译成功不代表 NSS 加载了、WiFi 真的没了，
清单里有每一项的验证命令和预期输出。

---

## 三、配置说明

### 无 WiFi 是怎么做到的
1. `diy.sh` 里摘掉 `ipq60xx.mk` 中强制携带的 `ipq-wifi-jdcloud_re-ss-01`；
2. 从 `target/linux/qualcommax/Makefile` 默认包中剔除 `wpad` / `hostapd` / `ath11k-firmware` / `wifi-scripts`；
3. 直接删除 `package/firmware/{ath11k-firmware,ipq-wifi,wireless-regdb}` 目录；
4. `.config` 中 `kmod-ath11k` / `kmod-mac80211` 全部 `is not set`。

### 硬件加速（你说的"硬件解码"）
IPQ6000 没有视频硬解单元，路由器上的硬件加速指的是 **NSS 网络子系统卸载**：
- `kmod-qca-nss-drv` + `kmod-qca-nss-ecm`：转发卸载，跑满千兆时 CPU 占用极低；
- `kmod-qca-nss-crypto` + `kmod-qca-nss-cfi` + 内核 crypto 引擎：AES/SHA 加解密卸载，ssr-plus 的加密流量直接受益。

⚠️ Kwrt 官方的 Defconfig 步骤会执行 `sed -i "s/\(kmod-qca.*\)=m/\1=n/" .config` 把 NSS 模块关掉，
所以本配置里 NSS 全部写成 `=y`（而不是 `=m`），这样不会被清掉。

IPQ 的加密引擎 **没有** `kmod-crypto-hw-qce` 这种包，是纯内核配置项，
已由 `diy.sh` 往 target 内核配置里追加 `CONFIG_CRYPTO_DEV_QCE=y` / `CONFIG_CRYPTO_DEV_QCOM_RNG=y` 开启。

### 包名核对记录
配置里的包名已逐个对着真实源码核过，修正了几处"看起来对、实际不存在"的写法
（OpenWrt 对无效符号是静默忽略的，写错了不会报错，只会悄悄不生效）：

| 原写法 | 实际情况 | 修正为 |
|---|---|---|
| `nss-firmware-ipq6018` | 不存在，固件包按平台划分 | `nss-firmware-ipq60xx` |
| `kmod-qca-nss-drv-ovpnmgr` | 不存在 | `kmod-qca-nss-drv-ovpn-mgr` |
| `kmod-usb-dwc3-of-simple` | 25.12 无此包 | 删除（usb-dwc3 已含） |
| `kmod-phy-qcom-qusb2` / `-ipq806x-usb` | 25.12 无此 kmod | 删除，改为内核配置项 |
| `kmod-crypto-hw-qcom-rng` | 不存在 | 删除，改为 `CONFIG_CRYPTO_DEV_QCE` |
| `kmod-qca-nss-drv-vlan-mgr` | **误关**（它是有线 VLAN 卸载，跟 WiFi 无关） | 改为 `=y` |

顺带补上了 `qdisc`（NSS QoS，配合 sqm-scripts-nss）、`match`、`mirror`、`netlink` 四个 NSS 子模块。

### USB
亚瑟的 DTS（`ipq6000-re-ss-01.dts`）里有 `&usb3` / `&ssphy_0` / `&qusb_phy_0` 节点，硬件确实有 USB3.0。
已编入 dwc3 驱动、QUSB2/IPQ806X PHY、UAS 存储、ext4/vfat/exfat/ntfs3/f2fs、USB 网卡（RTL8152/ASIX）、
4G 模块（option/qualcomm/sierra + wwan）、`block-mount`、`hd-idle`。

---

## 四、排错

| 现象 | 处理 |
|---|---|
| NSS 模块编译失败 | 删除 `.config` 里 `CONFIG_PACKAGE_kmod-qca-nss-*` 全部行，只留固件和 ECM，或全部注释退化成纯软件转发 |
| ssr-plus / xray 编不过或超时 | 删掉 `CONFIG_PACKAGE_luci-app-ssr-plus=y` 先出基础固件，之后 `opkg install` 在线装 |
| 固件体积超限 | 注释掉 USB 网卡 / 4G 模块那一段，或去掉 `kmod-fs-f2fs`、`hd-idle` |
| 提示 unknown package | 某些 `kmod-qca-nss-drv-*` 子包在不同分支里名字可能变，defconfig 会自动忽略无效行，不影响编译 |

想看完整配置是否被正确应用，看日志里 `关键配置自检` 那一段的输出。

---

## 五、Open-Box 后期安装

按你说的，不预装。刷好固件后 SSH 登路由器执行：

```sh
curl -fsSL https://raw.githubusercontent.com/liandu2024/Open-Box/main/scripts/install.sh | sh
```

GitHub 不通时：

```sh
curl -fsSL https://gh-proxy.com/raw.githubusercontent.com/liandu2024/Open-Box/main/scripts/install.sh | sh -s -- --mirror
```

arm64 完整包约 75MB（含 sing-box + Node + GeoSite/GeoIP），要求 ≥512MB 存储和内存。
这也是不把它编进固件的原因——塞进 squashfs 会把固件撑到 100MB+，容易超分区。
