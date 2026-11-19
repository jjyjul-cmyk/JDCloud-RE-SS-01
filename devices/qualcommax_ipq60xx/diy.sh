#!/bin/bash
# ==========================================================
#  Kwrt / qualcommax-ipq60xx 设备定制脚本
#  基于官方 devices/qualcommax_ipq60xx/diy.sh，追加「无 WiFi」改造
#  内核来源：LiBwrt openwrt-6.x 分支 25.12-nss（Linux 6.12 + NSS 补丁）
# ==========================================================

shopt -s extglob

SHELL_FOLDER=$(dirname $(readlink -f "$0"))

rm -rf package/boot package/firmware/ipq-wifi target/linux/generic target/linux/qualcommax package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

git_clone_path 25.12-nss https://github.com/LiBwrt/openwrt-6.x target/linux/generic target/linux/qualcommax package/boot package/firmware/ipq-wifi package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/include/image-commands.mk -P include/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/config/Config-ipq.in -P config/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/Config.in -P ./

rm -rf feeds/kiddin9/shortcut-fe

git clone --depth 1 -b NSS-12.5-K6.x https://github.com/qosmio/nss-packages.git package/nss-packages
git clone --depth 1 https://github.com/qosmio/sqm-scripts-nss.git package/sqm-scripts-nss


# ===== FIX 2026-11-19: ECM notifier 与内核 6.12 CHAIN_EVENTS 不兼容 =====
# LiBwrt 内核启用 CONFIG_NF_CONNTRACK_CHAIN_EVENTS 后，0006 patch 强改为旧的
# nf_ct_event_notifier API（.ct_event），与内核新的 notifier_block 签名冲突，
# 编译报 ecm_conntrack_notifier.c: wrong argument type / too few arguments。
# ECM 源码本身已完整支持 CHAIN_EVENTS，禁用该 patch 即可恢复原生兼容分支。
if [ -f package/nss-packages/qca-nss-ecm/patches/0006-treewide-rework-notifier-changes-for-5.15.patch ]; then
    mv package/nss-packages/qca-nss-ecm/patches/0006-treewide-rework-notifier-changes-for-5.15.patch \
       package/nss-packages/qca-nss-ecm/patches/0006-treewide-rework-notifier-changes-for-5.15.patch.disabled
    echo "[FIX-ECM] disabled 0006 notifier patch (use native CHAIN_EVENTS)"
fi


# ===== FIX 2026-11-19b: bypass build_dir cache for ECM =====
# cachewrtbuild caches build_dir with old 0006-patched ECM source.
# Renaming the patch file does NOT force re-prepare of cached source.
# Bump PKG_VERSION -> build_dir path changes -> cache miss -> re-extract + re-patch
# with 0006 disabled -> native CONFIG_NF_CONNTRACK_CHAIN_EVENTS (new API) is used.
if [ -f package/nss-packages/qca-nss-ecm/Makefile ]; then
    sed -i 's|^PKG_VERSION:=.*|PKG_VERSION:=$(QSDK_VERSION).$(subst -,.,$(PKG_SOURCE_DATE))~$(PKG_SOURCE_VERSION)k6c|' package/nss-packages/qca-nss-ecm/Makefile
    echo "[FIX-CACHE] ECM PKG_VERSION bumped (k6c) to bypass build_dir cache"
fi



sed -i "/ECM_INTERFACE_RAWIP_ENABLE/d"  package/nss-packages/qca-nss-ecm/Makefile
rm -rf package/nss-packages/nss-userspace-oss

sed -i "s/luci uboot-envtools wpad-openssl/luci uboot-envtools wpad-mbedtls/" target/linux/qualcommax/Makefile

# ==========================================================
#  以下为「无 WiFi」定制：把无线相关全部剥离
# ==========================================================

# 1) 摘掉亚瑟设备定义里强制携带的 WiFi 板级校准数据
#    （原：DEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01）
sed -i 's/^\([[:space:]]*\)DEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01/\1DEVICE_PACKAGES :=/' \
    target/linux/qualcommax/image/ipq60xx.mk

# 2) 从 qualcommax 默认包里剔除 wpad / hostapd / 无线固件 / wifi-scripts
sed -i -e 's/ wpad-[a-z0-9_-]*//g' \
       -e 's/ hostapd[a-z0-9_-]*//g' \
       -e 's/ ath11k-firmware[a-z0-9_-]*//g' \
       -e 's/ wifi-scripts//g' \
       -e 's/ iwinfo//g' \
       -e 's/ iw//g' \
       target/linux/qualcommax/Makefile

# 3) 直接删掉无线软件包目录，杜绝被依赖重新拉起
rm -rf package/firmware/ath11k-firmware
rm -rf package/firmware/ipq-wifi
rm -rf package/firmware/wireless-regdb

# 4) 关掉无线驱动内核模块（kmod 层面）
sed -i 's/^CONFIG_PACKAGE_kmod-ath11k.*$/# CONFIG_PACKAGE_kmod-ath11k is not set/' .config 2>/dev/null
sed -i 's/^CONFIG_PACKAGE_kmod-mac80211.*$/# CONFIG_PACKAGE_kmod-mac80211 is not set/' .config 2>/dev/null

# ==========================================================
#  USB：确认 dwc3 / PHY 驱动在内核里开启（亚瑟 USB3.0 走 dwc3）
# ==========================================================
for cfg in target/linux/qualcommax/config-* target/linux/qualcommax/ipq60xx/config*; do
    [ -f "$cfg" ] || continue
    grep -q "CONFIG_USB_DWC3" "$cfg" || cat >> "$cfg" <<'EOF'
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_QCOM=y
CONFIG_USB_DWC3_OF_SIMPLE=y
CONFIG_PHY_QCOM_QUSB2=y
CONFIG_PHY_QCOM_IPQ806X_USB=y
CONFIG_USB_ROLE_SWITCH=y
EOF
done

# ==========================================================
#  硬件加解密：开启 IPQ 的 QCE(Qualcomm Crypto Engine) 与硬件随机数
#  OpenWrt 里没有 kmod-crypto-hw-qce 打包，只能走内核配置项
# ==========================================================
for cfg in target/linux/qualcommax/config-* target/linux/qualcommax/ipq60xx/config*; do
    [ -f "$cfg" ] || continue
    grep -q "CONFIG_CRYPTO_DEV_QCE" "$cfg" || cat >> "$cfg" <<'EOF'
CONFIG_CRYPTO_HW=y
CONFIG_CRYPTO_DEV_QCE=y
CONFIG_CRYPTO_DEV_QCOM_RNG=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_SHA2_ARM64_CE=y
EOF
done

# ==========================================================
#  主机名固定为 Kwrt（官方已全局替换，这里做二次保险）
# ==========================================================
sed -i "s/OpenWrt/Kwrt/g" package/base-files/files/bin/config_generate 2>/dev/null || true

# ===== FIX 2026-11-19: xray-core go.mod 要求 go>=1.27 =====
# OpenWrt golang-package.mk 写死 GOTOOLCHAIN=local，导致 go1.26 编译 xray-core 失败。
# 改成 auto 让 go 自动下载匹配的 1.27 工具链。
if [ -f feeds/packages/lang/golang/golang-package.mk ]; then
    sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' feeds/packages/lang/golang/golang-package.mk
    echo "[FIX] GOTOOLCHAIN set to auto in golang-package.mk"
else
    echo "[FIX][WARN] golang-package.mk not found at diy time"
fi
