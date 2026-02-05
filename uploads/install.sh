#!/bin/bash
# setup.sh
# -----------------------------------------------------------------------------
# AUTOMATED CACHYOS + HYDE + ASUS G14 + NVIDIA BETA SETUP
# -----------------------------------------------------------------------------
# Phase 1: Installs HyDE with custom package list.
# Phase 2: Runs comprehensive Post-Install (ASUS setup, Nvidia Beta, Optimizations).
#
# Usage: sudo ./setup.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
HYDE_REPO="https://github.com/prasanthrangan/hyprdots"
HYDE_DIR="/home/${SUDO_USER:-$(whoami)}/HyDE"
WALLPAPER_URL="https://files.catbox.moe/toernq.png"
BANNER_URL="https://raw.githubusercontent.com/kmaba/kmaba/main/uploads/banner.png"

# ASUS-Linux G14 Repo Details
G14_KEY_FPR="8F654886F17D497FEFE3DB448B15A6B0E9A3FA35"
G14_KEY_SHORT="8B15A6B0E9A3FA35"
G14_REPO_NAME="g14"
G14_REPO_SERVER="https://arch.asus-linux.org"

# --- Helper Functions ---

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[✗] %s\033[0m\n' "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Run as root (sudo ./setup.sh)."
    exit 1
  fi
}

detect_user() {
  if [ "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  else
    # Fallback if SUDO_USER is empty (rare in sudo)
    TARGET_USER="$(ls -1 /home 2>/dev/null | head -n 1 || true)"
    [ -n "${TARGET_USER:-}" ] || { err "Couldn't detect target user."; exit 1; }
  fi
  TARGET_HOME="$(eval echo "~$TARGET_USER")"
  # Update HYDE_DIR to match detected user
  HYDE_DIR="$TARGET_HOME/HyDE"
  log "Target user: $TARGET_USER ($TARGET_HOME)"
}

wait_pacman_lock() {
  lock="/var/lib/pacman/db.lck"
  i=0
  while [ -f "$lock" ]; do
    i=$((i+1))
    [ "$i" -le 30 ] || { err "Pacman lock stuck: $lock. Please remove it manually."; exit 1; }
    warn "Waiting for pacman lock... ($i/30)"
    sleep 2
  done
}

pacman_install() {
  wait_pacman_lock
  [ "$#" -eq 0 ] && return 0
  log "Installing: $*"
  pacman -S --needed --noconfirm "$@"
}

install_yay_if_missing() {
  if su - "$TARGET_USER" -c 'command -v yay >/dev/null 2>&1'; then
    return 0
  fi
  log "Installing yay..."
  pacman_install git base-devel
  build_dir="/tmp/yay-build"
  rm -rf "$build_dir" && mkdir -p "$build_dir"
  chown -R "$TARGET_USER:$TARGET_USER" "$build_dir"

  su - "$TARGET_USER" -c "
    set -eu
    cd '$build_dir'
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  " || { err "Failed to install yay."; exit 1; }
  rm -rf "$build_dir"
}

# --- PHASE 1: HyDE Installation ---

run_phase_1() {
    log "=== PHASE 1: HyDE Installation ==="
    
    detect_user
    pacman_install git

    if [ -d "$HYDE_DIR" ]; then
        log "HyDE directory detected at $HYDE_DIR. Skipping clone."
    else
        log "Cloning HyDE..."
        su - "$TARGET_USER" -c "git clone --depth 1 '$HYDE_REPO' '$HYDE_DIR'"
    fi

    log "Generating pkg_user.lst..."
    # Note: Corrected ntfs3g to ntfs-3g
    cat > "$HYDE_DIR/Scripts/pkg_user.lst" <<EOF
polkit
polkit-gnome
power-profiles-daemon
asusctl
rog-control-center
steam
discord
prismlauncher
mangohud
gamescope
gamemode
protonup-qt
pavucontrol
blueman
nm-connection-editor
wdisplays
git
base-devel
neovim
python
python-pip
nodejs
npm
docker
docker-compose
discord
proton-vpn-gtk-app
ntfs-3g
EOF
    chown "$TARGET_USER:$TARGET_USER" "$HYDE_DIR/Scripts/pkg_user.lst"

    log "Launching HyDE Installer..."
    warn "---------------------------------------------------------"
    warn "IMPORTANT: The HyDE installer will take over."
    warn "Allow it to finish, then REBOOT YOUR SYSTEM."
    warn "After reboot, RUN THIS SCRIPT AGAIN to apply optimizations."
    warn "---------------------------------------------------------"
    sleep 3

    cd "$HYDE_DIR/Scripts"
    chmod +x install.sh
    # Run as user, HyDE handles sudo internally where needed
    su - "$TARGET_USER" -c "cd '$HYDE_DIR/Scripts' && ./install.sh pkg_user.lst"

    exit 0
}

# --- PHASE 2: Post-Install Logic ---

ensure_kernel_headers() {
    log "Ensuring Kernel Headers (Critical for Nvidia DKMS)"
    # Identify running kernel
    CURRENT_KERNEL=$(uname -r)
    log "Current Kernel: $CURRENT_KERNEL"
    
    # Try to install headers matching the running kernel
    if [[ "$CURRENT_KERNEL" == *"cachyos"* ]]; then
        pacman_install linux-cachyos-headers
    else
        # Fallback generic logic or standard arch
        pacman_install linux-headers
    fi
}

ensure_g14_repo() {
  log "Setting up ASUS-Linux (g14) repo..."
  pacman_install wget gnupg

  # Fix GPG keyserver issues
  if [ -f /etc/pacman.d/gnupg/gpg.conf ] && ! grep -qi 'keyserver' /etc/pacman.d/gnupg/gpg.conf; then
    printf "\nkeyserver hkp://keyserver.ubuntu.com\n" >> /etc/pacman.d/gnupg/gpg.conf
  fi

  if ! pacman-key --list-keys "$G14_KEY_FPR" >/dev/null 2>&1; then
    if ! pacman-key --recv-keys "$G14_KEY_FPR" >/dev/null 2>&1; then
      warn "Standard key recv failed; using wget fallback..."
      tmp="/tmp/g14.sec"
      wget "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$G14_KEY_SHORT" -O "$tmp"
      pacman-key -a "$tmp"
      rm -f "$tmp"
    fi
    pacman-key --lsign-key "$G14_KEY_FPR" >/dev/null 2>&1 || true
  fi

  if ! grep -qs "^\[$G14_REPO_NAME\]" /etc/pacman.conf; then
    printf "\n[%s]\nServer = %s\n" "$G14_REPO_NAME" "$G14_REPO_SERVER" >> /etc/pacman.conf
    log "Repo added to pacman.conf"
    pacman -Syu --noconfirm
  fi
}

install_nvidia_beta_stack() {
  log "Installing NVIDIA Beta Drivers (AUR)..."
  install_yay_if_missing
  
  # 1. Clean up conflicting stock drivers
  if pacman -Qs nvidia > /dev/null; then
    warn "Removing stock/conflicting NVIDIA packages..."
    # We use || true because if one is missing, we don't want to stop the script
    pacman -Rns --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils opencl-nvidia nvidia-settings 2>/dev/null || true
  fi

  # 2. Install Beta Stack (Explicitly including lib32 for Steam)
  log "Building Beta Drivers (This may take a while)..."
  su - "$TARGET_USER" -c "
    set -eu
    yay -S --needed --noconfirm nvidia-beta-dkms nvidia-utils-beta opencl-nvidia-beta lib32-nvidia-utils-beta nvidia-settings-beta
  " || err "Nvidia Beta install failed. Ensure headers are correct."
}

install_app_replacements() {
  log "Swapping Apps (Code -> VSCode Official)..."
  install_yay_if_missing

  if pacman -Qs code >/dev/null; then
    pacman -Rns --noconfirm code 2>/dev/null || true
  fi
  
  su - "$TARGET_USER" -c "yay -S --needed --noconfirm visual-studio-code-bin microsoft-edge-stable-bin"
  
  pacman_install tty-clock cmatrix
}

setup_docker() {
    log "Configuring Docker..."
    pacman_install docker docker-compose
    if ! getent group docker >/dev/null; then
        groupadd docker
    fi
    usermod -aG docker "$TARGET_USER"
    systemctl enable --now docker.service
    log "Docker enabled and user added to group."
}

install_fastfetch_config() {
  log "Configuring Fastfetch..."
  FF_DIR="$TARGET_HOME/.config/fastfetch"
  FF_CONF="$FF_DIR/config.jsonc"
  mkdir -p "$FF_DIR"
  
  # Download Banner
  su - "$TARGET_USER" -c "curl -fsSL '$BANNER_URL' -o '$FF_DIR/banner.png'"
  
  # Generate Config if missing
  if [ ! -f "$FF_CONF" ]; then
    su - "$TARGET_USER" -c "fastfetch --gen-config"
  fi
  
  # Modify Config
  if [ -f "$FF_CONF" ]; then
      # Replace source with image path
      sed -i 's|"source":.*|"source": "'"$FF_DIR/banner.png"'",|' "$FF_CONF"
      # Replace type with image
      sed -i 's|"type":.*|"type": "image",|' "$FF_CONF"
  fi
  chown -R "$TARGET_USER:$TARGET_USER" "$FF_DIR"
}

create_optimization_scripts() {
  log "Creating Optimization Scripts..."
  
  # 1. Sudoers Drop-in (Safety first: strict paths)
  echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/cpupower, /usr/bin/systemctl, /usr/bin/iw, /usr/bin/asusctl, /usr/bin/tee" > /etc/sudoers.d/hypr-optimization
  chmod 0440 /etc/sudoers.d/hypr-optimization

  SCRIPTS_DIR="$TARGET_HOME/.config/hypr/scripts"
  mkdir -p "$SCRIPTS_DIR"

  # 2. Net Interface Helper
  cat >"$SCRIPTS_DIR/net-iface.sh" <<'EOF'
#!/bin/bash
iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl" {print $2;getline}' | xargs)
# Try to find wifi specifically
wifi=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
[ -n "$wifi" ] && echo "$wifi" || echo "$iface"
EOF
  chmod +x "$SCRIPTS_DIR/net-iface.sh"

  # 3. HDMI Hotplug
  cat >"$SCRIPTS_DIR/refresh-monitors.sh" <<'EOF'
#!/bin/bash
# Toggles DPMS to force handshake
monitors=$(hyprctl monitors | grep "Monitor" | awk '{print $2}')
for mon in $monitors; do hyprctl dispatch dpms off "$mon"; done
sleep 2
for mon in $monitors; do hyprctl dispatch dpms on "$mon"; done
EOF
  chmod +x "$SCRIPTS_DIR/refresh-monitors.sh"

  # 4. Ultra Performance (Gaming)
  cat >"$SCRIPTS_DIR/mode-gaming.sh" <<EOF
#!/bin/bash
asusctl profile -P Performance || true
sudo cpupower frequency-set -g performance || true
# Set Nvidia PowerMizer to Max Performance
if command -v nvidia-settings &>/dev/null; then
    nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" || true
fi
# Disable Wifi Power Save
wifi=\$($SCRIPTS_DIR/net-iface.sh)
[ -n "\$wifi" ] && sudo iw dev "\$wifi" set power_save off || true
notify-send "Mode" "Ultra Performance Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-gaming.sh"

  # 5. Battery Saver
  cat >"$SCRIPTS_DIR/mode-powersave.sh" <<EOF
#!/bin/bash
asusctl profile -P Quiet || true
sudo cpupower frequency-set -g powersave || true
# Disable Turbo Boost
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost || true
# Enable Wifi Power Save
wifi=\$($SCRIPTS_DIR/net-iface.sh)
[ -n "\$wifi" ] && sudo iw dev "\$wifi" set power_save on || true
sudo systemctl stop bluetooth || true
notify-send "Mode" "Battery Saver Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-powersave.sh"

  # 6. Normal Mode
  cat >"$SCRIPTS_DIR/mode-normal.sh" <<EOF
#!/bin/bash
asusctl profile -P Balanced || true
sudo cpupower frequency-set -g schedutil || true
echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost || true
if command -v nvidia-settings &>/dev/null; then
    nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0" || true
fi
sudo systemctl start bluetooth || true
notify-send "Mode" "Normal Mode Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-normal.sh"

  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/hypr"
}

update_hyprland_conf() {
    log "Updating Hyprland Keybinds..."
    CONF="$TARGET_HOME/.config/hypr/hyprland.conf"
    
    # Ensure config exists
    if [ ! -f "$CONF" ]; then touch "$CONF"; fi

    # Clean previous entries
    sed -i '/mode-gaming.sh/d' "$CONF"
    sed -i '/mode-powersave.sh/d' "$CONF"
    sed -i '/mode-normal.sh/d' "$CONF"
    sed -i '/steam --silent/d' "$CONF"
    sed -i '/polkit-gnome/d' "$CONF"

    # Append new entries
    echo "# --- Setup Script Additions ---" >> "$CONF"
    echo "exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" >> "$CONF"
    echo "exec-once = steam --silent" >> "$CONF"
    echo "bind = SUPER ALT, G, exec, ~/.config/hypr/scripts/mode-gaming.sh" >> "$CONF"
    echo "bind = SUPER ALT, B, exec, ~/.config/hypr/scripts/mode-powersave.sh" >> "$CONF"
    echo "bind = SUPER ALT, N, exec, ~/.config/hypr/scripts/mode-normal.sh" >> "$CONF"
}

run_phase_2() {
    log "=== PHASE 2: Post-Install Optimizations ==="
    detect_user
    
    # 1. System Prep
    ensure_kernel_headers
    pacman -Syu --noconfirm
    
    # 2. Hardware / Drivers
    ensure_g14_repo
    pacman_install asusctl rog-control-center power-profiles-daemon
    systemctl enable --now power-profiles-daemon.service || true
    
    # Nvidia specific
    pacman_install nvidia-laptop-power-cfg || true # Try repo first
    install_nvidia_beta_stack
    
    # Enable services
    for svc in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-powerd; do
        systemctl enable "$svc" 2>/dev/null || true
    done

    # 3. Applications
    install_app_replacements
    install_dev_extras
    setup_docker

    # 4. Configs
    install_fastfetch_config
    create_optimization_scripts
    update_hyprland_conf

    # 5. Wallpaper (Download Only)
    log "Downloading Wallpaper..."
    WP_DIR="$TARGET_HOME/.local/share/wallpapers"
    mkdir -p "$WP_DIR"
    su - "$TARGET_USER" -c "curl -fsSL '$WALLPAPER_URL' -o '$WP_DIR/toernq.png'"

    log "====================================================="
    log "              SETUP COMPLETE                         "
    log "====================================================="
    warn "Please REBOOT one last time to load the new Kernel Modules (Nvidia Beta)."
    warn "Docker permissions will apply after reboot/logout."
}

install_dev_extras() {
    install_yay_if_missing
    su - "$TARGET_USER" -c "yay -S --needed --noconfirm github-cli"
    if ! su - "$TARGET_USER" -c 'command -v bun >/dev/null 2>&1'; then
        su - "$TARGET_USER" -c "curl -fsSL https://bun.sh/install | bash"
    fi
}

# --- Main Execution ---

need_root
detect_user

# Logic: If HyDE directory exists, assume Phase 1 is done.
if [ -d "$HYDE_DIR" ] && [ -f "$HYDE_DIR/Scripts/install.sh" ]; then
    run_phase_2
else
    run_phase_1
fi