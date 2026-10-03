#!/bin/bash
set -e # Dừng script ngay lập tức nếu có bất kỳ lỗi nào xảy ra

# 1. CẬP NHẬT KEYRING (Tránh lỗi chứng chỉ khi tải)
pacman -Sy --noconfirm archlinux-keyring

clear
echo "========================================================"
echo "    KỊCH BẢN CÀI ĐẶT TỰ ĐỘNG ARCH LINUX (CLEAN INSTALL)   "
echo "========================================================"
echo "Chọn cấu hình máy bạn đang cài đặt:"
echo "1) HP Elitebook 840 G1 (Intel HD 4400, GNOME Full)"
echo "2) Dell Inspiron 15 3567 (Intel + AMD, GNOME Minimal)"
read -p "Nhập lựa chọn của bạn (1 hoặc 2): " MACHINE_CHOICE

echo "--------------------------------------------------------"
read -p "Nhập Tên máy (Hostname) muốn đặt: " HOST_NAME
read -p "Nhập Tên người dùng (Username): " USER_NAME
read -s -p "Nhập Mật khẩu cho Root: " ROOT_PASS; echo
read -s -p "Nhập Mật khẩu cho $USER_NAME: " USER_PASS; echo
echo "--------------------------------------------------------"
echo "CẢNH BÁO: TOÀN BỘ DỮ LIỆU TRÊN Ổ /dev/sda SẼ BỊ XÓA SẠCH!"
read -p "Bạn có chắc chắn muốn tiếp tục? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Đã hủy cài đặt."
    exit 1
fi

DRIVE="/dev/sda"

# 2. XÓA VÀ PHÂN VÙNG LẠI Ổ CỨNG
echo "[1/8] Đang phân vùng ổ cứng ($DRIVE)..."
umount -A --recursive /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

# Xóa toàn bộ cấu trúc cũ và tạo mới: 512MB EFI, còn lại là Root (Ext4)
sgdisk -Z $DRIVE
sgdisk -n 1:0:+512M -t 1:ef00 $DRIVE
sgdisk -n 2:0:0 -t 2:8300 $DRIVE

# Format phân vùng
mkfs.fat -F32 ${DRIVE}1
mkfs.ext4 -F ${DRIVE}2

# 3. MOUNT VÀ TẠO SWAPFILE (4GB)
echo "[2/8] Đang Mount và tạo Swapfile dự phòng..."
mount ${DRIVE}2 /mnt
mkdir -p /mnt/boot
mount ${DRIVE}1 /mnt/boot

fallocate -l 4G /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile # Bật luôn để genfstab tự nhận diện

# 4. THIẾT LẬP DANH SÁCH GÓI CẦN CÀI
# Các gói cơ bản, âm thanh, bluetooth, nguồn, zram
PKGS_BASE="base base-devel linux linux-firmware intel-ucode nano networkmanager sudo e2fsprogs git wget curl"
PKGS_AUDIO="pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber bluez bluez-utils"
PKGS_POWER="power-profiles-daemon zram-generator"

if [ "$MACHINE_CHOICE" == "1" ]; then
    # Cấu hình HP (Intel Haswell)
    PKGS_GUI="gnome"
    # Dùng libva-intel-driver cho CPU cũ, intel-media-driver phòng hờ
    PKGS_GPU="mesa vulkan-intel libva-intel-driver intel-media-driver"
else
    # Cấu hình Dell (Hybrid Intel Kaby Lake + AMD)
    PKGS_GUI="gnome-shell gnome-control-center gnome-terminal nautilus gdm xdg-user-dirs-gtk"
    PKGS_GPU="mesa vulkan-intel intel-media-driver vulkan-radeon xf86-video-amdgpu switcheroo-control"
fi

# 5. CÀI ĐẶT HỆ THỐNG CƠ BẢN (PACSTRAP)
echo "[3/8] Đang cài đặt các gói hệ thống cốt lõi..."
pacstrap /mnt $PKGS_BASE $PKGS_AUDIO $PKGS_POWER $PKGS_GUI $PKGS_GPU

# 6. TẠO FSTAB & CẤU HÌNH ZRAM
echo "[4/8] Cấu hình Fstab và zRAM..."
genfstab -U /mnt >> /mnt/etc/fstab

cat <<EOF > /mnt/etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
# Note: Swapfile ở fstab mặc định có priority âm, zRAM là 100 -> OS sẽ ưu tiên zRAM tuyệt đối.

# 7. CẤU HÌNH BÊN TRONG HỆ THỐNG (CHROOT)
echo "[5/8] Thiết lập cấu hình người dùng, Bootloader và Dịch vụ..."
PARTUUID=$(blkid -s PARTUUID -o value ${DRIVE}2)

arch-chroot /mnt /bin/bash <<EOF
# Giờ, Ngôn ngữ, Hostname
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOST_NAME" > /etc/hostname

# Người dùng và Mật khẩu
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,video,audio,storage -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Cài đặt Bootloader (systemd-boot)
bootctl install
cat <<BOOT > /boot/loader/loader.conf
default arch.conf
timeout 3
editor no
BOOT

cat <<ARCH > /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=PARTUUID=$PARTUUID rw quiet splash
ARCH

# Bật các dịch vụ (Services)
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth
systemctl enable power-profiles-daemon

if [ "$MACHINE_CHOICE" == "2" ]; then
    systemctl enable switcheroo-control
fi

# Thiết lập Môi trường Bộ gõ (cho IBus-Bamboo)
echo "GTK_IM_MODULE=ibus" >> /etc/environment
echo "QT_IM_MODULE=ibus" >> /etc/environment
echo "XMODIFIERS=@im=ibus" >> /etc/environment
EOF

# 8. CÀI YAY, CHROME, BỘ GÕ & FONT BẰNG QUYỀN USER
echo "[6/8] Tải YAY, Chrome, Fonts và cấu hình tối ưu Chrome..."
arch-chroot /mnt /bin/bash <<EOF
su - $USER_NAME -c '
# Tải và cài đặt YAY
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

# Cài đặt các ứng dụng AUR và Fonts
yay -S --noconfirm google-chrome ttf-ms-fonts ttf-noto-nerd ttf-roboto noto-fonts-emoji ibus-bamboo

# Tối ưu hóa Chrome (Hardware Acceleration)
mkdir -p ~/.config
cat <<FLAGS > ~/.config/chrome-flags.conf
--ozone-platform-hint=auto
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
--enable-features=VaapiVideoDecoder,VaapiVideoEncoder,VaapiIgnoreDriverChecks
--disable-features=Vulkan
--disable-features=ExtensionManifestV2Unsupported
FLAGS

# Google Chrome bản AUR thường đọc cả file này
cp ~/.config/chrome-flags.conf ~/.config/google-chrome-flags.conf
'
EOF

echo "[8/8] HOÀN TẤT CÀI ĐẶT!"
echo "Bạn có thể gõ lệnh 'reboot' để khởi động lại máy ngay bây giờ."
echo "Hãy rút USB ra khi máy tính bắt đầu khởi động lại."