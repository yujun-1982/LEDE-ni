#!/usr/bin/env bash
#
# build.sh - prepare an official OpenWrt tree for this repo's custom firmware
#
# What it does:
#   1. install build dependencies (Ubuntu/Debian)
#   2. clone the official OpenWrt source
#   3. add the plugin feeds and clone the Argon theme
#   4. apply seed.config as .config and files/ as the rootfs overlay
#   5. run 'make defconfig' to resolve dependencies
#   6. verify no requested symbol was silently dropped
#   7. print the compile command
#
# It never compiles the firmware itself - step 7 is run by you, so a long
# build stays under your control.
#
# IMPORTANT: the custom feed is this directory, NOT the GitHub URL, so that
# the feeds, seed.config and files/ can never come from two different
# revisions of this repo.
#

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}==> $*${NC}"; }
info()  { echo -e "    ${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "    ${YELLOW}[warn]${NC} $*"; }
error() { echo -e "    ${RED}[error]${NC} $*" >&2; }

OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
# 25.12+ series: apk package manager and the ucode/JS LuCI. Do not use an
# older stable branch - the plugins and the .apk files here assume master.
OPENWRT_BRANCH="master"
OPENWRT_DIR="openwrt"

# Argon theme (jerrykuku master branch - required for 25.12+ ucode/JS).
# It is a single-package repo (Makefile at the root), so 'scripts/feeds'
# cannot treat it as a feed; it is cloned straight into package/feeds/.
ARGON_FEED_URL="https://github.com/jerrykuku/luci-theme-argon.git"
ARGON_CONFIG_FEED_URL="https://github.com/jerrykuku/luci-app-argon-config.git"

# PassWall needs TWO feeds: the LuCI app plus its backend packages.
PASSWALL_FEED_NAME="passwall"
PASSWALL_FEED_URL="https://github.com/xiaorouji/luci-app-passwall.git"
PASSWALL_PKG_FEED_NAME="passwall_pkgs"
PASSWALL_PKG_FEED_URL="https://github.com/xiaorouji/openwrt-passwall-packages.git"

# Packages kept in this repo's package/ directory, exposed as a src-link feed.
CUSTOM_FEED_NAME="custom"

# TimeControl (schedule-based access control).
TIMECONTROL_FEED_NAME="timecontrol"
TIMECONTROL_FEED_URL="https://github.com/sirpdboy/luci-app-timecontrol.git"

# SoftEtherVPN needs no extra feed: softethervpn5-* is in the official
# packages feed and luci-app-softether in the official luci feed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"

step "Step 1: Build dependencies"
echo "    If these are missing, run:"
echo "      sudo apt-get update && sudo apt-get install -y \\"
echo "        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \\"
echo "        gettext git libncurses5-dev libssl-dev python3 python3-setuptools \\"
echo "        rsync swig unzip zlib1g-dev file wget libelf-dev ccache"

step "Step 2: OpenWrt source"
if [ ! -d "${SCRIPT_DIR}/${OPENWRT_DIR}/.git" ]; then
    git clone --depth 1 -b "${OPENWRT_BRANCH}" "${OPENWRT_REPO}" "${SCRIPT_DIR}/${OPENWRT_DIR}"
    info "cloned ${OPENWRT_REPO} (${OPENWRT_BRANCH})"
else
    info "reusing existing checkout at ${SCRIPT_DIR}/${OPENWRT_DIR}"
fi

OPENWRT_DIR="${SCRIPT_DIR}/${OPENWRT_DIR}"

step "Step 3: Feeds"
cd "${OPENWRT_DIR}"

for f in "${PASSWALL_FEED_NAME}" "${PASSWALL_PKG_FEED_NAME}" "${TIMECONTROL_FEED_NAME}"; do
    sed -i "/^src-git[^ ]* ${f} /d" feeds.conf.default
done

echo "src-git ${PASSWALL_FEED_NAME} ${PASSWALL_FEED_URL}"          >> feeds.conf.default
echo "src-git ${PASSWALL_PKG_FEED_NAME} ${PASSWALL_PKG_FEED_URL}"  >> feeds.conf.default
echo "src-git ${TIMECONTROL_FEED_NAME} ${TIMECONTROL_FEED_URL}"    >> feeds.conf.default

# Packages maintained inside this repo (package/luci-app-softether-service).
# A src-link feed keeps them versioned with the config instead of needing a
# separate repository.
sed -i "/^src-link[^ ]* ${CUSTOM_FEED_NAME} /d" feeds.conf.default
echo "src-link ${CUSTOM_FEED_NAME} ${SCRIPT_DIR}/package" >> feeds.conf.default

# Argon is two single-package repos (Makefile at the root), so 'scripts/feeds'
# cannot treat either as a feed; they are cloned straight into package/feeds/.
# The config app lives in its own repo and provides 系统 -> Argon 设置.
mkdir -p package/feeds/argon
rm -rf package/feeds/argon/luci-theme-argon package/feeds/argon/luci-app-argon-config
git clone --depth 1 "${ARGON_FEED_URL}" package/feeds/argon/luci-theme-argon
git clone --depth 1 "${ARGON_CONFIG_FEED_URL}" package/feeds/argon/luci-app-argon-config
info "argon theme + config app cloned into package/feeds/argon/"

./scripts/feeds update -a
./scripts/feeds install -a
info "feeds installed"

step "Step 4: Apply seed.config and files/ overlay"
if git -C "${SCRIPT_DIR}" rev-parse --short HEAD >/dev/null 2>&1; then
    info "building from ${SCRIPT_DIR} @ $(git -C "${SCRIPT_DIR}" rev-parse --short HEAD) - $(git -C "${SCRIPT_DIR}" log -1 --format=%s | cut -c1-60)"
    if [ -n "$(git -C "${SCRIPT_DIR}" status --porcelain)" ]; then
        warn "working tree has uncommitted changes:"
        git -C "${SCRIPT_DIR}" status --short | sed 's/^/         /'
    fi
else
    warn "${SCRIPT_DIR} is not a git checkout - cannot tell which revision this is"
fi

[ -f "${SCRIPT_DIR}/seed.config" ] || { error "seed.config not found"; exit 1; }
cp "${SCRIPT_DIR}/seed.config" "${OPENWRT_DIR}/.config"
info "seed.config -> .config"

rm -rf "${OPENWRT_DIR}/files"
cp -r "${SCRIPT_DIR}/files" "${OPENWRT_DIR}/files"
info "files/ -> ${OPENWRT_DIR}/files/"

step "Step 5: Resolve dependencies"
make defconfig
info ".config expanded"

# A symbol that is absent from the generated .config was silently dropped by
# Kconfig - unknown name, unsatisfied dependency, or no prompt to set it from
# (that is how the hidden luci-i18n-*-zh-cn packages behave). The build would
# still succeed and produce firmware with the feature missing, so fail here.
step "Step 6: Verify the resolved configuration"
required_symbols="
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-app-softether-service=y
CONFIG_PACKAGE_luci-app-timecontrol=y
CONFIG_PACKAGE_softethervpn5-server=y
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y
"
missing=""
for s in ${required_symbols}; do
    grep -qxF "$s" .config || missing="${missing} ${s}"
done
if [ -n "${missing}" ]; then
    error "defconfig dropped these symbols:${missing}"
    error "Fix the name in seed.config, or select the package/dependency it needs."
    exit 1
fi
i18n_count=$(grep -cE '^CONFIG_PACKAGE_luci-i18n-.*zh-cn=y$' .config || true)
info "all required symbols present; ${i18n_count} Simplified Chinese translation packages"

echo
echo -e "${GREEN}Ready. Compile with:${NC}"
echo "    cd ${OPENWRT_DIR} && make -j${JOBS} V=s"
echo
echo -e "${CYAN}Deliverable for PVE:${NC}"
echo "    ${OPENWRT_DIR}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz"
echo
echo -e "${YELLOW}The two .apk files ship inside the image and are installed by${NC}"
echo -e "${YELLOW}files/etc/uci-defaults/99-install-pkgs on first boot.${NC}"
echo -e "${YELLOW}Check /tmp/uci-defaults-99-install-pkgs.log if a plugin is missing.${NC}"
