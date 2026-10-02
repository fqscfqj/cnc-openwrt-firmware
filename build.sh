#!/usr/bin/env bash
# =============================================================================
# CncTion 1338NP-12 —— OpenWrt 固件构建脚本（本地与 GitHub Actions 共用同一份）
#
# 产物：out/openwrt-<版本>-x86-64-cnc1338np12-<fwbuild>-ext4-combined-efi.img.gz
#       + .sha256 + .manifest + latest.json（供路由器"网页一键在线升级"使用）
#
# 用法：
#   bash build.sh                     # 全流程
#   bash build.sh preflight tools sources packages image   # 只跑指定阶段
#   OPENWRT_VERSION=25.12.7 FIRMWARE_BUILD=r2 bash build.sh   # 升级到新版本
#   BAKE_SECRETS=1 bash build.sh      # 把 secrets/ 里的宽带账号密码与 root 密码烤进镜像
#
# 阶段说明：
#   preflight 环境与依赖自检        tools    下载并校验 SDK / ImageBuilder
#   sources   按 commit 拉第三方源   packages 用 SDK 编 7 个包（+3 个中文语言包）
#   image     组装镜像               verify   离线校验（GPT/挂载/包清单）
#   smoke     QEMU 冒烟（可选）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 参数覆盖
# 允许用环境变量覆盖 versions.env 里的少数几项（CI 与升级时用）
__overridable="OPENWRT_VERSION FIRMWARE_BUILD OPENWRT_MIRROR GITHUB_PROXY RELEASE_REPO RELEASE_TAG BAKE_SECRETS RUN_QEMU_SMOKE"
declare -A __ov=()
for __v in $__overridable; do __ov[$__v]="${!__v-}"; done
# shellcheck source=versions.env disable=SC1091
. "$HERE/versions.env"
for __v in $__overridable; do
	[ -n "${__ov[$__v]}" ] && printf -v "$__v" '%s' "${__ov[$__v]}"
done
unset __ov __v __overridable

# CI 里自动使用当前仓库作为发布地址
[ -n "${GITHUB_REPOSITORY:-}" ] && RELEASE_REPO="$GITHUB_REPOSITORY"
RELEASE_BASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"

WORK="$HERE/.work"
DL="$HERE/dl"
OUT="$HERE/out"
SDK="$WORK/sdk"
IB="$WORK/ib"
OVERLAY="$WORK/overlay"
JOBS="$(nproc 2>/dev/null || echo 4)"

# ---------------------------------------------------------------- 日志工具
c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_r=; c_g=; c_y=; c_b=; c_0=; }
log()  { printf '%s[%s]%s %s\n' "$c_b" "$(date +%H:%M:%S)" "$c_0" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s  ! %s%s\n' "$c_y" "$*" "$c_0" >&2; }
die()  { printf '%s  ✘ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }
stage(){ printf '\n%s===== %s =====%s\n' "$c_b" "$*" "$c_0"; }

# 给 github.com 下载/克隆加代理前缀（大陆构建机可用，例如 https://ghfast.top/）
gh_url() { [ -n "$GITHUB_PROXY" ] && printf '%s%s' "$GITHUB_PROXY" "$1" || printf '%s' "$1"; }

fetch_verified() { # <url> <dest> <sha256>
	local url="$1" dest="$2" want="$3" got
	if [ -s "$dest" ]; then
		got="$(sha256sum "$dest" | cut -d' ' -f1)"
		[ "$got" = "$want" ] && { ok "已缓存并通过校验：$(basename "$dest")"; return 0; }
		warn "缓存文件校验不符，重新下载：$(basename "$dest")"
		rm -f "$dest"
	fi
	mkdir -p "$(dirname "$dest")"
	log "下载 $(basename "$dest")"
	curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest.part" "$url" \
		|| die "下载失败：$url"
	mv -f "$dest.part" "$dest"
	got="$(sha256sum "$dest" | cut -d' ' -f1)"
	[ "$got" = "$want" ] || die "$(basename "$dest") 校验和不符：期望 $want，实际 $got"
	ok "校验通过：$(basename "$dest")"
}

clone_pinned() { # <repo> <branch> <commit> <dest>
	local repo="$1" br="$2" want="$3" dest="$4" got
	if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" = "$want" ]; then
		ok "源码已就位：$(basename "$dest") @ ${want:0:12}"
		return 0
	fi
	rm -rf "$dest"; mkdir -p "$dest"
	log "取源码 $(basename "$dest") @ ${want:0:12}"
	git -C "$dest" init -q
	git -C "$dest" remote add origin "$(gh_url "$repo")"
	# 优先按精确 commit 浅取（GitHub 支持按 SHA fetch）
	git -C "$dest" fetch -q --depth 1 origin "$want" 2>/dev/null || true
	if ! git -C "$dest" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1; then
		git -C "$dest" fetch -q --depth 1 origin "$br" || die "拉取失败：$repo ($br)"
	fi
	git -C "$dest" checkout -q FETCH_HEAD
	got="$(git -C "$dest" rev-parse HEAD)"
	if [ "$got" != "$want" ]; then
		warn "分支 $br 已前进（当前 $got），回退到 versions.env 钉住的 ${want:0:12}"
		git -C "$dest" fetch -q origin "$br" 2>/dev/null || true
		git -C "$dest" checkout -q "$want" || die "无法 checkout $want"
		got="$(git -C "$dest" rev-parse HEAD)"
	fi
	[ "$got" = "$want" ] || die "$repo checkout 结果不符：$got != $want"
	ok "$(basename "$dest") @ ${got:0:12}"
}

# =============================================================================
stage_preflight() {
	stage "preflight：环境自检"
	[ "$(uname -m)" = "x86_64" ] || die "需要 x86_64 Linux（当前 $(uname -m)）"
	log "构建机：$(uname -sr) / $(nproc) 核 / 可用磁盘 $(df -h "$HERE" | awk 'NR==2{print $4}')"
	local miss=()
	for t in curl git tar make gcc g++ python3 awk sed grep find xargs sha256sum nproc; do
		command -v "$t" >/dev/null 2>&1 || miss+=("$t")
	done
	# zstd 解包：GNU tar >= 1.31 自带 --zstd
	tar --zstd --help >/dev/null 2>&1 || command -v zstd >/dev/null 2>&1 || miss+=("zstd")
	[ ${#miss[@]} -eq 0 ] || die "缺少工具：${miss[*]}
   Debian/Ubuntu 上执行：
   sudo apt update && sudo apt install -y build-essential gawk unzip file rsync \\
     wget git python3 zstd libncurses-dev libssl-dev util-linux ca-certificates
   （getopt/losetup/blkid/mount 都由 util-linux 提供；dosfstools、parted 为可选）"
	local avail_kb; avail_kb="$(df -Pk "$HERE" | awk 'NR==2{print $4}')"
	[ "$avail_kb" -ge $((15*1024*1024)) ] || die "磁盘不足 15 GB（当前 $((avail_kb/1024/1024)) GB）"
	curl -fsSI --connect-timeout 15 "$OPENWRT_MIRROR/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}/" >/dev/null \
		|| die "无法访问镜像：$OPENWRT_MIRROR（可用 OPENWRT_MIRROR 换成 https://mirrors.tuna.tsinghua.edu.cn/openwrt 等）"
	mkdir -p "$WORK" "$DL" "$OUT"
	ok "环境自检通过（OpenWrt $OPENWRT_VERSION / 布局 p1=${KERNEL_PARTSIZE}MiB p2=${ROOTFS_PARTSIZE}MiB / 固件 $FIRMWARE_BUILD）"
}

stage_tools() {
	stage "tools：下载并校验 SDK 与 ImageBuilder"
	local base="$OPENWRT_MIRROR/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
	fetch_verified "$base/$SDK_FILE"            "$DL/$SDK_FILE"            "$SDK_SHA256"
	fetch_verified "$base/$IMAGEBUILDER_FILE"  "$DL/$IMAGEBUILDER_FILE"  "$IMAGEBUILDER_SHA256"

	rm -rf "$SDK" "$IB"; mkdir -p "$SDK" "$IB"
	log "解包 SDK…";         tar --zstd -xf "$DL/$SDK_FILE" -C "$SDK" --strip-components=1
	log "解包 ImageBuilder…"; tar --zstd -xf "$DL/$IMAGEBUILDER_FILE" -C "$IB" --strip-components=1
	[ -f "$SDK/Makefile" ] || die "SDK 解包异常"
	[ -f "$IB/Makefile" ]  || die "ImageBuilder 解包异常"

	# 确保第三方 apk 能被装入（本地索引用 --allow-untrusted 构建，
	# 命令行传空值可覆盖 .config 里的设置；详见 target/imagebuilder/files/Makefile）
	if [ -f "$IB/.config" ] && grep -q '^CONFIG_SIGNATURE_CHECK=y' "$IB/.config"; then
		log "关闭 ImageBuilder 的签名校验（以允许本地/第三方 apk）"
		sed -i 's/^CONFIG_SIGNATURE_CHECK=y/# CONFIG_SIGNATURE_CHECK is not set/' "$IB/.config"
	fi

	# 让 ImageBuilder 也从同一个镜像源拉官方包与 kmod（大陆构建机明显更快）
	if [ "$OPENWRT_MIRROR" != "https://downloads.openwrt.org" ]; then
		local rc
		while IFS= read -r rc; do
			sed -i "s|https://downloads.openwrt.org|$OPENWRT_MIRROR|g" "$rc"
			log "已把包源重写到镜像：$rc"
		done < <(find "$IB" -maxdepth 2 \( -name 'repositories' -o -name 'repositories.conf' \) 2>/dev/null)
	fi
	mkdir -p "$IB/packages"
	ok "工具链就绪"
}

stage_sources() {
	stage "sources：拉取第三方源码并安装进 SDK"
	local w="$HERE/pkgs/winsrc"
	clone_pinned "$IMMORTALWRT_PACKAGES_REPO" "$IMMORTALWRT_PACKAGES_BRANCH" "$IMMORTALWRT_PACKAGES_COMMIT" "$w/immortalwrt/packages"
	clone_pinned "$IMMORTALWRT_LUCI_REPO"     "$IMMORTALWRT_LUCI_BRANCH"     "$IMMORTALWRT_LUCI_COMMIT"     "$w/immortalwrt/luci"
	clone_pinned "$LUCKY_REPO"                "$LUCKY_BRANCH"                "$LUCKY_COMMIT"                "$w/gdy666/luci-app-lucky"

	# 我们自己写的包（直接来自本仓库，不需要下载）
	[ -f "$HERE/pkgs/winsrc/local/luci-app-cnc-upgrade/Makefile" ] \
		|| die "缺少本地包 pkgs/winsrc/local/luci-app-cnc-upgrade/Makefile"

	# 把 7 个包目录放进 SDK 的 package/
	while IFS='|' read -r name path; do
		[ -n "${name:-}" ] || continue
		rm -rf "$SDK/package/$name"
		cp -a "$w/$path" "$SDK/package/$name"
		rm -rf "$SDK/package/$name/.git"
		# 权限兜底：Windows/挂载盘上取回的源码会丢可执行位，
		# 而 luci.mk 是 `cp -pR root/*` 安装的，会把这个位一路带进 apk。
		find "$SDK/package/$name" -type f \
			\( -path '*/usr/sbin/*' -o -path '*/usr/bin/*' \
			   -o -path '*/etc/init.d/*' -o -path '*/etc/uci-defaults/*' \) \
			-exec chmod 0755 {} + 2>/dev/null || true
		# immortalwrt 的 LuCI 应用写的是相对路径 `include ../../luci.mk`：
		# 那只在 luci feed 的 applications/<app>/ 布局下成立。我们的包统一放在
		# package/ 下，这里改写成绝对路径（指向同一个 feeds/luci/luci.mk，语义不变）。
		if [ -f "$SDK/package/$name/Makefile" ]; then
			sed -i 's|^include \.\./\.\./luci\.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
				"$SDK/package/$name/Makefile"
		fi
	done <<< "$SDK_PACKAGES"
	ok "已放入 SDK：$(echo "$SDK_PACKAGES" | tr -d ' ' | awk -F'|' 'NF{printf "%s ",$1}')"

	# LuCI 应用需要 feeds/luci/luci.mk：默认 feeds 用的是 25.12.5 发布时钉住的 commit
	cd "$SDK"
	if [ -n "$GITHUB_PROXY" ]; then
		log "把 feeds 源重写到 GitHub 镜像（配合 GITHUB_PROXY）"
		sed -i -E 's#git://git\.openwrt\.org/(feed|project)/#https://github.com/openwrt/#g; s#https://git\.openwrt\.org/(feed|project)/#https://github.com/openwrt/#g' feeds.conf.default || true
	fi
	log "更新 feeds（首次约需数分钟）…"
	./scripts/feeds update -a >/dev/null 2>&1 || die "feeds update 失败"
	./scripts/feeds install -a >/dev/null 2>&1 || warn "feeds install 有部分失败（不影响我们这 7 个包）"
	[ -f "$SDK/feeds/luci/luci.mk" ] || die "缺少 feeds/luci/luci.mk，LuCI 插件无法编译"
	cd "$HERE"
	make -C "$SDK" defconfig >/dev/null 2>&1 || true

	# 语言包 luci-i18n-<app>-<语言> 是 luci.mk 依据 app 源码里的 po/<语言>/ 自动生成的
	# 子包，与 app 同目录、同一次编译产出。这里显式把它们选进 .config，保证编译 app 时
	# 一定产出对应 .apk（否则页面是英文 —— 这正是 lucky/msd_lite/vlmcsd 之前的样子）。
	# 必须在 defconfig 之后做：包目录此时才放进 SDK/package/，配置符号这时才存在。
	local _src _extra _key
	while IFS='|' read -r _src _extra; do
		[ -n "${_extra:-}" ] || continue
		# 三路写法与下面 ImageBuilder 的 set_ib_config 一致：
		# 未选中的包在 .config 里是注释行 `# CONFIG_PACKAGE_x is not set`，必须改写它而不是追加，
		# 否则同一个符号出现两次（Kconfig 取最后一条，但依赖解析会变得难以排查）。
		_key="CONFIG_PACKAGE_${_extra}"
		if grep -q "^${_key}=" "$SDK/.config" 2>/dev/null; then
			sed -i "s|^${_key}=.*|${_key}=y|" "$SDK/.config"
		elif grep -q "^# ${_key} is not set" "$SDK/.config" 2>/dev/null; then
			sed -i "s|^# ${_key} is not set|${_key}=y|" "$SDK/.config"
		else
			printf '%s=y\n' "$_key" >> "$SDK/.config"
		fi
		log "语言包选入 SDK 配置：$_extra"
	done <<< "$SDK_EXTRA_APKS"
	make -C "$SDK" oldconfig </dev/null >/dev/null 2>&1 || warn "SDK oldconfig 未跑通（语言包可能没被选中）"
	ok "feeds 就绪"
}

stage_packages() {
	stage "packages：用 SDK 编译 7 个包（含 3 个中文语言包）"
	mkdir -p "$IB/packages"
	# 清掉上一次运行留下的 apk：否则数量断言会失真，旧的同名包还可能被 apk 当成候选
	rm -f "$IB/packages"/*.apk "$IB/packages"/packages.adb 2>/dev/null || true
	local name path apk
	while IFS='|' read -r name path; do
		[ -n "${name:-}" ] || continue
		log "编译 $name"
		# PKG_HASH/PKG_MIRROR_HASH=skip：msd_lite 与 vlmcsd 是 git 源，OpenWrt 会把
		# checkout 重新打包成 tarball 并校验 PKG_MIRROR_HASH。该 tarball 的字节流依赖
		# 宿主机的 git/tar/zstd 版本（本例 Debian 13 与上游构建机不同），必然对不上；
		# download.mk 明确支持 skip 哨兵值。**源完整性仍由 versions.env 钉住的
		# PKG_SOURCE_VERSION(commit) 保证**，这里跳过的只是"重打包产物"的校验。
		make -C "$SDK" "package/$name/compile" V=s -j"$JOBS" \
			PKG_HASH=skip PKG_MIRROR_HASH=skip >"$WORK/build-$name.log" 2>&1 \
			|| { tail -n 40 "$WORK/build-$name.log" >&2; die "编译 $name 失败（完整日志 $WORK/build-$name.log）"; }
		apk="$(find "$SDK/bin/packages" -name "$name-*.apk" | head -1)"
		[ -n "$apk" ] || die "$name 没有产出 .apk"
		cp -f "$apk" "$IB/packages/"
		ok "$(basename "$apk")"

		# 同一次编译还会产出这个 app 的语言包（见 versions.env 的 SDK_EXTRA_APKS）。
		# ★漏掉它 = LuCI 页面全是英文★，所以这里找不到就直接构建失败，不静默放过。
		local _src _extra _eapk
		while IFS='|' read -r _src _extra; do
			[ -n "${_extra:-}" ] || continue
			[ "$_src" = "$name" ] || continue
			_eapk="$(find "$SDK/bin/packages" -name "$_extra-*.apk" | head -1)"
			[ -n "$_eapk" ] || die "$name 的语言包 $_extra 没有产出 .apk（po/ 目录或 luci.mk 有变？）"
			cp -f "$_eapk" "$IB/packages/"
			ok "  └ $(basename "$_eapk")"
		done <<< "$SDK_EXTRA_APKS"
	done <<< "$SDK_PACKAGES"

	stage "packages：下载并校验 7 个预编译 apk"
	local localcopy dest
	while IFS='|' read -r dir file url sha dest; do
		[ -n "${file:-}" ] || continue
		[ -n "${dest:-}" ] || dest="$file"
		localcopy="$HERE/pkgs/prebuilt/$dir/$file"
		# 本地已有且校验通过就用本地的（离线/大陆网络友好），否则按 URL+sha256 下载
		if [ -s "$localcopy" ] && [ "$(sha256sum "$localcopy" | cut -d' ' -f1)" = "$sha" ]; then
			ok "使用本地预编译包：$file"
			cp -f "$localcopy" "$IB/packages/$dest"
		else
			fetch_verified "$(gh_url "$url")" "$DL/prebuilt/$file" "$sha"
			cp -f "$DL/prebuilt/$file" "$IB/packages/$dest"
		fi
		[ "$dest" = "$file" ] || ok "  规范文件名 → $dest"
	done <<< "$PREBUILT_APKS"

	# 期望数量直接从清单推导，避免以后加包时忘了同步这里的魔数
	local want n
	want=$(( $(printf '%s\n' "$SDK_PACKAGES"  | grep -c '|' || true) \
	      + $(printf '%s\n' "$SDK_EXTRA_APKS" | grep -c '|' || true) \
	      + $(printf '%s\n' "$PREBUILT_APKS"  | grep -c '|' || true) ))
	n="$(find "$IB/packages" -maxdepth 1 -name '*.apk' | wc -l)"
	[ "$n" -eq "$want" ] \
		|| die "ImageBuilder packages/ 里应有 $want 个 apk，实际 $n 个（$(printf '%s\n' "$SDK_PACKAGES" | grep -c '|' || true) 自编 + $(printf '%s\n' "$SDK_EXTRA_APKS" | grep -c '|' || true) 语言包 + $(printf '%s\n' "$PREBUILT_APKS" | grep -c '|' || true) 预编译）"
	ok "$want 个 apk 全部就绪"
}

stage_image() {
	stage "image：组装镜像（ext4-combined-efi）"

	# ---- 组装 FILES 覆盖层 ----
	rm -rf "$OVERLAY"; mkdir -p "$OVERLAY"
	cp -a "$HERE/files/." "$OVERLAY/"
	# 权限兜底：某些文件系统（Windows/挂载盘）上取回的脚本会丢可执行位
	find "$OVERLAY" -type d -exec chmod 0755 {} +
	find "$OVERLAY/etc/uci-defaults" -type f -exec chmod 0755 {} +
	find "$OVERLAY" -type f ! -path "*/uci-defaults/*" -exec chmod 0644 {} +

	# ---- 版本标识（供"网页一键在线升级"比对）----
	cat > "$OVERLAY/etc/cnc-release" <<EOF
OPENWRT_VERSION=$OPENWRT_VERSION
FIRMWARE_BUILD=$FIRMWARE_BUILD
FIRMWARE_NAME=$FIRMWARE_NAME
KVER=$OPENWRT_KVER
TARGET=$OPENWRT_TARGET/$OPENWRT_SUBTARGET
KERNEL_PARTSIZE=$KERNEL_PARTSIZE
ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_BY=$(if [ -n "${GITHUB_ACTIONS:-}" ]; then echo github-actions; else echo local; fi)
EOF

	# ---- 在线升级入口的默认地址 ----
	cat > "$OVERLAY/etc/config/cnc_upgrade" <<EOF
config cnc_upgrade 'settings'
	option enabled '1'
	option url '$RELEASE_BASE_URL/latest.json'
	option proxy ''
	option auto_check '0'
	option keep_config '1'
EOF

	# ---- 宽带账号密码 ----
	if [ "$BAKE_SECRETS" = "1" ]; then
		[ -s "$HERE/secrets/wan.env" ] || die "BAKE_SECRETS=1 但缺少 secrets/wan.env（内容示例：WAN_USERNAME=你的宽带账号）"
		log "注入宽带账号密码（BAKE_SECRETS=1）"
		WAN_ENV="$HERE/secrets/wan.env" NET_CFG="$OVERLAY/etc/config/network" python3 - <<'PY'
import os, re
env = {}
for line in open(os.environ['WAN_ENV'], encoding='utf-8'):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    env[k.strip()] = v.strip().strip('"').strip("'")
p = os.environ['NET_CFG']
s = open(p, encoding='utf-8').read()
s = s.replace('__WAN_USERNAME__', env.get('WAN_USERNAME', ''))
s = s.replace('__WAN_PASSWORD__', env.get('WAN_PASSWORD', ''))
open(p, 'w', encoding='utf-8').write(s)
PY
		[ -s "$HERE/secrets/root-password.plain" ] && {
			log "注入 root 密码哈希（SHA-512 crypt）"
			openssl passwd -6 -stdin < "$HERE/secrets/root-password.plain" > "$OVERLAY/etc/cnc-root-hash"
			chmod 0600 "$OVERLAY/etc/cnc-root-hash"
		}
	else
		log "BAKE_SECRETS=0：不注入任何凭据（首登后在 LuCI 手填一次宽带账号密码）"
		NET_CFG="$OVERLAY/etc/config/network" python3 - <<'PY'
import os
p = os.environ['NET_CFG']
s = open(p, encoding='utf-8').read()
for k in ('__WAN_USERNAME__', '__WAN_PASSWORD__'):
    s = s.replace(k, '')
open(p, 'w', encoding='utf-8').write(s)
PY
	fi

	# ---- 把布局与串口参数写进 ImageBuilder 的 .config ----
	# ★ 实测教训：x86 镜像的 p1/p2 尺寸与 GRUB 参数取自 ImageBuilder 的 .config，
	#   在 make 命令行上传 CONFIG_TARGET_*_PARTSIZE **不生效**（出图仍是默认
	#   16 MiB / 104 MiB）。必须改这个文件。
	set_ib_config() { # <KEY> <VALUE>
		local key="$1" val="$2" f="$IB/.config"
		if grep -q "^${key}=" "$f" 2>/dev/null; then
			sed -i "s|^${key}=.*|${key}=${val}|" "$f"
		elif grep -q "^# ${key} is not set" "$f" 2>/dev/null; then
			sed -i "s|^# ${key} is not set|${key}=${val}|" "$f"
		else
			printf '%s=%s\n' "$key" "$val" >> "$f"
		fi
	}
	set_ib_config CONFIG_TARGET_KERNEL_PARTSIZE "$KERNEL_PARTSIZE"
	set_ib_config CONFIG_TARGET_ROOTFS_PARTSIZE "$ROOTFS_PARTSIZE"
	set_ib_config CONFIG_TARGET_SERIAL '"ttyS0"'
	set_ib_config CONFIG_GRUB_BAUDRATE 115200
	set_ib_config CONFIG_GRUB_CONSOLE y
	set_ib_config CONFIG_GRUB_TIMEOUT 3
	set_ib_config CONFIG_GRUB_TITLE "\"OpenWrt $FIRMWARE_NAME\""
	set_ib_config CONFIG_IPV6 y
	log "ImageBuilder .config：p1=${KERNEL_PARTSIZE}MiB p2=${ROOTFS_PARTSIZE}MiB / 串口 ttyS0 115200 / 超时 3s"

	# ---- 组装镜像 ----
	local pkgs; pkgs="$(echo "$IMAGE_PACKAGES" | tr '\n' ' ' | tr -s ' ')"
	log "make image（首次约 5–15 分钟）…"
	make -C "$IB" clean >/dev/null 2>&1 || true
	make -C "$IB" image \
		PROFILE=generic \
		FILES="$OVERLAY" \
		PACKAGES="$pkgs" \
		CONFIG_TARGET_KERNEL_PARTSIZE="$KERNEL_PARTSIZE" \
		CONFIG_TARGET_ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
		CONFIG_TARGET_SERIAL="ttyS0" \
		CONFIG_GRUB_BAUDRATE=115200 \
		CONFIG_GRUB_CONSOLE=y \
		CONFIG_GRUB_TIMEOUT=3 \
		CONFIG_GRUB_TITLE="OpenWrt $FIRMWARE_NAME" \
		CONFIG_IPV6=y \
		CONFIG_SIGNATURE_CHECK= \
		-j"$JOBS" >"$WORK/image.log" 2>&1 \
		|| { tail -n 60 "$WORK/image.log" >&2; die "make image 失败（完整日志 $WORK/image.log）"; }

	local tdir="$IB/bin/targets/$OPENWRT_TARGET/$OPENWRT_SUBTARGET"
	local src; src="$(find "$tdir" -maxdepth 1 -name 'openwrt-*-generic-ext4-combined-efi.img.gz' | head -1)"
	[ -n "$src" ] || die "没找到 ext4-combined-efi 镜像，检查 $tdir"

	local outname="openwrt-${OPENWRT_VERSION}-x86-64-${FIRMWARE_NAME}-${FIRMWARE_BUILD}-ext4-combined-efi.img.gz"
	mkdir -p "$OUT"
	cp -f "$src" "$OUT/$outname"
	sha256sum "$OUT/$outname" | sed "s| .*/| |" > "$OUT/$outname.sha256"
	local man; man="$(find "$tdir" -maxdepth 1 -name 'openwrt-*-generic.manifest' | head -1)"
	[ -n "$man" ] && cp -f "$man" "$OUT/$outname.manifest"

	# ---- latest.json（路由器端比对用）----
	IMG="$OUT/$outname" FILE="$outname" URL="$RELEASE_BASE_URL/$outname" \
	OV="$OPENWRT_VERSION" FB="$FIRMWARE_BUILD" KV="$OPENWRT_KVER" \
	python3 - > "$OUT/latest.json" <<'PY'
import json, os
p = os.environ['IMG']
print(json.dumps({
    "schema": 1,
    "openwrt_version": os.environ['OV'],
    "firmware_build": os.environ['FB'],
    "kver": os.environ['KV'],
    "target": "x86/64",
    "file": os.environ['FILE'],
    "url": os.environ['URL'],
    "sha256": __import__('hashlib').sha256(open(p,'rb').read()).hexdigest(),
    "size": os.path.getsize(p),
    "built_at": __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "notes": "CncTion 1338NP-12: openclash/lucky/vlmcsd/msd_lite/bandix + argon + wireguard + ipv6, eth0=WAN",
}, indent=2, ensure_ascii=False))
PY
	ok "镜像：out/$outname ($(du -h "$OUT/$outname" | cut -f1))"
	ok "SHA256：$(cut -d' ' -f1 "$OUT/$outname.sha256")"
}

stage_verify() {
	stage "verify：离线校验"
	local img; img="$(ls -1 "$OUT"/*.img.gz 2>/dev/null | head -1)"
	[ -n "$img" ] || die "out/ 里没有镜像"
	# layout-reference.txt 是"跨版本重编后仍能就地升级"的守门员。
	# 若它是上一次失败运行留下的、尺寸与当前布局常量不符，就先删掉让本轮重建。
	if [ -f "$HERE/layout-reference.txt" ] && \
	   ! grep -q "size_mib=$KERNEL_PARTSIZE " "$HERE/layout-reference.txt"; then
		log "layout-reference.txt 与当前布局常量不符（p1=${KERNEL_PARTSIZE}MiB），重新生成"
		rm -f "$HERE/layout-reference.txt"
	fi
	local runner=(bash "$HERE/verify.sh" "$img")
	if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
		sudo -E "${runner[@]}" || die "离线校验未通过"
	else
		"${runner[@]}" || die "离线校验未通过"
	fi
}

stage_smoke() {
	[ "$RUN_QEMU_SMOKE" = "1" ] || { log "跳过 QEMU 冒烟（RUN_QEMU_SMOKE=0）"; return 0; }
	stage "smoke：QEMU 起机冒烟（引导镜像并从串口进系统跑断言）"
	command -v qemu-system-x86_64 >/dev/null 2>&1 || \
		warn "没装 qemu-system-x86_64，冒烟会失败（Debian/Ubuntu: apt install qemu-system-x86 ovmf）"
	# CNC_QEMU_* 环境变量对脚本可覆盖：工作目录、内存、超时、是否进系统跑断言
	bash "$HERE/tests/qemu-smoke.sh" "$(ls -1 "$OUT"/*.img.gz | head -1)" || die "QEMU 冒烟未通过"
}

# =============================================================================
main() {
	local stages=("$@")
	if [ ${#stages[@]} -eq 0 ]; then
		stages=(preflight tools sources packages image verify)
		# RUN_QEMU_SMOKE=1（例如 CI 勾选 run_smoke）时，默认流程末尾自动加上冒烟
		[ "$RUN_QEMU_SMOKE" = "1" ] && stages+=(smoke)
	fi
	local s
	for s in "${stages[@]}"; do
		case "$s" in
			preflight|tools|sources|packages|image|verify|smoke) "stage_$s" ;;
			all) for s2 in preflight tools sources packages image verify smoke; do "stage_$s2"; done ;;
			-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
			*) die "未知阶段：$s" ;;
		esac
	done

	stage "完成"
	local img; img="$(ls -1 "$OUT"/*.img.gz 2>/dev/null | head -1)"
	[ -n "$img" ] || exit 0
	cat <<EOF
产物：
  $img
  $img.sha256
  $OUT/latest.json   ← 发布到 GitHub Release 的 tag '$RELEASE_TAG' 后，路由器即可"网页一键在线升级"

刷到路由器（在现有系统上原地刷，无需 U 盘）：
  scp "$img" root@192.168.2.1:/tmp/
  ssh root@192.168.2.1 'sysupgrade -F -n /tmp/$(basename "$img")'   # 首次：-n 不保留旧配置
  # 之后每次升级：不要加 -n（保留 /etc/config，含 WG 私钥与 IPv6 设置）

提示：首次刷写前务必确认串口线已接好（ttyS0 / 115200 8N1），那是唯一的救援通道。
EOF
}
main "$@"
