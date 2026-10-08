include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-softether-service
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=yujun-1982

LUCI_TITLE:=LuCI page to start and stop the SoftEther VPN Server
LUCI_DEPENDS:=+luci-base +softethervpn5-server
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
