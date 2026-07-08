#!/usr/bin/env bash
#
# build-kiosk-image.sh — 一键构建 kiosk 镜像
#
# 用法: sudo ./build-kiosk-image.sh [URL] [IMG_SIZE_GB]
# 示例: sudo ./build-kiosk-image.sh https://www.baidu.com 4
#
set -euo pipefail

# === 确保 PATH 包含所有标准系统目录 ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === 脚本所在目录的绝对路径 (用于定位 init 等配套文件) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === 参数 ===
KIOSK_URL="${1:-https://www.baidu.com}"
IMG_SIZE_GB="${2:-3}"

# === 常量 ===
WORK="/tmp/kiosk-build"
ROOTFS="$WORK/rootfs"
IMG="$WORK/kiosk.img"
SUITE="bookworm"
ARCH="amd64"

# 颜色
if [[ -t 1 ]]; then
  G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
  G=''; Y=''; C=''; B=''; N=''
fi

log()  { echo -e "${G}[..]${N} $*"; }
info() { echo -e "${C}[==]${N} $*"; }
warn() { echo -e "${Y}[!!]${N} $*"; }
ok()   { echo -e "${G}[ok]${N} $*"; }
die()  { echo -e "${Y}[EE]${N} $*" >&2; exit 1; }

step() { echo -e "\n${B}${C}━━━ Step $1: $2 ━━━${N}"; }

# === 清理函数 (中断/错误/正常退出时调用) ===
LOOP_DEV=""
cleanup() {
    trap - EXIT INT TERM  # 防止重复触发
    local exit_code=$?
    # 卸载 chroot 虚拟文件系统 (倒序)
    for m in "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"; do
        umount -l "$m" 2>/dev/null || true
    done
    # 卸载镜像分区挂载点
    for m in /mnt/kiosk-imgpart /mnt/kiosk-boot; do
        umount -l "$m" 2>/dev/null || true
    done
    # 释放 loop 设备
    [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    exit $exit_code
}
trap cleanup EXIT INT TERM

# === 前置检查 ===
[[ "$(id -u)" -eq 0 ]] || die "需要 root 权限 (sudo)"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "需要 x86_64 架构"

# === Step 0: 安装构建依赖 ===
step 0 "安装构建依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq debootstrap squashfs-tools syslinux syslinux-common \
    grub-efi-amd64-bin grub-pc-bin mtools dosfstools parted kpartx \
    linux-image-amd64 2>&1 | tail -3
ok "依赖已安装"

# === Step 1: 创建 rootfs (debootstrap + 安装软件包) ===
step 1 "创建 rootfs (debootstrap + 安装软件包)"

# rootfs 缓存路径（含 debootstrap + 软件包，不含 kiosk 配置，可跨 URL 复用）
ROOTFS_CACHE="${ROOTFS_CACHE:-/var/cache/kiosk-rootfs-${SUITE}-${ARCH}.tar.gz}"

# 清理工作目录（不影响缓存）
rm -rf "$WORK"
mkdir -p "$WORK"

mount_chroot() {
    mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
    mount -t sysfs sysfs "$ROOTFS/sys" 2>/dev/null || true
    mount --bind /dev "$ROOTFS/dev" 2>/dev/null || true
    mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
}

umount_chroot() {
    umount "$ROOTFS/dev/pts" 2>/dev/null || true
    umount "$ROOTFS/dev" 2>/dev/null || true
    umount "$ROOTFS/proc" 2>/dev/null || true
    umount "$ROOTFS/sys" 2>/dev/null || true
}

if [[ -f "$ROOTFS_CACHE" ]]; then
    log "发现 rootfs 缓存: $ROOTFS_CACHE"
    log "解压缓存 (跳过 debootstrap + apt install)..."
    tar xf "$ROOTFS_CACHE" -C "$WORK"
    mount_chroot
    ok "rootfs 从缓存恢复完成"
else
    log "运行 debootstrap ($SUITE $ARCH)..."
    debootstrap --arch="$ARCH" "$SUITE" "$ROOTFS" http://deb.debian.org/debian

    log "挂载 chroot..."
    mount_chroot

    log "安装软件包 (chroot 内)..."
    chroot "$ROOTFS" /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# 升级已安装的包
apt-get upgrade -y

# 内核
apt-get install -y linux-image-amd64

# X 图形系统
apt-get install -y xserver-xorg xserver-xorg-video-all xinit

# 窗口管理器
apt-get install -y openbox

# 浏览器（排除 luit，它与 bookworm 的 x11-utils 版本冲突）
apt-get install -y chromium luit-

# 系统工具
apt-get install -y systemd systemd-sysv sudo network-manager
apt-get install -y alsa-utils fonts-noto-cjk

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT_EOF

    # umount 后打包缓存，再重新挂载
    log "卸载 chroot 以打包缓存..."
    umount_chroot

    log "创建 rootfs 缓存..."
    mkdir -p "$(dirname "$ROOTFS_CACHE")"
    tar czf "$ROOTFS_CACHE" -C "$WORK" rootfs
    ok "rootfs 创建完成并已缓存: $ROOTFS_CACHE"

    log "重新挂载 chroot..."
    mount_chroot
fi

# === Step 2: 配置 kiosk 模式 ===
step 2 "配置 kiosk 模式"

# 创建 kiosk 用户
chroot "$ROOTFS" useradd -m -s /bin/bash kiosk 2>/dev/null || true

# 设置默认密码: kiosk/kiosk, root/root
chroot "$ROOTFS" bash -c 'echo "kiosk:kiosk" | chpasswd'
chroot "$ROOTFS" bash -c 'echo "root:root" | chpasswd'
info "默认密码已设置: kiosk/kiosk, root/root"

echo "kiosk ALL=(ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/kiosk"
chmod 0440 "$ROOTFS/etc/sudoers.d/kiosk"

# Autologin (tty1)
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF

# .xinitrc
cat > "$ROOTFS/home/kiosk/.xinitrc" <<'EOF'
#!/bin/bash
xset s off
xset -dpms
xset s noblank
exec openbox-session
EOF
chmod +x "$ROOTFS/home/kiosk/.xinitrc"
chroot "$ROOTFS" chown kiosk:kiosk /home/kiosk/.xinitrc

# openbox autostart (chromium kiosk)
mkdir -p "$ROOTFS/home/kiosk/.config/openbox"
cat > "$ROOTFS/home/kiosk/.config/openbox/autostart" <<EOF
sleep 3
chromium --kiosk --noerrdialogs --disable-translate \
    --disable-features=TranslateUI \
    --disable-session-crashed-bubble \
    --disable-infobars \
    --no-first-run \
    --no-sandbox \
    --start-maximized \
    "${KIOSK_URL}" &
EOF
chroot "$ROOTFS" chown -R kiosk:kiosk /home/kiosk/.config

# .bash_profile (auto startx on tty1)
cat > "$ROOTFS/home/kiosk/.bash_profile" <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx > /dev/null 2>&1
fi
EOF
chroot "$ROOTFS" chown kiosk:kiosk /home/kiosk/.bash_profile

# NetworkManager
cat > "$ROOTFS/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=ifupdown,keyfile
[ifupdown]
managed=true
EOF
chroot "$ROOTFS" systemctl enable NetworkManager 2>/dev/null || true

# Hostname
echo "kiosk" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   kiosk
::1         localhost ip6-localhost ip6-loopback
EOF

ok "kiosk 配置完成 (URL: $KIOSK_URL)"

# === 卸载 chroot ===
log "卸载 chroot..."
umount "$ROOTFS/dev/pts" 2>/dev/null || true
umount "$ROOTFS/dev" 2>/dev/null || true
umount "$ROOTFS/proc" 2>/dev/null || true
umount "$ROOTFS/sys" 2>/dev/null || true

# === Step 3: 创建 squashfs ===
step 3 "创建 squashfs"

# 清理减小体积
rm -rf "$ROOTFS/usr/share/doc/"*
rm -rf "$ROOTFS/usr/share/man/"*
find "$ROOTFS/usr/share/locale" -maxdepth 1 -type d ! -name "en*" ! -name "C*" ! -name "locale" -exec rm -rf {} \; 2>/dev/null || true

# 移除内核文件（内核会放到 boot 分区，不需要在 squashfs 里）
# 保留 modules，移除 vmlinuz/initrd
# 但先保存 rootfs 自己的 vmlinuz 和 initrd（Step 5/7 需要，确保版本匹配）
log "保存 rootfs 的 vmlinuz 和 initrd (确保内核模块版本一致)..."
cp "$ROOTFS/boot/vmlinuz-"* "$WORK/rootfs-vmlinuz" 2>/dev/null || cp "/boot/vmlinuz-$(ls "$ROOTFS/lib/modules/" | sort -V | tail -1)" "$WORK/rootfs-vmlinuz"
cp "$ROOTFS/boot/initrd.img-"* "$WORK/rootfs-initrd.img" 2>/dev/null || true
log "  vmlinuz: $(ls -lh "$WORK/rootfs-vmlinuz" 2>/dev/null | awk '{print $5}')"
log "  initrd: $(ls -lh "$WORK/rootfs-initrd.img" 2>/dev/null | awk '{print $5}')"

rm -f "$ROOTFS/boot/vmlinuz-"* "$ROOTFS/boot/initrd.img-"* "$ROOTFS/boot/config-"* "$ROOTFS/boot/System.map-"*

log "打包 squashfs..."
rm -f "$WORK/system.sqsh"
mksquashfs "$ROOTFS" "$WORK/system.sqsh" -comp gzip -no-exports -no-progress 2>&1 | tail -3
ok "squashfs: $(ls -lh "$WORK/system.sqsh" | awk '{print $5}')"

# === Step 4: 制作 initramfs ===
step 4 "制作自定义 initramfs"

INITRAMFS_DIR="$WORK/initramfs"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"
cd "$INITRAMFS_DIR"

# 用 rootfs 自己的 initrd 作为基础（确保模块版本与 vmlinuz 一致）
if [[ -f "$WORK/rootfs-initrd.img" ]]; then
    INITRD_SRC="$WORK/rootfs-initrd.img"
    log "基础 initrd: $INITRD_SRC (来自 rootfs，版本匹配)"
else
    INITRD_SRC=$(ls /boot/initrd.img-* | sort -V | tail -1)
    warn "使用构建机 initrd: $INITRD_SRC (可能与 rootfs 内核版本不匹配!)"
fi
unmkinitramfs "$INITRD_SRC" "$INITRAMFS_DIR"
if [[ -d "$INITRAMFS_DIR/main" ]]; then
    cp -a "$INITRAMFS_DIR/main/"* "$INITRAMFS_DIR/" 2>/dev/null || true
    cp -a "$INITRAMFS_DIR/early/"* "$INITRAMFS_DIR/" 2>/dev/null || true
fi

# 复制自定义 init 脚本
cp "$SCRIPT_DIR/init" ./init
chmod +x ./init

# 确保关键工具存在于 initramfs（init 脚本依赖）
log "检查关键工具..."
# blkid — 用于 UUID/LABEL 查找
if ! [ -x ./bin/blkid ] && ! [ -x ./usr/bin/blkid ]; then
    log "  拷入 blkid..."
    cp "$(command -v blkid)" ./bin/blkid 2>/dev/null && chmod +x ./bin/blkid || warn "  blkid 未找到"
fi
# losetup — 用于 loop 挂载 squashfs
if ! [ -x ./sbin/losetup ] && ! [ -x ./usr/sbin/losetup ]; then
    log "  拷入 losetup..."
    cp "$(command -v losetup)" ./sbin/losetup 2>/dev/null && chmod +x ./sbin/losetup || warn "  losetup 未找到"
fi
# blockdev — 用于触发分区表扫描
if ! [ -x ./sbin/blockdev ] && ! [ -x ./usr/sbin/blockdev ]; then
    log "  拷入 blockdev..."
    cp "$(command -v blockdev)" ./sbin/blockdev 2>/dev/null && chmod +x ./sbin/blockdev || warn "  blockdev 未找到"
fi
# run-init — 用于切换到真实根（initrd 自带，检查即可）
if ! [ -x ./sbin/run-init ] && ! [ -x ./usr/sbin/run-init ]; then
    if [ -x ./bin/busybox ]; then
        ln -sf busybox ./sbin/run-init 2>/dev/null || true
    fi
fi
# busybox — 提供 mdev/shell 等
if ! [ -x ./bin/busybox ]; then
    log "  拷入 busybox..."
    cp /usr/bin/busybox ./bin/busybox 2>/dev/null && chmod +x ./bin/busybox || warn "  busybox 未找到"
fi
# zstd — 解压 .ko.zst 模块需要
if ! [ -x ./usr/bin/zstd ] && ! [ -x ./bin/zstd ]; then
    log "  拷入 zstd..."
    cp /usr/bin/zstd ./usr/bin/zstd 2>/dev/null && chmod +x ./usr/bin/zstd || warn "  zstd 未找到"
fi
# insmod — init 脚本回退方案需要
if ! [ -x ./sbin/insmod ] && ! [ -L ./sbin/insmod ] && [ -x ./bin/busybox ]; then
    ln -sf busybox ./sbin/insmod 2>/dev/null || true
fi

# 预解压关键模块的 .ko.zst → .ko（确保 insmod 能直接加载）
log "预解压关键模块 (.ko.zst → .ko)..."
KVER_BUILT=$(ls ./lib/modules/ 2>/dev/null | head -1)
if [ -n "$KVER_BUILT" ]; then
    find ./lib/modules/$KVER_BUILT -name "*.ko.zst" | while read -r zstfile; do
        kofile="${zstfile%.zst}"
        if command -v zstd >/dev/null 2>&1; then
            zstd -dc "$zstfile" > "$kofile" 2>/dev/null && rm -f "$zstfile"
        fi
    done

    # 从 rootfs 拷入 initramfs 缺失的关键模块（squashfs/overlay 等）
    # 系统 initrd 可能不包含这些模块，但 kiosk initramfs 需要
    ROOTFS_KMODS="$WORK/rootfs/lib/modules/$KVER_BUILT/kernel"
    log "从 rootfs 补充缺失的模块..."
    for modpair in \
        "fs/squashfs/squashfs" \
        "fs/overlayfs/overlay" \
        "fs/fat/fat" \
        "fs/fat/vfat" \
        "fs/nls/nls_cp437" \
        "fs/nls/nls_iso8859_1" \
        "drivers/usb/core/usbcore" \
        "drivers/usb/common/usb-common" \
        "drivers/usb/storage/usb-storage" \
        "drivers/usb/storage/uas" \
        "drivers/usb/host/xhci-hcd" \
        "drivers/usb/host/xhci-pci" \
        "drivers/usb/host/ehci-hcd" \
        "drivers/usb/host/ehci-pci" \
        "drivers/usb/host/ohci-hcd" \
        "drivers/usb/host/ohci-pci" \
        "drivers/usb/host/uhci-hcd" \
        "drivers/hid/usbhid" \
        "drivers/hid/hid" \
        "drivers/hid/hid-generic"; do
        # 在 initramfs 里找
        found=$(find ./lib/modules/$KVER_BUILT -name "$(basename $modpair).ko" 2>/dev/null | head -1)
        if [ -z "$found" ]; then
            # 从 rootfs 拷入
            for ext in .ko .ko.zst; do
                src="$ROOTFS_KMODS/$modpair$ext"
                if [ -f "$src" ]; then
                    dest="./lib/modules/$KVER_BUILT/kernel/$(dirname $modpair)/$(basename $src)"
                    mkdir -p "$(dirname "$dest")"
                    if [[ "$ext" == ".ko.zst" ]] && command -v zstd >/dev/null 2>&1; then
                        zstd -dc "$src" > "${dest%.zst}" 2>/dev/null
                        info "  补充: $(basename $modpair).ko (从 rootfs 解压)"
                    else
                        cp "$src" "$dest"
                        info "  补充: $(basename $src) (从 rootfs)"
                    fi
                    break
                fi
            done
        fi
    done

    # 重新生成 modules.dep（让 modprobe 能正常工作）
    if [ -x ./sbin/depmod ] || [ -x ./usr/sbin/depmod ]; then
        depmod -b . "$KVER_BUILT" 2>/dev/null || true
    fi
fi

# 检查关键模块
log "检查关键模块..."
for mod in squashfs overlay ext4 virtio_blk virtio_pci ahci sd_mod usbcore uas; do
    found=$(find ./lib/modules -name "${mod}.ko" 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
        info "  $mod: $found"
    else
        warn "  $mod: 未找到（可能已编译进内核）"
    fi
done

# 重新打包
log "打包 initramfs..."
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$WORK/initrd.img"
ok "initramfs: $(ls -lh "$WORK/initrd.img" | awk '{print $5}')"
cd "$WORK"

# === Step 5: 创建磁盘镜像 ===
step 5 "创建磁盘镜像 (${IMG_SIZE_GB}GB)"

dd if=/dev/zero of="$IMG" bs=1M count=$((IMG_SIZE_GB * 1024)) status=progress 2>&1 | tail -2

# 分区
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart primary fat32 1MiB 257MiB
parted -s "$IMG" mkpart primary ext4 257MiB $((257 + 2048))MiB
parted -s "$IMG" mkpart primary ext4 $((257 + 2048))MiB 100%
parted -s "$IMG" set 1 boot on
parted -s "$IMG" set 1 esp on

LOOP=$(losetup -fP --show "$IMG")
LOOP_DEV="$LOOP"
log "loop 设备: $LOOP"

# 格式化
mkfs.vfat -F 32 -n boot "${LOOP}p1" 2>&1 | tail -1
mkfs.ext4 -F -L imgpart "${LOOP}p2" 2>&1 | tail -1
mkfs.ext4 -F -L datapart "${LOOP}p3" 2>&1 | tail -1

UUID_BOOT=$(blkid -s UUID -o value "${LOOP}p1")
UUID_IMG=$(blkid -s UUID -o value "${LOOP}p2")
UUID_DATA=$(blkid -s UUID -o value "${LOOP}p3")
ok "分区完成: boot=$UUID_BOOT img=$UUID_IMG data=$UUID_DATA"

# === Step 6: 填充分区 ===
step 6 "填充分区内容"

# p1: boot — 使用 rootfs 的 vmlinuz（与 initramfs 模块版本一致）
mkdir -p /mnt/kiosk-boot
mount "${LOOP}p1" /mnt/kiosk-boot
cp "$WORK/rootfs-vmlinuz" /mnt/kiosk-boot/vmlinuz
cp "$WORK/initrd.img" /mnt/kiosk-boot/initrd.img
log "boot 分区: vmlinuz ($(ls -lh /mnt/kiosk-boot/vmlinuz | awk '{print $5}')) + initrd.img ($(ls -lh /mnt/kiosk-boot/initrd.img | awk '{print $5}'))"

# p2: imgpart (squashfs)
mkdir -p /mnt/kiosk-imgpart
mount "${LOOP}p2" /mnt/kiosk-imgpart
cp "$WORK/system.sqsh" /mnt/kiosk-imgpart/system.sqsh
log "imgpart 分区: system.sqsh ($(ls -lh /mnt/kiosk-imgpart/system.sqsh | awk '{print $5}'))"

umount /mnt/kiosk-imgpart

# === Step 7: 安装 bootloader ===
step 7 "安装 bootloader (syslinux + GRUB UEFI)"

# --- Syslinux (Legacy BIOS) ---
log "安装 syslinux..."
syslinux --install "${LOOP}p1" 2>&1 | tail -1
dd if=/usr/lib/syslinux/mbr/gptmbr.bin of="$LOOP" bs=440 count=1 conv=notrunc 2>&1

cat > /mnt/kiosk-boot/syslinux.cfg <<EOF
DEFAULT kiosk
LABEL kiosk
  SAY Booting Kiosk Image...
  LINUX vmlinuz
  APPEND initrd=initrd.img loglevel=7 console=tty0 console=ttyS0,115200 \
    imgpart=UUID=${UUID_IMG} datapart=UUID=${UUID_DATA} imgfile=system.sqsh
  INITRD initrd.img
EOF
ok "syslinux 安装完成"

# --- GRUB UEFI ---
log "安装 GRUB UEFI..."
mkdir -p /mnt/kiosk-boot/efi/BOOT /mnt/kiosk-boot/grub

# 用 grub-install 安装完整的 GRUB（自动处理模块依赖和 EFI boot entry）
# --removable 模式安装到 /efi/BOOT/BOOTX64.EFI（无需 NVRAM，适配 UTM/QEMU）
grub-install --target=x86_64-efi \
    --efi-directory=/mnt/kiosk-boot \
    --boot-directory=/mnt/kiosk-boot \
    --removable \
    --no-nvram \
    --modules="part_gpt search_fs_uuid" \
    "$LOOP" 2>&1 | tail -3

# grub-install 会创建 /mnt/kiosk-boot/grub/ 目录并放入模块
# 现在写入 grub.cfg
cat > /mnt/kiosk-boot/grub/grub.cfg <<EOF
set timeout=3
set default=0
terminal_output console
menuentry "Kiosk" {
    linux /vmlinuz loglevel=7 console=tty0 console=ttyS0,115200\
        imgpart=UUID=${UUID_IMG} datapart=UUID=${UUID_DATA} imgfile=system.sqsh
    initrd /initrd.img
}
EOF
cp /mnt/kiosk-boot/grub/grub.cfg /mnt/kiosk-boot/efi/BOOT/grub.cfg
ok "GRUB UEFI 安装完成"

umount /mnt/kiosk-boot
losetup -d "$LOOP"
LOOP_DEV=""
ok "镜像构建完成: $IMG ($(ls -lh "$IMG" | awk '{print $5}'))"

# === Step 8: 验证 ===
step 8 "验证"
LOOP=$(losetup -fP --show "$IMG")
LOOP_DEV="$LOOP"
parted -s "$LOOP" print
echo "=== blkid ==="
blkid "${LOOP}p1" "${LOOP}p2" "${LOOP}p3"
losetup -d "$LOOP"
LOOP_DEV=""

echo ""
echo -e "${B}${G}━━━ Kiosk 镜像构建完成! ━━━${N}"
echo ""
echo "镜像文件: $IMG"
echo "目标 URL: $KIOSK_URL"
echo ""
echo "测试启动 (QEMU):"
echo "  qemu-system-x86_64 -machine q35 -cpu max -m 2048 \\"
echo "    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \\"
echo "    -drive file=$IMG,format=raw \\"
echo "    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \\"
echo "    -serial mon:stdio"
echo ""
echo "写入 U 盘:"
echo "  sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo ""
echo "修改 URL: 编辑脚本开头的 KIOSK_URL 变量，重新运行"
