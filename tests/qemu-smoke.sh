#!/usr/bin/env bash
# =============================================================================
# QEMU 冒烟测试（可选）：用 OVMF 引导镜像，从串口抓启动日志
#
#   bash tests/qemu-smoke.sh out/xxx.img.gz
#
# 说明：
#   * 只验证"能启动 + 软件栈装进去了"，不验证 Intel I226-V 网卡（QEMU 没有这个硬件，
#     真实驱动能力由官方 kmod-igc 与上机核对保证）。
#   * 有 /dev/kvm 时用 KVM（约 30 秒），否则退回 TCG 软件模拟（约 3–10 分钟）。
#   * 需要：qemu-system-x86_64、OVMF（Debian: apt install qemu-system-x86 ovmf）
#   * 解压后的镜像约 4.2 GB，请注意磁盘空间。
# =============================================================================
set -uo pipefail

IMG="${1:-}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "用法: bash tests/qemu-smoke.sh <image.img.gz>"; exit 2; }

c_g=$'\033[32m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=; c_r=; c_b=; c_0=; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "缺少 qemu-system-x86_64，跳过冒烟测试"; exit 0; }
OVMF=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
	[ -f "$c" ] && { OVMF="$c"; break; }
done
[ -n "$OVMF" ] || { echo "找不到 OVMF 固件（apt install ovmf），跳过冒烟测试"; exit 0; }

WORK="$(mktemp -d /tmp/cnc-qemu.XXXXXX)"
LOG="$WORK/serial.log"
RAW="$WORK/disk.img"
cleanup() { [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null; sleep 1; kill -9 "${QPID:-0}" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

echo "${c_b}== QEMU 冒烟：解压镜像 ==${c_0}"
gzip -dc "$IMG" > "$RAW" || { echo "${c_r}解压失败${c_0}"; exit 1; }
ls -lh "$RAW" | awk '{print "  镜像大小:", $5}'

ACCEL=(-accel tcg)
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)
echo "  加速: ${ACCEL[*]}"
echo "  OVMF: $OVMF"

echo "${c_b}== 启动并在串口日志里等待 init 完成（最长 600 秒）==${c_0}"
qemu-system-x86_64 \
	-m 2048 -smp 2 "${ACCEL[@]}" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF" \
	-drive file="$RAW",format=raw,if=virtio,cache=unsafe \
	-netdev user,id=n0 -device e1000e,netdev=n0 \
	-netdev user,id=n1 -device e1000e,netdev=n1 \
	-nographic -serial "file:$LOG" -monitor none -display none \
	& QPID=$!

deadline=$((SECONDS + 600))
found=""
while [ $SECONDS -lt $deadline ]; do
	if grep -q 'init complete' "$LOG" 2>/dev/null; then found="init complete"; break; fi
	if grep -qi 'Kernel panic' "$LOG" 2>/dev/null; then found="PANIC"; break; fi
	kill -0 "$QPID" 2>/dev/null || break
	sleep 5
done

echo
echo "${c_b}== 结果 ==${c_0}"
rc=0
if [ "$found" = "init complete" ]; then
	echo "  ${c_g}✔${c_0} 系统启动到 init complete"
	grep -qi 'OpenWrt' "$LOG" && echo "  ${c_g}✔${c_0} 日志中出现 OpenWrt 标识" || { echo "  ${c_r}✘${c_0} 未见 OpenWrt 标识"; rc=1; }
	for p in br-lan eth0 eth1; do
		grep -q "$p" "$LOG" && echo "  ${c_g}✔${c_0} 网络接口出现：$p" || echo "  (提示) 日志中未见 $p（QEMU 网卡型号与真机不同，属正常）"
	done
	grep -qi 'sysupgrade' "$LOG" && echo "  ${c_g}✔${c_0} 日志中出现 sysupgrade（内核命令行/系统识别正常）"
else
	echo "  ${c_r}✘${c_0} 未在限定时间内启动完成（found=${found:-timeout}）"
	echo "  串口日志末尾 40 行："
	tail -n 40 "$LOG" | sed 's/^/    /'
	rc=1
fi
echo
echo "  完整串口日志：$LOG（脚本退出时会删除）"
[ "$rc" -eq 0 ] && cp -f "$LOG" "${IMG%.img.gz}.qemu-serial.log" 2>/dev/null && echo "  已保存到 ${IMG%.img.gz}.qemu-serial.log"
exit "$rc"
