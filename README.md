# CncTion 1338NP-12 固件工程（fn/）

给 **CncTion 1338NP-12**（N6000 四网口软路由 / 16 GB Optane / 4× Intel I226-V / UEFI / 串口 ttyS0）
构建一份**可复现、可长期升级**的 OpenWrt 固件。

* 基线：**OpenWrt 25.12.5 x86/64 generic**，`ext4-combined-efi` 镜像（内核 6.12.94，apk 包管理）
* 插件：**OpenClash / Lucky / vlmcsd / msd_lite / Bandix**
* Web：**Argon 主题**（默认）+ 简体中文
* 网络：**eth0 = WAN(PPPoE)**、eth1 = IPTV、eth2+eth3 = LAN 桥（192.168.2.1/24）
* 另有：**WireGuard**（只装能力不预置隧道）、**IPv6 默认开启**、**网页一键在线升级**
* 另装：**UPnP/NAT-PMP**（`miniupnpd-nftables` + LuCI 页，镜像里默认不开）、**x86 排障工具**（`lspci` / `lsusb` / `nvme` / `iperf3` / `tcpdump` / `mtr`）

---

## 快速开始

```bash
# 构建机（x86_64 Debian/Ubuntu）：见 03-固件构建与升级.md §1 装依赖
cd fn
bash build.sh            # 出图 + 离线校验，产物在 out/
bash tests/run.sh        # 升级逻辑单元测试（22 项，不需要硬件）
```

## 升级到新版本（只改两个值）

```bash
# fn/versions.env
OPENWRT_VERSION=25.12.7
FIRMWARE_BUILD=r2
```

重跑 `bash build.sh`（或 push 让 GitHub Actions 自动构建并发布），
然后在路由器 **LuCI → 系统 → 固件在线升级** 点「检查更新 → 下载并校验 → 刷写并重启」。

> ★ **铁律**：不要改 `KERNEL_PARTSIZE` / `ROOTFS_PARTSIZE`。
> 默认 `sysupgrade` 只在"镜像分区表 == 磁盘分区表"时才按分区就地写入；
> 改这两个值会导致以后每次升级都整盘覆写。`verify.sh` 会拿 `layout-reference.txt` 比对。

## 文件

| 文件 | 作用 |
|---|---|
| `versions.env` | **唯一的版本号文件**：OpenWrt 版本、第三方源 commit、14 个 apk 的版本与 sha256、包清单、布局常量 |
| `build.sh` | 构建主脚本：自检 → 官方工具链（校验 sha256）→ 取源码（按 commit）→ SDK 编 7 个包 → ImageBuilder 出图 → 校验 |
| `verify.sh` | 离线校验：GPT 布局、grub 串口/failsafe、四大插件与 Bandix/WireGuard/Argon/UPnP 是否真的在镜像里、IPv6 预置、升级保留清单 |
| `layout-reference.txt` | 分区布局指纹（保证升级能"就地写入"） |
| `files/` | 预置进镜像的配置：`network`(eth0=WAN/IPv6)、`luci`(Argon)、`system`、`uci-defaults`、`keep.d` |
| `pkgs/winsrc/local/luci-app-cnc-upgrade/` | 自研"固件在线升级"包（shell 逻辑 + LuCI 页面） |
| `pkgs/prebuilt/` | 7 个预编译 apk（OpenClash / Argon×3 / Bandix×3），按 sha256 校验 |
| `tests/run.sh` | 升级逻辑单测（版本比较、sha256/大小校验、降级、坏包拦截、保留/清空配置） |
| `tests/qemu-smoke.sh` | QEMU+OVMF 冒烟：引导镜像 + 串口进系统跑 91 项断言（见手册 §2.1） |
| `smoke-evidence/` | 冒烟的原始证据（断言结果 / 系统取证 / 串口日志 / 运行日志 + 说明） |
| `.github/workflows/build.yml` | CI：测试 → 构建 → 校验 → 发布到"滚动 Release + 按版本 Release" |
| `secrets/` | 可选凭据（`BAKE_SECRETS=1` 时才用，不入库） |
| `03-固件构建与升级.md` | **完整运行手册**：构建、升级、刷机、上机核对、WireGuard/IPv6/Bandix 细节、故障处置 |

## 为什么这样设计（三个关键取舍）

1. **用官方 SDK 编第三方包、用官方 ImageBuilder 组装**，而不是全源码编译内核：
   内核与 kmod 来自官方同一发布，ABI 天然匹配；改版本号重编即可，不存在"内核和 kmod 对不上"。
2. **配置进镜像 + 升级靠 conffiles/keep.d 保留**，而不是升级后手工回填：
   `/etc/config/*` 由 apk 的 conffiles 机制自动保留（已核对 25.12 的 `sysupgrade` 源码），
   插件数据目录由 `lib/upgrade/keep.d/99-cnc-plugins` 登记。
3. **不装官方 ASU**：它只认官方仓库，会把这 4 个第三方插件丢掉；
   升级入口改为"重编镜像 + sysupgrade"，并在网页上做成一个按钮。
