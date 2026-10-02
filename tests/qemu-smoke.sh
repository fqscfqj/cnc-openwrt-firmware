#!/usr/bin/env bash
# =============================================================================
# QEMU 冒烟测试 —— 把镜像当真实硬盘引导，并从串口控制台"进系统里"跑断言
#
#   bash tests/qemu-smoke.sh out/openwrt-...-combined-efi.img.gz
#
# 三步：
#   1) 用 OVMF(UEFI) 引导镜像；挂 4 张 e1000e 网卡 ⇒ eth0/eth1/eth2/eth3，与真机口序一致
#   2) 抓完整串口日志（有可用的 /dev/kvm 时约 30–60 秒；纯 TCG 软件模拟 3–10 分钟）
#   3) 以 root 从串口登录，运行系统内断言：插件是否真的装好/可执行、uci 预置是否生效、
#      IPv6 是否打开、内核模块是否在、br-lan 是否真的起来、LuCI 是否真的能访问……
#      并把 uname / 接口列表 / apk 数量 / logread 等系统信息一起存档
#
# 环境变量：
#   CNC_QEMU_WORK          工作目录（默认自动挑剩余空间够的目录；★不要用小 tmpfs）
#   CNC_QEMU_OUT           结果与日志保存目录（默认 = 镜像所在目录）
#   CNC_QEMU_MEM           内存 MB（默认 2048）
#   CNC_QEMU_BOOT_TIMEOUT  等待系统启动完成的秒数（默认 480；没有 KVM 的纯软件模拟要留足）
#   CNC_QEMU_EXEC          1=进系统跑断言；0=只看启动日志（默认 1）
#   CNC_QEMU_KEEP          1=保留工作目录便于排障（默认 0）
#   CNC_QEMU_DISK_IF       磁盘总线（默认 virtio；本镜像 CONFIG_VIRTIO_BLK=y，可改 ide）
#
# 依赖：qemu-system-x86_64、OVMF（Debian/Ubuntu: apt install qemu-system-x86 ovmf）；
#       进系统跑断言需要 python3；没有 python3 时自动降级为"只看启动日志"。
#
# 局限（有意为之，不在这里验证）：QEMU 里没有 Intel I226-V、没有光猫/PPPoE 环境，
#       所以 igc 真机驱动、PPPoE 拨号、IPv6 从运营商拿地址这三件事仍由上机核对保证，
#       见 03-固件构建与升级.md §5。
# =============================================================================
set -uo pipefail

IMG_ARG="${1:-}"
[ -n "$IMG_ARG" ] && [ -f "$IMG_ARG" ] || { echo "用法: bash tests/qemu-smoke.sh <image.img.gz>"; exit 2; }
IMG="$(cd "$(dirname "$IMG_ARG")" && pwd)/$(basename "$IMG_ARG")"
IMG_DIR="$(dirname "$IMG")"

# ------------------------------------------------------------------ 输出工具
c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=; c_r=; c_y=; c_b=; c_0=; }
log()  { printf '%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
ok()   { printf '  %s✔%s %s\n' "$c_g" "$c_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$c_r" "$c_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✘ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

# ------------------------------------------------------------------ 依赖检查
QEMU_BIN="$(command -v qemu-system-x86_64 || true)"
[ -n "$QEMU_BIN" ] || die "缺少 qemu-system-x86_64，无法冒烟（Debian/Ubuntu: apt install qemu-system-x86）"

OVMF_CODE=""; OVMF_VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF_CODE_4M.fd /usr/share/ovmf/OVMF_CODE.fd; do
	[ -f "$c" ] || continue
	OVMF_CODE="$c"
	for v in "${c%_CODE*}_VARS${c##*_CODE}" /usr/share/OVMF/OVMF_VARS.fd \
	         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/ovmf/OVMF_VARS.fd; do
		[ -f "$v" ] && { OVMF_VARS="$v"; break; }
	done
	[ -n "$OVMF_VARS" ] && break
	OVMF_CODE=""
done
if [ -z "$OVMF_CODE" ]; then
	for c in /usr/share/OVMF/OVMF.fd /usr/share/ovmf/OVMF.fd; do
		[ -f "$c" ] && { OVMF_CODE="$c"; break; }
	done
fi
[ -n "$OVMF_CODE" ] || die "找不到 OVMF 固件（Debian/Ubuntu: apt install ovmf）"

# ------------------------------------------------------------------ 磁盘空间估算
# 注意：镜像原始大小约 4.2 GB，超过 2^32 字节，`gzip -l` 的 ISIZE 字段会回绕成几十 MB，
# 所以优先用构建产物自带的 *.layout.txt（GPT 分区表）反推真实大小。
raw_mb() {
	local lay="${IMG%.img.gz}.layout.txt" v=""
	if [ -f "$lay" ]; then
		v="$(awk -F'[ =]+' '/start_lba=/{ e = ($3 * 512 + $5 * 1048576) / 1048576; if (e > m) m = e } END { if (m > 0) printf "%d", m }' "$lay")"
	fi
	if [ -z "$v" ] || [ "$v" -lt 512 ]; then
		v="$(gzip -l "$IMG" 2>/dev/null | awk 'NR==2{print int($2/1048576)}')"
		if [ -z "$v" ] || [ "$v" -lt 512 ]; then
			warn "无法从 $lay 或 gzip 头推算镜像大小，按 6000MB 申请空间"
			v=6000
		fi
	fi
	printf '%s' "$v"
}
RAW_MB="$(raw_mb)"
NEED_MB=$(( RAW_MB + 512 ))

pick_work() {
	local d avail
	for d in "${CNC_QEMU_WORK:-}" /mnt /var/tmp "${TMPDIR:-}" "$IMG_DIR" "${PWD:-/var/tmp}"; do
		[ -n "$d" ] || continue
		[ -d "$d" ] && [ -w "$d" ] || continue
		avail="$(df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}')"
		[ -n "$avail" ] || continue
		if [ "$avail" -ge "$NEED_MB" ]; then printf '%s' "$d"; return 0; fi
		warn "跳过 $d：可用 ${avail}MB < 需要 ${NEED_MB}MB"
	done
	return 1
}
WORK_BASE="$(pick_work)" || die "找不到可用空间 ≥ ${NEED_MB}MB 的工作目录（可用 CNC_QEMU_WORK 指定，例如 CNC_QEMU_WORK=/mnt）"
WORK="$(mktemp -d "$WORK_BASE/cnc-qemu.XXXXXX")" || die "无法在 $WORK_BASE 建工作目录"
LOG="$WORK/serial.log"
RAW="$WORK/disk.img"
RES="$WORK/results.txt"
SOCK="$WORK/serial.sock"
OUT_DIR="${CNC_QEMU_OUT:-$IMG_DIR}"
mkdir -p "$OUT_DIR"

QPID=""
cleanup() {
	[ -n "$QPID" ] && kill "$QPID" 2>/dev/null
	sleep 1
	[ -n "$QPID" ] && kill -9 "$QPID" 2>/dev/null
	if [ "${CNC_QEMU_KEEP:-0}" = "1" ]; then
		echo "  (保留工作目录：$WORK)"
	else
		rm -rf "$WORK"
	fi
	return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ 解压镜像
log "解压镜像到 $RAW（约 ${RAW_MB}MB，请稍候）"
gzip -dc "$IMG" > "$RAW" || die "解压失败"
ok "已解压：$(du -h "$RAW" | cut -f1)"

# ------------------------------------------------------------------ 加速与 PCI 设备
ACCEL=(-accel tcg,thread=multi)
ACCEL_DESC="TCG 软件模拟（慢）"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	ACCEL=(-enable-kvm -cpu host)
	ACCEL_DESC="KVM（快）"
	ok "/dev/kvm 可用 ⇒ 使用 KVM 加速"
else
	warn "没有可用的 /dev/kvm ⇒ 退回 TCG 软件模拟，启动会慢很多"
fi
DISK_IF="${CNC_QEMU_DISK_IF:-virtio}"

OVMF_ARGS=()
if [ -n "$OVMF_VARS" ]; then
	cp -f "$OVMF_VARS" "$WORK/OVMF_VARS.fd"
	OVMF_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
	           -drive "if=pflash,format=raw,file=$WORK/OVMF_VARS.fd")
else
	cp -f "$OVMF_CODE" "$WORK/OVMF.fd"
	OVMF_ARGS=(-drive "if=pflash,format=raw,file=$WORK/OVMF.fd")
fi

# 4 张 e1000e：镜像里带 kmod-e1000e，QEMU 里就是 eth0..eth3，和真机 4 个口一一对应
NIC_ARGS=()
for i in 0 1 2 3; do
	NIC_ARGS+=(-netdev "user,id=n$i" -device "e1000e,netdev=n$i")
done

EXEC_MODE="${CNC_QEMU_EXEC:-1}"
if [ "$EXEC_MODE" = "1" ] && ! command -v python3 >/dev/null 2>&1; then
	warn "没有 python3 ⇒ 降级为只看启动日志（CNC_QEMU_EXEC=0）"
	EXEC_MODE=0
fi
if [ "$EXEC_MODE" = "1" ]; then
	SERIAL_ARGS=(-serial "unix:$SOCK,server=on,wait=off")
else
	SERIAL_ARGS=(-serial "file:$LOG")
fi

# ------------------------------------------------------------------ 启动 QEMU
log "启动 QEMU（${ACCEL_DESC}，磁盘总线 $DISK_IF，4×e1000e，内存 ${CNC_QEMU_MEM:-2048}MB）"
"$QEMU_BIN" -name cnc-smoke \
	-m "${CNC_QEMU_MEM:-2048}" -smp 2 "${ACCEL[@]}" \
	"${OVMF_ARGS[@]}" \
	-drive "file=$RAW,format=raw,if=$DISK_IF,cache=unsafe" \
	"${NIC_ARGS[@]}" \
	-boot order=c -display none -monitor none -no-reboot \
	"${SERIAL_ARGS[@]}" \
	>>"$WORK/qemu-stdout.log" 2>&1 &
QPID=$!
sleep 2
kill -0 "$QPID" 2>/dev/null || { sed -n '1,40p' "$WORK/qemu-stdout.log"; die "QEMU 启动失败（见上面输出）"; }

# ------------------------------------------------------------------ 只看日志模式
if [ "$EXEC_MODE" != "1" ]; then
	BOOT_TIMEOUT="${CNC_QEMU_BOOT_TIMEOUT:-480}"
	log "等待启动完成（最长 ${BOOT_TIMEOUT}s，串口日志：$LOG）"
	found=""
	deadline=$(( SECONDS + BOOT_TIMEOUT ))
	while [ $SECONDS -lt $deadline ]; do
		grep -qE 'init complete|Please press Enter to activate this console|root@[^ ]*#' "$LOG" 2>/dev/null && { found=ok; break; }
		grep -qi 'Kernel panic' "$LOG" 2>/dev/null && { found=panic; break; }
		kill -0 "$QPID" 2>/dev/null || { found=exit; break; }
		sleep 3
	done
	echo
	log "结果"
	rc=0
	if [ "$found" = "ok" ]; then
		ok "系统启动完成（串口出现控制台提示）"
		grep -q OpenWrt "$LOG" && ok "日志中出现 OpenWrt 标识" || { bad "未见 OpenWrt 标识"; rc=1; }
	else
		bad "未在 ${BOOT_TIMEOUT}s 内启动完成（原因：${found:-超时}）"
		tail -n 40 "$LOG" | sed 's/^/    /'
		rc=1
	fi
	cp -f "$LOG" "$OUT_DIR/qemu-smoke-serial.log" 2>/dev/null && echo "  串口日志已保存：$OUT_DIR/qemu-smoke-serial.log"
	exit "$rc"
fi

# ------------------------------------------------------------------ 进系统跑断言
cat > "$WORK/checks.txt" <<'CHECKS'
# 格式： 类型|名称|命令
#   c = 普通命令（按参数依次执行，不做 shell 展开）
#   x = 交给 sh -c 执行（需要 $()、| 、! 等）
# --- 基础系统 ---
c|openwrt_release|test -s /etc/openwrt_release
x|version_25_12_5|grep -q "DISTRIB_RELEASE=.25\.12\.5" /etc/openwrt_release
x|kernel_6_12_94|test "$(uname -r)" = 6.12.94
x|hostname|test "$(cat /proc/sys/kernel/hostname)" = cnc1338np12
x|timezone_cst8|test "$(uci -q get system.@system[0].timezone)" = CST-8
x|ttylogin_off|test "$(uci -q get system.@system[0].ttylogin)" = 0
# --- 网络预置：eth0=WAN(PPPoE,IPv6 auto) / eth1=IPTV / eth2+eth3=br-lan ---
x|wan_proto_pppoe|test "$(uci -q get network.wan.proto)" = pppoe
x|wan_device_eth0|test "$(uci -q get network.wan.device)" = eth0
x|wan_ipv6_auto|test "$(uci -q get network.wan.ipv6)" = auto
x|iptv_device_eth1|test "$(uci -q get network.iptv.device)" = eth1
x|iptv_ipv6_off|test "$(uci -q get network.iptv.ipv6)" = 0
x|iptv_no_defaultroute|test "$(uci -q get network.iptv.defaultroute)" = 0
x|lan_ip_192_168_2_1|test "$(uci -q get network.lan.ipaddr)" = 192.168.2.1
x|lan_ip6assign_60|test "$(uci -q get network.lan.ip6assign)" = 60
x|brlan_ports_cfg_eth2|uci -q get network.@device[0].ports | grep -qw eth2
x|brlan_ports_cfg_eth3|uci -q get network.@device[0].ports | grep -qw eth3
x|packet_steering_on|test "$(uci -q get network.globals.packet_steering)" = 1
# --- IPv6 服务端 ---
x|dhcpv6_server|test "$(uci -q get dhcp.lan.dhcpv6)" = server
x|ra_server|test "$(uci -q get dhcp.lan.ra)" = server
x|ra_slaac_on|test "$(uci -q get dhcp.lan.ra_slaac)" = 1
x|firewall_wan6_zone|uci show firewall | grep -q wan_6
# uci show 的 list 只把第一个值挂在 `network=` 后面（network='wan' 'wan6'），
# 所以判断"有没有"和"有没有重复"都要按词来数，不能直接 grep network='wan6'。
x|firewall_wan6_once|test "$(uci -q show firewall | sed -n "s/.*network=//p" | tr " " "\n" | tr -d "'" | grep -cw wan6)" = 1
x|firewall_wan_6_once|test "$(uci -q show firewall | sed -n "s/.*network=//p" | tr " " "\n" | tr -d "'" | grep -cw wan_6)" = 1
x|dns_aliyun|uci show dhcp | grep -q 223.5.5.5
x|dns_dnspod|uci show dhcp | grep -q 119.29.29.29
x|dns_aliyun_once|test "$(uci -q show dhcp | sed -n "s/.*server=//p" | tr " " "\n" | tr -d "'" | grep -cw 223.5.5.5)" = 1
# --- LuCI：Argon 主题 + 中文 ---
x|argon_default_theme|test "$(uci -q get luci.main.mediaurlbase)" = /luci-static/argon
x|argon_lang_zh_cn|test "$(uci -q get luci.main.lang)" = zh_cn
c|argon_dir|test -d /www/luci-static/argon
x|argon_css_files|find /www/luci-static/argon -name "*.css" 2>/dev/null | grep -q .
# --- 插件本体与服务脚本 ---
x|openclash_init|test -x /etc/init.d/openclash
c|openclash_dir|test -d /usr/share/openclash
x|openclash_luci_files|find /www/luci-static/resources -name "*openclash*" 2>/dev/null | grep -q .
# OpenClash 的 UDP 透明代理要 nft_tproxy，但它不在 apk 依赖里（init 脚本自己 modprobe）。
# 缺了不会报错退出，只会"静默降级成 UDP 不走代理"，所以必须在这里盯住。
# openclash_tproxy_loads 真的去 modprobe 一次：能挡住 kmod 与内核版本不匹配这种坑。
x|openclash_tproxy_ko|find /lib/modules -name "nft_tproxy.ko*" | grep -q .
x|openclash_tproxy_loads|modprobe nft_tproxy 2>/dev/null; lsmod | grep -q "^nft_tproxy"
x|openclash_inet_diag_ko|find /lib/modules -name "inet_diag.ko*" | grep -q .
x|lucky_init|test -x /etc/init.d/lucky
c|lucky_bin|test -x /usr/bin/lucky
x|msd_lite_init|test -x /etc/init.d/msd_lite
c|msd_lite_bin|test -x /usr/bin/msd_lite
x|vlmcsd_init|test -x /etc/init.d/vlmcsd
c|vlmcsd_bin|test -x /usr/bin/vlmcsd
c|vlmcsd_ini|test -f /etc/vlmcsd.ini
x|bandix_init|test -x /etc/init.d/bandix
c|bandix_bin|test -x /usr/bin/bandix
c|bandix_datadir|test -d /usr/share/bandix
c|bandix_keepd|test -f /lib/upgrade/keep.d/bandix
# --- UPnP/NAT-PMP（2026-10 补装；镜像里默认不开，这里只验"装好且能起来"）---
x|miniupnpd_init|test -x /etc/init.d/miniupnpd
x|miniupnpd_bin|find /usr/sbin /usr/bin -name "miniupnpd" 2>/dev/null | grep -q .
x|miniupnpd_pkg|apk list --installed 2>/dev/null | grep -q "^miniupnpd-nftables"
x|miniupnpd_nft_variant|! apk list --installed 2>/dev/null | grep -q "^miniupnpd-iptables"
x|upnp_luci_files|find /www/luci-static/resources -name "*upnp*" 2>/dev/null | grep -q .
# --- IPTV：eth1 专用口 + msd_lite 组播转单播（见手册 §7.7）---
# 接口本身（device/ipv6/defaultroute）在上面 iptv_* 三条里已经断言过；
# 这里盯的是"首启脚本 99-zz-cnc-defaults 到底有没有把防火墙与 msd_lite 做出来"：
# 离线校验只能看到镜像里的文件，看不到"进系统跑完 uci-defaults 之后的配置"。
x|iptv_fw_zone|uci -q show firewall | grep -q "\.name='iptv'"
x|iptv_fw_zone_network|uci -q show firewall | grep -A5 "\.name='iptv'" | grep -q "network='iptv'"
# 组播是进到本机（input 方向）的：zone 必须保持 REJECT，另外靠两条精确规则放行。
x|iptv_fw_zone_input_reject|uci -q show firewall | grep -A5 "\.name='iptv'" | grep -q "input='REJECT'"
x|iptv_fw_rule_igmp|uci -q show firewall | grep -q "\.name='Allow-IGMP-IPTV'"
x|iptv_fw_rule_multicast|uci -q show firewall | grep -q "\.name='Allow-IPTV-Multicast'"
x|msd_lite_enabled|uci -q get msd_lite.@instance[0].enabled | grep -qx 1
x|msd_lite_bind_4022|uci -q get msd_lite.@instance[0].address | grep -q 4022
x|msd_lite_rcv_iface|uci -q get msd_lite.@instance[0].network | grep -qx iptv
# QEMU 里 eth1 没有对端、拿不到地址，但 netifd 仍会给出 device，所以服务应当起得来。
# ★这里用 pidof 而不用 `pgrep -f "msd_lite -c"`★：冒烟是通过 `sh -c "<命令文本>"` 执行的，
#   -f 会匹配到执行这条断言的 shell 自己，于是服务根本没起来也会"通过"（实测：返回两个 PID）。
x|msd_lite_running|pidof msd_lite >/dev/null
x|msd_lite_listens_4022|netstat -ln 2>/dev/null | grep -q ":4022"
# --- x86 排障工具（2026-10 补装）---
x|tool_lspci|command -v lspci
x|tool_lsusb|command -v lsusb
x|tool_nvme|command -v nvme
x|tool_iperf3|command -v iperf3
x|tool_tcpdump|command -v tcpdump
x|tool_mtr|command -v mtr
# --- 中文语言包：LuCI 每个 app 有独立 .lmo，只装 base 时其它页面仍是英文。
#     逐个 app 断言，尤其自编的 msd_lite/vlmcsd/lucky（它们的语言包不来自官方源，
#     最容易被构建脚本丢掉，见 §7.5 / §9）。---
x|i18n_base_zh_cn|find /usr -name "base.zh-cn.lmo" 2>/dev/null | grep -q .
x|i18n_firewall_zh_cn|find /usr -name "firewall.zh-cn.lmo" 2>/dev/null | grep -q .
x|i18n_upnp_zh_cn|find /usr -name "upnp.zh-cn.lmo" 2>/dev/null | grep -q .
x|i18n_msd_lite_zh_cn|find /usr -name "msd_lite.zh-cn.lmo" 2>/dev/null | grep -q .
x|i18n_vlmcsd_zh_cn|find /usr -name "vlmcsd.zh-cn.lmo" 2>/dev/null | grep -q .
x|i18n_lucky_zh_cn|find /usr -name "lucky.zh-cn.lmo" 2>/dev/null | grep -q .
# --- WireGuard ---
x|wg_bin|command -v wg
x|kmod_wireguard_ko|find /lib/modules -name "wireguard.ko*" | grep -q .
x|wg_kmod_pkg|apk list --installed 2>/dev/null | grep -q "^kmod-wireguard"
x|wg_tools_pkg|apk list --installed 2>/dev/null | grep -q "^wireguard-tools"
x|wg_luci_pkg|apk list --installed 2>/dev/null | grep -q "^luci-proto-wireguard"
x|wg_luci_files|find /www /usr/share/rpcd /usr/libexec 2>/dev/null -name "*wireguard*" | grep -q .
# --- 内置刷写页（在线升级） ---
c|cnc_upgrade_bin|test -x /usr/sbin/cnc-upgrade
c|cnc_upgrade_menu|test -f /usr/share/luci/menu.d/luci-app-cnc-upgrade.json
c|cnc_upgrade_acl|test -f /usr/share/rpcd/acl.d/luci-app-cnc-upgrade.json
c|cnc_upgrade_view|test -f /www/luci-static/resources/view/cnc_upgrade/upgrade.js
c|cnc_upgrade_keepd|test -f /lib/upgrade/keep.d/99-cnc-plugins
c|cnc_release_file|test -s /etc/cnc-release
x|cnc_upgrade_usage|/usr/sbin/cnc-upgrade --help 2>&1 | grep -q 用法
# --- 内核模块与运行时 ---
x|kmod_igc_ko|find /lib/modules -name "igc.ko*" | grep -q .
x|kmod_tun_ko|find /lib/modules -name "tun.ko*" | grep -q .
x|kmod_zram_ko|find /lib/modules -name "zram.ko*" | grep -q .
x|kmod_e1000e_ko|find /lib/modules -name "e1000e.ko*" | grep -q .
x|dnsmasq_full|apk list --installed 2>/dev/null | grep -q "^dnsmasq-full"
x|dnsmasq_replaced|! apk list --installed 2>/dev/null | grep -qE "^dnsmasq-[0-9]"
x|ipv6_not_disabled|test "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0
x|zram_swap_active|grep -q zram /proc/swaps
x|ubus_alive|ubus -S list | grep -q "^uci$"
x|uhttpd_running|pgrep uhttpd
# 注意：busybox wget 没有 -S（拿不到状态行）。实测取证：
#   http://127.0.0.1/            → 200 + LuCI 的 HTML
#   http://127.0.0.1/cgi-bin/luci/ → HTTP error 403（没有会话时的正常响应）
#   http://…/luci-static/resources/luci.js → 真的返回 JS 内容
x|luci_static_js|test "$(wget -qO- http://127.0.0.1/luci-static/resources/luci.js 2>/dev/null | wc -c)" -gt 1000
x|luci_web_root|wget -qO- http://127.0.0.1/ 2>/dev/null | grep -qi "luci"
x|luci_cgi_answers|wget -O- http://127.0.0.1/cgi-bin/luci/ 2>&1 | grep -qE "HTTP error (200|302|401|403)"
# --- 真实网络栈（QEMU 里 4 个口都在 ⇒ br-lan 应该真的起来） ---
x|eth0_exists|ip -o link show eth0
x|eth1_exists|ip -o link show eth1
x|eth3_exists|ip -o link show eth3
x|brlan_exists|ip -o link show br-lan
x|brlan_ipv4|ip -4 -o addr show br-lan | grep -q 192.168.2.1
x|brlan_port_eth2_up|ip -o link show eth2 | grep -q "master br-lan"
x|brlan_ipv6_ll|ip -6 -o addr show br-lan | grep -q "scope link"
x|eth0_not_in_bridge|! ip -o link show eth0 | grep -q "master br-lan"
x|eth1_not_in_bridge|! ip -o link show eth1 | grep -q "master br-lan"
CHECKS

cat > "$WORK/driver.py" <<'PYEOF'
#!/usr/bin/env python3
"""QEMU 串口控制台驱动：等系统起来 -> 跑 checks.txt 里的断言 -> 收集系统信息 -> 关机。

用法: driver.py <sock> <serial.log> <checks.txt> <results.txt> <qemu-pid>
环境: CNC_QEMU_BOOT_TIMEOUT(480) CNC_QEMU_CHECK_TIMEOUT(20)
约定: 断言输出形如 "@@CK@@ <名字> OK|FAIL"（tty 会回显整行命令，所以只认"整行就是标记"的行）
"""
import os
import re
import socket
import sys
import threading
import time

sock_path, log_path, checks_path, res_path, qemu_pid = sys.argv[1:6]
try:  # 让 ✔/✘ 在 GBK 控制台或 LANG=C 下也不会炸
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
BOOT_TIMEOUT = float(os.environ.get("CNC_QEMU_BOOT_TIMEOUT", "480"))
CHK_TIMEOUT = float(os.environ.get("CNC_QEMU_CHECK_TIMEOUT", "20"))
qemu_pid = int(qemu_pid)

logf = open(log_path, "ab", buffering=0)
buf = bytearray()
buf_lock = threading.Lock()
closed = threading.Event()
connected = threading.Event()


def connect():
    # sock_path 形如 "/tmp/xxx/serial.sock"（AF_UNIX）或 "tcp:127.0.0.1:12345"
    # 后者只用于本机单元测试/兜底（QEMU 也能用 -serial tcp:...）
    use_tcp = sock_path.startswith("tcp:")
    host = port = None
    if use_tcp:
        host, port = sock_path[4:].rsplit(":", 1)
        port = int(port)
    deadline = time.time() + 30
    while True:
        try:
            s = socket.socket(socket.AF_INET if use_tcp else socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect((host, port) if use_tcp else sock_path)
            s.settimeout(0.5)
            return s
        except OSError:
            try:
                os.kill(qemu_pid, 0)
            except ProcessLookupError:
                sys.stderr.write("QEMU 进程已经退出，串口连不上\n")
                sys.exit(1)
            if time.time() > deadline:
                sys.stderr.write("连不上 QEMU 串口 socket：%s\n" % sock_path)
                sys.exit(1)
            time.sleep(0.5)


sock = connect()


def pump():
    while True:
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not data:
            break
        logf.write(data)
        with buf_lock:
            buf.extend(data)
    closed.set()


threading.Thread(target=pump, daemon=True).start()


def text():
    with buf_lock:
        raw = bytes(buf)
    return raw.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")


def send(cmd):
    sock.sendall((cmd + "\n").encode())


def wait_re(pattern, timeout, since=0):
    rx = re.compile(pattern, re.M)
    end = time.time() + timeout
    while True:
        m = rx.search(text()[since:])
        if m:
            return m
        if time.time() >= end:
            return None
        time.sleep(0.3)


def qemu_alive():
    if qemu_pid <= 1:
        return True
    try:
        os.kill(qemu_pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True  # EPERM/平台差异：进程还在，只是查不了
    except Exception:
        return True


def wait_boot():
    """等到串口出现控制台/启动完成标志；期间不停敲回车唤醒 askfirst 控制台。"""
    boot_re = (r"(init complete"
               r"|Please press Enter to activate this console"
               r"|root@[^\n]*#\s*$)")
    end = time.time() + BOOT_TIMEOUT
    while time.time() < end:
        m = wait_re(boot_re, 3)
        if m:
            return m.group(1).strip()
        if not qemu_alive():
            return None
        send("")
    return None


def wait_shell():
    """确认串口那头真的有个能执行命令的 shell。"""
    end = time.time() + 90
    while time.time() < end:
        mark = len(text())
        send("echo @@CKREADY@@")
        if wait_re(r"^@@CKREADY@@\s*$", 6, since=mark):
            return True
        if not qemu_alive():
            return False
    return False


def block(cmds, timeout=30):
    """把一段命令的输出夹在 @@B@@ / @@E@@ 之间取回来。"""
    mark = len(text())
    send("echo @@B@@")
    if not wait_re(r"^@@B@@\s*$", 15, since=mark):
        return "(取系统信息失败：控制台没有回应)"
    for c in cmds:
        send(c)
    end_mark = len(text())
    send("echo @@E@@")
    if not wait_re(r"^@@E@@\s*$", timeout, since=end_mark):
        return "(取系统信息超时)"
    body = text()[mark:]
    body = re.sub(r"^@@B@@\s*$", "", body, count=1, flags=re.M)
    body = re.sub(r"^@@E@@\s*$.*$", "", body, count=1, flags=re.M | re.S)
    # tty 会把我们发过去的命令行回显出来，去掉这些回显与多余空行，存档才好看
    sent = set(["echo @@B@@", "echo @@E@@"] + list(cmds))
    lines = [ln for ln in body.split("\n") if ln.strip() != "" and ln.strip() not in sent]
    return "\n".join(lines).strip()


t = text  # 短别名，block() 里用

print("  等待系统启动完成（最长 %ds）…" % int(BOOT_TIMEOUT))
boot = wait_boot()
if boot is None:
    if not qemu_alive():
        print("  ✘ QEMU 提前退出（多半是引导失败）")
    else:
        print("  ✘ %ds 内没有出现控制台提示" % int(BOOT_TIMEOUT))
    sys.exit(1)
print("  ✔ 控制台已就绪（识别到：%s）" % boot)

if not wait_shell():
    print("  ✘ 串口上的 shell 不响应命令")
    sys.exit(1)
print("  ✔ 串口 shell 可执行命令")

harness = [
    r"""ck(){ n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "@@CK@@ $n OK"; else echo "@@CK@@ $n FAIL"; fi; }""",
    r"""ckx(){ n="$1"; if sh -c "$2" >/dev/null 2>&1; then echo "@@CK@@ $n OK"; else echo "@@CK@@ $n FAIL"; fi; }""",
]
for h in harness:
    send(h)
time.sleep(1.0)

def shq(s):
    """POSIX 单引号转义：断言命令里可以放心写引号、$()、| 等。"""
    return "'" + s.replace("'", "'\\''") + "'"


results = []
timeouts = 0
for line in open(checks_path):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    kind, name, cmd = line.split("|", 2)
    call = ("ckx %s %s" % (shq(name), shq(cmd))) if kind == "x" else ("ck %s %s" % (shq(name), cmd))
    mark = len(text())
    send(call)
    m = wait_re(r"^@@CK@@ %s (OK|FAIL)\s*$" % re.escape(name), CHK_TIMEOUT, since=mark)
    if m:
        res = m.group(1)
    else:
        res = "TIMEOUT"
        timeouts += 1
        if timeouts >= 3:
            results.append((name, res))
            print("  ✘ 连续 3 项无响应，放弃后续断言")
            break
    results.append((name, res))
    mark_char = {"OK": "✔", "FAIL": "✘"}.get(res, "?")
    print("  %s %s (%s)" % (mark_char, name, res))

info_cmds = [
    "uname -a",
    "cat /etc/openwrt_release 2>/dev/null",
    "cat /etc/cnc-release 2>/dev/null",
    "uci show network",
    "uci show firewall | head -n 40",
    "cat /etc/config/uhttpd",
    "ls /etc/uci-defaults/",
    "ip -o link show",
    "ip -4 -o addr show",
    "ip -6 -o addr show | head -n 12",
    "free",
    "apk list --installed 2>/dev/null | wc -l",
    "ubus call system board 2>/dev/null",
    "ls /www/luci-static/ | head -n 12",
    "ls /www/luci-static/resources/ 2>/dev/null | head -n 8",
    "wget -O- http://127.0.0.1/ 2>&1 | head -c 200; echo",
    "wget -O- http://127.0.0.1/cgi-bin/luci/ 2>&1 | head -c 200; echo",
    "wget -O- http://127.0.0.1/luci-static/resources/luci.js 2>/dev/null | wc -c",
    "logread 2>/dev/null | grep -iE 'cnc|firewall|uci-default' | tail -n 15",
    "logread 2>/dev/null | tail -n 15",
]
print("  收集系统信息…")
info = block(info_cmds)

send("poweroff")
end = time.time() + 45
while time.time() < end and qemu_alive() and not closed.is_set():
    time.sleep(0.5)

passed = sum(1 for _, r in results if r == "OK")
failed = sum(1 for _, r in results if r == "FAIL")
timed = sum(1 for _, r in results if r == "TIMEOUT")

with open(res_path, "w") as f:
    f.write("boot_marker=%s\n" % boot)
    f.write("checks_pass=%d\nchecks_fail=%d\nchecks_timeout=%d\n" % (passed, failed, timed))
    f.write("\n# checks\n")
    for n, r in results:
        f.write("%s\t%s\n" % (n, r))
    f.write("\n# system info\n")
    f.write(info + "\n")

print("  通过 %d 项，失败 %d 项，超时 %d 项" % (passed, failed, timed))
for n, r in results:
    if r != "OK":
        print("    失败项：%s (%s)" % (n, r))
sys.exit(0 if failed == 0 and timed == 0 else 1)
PYEOF

log "进系统跑断言（串口日志：$LOG）"
CNC_QEMU_BOOT_TIMEOUT="${CNC_QEMU_BOOT_TIMEOUT:-480}" \
	python3 "$WORK/driver.py" "$SOCK" "$LOG" "$WORK/checks.txt" "$RES" "$QPID"
rc=$?

echo
log "结果"
if [ -s "$RES" ]; then
	sed -n '1,3p' "$RES" | sed 's/^/  /'
	pass_n=$(sed -n 's/^checks_pass=//p' "$RES"); pass_n=${pass_n:-0}
	fail_n=$(sed -n 's/^checks_fail=//p' "$RES"); fail_n=${fail_n:-0}
	to_n=$(sed -n 's/^checks_timeout=//p' "$RES"); to_n=${to_n:-0}
	printf '  断言共 %s 项：通过 %s，失败 %s，超时 %s\n' "$(( pass_n + fail_n + to_n ))" "$pass_n" "$fail_n" "$to_n"
else
	bad "没有拿到断言结果（驱动提前退出，rc=$rc）"
fi

cp -f "$LOG" "$OUT_DIR/qemu-smoke-serial.log" 2>/dev/null
cp -f "$RES" "$OUT_DIR/qemu-smoke-results.txt" 2>/dev/null
# 系统信息单独存一份，便于直接翻看
awk '/^# system info$/{f=1;next} f' "$RES" > "$OUT_DIR/qemu-smoke-system-info.txt" 2>/dev/null

if [ "$rc" -eq 0 ]; then
	ok "QEMU 冒烟通过"
	echo "  串口日志：$OUT_DIR/qemu-smoke-serial.log"
	echo "  断言结果：$OUT_DIR/qemu-smoke-results.txt"
	echo "  系统信息：$OUT_DIR/qemu-smoke-system-info.txt"
else
	bad "QEMU 冒烟未通过"
	echo "  串口日志末尾 40 行："
	tail -n 40 "$LOG" 2>/dev/null | sed 's/^/    /'
	echo "  串口日志：$OUT_DIR/qemu-smoke-serial.log"
	echo "  断言结果：$OUT_DIR/qemu-smoke-results.txt"
fi
exit "$rc"
