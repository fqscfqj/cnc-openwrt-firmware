# QEMU 冒烟证据（2026-09-27 / 固件 r1）

> ⚠️ **先读这段：本目录的证据是"历史快照"，它证明的不是"现在发布的那份图"**
>
> 本目录记录的是 **2026-09-27 那次构建**（`OPENWRT_VERSION=25.12.5`,
> `FIRMWARE_BUILD=r1`）的两份镜像的冒烟结果。**之后 `firmware-latest` 被覆盖过**
> （2026-10-02 的 25.12.5-r1，含 IPTV 与 `kmod-nft-tproxy` 等改动），那份图的
> sha256 与此处的两份都不同 —— 也就是说 **本目录的 79/79 并不构成对"当前发布图"
> 的证明**。当时的 CI 冒烟是手动勾选项（默认关闭），发布步骤也没有门禁，
> 所以"发布出去的镜像从没起过机"是可能的。
>
> **2026-10 起已改成：推送到 main 一律跑冒烟，且发布步骤前置了一道
> "必须有通过的冒烟证据"的检查**（见 `.github/workflows/build.yml` 的
> 「发布门禁」步骤）。所以从那以后，`firmware-latest` 上的那份图**必然**有
> 同一次构建产出的 `qemu-smoke-results.txt` 作为证据，见该次 CI run 的
> `qemu-smoke-*` artifact。刷新本目录的步骤见上一级 `smoke-evidence/README.md`。

## 结论

```
断言共 79 项：通过 79，失败 0，超时 0
✔ QEMU 冒烟通过
boot_marker=Please press Enter to activate this console
```

（79 是**当时** `tests/qemu-smoke.sh` 的断言数；脚本后来陆续加过断言，
现在请以仓库里脚本的实际条数为准。）

## 被测对象（严格对应关系）

| 项 | 值 |
|---|---|
| 镜像 | `openwrt-25.12.5-x86-64-cnc1338np12-r1-ext4-combined-efi.img.gz` |
| 本目录（`qemu-smoke-*.txt/log`）测的 sha256 | `bb5c8518f257acdefc095a34cf67464e52d7c976cf1d340f3bb2c881070b9bd9`（构建机 Debian 13 本地出的图，**KVM** 加速，79/79） |
| `ci/` 子目录测的 sha256 | `c67ab162b541bd5827706e338ab3848836e61e960118ab0ac37be9099fa53d3e`（48,667,846 B）—— 2026-09-27 那次 CI 出的图（GitHub Actions，**无 KVM 的 TCG 软件模拟**，79/79） |
| 分区指纹 | `entry1 64MiB@512` / `entry2 4096MiB@131584` / `entry128 32KiB@34 BIOSboot`（与 `layout-reference.txt` 一致） |
| 内核 | 6.12.94（`uname -r` 实测） |
| 运行环境 | Debian 13 虚拟机（4 vCPU / 8 GB）、QEMU 10.0.13、OVMF 4M、**KVM 加速**（嵌套虚拟化） |
| 虚拟硬件 | 磁盘 virtio-blk、4 × e1000e（⇒ eth0/eth1/eth2/eth3，与真机口序一致）、2048 MB 内存 |
| 总耗时 | 约 3.5 分钟（含 4.2 GB 镜像解压；纯 TCG 软件模拟约 5–10 分钟） |

> 供对照：2026-10-02 覆盖 `firmware-latest` 的那份图是
> `65741d8dc89df46d623b421d034d9e97dad112032011cd35ab753bb2c1ad3609`
> （50,796,780 B，`built_at=2026-10-02T06:50:20Z`）—— **不在本目录的证据范围内**；
> 它的冒烟证据在该次 CI run 的 artifact 里（那次流水线尚未启用发布门禁）。

## 文件

| 文件 | 内容 |
|---|---|
| `qemu-smoke-results.txt` | 79 项断言的逐项结果（名字 + OK/FAIL）+ 系统信息（构建机 KVM 跑的那次） |
| `qemu-smoke-system-info.txt` | 系统内取证：`uname` / `openwrt_release` / `cnc-release` / `uci show network` / `uci show firewall` / `uhttpd` 配置 / 接口列表 / 地址 / `free` / apk 数量 / `ubus call system board` / `wget` 原始响应 / `logread` |
| `qemu-smoke-serial.log` | 完整串口日志（GRUB 菜单 → 内核 → procd → 服务 → 断言 → 关机），已清除 ANSI 转义 |
| `qemu-smoke-run.log` | 冒烟脚本自身的运行日志（解压/加速方式/逐项结果/汇总） |
| `ci/` | **CI 侧同一套断言的证据**（GitHub Actions 跑，无 KVM、纯 TCG），由 CI 的 `qemu-smoke-v25.12.5-r1` artifact 原样下载 |

## 两次独立跑出来的结果一致

| 跑在哪 | 加速 | 结果 | 镜像 sha256 |
|---|---|---|---|
| 构建机 Debian 13（本目录） | KVM（嵌套虚拟化） | **79/79 通过**，整轮约 3.5 分钟 | `bb5c8518…` |
| GitHub Actions ubuntu-24.04（`ci/`） | 无 KVM ⇒ TCG 软件模拟 | **79/79 通过**，QEMU 起到控制台约 71 秒 | `c67ab162…` |

两次跑的都是 2026-09-27 那批构建；同一套断言换个加速方式、换台机器结果一致，
说明"冒烟通过"不是靠某台机器的偶然状态。

## 验到了什么（摘要）

* **能启动**：OVMF 引导 → GRUB（含 failsafe 条目）→ 6.12.94 内核 → procd → 串口 root shell。
* **网络预置真的生效**：`eth0=pppoe(ipv6 auto)`、`eth1=dhcp(defaultroute 0, ipv6 0)`、
  `eth2+eth3` 桥成 `br-lan`（实测 `master br-lan`、`br-lan` 拿到 `192.168.2.1/24` 与
  ULA `fd52:…::1/60` + 链路本地地址）、`eth0/eth1` 确实不在桥里。
* **IPv6 是开着的**：`disable_ipv6=0`、`dhcp.lan.dhcpv6/ra=server`、`ra_slaac=1`、
  firewall 的 wan zone 里有 `wan6` 与 `wan_6`（各一次，无重复）。
* **五个插件真装进去了**：OpenClash（服务脚本 + `/usr/share/openclash` + LuCI 视图）、
  Lucky、vlmcsd（含 `/etc/vlmcsd.ini`）、msd_lite 的服务脚本与主程序、Bandix（含自带
  `keep.d`）；WireGuard 是内核模块 `wireguard.ko` + `wg` + `kmod/wireguard-tools/luci-proto-wireguard`
  三个包 + LuCI 相关文件都在。
* **自研在线升级页完整**：`/usr/sbin/cnc-upgrade` 可执行且 `--help` 正常、
  menu.d/acl.d/视图/`keep.d/99-cnc-plugins`/`/etc/cnc-release` 齐全。
