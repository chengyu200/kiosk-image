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

[init脚本](./init)
