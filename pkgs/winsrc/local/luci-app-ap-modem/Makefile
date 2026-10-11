#
# luci-app-ap-modem —— 从内网访问 WAN 侧的光猫（或 LAN 侧的 AP）
#
# 需求：本机 eth0 是 WAN(PPPoE)，光猫桥接在其上、管理地址 192.168.1.1。
# PPPoE 拨起来之后系统里没有任何 192.168.1.0/24 的路径（默认路由指向 pppoe-wan），
# 内网客户端因此够不到光猫后台。本包在 WAN 物理设备上挂一个同网段的虚拟 IP，
# 并把该接口划进 WAN 防火墙区域，让 LAN → 光猫 的流量能穿过 masquerade 出去。
#
# 实现方式（记住这个形状，看日志时不容易懵）：建一对 veth（vap-lan ←→ vap-lan-peer），
# vap-lan 桥进 br-lan；另起接口 vap_wan 直接跑在 eth0 上；vap_lan/vap_wan 都在
# wan zone 里。所以 `ip -br link` 会多出两个 vap-* 网卡，`uci show network` 会多出
# veth_lan / veth_lan_peer / vap_lan / vap_wan 四段 —— 都是这个插件写的。
#
# ============================================================================
# ★ 为什么是"源码化"，而不是下载 apk 丢进 ImageBuilder ★
# 这个 app 是 iStoreOS/易有云（linkease）的第三方插件，**不在 OpenWrt 官方源**。
# 唯一的第三方分发是 dl.openwrt.ai，而它只发 .ipk —— OpenWrt 25.12 已改用 apk，
# apk-tools 3 只认 v3 容器格式（魔数 ADBd），**读不了 ipk**（实测传统 v2 拼包报
# "unexpected end of file"，且 apk 3.0.5 没有 mkpkg 子命令）。arm64 下也一样。
# 因此把那份 ipk 解包后的文件源码化，走 SDK 正常编译 —— 与 msd_lite / vlmcsd /
# luci-app-cnc-upgrade 同一条路，产出标准 .apk，可被 verify.sh 与 apk 断言覆盖。
#
#   ipk 来源（本目录内容即由它解包而来，逐字节一致）：
#     https://dl.openwrt.ai/releases/25.12/packages/x86_64/kiddin9/
#       luci-app-ap-modem_1.0.5-r20241208-r3_all.ipk
#
# ★ 相对上游的四处改动 ★（前三处都写在对应文件头里，看文件比看这里清楚）
#   1. root/etc/init.d/ap_modem —— 打了**两个**补丁，都是上游的真实缺陷：
#        (a) start_service / stop_service 里补 `/etc/init.d/firewall reload`。
#            ★装上了但内网访问不了★：它只 commit firewall 配置、从不重载，
#            于是 nft 里 masquerade 的 oifname 少了 eth0，去光猫的包不做 SNAT。
#        (b) boot() 里补一次 start_service（上游只有一个空的 `rc_procd true`）。
#            ★全新刷机后功能不生效★：它的 service_triggers 挂的是
#            /etc/config/network 的 config.change，而首启没人 commit 它，
#            写 vap_* 的 generate_config 因此永远不会被调用。
#            两条都是真机实测出来的，细节见该文件里各自的注释。
#   2. root/etc/hotplug.d/iface/99-ap-modem
#        新增：接口 ifup 时的兜底重载（只在规则集真的缺 eth0 时才动）。
#   3. root/etc/config/ap_modem
#        默认改成 enabled=1 + wan ipaddr 192.168.1.254（上游出厂是不启用的）。
#   4. 丢弃上游的 /etc/uci-defaults/luci-i18n-ap-modem-zh-cn
#        它只做 `uci set luci.languages.zh_cn=...`，而镜像里本来就装了
#        luci-i18n-base-zh-cn，重复且与语言包来源不一致。
#
# ★ 中文包为什么是预编译 .lmo，而不是 po/ ★
# 上游 ipk 里带的就是编译好的 ap-modem.zh-cn.lmo，**没有 .po 源**。
# 反推 .po 要先反解 LuCI 的 lmo 容器格式（纯 NUL 分隔串、无索引头），
# 收益不抵风险，所以直接把那份 .lmo 放在 root/usr/lib/lua/luci/i18n/ 下 ——
# 路径与文件名和 luci-i18n-<app>-zh-cn 装出来的完全一致，LuCI 一样能读到。
# ⇒ 因此本包**不进 SDK_EXTRA_APKS**（那是给"由 po/ 编译出语言包"的 app 用的）。
#
# ★ 依赖 kmod-veth ★
# 上游把 Depends 写成只有 libc，但它的 generate_config 无条件建 veth 网卡。
# 缺这个模块时 netifd 建不出 vap-lan，日志里是 `cannot find module - veth`，
# 插件功能不完整。这里补成真实依赖，不再依赖 ImageBuilder 恰好带着它。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ap-modem
PKG_VERSION:=1.0.5
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=iStoreOS / linkease (upstream); packaged by CncTion 1338NP-12 build kit

LUCI_TITLE:=Access AP / Modem behind the WAN port
LUCI_DESCRIPTION:=Let LAN clients reach an AP or modem that lives on a different \
 subnet behind the WAN port. Typical case: a PPPoE-bridged ONT whose management \
 address (192.168.1.1) is otherwise unreachable once the router dials PPPoE.
LUCI_DEPENDS:=+luci-base +kmod-veth
LUCI_PKGARCH:=all

# /etc/config/ap_modem 是 conffile：升级时设备上的旧文件会覆盖镜像里的新文件
# （/etc/config/ 整目录都在 base-files 的 keep.d 里，真机 `sysupgrade -l` 实测
#   会列出 /etc/config/ap_modem），所以上面的默认值只服务"全新刷写"，
# 老设备上操作者改过的 enabled / ipaddr **不会被下次刷机冲掉**。
define Package/$(PKG_NAME)/conffiles
/etc/config/ap_modem
endef

# 说明：这里刻意不定义 Package/$(PKG_NAME)/install ——
# feeds/luci/luci.mk 会在最后重新定义它，并自动安装 root/ 与 htdocs/ 下的全部文件。
# 只要把文件放在 root/ 和 htdocs/ 下即可（root/* → /，htdocs/* → /www/）。
include $(TOPDIR)/feeds/luci/luci.mk

# ★ 下面这行注释不能删！
# SDK 扫描包元数据的规则是（见 include/scan.mk）：
#     find package -maxdepth 5 -name Makefile | xargs grep -E 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
# 只有"自己的 Makefile 里出现这个字符串"的目录才会被收录，否则编译时会报
#     *** No rule to make target 'package/luci-app-ap-modem/compile'
# luci.mk 系包真正的 BuildPackage 展开在 luci.mk 里，所以必须靠这行注释来被扫到。
# call BuildPackage - OpenWrt buildroot signature
