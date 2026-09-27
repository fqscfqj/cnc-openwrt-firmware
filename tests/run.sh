#!/usr/bin/env bash
# =============================================================================
# cnc-upgrade 脚本单元测试（不需要路由器、不需要网络）
#
#   bash tests/run.sh
#
# 做法：造一个沙箱，把 uci / jsonfilter / sysupgrade 换成桩，用 file:// 当"远端"，
#       然后覆盖这些路径：
#         正常升级 / 同版本 / 降级 / 远端不可达 / latest.json 不合法 /
#         sha256 不符 / 大小不符 / sysupgrade --test 失败 / 保留配置与清空配置
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pkgs/winsrc/local/luci-app-cnc-upgrade/root/usr/sbin/cnc-upgrade"
[ -f "$SCRIPT" ] || { echo "找不到被测脚本：$SCRIPT"; exit 2; }

c_g=$'\033[32m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=; c_r=; c_b=; c_0=; }
PASS=0; FAIL=0

SB="$(mktemp -d /tmp/cnc-tests.XXXXXX)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/stage" "$SB/fix"

# 用 file:// 当"远端"。MSYS/Windows 下 curl 需要 Windows 形式的路径，自动适配。
if command -v cygpath >/dev/null 2>&1; then
	FIX_BASE="file:///$(cygpath -m "$SB/fix")"
else
	FIX_BASE="file://$SB/fix"
fi

# ------------------------------------------------------------------ 桩程序
cat > "$SB/bin/uci" <<'EOF'
#!/bin/sh
# 只支持 `uci -q get cnc_upgrade.settings.keep_config`，其余一律失败（模拟"没配置"）
[ "${1:-}" = "-q" ] && shift
[ "${1:-}" = "get" ] && shift
case "$*" in
	cnc_upgrade.settings.keep_config) echo "${UCI_KEEP:-1}"; exit 0 ;;
	*) exit 1 ;;
esac
EOF

cat > "$SB/bin/sysupgrade" <<'EOF'
#!/bin/sh
# 记录调用参数；CNC_SUP_FAIL=1 时模拟 --test 失败
printf '%s\n' "$*" >> "${CNC_SUP_LOG:-/dev/null}"
[ "${CNC_SUP_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF

# jsonfilter 桩：只实现本脚本用到的 -i <file> -e '@.a.b' 形式
cat > "$SB/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, sys
path, expr = None, None
a = sys.argv[1:]
i = 0
while i < len(a):
    if a[i] == '-i':
        path = a[i+1]; i += 2
    elif a[i] == '-e':
        expr = a[i+1]; i += 2
    else:
        i += 1
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
cur = d
for key in (expr or '').lstrip('@').strip('.').split('.'):
    if not key:
        continue
    if isinstance(cur, dict) and key in cur:
        cur = cur[key]
    else:
        sys.exit(1)
if cur is None:
    sys.exit(1)
print(cur if not isinstance(cur, bool) else ('true' if cur else 'false'))
EOF
chmod +x "$SB/bin/uci" "$SB/bin/sysupgrade" "$SB/bin/jsonfilter"
export PATH="$SB/bin:$PATH"
export CNC_STAGE_DIR="$SB/stage"
export CNC_RELEASE_FILE="$SB/release"
export CNC_SYSUPGRADE="$SB/bin/sysupgrade"
export CNC_SUP_LOG="$SB/sysupgrade.args"

# ------------------------------------------------------------------ 工具函数
mk_release() { printf 'OPENWRT_VERSION=%s\nFIRMWARE_BUILD=%s\n' "$1" "$2" > "$CNC_RELEASE_FILE"; }

mk_image() { # 生成"假固件"（内容随机，仅用于校验和比对）
	head -c 8192 /dev/urandom > "$SB/fix/fw.img.gz"
	FW_SHA="$(sha256sum "$SB/fix/fw.img.gz" | cut -d' ' -f1)"
	FW_SIZE="$(wc -c < "$SB/fix/fw.img.gz" | tr -d ' ')"
}

mk_latest() { # <version> <build> [sha] [size] [extra-omit]
	local v="$1" b="$2" sha="${3:-$FW_SHA}" size="${4:-$FW_SIZE}" omit="${5:-}"
	python3 - "$SB/fix/latest.json" "$v" "$b" "$sha" "$size" "$omit" "$FIX_BASE" <<'PY'
import json, sys
out, v, b, sha, size, omit, base = sys.argv[1:8]
d = {"schema": 1, "openwrt_version": v, "firmware_build": b, "kver": "6.12.94",
     "target": "x86/64", "file": "fw.img.gz",
     "url": base + "/fw.img.gz",
     "sha256": sha, "size": int(size), "built_at": "2026-09-27T00:00:00Z", "notes": "unit test"}
if omit:
    d.pop(omit, None)
json.dump(d, open(out, 'w'))
PY
}

reset() {
	rm -rf "$SB/stage"; mkdir -p "$SB/stage"
	: > "$CNC_SUP_LOG"
	unset UCI_KEEP CNC_SUP_FAIL
}

check() { # <用例名> <期望:ok|fail> <子命令...>
	local name="$1" want="$2"; shift 2
	local out rc
	out="$(run_cmd "$@" 2>"$SB/stderr")"; rc=$?
	if [ "$want" = ok ]; then
		if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '"ok": true'; then
			PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$c_g" "$c_0" "$name"
		else
			FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n    rc=%s out=%s err=%s\n' "$c_r" "$name" "$c_0" "$rc" "$out" "$(head -c 300 "$SB/stderr")"
		fi
	else
		if [ $rc -ne 0 ]; then
			PASS=$((PASS+1)); printf '  %s✔%s %s（按预期失败：%s）\n' "$c_g" "$c_0" "$name" "$(head -c 120 "$SB/stderr")"
		else
			FAIL=$((FAIL+1)); printf '  %s✘ %s%s（本应失败却成功了）out=%s\n' "$c_r" "$name" "$c_0" "$out"
		fi
	fi
}

run_cmd() { # 用 file:// 指向 fixture 目录
	CNC_URL="$FIX_BASE/latest.json" sh "$SCRIPT" "$@"
}

assert_contains() { # <用例名> <haystack> <needle>
	if printf '%s' "$2" | grep -q "$3"; then
		PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$c_g" "$c_0" "$1"
	else
		FAIL=$((FAIL+1)); printf '  %s✘ %s%s（未找到 %s）\n' "$c_r" "$1" "$c_0" "$3"
	fi
}

echo "${c_b}== cnc-upgrade 单元测试 ==${c_0}"

echo "-- check --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
out="$(run_cmd check 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && PASS=$((PASS+1)) && printf '  %s✔%s 远端更新时 check 成功\n' "$c_g" "$c_0" || { FAIL=$((FAIL+1)); printf '  %s✘%s 远端更新时 check 失败\n' "$c_r" "$c_0"; }
assert_contains "判定为 upgrade" "$out" '"direction": "upgrade"'
assert_contains "标记 available=true" "$out" '"available": 1'

reset; mk_release 25.12.5 r2; mk_image; mk_latest 25.12.5 r2
out="$(run_cmd check 2>/dev/null)"
assert_contains "同版本同构建 → direction=same" "$out" '"direction": "same"'
assert_contains "同版本同构建 → available=0" "$out" '"available": 0'

reset; mk_release 25.12.5 r3; mk_image; mk_latest 25.12.5 r1
out="$(run_cmd check 2>/dev/null)"
assert_contains "同版本不同构建 → upgrade" "$out" '"direction": "upgrade"'

reset; mk_release 25.12.7 r1; mk_image; mk_latest 25.12.5 r1
out="$(run_cmd check 2>/dev/null)"
assert_contains "远端更旧 → downgrade" "$out" '"direction": "downgrade"'

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "" "" sha256
check "latest.json 缺 sha256 时拒绝" fail check

reset; mk_release 25.12.5 r1; mk_image
CNC_URL="$FIX_BASE/nope.json" sh "$SCRIPT" check >/dev/null 2>&1 \
	&& { FAIL=$((FAIL+1)); printf '  %s✘%s 远端 404 竟然成功了\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s 远端 404 时按预期失败\n' "$c_g" "$c_0"; }

echo "-- download --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
check "sha256 与大小都正确 → 下载通过" ok download
[ -s "$SB/stage/fw.img.gz" ] && { PASS=$((PASS+1)); printf '  %s✔%s 镜像落在暂存目录\n' "$c_g" "$c_0"; } \
	|| { FAIL=$((FAIL+1)); printf '  %s✘%s 暂存目录里没有镜像\n' "$c_r" "$c_0"; }
grep -q -- '--test' "$CNC_SUP_LOG" && { PASS=$((PASS+1)); printf '  %s✔%s 调用了 sysupgrade --test\n' "$c_g" "$c_0"; } \
	|| { FAIL=$((FAIL+1)); printf '  %s✘%s 没有调用 sysupgrade --test\n' "$c_r" "$c_0"; }

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "deadbeef" ""
check "sha256 不符 → 拒绝" fail download
[ -e "$SB/stage/fw.img.gz" ] && { FAIL=$((FAIL+1)); printf '  %s✘%s 校验失败后残留了坏包\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s 校验失败后已删除坏包\n' "$c_g" "$c_0"; }

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "$FW_SHA" "12345"
check "大小不符 → 拒绝" fail download

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
CNC_SUP_FAIL=1 run_cmd download >/dev/null 2>&1 \
	&& { FAIL=$((FAIL+1)); printf '  %s✘%s sysupgrade --test 失败时竟然通过了\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s sysupgrade --test 失败 → 拒绝并删除\n' "$c_g" "$c_0"; }

echo "-- flash --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
check "默认保留配置刷写成功" ok flash
grep -q -- '-n' "$CNC_SUP_LOG" && { FAIL=$((FAIL+1)); printf '  %s✘%s 保留配置时不该传 -n\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s 保留配置时未传 -n\n' "$c_g" "$c_0"; }

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
UCI_KEEP=0 sh -c "CNC_URL=$FIX_BASE/latest.json CNC_STAGE_DIR=$SB/stage CNC_RELEASE_FILE=$CNC_RELEASE_FILE CNC_SYSUPGRADE=$CNC_SYSUPGRADE sh '$SCRIPT' download" >/dev/null 2>&1
UCI_KEEP=0 sh -c "CNC_URL=$FIX_BASE/latest.json CNC_STAGE_DIR=$SB/stage CNC_RELEASE_FILE=$CNC_RELEASE_FILE CNC_SYSUPGRADE=$CNC_SYSUPGRADE sh '$SCRIPT' flash" >/dev/null 2>&1
grep -q -- '-n' "$CNC_SUP_LOG" && { PASS=$((PASS+1)); printf '  %s✔%s keep_config=0 时传 -n（清空配置重刷）\n' "$c_g" "$c_0"; } \
	|| { FAIL=$((FAIL+1)); printf '  %s✘%s keep_config=0 时没有传 -n\n' "$c_r" "$c_0"; }

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "badsha" ""
printf 'tampered' >> "$SB/stage/fw.img.gz" 2>/dev/null || true
CNC_SUP_LOG="$SB/sup2.log" run_cmd flash >/dev/null 2>&1 \
	&& { FAIL=$((FAIL+1)); printf '  %s✘%s 坏包刷写竟然通过\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s 暂存镜像被篡改 → 刷写前拦截\n' "$c_g" "$c_0"; }

echo "-- clean --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
check "clean 清空暂存目录" ok clean
[ -d "$SB/stage" ] && { FAIL=$((FAIL+1)); printf '  %s✘%s clean 后暂存目录仍在\n' "$c_r" "$c_0"; } \
	|| { PASS=$((PASS+1)); printf '  %s✔%s 暂存目录已清空\n' "$c_g" "$c_0"; }

echo
printf '%s通过 %d 项，失败 %d 项%s\n' "$([ $FAIL -eq 0 ] && printf '%s' "$c_g" || printf '%s' "$c_r")" "$PASS" "$FAIL" "$c_0"
[ "$FAIL" -eq 0 ]
