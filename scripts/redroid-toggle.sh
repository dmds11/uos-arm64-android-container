#!/bin/bash
# redroid 安卓11 一键开关(用户级, 无需密码) —— 放在桌面图标/应用菜单执行
# 行为: 运行中+窗口在 -> 全关; 运行中+窗口没 -> 重新投屏; 已关 -> 启动容器+等开机+弹投屏窗口
# 依赖: docker(用户组), adb, scrcpy, notify-send; 路径按需修改(LOG/数据目录/窗口标题)
# 注意: docker run 里的 -v /dev/binder:* 依赖 redroid-binder-setup.sh 先执行(开机服务或手动)
export XDG_RUNTIME_DIR=/run/user/1000
export DISPLAY=${DISPLAY:-:1}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
LOG="$HOME/android-exp/redroid.log"
NAME=redroid
mkdir -p /tmp/emptydt "$HOME/android-data"

notify(){ notify-send -t 3000 "安卓11 (redroid)" "$1" 2>/dev/null; }

# 等 adb 设备就绪(最多 25s), 就绪后返回 0
wait_adb(){
  for _ in $(seq 1 12); do
    adb connect 127.0.0.1:5555 >/dev/null 2>&1
    st=$(adb devices 2>/dev/null | awk '$1=="127.0.0.1:5555"{print $2}')
    [ "$st" = "device" ] && return 0
    sleep 2
  done
  # 兜底: 强制 adbd 走 tcp 并重启(安卓重启后 persist 属性偶发不生效)
  docker exec "$NAME" /system/bin/setprop persist.adb.tcp.port 5555 >/dev/null 2>&1
  docker exec "$NAME" /system/bin/setprop service.adb.tcp.port 5555 >/dev/null 2>&1
  APID=$(docker exec "$NAME" /system/bin/toybox ps -A 2>/dev/null | awk '$NF=="adbd"{print $2}' | head -1)
  [ -n "$APID" ] && docker exec "$NAME" /system/bin/toybox kill "$APID" >/dev/null 2>&1
  for _ in $(seq 1 10); do
    sleep 2
    adb connect 127.0.0.1:5555 >/dev/null 2>&1
    st=$(adb devices 2>/dev/null | awk '$1=="127.0.0.1:5555"{print $2}')
    [ "$st" = "device" ] && return 0
  done
  return 1
}

# 启动投屏(带一次崩溃重试: scrcpy 1.17 在 adb 未就绪时 push 失败会 double-free), 成功返回 0
launch_scrcpy(){
  wait_adb || { echo "$(date +%H:%M:%S) adb 未就绪" >>"$LOG"; return 1; }
  setsid scrcpy -s 127.0.0.1:5555 --stay-awake --window-title '安卓11 (redroid)' >>"$LOG" 2>&1 &
  sleep 5
  pgrep -f 'scrcp[y] -s' >/dev/null || {
    setsid scrcpy -s 127.0.0.1:5555 --stay-awake --window-title '安卓11 (redroid)' >>"$LOG" 2>&1 &
    sleep 4
  }
  pgrep -f 'scrcp[y] -s' >/dev/null
}

running=$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)
scr=$(pgrep -f 'scrcp[y] -s' | head -1)

if [ "$running" = "true" ]; then
  if [ -n "$scr" ]; then
    # 全关
    pkill -f 'scrcp[y] -s' 2>/dev/null
    docker stop "$NAME" >>"$LOG" 2>&1
    echo "$(date +%H:%M:%S) 已关闭" >>"$LOG"
    notify "已关闭 ✓"
  else
    # 容器在跑只是窗口没了 -> 重新投屏
    if launch_scrcpy; then
      notify "投屏窗口已重新打开"
    else
      notify "adb 未就绪, 稍后再点一次"
    fi
  fi
  exit 0
fi

# ---- 启动流程 ----
echo "$(date +%H:%M:%S) 启动..." >>"$LOG"
if ! docker inspect "$NAME" >/dev/null 2>&1; then
  docker run -itd --name "$NAME" --privileged \
    --device /dev/ashmem \
    -v /dev/binder:/dev/binder -v /dev/hwbinder:/dev/hwbinder -v /dev/vndbinder:/dev/vndbinder \
    -v /dev/binderfs:/dev/binderfs \
    -v /tmp/emptydt:/proc/device-tree \
    -v "$HOME/android-data":/data -p 5555:5555 \
    redroid/redroid:11.0.0-latest \
    androidboot.redroid_width=1080 androidboot.redroid_height=1920 androidboot.redroid_dpi=480 androidboot.redroid_fps=30 >>"$LOG" 2>&1
else
  docker start "$NAME" >>"$LOG" 2>&1
fi

# 等安卓开机完成(最多 ~2 分钟; 镜像无 shell, 用 /system/bin/getprop)
for _ in $(seq 1 60); do
  b=$(docker exec "$NAME" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  [ "$b" = "1" ] && break
  sleep 2
done

if [ "$(docker exec "$NAME" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
  if launch_scrcpy; then
    echo "$(date +%H:%M:%S) 已启动" >>"$LOG"
    notify "已启动, 投屏窗口弹出中 ✓"
  else
    echo "$(date +%H:%M:%S) adb 未就绪, 容器已跑但没投屏" >>"$LOG"
    notify "容器已启动但投屏失败, 再点一次图标试试"
  fi
else
  echo "$(date +%H:%M:%S) 启动超时" >>"$LOG"
  notify "启动超时, 看日志 $LOG"
fi
exit 0
