# QEMU 冒烟证据（2026-09-27 / 固件 r1）

本目录是 **OpenWrt 25.12.5 / cnc1338np12 / r1** 那份镜像的 QEMU 冒烟原始记录，
由 `tests/qemu-smoke.sh` 自动生成（脚本见仓库 `tests/qemu-smoke.sh`，说明见手册 §2.1）。

## 结论

```
断言共 79 项：通过 79，失败 0，超时 0
✔ QEMU 冒烟通过
boot_marker=Please press Enter to activate this console
```

## 被测对象

| 项 | 值 |
|---|---|
| 镜像 | `openwrt-25.12.5-x86-64-cnc1338np12-r1-ext4-combined-efi.img.gz` |
| 镜像 sha256 | `bb5c8518f257acdefc095a34cf67464e52d7c976cf1d340f3bb2c881070b9bd9` |
| 分区指纹 | `entry1 64MiB@512` / `entry2 4096MiB@131584` / `entry128 32KiB@34 BIOSboot`（与 `layout-reference.txt` 一致） |
| 内核 | 6.12.94（`uname -r` 实测） |
| 运行环境 | Debian 13 虚拟机（4 vCPU / 8 GB）、QEMU 10.0.13、OVMF 4M、**KVM 加速**（嵌套虚拟化） |
| 虚拟硬件 | 磁盘 virtio-blk、4 × e1000e（⇒ eth0/eth1/eth2/eth3，与真机口序一致）、2048 MB 内存 |
| 总耗时 | 约 3.5 分钟（含 4.2 GB 镜像解压；纯 TCG 软件模拟约 5–10 分钟） |

## 文件

| 文件 | 内容 |
|---|---|
| `qemu-smoke-results.txt` | 79 项断言的逐项结果（名字 + OK/FAIL）+ 系统信息 |
| `qemu-smoke-system-info.txt` | 系统内取证：`uname` / `openwrt_release` / `cnc-release` / `uci show network` / `uci show firewall` / `uhttpd` 配置 / 接口列表 / 地址 / `free` / apk 数量 / `ubus call system board` / `wget` 原始响应 / `logread` |
| `qemu-smoke-serial.log` | 完整串口日志（GRUB 菜单 → 内核 → procd → 服务 → 断言 → 关机），已清除 ANSI 转义 |
| `qemu-smoke-run.log` | 冒烟脚本自身的运行日志（解压/加速方式/逐项结果/汇总） |

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
* **内核模块齐全**：`igc.ko`、`tun.ko`、`zram.ko`、`e1000e.ko`；zram swap 1.2 GB 已挂上。
* **包管理器状态正确**：`dnsmasq-full` 在、`dnsmasq` 已不在（替换真的生效），共 281 个包。
* **Web 栈可用**：uhttpd 在跑，`http://127.0.0.1/` 返回 LuCI 的 HTML，
  `/luci-static/resources/luci.js` 真能取到内容，`/cgi-bin/luci/` 无会话时按预期返回 403。

## 这一轮冒烟抓到并修掉的问题

1. **（真 bug）`wan_6` 从来没进 firewall 的 wan zone**：首启脚本原来用
   `uci -q get firewall.wan` 找 wan zone，而官方默认 firewall 里 wan zone 是**匿名段**
   （`config zone` + `option name 'wan'`）⇒ 永远取不到，结果 `wan6`/`wan_6` 都没登记。
   离线校验只看文件内容，看不出来；进系统 `uci show firewall` 一看就露了。已改成按
   `option name` 扫 `firewall.@zone[i]`。
2. **（真 bug）列表重复**：`uci get` 对 list 选项是**空格分隔的一行**，原脚本用
   `grep -qx` 判断"是否已存在"永远匹配不上 ⇒ 每跑一次就 `add_list` 一次（实测
   `network='wan' 'wan6' 'wan6' 'wan_6'`）。已改成 `grep -qw`，并加了"wan6/wan_6/阿里 DNS
   各只出现一次"的断言防回归。
3. **（断言自身写错，非镜像问题）**：busybox `wget` 没有 `-S`；`uci show` 只把 list 的
   第一个值挂在 `=` 后面（`ports='eth2' 'eth3'`）。这两条都按实测重新写准了断言，
   并把 `wget`/`uci` 的真实输出存进 `qemu-smoke-system-info.txt` 便于以后对照。

## 已知的无害现象 / 验不了的部分

* 串口日志开头 GRUB 会报 `error: can't find command 'search'`：GRUB 镜像里没带 `search`
  模块。因为 `$root` 默认就是刚引导的那个 ESP，而 `vmlinuz` 就在 ESP 的 `/boot/` 下，
  所以不影响启动（本次一路启动成功，真机亦然）。属于外观问题。
* `odhcpd: No default route present, setting ra_lifetime to 0!`：QEMU 里没有运营商 IPv6
  上游，属预期。
* QEMU 里**没有 Intel I226-V、没有光猫/PPPoE 环境**，所以下面三项仍然只能上机核对
  （见手册 §5）：igc 真机驱动是否带起 4 个口、PPPoE 拨号、IPv6 从运营商拿地址/前缀（PD）。

## 怎么复现

```bash
# 构建机（Debian/Ubuntu）
sudo apt install -y qemu-system-x86 ovmf
cd fn
CNC_QEMU_OUT=$PWD/out bash tests/qemu-smoke.sh out/openwrt-*.img.gz
# 或者整条流水线：
RUN_QEMU_SMOKE=1 bash build.sh
```
