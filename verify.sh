#!/usr/bin/env bash
# =============================================================================
# CncTion 1338NP-12 —— 镜像离线校验（刷机前就能查出绝大多数问题）
#
# 用法：
#   sudo bash verify.sh out/xxx.img.gz              # 单镜像校验
#   sudo bash verify.sh out/r1.img.gz out/r2.img.gz # 额外比对两次构建的分区表
#
# 校验内容：
#   1. gzip 完整性 + GPT 布局（分区个数/顺序/大小/类型/卷标）
#   2. 分区表与 layout-reference.txt 逐行比对（保证"改版本号重编后仍能 sysupgrade 就地升级"）
#   3. 挂载 ESP：grub.cfg 串口控制台 + failsafe + search -l kernel，以及 FAT 卷标 kernel
#   4. 挂载 rootfs：四大插件 + Bandix + WireGuard + Argon + UPnP + x86 排障工具 + 网络/IPv6 预置 + 升级保留清单
#
# 需要 root（loop 挂载）。只读挂载，不会修改镜像。
#
# 注意：解压后的镜像约 4.2 GB，所以临时目录必须放在"磁盘"上，不能放 /tmp
# （很多系统 /tmp 是 tmpfs，会直接 No space left on device）。这里默认用
# 镜像自己所在的目录；也可以用 CNC_VERIFY_WORK=<dir> 指定别处。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env disable=SC1091
. "$HERE/versions.env"
IMG="${1:-}"
IMG2="${2:-}"
[ -n "$IMG" ] || { echo "用法: sudo bash verify.sh <image.img.gz> [<image2.img.gz>]"; exit 2; }
[ -f "$IMG" ] || { echo "找不到镜像：$IMG"; exit 2; }

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_r=; c_g=; c_y=; c_b=; c_0=; }
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$c_g" "$c_0" "$*"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$*"); printf '  %s✘ %s%s\n' "$c_r" "$*" "$c_0"; }
sec() { printf '\n%s── %s%s\n' "$c_b" "$*" "$c_0"; }

WORKBASE="${CNC_VERIFY_WORK:-$(dirname "$(readlink -f "$IMG")")}"
[ -w "$WORKBASE" ] || WORKBASE="$(dirname "$(readlink -f "$IMG")")"
WORKTMP="$(mktemp -d "$WORKBASE/.verify.XXXXXX")" \
	|| { echo "无法在 $WORKBASE 创建临时目录"; exit 1; }
MNT1="$WORKTMP/esp"; MNT2="$WORKTMP/root"
LOOP1=""; LOOP2=""
cleanup() {
	umount "$MNT1" 2>/dev/null || true; umount "$MNT2" 2>/dev/null || true
	[ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
	[ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
	[ "${KEEP_RAW:-0}" = "1" ] || rm -f "$WORKTMP/raw.img"
	rmdir "$MNT1" "$MNT2" 2>/dev/null || true
	rm -rf "$WORKTMP"
}
trap cleanup EXIT

# ----------------------------------------------------------------- 1. GPT
sec "gzip 与 GPT 分区布局"
python3 - "$IMG" > "$WORKTMP/layout.txt" <<'PY' || { echo "GPT 解析失败"; exit 1; }
import gzip, struct, sys

path = sys.argv[1]
with open(path, 'rb') as fh:
    head = fh.read(4)
if head[:2] != b'\x1f\x8b':
    print("ERROR: 不是 gzip 文件（%.2x%.2x）" % (head[0], head[1]), file=sys.stderr)
    sys.exit(1)

f = gzip.open(path, 'rb')
hdr = f.read(1024)[512:1024]
if hdr[:8] != b'EFI PART':
    print("ERROR: GPT 签名缺失", file=sys.stderr); sys.exit(1)
part_entry_lba, num_parts, entry_size = struct.unpack_from('<QII', hdr, 72)
f.seek(part_entry_lba * 512)
table = f.read(num_parts * entry_size)

TYPES = {
    'c12a7328-f81f-11d2-ba4b-00a0c93ec93b': 'ESP(FAT)',
    '0fc63daf-8483-4772-8e79-3d69d8477de4': 'LinuxFS',
    '21686148-6449-6e6f-744e-656564454649': 'BIOSboot',
}

def guid(b):
    return '%08x-%04x-%04x-%s-%s' % (
        struct.unpack_from('<I', b, 0)[0], struct.unpack_from('<H', b, 4)[0],
        struct.unpack_from('<H', b, 6)[0], b[8:10].hex(), b[10:16].hex())

rows = []
for i in range(num_parts):
    e = table[i*entry_size:(i+1)*entry_size]
    if e[:16] == b'\x00'*16:
        continue
    tguid = guid(e[:16]); pguid = guid(e[16:32])
    first, last = struct.unpack_from('<QQ', e, 32)
    name = e[56:128].decode('utf-16-le', 'ignore').rstrip('\x00')
    size_mib = (last - first + 1) * 512 // (1024*1024)
    rows.append((i+1, first, last, size_mib, TYPES.get(tguid, tguid), name))

for idx, first, last, size, t, name in rows:
    print("entry%d start_lba=%-8d size_mib=%-6d type=%-10s label=%s" % (idx, first, size, t, name))

# 给断言用的机器可读行
print("#count=%d" % len(rows))
PY
cat "$WORKTMP/layout.txt" | sed 's/^/    /'

# 官方 x86 combined-efi 镜像的真实布局（本工程实测）：
#   entry1   = 引导分区（FAT，GPT 类型显示为 LinuxFS、partlabel 为空）
#   entry2   = rootfs（ext4，partlabel 为空）
#   entry128 = BIOS boot（≤1 MiB，位于 LBA 34）
# 真正的不变量是这四条：
#   ① 前两项必须是"引导分区 + rootfs"——升级时 platform.sh 按第 2 项的 UniquePartitionGUID
#      改写 grub.cfg 的 root=PARTUUID；
#   ② 两项尺寸必须等于 versions.env 的常量（否则以后升级会整盘覆写）；
#   ③ 必须存在 BIOS boot 项（保住 Legacy 引导能力）；
#   ④ 分区总数必须是 3。
awk -v k="$KERNEL_PARTSIZE" -v r="$ROOTFS_PARTSIZE" '
	$1=="entry1" && $3=="size_mib="k { ek=1 }
	$1=="entry2" && $3=="size_mib="r { er=1 }
	$4=="type=BIOSboot" { bb=1 }
	/^#count=3$/ { c=1 }
	END { printf "%d %d %d %d\n", ek+0, er+0, bb+0, c+0 }
' "$WORKTMP/layout.txt" | {
	read -r ek er bb c
	[ "$ek" = 1 ] && ok "entry1 = ${KERNEL_PARTSIZE} MiB 引导分区（ESP）" \
		|| bad "entry1 不是 ${KERNEL_PARTSIZE} MiB 的引导分区（分区顺序或尺寸不对）"
	[ "$er" = 1 ] && ok "entry2 = ${ROOTFS_PARTSIZE} MiB rootfs（升级时靠第 2 项改写 root=PARTUUID）" \
		|| bad "entry2 不是 ${ROOTFS_PARTSIZE} MiB 的 rootfs"
	[ "$bb" = 1 ] && ok "存在 BIOS boot 分区（保留 Legacy 引导能力）" || bad "缺少 BIOS boot 分区"
	[ "$c" = 1 ] && ok "分区数量 = 3（与官方 combined-efi 布局一致）" || bad "分区数量不是 3"
}

# 与参考布局比对（保证"改版本号重编"后仍能就地升级）
cp -f "$WORKTMP/layout.txt" "${IMG%.img.gz}.layout.txt"
if [ -f "$HERE/layout-reference.txt" ]; then
	if diff -q <(grep '^entry' "$HERE/layout-reference.txt") <(grep '^entry' "$WORKTMP/layout.txt") >/dev/null; then
		ok "分区表与 layout-reference.txt 逐行一致（升级可就地写入，不整盘覆写）"
	else
		bad "分区表与 layout-reference.txt 不一致 —— 改过 KERNEL_PARTSIZE/ROOTFS_PARTSIZE？这会让后续 sysupgrade 整盘覆写"
		diff <(grep '^entry' "$HERE/layout-reference.txt") <(grep '^entry' "$WORKTMP/layout.txt") | sed 's/^/      /'
	fi
else
	echo "  (首次运行：已生成 $HERE/layout-reference.txt，请 review 后纳入版本控制)"
	cp -f "$WORKTMP/layout.txt" "$HERE/layout-reference.txt"
fi

if [ -n "$IMG2" ] && [ -f "$IMG2" ]; then
	sec "两次构建的分区表比对：$(basename "$IMG") vs $(basename "$IMG2")"
	python3 - "$IMG2" > "$WORKTMP/layout2.txt" <<'PY'
import gzip, struct, sys
f = gzip.open(sys.argv[1], 'rb'); f.read(1024)
hdr = f.read(512)
part_entry_lba, num_parts, entry_size = struct.unpack_from('<QII', hdr, 72)
f.seek(part_entry_lba*512); table = f.read(num_parts*entry_size)
for i in range(num_parts):
    e = table[i*entry_size:(i+1)*entry_size]
    if e[:16] == b'\x00'*16: continue
    first, last = struct.unpack_from('<QQ', e, 32)
    print("entry%d start_lba=%d size_mib=%d" % (i+1, first, (last-first+1)*512//(1024*1024)))
PY
	if diff -q <(grep '^entry' "$WORKTMP/layout.txt") <(grep '^entry' "$WORKTMP/layout2.txt") >/dev/null; then
		ok "两次构建的分区表完全一致"
	else
		bad "两次构建的分区表不一致"; diff <(grep '^entry' "$WORKTMP/layout.txt") <(grep '^entry' "$WORKTMP/layout2.txt") | sed 's/^/      /'
	fi
fi

# ----------------------------------------------------------------- 2. 解压并挂载
sec "解压镜像并挂载各分区（只读）"
RAW="$WORKTMP/raw.img"
if ! gzip -dc "$IMG" > "$RAW"; then bad "gzip 解压失败"; else ok "gzip 解压完整（$(du -h "$RAW" | cut -f1)）"; fi

# 从 GPT 取各分区的字节偏移
read -r OFF1 SZ1 OFF2 SZ2 < <(python3 - "$IMG" <<'PY'
import gzip, struct, sys
f = gzip.open(sys.argv[1], 'rb')
# GPT 头在 LBA1（字节 512..1024）：先读满 1024 字节再取这一段
hdr = f.read(1024)[512:1024]
if hdr[:8] != b'EFI PART':
    sys.exit(1)
pel, np, es = struct.unpack_from('<QII', hdr, 72)
f.seek(pel * 512)
t = f.read(np * es)
out = []
for i in range(np):
    e = t[i*es:(i+1)*es]
    if e[:16] == b'\x00'*16:
        continue
    first, last = struct.unpack_from('<QQ', e, 32)
    out.append((first*512, (last-first+1)*512))
if len(out) < 2:
    sys.exit(1)
print(out[0][0], out[0][1], out[1][0], out[1][1])
PY
)
[ "${SZ1:-0}" -gt 0 ] && [ "${SZ2:-0}" -gt 0 ] || { bad "无法取得分区偏移"; exit 1; }

LOOP1="$(losetup -f --show -o "$OFF1" --sizelimit "$SZ1" --read-only "$RAW")" || { bad "ESP 挂载点创建失败"; exit 1; }
LOOP2="$(losetup -f --show -o "$OFF2" --sizelimit "$SZ2" --read-only "$RAW")" || { bad "rootfs 挂载点创建失败"; exit 1; }
mkdir -p "$MNT1" "$MNT2"
mount -o ro "$LOOP1" "$MNT1" 2>/dev/null || mount -t vfat -o ro "$LOOP1" "$MNT1" || bad "ESP 挂载失败"
mount -o ro "$LOOP2" "$MNT2" 2>/dev/null || bad "rootfs 挂载失败"
[ -d "$MNT2/etc" ] || { bad "rootfs 内容异常（缺少 /etc）"; exit 1; }

# ----------------------------------------------------------------- 3. ESP
sec "引导分区（ESP）"
LBL="$(blkid -o value -s LABEL "$LOOP1" 2>/dev/null)"
[ "$LBL" = "kernel" ] && ok "FAT 卷标 = kernel（GRUB 的 search -l kernel -s root 靠它定位）" \
	|| bad "FAT 卷标是 '$LBL'，应为 kernel —— GRUB 会找不到引导分区"
EFI="$(find "$MNT1" -iname 'BOOTX64.EFI' | head -1)"
[ -n "$EFI" ] && ok "存在 EFI 引导文件：${EFI#$MNT1}" || bad "缺少 \\EFI\\BOOT\\BOOTX64.EFI（UEFI 起不来）"
GRUB="$(find "$MNT1" -iname 'grub.cfg' | head -1)"
if [ -n "$GRUB" ]; then
	ok "存在 grub.cfg：${GRUB#$MNT1}"
	grep -q 'console=ttyS0,115200n8' "$GRUB" && ok "内核命令行含 console=ttyS0,115200n8（串口可登录）" \
		|| bad "grub.cfg 缺少 console=ttyS0,115200n8（重装只能靠串口救援，必须保留）"
	grep -qi 'failsafe' "$GRUB" && ok "含 failsafe 菜单项（刷坏了能救）" || bad "grub.cfg 缺少 failsafe 菜单项"
	grep -q 'search -l kernel -s root' "$GRUB" && ok "含 search -l kernel -s root" || bad "grub.cfg 缺少 search -l kernel"
	KRN="$(find "$MNT1" -iname 'vmlinuz*' | head -1)"
	[ -n "$KRN" ] && ok "存在内核：$(basename "$KRN")（$(du -h "$KRN" | cut -f1)）" || bad "引导分区里没有 vmlinuz"
	grep -q 'console=tty0' "$GRUB" && ok "含 console=tty0（HDMI 也有内核日志）" || echo "  (提示：未启用 console=tty0，HDMI 无日志)"
else
	bad "引导分区里没有 grub.cfg"
fi

# ----------------------------------------------------------------- 4. rootfs
sec "rootfs：四大插件 + Bandix + WireGuard"
for f in \
	"etc/init.d/openclash|OpenClash 服务" \
	"usr/share/openclash|OpenClash 程序目录" \
	"etc/init.d/lucky|Lucky 服务" \
	"usr/bin/lucky|Lucky 主程序" \
	"etc/init.d/vlmcsd|vlmcsd 服务" \
	"usr/bin/vlmcsd|vlmcsd 主程序" \
	"etc/vlmcsd.ini|vlmcsd 配置" \
	"etc/init.d/msd_lite|msd_lite 服务" \
	"usr/bin/msd_lite|msd_lite 主程序" \
	"etc/init.d/bandix|Bandix 服务" \
	"usr/bin/bandix|Bandix 主程序" \
	"lib/upgrade/keep.d/bandix|Bandix 自带升级保留清单" \
	"usr/sbin/cnc-upgrade|在线升级脚本" \
	"usr/share/luci/menu.d/luci-app-cnc-upgrade.json|在线升级 LuCI 菜单" \
	"www/cgi-bin/luci|LuCI Web 入口" \
	"usr/bin/ruby|Ruby（OpenClash 依赖）" \
	"sbin/sysupgrade|sysupgrade 本体" \
	; do
	p="${f%%|*}"; d="${f##*|}"
	[ -e "$MNT2/$p" ] && ok "$d" || bad "缺少 $d（$p）"
done

# 可执行位：luci.mk 用 `cp -pR` 安装，源码在 Windows/挂载盘上取回时容易丢可执行位，
# 会让「固件在线升级」页面报 exec 失败——这里直接断言。
for f in "usr/sbin/cnc-upgrade|在线升级脚本" \
         "etc/init.d/openclash|OpenClash 服务脚本" \
         "etc/init.d/lucky|Lucky 服务脚本" \
         "etc/init.d/vlmcsd|vlmcsd 服务脚本" \
         "etc/init.d/msd_lite|msd_lite 服务脚本" \
         "etc/init.d/bandix|Bandix 服务脚本" \
         "etc/uci-defaults/99-zz-cnc-defaults|首启收尾脚本" \
         ; do
	p="${f%%|*}"; d="${f##*|}"
	[ -x "$MNT2/$p" ] && ok "$d 可执行" || bad "$d 没有可执行位（$p）"
done

sec "rootfs：UPnP/NAT-PMP 与 x86 排障工具（2026-10 补装）"
[ -x "$MNT2/etc/init.d/miniupnpd" ] && ok "miniupnpd 服务脚本可执行" \
	|| bad "缺少可执行的 /etc/init.d/miniupnpd（UPnP 装了也起不来）"
find "$MNT2/usr/sbin" "$MNT2/usr/bin" -name 'miniupnpd' 2>/dev/null | grep -q . \
	&& ok "miniupnpd 主程序存在" || bad "找不到 miniupnpd 主程序"
[ -f "$MNT2/usr/share/luci/menu.d/luci-app-upnp.json" ] \
	&& ok "UPnP 的 LuCI 菜单已安装（服务 → UPnP/NAT-PMP）" \
	|| bad "缺少 luci-app-upnp 的菜单文件（网页上会看不到 UPnP 页面）"
# 工具按"找不找得到可执行文件"判断，不写死 /usr/bin 还是 /usr/sbin
# （注意 mtr：包名是 mtr-json，但装出来的命令就叫 mtr）
for t in lspci lsusb nvme iperf3 tcpdump mtr; do
	find "$MNT2/usr/sbin" "$MNT2/usr/bin" -name "$t" 2>/dev/null | grep -q . \
		&& ok "排障工具：$t" || bad "缺少排障工具 $t"
done

sec "rootfs：Argon 主题与中文界面"
[ -d "$MNT2/www/luci-static/argon" ] && ok "Argon 主题静态资源已安装" || bad "缺少 /www/luci-static/argon —— 主题 apk 没装上"
grep -q "mediaurlbase '/luci-static/argon'" "$MNT2/etc/config/luci" 2>/dev/null \
	&& ok "/etc/config/luci 默认主题 = argon" || bad "/etc/config/luci 未把 argon 设为默认主题"
grep -q "lang 'zh_cn'" "$MNT2/etc/config/luci" 2>/dev/null \
	&& ok "LuCI 默认语言 = zh_cn" || bad "LuCI 默认语言不是 zh_cn"
# LuCI 的每个 app 各有独立语言包：只装 luci-i18n-base-zh-cn 时防火墙等页面仍是英文
find "$MNT2/usr" -name 'firewall.zh-cn.lmo' 2>/dev/null | grep -q . \
	&& ok "防火墙页面中文语言包已安装（luci-i18n-firewall-zh-cn）" \
	|| bad "缺少 luci-i18n-firewall-zh-cn —— 防火墙页面会是英文"

sec "rootfs：网络预置（eth0=WAN 与 IPv6）"
NET="$MNT2/etc/config/network"
# 按 UCI 段作用域取值，避免"两个 grep 命中不同段"的假阳性
uci_get() { # <file> <section-type> <section-name> <option>
	awk -v t="$2" -v n="$3" -v o="$4" '
		$1=="config" && $2==t && $3=="'\''"n"'\''" { inb=1; next }
		$1=="config" { inb=0 }
		inb && $1=="option" && $2==o { gsub(/'\''/,"",$3); print $3 }
	' "$1"
}
if [ -f "$NET" ]; then
	[ "$(uci_get "$NET" interface wan device)" = "eth0" ] \
		&& ok "wan.device = eth0" || bad "wan.device 不是 eth0（实际：$(uci_get "$NET" interface wan device)）"
	[ "$(uci_get "$NET" interface wan proto)" = "pppoe" ] \
		&& ok "wan.proto = pppoe" || bad "wan.proto 不是 pppoe"
	[ "$(uci_get "$NET" interface wan ipv6)" = "auto" ] \
		&& ok "wan.ipv6 = auto（协商 IPv6CP 并自动生成动态接口 wan_6）" \
		|| bad "wan.ipv6 不是 auto（写成 0 会关掉 IPv6CP，IPv6 直接没了）"
	[ "$(uci_get "$NET" interface lan ip6assign)" = "60" ] \
		&& ok "lan.ip6assign = 60（客户端可从委派前缀拿到 /64）" || bad "lan.ip6assign 不是 60"
	[ "$(uci_get "$NET" interface lan ipaddr)" = "192.168.2.1" ] \
		&& ok "lan.ipaddr = 192.168.2.1" || bad "lan.ipaddr 不是 192.168.2.1"
	[ "$(uci_get "$NET" interface iptv device)" = "eth1" ] && [ "$(uci_get "$NET" interface iptv ipv6)" = "0" ] \
		&& ok "IPTV = eth1 且有意关闭 IPv6（IPv4 组播）" || bad "iptv 段不符合预期（eth1 / ipv6 0）"
	grep -q "list ports 'eth2'" "$NET" && grep -q "list ports 'eth3'" "$NET" \
		&& ok "br-lan = eth2 + eth3" || bad "br-lan 端口不是 eth2+eth3"
	[ "$(uci_get "$NET" globals globals packet_steering)" = "1" ] \
		&& ok "packet_steering = 1（4 核多队列转发）" || bad "缺少 packet_steering=1"
else
	bad "缺少 /etc/config/network"
fi
[ -f "$MNT2/etc/config/system" ] && ok "存在 /etc/config/system（与 network 一起阻止首启重新生成配置）" \
	|| bad "缺少 /etc/config/system —— 首启 config_generate 会重建配置，覆盖我们的预置"

sec "rootfs：升级保留与在线升级"
grep -q '^/etc/openclash$' "$MNT2/lib/upgrade/keep.d/99-cnc-plugins" 2>/dev/null \
	&& ok "keep.d 登记了 /etc/openclash（升级不丢订阅与规则）" || bad "keep.d 缺少 /etc/openclash"
[ -f "$MNT2/etc/sysupgrade.conf" ] && ok "存在 /etc/sysupgrade.conf" || bad "缺少 /etc/sysupgrade.conf"
if [ -f "$MNT2/etc/cnc-release" ]; then
	ok "存在 /etc/cnc-release：$(tr '\n' ' ' < "$MNT2/etc/cnc-release" | cut -c1-80)…"
	grep -q "^FIRMWARE_BUILD=$FIRMWARE_BUILD$" "$MNT2/etc/cnc-release" \
		&& ok "镜像内 FIRMWARE_BUILD=${FIRMWARE_BUILD}（与 versions.env 一致）" \
		|| bad "镜像内 FIRMWARE_BUILD 与 versions.env 不一致（CI 缓存残留？）"
else
	bad "缺少 /etc/cnc-release（在线升级无法比对版本）"
fi
if [ -f "$MNT2/etc/config/cnc_upgrade" ]; then
	u="$(sed -n "s/.*option url '\(.*\)'/\1/p" "$MNT2/etc/config/cnc_upgrade")"
	case "$u" in
		https://github.com/*/releases/download/*/latest.json) ok "在线升级源：$u" ;;
		*CHANGE_ME*) bad "在线升级源还是占位符（$u）：请在 versions.env 里填 RELEASE_REPO" ;;
		*) ok "在线升级源：$u" ;;
	esac
else
	bad "缺少 /etc/config/cnc_upgrade"
fi
[ -x "$MNT2/etc/uci-defaults/99-zz-cnc-defaults" ] && ok "首启收尾脚本可执行（权限正确）" \
	|| bad "/etc/uci-defaults/99-zz-cnc-defaults 不可执行（Windows/挂载盘上 checkout 常丢可执行位）"

sec "rootfs：内核模块（WireGuard / igc / tun / zram）"
KDIR="$(ls -d "$MNT2"/lib/modules/*/ 2>/dev/null | head -1)"
if [ -n "$KDIR" ]; then
	kv="$(basename "$KDIR")"
	ok "内核模块目录：$kv"
	[ "$kv" = "$OPENWRT_KVER" ] && ok "内核版本与 versions.env 一致（$OPENWRT_KVER）" \
		|| bad "内核版本 $kv 与 versions.env 的 $OPENWRT_KVER 不一致"
	for m in wireguard igc tun zram; do
		find "$KDIR" -name "${m}.ko*" | grep -q . && ok "kmod: ${m}.ko" || bad "缺少内核模块 ${m}.ko"
	done
else
	bad "找不到 /lib/modules/*（内核模块没装进去）"
fi

sec "rootfs：已安装包清单（apk）"
if [ -f "$MNT2/etc/apk/world" ]; then
	for p in luci-app-openclash lucky luci-app-lucky msd_lite luci-app-msd_lite vlmcsd \
	         luci-app-vlmcsd luci-app-cnc-upgrade bandix luci-app-bandix \
	         luci-theme-argon luci-app-argon-config \
	         luci-i18n-bandix-zh-cn luci-i18n-argon-config-zh-cn luci-i18n-base-zh-cn \
	         luci-i18n-firewall-zh-cn miniupnpd-nftables luci-app-upnp pciutils usbutils nvme-cli iperf3 tcpdump mtr-json luci-proto-wireguard wireguard-tools kmod-wireguard \
	         kmod-igc dnsmasq-full luci-proto-ipv6 odhcpd-ipv6only zram-swap; do
		grep -qx "$p" "$MNT2/etc/apk/world" && ok "已安装 $p" || bad "清单里没有 $p"
	done
	grep -qx 'dnsmasq' "$MNT2/etc/apk/world" && bad "dnsmasq 与 dnsmasq-full 同时存在（替换没生效）" \
		|| ok "dnsmasq 已被 dnsmasq-full 替换"
	# UPnP 必须是 nftables 版：iptables 版在 firewall4 上"能装不能生效"
	grep -qx 'miniupnpd-iptables' "$MNT2/etc/apk/world" \
		&& bad "装的是 miniupnpd-iptables（fw4/nftables 上规则不生效），应改为 miniupnpd-nftables" \
		|| ok "miniupnpd 是 nftables 版（与 firewall4 匹配）"
else
	echo "  (未找到 /etc/apk/world，改用文件系统断言，上面已覆盖)"
fi

# ----------------------------------------------------------------- 汇总
sec "汇总"
printf '  通过 %s%d%s 项，失败 %s%d%s 项\n' "$c_g" "$PASS" "$c_0" "$([ "$FAIL" -gt 0 ] && printf '%s' "$c_r" || printf '%s' "$c_g")" "$FAIL" "$c_0"
if [ "$FAIL" -gt 0 ]; then
	echo "  失败项："
	printf '    - %s\n' "${FAILED[@]}"
	exit 1
fi
echo "  镜像校验全部通过，可以刷机。"
