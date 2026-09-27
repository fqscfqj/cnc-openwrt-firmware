#
# luci-app-cnc-upgrade —— 固件在线升级（CncTion 1338NP-12 专用）
#
# 功能：在 LuCI 里检查本项目发布的新固件 → 下载 → 校验 sha256/大小 →
#       用 sysupgrade 刷写并重启（默认保留配置）。
#
# 全部逻辑在 root/usr/sbin/cnc-upgrade（POSIX sh）里，页面只负责调用与展示，
# 因此可以脱离硬件用 tests/run.sh 做单元测试。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cnc-upgrade
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=CncTion 1338NP-12 build kit

LUCI_TITLE:=Firmware online upgrade (check / download / flash)
LUCI_DESCRIPTION:=Check for newer firmware published by this project, verify its \
 sha256 and flash it from LuCI. Keeps the configuration by default.
LUCI_DEPENDS:=+luci-base +curl +jsonfilter +ca-bundle
LUCI_PKGARCH:=all

# 说明：这里刻意不定义 Package/$(PKG_NAME)/install ——
# feeds/luci/luci.mk 会在最后重新定义它，并自动安装 root/ 与 htdocs/ 下的全部文件。
# 只要把文件放在 root/ 和 htdocs/ 下即可。

define Package/$(PKG_NAME)/conffiles
/etc/config/cnc_upgrade
endef

include $(TOPDIR)/feeds/luci/luci.mk

# ★ 下面这行注释不能删！
# SDK 扫描包元数据的规则是（见 include/scan.mk）：
#     find package -maxdepth 5 -name Makefile | xargs grep -E 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
# 只有"自己的 Makefile 里出现这个字符串"的目录才会被收录，否则编译时会报
#     *** No rule to make target 'package/luci-app-cnc-upgrade/compile'
# luci.mk 系包真正的 BuildPackage 展开在 luci.mk 里，所以必须靠这行注释来被扫到——
# 这也是所有官方 LuCI 应用 Makefile 结尾都有它的原因。
# call BuildPackage - OpenWrt buildroot signature
