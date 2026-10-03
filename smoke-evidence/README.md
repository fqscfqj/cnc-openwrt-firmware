# smoke-evidence —— QEMU 冒烟证据归档

这个目录存放**某一版固件**的 QEMU 冒烟原始记录。一条铁律：

> **证据只对它自己那一份 sha256 负责。** 镜像一旦重编，即使版本号与构建号都没变，
> 旧证据也不再构成对它的证明。

## 为什么要有这条规矩

2026-09 时 CI 的 QEMU 冒烟是手动勾选项（默认关闭），而"发布到滚动 Release"
没有门禁 —— 于是 `firmware-latest` 被覆盖过好几次，其中至少有一次
（2026-10-02 的 25.12.5-r1）**没有跑过冒烟**，而仓库里的证据还写着
"现在发布的那份图通过了全部断言"。那句话说出口时就已经不成立了。

现在改成两道措施：

1. **推送到 main 的构建一律跑冒烟**（`.github/workflows/build.yml` 里
   `RUN_QEMU_SMOKE` 对 push 固定为 `1`；手动触发时默认 `true`，可以关掉，
   但关掉之后发布步骤会失败）。
2. **发布步骤前有一道「发布门禁」**：`out/qemu-smoke-results.txt` 必须存在，
   且 `checks_fail=0`、`checks_timeout=0`、`checks_pass>0`。不满足就不许
   覆盖 `firmware-latest`。

所以从那以后，**`firmware-latest` 上的那份图必然有同一次构建的冒烟证据**，
放在该次 CI run 的 `qemu-smoke-<tag>` artifact 里（保留 90 天）。

## 目录命名

`<日期>-<构建号>/`，例如 `2026-09-27-r1/`。每个目录里应有：

| 文件 | 内容 |
|---|---|
| `README.md` | 这次测的是**哪一份 sha256**、跑在什么环境、验到了什么、抓到了什么 |
| `qemu-smoke-results.txt` | 逐项断言结果（`checks_pass/fail/timeout` + 每项 OK/FAIL） |
| `qemu-smoke-system-info.txt` | 系统内取证（`uname` / uci / 接口 / 日志 等） |
| `qemu-smoke-serial.log` | 串口全量日志（GRUB → 内核 → procd → 断言 → 关机） |
| `qemu-smoke-run.log` | 冒烟脚本自身的运行日志 |
| `ci/`（可选） | 同一套断言在 GitHub Actions 上跑的副本 |

## 怎么刷新（每次动过 `files/`、包清单、`uci-defaults` 或版本号之后）

```bash
# 1) 本地出图并冒烟（会写进 out/）
RUN_QEMU_SMOKE=1 bash build.sh

# 2) 记下这次测的 sha256（★必须与 README 里写的一致★）
cut -d' ' -f1 out/*.img.gz.sha256

# 3) 归档
d=smoke-evidence/$(date +%F)-r<N>
mkdir -p "$d"
cp out/qemu-smoke-{results.txt,system-info.txt,serial.log} "$d/"
# run.log 在 CNC_QEMU_WORK 目录里（默认自动挑一个剩余空间够的目录）
cp <CNC_QEMU_WORK>/run.log "$d/qemu-smoke-run.log"

# 4) 写 README：被测 sha256 / 环境 / 断言数 / 验到什么 / 抓到什么
# 5) 若 CI 也跑了，把 CI 的 qemu-smoke-<tag> artifact 下载到 $d/ci/
```

## 和 `firmware-latest` 对不上时怎么办

先确认不是自己看错了：

```bash
# 当前发布的那份图的 sha256
curl -fsSL https://github.com/fqscfqj/cnc-openwrt-firmware/releases/download/firmware-latest/latest.json
```

* 如果和最新证据目录里的 sha256 **相同** → 证据有效。
* 如果**不同** → 要么是发布门禁上线前留下的历史镜像，要么是门禁被绕过了
  （例如手动 `gh release upload`）。两种情况都应当**重新构建并冒烟**，
  然后把新证据归档进来；不要修改旧证据来"对齐"。
