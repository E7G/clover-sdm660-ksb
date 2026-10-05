# Clover KS-SB Hybrid 4.19 — 设计文档

- **日期**：2026-10-06
- **设备**：Xiaomi Mi Pad 4（clover / SDA660，soc_id 324），adb 序列号 2253acd9
- **仓库**：https://github.com/E7G/clover-sdm660-ksb
- **上游基线**：pix106/android_kernel_xiaomi_sdm660_southwest-ng @ `cf1462f2a`（SouthWest-NG 0.18.0）
- **首个目标版本**：v0.1（= Phase 0 + Phase 1）

---

## 1. 目标与非目标

### 1.1 体验目标

融合两种思路，而不是简单叠加参数：

- **底盘（Kirisakura 思路）**：稳定、低后台功耗、不激进超频、不牺牲硬件可靠性。
- **前台（StormBreaker 思路）**：WALT 调度、KGSL、短时 boost、降低 frame jank、提高触摸响应。

最终体验链条：

```
平时桌面/浏览/视频基本不热
  → 点下去马上响应
  → 游戏瞬时性能迅速拉起
  → 持续负载不过热
  → 锁屏迅速进入 deep sleep
```

核心思想是 **race-to-idle**：尽快把活干完然后回 idle，而不是锁高频。

### 1.2 v0.1 验收标准

| 维度 | 指标 | 目标 |
|---|---|---|
| 待机 | 8h 锁屏 Wi-Fi 连接下 deep sleep 占比 | ≥95%，理想 97~99% |
| 待机 | 8h 掉电 | ≤2~3%（同一块电池 A/B） |
| 响应 | app launch P50/P95 | 相对基线不劣化（Phase 1 不改响应路径，只要求不掉） |
| 响应 | frame time P95/P99、>16.7ms / >33.3ms 掉帧数 | 不劣化 |
| 持续 | 20~30min 负载下频率/温度/FPS 曲线 | 不出现"前 3 分钟快、10 分钟后腰斩" |
| 功能 | Wi-Fi/BT/音频/摄像头/充电/USB/触摸/传感器/KSU/DroidSpaces | 零 regression |

### 1.3 明确不做（第一版）

- 不做 CPU/GPU 超频、不做降压。
- 不锁最低频、不禁用 deep idle、不做永久 input boost、不用 performance governor、不做永久大核在线 boost。
- 不删温控、不做 thermal bypass / fake temp / disable thermal zone。
- 不批量移植 5.4/5.10 subsystem，不为"版本新"而 backport。
- 不用 BORE/Cachy/EEVDF/各种 CFS 魔改；第一版不上 schedhorizon。

---

## 2. 现状（全部为实测，非假设）

### 2.1 设备与内核

| 项 | 值 |
|---|---|
| 型号 | Xiaomi MI PAD 4，codename `clover`，SoC `SDA660`（soc_id 324） |
| 系统 | Android 17 / SDK 37 / build `CP2A.260605.016` |
| A/B | 否（`ro.boot.slot_suffix` 为空，`ro.build.ab_update=false`） |
| bootloader | 已解锁（`androidboot.verifiedbootstate=orange`） |
| 内核 | `4.19.325-cip135-st19-SouthWest-NG-0.17.3`，clang 22.1.7 + LLD 22.1.7，单体式（无模块） |
| root | ReSukiSU（KernelSU），`adb shell` 直接 uid=0（`u:r:ksu:s0`） |
| 已装模块 | Automatic_brick_rescue、RescueBrick、anland-awl、auditpatch、clover_pandora_compat、clover_wifi_powersave、droidspaces、haxizhi、hybrid_mount、mipad4_sf_response、mipad4_touch_tuning、playintegrityfix、qcom_dtb_90hz、susfs4ksu、tricky_store、xiaocaiye、zygisk_lsposed、zygisksu |

**关键结论**：设备实际在跑 0.17.3，而仓库基线是 0.18.0。0.18.0 与设备现固件不是同一个镜像，所以 **"零改动构建"这一步本身就是一次 A/B**，必须先证明它不输给现固件。

### 2.2 分区与模块

- `boot` = `/dev/block/mmcblk0p12`，64 MiB（67108864 B）。
- **没有 `dtbo` 分区**。
- 没有 `/proc/modules`、`/lib/modules`、`/vendor/lib/modules`、`/system/lib/modules` → **内核是单体式**，无外部模块需要同步构建。

### 2.3 boot 镜像实测布局

`ANDROID!` boot header **v2**，`header_size=1660`，`page_size=4096`：

| 区域 | 偏移 | 内容 | 备注 |
|---|---|---|---|
| header | `0x0000000` | boot header v2 | 1 页 |
| kernel | `0x0001000` | gzip（`1f8b08`） | 18537940 B → 占 18538496 B |
| ramdisk | `0x0011AF000` | **lz4 legacy**（`02214c18`） | 3821660 B → 占 3825664 B |
| dtb[0] | `0x001555000` | FDT，version 17 | 319604 B（`dtb_size` 字段值） |
| 其它 | `0x0015A4000` | 高熵数据 → dtb[1] @ `0x15BE000` | 头部未描述 |
| vbmeta | `0x00296B000` | AVB vbmeta | 头部未描述 |
| AVB footer | 分区末 | `AVBf` 魔数 | 固定位置 |

- `cmdline`：`androidboot.hardware=qcom user_debug=31 msm_rtb.filter=0x37 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.configfs=true androidboot.usbcontroller=a800000.dwc3 loop.max_part=7 printk.devkmsg=on usbcore.autosuspend=7 kpti=off androidboot.boot_devices=soc/c0c4000.sdhci`
- header 里的 `id` 字段**不是**标准 AOSP SHA1（三种候选算法都不匹配）→ 处理方式：**原样保留，不重算**。

### 2.4 关键 KCONFIG（设备实际值 vs 0.18.0 defconfig）

| 配置 | 设备（0.17.3） | 0.18.0 defconfig | 说明 |
|---|---|---|---|
| `CONFIG_SCHED_WALT` | y | y | WALT 已在 |
| `CONFIG_UCLAMP_TASK` | y | y | 无 schedtune，靠 uclamp |
| `CONFIG_LRU_GEN` | y（enabled 0x0001） | y | MGLRU 已在 |
| `CONFIG_CPU_FREQ_GOV_SCHEDUTIL` | y | y | |
| `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE` | **y** | **y** | 配置默认 performance，但运行时被覆盖为 schedutil |
| `CONFIG_PSI` | **未启用** | **未启用** | `/proc/pressure` 不存在，LMKD 只能走 legacy |
| `CONFIG_WQ_POWER_EFFICIENT_DEFAULT` | 未启用 | **y** | 0.18.0 已启用 |
| `CONFIG_ZRAM_DEF_COMP` | `"lzo-rle"`（运行时被设为 zstd） | — | 用户要求 lz4 |
| `CONFIG_HZ` | 300 | — | |
| `CONFIG_MQ_IOSCHED_DEADLINE` / `KYBER` | y / y | — | 无 BFQ |
| `CONFIG_THERMAL` / `step_wise` | y | — | |
| `CONFIG_MODULES` | 实际无模块 | — | |
| `CONFIG_MACH_XIAOMI_CLOVER` | y | 需合并 `clover.config` | |

### 2.5 运行时基线

| 项 | 实测 |
|---|---|
| governor | policy0（Silver）schedutil 633600–1843200；policy4（Gold）schedutil 1113600–2208000 |
| cpuidle | 仅 `state0/1/2` = C0/C1/C2，均未 disable |
| `lpm_levels.sleep_disabled` | cmdline 里有 `=1`，但设备上**不存在** `/sys/module/lpm_levels/parameters/sleep_disabled` |
| zram0 | disksize 3221225472（3 GB），`comp_algorithm` 可选 `lzo lzo-rle lz4 [zstd]`，**当前 zstd** |
| MGLRU | `enabled=0x0001`，`min_ttl_ms=0` |
| PSI | **不可用**（`/proc/pressure` 不存在） |
| workqueue | `/sys/devices/virtual/workqueue/cpumask` = `0f`，`writeback/cpumask` = `0f`（已只在 LITTLE 0-3） |
| devfreq | kgsl-3d0 = `msm-adreno-tz`；mmc0 = `simple_ondemand`；`cpu*-cpu-ddr-lat` = `mem_latency`；`cpu*-ddr-latfloor` = `compute`；`cpu-cpu-ddr-bw` = `bw_hwmon`；`gpubw` = `bw_vbif` |
| KGSL | `idle_timer=67` |
| thermal | `thermal_zone0` policy = `step_wise` |
| schedtune | `/dev/stune` 不存在 |
| debugfs | 未挂载 → `sched_features` / `wakeup_sources` 需要 `mount -t debugfs none /sys/kernel/debug` |

### 2.6 0.18.0 需要的构建修复（已在 main 提交）

0.18.0 源码与当前树内 API 不一致，**必须**打补丁才能编译：

| 文件 | 问题 |
|---|---|
| `drivers/gpu/drm/drm_atomic.c:2724` | `DEVFREQ_MSM_CPUBW` 不存在 → `DEVFREQ_MSM_CPU_DDR_BW` |
| `drivers/gpu/drm/drm_irq.c:104` | `IRQF_PERF_CRITICAL` 不存在 → 去掉 |
| `drivers/gpu/drm/msm/msm_drv.c:505/640/1237` | `dma_set_max_seg_size` 类型、`irq_set_perf_affinity` 少一个 `perf_flag` 参数、`strnstr` 少长度参数 |
| `drivers/gpu/drm/vkms/vkms_drv.h:65`、`vkms_gem.c:40` | `int` → `vm_fault_t` |
| `fs/notify/fanotify/fanotify.c` | 缺 `struct mem_cgroup *old_memcg;` 声明 |
| `include/linux/ramfs.h` | 缺 `struct fs_context;` 前向声明 |

### 2.7 设备现固件的真实增量（相对 pristine 0.17.3）

| 类别 | 文件/配置 |
|---|---|
| 工具链适配 | 上表 8 个文件 |
| ReSukiSU 手动 hook | `fs/exec.c`、`fs/open.c`、`fs/stat.c`、`kernel/reboot.c`、`drivers/Makefile`、`drivers/Kconfig`、`drivers/kernelsu`（软链到 ReSukiSU `kernel/`） |
| **DroidSpaces 支持** | `clover.config` + `sdm660_defconfig` 追加：`SYSVIPC`、`NAMESPACES`、`UTS_NS`、`IPC_NS`、`PID_NS`、`USER_NS`、`NET_NS`、`DMA_SHARED_BUFFER`、`DRM`、`DRM_VGEM`、`DRM_VKMS`、`SYNC_FILE`、`UDMABUF`、`DMABUF_HEAPS`、`DMABUF_HEAPS_SYSTEM` |
| KSU 配置 | defconfig 中的 KSU 配置块 |

**DroidSpaces 那一块必须保留**——用户明确要求不能因省电改动破坏 DroidSpaces。

---

## 3. 方案选择

### 3.1 候选

- **方案 A（采纳）**：以 `southwest-ng` 0.18.0 为基座，复制设备树里的 ReSukiSU 集成方式，阶段分支链式推进。
- **方案 B（否决）**：复刻设备当前的 0.17.3 + KSU 树当基线。基线等于现固件、归因最干净，但那棵树不是 git 仓库（只有 `drivers/kernelsu` 是子仓库），手工重建成本更高，且放弃 0.18.0 的上游修复。
- **方案 C（明确否决）**：用 `kernel-southwest-4.19` 那棵带 `clover_defconfig` 的树。它单 commit、无 remote、索引区有大量来历不明的未提交改动（`kernel/sched/walt.c`、`kernel/sched/sched.h`、`net/netfilter/*`、多驱动 Makefile、新增 `msm_vidc_trace.c`），把未知行为写进"稳定基线"不可接受。

### 3.2 采纳理由

方案 A 是唯一能同时满足"基线可信"与"后续每步可归因"的选项，并保留用户指定的 `southwest-ng` 与 KSU。

---

## 4. 架构：屏幕状态机

整个设计围绕一个二态机，而不是一组散落的参数：

| | Screen ON | Screen OFF |
|---|---|---|
| 定位 | StormBreaker | Kirisakura |
| CPU governor | schedutil（WALT） | schedutil |
| input boost | **短时 80~150ms**（不是 500/1000ms，不是永久） | **完全关闭** |
| GPU boost | 短时 devfreq boost | 关闭，GPU 尽早 idle |
| top-app 优先 | 开启 | 关闭激进 boost |
| workqueue | latency-critical 不受 power-efficient 影响 | 全部偏向 LITTLE |
| CPU idle | 正常 | 激进 idle |
| Wi-Fi | 正常 | power save |

v0.1 只建立 **Screen OFF 一半的地基**（Phase 1 省电底座），屏幕状态机在后续 Phase 2/4 落地。

---

## 5. 仓库与分支链

```
main                        pristine 0.18.0 导入 + clang-22 构建修复 + 项目脚手架
 └── ks-sb/00-baseline      main + ReSukiSU + DroidSpaces 配置 + 版本身份     → v0.1.0
      └── ks-sb/01-power   + Phase 1 省电底座                              → v0.1.1
           └── 02-walt → 03-response → 04-kgsl → 05-memory → 06-io
                → 07-thermal → 08-profile → ks-sb/release
```

规则：

1. 每个阶段**只改一个 subsystem**，独立分支、独立 commit、可单独回滚。
2. 每级都必须能独立编译、开机、通过回归检查。
3. 每个 Release 附：`boot.img` + `sha256` + 测量 JSON + CHANGELOG。
4. 出现待机变差 / 随机重启 / Wi-Fi 唤醒异常 / 摄像头异常 / 音频 crackling / 触摸延迟 / GPU hang，按分支链二分定位。

---

## 6. 构建流水线

- 环境：WSL2 `kali-linux`，`clang-22`（Debian clang 22.1.7）、`ld.lld-22`、`llvm-*-22`、`aarch64-linux-gnu` binutils 16.1.0、8 核。
- 配置：`vendor/xiaomi/sdm660_defconfig` → `scripts/kconfig/merge_config.sh` 合并 `arch/arm64/configs/vendor/xiaomi/clover.config` → `olddefconfig`。
- 产物：**只取 `arch/arm64/boot/Image.gz`**。ramdisk 与 dtb 全部复用原厂镜像里的字节，不重新编译 dtb。
- 构建目录 **out-of-tree**（`/home/kali/android/clover-ksb-out`），仓库保持干净。
- `CONFIG_LOCALVERSION` 改为 `-Clover-KS-SB-v0.1.0-baseline`；刷机后 `cat /proc/version` 必须含该串，**这是刷机成功的判定条件**。

---

## 7. 打包与刷机

### 7.1 策略：固定偏移替换内核 + 零填充

由于 `0x11AF000` 之后的内容（ramdisk、两个 dtb、vbmeta、AVB footer）头部并未完整描述，**平移它们存在未知风险**。因此：

1. 新 `Image.gz` 必须 `≤ 18538496 B`（旧内核占用区大小）。
2. 新内核写入 `0x1000` 起，**不足部分零填充**到 `0x11AF000`。
3. `0x11AF000` 之后的**所有字节保持原位、完全不变**。
4. 只修改 header 的 `kernel_size` 字段。`id` 字段原样保留。

这样产出的镜像与原始镜像**只在 kernel 区域内不同**，把未知区域的风险降到零。

### 7.2 `tools/bootimg.py`

- `unpack <img> <dir>`：解析 v2 header，导出 kernel/ramdisk/dtb 与元数据。
- `repack <orig> <new-kernel.gz> <out>`：按 7.1 生成新镜像，越界时**报错而不是静默平移**。
- `verify <orig>`：用**原始内核** repack，输出必须与原镜像**字节完全一致**——这是打包器正确性的证明。

### 7.3 刷机

```
adb shell dd if=/dev/block/by-name/boot of=/data/local/tmp/boot-backup.img   # 已做
fastboot flash boot <new-boot.img>
fastboot reboot
adb shell cat /proc/version   # 必须含 -Clover-KS-SB-v0.1.0-baseline
```

不触碰 vbmeta 及其它分区。三层回滚：boot 全量备份 → 上一版 Release `boot.img` → 分支 checkout 重编。

---

## 8. 测量工具链

`tools/measure/short.sh`（DSH 跑，每次构建后）：

- app 启动时延 P50/P95（`am start -W`）
- frame 统计与掉帧（`dumpsys gfxinfo`、`dumpsys SurfaceFlinger --latency`）
- `cpufreq` `time_in_state`（两 cluster）
- thermal zone 温度、KGSL 频率/负载
- `wakeup_sources` 前后 diff、`suspend_stats`
- 前置：`mount -t debugfs none /sys/kernel/debug`

`tools/measure/sleep.sh`（用户跑，8h）：记录 `suspend_stats`、`wakeup_sources`、电量差、Wi-Fi wakelock。

统一输出 JSON 到 `docs/measurements/<date>-<build>.json`，使每次 A/B 可直接比对。

---

## 9. Phase 1 补丁清单（先测后改）

| # | 项 | 动作 |
|---|---|---|
| 1 | `lpm_levels.sleep_disabled=1` | 查清这条 cmdline 在本树是否真的禁掉 LPM；设备上无对应 sysfs 节点 |
| 2 | suspend 审计 | `suspend_stats` + `wakeup_sources` 找出真正拖住 suspend 的源，逐个处理 |
| 3 | power-efficient workqueue | 0.18.0 已启用 `WQ_POWER_EFFICIENT_DEFAULT`；逐点确认触摸/KGSL/display/audio/binder **没有**被误置为 power-efficient |
| 4 | IRQ affinity / MPM | 核对 wakeup IRQ 与 MPM 配置，保证唤醒路径正确 |
| 5 | PSI + MEMCG | 补上（为 Phase 4 的 LMKD 铺路；当前完全不可用） |
| 6 | debug 开销 | 去掉无用 debug，但**保留 SCHED_DEBUG**（后续 WALT 调参要用） |
| 7 | bugfix backport | 仅 F2FS/EXT4/MMC/binder/RCU 的 bugfix，不批量移植 subsystem |
| 8 | 待机专项 | Wi-Fi 息屏省电、alarmtimer、IPA/rmnet wakelock |
| 9 | 默认 governor | 评估把 `CPU_FREQ_DEFAULT_GOV_PERFORMANCE` 改为 schedutil，避免无 ROM 脚本时锁高频 |

每项独立 commit、可单独回滚。**每项改动前后都要有测量数据，没有数据的改动不合并。**

---

## 10. 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| 新内核 > 18538496 B | 固定偏移策略失效 | `bootimg.py` 报错；退路是允许平移并实测验证 bootloader 接受，或重新评估压缩方式 |
| AVB 校验 | 无法开机 | bootloader 已解锁（orange），且现固件本身就是自制内核，实测可行；最坏情况刷回备份 |
| 0.18.0 与现固件行为差异 | 待机/功能 regression | `v0.1.0-baseline` 本身就是这次 A/B；不通过就不进入 Phase 1 |
| 编译错误超出已知 8 项 | 阻塞 | 已全树扫过 `irq_set_perf_affinity`/`strnstr`/`dma_set_max_seg_size`/`vm_fault_t`/`DEVFREQ_MSM_CPUBW`/`IRQF_PERF_CRITICAL`，无额外命中；剩余错误用构建日志逐个修 |

变砖风险极低：只动 boot 分区，且已有全量备份。

---

## 11. 交付物

1. GitHub 仓库 `E7G/clover-sdm660-ksb`（内核在仓库根，分支链 + 文档 + 工具）。
2. Release `v0.1.0-baseline`、`v0.1.1-power`：`boot.img` + `sha256` + 测量 JSON + CHANGELOG。
3. 可复用工具：`tools/bootimg.py`、`tools/build.sh`、`tools/measure/*.sh`。
4. 测量报告：`docs/measurements/`。
