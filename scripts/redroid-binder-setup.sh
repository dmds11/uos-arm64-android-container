#!/bin/bash
# redroid binder 设备开机准备(需 root): 挂 binderfs + 建传统设备节点 + 放权
# 装到 /usr/local/sbin/redroid-binder-setup.sh, 由 redroid-binder.service 开机调用
# 背景: 统信 UOS ARM64 内核 binder/binderfs 内建但不挂载, 且安卓服务需要传统 /dev/binder 节点 + 0666 权限
set -u
mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null
for d in binder hwbinder vndbinder; do
  if [ ! -e /dev/$d ]; then
    touch /dev/$d
    mount --bind /dev/binderfs/$d /dev/$d
  fi
done
exit 0
