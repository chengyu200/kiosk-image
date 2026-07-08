# Kiosk 镜像制作指南

## 架构概述

本指南教你制作一个类似 Volumio-OS 的 kiosk 镜像：squashfs 只读根 + overlay 可写层 + 开机自动打开浏览器。

### 磁盘布局（3 分区 GPT）

```
┌────────────┬─────────────────────────┬──────────────┐
│ p1 boot    │ p2 imgpart              │ p3 datapart  │
│ vfat 256MB │ ext4 2GB                │ ext4 剩余     │
│            │                         │              │
│ vmlinuz    │ system.sqsh (squashfs)  │ (overlay     │
│ initrd.img │                         │  可写层)      │
│ syslinux   │                         │              │
│ grub efi   │                         │              │
└────────────┴─────────────────────────┴──────────────┘
```

### 启动流程

```
UEFI/BIOS → bootloader(syslinux/grub) → 加载 vmlinuz + initrd.img
  → initramfs 的 /init 脚本:
    1. 挂载 p2(ext4) → /mnt/imgpart
    2. losetup + mount system.sqsh → /mnt/static (只读)
    3. 挂载 p3(ext4) → /mnt/data (可写)
    4. mount overlay(lower=static, upper=data/dyn, work=data/work) → /mnt/union
    5. exec run-init /mnt/union /sbin/init
  → systemd 启动
    1. autologin → 用户 kiosk 登录
    2. startx → openbox → chromium --kiosk URL
```

## 前提条件

### 构建环境

- **Debian 12 (bookworm) x86_64** 原生系统（或 VM）
- root 权限
- ≥ 10GB 磁盘空间
- 网络：能访问 deb.debian.org

### 安装构建工具

```bash
sudo apt-get update 
sudo apt-get install -y debootstrap squashfs-tools syslinux syslinux-common \
    grub-efi-amd64-bin grub-pc-bin mtools dosfstools parted kpartx \
    linux-image-amd64 qemu-utils

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

---

## Step 1: 创建 base rootfs

用 debootstrap 创建一个最小 Debian 系统。

```bash
# 创建工作目录
export WORK=/tmp/kiosk-build
mkdir -p $WORK

# debootstrap 创建 bookworm amd64 rootfs
debootstrap --arch=amd64 bookworm $WORK/rootfs http://deb.debian.org/debian

# 挂载虚拟文件系统（为 chroot 做准备）
mount -t proc proc $WORK/rootfs/proc
mount -t sysfs sysfs $WORK/rootfs/sys
mount --bind /dev $WORK/rootfs/dev
mount --bind /dev/pts $WORK/rootfs/dev/pts
```

---

## Step 2: 安装软件包

进入 chroot 安装所需软件。

```bash
# 拷贝 resolv.conf（让 chroot 内能上网）
cp /etc/resolv.conf $WORK/rootfs/etc/resolv.conf

# 进入 chroot
chroot $WORK/rootfs /bin/bash


# === 以下在 chroot 内执行 ===
export DEBIAN_FRONTEND=noninteractive
apt-get update

# 内核（与构建机同版本，确保模块匹配）
apt-get install -y linux-image-amd64

# X 图形系统
apt-get install -y xserver-xorg xserver-xorg-video-all xinit

# 窗口管理器
apt-get install -y openbox

# 浏览器
apt-get install -y chromium luit-

# 系统工具
apt-get install -y systemd systemd-sysv sudo network-manager
apt-get install -y alsa-utils fonts-noto-cjk

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/*

exit
# === chroot 结束 ===
``` 

---

## Step 3: 配置 Kiosk 模式

### 3.1 创建 kiosk 用户

```bash
# 在 chroot 内或直接操作 rootfs 目录
chroot $WORK/rootfs useradd -m -s /bin/bash kiosk

# 设置默认密码: kiosk/kiosk, root/root
chroot $WORK/rootfs bash -c 'echo "kiosk:kiosk" | chpasswd'
chroot $WORK/rootfs bash -c 'echo "root:root" | chpasswd'


echo "kiosk ALL=(ALL) NOPASSWD: ALL" > $WORK/rootfs/etc/sudoers.d/kiosk
chmod 0440 $WORK/rootfs/etc/sudoers.d/kiosk
```

### 3.2 配置 autologin（systemd）

```bash
# 创建 autologin getty override
# mkdir -p $WORK/rootfs/etc/systemd/system/serial-getty@tty1.service.d
mkdir -p $WORK/rootfs/etc/systemd/system/getty@tty1.service.d

cat > $WORK/rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF
```

### 3.3 配置 .xinitrc（启动 X + openbox + chromium）

```bash
cat > $WORK/rootfs/home/kiosk/.xinitrc <<'EOF'
#!/bin/bash
# 关闭屏保和 DPMS
xset s off
xset -dpms
xset s noblank

# 启动 openbox，autostart 里启动 chromium
exec openbox-session
EOF
chmod +x $WORK/rootfs/home/kiosk/.xinitrc
chroot $WORK/rootfs chown kiosk:kiosk /home/kiosk/.xinitrc
```

### 3.4 配置 openbox autostart（启动 chromium）

```bash
mkdir -p $WORK/rootfs/home/kiosk/.config/openbox

cat > $WORK/rootfs/home/kiosk/.config/openbox/autostart <<'EOF'
# 等待网络就绪
sleep 3

# 启动 Chromium Kiosk 模式
# 替换 URL 为你想要的网页
chromium --kiosk --noerrdialogs --disable-translate \
    --disable-features=TranslateUI \
    --disable-session-crashed-bubble \
    --disable-infobars \
    --no-first-run \
    --start-maximized \
    "https://www.gov.cn" &
EOF
chroot $WORK/rootfs chown -R kiosk:kiosk /home/kiosk/.config
```

### 3.5 配置 .bash_profile（登录后自动 startx）

```bash
cat > $WORK/rootfs/home/kiosk/.bash_profile <<'EOF'
# 自动启动 X（仅在 tty1 且未已运行时）
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx > /dev/null 2>&1
fi
EOF
chroot $WORK/rootfs chown kiosk:kiosk /home/kiosk/.bash_profile
```

### 3.6 配置网络（DHCP 自动获取）

```bash
cat > $WORK/rootfs/etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true
EOF

# 启用 NetworkManager
chroot $WORK/rootfs systemctl enable NetworkManager

```

### 3.7 配置主机名

```bash
echo "kiosk" > $WORK/rootfs/etc/hostname
cat > $WORK/rootfs/etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   kiosk
::1         localhost ip6-localhost ip6-loopback
EOF
```

---

## Step 4: 清理 rootfs 并创建 squashfs

```bash
# 卸载 chroot 挂载
umount $WORK/rootfs/dev/pts 2>/dev/null
umount $WORK/rootfs/dev 2>/dev/null
umount $WORK/rootfs/proc 2>/dev/null
umount $WORK/rootfs/sys 2>/dev/null

# 清理不需要的文件（减小体积）
rm -rf $WORK/rootfs/usr/share/doc/*
rm -rf $WORK/rootfs/usr/share/man/*
find "$WORK/rootfs/usr/share/locale" -maxdepth 1 -type d ! -name "en*" ! -name "C*" ! -name "locale" -exec rm -rf {} \; 2>/dev/null


# 移除内核文件（内核会放到 boot 分区，不需要在 squashfs 里）
cp -v "$WORK/rootfs/boot/vmlinuz-"* "$WORK/rootfs-vmlinuz" 
cp -v "$WORK/rootfs/boot/initrd.img-"* "$WORK/rootfs-initrd.img" 

# 保留 modules，移除 vmlinuz/initrd
rm -f "$WORK/rootfs/boot/vmlinuz-"* "$WORK/rootfs/boot/initrd.img-"* "$WORK/rootfs/boot/config-"* "$WORK/rootfs/boot/System.map-"*

# 创建 squashfs
mksquashfs $WORK/rootfs $WORK/system.sqsh -comp gzip -no-exports
ls -lh $WORK/system.sqsh
```

---

## Step 5: 制作自定义 initramfs

这是核心步骤——initramfs 的 init 脚本负责挂载 squashfs + overlay。

### 5.1 init 脚本

initramfs 的 init 脚本是整个架构的核心。它需要：
1\. 解析内核 cmdline 参数
2\. 挂载 imgpart 分区（ext4，含 squashfs 文件）
3\. loop 挂载 squashfs 作为只读层
4\. 挂载 datapart 分区（ext4，可写层）
5\. 创建 overlay 合并两层
6\. pivot 到真实根文件系统

```bash

# 创建 initramfs 工作目录
INITRAMFS_DIR="$WORK/initramfs"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"
cd "$INITRAMFS_DIR"

INITRD_SRC="$WORK/rootfs-initrd.img"



unmkinitramfs "$INITRD_SRC" "$INITRAMFS_DIR"


# 替换 init 脚本为我们自定义的版本
cp /path/to/kiosk-image/init ./init
chmod +x ./init



# 检查： blkid losetup blockdev run-init busybox zstd insmod 是否存在，感觉没有必要
cp -v "$(command -v blkid)" ./bin/blkid
cp -v /usr/bin/zstd ./usr/bin/zstd


# 确保关键模块存在
# squashfs 和 overlay 应该已在内核中编译或作为模块
# 如果是模块，需要确保它们在 initramfs 里
for mod in squashfs overlay  fat  vfat nls_cp437 ext4 virtio_blk virtio_pci ahci sd_mod usbcore uas; do
    find ./lib/modules -name "${mod}.ko*" 2>/dev/null | head -1
done



# 补充关键模块
KVER_BUILT=$(ls ./lib/modules/ 2>/dev/null | head -1)
ROOTFS_KMODS="$WORK/rootfs/lib/modules/$KVER_BUILT/kernel"

mkdir -p ./lib/modules/$KVER_BUILT/kernel/fs/squashfs/ 
mkdir -p ./lib/modules/$KVER_BUILT/kernel/fs/overlayfs
mkdir -p ./lib/modules/$KVER_BUILT/kernel/fs/fat
mkdir -p ./lib/modules/$KVER_BUILT/kernel/fs/nls

cp -v $ROOTFS_KMODS/fs/squashfs/squashfs.ko  ./lib/modules/$KVER_BUILT/kernel/fs/squashfs/
cp -v $ROOTFS_KMODS/fs/overlayfs/overlay.ko  ./lib/modules/$KVER_BUILT/kernel/fs/overlayfs/
cp -v $ROOTFS_KMODS/fs/fat/fat.ko  ./lib/modules/$KVER_BUILT/kernel/fs/fat/
cp -v $ROOTFS_KMODS/fs/fat/vfat.ko  ./lib/modules/$KVER_BUILT/kernel/fs/fat/
cp -v $ROOTFS_KMODS/fs/nls/nls_cp437.ko  ./lib/modules/$KVER_BUILT/kernel/fs/nls/


depmod -b . "$KVER_BUILT"

# 重新打包 initramfs
find . | cpio -H newc -o | gzip -9 > $WORK/initrd.img

ls -lh $WORK/initrd.img
```


### 5.2 init 脚本说明

init 脚本的关键逻辑（见 `kiosk-image/init` 文件）：

```bash
# 解析 cmdline
#   imgpart=UUID=xxx     — 含 squashfs 的 ext4 分区
#   imgfile=system.sqsh  — squashfs 文件名
#   datapart=UUID=xxx    — 可写层 ext4 分区

# 挂载 imgpart
mount -t ext4 ${IMAGE_PARTITION} /mnt/imgpart

# loop 挂载 squashfs（只读层）
losetup /dev/loop0 /mnt/imgpart/${SQUASH_FILE}
mount -t squashfs /dev/loop0 /mnt/static

# 挂载 datapart（可写层）
mount -t ext4 ${DATA_PARTITION} /mnt/data
mkdir -p /mnt/data/dyn /mnt/data/work

# 创建 overlay
mount -t overlay overlay /mnt/union \
    -olowerdir=/mnt/static,upperdir=/mnt/data/dyn,workdir=/mnt/data/work

# 切换到真实根
exec run-init /mnt/union /sbin/init
```

---

## Step 6: 创建磁盘镜像

```bash
IMG=$WORK/kiosk.img

# 创建 4GB 镜像
dd if=/dev/zero of=$IMG bs=1M count=4096

# 分区（GPT, 3 个分区）
parted -s $IMG mklabel gpt
parted -s $IMG mkpart primary fat32 1MiB 257MiB     # p1: boot 256MB
parted -s $IMG mkpart primary ext4 257MiB 2305MiB    # p2: imgpart 2GB
parted -s $IMG mkpart primary ext4 2305MiB 100%      # p3: datapart 剩余
parted -s $IMG set 1 boot on
parted -s $IMG set 1 esp on

# 关联 loop 设备
LOOP=$(losetup -fP --show $IMG)

# 格式化
mkfs.vfat -F 32 -n boot ${LOOP}p1
mkfs.ext4 -F -L imgpart ${LOOP}p2
mkfs.ext4 -F -L datapart ${LOOP}p3

# 获取 UUID（用于 bootloader 配置）
UUID_BOOT=$(blkid -s UUID -o value ${LOOP}p1)
UUID_IMG=$(blkid -s UUID -o value ${LOOP}p2)
UUID_DATA=$(blkid -s UUID -o value ${LOOP}p3)
echo "boot=$UUID_BOOT img=$UUID_IMG data=$UUID_DATA"
```

---

## Step 7: 填充分区内容

### 7.1 boot 分区（p1）

```bash
mkdir -p /mnt/boot
mount ${LOOP}p1 /mnt/boot

# 拷贝内核
cp -v $WORK/rootfs-vmlinuz /mnt/boot/vmlinuz

# 拷贝 initramfs
cp -v $WORK/initrd.img /mnt/boot/initrd.img


umount /mnt/boot

```

### 7.2 imgpart 分区（p2）

```bash
mkdir -p /mnt/imgpart
mount ${LOOP}p2 /mnt/imgpart

# 拷贝 squashfs
cp -v $WORK/system.sqsh /mnt/imgpart/system.sqsh

umount /mnt/imgpart
```

### 7.3 datapart 分区（p3）

```bash
# datapart 留空——首启时 initramfs 会自动创建 dyn/work 目录
# 不需要预先填充
```

---

## Step 8: 安装 bootloader

### 8.1 Syslinux（Legacy BIOS 引导）

```bash

mount ${LOOP}p1 /mnt/boot

# 安装 syslinux 到 boot 分区
syslinux --install ${LOOP}p1

# 写入 MBR 引导扇区
dd if=/usr/lib/syslinux/mbr/gptmbr.bin of=$LOOP bs=440 count=1 conv=notrunc

# 创建 syslinux.cfg
cat > /mnt/boot/syslinux.cfg <<EOF
DEFAULT kiosk
LABEL kiosk
  SAY Booting Kiosk Image...
  LINUX vmlinuz
  APPEND initrd=initrd.img loglevel=7 console=tty0 console=ttyS0,115200 \
    imgpart=UUID=${UUID_IMG} datapart=UUID=${UUID_DATA} imgfile=system.sqsh
  INITRD initrd.img
EOF



umount /mnt/boot
```

### 8.2 GRUB UEFI 引导

```bash

mount ${LOOP}p1 /mnt/boot

# 创建 EFI 目录结构
mkdir -p /mnt/boot/efi/BOOT

# 安装 GRUB UEFI bootloader
#grub-mkimage -O x86_64-efi -p /boot/grub -o /mnt/boot/efi/BOOT/BOOTX64.EFI \
#    part_gpt part_msdos fat ext2 normal boot linux configfile loopback chain \
#    efivarfs ls search search_label search_fs_uuid search_fs_file gfxterm \
#    gfxterm_background test test_loadenv loadenv exfat ntfs udf

# 用 grub-install 安装完整的 GRUB（自动处理模块依赖和 EFI boot entry）
# --removable 模式安装到 /efi/BOOT/BOOTX64.EFI（无需 NVRAM，适配 UTM/QEMU）
grub-install --target=x86_64-efi \
    --efi-directory=/mnt/boot \
    --boot-directory=/mnt/boot \
    --removable \
    --no-nvram \
    --modules="part_gpt search_fs_uuid" \
    "$LOOP" 


# 创建 grub.cfg
mkdir -p /mnt/boot/grub
cat > /mnt/boot/grub/grub.cfg <<EOF
set timeout=3
set default=0
terminal_output console
menuentry "Kiosk" {
    linux /vmlinuz loglevel=7 console=tty0 console=ttyS0,115200\
        imgpart=UUID=${UUID_IMG} datapart=UUID=${UUID_DATA} imgfile=system.sqsh
    initrd /initrd.img
}
EOF



# 也放一份在 EFI 目录（有些 UEFI 只看这里）
cp -v /mnt/boot/grub/grub.cfg /mnt/boot/efi/BOOT/grub.cfg

umount /mnt/boot
```

---

## Step 9: 完成 + 测试

```bash
# 验证
# parted -s "$LOOP" print
# blkid "${LOOP}p1" "${LOOP}p2" "${LOOP}p3"

# 释放 loop 设备
losetup -d $LOOP

# 查看最终镜像
ls -lh $IMG

# 转换为 qcow2（可选，节省空间）
qemu-img convert -O qcow2 $IMG $WORK/kiosk.qcow2
```

---

## 关键文件说明

### init 脚件（initramfs 的 /init）

这是整个架构的核心。完整脚本见 `kiosk-image/init`，关键流程：

```
1\. mount /proc /sys /dev                    ← 基础虚拟文件系统
2\. 解析 /proc/cmdline                       ← 获取 imgpart/datapart/imgfile
3\. modprobe squashfs overlay ext4           ← 加载所需模块
4\. mount ext4 imgpart → /mnt/imgpart        ← 含 squashfs 的分区
5\. losetup + mount squashfs → /mnt/static   ← 只读根
6\. mount ext4 datapart → /mnt/data          ← 可写层
7\. mount overlay → /mnt/union               ← 合并
8\. move /proc /sys /dev → /mnt/union        ← 迁移虚拟文件系统
9\. exec run-init /mnt/union /sbin/init      ← 切换到真实根
```

### cmdline 参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `imgpart=UUID=xxx` | 含 squashfs 的 ext4 分区 | `imgpart=UUID=a1b2c3d4...` |
| `imgfile=system.sqsh` | squashfs 文件名 | `imgfile=system.sqsh` |
| `datapart=UUID=xxx` | overlay 可写层 ext4 分区 | `datapart=UUID=e5f6g7h8...` |
| `console=tty0` | 主显示输出 | `console=tty0` |
| `console=ttyS0,115200` | 串口输出（调试用） | `console=ttyS0,115200` |

### 修改目标 URL

编辑 rootfs 里的 openbox autostart 文件：
```bash
# 在 Step 3.4 中修改
chromium --kiosk "https://your-url-here" &
```

或在构建完成后，挂载 squashfs 修改后重新打包：
```bash
# 解包 squashfs
unsquashfs system.sqsh -d rootfs-edit

# 修改 URL
sed -i 's|https://volumio.local:3000|https://your-url.com|' \
    rootfs-edit/home/kiosk/.config/openbox/autostart

# 重新打包
mksquashfs rootfs-edit system.sqsh -comp gzip -no-exports
```

---

### init 脚本

```bash
# cat init 
#!/bin/sh
#
# Custom initramfs init script for kiosk image
# Based on Volumio's initv3 architecture, simplified for kiosk use.
#
# This script:
#   1. Parses kernel cmdline for partition UUIDs
#   2. Mounts the image partition (ext4) containing the squashfs
#   3. Loop-mounts the squashfs as read-only root
#   4. Mounts the data partition (ext4) as writable overlay
#   5. Creates an overlay filesystem merging both
#   6. Pivots to the real root and execs systemd
#
# Required cmdline parameters:
#   imgpart=UUID=xxx        ext4 partition containing the squashfs file
#   imgfile=system.sqsh     squashfs filename on imgpart
#   datapart=UUID=xxx       ext4 partition for writable overlay
#
# Optional cmdline parameters:
#   console=ttyS0,115200    serial console output
#   debug                   enable debug output (set -x)
#   break=<point>           drop to shell at specified breakpoint
#                          (valid: init, mount, overlay, switch)

export PATH=/sbin:/usr/sbin:/bin:/usr/bin

# === Mount essential virtual filesystems ===
[ -d /dev ]  || mkdir -m 0755 /dev
[ -d /sys ]  || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ]  || mkdir /tmp

mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc
mount -t devtmpfs -o nosuid,mode=0755 udev /dev 2>/dev/null || mount --bind /dev /dev
mkdir -p /dev/pts
mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts /dev/pts 2>/dev/null || true

# === Parse kernel cmdline ===
cmdline_opts=""
for x in $(cat /proc/cmdline); do
    case "$x" in
        imgpart=*)   IMAGE_PARTITION="${x#imgpart=}" ;;
        imgfile=*)   SQUASH_FILE="${x#imgfile=}" ;;
        datapart=*)  DATA_PARTITION="${x#datapart=}" ;;
        debug)       set -x ;;
        break=*)     BREAK_POINT="${x#break=}" ;;
        quiet)       QUIET=1 ;;
    esac
done

# Logging function
log() {
    [ -z "$QUIET" ] && echo "[init] $*"
}

# Breakpoint function (for debugging)
maybe_break() {
    if [ "$BREAK_POINT" = "$1" ]; then
        echo "[init] Breakpoint '$1' reached. Dropping to shell."
        echo "  Available commands: ls, cat, mount, dmesg, exit"
        exec /bin/sh
    fi
}

# === Default values ===
SQUASH_FILE="${SQUASH_FILE:-system.sqsh}"

log "Kiosk initramfs starting..."
log "  imgpart:  ${IMAGE_PARTITION:-<not set>}"
log "  imgfile:  ${SQUASH_FILE}"
log "  datapart: ${DATA_PARTITION:-<not set>}"

maybe_break init

# === Load kernel modules ===
# These may be built-in or modules depending on kernel config
for mod in squashfs overlay ext4 vfat virtio_blk virtio_net virtio_pci \
           loop dm_mod nls_cp437 nls_iso8859_1; do
    modprobe "$mod" 2>/dev/null
done

# === Validate required parameters ===
if [ -z "$IMAGE_PARTITION" ]; then
    echo "[init] FATAL: 'imgpart=' not specified on kernel cmdline"
    echo "[init] Example: imgpart=UUID=a1b2c3d4-..."
    exec /bin/sh
fi

if [ -z "$DATA_PARTITION" ]; then
    echo "[init] FATAL: 'datapart=' not specified on kernel cmdline"
    echo "[init] Example: datapart=UUID=e5f6g7h8-..."
    exec /bin/sh
fi

# === Wait for partitions to appear ===
log "Waiting for partitions to be available..."

wait_for_device() {
    local dev="$1"
    local tries=0
    while [ $tries -lt 30 ]; do
        # Try to resolve UUID= or LABEL= to a device path
        if echo "$dev" | grep -q "^UUID="; then
            local uuid="${dev#UUID=}"
            if [ -e "/dev/disk/by-uuid/$uuid" ]; then
                echo "/dev/disk/by-uuid/$uuid"
                return 0
            fi
        elif echo "$dev" | grep -q "^LABEL="; then
            local label="${dev#LABEL=}"
            if [ -e "/dev/disk/by-label/$label" ]; then
                echo "/dev/disk/by-label/$label"
                return 0
            fi
        elif [ -e "$dev" ]; then
            echo "$dev"
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

IMG_DEV=$(wait_for_device "$IMAGE_PARTITION") || {
    echo "[init] FATAL: imgpart device not found: $IMAGE_PARTITION"
    echo "[init] Available devices:"
    ls /dev/disk/by-uuid/ 2>/dev/null
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null
    exec /bin/sh
}
log "imgpart resolved to: $IMG_DEV"

DATA_DEV=$(wait_for_device "$DATA_PARTITION") || {
    echo "[init] FATAL: datapart device not found: $DATA_PARTITION"
    exec /bin/sh
}
log "datapart resolved to: $DATA_DEV"

maybe_break mount

# === Mount image partition (ext4, contains squashfs) ===
mkdir -p /mnt/imgpart
log "Mounting imgpart ($IMG_DEV)..."
mount -t ext4 "$IMG_DEV" /mnt/imgpart || {
    echo "[init] FATAL: failed to mount imgpart $IMG_DEV"
    exec /bin/sh
}

# Verify squashfs file exists
if [ ! -f "/mnt/imgpart/${SQUASH_FILE}" ]; then
    echo "[init] FATAL: squashfs file not found: /mnt/imgpart/${SQUASH_FILE}"
    echo "[init] Contents of imgpart:"
    ls -la /mnt/imgpart/
    exec /bin/sh
fi
log "Found squashfs: /mnt/imgpart/${SQUASH_FILE} ($(ls -lh /mnt/imgpart/${SQUASH_FILE} | awk '{print $5}'))"

# === Loop-mount squashfs (read-only lower layer) ===
mkdir -p /mnt/static
log "Mounting squashfs (read-only)..."

# Find a free loop device
LOOP_DEV=$(losetup -f 2>/dev/null)
if [ -z "$LOOP_DEV" ]; then
    # Create a loop device manually if needed
    for i in 0 1 2 3 4 5 6 7; do
        if [ ! -e "/dev/loop$i" ]; then
            mknod "/dev/loop$i" b 7 "$i"
        fi
        if ! losetup "/dev/loop$i" 2>/dev/null | grep -q "/mnt/imgpart"; then
            LOOP_DEV="/dev/loop$i"
            break
        fi
    done
fi

losetup "$LOOP_DEV" "/mnt/imgpart/${SQUASH_FILE}" || {
    echo "[init] FATAL: failed to losetup $LOOP_DEV"
    exec /bin/sh
}

mount -t squashfs "$LOOP_DEV" /mnt/static || {
    echo "[init] FATAL: failed to mount squashfs on $LOOP_DEV"
    exec /bin/sh
}
log "Squashfs mounted at /mnt/static"

# === Mount data partition (ext4, writable overlay) ===
mkdir -p /mnt/data
log "Mounting datapart ($DATA_DEV)..."
mount -t ext4 -o noatime "$DATA_DEV" /mnt/data || {
    echo "[init] FATAL: failed to mount datapart $DATA_DEV"
    exec /bin/sh
}

# Create overlay directories if they don't exist (first boot)
mkdir -p /mnt/data/dyn /mnt/data/work /mnt/data/union
chmod 777 /mnt/data/dyn /mnt/data/work /mnt/data/union

maybe_break overlay

# === Create overlay filesystem ===
log "Creating overlay (lower=/mnt/static, upper=/mnt/data/dyn)..."
mount -t overlay overlay /mnt/data/union \
    -o "lowerdir=/mnt/static,upperdir=/mnt/data/dyn,workdir=/mnt/data/work" || {
    echo "[init] FATAL: failed to create overlay"
    echo "[init] Trying without workdir (older kernel?)..."
    mount -t overlay overlay /mnt/data/union \
        -o "lowerdir=/mnt/static,upperdir=/mnt/data/dyn" || {
        echo "[init] FATAL: overlay mount failed completely"
        exec /bin/sh
    }
}
log "Overlay created at /mnt/data/union"

# === Move mount points into the real root ===
# These will be accessible from the real root for updates/debugging
mkdir -p /mnt/data/union/mnt/static /mnt/data/union/mnt/imgpart
mount --move /mnt/static /mnt/data/union/mnt/static 2>/dev/null || true
mount --move /mnt/imgpart /mnt/data/union/mnt/imgpart 2>/dev/null || true

# Move virtual filesystems to real root
mount --move /proc /mnt/data/union/proc 2>/dev/null || true
mount --move /sys  /mnt/data/union/sys  2>/dev/null || true
mount --move /dev  /mnt/data/union/dev  2>/dev/null || true

maybe_break switch

# === Switch to real root and exec systemd ===
log "Switching to real root (/mnt/data/union)..."

# Clean up environment
unset IMAGE_PARTITION DATA_PARTITION SQUASH_FILE BREAK_POINT QUIET

# Exec into the real init (systemd)
exec run-init /mnt/data/union /sbin/init "$@"

# If we get here, something went very wrong
echo "[init] FATAL: run-init failed!"
exec /bin/sh
```



最终init脚本

```bash
#!/bin/sh
#
# Custom initramfs init script for kiosk image
# Based on Volumio's initv3 architecture, simplified for kiosk use.
#
# This script:
#   1. Parses kernel cmdline for partition UUIDs
#   2. Mounts the image partition (ext4) containing the squashfs
#   3. Loop-mounts the squashfs as read-only root
#   4. Mounts the data partition (ext4) as writable overlay
#   5. Creates an overlay filesystem merging both
#   6. Pivots to the real root and execs systemd
#
# Required cmdline parameters:
#   imgpart=UUID=xxx        ext4 partition containing the squashfs file
#   imgfile=system.sqsh     squashfs filename on imgpart
#   datapart=UUID=xxx       ext4 partition for writable overlay
#
# Optional cmdline parameters:
#   debug                   enable debug output (set -x)
#   break=<point>           drop to shell at specified breakpoint
#                          (valid: init, mount, overlay, switch)

export PATH=/sbin:/usr/sbin:/bin:/usr/bin

# === Mount essential virtual filesystems ===
[ -d /dev ]  || mkdir -m 0755 /dev
[ -d /sys ]  || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ]  || mkdir /tmp

mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc
mount -t devtmpfs -o nosuid,mode=0755 devtmpfs /dev
mkdir -p /dev/pts /dev/disk/by-uuid /dev/disk/by-label /dev/disk/by-partuuid
mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts /dev/pts 2>/dev/null || true

# === Parse kernel cmdline ===
for x in $(cat /proc/cmdline); do
    case "$x" in
        imgpart=*)   IMAGE_PARTITION="${x#imgpart=}" ;;
        imgfile=*)   SQUASH_FILE="${x#imgfile=}" ;;
        datapart=*)  DATA_PARTITION="${x#datapart=}" ;;
        debug)       set -x ;;
        break=*)     BREAK_POINT="${x#break=}" ;;
        quiet)       QUIET=1 ;;
    esac
done

log() {
    [ -z "$QUIET" ] && echo "[init] $*"
}

maybe_break() {
    if [ "$BREAK_POINT" = "$1" ]; then
        echo "[init] Breakpoint '$1' reached. Dropping to shell."
        exec /bin/sh
    fi
}

SQUASH_FILE="${SQUASH_FILE:-system.sqsh}"

log "Kiosk initramfs starting..."
log "  imgpart:  ${IMAGE_PARTITION:-<not set>}"
log "  imgfile:  ${SQUASH_FILE}"
log "  datapart: ${DATA_PARTITION:-<not set>}"

maybe_break init

# === Load kernel modules ===
KVER=$(ls /lib/modules/ 2>/dev/null | head -1)
KMODDIR="/lib/modules/${KVER}/kernel"

log "Loading kernel modules (KVER=$KVER)..."
# Try modprobe first for all modules (handles dependencies via modules.dep)
for mod in squashfs overlay ext4 vfat virtio_blk virtio_net virtio_pci virtio_pci_modern_dev \
           loop dm_mod nls_cp437 nls_iso8859_1 \
           ahci sd_mod sr_mod ata_piix pata_acpi \
           usbcore usb_common usb_storage uas \
           xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd ohci_pci uhci_hcd \
           usbhid hid hid_generic; do
    modprobe "$mod" 2>/dev/null
done

# === Wait for block devices to appear ===
log "Waiting for block devices..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    nbd=$(ls /sys/block/ 2>/dev/null | grep -vE "^loop|^ram|^fd" | wc -l)
    if [ "$nbd" -gt 0 ]; then
        log "Found $nbd block device(s) after ${i} second(s)"
        break
    fi
    mdev -s 2>/dev/null
    log "  try $i: waiting for devices..."
    sleep 1
done

# === Trigger partition table scan ===
log "Triggering partition table scan..."
for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]*n[0-9]*; do
    [ -b "$disk" ] || continue
    blockdev --rereadpt "$disk" 2>/dev/null || \
        echo 1 > "/sys/block/$(basename $disk)/device/rescan" 2>/dev/null || true
done

# Wait for partition devices to appear
for i in 1 2 3 4 5; do
    nparts=$(ls /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*p[0-9] /dev/mmcblk*p[0-9] 2>/dev/null | wc -l)
    [ "$nparts" -gt 0 ] && break
    sleep 1
done

# Re-create device nodes (partitions may have appeared after scan)
mdev -s 2>/dev/null

# === Populate /dev/disk/by-uuid ===
log "Populating /dev/disk/by-uuid/..."
if command -v blkid >/dev/null 2>&1; then
    for dev in /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*p[0-9] /dev/mmcblk*p[0-9]; do
        [ -b "$dev" ] || continue
        uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
        [ -n "$uuid" ] && ln -sf "$dev" "/dev/disk/by-uuid/$uuid" 2>/dev/null
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null)
        [ -n "$label" ] && ln -sf "$dev" "/dev/disk/by-label/$label" 2>/dev/null
    done
fi

# === Validate required parameters ===
if [ -z "$IMAGE_PARTITION" ]; then
    echo "[init] FATAL: 'imgpart=' not specified on kernel cmdline"
    exec /bin/sh
fi
if [ -z "$DATA_PARTITION" ]; then
    echo "[init] FATAL: 'datapart=' not specified on kernel cmdline"
    exec /bin/sh
fi

# === Wait for and resolve partition devices ===
log "Waiting for partitions: $IMAGE_PARTITION, $DATA_PARTITION"

wait_for_device() {
    local dev="$1"
    local tries=0
    while [ $tries -lt 30 ]; do
        if echo "$dev" | grep -q "^UUID="; then
            local uuid="${dev#UUID=}"
            if [ -e "/dev/disk/by-uuid/$uuid" ]; then
                echo "/dev/disk/by-uuid/$uuid"
                return 0
            fi
            if command -v blkid >/dev/null 2>&1; then
                local found=$(blkid -U "$uuid" 2>/dev/null)
                if [ -n "$found" ] && [ -e "$found" ]; then
                    echo "$found"
                    return 0
                fi
            fi
        elif echo "$dev" | grep -q "^LABEL="; then
            local label="${dev#LABEL=}"
            if [ -e "/dev/disk/by-label/$label" ]; then
                echo "/dev/disk/by-label/$label"
                return 0
            fi
        elif [ -e "$dev" ]; then
            echo "$dev"
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
        [ $((tries % 5)) -eq 0 ] && mdev -s 2>/dev/null
    done
    return 1
}

IMG_DEV=$(wait_for_device "$IMAGE_PARTITION") || {
    echo "[init] FATAL: imgpart not found: $IMAGE_PARTITION"
    exec /bin/sh
}
log "imgpart: $IMG_DEV"

DATA_DEV=$(wait_for_device "$DATA_PARTITION") || {
    echo "[init] FATAL: datapart not found: $DATA_PARTITION"
    exec /bin/sh
}
log "datapart: $DATA_DEV"

maybe_break mount

# === Mount image partition (ext4, contains squashfs) ===
mkdir -p /mnt/imgpart
log "Mounting imgpart..."
if ! mount -t ext4 "$IMG_DEV" /mnt/imgpart 2>/dev/null; then
    log "Read-write failed, trying read-only (noload)..."
    mount -t ext4 -o ro,noload "$IMG_DEV" /mnt/imgpart || {
        echo "[init] FATAL: failed to mount imgpart"
        exec /bin/sh
    }
fi

if [ ! -f "/mnt/imgpart/${SQUASH_FILE}" ]; then
    echo "[init] FATAL: squashfs not found: /mnt/imgpart/${SQUASH_FILE}"
    ls -la /mnt/imgpart/
    exec /bin/sh
fi
log "Found squashfs: ${SQUASH_FILE}"

# === Loop-mount squashfs (read-only lower layer) ===
mkdir -p /mnt/static
log "Mounting squashfs..."
LOOP_DEV=$(losetup -f 2>/dev/null)
losetup "$LOOP_DEV" "/mnt/imgpart/${SQUASH_FILE}" || {
    echo "[init] FATAL: losetup failed"
    exec /bin/sh
}
mount -t squashfs "$LOOP_DEV" /mnt/static || {
    echo "[init] FATAL: squashfs mount failed"
    exec /bin/sh
}
log "Squashfs mounted"

# === Mount data partition (ext4, writable overlay) ===
mkdir -p /mnt/data
log "Mounting datapart..."
DATA_READONLY=no
if mount -t ext4 -o noatime "$DATA_DEV" /mnt/data 2>/dev/null; then
    if ! (touch /mnt/data/.write_test 2>/dev/null && rm -f /mnt/data/.write_test 2>/dev/null); then
        log "datapart is read-only, remounting noload..."
        umount /mnt/data 2>/dev/null
        mount -t ext4 -o ro,noload "$DATA_DEV" /mnt/data 2>/dev/null
        DATA_READONLY=yes
    fi
else
    mount -t ext4 -o ro,noload "$DATA_DEV" /mnt/data 2>/dev/null && DATA_READONLY=yes || {
        log "datapart unavailable, using tmpfs..."
        mount -t tmpfs -o size=512M tmpfs /mnt/data
        DATA_READONLY=tmpfs
    }
fi

maybe_break overlay

# === Create overlay filesystem ===
if [ "$DATA_READONLY" == "no" ]; then
    mkdir -p /mnt/data/dyn /mnt/data/work /mnt/data/union
    chmod 777 /mnt/data/dyn /mnt/data/work /mnt/data/union
    log "Creating overlay (persistent)..."
    mount -t overlay overlay /mnt/data/union \
        -o "lowerdir=/mnt/static,upperdir=/mnt/data/dyn,workdir=/mnt/data/work" || {
        echo "[init] FATAL: overlay mount failed"
        exec /bin/sh
    }
    UNION_ROOT="/mnt/data/union"
else
    log "Creating overlay with tmpfs (non-persistent)..."
    mkdir -p /mnt/overlay /mnt/union
    mount -t tmpfs -o size=512M tmpfs /mnt/overlay
    mkdir -p /mnt/overlay/upper /mnt/overlay/work
    chmod 777 /mnt/overlay/upper /mnt/overlay/work /mnt/union
    mount -t overlay overlay /mnt/union \
        -o "lowerdir=/mnt/static,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work" || {
        echo "[init] FATAL: overlay mount with tmpfs failed"
        exec /bin/sh
    }
    UNION_ROOT="/mnt/union"
fi
log "Overlay created at $UNION_ROOT"

# === Move mount points into the real root ===
mkdir -p "$UNION_ROOT/mnt/static" "$UNION_ROOT/mnt/imgpart"
mount --move /mnt/static "$UNION_ROOT/mnt/static" 2>/dev/null || true
mount --move /mnt/imgpart "$UNION_ROOT/mnt/imgpart" 2>/dev/null || true
mount --move /proc "$UNION_ROOT/proc" 2>/dev/null || true
mount --move /sys  "$UNION_ROOT/sys"  2>/dev/null || true
mount --move /dev  "$UNION_ROOT/dev"  2>/dev/null || true

maybe_break switch

# === Switch to real root and exec systemd ===
log "Switching to real root ($UNION_ROOT)..."
unset IMAGE_PARTITION DATA_PARTITION SQUASH_FILE BREAK_POINT QUIET
exec run-init "$UNION_ROOT" /sbin/init "$@"

echo "[init] FATAL: run-init failed!"
exec /bin/sh
```
