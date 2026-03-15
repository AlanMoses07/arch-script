#!/usr/bin/env bash

set -euo pipefail

# ==========================================

# Logging

# ==========================================

LOG_FILE="/var/log/arch-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

REAL_USER="${SUDO_USER:-$USER}"

# ==========================================

# Root Check

# ==========================================

check_root() {
if [[ $EUID -ne 0 ]]; then
log_error "Run with sudo."
exit 1
fi
}

# ==========================================

# Pacman Optimization

# ==========================================

optimize_pacman() {

```
log_info "Optimizing pacman configuration..."

sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

pacman -Syu --noconfirm

pacman -S --needed --noconfirm reflector

reflector --latest 10 --protocol https --sort rate \
    --save /etc/pacman.d/mirrorlist
```

}

# ==========================================

# WiFi Setup

# ==========================================

setup_wifi() {

```
read -rp "Enter WiFi SSID: " WIFI_SSID
read -rp "Enter WiFi username: " WIFI_USER
read -rsp "Enter WiFi password: " WIFI_PASS
echo ""

rfkill unblock wifi || true
nmcli radio wifi on

WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device | grep wifi | cut -d: -f1 | head -n1)

if [[ -z "$WIFI_IFACE" ]]; then
    log_error "No WiFi interface found."
    exit 1
fi

log_info "Using interface: $WIFI_IFACE"

nmcli connection add \
    type wifi \
    con-name "$WIFI_SSID" \
    ifname "$WIFI_IFACE" \
    ssid "$WIFI_SSID" \
    wifi-sec.key-mgmt wpa-eap \
    802-1x.eap peap \
    802-1x.phase2-auth mschapv2 \
    802-1x.identity "$WIFI_USER" \
    802-1x.password "$WIFI_PASS"

nmcli connection up "$WIFI_SSID"
```

}

# ==========================================

# Internet Check

# ==========================================

verify_connection() {

```
log_info "Checking internet connectivity..."

if ping -c 3 archlinux.org >/dev/null; then
    log_success "Internet working."
else
    log_error "No internet connection."
    exit 1
fi
```

}

# ==========================================

# Pacman Retry Wrapper

# ==========================================

retry_pacman() {

```
local retries=3
local count=0

until pacman -S --needed --noconfirm "$@"; do

    ((count++))

    if [[ $count -ge $retries ]]; then
        log_error "Failed installing: $*"
        return 1
    fi

    log_warn "Retrying pacman..."
    sleep 5
done
```

}

# ==========================================

# Base Packages

# ==========================================

install_base_packages() {

```
log_info "Installing base packages..."

retry_pacman \
    firefox telegram-desktop discord vlc \
    git cmake cargo gcc \
    pipewire pipewire-pulse wireplumber \
    pipewire-alsa pipewire-jack pavucontrol \
    bluez bluez-utils networkmanager \
    wpa_supplicant dhcpcd \
    fastfetch htop btop iotop \
    nano vim dolphin pciutils \
    waybar kitty wofi \
    xdg-desktop-portal-hyprland
```

}

# ==========================================

# AUR Helper

# ==========================================

setup_aur_helper() {

```
if command -v yay &>/dev/null; then
    return
fi

log_info "Installing yay..."

retry_pacman base-devel git

tmp_dir=$(sudo -u "$REAL_USER" mktemp -d)

sudo -u "$REAL_USER" git clone \
    https://aur.archlinux.org/yay-bin.git \
    "$tmp_dir/yay-bin"

pushd "$tmp_dir/yay-bin"

sudo -u "$REAL_USER" makepkg -si --noconfirm

popd

rm -rf "$tmp_dir"
```

}

install_aur_packages() {

```
if [[ "$REAL_USER" == "root" ]]; then
    log_warn "Skipping AUR packages."
    return
fi

sudo -u "$REAL_USER" yay -S --needed --noconfirm \
    visual-studio-code-bin
```

}

# ==========================================

# GPU Detection

# ==========================================

detect_gpu_and_install_drivers() {

```
log_info "Detecting GPU..."

GPU_INFO=$(lspci | grep -E "VGA|3D")

GPU=$(echo "$GPU_INFO" | tr '[:upper:]' '[:lower:]')

if [[ "$GPU" == *intel* ]]; then

    log_info "Intel GPU detected"

    retry_pacman \
        mesa vulkan-intel \
        intel-media-driver libva-intel-driver

elif [[ "$GPU" == *amd* ]] || [[ "$GPU" == *radeon* ]]; then

    log_info "AMD GPU detected"

    retry_pacman \
        mesa vulkan-radeon \
        lib32-vulkan-radeon \
        libva-mesa-driver

elif [[ "$GPU" == *nvidia* ]]; then

    log_info "NVIDIA GPU detected"

    retry_pacman \
        nvidia-dkms nvidia-utils \
        lib32-nvidia-utils egl-wayland
fi
```

}

# ==========================================

# Enable Services

# ==========================================

setup_services() {

```
log_info "Enabling services..."

services=(
    bluetooth
    NetworkManager
)

for svc in "${services[@]}"; do
    systemctl enable --now "$svc"
done
```

}

# ==========================================

# Main

# ==========================================

main() {

```
check_root

optimize_pacman

setup_wifi

verify_connection

install_base_packages

setup_aur_helper

install_aur_packages

detect_gpu_and_install_drivers

setup_services

log_success "System setup complete."
```

}

main
