#!/usr/bin/env bash
#
# Prepare an official OpenWrt tree for this repository's custom firmware.
# Build the firmware separately with the bounded job count printed below.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}==> $*${NC}"; }
info()  { echo -e "    ${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "    ${YELLOW}[warn]${NC} $*"; }
error() { echo -e "    ${RED}[error]${NC} $*" >&2; }

OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_REF="${OPENWRT_REF:-master}"  # branch/tag; choose a stable ref to pin upstream
OPENWRT_DIR="openwrt"
ARGON_FEED_URL="https://github.com/jerrykuku/luci-theme-argon.git"
ARGON_CONFIG_FEED_URL="https://github.com/jerrykuku/luci-app-argon-config.git"
PASSWALL_FEED_NAME="passwall"
PASSWALL_FEED_URL="https://github.com/xiaorouji/luci-app-passwall.git"
PASSWALL_PKG_FEED_NAME="passwall_pkgs"
PASSWALL_PKG_FEED_URL="https://github.com/xiaorouji/openwrt-passwall-packages.git"
CUSTOM_FEED_NAME="custom"
TIMECONTROL_FEED_NAME="timecontrol"
TIMECONTROL_FEED_URL="https://github.com/sirpdboy/luci-app-timecontrol.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to at most four jobs to reduce OOM risk on the 8-10 GiB build host.
# Set JOBS explicitly to override this cap after checking available RAM.
CPU_COUNT="$(nproc)"
JOBS="${JOBS:-$(( CPU_COUNT < 4 ? CPU_COUNT : 4 ))}"
case "$JOBS" in ''|*[!0-9]*|0) error "JOBS must be a positive integer"; exit 2 ;; esac

step "Step 1: Build dependencies"
echo "Install on Ubuntu/Debian if missing:"
echo "  sudo apt-get update && sudo apt-get install -y build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev python3 python3-setuptools rsync swig unzip zlib1g-dev file wget libelf-dev ccache"

step "Step 2: OpenWrt source"
if [ ! -d "${SCRIPT_DIR}/${OPENWRT_DIR}/.git" ]; then
    [ ! -e "${SCRIPT_DIR}/${OPENWRT_DIR}" ] || { error "Path ${SCRIPT_DIR}/${OPENWRT_DIR} exists but is not an OpenWrt git checkout; move it aside before continuing."; exit 1; }
    git clone --depth 1 -b "${OPENWRT_REF}" "${OPENWRT_REPO}" "${SCRIPT_DIR}/${OPENWRT_DIR}"
    info "cloned ${OPENWRT_REPO} (${OPENWRT_REF})"
else
    info "reusing existing checkout at ${SCRIPT_DIR}/${OPENWRT_DIR}"
fi
OPENWRT_DIR="${SCRIPT_DIR}/${OPENWRT_DIR}"

# Never silently replace a pre-existing config/overlay that this script has not
# marked as managed. Explicit opt-in is required for legacy build trees.
if [ ! -f "${OPENWRT_DIR}/.lede-ni-managed" ] && { [ -e "${OPENWRT_DIR}/.config" ] || [ -e "${OPENWRT_DIR}/files" ]; }; then
    if [ "${ALLOW_EXISTING_OPENWRT:-0}" != "1" ]; then
        error "Existing .config/files found without this script's marker. Review them, back them up, then rerun with ALLOW_EXISTING_OPENWRT=1 to explicitly allow replacement."
        exit 1
    fi
fi

step "Step 3: Feeds"
cd "${OPENWRT_DIR}"
for f in "${PASSWALL_FEED_NAME}" "${PASSWALL_PKG_FEED_NAME}" "${TIMECONTROL_FEED_NAME}"; do
    sed -i "/^src-git[^ ]* ${f} /d" feeds.conf.default
done
echo "src-git ${PASSWALL_FEED_NAME} ${PASSWALL_FEED_URL}" >> feeds.conf.default
echo "src-git ${PASSWALL_PKG_FEED_NAME} ${PASSWALL_PKG_FEED_URL}" >> feeds.conf.default
echo "src-git ${TIMECONTROL_FEED_NAME} ${TIMECONTROL_FEED_URL}" >> feeds.conf.default
sed -i "/^src-link[^ ]* ${CUSTOM_FEED_NAME} /d" feeds.conf.default
echo "src-link ${CUSTOM_FEED_NAME} ${SCRIPT_DIR}/package" >> feeds.conf.default

mkdir -p package/feeds/argon
# These are generated upstream checkouts, not user configuration. Replace them
# only after preserving the current config and files overlay below.
git clone --depth 1 "${ARGON_FEED_URL}" package/feeds/argon/luci-theme-argon.new
git clone --depth 1 "${ARGON_CONFIG_FEED_URL}" package/feeds/argon/luci-app-argon-config.new
rm -rf package/feeds/argon/luci-theme-argon package/feeds/argon/luci-app-argon-config
mv package/feeds/argon/luci-theme-argon.new package/feeds/argon/luci-theme-argon
mv package/feeds/argon/luci-app-argon-config.new package/feeds/argon/luci-app-argon-config

./scripts/feeds update -a
./scripts/feeds install -a
info "feeds installed"

step "Step 4: Back up then apply config and overlay"
if git -C "${SCRIPT_DIR}" rev-parse --short HEAD >/dev/null 2>&1; then
    info "repository revision $(git -C "${SCRIPT_DIR}" rev-parse --short HEAD)"
    if [ -n "$(git -C "${SCRIPT_DIR}" status --porcelain)" ]; then
        warn "repository has uncommitted changes; verify they are intentional before building"
        git -C "${SCRIPT_DIR}" status --short
    fi
fi
[ -f "${SCRIPT_DIR}/seed.config" ] || { error "seed.config not found"; exit 1; }
[ -d "${SCRIPT_DIR}/files" ] || { error "files/ overlay not found"; exit 1; }

if [ -e "${OPENWRT_DIR}/.config" ] || [ -e "${OPENWRT_DIR}/files" ]; then
    BACKUP_DIR="${SCRIPT_DIR}/.build-backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP_DIR}"
    [ ! -e "${OPENWRT_DIR}/.config" ] || cp -a "${OPENWRT_DIR}/.config" "${BACKUP_DIR}/config.before"
    [ ! -e "${OPENWRT_DIR}/files" ] || cp -a "${OPENWRT_DIR}/files" "${BACKUP_DIR}/files.before"
    info "previous .config/files preserved in ${BACKUP_DIR}"
fi
cp "${SCRIPT_DIR}/seed.config" "${OPENWRT_DIR}/.config"
rm -rf "${OPENWRT_DIR}/files"
cp -a "${SCRIPT_DIR}/files" "${OPENWRT_DIR}/files"
touch "${OPENWRT_DIR}/.lede-ni-managed"
info "repository config and overlay applied"

step "Step 5: Resolve dependencies"
make defconfig
info ".config expanded"

step "Step 6: Verify required features"
required_symbols="
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-app-softether-service=y
CONFIG_PACKAGE_luci-app-timecontrol=y
CONFIG_PACKAGE_softethervpn5-server=y
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y
CONFIG_PACKAGE_luci-proto-wireguard=y
CONFIG_PACKAGE_px5g-mbedtls=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y
"
missing=""
for s in ${required_symbols}; do grep -qxF "$s" .config || missing="${missing} ${s}"; done
if [ -n "${missing}" ]; then
    error "defconfig dropped these symbols:${missing}"
    error "Fix seed.config or the package dependencies; refusing to build an incomplete image."
    exit 1
fi
i18n_count=$(grep -cE '^CONFIG_PACKAGE_luci-i18n-.*zh-cn=y$' .config || true)
info "required symbols present; ${i18n_count} Chinese translation packages"

# Record exact upstream/feed commits so a build can be audited and source refs
# can be pinned later. This is a manifest, not a claim that rolling master is fixed.
{
    echo "repository_commit=$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "openwrt_ref=${OPENWRT_REF}"
    echo "openwrt_commit=$(git rev-parse HEAD)"
    for d in feeds/* package/feeds/argon/*; do
        [ -d "$d" ] || continue
        commit=$(git -C "$d" rev-parse HEAD 2>/dev/null) || continue
        echo "${d}_commit=${commit}"
    done
} > "${OPENWRT_DIR}/build-sources.txt"

echo
echo -e "${GREEN}Ready. Compile with:${NC}"
echo "    cd ${OPENWRT_DIR} && make -j${JOBS} V=s"
echo "Default compile jobs: ${JOBS} (override with JOBS=N after checking RAM)"
echo "Source manifest: ${OPENWRT_DIR}/build-sources.txt"
echo -e "${YELLOW}root password is intentionally left empty as requested; do not expose management services to the Internet.${NC}"
