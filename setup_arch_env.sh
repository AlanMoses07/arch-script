#!/usr/bin/env bash
# =============================================================================
# Arch Linux Environment Setup Script
# Connects to Wi-Fi, detects hardware, installs packages & GPU drivers.
# Idempotent — safe to run multiple times.
# =============================================================================
set -euo pipefail

# ── Colour codes ─────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Colour

# ── Wi-Fi configuration ─────────────────────────────────────────────────────
readonly WIFI_CON_NAME="KCG-HOSTELS"
WIFI_IFACE=""  # auto-detected at runtime
readonly WIFI_SSID="KCG-HOSTELS"
readonly WIFI_IDENTITY="22ec06"
readonly WIFI_PASSWORD="kcg@06"

# ── Retry / timeout knobs ───────────────────────────────────────────────────
readonly MAX_CONNECT_RETRIES=3
readonly PING_HOST="google.com"
readonly PING_COUNT=3

# ── Package lists ────────────────────────────────────────────────────────────
BASE_PACKAGES=(
    firefox
    telegram-desktop
    discord
    vlc
    cmake
    git
    sof-firmware
    alsa-firmware
    pipewire
    pipewire-pulse
    wireplumber
    pipewire-alsa
    pavucontrol
    btop
    iotop
    htop
    bluez
    bluez-utils
    networkmanager
    wpa_supplicant
    dhcpcd
    fastfetch
    nano
    vim
    cargo
    gcc
    dolphin
)

AUR_PACKAGES=(
    visual-studio-code-bin
)

AMD_GPU_PACKAGES=(
    xf86-video-amdgpu
    mesa
    vulkan-radeon
    lib32-vulkan-radeon
    libva-mesa-driver
    mesa-vdpau
)

INTEL_GPU_PACKAGES=(
    xorg-server
    xf86-video-intel
    mesa
    lib32-mesa
    vulkan-intel
    lib32-vulkan-intel
    intel-media-driver
    libva-intel-driver
)

NVIDIA_GPU_PACKAGES=(
    nvidia-dkms
    nvidia-utils
    lib32-nvidia-utils
    egl-wayland
)

# =============================================================================
# Logging helpers
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

# =============================================================================
# Root check
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        log_info  "Please re-run with: ${BOLD}sudo $0${NC}"
        exit 1
    fi
}

# =============================================================================
# Step 1 — Wi-Fi connection  (live-USB hardened)
# =============================================================================

# 1a — Unblock Wi-Fi via rfkill
_unblock_wifi() {
    if ! command -v rfkill &>/dev/null; then
        log_info "rfkill not found — skipping unblock step."
        return
    fi

    if rfkill list wifi 2>/dev/null | grep -qi "Soft blocked: yes"; then
        log_info "Wi-Fi is soft-blocked — unblocking…"
        rfkill unblock wifi
        sleep 1
        log_success "Wi-Fi unblocked."
    else
        log_info "Wi-Fi is not rfkill-blocked."
    fi
}

# 1b — Enable NetworkManager Wi-Fi radio
_enable_wifi_radio() {
    local radio_state
    radio_state=$(nmcli radio wifi 2>/dev/null || echo "unknown")

    if [[ "${radio_state}" != "enabled" ]]; then
        log_info "Wi-Fi radio is ${radio_state} — enabling…"
        nmcli radio wifi on
        sleep 1
        log_success "Wi-Fi radio enabled."
    else
        log_info "Wi-Fi radio already enabled."
    fi
}

# 1c — Wait for a Wi-Fi interface to appear, then auto-detect it
_detect_wifi_iface() {
    local attempt max_attempts=10

    for attempt in $(seq 1 "${max_attempts}"); do
        WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
                     | grep ':wifi$' | head -n1 | cut -d: -f1 || true)

        if [[ -n "${WIFI_IFACE}" ]]; then
            log_success "Wi-Fi interface detected: ${WIFI_IFACE}"
            return 0
        fi

        log_info "Waiting for Wi-Fi interface… (${attempt}/${max_attempts})"
        sleep 2
    done

    log_error "No Wi-Fi interface found after ${max_attempts} attempts."
    log_error "Ensure a wireless adapter is connected and its driver is loaded."
    exit 1
}

# 1d — Make sure NetworkManager manages the interface
_ensure_managed() {
    local state
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
            | grep "^${WIFI_IFACE}:" | cut -d: -f2 || true)

    if [[ "${state}" == "unmanaged" ]]; then
        log_info "${WIFI_IFACE} is unmanaged — setting to managed…"
        nmcli device set "${WIFI_IFACE}" managed yes
        sleep 2
        log_success "${WIFI_IFACE} is now managed by NetworkManager."
    else
        log_info "${WIFI_IFACE} state: ${state:-unknown}"
    fi
}

# 1e — Scan for the target SSID before attempting connection
_wait_for_ssid() {
    local attempt max_attempts=5  # 5 × 3s = 15s total

    for attempt in $(seq 1 "${max_attempts}"); do
        log_info "Scanning for SSID '${WIFI_SSID}'… (${attempt}/${max_attempts})"
        nmcli device wifi rescan ifname "${WIFI_IFACE}" 2>/dev/null || true
        sleep 3

        if nmcli -t -f SSID device wifi list ifname "${WIFI_IFACE}" 2>/dev/null \
           | grep -qx "${WIFI_SSID}"; then
            log_success "SSID '${WIFI_SSID}' found."
            return 0
        fi
    done

    log_error "SSID '${WIFI_SSID}' not found after scanning for $((max_attempts * 3))s."
    log_error "Make sure you are within range of the access point."
    exit 1
}

# 1f — Main Wi-Fi setup orchestrator
setup_wifi() {
    log_step "Step 1: Wi-Fi Setup"

    # Prepare hardware / radio
    _unblock_wifi
    _enable_wifi_radio
    _detect_wifi_iface
    _ensure_managed
    _wait_for_ssid

    # Create connection profile if it doesn't exist
    if nmcli -t -f NAME connection show | grep -qx "${WIFI_CON_NAME}"; then
        log_info "Connection '${WIFI_CON_NAME}' already exists — skipping creation."
    else
        log_info "Creating Wi-Fi connection '${WIFI_CON_NAME}' on ${WIFI_IFACE}…"
        nmcli connection add \
            type wifi \
            con-name "${WIFI_CON_NAME}" \
            ifname "${WIFI_IFACE}" \
            ssid "${WIFI_SSID}" \
            wifi-sec.key-mgmt wpa-eap \
            wifi-sec.pmf disable \
            802-11-wireless.cloned-mac-address permanent \
            802-1x.eap peap \
            802-1x.phase1-peapver 0 \
            802-1x.phase2-auth mschapv2 \
            802-1x.system-ca-certs no \
            802-1x.identity "${WIFI_IDENTITY}" \
            802-1x.password "${WIFI_PASSWORD}"
        log_success "Connection profile created."
    fi

    # Activate
    log_info "Activating connection '${WIFI_CON_NAME}'…"
    if nmcli connection up "${WIFI_CON_NAME}"; then
        log_success "Connected to '${WIFI_CON_NAME}'."
    else
        log_warn "Failed to activate connection — will retry during connectivity check."
    fi
}

# =============================================================================
# Step 2 — Verify internet connectivity
# =============================================================================
verify_connection() {
    log_step "Step 2: Connectivity Check"

    local attempt
    for attempt in $(seq 1 "${MAX_CONNECT_RETRIES}"); do
        log_info "Ping attempt ${attempt}/${MAX_CONNECT_RETRIES} → ${PING_HOST}"
        if ping -c "${PING_COUNT}" "${PING_HOST}" &>/dev/null; then
            log_success "Internet connection established."
            return 0
        fi
        log_warn "Ping failed. Retrying connection…"
        nmcli connection up "${WIFI_CON_NAME}" &>/dev/null || true
        sleep 3
    done

    log_error "No internet after ${MAX_CONNECT_RETRIES} attempts. Aborting."
    exit 1
}

# =============================================================================
# Step 3 — GPU detection
# =============================================================================
detect_gpu() {
    log_step "Step 3: GPU Detection"

    local gpu_info=""

    if command -v fastfetch &>/dev/null; then
        log_info "Using fastfetch for GPU detection…"
        gpu_info=$(fastfetch --structure GPU --pipe 2>/dev/null || true)
    fi

    if [[ -z "${gpu_info}" ]]; then
        log_info "Falling back to lspci for GPU detection…"
        gpu_info=$(lspci 2>/dev/null | grep -Ei "VGA|3D" || true)
    fi

    if [[ -z "${gpu_info}" ]]; then
        log_warn "Could not detect any GPU. Skipping driver installation."
        DETECTED_GPU="none"
        return
    fi

    log_info "GPU info: ${gpu_info}"

    # Normalise to lowercase for matching
    local gpu_lower
    gpu_lower=$(echo "${gpu_info}" | tr '[:upper:]' '[:lower:]')

    DETECTED_GPU="none"

    if echo "${gpu_lower}" | grep -q "nvidia"; then
        DETECTED_GPU="nvidia"
        log_info "NVIDIA GPU detected."
    fi
    if echo "${gpu_lower}" | grep -q "amd\|radeon"; then
        DETECTED_GPU="${DETECTED_GPU:+${DETECTED_GPU}+}amd"
        log_info "AMD GPU detected."
    fi
    if echo "${gpu_lower}" | grep -q "intel"; then
        DETECTED_GPU="${DETECTED_GPU:+${DETECTED_GPU}+}intel"
        log_info "Intel GPU detected."
    fi

    if [[ "${DETECTED_GPU}" == "none" ]]; then
        log_warn "GPU vendor not recognised. Skipping driver installation."
    fi
}

# =============================================================================
# Package-install helpers
# =============================================================================

# Return 0 if a package is already installed, 1 otherwise.
is_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Install a list of official packages, skipping those already present.
install_pacman_packages() {
    local -a to_install=()
    for pkg in "$@"; do
        if is_installed "${pkg}"; then
            log_info "  ✔ ${pkg} (already installed)"
        else
            to_install+=("${pkg}")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_info "All packages already installed — nothing to do."
        return 0
    fi

    log_info "Installing ${#to_install[@]} package(s): ${to_install[*]}"
    pacman -S --needed --noconfirm "${to_install[@]}"
    log_success "Pacman packages installed."
}

# Ensure an AUR helper (yay) is available; install it if missing.
ensure_aur_helper() {
    if command -v yay &>/dev/null; then
        log_info "AUR helper 'yay' found."
        AUR_HELPER="yay"
        return
    fi

    if command -v paru &>/dev/null; then
        log_info "AUR helper 'paru' found."
        AUR_HELPER="paru"
        return
    fi

    log_info "No AUR helper found — installing yay…"

    # yay must be built as a non-root user.  Determine a suitable user.
    local build_user="${SUDO_USER:-nobody}"

    local build_dir
    build_dir=$(mktemp -d)
    chmod 777 "${build_dir}"

    pacman -S --needed --noconfirm base-devel git

    su - "${build_user}" -c "
        git clone https://aur.archlinux.org/yay.git '${build_dir}/yay' &&
        cd '${build_dir}/yay' &&
        makepkg -si --noconfirm
    "

    rm -rf "${build_dir}"

    if command -v yay &>/dev/null; then
        log_success "yay installed successfully."
        AUR_HELPER="yay"
    else
        log_error "Failed to install yay. AUR packages will be skipped."
        AUR_HELPER=""
    fi
}

# Install AUR packages via yay/paru, skipping those already present.
install_aur_packages() {
    if [[ -z "${AUR_HELPER:-}" ]]; then
        ensure_aur_helper
    fi

    if [[ -z "${AUR_HELPER:-}" ]]; then
        log_warn "No AUR helper available — skipping AUR packages."
        return
    fi

    local build_user="${SUDO_USER:-nobody}"
    local -a to_install=()

    for pkg in "$@"; do
        if is_installed "${pkg}"; then
            log_info "  ✔ ${pkg} (already installed)"
        else
            to_install+=("${pkg}")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_info "All AUR packages already installed — nothing to do."
        return 0
    fi

    log_info "Installing ${#to_install[@]} AUR package(s): ${to_install[*]}"
    su - "${build_user}" -c "${AUR_HELPER} -S --needed --noconfirm ${to_install[*]}"
    log_success "AUR packages installed."
}

# =============================================================================
# Step 4 — Base package installation
# =============================================================================
install_base_packages() {
    log_step "Step 4: Base Package Installation"

    # Enable multilib repository if not already enabled (needed for lib32-* pkgs)
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        log_info "Enabling [multilib] repository…"
        cat >> /etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi

    log_info "Synchronising package databases…"
    pacman -Sy --noconfirm

    install_pacman_packages "${BASE_PACKAGES[@]}"
    install_aur_packages    "${AUR_PACKAGES[@]}"
}

# =============================================================================
# Step 4b — GPU driver installation
# =============================================================================
install_gpu_drivers() {
    log_step "Step 4b: GPU Driver Installation"

    if [[ "${DETECTED_GPU}" == "none" ]]; then
        log_info "No recognised GPU — skipping driver installation."
        return
    fi

    if [[ "${DETECTED_GPU}" == *"amd"* ]]; then
        log_info "Installing AMD GPU drivers…"
        install_pacman_packages "${AMD_GPU_PACKAGES[@]}"
    fi

    if [[ "${DETECTED_GPU}" == *"intel"* ]]; then
        log_info "Installing Intel GPU drivers…"
        install_pacman_packages "${INTEL_GPU_PACKAGES[@]}"
    fi

    if [[ "${DETECTED_GPU}" == *"nvidia"* ]]; then
        log_info "Installing NVIDIA GPU drivers…"
        install_pacman_packages "${NVIDIA_GPU_PACKAGES[@]}"
    fi

    log_success "GPU drivers installed."
}

# =============================================================================
# Step 5 — Bluetooth & services
# =============================================================================
setup_bluetooth() {
    log_step "Step 5: Bluetooth & Service Setup"

    log_info "Loading btusb kernel module…"
    modprobe btusb || log_warn "Could not load btusb module (may already be loaded)."

    # Persist across reboots
    if [[ ! -f /etc/modules-load.d/btusb.conf ]] || ! grep -qx "btusb" /etc/modules-load.d/btusb.conf; then
        echo "btusb" > /etc/modules-load.d/btusb.conf
        log_info "btusb module set to load on boot."
    fi

    log_info "Enabling bluetooth service…"
    systemctl enable --now bluetooth || log_warn "bluetooth.service could not be started."

    log_info "Enabling NetworkManager service…"
    systemctl enable --now NetworkManager || log_warn "NetworkManager.service could not be started."

    log_success "Services configured."
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     Arch Linux Environment Setup Script      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root

    # Initialise global set by detect_gpu
    DETECTED_GPU="none"
    AUR_HELPER=""

    setup_wifi
    verify_connection
    detect_gpu
    install_base_packages
    install_gpu_drivers
    setup_bluetooth

    echo ""
    log_success "═══ All done! Your Arch Linux environment is ready. ═══"
}

main "$@"