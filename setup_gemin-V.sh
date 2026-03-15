#!/usr/bin/env bash

# Enforce strict mode
set -euo pipefail

# ==========================================
# Colors & Logging Output
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==========================================
# Globals
# ==========================================
# Identify the real user calling sudo (needed for AUR helper 'yay')
REAL_USER="${SUDO_USER:-$USER}"

# ==========================================
# Step 0: Privilege Check
# ==========================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run with sudo/root privileges."
        echo -e "Please rerun using: ${YELLOW}sudo $0${NC}"
        exit 1
    fi

    if [[ "$REAL_USER" == "root" ]]; then
        log_warn "You are logged in directly as root. AUR helpers (yay) refuse to run as root."
        log_warn "AUR packages (like visual-studio-code-bin) will be skipped."
    fi
}

# ==========================================
# Step 1: Connect to WiFi (Live USB Friendly)
# ==========================================
setup_wifi() {
    local con_name="KCG-HOSTELS"
    local WIFI_IFACE=""
    
    log_info "Ensuring Wi-Fi is unblocked and enabled..."
    
    if command -v rfkill &>/dev/null; then
        rfkill unblock wifi
    fi
    
    nmcli radio wifi on
    
    log_info "Waiting for Wi-Fi interface to become available..."
    local attempt=1
    while [[ $attempt -le 10 ]]; do
        WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device | grep wifi | cut -d: -f1 | head -n 1)
        if [[ -n "$WIFI_IFACE" ]]; then
            break
        fi
        sleep 2
        ((attempt++))
    done
    
    if [[ -z "$WIFI_IFACE" ]]; then
        log_error "No Wi-Fi interface detected after waiting. Exiting."
        exit 1
    fi
    
    log_info "Detected Wi-Fi interface: $WIFI_IFACE"
    
    if nmcli -t -f DEVICE,STATE device | grep -q "^${WIFI_IFACE}:unmanaged$"; then
        log_info "Setting $WIFI_IFACE to managed state..."
        nmcli device set "$WIFI_IFACE" managed yes
        sleep 2
    fi
    
    log_info "Scanning for SSID $con_name..."
    local scan_attempt=1
    local ssid_found=false
    while [[ $scan_attempt -le 8 ]]; do
        nmcli device wifi rescan ifname "$WIFI_IFACE" &>/dev/null || true
        sleep 2
        if nmcli -t -f SSID device wifi list ifname "$WIFI_IFACE" | grep -qx "$con_name"; then
            ssid_found=true
            break
        fi
        ((scan_attempt++))
    done
    
    if [[ "$ssid_found" == false ]]; then
        log_error "SSID $con_name not found"
        exit 1
    fi
    
    log_info "Checking WiFi configuration..."
    if nmcli connection show "$con_name" &>/dev/null; then
        log_info "Connection '$con_name' already exists. Updating interface and skipping creation."
        nmcli connection modify "$con_name" connection.interface-name "$WIFI_IFACE"
    else
        log_info "Creating WiFi connection '$con_name' on interface '$WIFI_IFACE'..."
        nmcli connection add \
            type wifi \
            con-name "$con_name" \
            ifname "$WIFI_IFACE" \
            ssid "$con_name" \
            wifi-sec.key-mgmt wpa-eap \
            wifi-sec.pmf disable \
            802-11-wireless.cloned-mac-address permanent \
            802-1x.eap peap \
            802-1x.phase1-peapver 0 \
            802-1x.phase2-auth mschapv2 \
            802-1x.system-ca-certs no \
            802-1x.identity "22ec06" \
            802-1x.password "kcg@06" || {
                log_error "Failed to create WiFi connection via nmcli."
                exit 1
            }
    fi

    log_info "Connecting to $con_name..."
    set +e
    nmcli connection up "$con_name" >/dev/null 2>&1
    set -e
}

# ==========================================
# Step 2: Validate Internet Connection
# ==========================================
verify_connection() {
    local max_retries=3
    local attempt=1
    
    while [[ $attempt -le $max_retries ]]; do
        log_info "Verifying internet connectivity (Attempt $attempt of $max_retries)..."
        
        # Disable exit on error for ping check
        set +e
        ping -c 3 google.com &>/dev/null
        local ping_status=$?
        set -e
        
        if [[ $ping_status -eq 0 ]]; then
            log_success "Internet connection established"
            return 0
        fi
        
        log_warn "Ping failed. Retrying connection to KCG-HOSTELS..."
        set +e
        nmcli connection up "KCG-HOSTELS" >/dev/null 2>&1
        set -e
        
        sleep 5
        ((attempt++))
    done
    
    log_error "Failed to establish internet connectivity after $max_retries attempts. Exiting."
    exit 1
}

# ==========================================
# Package Installation Helpers
# ==========================================
install_batch() {
    local packages=("$@")
    local missing_pkgs=()

    for pkg in "${packages[@]}"; do
        # Requirement: Check if package already installed using pacman -Qi
        if pacman -Qi "$pkg" &>/dev/null; then
            continue
        else
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing packages: ${missing_pkgs[*]}"
        pacman -S --needed --noconfirm "${missing_pkgs[@]}"
    fi
}

setup_aur_helper() {
    if command -v yay &>/dev/null; then
        return 0
    fi

    log_info "Installing 'yay' (AUR helper)..."
    install_batch "base-devel" "git"

    if [[ "$REAL_USER" == "root" ]]; then
        log_error "Cannot compile yay as root user. Skipping AUR setup."
        return 1
    fi

    local tmp_dir
    tmp_dir=$(sudo -u "$REAL_USER" mktemp -d)
    
    sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay-bin.git "$tmp_dir/yay-bin" >/dev/null 2>&1
    
    pushd "$tmp_dir/yay-bin" >/dev/null
    sudo -u "$REAL_USER" makepkg -si --noconfirm >/dev/null 2>&1
    popd >/dev/null
    
    rm -rf "$tmp_dir"
    log_success "'yay' installed successfully."
}

install_aur_batch() {
    local packages=("$@")
    local missing_pkgs=()

    for pkg in "${packages[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            continue
        else
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        if [[ "$REAL_USER" == "root" ]]; then
            log_error "Cannot install AUR packages as root. Skipping: ${missing_pkgs[*]}"
            return 1
        fi
        log_info "Installing AUR packages: ${missing_pkgs[*]}"
        sudo -u "$REAL_USER" yay -S --noconfirm "${missing_pkgs[@]}"
    fi
}

# ==========================================
# Step 4: Base Package Installation
# ==========================================
install_base_packages() {
    log_info "Installing base packages..."
    
    # Pre-flight check: ensure pacman DB is synchronized
    pacman -Syu --needed --noconfirm >/dev/null 2>&1 || true

    # Core official packages 
    # (Note: 'telegram' is mapped to 'telegram-desktop' in official Arch repos, 
    # and 'NetworkManager' is typically matched to 'networkmanager')
    local base_pkgs=(
        firefox telegram-desktop discord vlc cmake git 
        sof-firmware alsa-firmware pipewire pipewire-pulse 
        pipewire-jack wireplumber pipewire-alsa pavucontrol 
        btop iotop htop bluez bluez-utils networkmanager 
        wpa_supplicant dhcpcd fastfetch nano vim cargo gcc dolphin pciutils
        waybar kitty wofi xdg-desktop-portal-hyprland
    )
    
    install_batch "${base_pkgs[@]}"

    setup_aur_helper

    local aur_pkgs=(visual-studio-code-bin)
    install_aur_batch "${aur_pkgs[@]}"
}

# ==========================================
# Step 3: Detect Hardware (GPU)
# ==========================================
detect_gpu_and_install_drivers() {
    log_info "Detecting GPU..."
    local gpu_info=""
    
    # Primary detection: fastfetch
    if command -v fastfetch &>/dev/null; then
        set +e
        gpu_info=$(fastfetch --gpu 2>/dev/null)
        set -e
    fi
    
    # Fallback detection: lspci
    if [[ -z "$gpu_info" ]]; then
        set +e
        gpu_info=$(lspci | grep -E "VGA|3D")
        set -e
    fi
    
    # Convert to lowercase for easier matching
    local gpu_lower
    gpu_lower=$(echo "$gpu_info" | tr '[:upper:]' '[:lower:]')
    
    local amd_pkgs=(xf86-video-amdgpu mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver mesa-vdpau)
    local intel_pkgs=(xorg-server xf86-video-intel mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver libva-intel-driver)
    local nvidia_pkgs=(nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland)
    
    if [[ "$gpu_lower" == *amd* ]] || [[ "$gpu_lower" == *radeon* ]]; then
        log_info "AMD GPU detected"
        log_info "Installing GPU drivers..."
        install_batch "${amd_pkgs[@]}"
        
    elif [[ "$gpu_lower" == *intel* ]]; then
        log_info "Intel GPU detected"
        log_info "Installing GPU drivers..."
        install_batch "${intel_pkgs[@]}"
        
    elif [[ "$gpu_lower" == *nvidia* ]]; then
        log_info "NVIDIA GPU detected"
        log_info "Installing GPU drivers..."
        install_batch "${nvidia_pkgs[@]}"
        
    else
        log_warn "No recognized GPU (AMD/Intel/NVIDIA) detected. Skipping driver installation."
    fi
}

# ==========================================
# Step 5: Setup Bluetooth & Services
# ==========================================
setup_bluetooth() {
    log_info "Configuring Bluetooth and System Services..."
    
    set +e
    modprobe btusb
    local btusb_status=$?
    set -e
    
    if [[ $btusb_status -ne 0 ]]; then
        log_warn "Failed to load btusb kernel module automatically."
    fi
    
    log_info "Enabling services..."
    systemctl enable --now bluetooth || log_warn "Failed to enable Bluetooth service."
    systemctl enable --now NetworkManager || log_warn "Failed to enable NetworkManager service."
}

# ==========================================
# Main Execution
# ==========================================
main() {
    check_root
    
    # Steps 1 & 2
    setup_wifi
    verify_connection
    
    # Step 4 (Execute before Step 3 so fastfetch and pciutils are available)
    install_base_packages
    
    # Step 3
    detect_gpu_and_install_drivers
    
    # Step 5
    setup_bluetooth
    
    log_success "Setup completed"
}

# Run script
main
