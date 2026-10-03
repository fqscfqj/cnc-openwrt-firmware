#!/usr/bin/env bash
# =============================================================================
# cnc-upgrade 脚本单元测试（不需要路由器、不需要网络）
#
#   bash tests/run.sh
#
# 做法：造一个沙箱，把 uci / jsonfilter / sysupgrade 换成桩，用 file:// 当"远端"，
#       然后覆盖这些场景：
#         正常升级 / 同名重发 / 降级 / 远端不可达 / latest.json 不合法 /
#         sha256 不符 / 大小不符 / sysupgrade --test 失败 / 保留配置与清空配置 /
#         分区布局变化拦截 / 备份体积超预算拦截 / file 字段目录穿越拦截 / 并发锁
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
# 记录调用参数（含子命令），并按环境变量模拟各种结果：
#   CNC_BACKUP_BYTES   -b <file> 时生成多大的"备份"（默认 1024 字节）
#   CNC_SUP_FAIL=1     --test 失败
#   CNC_SUP_LAYOUT=1   --test 报"分区布局已变"（真机上 sysupgrade 此时**仍返回 0**）
printf '%s\n' "$*" >> "${CNC_SUP_LOG:-/dev/null}"
prev=""
for a in "$@"; do
	[ "$prev" = "-b" ] && head -c "${CNC_BACKUP_BYTES:-1024}" /dev/zero > "$a" 2>/dev/null
	prev="$a"
done
[ "${CNC_SUP_FAIL:-0}" = "1" ] && exit 1
[ "${CNC_SUP_LAYOUT:-0}" = "1" ] && \
	echo "upgrade: Partition layout has changed. Full image will be written." >&2
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
# 与 build.sh 同源的"构建时间戳"：/etc/cnc-release 的 BUILT_AT 与 latest.json 的
# built_at 现在是同一个值，才能靠它判断"是不是同一份固件"。
STAMP_DEFAULT="2026-09-27T00:00:00Z"

mk_release() { # <version> <build> [built_at]
	printf 'OPENWRT_VERSION=%s\nFIRMWARE_BUILD=%s\nBUILT_AT=%s\n' \
		"$1" "$2" "${3:-$STAMP_DEFAULT}" > "$CNC_RELEASE_FILE"
}

mk_image() { # 生成"假固件"（内容随机，仅用于校验和比对）
	head -c 8192 /dev/urandom > "$SB/fix/fw.img.gz"
	FW_SHA="$(sha256sum "$SB/fix/fw.img.gz" | cut -d' ' -f1)"
	FW_SIZE="$(wc -c < "$SB/fix/fw.img.gz" | tr -d ' ')"
}

mk_latest() { # <version> <build> [sha] [size] [omit] [built_at] [file]
	local v="$1" b="$2" sha="${3:-$FW_SHA}" size="${4:-$FW_SIZE}" omit="${5:-}"
	local stamp="${6:-$STAMP_DEFAULT}" file="${7:-fw.img.gz}"
	python3 - "$SB/fix/latest.json" "$v" "$b" "$sha" "$size" "$omit" "$stamp" "$file" "$FIX_BASE" <<'PY'
import json, sys
out, v, b, sha, size, omit, stamp, fname, base = sys.argv[1:10]
d = {"schema": 1, "openwrt_version": v, "firmware_build": b, "kver": "6.12.94",
     "target": "x86/64", "file": fname,
     "url": base + "/" + fname,
     "sha256": sha, "size": int(size), "built_at": stamp, "notes": "unit test"}
if omit:
    d.pop(omit, None)
json.dump(d, open(out, 'w'))
PY
}

reset() {
	rm -rf "$SB/stage"; mkdir -p "$SB/stage"
	: > "$CNC_SUP_LOG"
	unset UCI_KEEP CNC_SUP_FAIL CNC_SUP_LAYOUT CNC_BACKUP_BYTES 2>/dev/null || true
	# 体积预算给一个宽松的默认值，让"与预算无关"的用例不受宿主 /boot 大小影响
	export CNC_BACKUP_BUDGET_KB=1048576
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

assert_ok()   { PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$c_g" "$c_0" "$1"; }
assert_bad()  { FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n' "$c_r" "$1" "$c_0"; }

echo "${c_b}== cnc-upgrade 单元测试 ==${c_0}"

echo "-- check --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
out="$(run_cmd check 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && assert_ok "远端更新时 check 成功" || assert_bad "远端更新时 check 失败"
assert_contains "判定为 upgrade" "$out" '"direction": "upgrade"'
assert_contains "标记 available=true" "$out" '"available": 1'

reset; mk_release 25.12.5 r2; mk_image; mk_latest 25.12.5 r2
out="$(run_cmd check 2>/dev/null)"
assert_contains "同版本同构建同时间戳 → direction=same" "$out" '"direction": "same"'
assert_contains "同版本同构建同时间戳 → available=0" "$out" '"available": 0'

# ★ 同名重发：版本号与构建号都没变，但内容变了（built_at 不同）。
#   旧实现只看版本号+构建号，会把这种发布判成 same —— 于是"忘了改 FIRMWARE_BUILD
#   的那次发布"路由器永远看不到。这里必须提示可升级。
reset; mk_release 25.12.5 r1 "$STAMP_DEFAULT"; mk_image; mk_latest 25.12.5 r1 "" "" "" "2026-10-02T06:42:49Z"
out="$(run_cmd check 2>/dev/null)"
assert_contains "同名重发（built_at 变了）→ upgrade" "$out" '"direction": "upgrade"'
assert_contains "同名重发 → available=1" "$out" '"available": 1'

# ★ rN 要按数字比：本地 r3 遇到远端 r1 是"降级"，不是"可升级"。
#   旧实现对"同版本号不同构建号"一律返回 upgrade，会把降级当升级推给用户。
reset; mk_release 25.12.5 r3; mk_image; mk_latest 25.12.5 r1
out="$(run_cmd check 2>/dev/null)"
assert_contains "同版本 r3 遇到 r1 → downgrade" "$out" '"direction": "downgrade"'

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.5 r10
out="$(run_cmd check 2>/dev/null)"
assert_contains "同版本 r1 遇到 r10 → upgrade（按数字比，不是按字符串）" "$out" '"direction": "upgrade"'

reset; mk_release 25.12.7 r1; mk_image; mk_latest 25.12.5 r1
out="$(run_cmd check 2>/dev/null)"
assert_contains "远端更旧 → downgrade" "$out" '"direction": "downgrade"'

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "" "" sha256
check "latest.json 缺 sha256 时拒绝" fail check

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "" "" "" "" ""; sed -i 's/"schema": 1/"schema": 2/' "$SB/fix/latest.json"
check "schema 不是 1 时拒绝" fail check

reset; mk_release 25.12.5 r1; mk_image
CNC_URL="$FIX_BASE/nope.json" sh "$SCRIPT" check >/dev/null 2>&1 \
	&& assert_bad "远端 404 竟然成功了" \
	|| assert_ok "远端 404 时按预期失败"

echo "-- download --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
check "sha256 与大小都正确 → 下载通过" ok download
[ -s "$SB/stage/fw.img.gz" ] && assert_ok "镜像落在暂存目录" || assert_bad "暂存目录里没有镜像"
grep -q -- '--test' "$CNC_SUP_LOG" && assert_ok "调用了 sysupgrade --test" || assert_bad "没有调用 sysupgrade --test"
grep -q -- '-b' "$CNC_SUP_LOG" && assert_ok "保留了配置 → 量了备份体积" || assert_bad "没有量备份体积"

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "deadbeef" ""
check "sha256 不符 → 拒绝" fail download
[ -e "$SB/stage/fw.img.gz" ] && assert_bad "校验失败后残留了坏包" || assert_ok "校验失败后已删除坏包"

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "$FW_SHA" "12345"
check "大小不符 → 拒绝" fail download

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
CNC_SUP_FAIL=1 run_cmd download >/dev/null 2>&1 \
	&& assert_bad "sysupgrade --test 失败时竟然通过了" \
	|| assert_ok "sysupgrade --test 失败 → 拒绝并删除"

echo "-- download：file 字段目录穿越 --"
# latest.json 的 file 会被拼成 $STAGE/$file 并用于 rm -f，最后交给 sysupgrade。
# 带 / 就能穿出暂存目录（删任意文件 / 把任意文件当镜像刷）。
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
echo "sentinel" > "$SB/outside.txt"
python3 - "$SB/fix/latest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['file'] = '../../outside.txt'
json.dump(d, open(p, 'w'))
PY
check "file 含 ../（目录穿越）→ 拒绝" fail download
[ -s "$SB/outside.txt" ] && assert_ok "暂存目录外的文件没被删除" || assert_bad "暂存目录外的文件被删掉了"

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2 "" "" "" "" "/etc/shadow"
check "file 是绝对路径 → 拒绝" fail download

echo "-- download：备份体积预算（A2）--"
# sysupgrade 的 platform_copy_config 不检查 cp 失败 ⇒ 备份放不下时升级"成功"但配置丢。
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
CNC_BACKUP_BYTES=8192 CNC_BACKUP_BUDGET_KB=4 run_cmd download >/dev/null 2>&1 \
	&& assert_bad "备份超出预算时下载阶段竟然通过了" \
	|| assert_ok "备份超出预算 → 下载阶段就拦下"

# 清空配置重刷（-n）时不会写备份文件，不该被预算拦住
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
UCI_KEEP=0 CNC_BACKUP_BYTES=8192 CNC_BACKUP_BUDGET_KB=4 sh -c \
	"CNC_URL=$FIX_BASE/latest.json CNC_STAGE_DIR=$SB/stage CNC_RELEASE_FILE=$CNC_RELEASE_FILE CNC_SYSUPGRADE=$CNC_SYSUPGRADE CNC_SUP_LOG=$CNC_SUP_LOG sh '$SCRIPT' download" >/dev/null 2>&1 \
	&& assert_ok "keep_config=0 时不检查备份预算" \
	|| assert_bad "keep_config=0 时被备份预算误拦"

echo "-- flash --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
check "默认保留配置刷写成功" ok flash
grep -q -- '-n' "$CNC_SUP_LOG" && assert_bad "保留配置时不该传 -n" || assert_ok "保留配置时未传 -n"

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
UCI_KEEP=0 sh -c "CNC_URL=$FIX_BASE/latest.json CNC_STAGE_DIR=$SB/stage CNC_RELEASE_FILE=$CNC_RELEASE_FILE CNC_SYSUPGRADE=$CNC_SYSUPGRADE sh '$SCRIPT' download" >/dev/null 2>&1
UCI_KEEP=0 sh -c "CNC_URL=$FIX_BASE/latest.json CNC_STAGE_DIR=$SB/stage CNC_RELEASE_FILE=$CNC_RELEASE_FILE CNC_SYSUPGRADE=$CNC_SYSUPGRADE sh '$SCRIPT' flash" >/dev/null 2>&1
grep -q -- '-n' "$CNC_SUP_LOG" && assert_ok "keep_config=0 时传 -n（清空配置重刷）" || assert_bad "keep_config=0 时没有传 -n"

# ★ 刷写前拦截被篡改的暂存镜像（旧版这个用例是空转的：reset 已经清掉 stage，
#   `>> ... || true` 静默失败，根本没有镜像存在，只测到了下载路径）。
#   这里真下载一次、再篡改、再单独跑 flash，才真的覆盖 flash 里的 sha 校验。
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
[ -s "$SB/stage/fw.img.gz" ] || assert_bad "前置下载失败，用例无效"
printf 'tampered' >> "$SB/stage/fw.img.gz"
CNC_SUP_LOG="$SB/sup2.log" run_cmd flash >/dev/null 2>&1 \
	&& assert_bad "坏包刷写竟然通过" \
	|| assert_ok "暂存镜像被篡改 → 刷写前拦截"

echo "-- flash：分区布局变化拦截（A3）--"
# sysupgrade --test 对布局变化**仍然返回 0**（只打一行警告），旧实现只看返回码，
# 于是网页升级会一路放行并整盘覆写。这里断言我们看输出、并且拦下来。
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
CNC_SUP_LAYOUT=1 run_cmd flash >/dev/null 2>"$SB/stderr" \
	&& assert_bad "布局变化时刷写竟然通过了" \
	|| assert_ok "布局变化 → 刷写被拦下"
grep -q '整盘覆写' "$SB/stderr" && assert_ok "拦截信息说明了会整盘覆写" || assert_bad "拦截信息没说清后果"
grep -q -- 'Partition layout has changed' "$SB/stderr" && assert_ok "拦截信息带上了 sysupgrade 的原文" || assert_bad "拦截信息缺 sysupgrade 原文"

echo "-- flash：备份体积预算拦截（A2）--"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
CNC_BACKUP_BUDGET_KB=1048576 run_cmd download >/dev/null 2>&1
CNC_BACKUP_BYTES=8192 CNC_BACKUP_BUDGET_KB=4 run_cmd flash >/dev/null 2>"$SB/stderr" \
	&& assert_bad "备份超预算时刷写竟然通过了" \
	|| assert_ok "备份超预算 → 刷写被拦下"
grep -q '静默' "$SB/stderr" && assert_ok "拦截信息点明了是静默丢失" || assert_bad "拦截信息没点明静默丢失"

echo "-- 并发锁 --"
# 双击/两个标签页 = 两个 sysupgrade 同时写同一块盘 = 变砖。
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
mkdir -p "$SB/stage/.lock"; printf '%s' "$$" > "$SB/stage/.lock/pid"
run_cmd download >/dev/null 2>&1 && assert_bad "有活跃锁时竟然继续执行" || assert_ok "已有升级任务在跑 → 拒绝并发"
rm -rf "$SB/stage/.lock"

reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
mkdir -p "$SB/stage/.lock"; printf '999999' > "$SB/stage/.lock/pid"
check "陈旧锁（进程已不在）→ 自动清理并继续" ok download
[ -d "$SB/stage/.lock" ] && assert_bad "跑完后锁没释放" || assert_ok "跑完后锁已释放"

echo "-- clean --"
reset; mk_release 25.12.5 r1; mk_image; mk_latest 25.12.7 r2
run_cmd download >/dev/null 2>&1
check "clean 清空暂存目录" ok clean
[ -d "$SB/stage" ] && assert_bad "clean 后暂存目录仍在" || assert_ok "暂存目录已清空"

CNC_STAGE_DIR=/ sh "$SCRIPT" clean >/dev/null 2>&1 \
	&& assert_bad "clean 竟然接受了 STAGE=/" \
	|| assert_ok "clean 拒绝对 / 执行"

echo
printf '%s通过 %d 项，失败 %d 项%s\n' "$([ $FAIL -eq 0 ] && printf '%s' "$c_g" || printf '%s' "$c_r")" "$PASS" "$FAIL" "$c_0"
[ "$FAIL" -eq 0 ]
