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
