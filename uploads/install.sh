#!/bin/bash
# setup.sh
# -----------------------------------------------------------------------------
# AUTOMATED CACHYOS + HYDE + ASUS G14 + NVIDIA BETA SETUP
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
HYDE_REPO="https://github.com/HyDE-Project/HyDE"
# Detect user immediately
if [ "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(ls -1 /home 2>/dev/null | head -n 1 || true)"
fi
TARGET_HOME="$(eval echo "~$TARGET_USER")"
HYDE_DIR="$TARGET_HOME/HyDE"

WALLPAPER_URL="https://files.catbox.moe/toernq.png"
BANNER_URL="https://raw.githubusercontent.com/kmaba/kmaba/main/uploads/banner.png"

CPU_CURVE_AGG="30c:10%,40c:20%,50c:35%,60c:50%,70c:75%,80c:92%,85c:100%"
GPU_CURVE_AGG="30c:15%,40c:25%,50c:40%,60c:55%,70c:78%,80c:94%,85c:100%"

G14_KEY_FPR="8F654886F17D497FEFE3DB448B15A6B0E9A3FA35"
G14_KEY_SHORT="8B15A6B0E9A3FA35"
G14_REPO_NAME="g14"
G14_REPO_SERVER="https://arch.asus-linux.org"

# --- Helper Functions ---

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[✗] %s\033[0m\n' "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Run as root (sudo bash)."; exit 1; fi
}

wait_pacman_lock() {
  lock="/var/lib/pacman/db.lck"
  i=0
  while [ -f "$lock" ]; do
    i=$((i+1))
    [ "$i" -le 60 ] || { err "Pacman lock stuck. Please remove /var/lib/pacman/db.lck"; exit 1; }
    warn "Waiting for pacman lock... ($i/60)"
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
  if su - "$TARGET_USER" -c 'command -v yay >/dev/null 2>&1'; then return 0; fi
  log "Installing yay..."
  pacman_install git base-devel
  build_dir="/tmp/yay-build"
  rm -rf "$build_dir" && mkdir -p "$build_dir"
  chown -R "$TARGET_USER:$TARGET_USER" "$build_dir"
  su - "$TARGET_USER" -c "cd '$build_dir' && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm" || { err "Failed to install yay."; exit 1; }
  rm -rf "$build_dir"
}

# --- PHASE 1: HyDE Installation ---

run_phase_1() {
    log "=== PHASE 1: HyDE Installation ==="
    log "Target User: $TARGET_USER"
    pacman_install git

    if [ -d "$HYDE_DIR" ]; then
        log "HyDE detected. Skipping clone."
    else
        log "Cloning HyDE..."
        su - "$TARGET_USER" -c "git clone --depth 1 '$HYDE_REPO' '$HYDE_DIR'"
    fi

    log "Generating pkg_user.lst..."
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
    warn "IMPORTANT: Allow HyDE to finish, then REBOOT."
    warn "After reboot, RUN THIS SCRIPT AGAIN."
    sleep 3
    chmod +x "$HYDE_DIR/Scripts/install.sh"
    su - "$TARGET_USER" -c "cd '$HYDE_DIR/Scripts' && ./install.sh pkg_user.lst"
    exit 0
}

# --- PHASE 2: Post-Install ---

# [CRITICAL FIX] Run this first to stop 'yay' from asking for passwords and crashing curl pipe
configure_sudoers() {
    log "Configuring Passwordless Sudo (Preventing TTY errors)..."
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/00-installer-temp
    chmod 0440 /etc/sudoers.d/00-installer-temp
    # We will restrict this back to specific commands at the end
}

finalize_sudoers() {
    log "Locking down Sudo permissions..."
    # Replace the "ALL" permission with the specific optimization commands
    echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/cpupower, /usr/bin/systemctl, /usr/bin/iw, /usr/bin/asusctl, /usr/bin/tee" > /etc/sudoers.d/hypr-optimization
    chmod 0440 /etc/sudoers.d/hypr-optimization
    # Remove the temporary wide-open permission
    rm -f /etc/sudoers.d/00-installer-temp
}

ensure_kernel_headers() {
    log "Ensuring Kernel Headers..."
    CURRENT_KERNEL=$(uname -r)
    if [[ "$CURRENT_KERNEL" == *"cachyos"* ]]; then
        pacman_install linux-cachyos-headers
    else
        pacman_install linux-headers
    fi
}

ensure_g14_repo() {
  log "Setting up ASUS-Linux (g14) repo..."
  pacman_install wget gnupg
  if [ -f /etc/pacman.d/gnupg/gpg.conf ] && ! grep -qi 'keyserver' /etc/pacman.d/gnupg/gpg.conf; then
    printf "\nkeyserver hkp://keyserver.ubuntu.com\n" >> /etc/pacman.d/gnupg/gpg.conf
  fi
  if ! pacman-key --list-keys "$G14_KEY_FPR" >/dev/null 2>&1; then
    pacman-key --recv-keys "$G14_KEY_FPR" >/dev/null 2>&1 || {
      wget "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$G14_KEY_SHORT" -O /tmp/g14.sec
      pacman-key -a /tmp/g14.sec
    }
    pacman-key --lsign-key "$G14_KEY_FPR" >/dev/null 2>&1 || true
  fi
  if ! grep -qs "^\[$G14_REPO_NAME\]" /etc/pacman.conf; then
    printf "\n[%s]\nServer = %s\n" "$G14_REPO_NAME" "$G14_REPO_SERVER" >> /etc/pacman.conf
    pacman -Syu --noconfirm
  fi
}

install_nvidia_beta_stack() {
  log "Installing NVIDIA Beta Drivers..."
  install_yay_if_missing
  pacman -Rns --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils opencl-nvidia nvidia-settings 2>/dev/null || true
  su - "$TARGET_USER" -c "yay -S --needed --noconfirm nvidia-beta-dkms nvidia-utils-beta opencl-nvidia-beta lib32-nvidia-utils-beta nvidia-settings-beta" || err "Nvidia Beta install failed."
}

install_app_replacements() {
  log "Swapping Apps..."
  install_yay_if_missing
  pacman -Rns --noconfirm code 2>/dev/null || true
  su - "$TARGET_USER" -c "yay -S --needed --noconfirm visual-studio-code-bin microsoft-edge-stable-bin"
  pacman_install tty-clock cmatrix
}

setup_docker() {
    log "Configuring Docker..."
    pacman_install docker docker-compose
    if ! getent group docker >/dev/null; then groupadd docker; fi
    usermod -aG docker "$TARGET_USER"
    systemctl enable --now docker.service
}

install_fastfetch_config() {
  log "Configuring Fastfetch..."
  FF_DIR="$TARGET_HOME/.config/fastfetch"
  FF_CONF="$FF_DIR/config.jsonc"
  mkdir -p "$FF_DIR"
  su - "$TARGET_USER" -c "curl -fsSL '$BANNER_URL' -o '$FF_DIR/banner.png'"
  if [ ! -f "$FF_CONF" ]; then su - "$TARGET_USER" -c "fastfetch --gen-config"; fi
  if [ -f "$FF_CONF" ]; then
      sed -i 's|"source":.*|"source": "'"$FF_DIR/banner.png"'",|' "$FF_CONF"
      sed -i 's|"type":.*|"type": "image",|' "$FF_CONF"
  fi
  chown -R "$TARGET_USER:$TARGET_USER" "$FF_DIR"
}

create_optimization_scripts() {
  log "Creating Optimization Scripts..."
  # Sudoers handled by finalize_sudoers now

  SCRIPTS_DIR="$TARGET_HOME/.config/hypr/scripts"
  mkdir -p "$SCRIPTS_DIR"

  cat >"$SCRIPTS_DIR/asus-fans-aggressive.sh" <<EOF
#!/bin/bash
CPU_CURVE="$CPU_CURVE_AGG"
GPU_CURVE="$GPU_CURVE_AGG"
if asusctl fan-curve -m Performance -f cpu -D "\$CPU_CURVE" >/dev/null 2>&1; then
  asusctl fan-curve -m Performance -f gpu -D "\$GPU_CURVE" >/dev/null 2>&1
  asusctl fan-curve -m Performance -f cpu -E true >/dev/null 2>&1
  asusctl fan-curve -m Performance -f gpu -E true >/dev/null 2>&1
else
  asusctl fan-curve -m Performance -D "\$CPU_CURVE" >/dev/null 2>&1
  asusctl fan-curve -m Performance -E true >/dev/null 2>&1
fi
EOF
  chmod +x "$SCRIPTS_DIR/asus-fans-aggressive.sh"

  cat >"$SCRIPTS_DIR/net-iface.sh" <<'EOF'
#!/bin/bash
iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl" {print $2;getline}' | xargs)
wifi=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
[ -n "$wifi" ] && echo "$wifi" || echo "$iface"
EOF
  chmod +x "$SCRIPTS_DIR/net-iface.sh"

  cat >"$SCRIPTS_DIR/refresh-monitors.sh" <<'EOF'
#!/bin/bash
monitors=$(hyprctl monitors | grep "Monitor" | awk '{print $2}')
for mon in $monitors; do hyprctl dispatch dpms off "$mon"; done
sleep 2
for mon in $monitors; do hyprctl dispatch dpms on "$mon"; done
EOF
  chmod +x "$SCRIPTS_DIR/refresh-monitors.sh"

  cat >"$SCRIPTS_DIR/mode-gaming.sh" <<EOF
#!/bin/bash
asusctl profile -P Performance || true
$SCRIPTS_DIR/asus-fans-aggressive.sh || true
sudo cpupower frequency-set -g performance || true
command -v nvidia-settings &>/dev/null && nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" || true
wifi=\$($SCRIPTS_DIR/net-iface.sh)
[ -n "\$wifi" ] && sudo iw dev "\$wifi" set power_save off || true
notify-send "Mode" "Ultra Performance Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-gaming.sh"

  cat >"$SCRIPTS_DIR/mode-powersave.sh" <<EOF
#!/bin/bash
asusctl profile -P Quiet || true
sudo cpupower frequency-set -g powersave || true
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost || true
wifi=\$($SCRIPTS_DIR/net-iface.sh)
[ -n "\$wifi" ] && sudo iw dev "\$wifi" set power_save on || true
sudo systemctl stop bluetooth || true
notify-send "Mode" "Battery Saver Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-powersave.sh"

  cat >"$SCRIPTS_DIR/mode-normal.sh" <<EOF
#!/bin/bash
asusctl profile -P Balanced || true
sudo cpupower frequency-set -g schedutil || true
echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost || true
command -v nvidia-settings &>/dev/null && nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0" || true
sudo systemctl start bluetooth || true
notify-send "Mode" "Normal Mode Enabled"
EOF
  chmod +x "$SCRIPTS_DIR/mode-normal.sh"
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/hypr"
}

update_hyprland_conf() {
    log "Updating Hyprland Keybinds..."
    CONF="$TARGET_HOME/.config/hypr/hyprland.conf"
    if [ ! -f "$CONF" ]; then touch "$CONF"; fi

    sed -i '/mode-gaming.sh/d' "$CONF"
    sed -i '/mode-powersave.sh/d' "$CONF"
    sed -i '/mode-normal.sh/d' "$CONF"
    sed -i '/steam --silent/d' "$CONF"
    sed -i '/polkit-gnome/d' "$CONF"

    echo "# --- Setup Script Additions ---" >> "$CONF"
    echo "exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" >> "$CONF"
    echo "exec-once = steam --silent" >> "$CONF"
    echo "bind = SUPER ALT, G, exec, ~/.config/hypr/scripts/mode-gaming.sh" >> "$CONF"
    echo "bind = SUPER ALT, B, exec, ~/.config/hypr/scripts/mode-powersave.sh" >> "$CONF"
    echo "bind = SUPER ALT, N, exec, ~/.config/hypr/scripts/mode-normal.sh" >> "$CONF"
    chown "$TARGET_USER:$TARGET_USER" "$CONF"
}

run_phase_2() {
    log "=== PHASE 2: Post-Install Optimizations ==="
    log "Target User: $TARGET_USER"
    
    # 1. IMMEDIATE FIX: Disable sudo passwords so yay doesn't crash the pipe
    configure_sudoers
    
    ensure_kernel_headers
    pacman -Syu --noconfirm
    ensure_g14_repo
    pacman_install asusctl rog-control-center power-profiles-daemon
    systemctl enable --now power-profiles-daemon.service || true
    pacman_install nvidia-laptop-power-cfg || true
    install_nvidia_beta_stack
    
    for svc in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-powerd; do
        systemctl enable "$svc" 2>/dev/null || true
    done

    install_app_replacements
    install_dev_extras
    setup_docker
    install_fastfetch_config
    create_optimization_scripts
    update_hyprland_conf

    # 2. Security cleanup: Re-lock sudoers
    finalize_sudoers

    log "Downloading Wallpaper..."
    WP_DIR="$TARGET_HOME/.local/share/wallpapers"
    mkdir -p "$WP_DIR"
    su - "$TARGET_USER" -c "curl -fsSL '$WALLPAPER_URL' -o '$WP_DIR/toernq.png'"

    log "====================================================="
    log "              SETUP COMPLETE                         "
    log "====================================================="
    warn "Please REBOOT one last time."
}

# --- Main Execution ---
need_root
if [ -d "$HYDE_DIR" ] && [ -f "$HYDE_DIR/Scripts/install.sh" ]; then
    run_phase_2
else
    run_phase_1
fi