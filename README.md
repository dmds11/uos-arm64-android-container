# UOS ARM64 上跑安卓容器（redroid + scrcpy）完整实战记录

> 一台 **统信 UOS 20 ARM64（华为麒麟 9006C，kernel 5.4.96，glibc 2.28）** 办公笔记本上，用 Docker 跑 Android 11 容器并投屏使用的完整记录：可行方案、全部深坑、排障方法，以及 **GPU 硬件加速四条路的穷尽测试结论**。

## TL;DR

- ✅ **技术完全可行**：ARM64 宿主原生跑 ARM 安卓，日常轻应用（浏览器、IM、工具类）流畅可用
- 🖥️ 最终形态：`redroid/redroid:11.0.0-latest` + scrcpy 投屏，**1080x1920@480dpi / 30fps**，软渲染（宿主 Mali GPU 无法直通进容器，见下文）
- 🎛️ 一键开关：桌面图标点击启动/关闭（`scripts/` 下脚本）
- ❌ **GPU 容器内硬件加速：四条路全部实测判死**——官方不支持 Mali、瑞芯微镜像卡内核 binder 协议、panfrost 需换内核、麒麟 EMUI blob 缺胶水

---

## 环境

| 项 | 值 |
|---|---|
| 系统 | 统信 UOS 20（eagle，Debian 10 base，dpkg 1.19.7） |
| SoC | 华为麒麟 9006C（8×A77 级，15G 内存） |
| 内核 | 5.4.96-arm64-desktop（**binder/binderfs/ashmem 内建**，KVM 可用） |
| GPU | Mali（内核 mali_kbase_r23p0 + hisi-drm 驱动，**桌面 kwin 在用 GPU**，GLX 路径 llvmpipe） |
| 显示 | DDE Wayland（kwin_wayland + Xwayland :1） |
| Docker | 26.x（daemon 需配国内镜像加速） |
| 安卓 | redroid/redroid:**11.0.0-latest**（选 11 因与 kernel 5.4 同期，Pixel 5 同款组合，binder 特性最匹配） |

---

## 最终可用方案

### 1. binder 设备开机准备（systemd 服务，root）

内核 binder 是**内建**的，但统信默认不挂 binderfs、也没有传统 `/dev/binder` 节点。创建 `/usr/local/sbin/redroid-binder-setup.sh`（见 `scripts/`）：

```bash
mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder
for d in binder hwbinder vndbinder; do
  [ -e /dev/$d ] || { touch /dev/$d; mount --bind /dev/binderfs/$d /dev/$d; }
done
```

配 `/etc/systemd/system/redroid-binder.service`：`Type=oneshot` + `WantedBy=multi-user.target`，`systemctl enable --now`。

### 2. 启动容器（关键参数全在这）

```bash
docker run -itd --name redroid --privileged \
  --device /dev/ashmem \
  -v /dev/binder:/dev/binder -v /dev/hwbinder:/dev/hwbinder -v /dev/vndbinder:/dev/vndbinder \
  -v /dev/binderfs:/dev/binderfs \
  -v /tmp/emptydt:/proc/device-tree \
  -v $HOME/android-data:/data -p 5555:5555 \
  redroid/redroid:11.0.0-latest \
  androidboot.redroid_width=1080 androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480 androidboot.redroid_fps=30
```

启动后：`adb connect 127.0.0.1:5555`，`scrcpy -s 127.0.0.1:5555` 投屏。

### 3. 一键开关脚本

`scripts/redroid-toggle.sh`：点击 = 启动（等开机 + 弹投屏）；再点 = 全关；容器在跑但窗口关了 = 只重开窗口。配 `.desktop` 放桌面/应用菜单即可。依赖：adb、scrcpy、notify-send。

---

## 深坑记录（每个都是血泪）

1. **华为麒麟 DT 泄漏 → init 自杀（exit 129）**
   宿主 `/proc/device-tree/firmware/android/` 里有华为安卓分区表。redroid 的 AOSP init 会读它生成 fstab，然后傻等不存在的 `super/vbmeta/cust...` 分区 10 秒 → `InitFatalReboot` → 容器退出 129。
   **解法**：`-v /tmp/emptydt:/proc/device-tree` 用空目录盖住。凡是在华为/麒麟板子跑安卓容器都可能中招。诊断看宿主 `dmesg`（容器与宿主共享 kmsg）：`init: Wait for partitions returned after 10005ms`。

2. **binder 必须 bind 挂载，不能 `--device`**
   docker `--device` 是在容器里 mknod **复制**节点，而 binderfs 只认真实 inode → 所有服务报 `Binder driver '/dev/binder' could not be opened`。必须 `-v /dev/binder:/dev/binder` 整文件 bind。ashmem 是普通 misc 设备，`--device` 即可。

3. **binder 节点权限 0600 → Permission denied**
   binderfs 节点默认 `crw-------`，system(uid 1000) 等服务打不开 → 报 `Opening '/dev/binder' failed: Permission denied`。需 `chmod 666`（binderfs 内存态，重启重置，所以放进开机服务）。

4. **redroid init 只认传统 /dev/binder**
   `strings /system/bin/init | grep binder` 能看到它要 `ashmem`/传统设备，binderfs 新式路径它不认——所以要造 `/dev/binder` bind。

5. **scrcpy 1.17 时序崩溃（double free）**
   adb 未就绪时 push server 失败 → `free(): double free detected`。启动脚本里先 `adb connect` 并等 `adb devices` 显示 `device` 再拉起 scrcpy。

6. **分辨率只能靠容器参数**
   运行时 `wm size` **不能超过物理分辨率**（720x1280 物理屏设 1920 会被压到 1440x1080）。真 1080p 必须重建容器带 `androidboot.redroid_width/height/dpi`。

7. **无 GPU 默认 15fps**
   `androidboot.redroid_fps` 默认 15（无 GPU 时），VSYNC 66.7ms 明显不跟手；设 30 + 动画缩放 0.5（`settings put global window_animation_scale 0.5` 等三个）体感翻倍。

8. **容器 exit 129 诊断**
   安卓 init `reboot()` 被 docker seccomp 拦截后 init 自杀。诊断顺序：宿主 `sudo dmesg` → `docker exec <c> /system/bin/logcat -b crash -d`（镜像无 shell，用 toybox/全路径二进制）。

9. **pkill 自伤**
   脚本里 `pkill -f 'scrcpy -s'` 会匹配到命令行含同样字面量的外层 shell；用 `scrcp[y]` 写法防自匹配，验证命令也别带裸字样。

10. **国内拉镜像**
    docker.io 被墙、daocloud 等公共加速器拒绝第三方仓库。用个人 1ms 专属域名（`<hash>.d.1ms.run`）等私有加速通道。标签带 `-latest` 后缀（`11.0.0-latest` 不是 `11.0.0`）。

---

## GPU 硬件加速：四条路穷尽测试记录（2026-09）

**背景**：宿主 Mali GPU 是活的（`mali_kbase_r23p0` + `gpu_mgm_r23p0` 内核模块在跑，`/dev/mali0` 被 kwin_wayland open+mmap，hisi-drm 驱动 card0/renderD128）。但**容器内** SurfaceFlinger 实测：`GLES: Google SwiftShader 4.1.0.7`（纯 CPU）。

### 路 1：redroid 官方 gpu_mode —— ❌ 官方不支持 Mali

redroid 官方 `androidboot.redroid_gpu_mode=host` 只支持 **intel / amd / virtio-gpu**。作者在 [Raspberry Pi issue #67](https://github.com/remote-android/redroid-doc/issues/67) 原话：
> redroid only add intel / amd / virtio gpu support currently

### 路 2：redroid-rockchip（RK3588 Mali 方案）—— ❌ 实测三层墙

[redroid-rockchip](https://github.com/redroid-rockchip) 的 `iceblacktea/redroid-arm64` 镜像专为 ARM Mali 板做 GPU 加速，运行法：`-v /dev/mali0:/dev/mali0` + `androidboot.redroid_gpu_mode=mali`。实测失败：
1. **binder 协议墙**：其镜像仅 Android 12，Android 12 需要 binder wire protocol v1（kernel ≥5.8），5.4 内核只有 v0 → 实测 keystore2 无限崩溃：`Cannot accept binder with older binder wire protocol version 0`——**与 GPU 无关，先死在这**
2. **DDK 墙**：其 blob 是 r4x 代（支持 G31~G610 全家桶，内含 `DDK compatibility check`），宿主华为 kbase 是 2019 年 r23p0，接口必然不匹配
3. **gralloc 墙**：瑞芯微 gralloc v4/dma-heap 与华为 kbase 缓冲区体系不同

### 路 3：开源 panfrost —— ⚠️ 理论可行但代价是换内核

Mesa panfrost **明确支持 Mali-G76（Bifrost v7，GLES 3.1）**。但：
- 内核 panfrost 驱动要 ≥5.6 代（5.4 只支持 Midgard），且 GPU 已被私有 kbase 独占，不能同开
- 换内核 + 桌面图形栈整体换到 mesa/panfrost——办公笔记本不可接受的改动

### 路 4：麒麟 990 EMUI Android blob —— ⚠️ 存在但缺胶水

Mate 30/P40 固件 dump 里有 r23p0 匹配的安卓版 `libGLES_mali.so`，但即便拿到：
- 缺配套 gralloc + hwcomposer（华为版是给真机屏幕的，容器无显示设备）
- redroid-rockchip 为 RK 做的那套 AOSP 定制构建，**麒麟方向无人做过**，工程量以天计、无成功先例

### 结论

> **宿主要 Mali 桌面驱动（kbase r23p0）+ 安卓容器要 GPU → 无解**。华为内核驱动封闭 + 安卓侧闭源 blob 双重锁死。软渲染 + 30fps + 动画半速是这台机器安卓容器的最终形态。

---

## 性能与资源

- 容器内存占用 ~1GB（共享宿主，无上限）；数据卷 1.1G；系统镜像 1.67G
- 8 核全部可见、docker 无 CPU 限制（软渲染本身多线程分块）
- 瓶颈 = 每帧 CPU 软渲染成本，不是核数
- 性能优化三板斧：`redroid_fps=30`、动画缩放 0.5/0、必要时降 720p（像素少 2.25 倍）

## 配套工具链（UOS 无源，buster arm64 手动装）

- **adb 8.1.0**：Debian buster pool `main/a/android-platform-system-core/`（**不在** android-platform-tools 目录！），依赖链 `android-libadb/android-libbase/android-libboringssl/android-libcrypto-utils` 等 + `libssl1.0.2`
- **scrcpy 1.17 + scrcpy-server + libsdl2-2.0-0**（2.0.9，别抓 bullseye 版——glibc 2.31 装不上；bullseye deb 可重打包放宽依赖）
- Google platform-tools zip 是 **x86_64**，ARM 别下
- 完整命令参考 `docs/` 或各脚本注释

## 目录

```
scripts/
  redroid-binder-setup.sh    # root: 开机准备 binder 设备(挂 binderfs+建节点+chmod 666)
  redroid-binder.service     # systemd 单元(装到 /etc/systemd/system/)
  redroid-toggle.sh          # 用户级一键开关(启动/关闭/重投屏) —— 路径按需改
  android11-redroid.desktop  # 桌面/菜单快捷方式模板
```

## 免责声明

- 文中宿主机为办公设备，所有操作以容器隔离优先，未动宿主内核/图形栈
- 1ms 私有镜像域名为个人账号专属，请替换为你自己的加速通道
- 仅供技术参考，请在理解原理后自行判断风险

---

*记录于 2026-09 · 一台华为麒麟 9006C 的统信 UOS 笔记本*
