#!/bin/bash
# =============================================================================
# AgentOS Installer — Devuan Excalibur (6.0) base
# =============================================================================
# Run this from any live Linux environment (Debian, Ubuntu, Devuan live USB)
# as root. It will partition a target disk, bootstrap Devuan, install all
# AgentOS components, and produce a bootable system.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/DansDesigns/LoomOS/main/install.sh | bash
#   — or —
#   bash install.sh
#
# The script detects hardware automatically and installs only what is needed.
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ── Configuration (edit or pass as env vars before running) ──────────────────
AGENTOS_REPO="${AGENTOS_REPO:-https://raw.githubusercontent.com/DansDesigns/LoomOS/main}"
DEVUAN_MIRROR="${DEVUAN_MIRROR:-https://pkgmaster.devuan.org/merged}"
DEVUAN_SUITE="${DEVUAN_SUITE:-excalibur}"          # Devuan 6 = excalibur
HOSTNAME="${AGENTOS_HOSTNAME:-agentos}"
USERNAME="${AGENTOS_USER:-agent}"
INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"             # sysvinit | runit | openrc
TTS_ENGINE="${TTS_ENGINE:-kokoro}"                 # kokoro | chatterbox | piper
VOSK_MODEL="${VOSK_MODEL:-vosk-model-en-us-0.22}"  # ~1.8GB accurate model
                                                    # vosk-model-small-en-us-0.15 = 40MB fast
LLM_MODEL="${LLM_MODEL:-hf.co/microsoft/bitnet-b1-58-3B-GGUF}"  # Bonsai 1-bit
INSTALL_FLATPAK="${INSTALL_FLATPAK:-yes}"
INSTALL_QTILE="${INSTALL_QTILE:-yes}"
OS_PART_SIZE="${OS_PART_SIZE:-32G}"                # OS partition size

# ── Sanity checks ─────────────────────────────────────────────────────────────
section "AgentOS Installer — Pre-flight checks"

[[ $EUID -eq 0 ]] || die "Must run as root"
command -v debootstrap >/dev/null 2>&1 || {
    warn "debootstrap not found — installing it now"
    apt-get install -y debootstrap || die "Cannot install debootstrap"
}
command -v lsblk >/dev/null 2>&1    || die "lsblk not found"
command -v parted >/dev/null 2>&1   || apt-get install -y parted
command -v mkfs.ext4 >/dev/null 2>&1 || apt-get install -y e2fsprogs

ping -c1 -W3 pkgmaster.devuan.org >/dev/null 2>&1 \
    || die "No network connectivity to Devuan mirror"

# ── Hardware detection ────────────────────────────────────────────────────────
section "Hardware detection"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  DARCH="amd64" ;;
    aarch64) DARCH="arm64" ;;
    armv7l)  DARCH="armhf" ;;
    i686)    DARCH="i386"  ;;
    *)       die "Unsupported architecture: $ARCH" ;;
esac
info "Architecture: $ARCH → Devuan package arch: $DARCH"

# CPU
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}' || echo "unknown")
CPU_CORES=$(nproc)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
info "CPU: $CPU_MODEL ($CPU_CORES cores, vendor: $CPU_VENDOR)"

# RAM
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
info "RAM: ${TOTAL_RAM_MB}MB (${TOTAL_RAM_GB}GB)"

# GPU detection
HAS_NVIDIA=false; HAS_AMD=false; HAS_INTEL_GPU=false; HAS_GPU=false
if lspci 2>/dev/null | grep -qi 'nvidia'; then
    HAS_NVIDIA=true; HAS_GPU=true
    info "GPU: NVIDIA detected"
fi
if lspci 2>/dev/null | grep -qi 'amd\|radeon\|advanced micro'; then
    HAS_AMD=true; HAS_GPU=true
    info "GPU: AMD detected"
fi
if lspci 2>/dev/null | grep -qi 'intel.*graphics\|intel.*uhd\|intel.*hd graphics'; then
    HAS_INTEL_GPU=true; HAS_GPU=true
    info "GPU: Intel integrated graphics detected"
fi
$HAS_GPU || info "GPU: No discrete GPU detected — CPU-only mode"

# UEFI vs BIOS
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
    info "Boot mode: UEFI"
else
    BOOT_MODE="bios"
    info "Boot mode: Legacy BIOS"
fi

# Wireless
HAS_WIFI=false
if iw dev 2>/dev/null | grep -q Interface || ls /sys/class/net/wl* 2>/dev/null | grep -q wl; then
    HAS_WIFI=true
    info "Wireless: detected"
fi

# Bluetooth
HAS_BT=false
if [[ -d /sys/class/bluetooth ]] || hciconfig 2>/dev/null | grep -q hci; then
    HAS_BT=true
    info "Bluetooth: detected"
fi

# Audio
HAS_AUDIO=false
if aplay -l 2>/dev/null | grep -q 'card\|device\|ALSA'; then
    HAS_AUDIO=true
    info "Audio: ALSA devices detected"
elif [[ -d /proc/asound ]]; then
    HAS_AUDIO=true
    info "Audio: /proc/asound present"
fi

# Touchscreen / tablet input
HAS_TOUCH=false
if xinput list 2>/dev/null | grep -qi 'touch\|stylus\|pen\|wacom'; then
    HAS_TOUCH=true
    info "Input: Touchscreen/stylus detected"
fi

# Laptop detection (has battery?)
IS_LAPTOP=false
if ls /sys/class/power_supply/BAT* 2>/dev/null | grep -q BAT; then
    IS_LAPTOP=true
    info "Form factor: Laptop (battery present)"
fi

# Decide LLM model based on RAM
if [[ $TOTAL_RAM_MB -lt 3000 ]]; then
    warn "Low RAM (${TOTAL_RAM_MB}MB) — using small Vosk model and lightweight LLM"
    VOSK_MODEL="vosk-model-small-en-us-0.15"
    LLM_MODEL="hf.co/microsoft/bitnet-b1-58-2B-GGUF"
    TTS_ENGINE="kokoro"   # lightest option
fi

# Decide TTS based on RAM
if [[ $TOTAL_RAM_MB -ge 8000 ]] && [[ "$TTS_ENGINE" == "kokoro" ]]; then
    TTS_ENGINE="chatterbox"
    info "Sufficient RAM — upgrading TTS to Chatterbox for better voice quality"
fi

# ── Disk selection ────────────────────────────────────────────────────────────
section "Disk selection"

info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk

echo ""
read -rp "$(echo -e "${BOLD}Enter target disk (e.g. sda, nvme0n1, vda):${NC} ")" DISK_NAME
TARGET_DISK="/dev/${DISK_NAME}"
[[ -b "$TARGET_DISK" ]] || die "Block device $TARGET_DISK not found"

DISK_SIZE=$(lsblk -d -o SIZE -n "$TARGET_DISK" | xargs)
warn "ALL DATA on $TARGET_DISK ($DISK_SIZE) will be erased."
read -rp "$(echo -e "${RED}Type 'yes' to confirm:${NC} ")" CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted by user"

# ── Partition layout ──────────────────────────────────────────────────────────
section "Partitioning: $TARGET_DISK"
# Layout:
#   [UEFI] p1 = 512MB EFI  | [BIOS] p1 = 1MB BIOS boot
#   p2 = OS (configurable, default 32G) — Devuan + all software
#   p3 = swap (2x RAM up to 8GB)
#   p4 = mesh storage (remainder) — mounted at /mnt/mesh

SWAP_SIZE_GB=$((TOTAL_RAM_GB > 4 ? 4 : TOTAL_RAM_GB))
[[ $SWAP_SIZE_GB -lt 1 ]] && SWAP_SIZE_GB=1

info "Partition plan:"
info "  1: Boot/EFI   — 512MB"
info "  2: OS (/)     — $OS_PART_SIZE"
info "  3: Swap       — ${SWAP_SIZE_GB}G"
info "  4: Mesh store — remainder of disk"

parted -s "$TARGET_DISK" mklabel gpt

if [[ "$BOOT_MODE" == "uefi" ]]; then
    parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 esp on
    EFI_PART="${TARGET_DISK}1"
    # Handle nvme partition naming (nvme0n1p1 not nvme0n11)
    [[ "$DISK_NAME" == nvme* ]] && EFI_PART="${TARGET_DISK}p1"
else
    parted -s "$TARGET_DISK" mkpart primary 1MiB 2MiB
    parted -s "$TARGET_DISK" set 1 bios_grub on
fi

# Adjust partition numbers and names for nvme vs sata
if [[ "$DISK_NAME" == nvme* ]]; then
    P="p"
else
    P=""
fi

parted -s "$TARGET_DISK" mkpart primary ext4 513MiB "$OS_PART_SIZE"
parted -s "$TARGET_DISK" mkpart primary linux-swap "$OS_PART_SIZE" "$((${OS_PART_SIZE%G} + SWAP_SIZE_GB))G"
parted -s "$TARGET_DISK" mkpart primary ext4 "$((${OS_PART_SIZE%G} + SWAP_SIZE_GB))G" 100%

OS_PART="${TARGET_DISK}${P}2"
SWAP_PART="${TARGET_DISK}${P}3"
MESH_PART="${TARGET_DISK}${P}4"

log "Formatting partitions..."
[[ "$BOOT_MODE" == "uefi" ]] && mkfs.fat -F32 "${TARGET_DISK}${P}1" -n AGENTOS_EFI
mkfs.ext4 -q -L AGENTOS_OS   "$OS_PART"
mkswap    -L AGENTOS_SWAP     "$SWAP_PART"
mkfs.ext4 -q -L AGENTOS_MESH  "$MESH_PART"

# ── Mount target ──────────────────────────────────────────────────────────────
TARGET="/mnt/agentos_install"
mkdir -p "$TARGET"
mount "$OS_PART" "$TARGET"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p "$TARGET/boot/efi"
    mount "${TARGET_DISK}${P}1" "$TARGET/boot/efi"
fi

# ── Debootstrap Devuan Excalibur ──────────────────────────────────────────────
section "Bootstrapping Devuan $DEVUAN_SUITE ($DARCH)"
info "This pulls ~400MB from $DEVUAN_MIRROR — takes 3-8 minutes..."

# Add keyring if not present
if ! apt-key list 2>/dev/null | grep -q devuan; then
    apt-get install -y devuan-keyring 2>/dev/null || \
    apt-get install -y debian-archive-keyring 2>/dev/null || true
fi

debootstrap \
    --arch="$DARCH" \
    --include="apt-transport-https,ca-certificates,curl,gnupg,locales,\
dbus-sysv,elogind,libpam-elogind" \
    --exclude="systemd,systemd-sysv,libsystemd0" \
    "$DEVUAN_SUITE" \
    "$TARGET" \
    "$DEVUAN_MIRROR"

log "Devuan base installed"

# ── chroot setup helper ───────────────────────────────────────────────────────
# All commands from here run inside the new system via chroot
IN_CHROOT="chroot $TARGET"

# Bind mounts for chroot
for fs in proc sys dev dev/pts run; do
    mkdir -p "$TARGET/$fs"
    mount --bind "/$fs" "$TARGET/$fs" 2>/dev/null || mount -t proc proc "$TARGET/proc"
done

# ── APT sources ───────────────────────────────────────────────────────────────
section "Configuring APT sources"
cat > "$TARGET/etc/apt/sources.list" <<EOF
deb $DEVUAN_MIRROR $DEVUAN_SUITE          main contrib non-free non-free-firmware
deb $DEVUAN_MIRROR ${DEVUAN_SUITE}-updates main contrib non-free non-free-firmware
deb $DEVUAN_MIRROR ${DEVUAN_SUITE}-security main contrib non-free non-free-firmware
EOF

$IN_CHROOT apt-get update -q

# ── Locale & timezone ─────────────────────────────────────────────────────────
$IN_CHROOT bash -c "echo 'en_GB.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen"
$IN_CHROOT bash -c "echo 'LANG=en_GB.UTF-8' > /etc/default/locale"
$IN_CHROOT bash -c "ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime"

# ── Hostname & networking ──────────────────────────────────────────────────────
section "System configuration"
echo "$HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF

# fstab
cat > "$TARGET/etc/fstab" <<EOF
# AgentOS fstab
LABEL=AGENTOS_OS    /           ext4  defaults,noatime  0 1
LABEL=AGENTOS_SWAP  none        swap  sw                0 0
LABEL=AGENTOS_MESH  /mnt/mesh   ext4  defaults,noatime  0 2
EOF
[[ "$BOOT_MODE" == "uefi" ]] && \
    echo "LABEL=AGENTOS_EFI   /boot/efi   vfat  umask=0077        0 1" >> "$TARGET/etc/fstab"
mkdir -p "$TARGET/mnt/mesh"

# ── Base system packages ───────────────────────────────────────────────────────
section "Installing base packages"

BASE_PKGS=(
    # Init — no systemd
    sysvinit-core sysvinit-utils
    # Kernel — generic catches most hardware
    linux-image-${DARCH} linux-headers-${DARCH}
    # Firmware — broad coverage
    firmware-linux firmware-linux-nonfree firmware-misc-nonfree
    firmware-realtek firmware-atheros firmware-iwlwifi
    firmware-amd-graphics
    # Bootloader
    grub-pc
    # Core tools
    bash sudo curl wget git nano vim less
    htop lsof strace pciutils usbutils
    net-tools iproute2 iputils-ping dnsutils
    # Python (core of AgentOS)
    python3 python3-pip python3-venv python3-dev
    # Audio — PipeWire (modern, lightweight, no systemd dependency via pipewire-audio)
    pipewire pipewire-audio pipewire-pulse pipewire-alsa
    wireplumber alsa-utils pavucontrol
    # X11 base (needed for Qtile and graphical apps)
    xorg xinit x11-xserver-utils x11-utils
    xdotool xclip xsel
    # Fonts
    fonts-dejavu fonts-liberation fonts-noto
    # Network
    network-manager network-manager-gnome
    wpasupplicant rfkill
    # NFS for mesh storage
    nfs-kernel-server nfs-common
    # Process migration
    criu
    # Compression & utilities
    zip unzip tar rsync
    # Build tools (needed for some Python packages)
    gcc g++ make cmake pkg-config
    libssl-dev libffi-dev libxml2-dev
    # Notification daemon (lightweight, no systemd)
    dunst libnotify-bin
)

# Conditional: NVIDIA
if $HAS_NVIDIA; then
    BASE_PKGS+=(nvidia-driver nvidia-cuda-toolkit)
    info "Adding NVIDIA driver packages"
fi

# Conditional: AMD
if $HAS_AMD; then
    BASE_PKGS+=(firmware-amd-graphics libgl1-mesa-dri mesa-vulkan-drivers)
    info "Adding AMD GPU packages"
fi

# Conditional: Intel GPU
if $HAS_INTEL_GPU; then
    BASE_PKGS+=(intel-media-va-driver-non-free i965-va-driver)
    info "Adding Intel GPU packages"
fi

# Conditional: Laptop extras
if $IS_LAPTOP; then
    BASE_PKGS+=(acpi acpid tlp tlp-rdw powertop laptop-mode-tools)
    info "Adding laptop power management packages"
fi

# Conditional: Bluetooth
if $HAS_BT; then
    BASE_PKGS+=(bluez bluez-tools pulseaudio-module-bluetooth)
    info "Adding Bluetooth packages"
fi

# Conditional: UEFI bootloader swap
if [[ "$BOOT_MODE" == "uefi" ]]; then
    BASE_PKGS=(${BASE_PKGS[@]/grub-pc/grub-efi-${DARCH}})
    BASE_PKGS+=(efibootmgr)
fi

$IN_CHROOT apt-get install -y --no-install-recommends "${BASE_PKGS[@]}"

# ── Flatpak ────────────────────────────────────────────────────────────────────
if [[ "$INSTALL_FLATPAK" == "yes" ]]; then
    section "Installing Flatpak"
    $IN_CHROOT apt-get install -y flatpak
    $IN_CHROOT flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    log "Flatpak + Flathub configured"
fi

# ── Qtile window manager ───────────────────────────────────────────────────────
if [[ "$INSTALL_QTILE" == "yes" ]]; then
    section "Installing Qtile"
    $IN_CHROOT apt-get install -y --no-install-recommends \
        python3-xcb python3-xcffib python3-cairocffi \
        libcairo2-dev libxcb1-dev libxcb-render0-dev \
        python3-dbus python3-psutil
    $IN_CHROOT pip3 install --break-system-packages qtile
    log "Qtile installed"
fi

# ── Python environment for AgentOS ────────────────────────────────────────────
section "Setting up AgentOS Python environment"

$IN_CHROOT python3 -m venv /opt/agentos/venv --system-site-packages

AGENTOS_PIP="$IN_CHROOT /opt/agentos/venv/bin/pip install --quiet"

# Core AgentOS dependencies
$AGENTOS_PIP \
    vosk \
    sounddevice soundfile \
    pyaudio \
    textual rich \
    requests \
    psutil \
    watchdog \
    rapidfuzz \
    python-nmap \
    paramiko \
    dbus-python

log "Core Python dependencies installed"

# ── TTS Engine ────────────────────────────────────────────────────────────────
section "Installing TTS: $TTS_ENGINE"

case "$TTS_ENGINE" in
    kokoro)
        $AGENTOS_PIP kokoro soundfile
        log "Kokoro TTS installed (82M params, ~0.3s latency)"
        ;;
    chatterbox)
        $AGENTOS_PIP chatterbox-tts
        log "Chatterbox TTS installed (0.5B params, higher quality)"
        ;;
    piper)
        $IN_CHROOT apt-get install -y piper-tts 2>/dev/null || \
            $AGENTOS_PIP piper-tts
        log "Piper TTS installed"
        ;;
esac

# ── Ollama (LLM inference server) ─────────────────────────────────────────────
section "Installing Ollama"

$IN_CHROOT bash -c "curl -fsSL https://ollama.com/install.sh | sh"
log "Ollama installed"

# Configure Ollama init script (sysvinit service, no systemd)
cat > "$TARGET/etc/init.d/ollama" <<'INITEOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ollama
# Required-Start:    $network $local_fs
# Required-Stop:     $network $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Ollama LLM server
# Description:       Local LLM inference server for AgentOS
### END INIT INFO

DAEMON=/usr/local/bin/ollama
DAEMON_ARGS="serve"
PIDFILE=/var/run/ollama.pid
LOGFILE=/var/log/ollama.log

case "$1" in
    start)
        echo "Starting Ollama..."
        start-stop-daemon --start --background \
            --pidfile $PIDFILE --make-pidfile \
            --exec $DAEMON -- $DAEMON_ARGS >> $LOGFILE 2>&1
        ;;
    stop)
        echo "Stopping Ollama..."
        start-stop-daemon --stop --pidfile $PIDFILE
        ;;
    restart)
        $0 stop; sleep 1; $0 start
        ;;
    status)
        if [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2>/dev/null; then
            echo "Ollama is running (PID $(cat $PIDFILE))"
        else
            echo "Ollama is not running"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
esac
exit 0
INITEOF
chmod +x "$TARGET/etc/init.d/ollama"
$IN_CHROOT update-rc.d ollama defaults

# ── Vosk STT model ────────────────────────────────────────────────────────────
section "Downloading Vosk STT model: $VOSK_MODEL"

VOSK_URL="https://alphacephei.com/vosk/models/${VOSK_MODEL}.zip"
mkdir -p "$TARGET/opt/agentos/models/vosk"
info "Downloading $VOSK_MODEL (~$([ "$VOSK_MODEL" = "vosk-model-small-en-us-0.15" ] && echo "40MB" || echo "1.8GB"))..."
curl -L "$VOSK_URL" -o "/tmp/vosk_model.zip" || warn "Vosk model download failed — download manually later"
if [[ -f /tmp/vosk_model.zip ]]; then
    unzip -q /tmp/vosk_model.zip -d "$TARGET/opt/agentos/models/vosk/"
    rm /tmp/vosk_model.zip
    log "Vosk model installed at /opt/agentos/models/vosk/$VOSK_MODEL"
fi

# ── AgentOS core files ────────────────────────────────────────────────────────
section "Installing AgentOS core"

mkdir -p "$TARGET/opt/agentos"/{bin,configs,models,logs,mesh}

# Main config
cat > "$TARGET/opt/agentos/configs/agentos.conf" <<CONF
# AgentOS Configuration
# Generated by installer — edit to customise

[core]
hostname        = $HOSTNAME
username        = $USERNAME
init_system     = $INIT_SYSTEM
arch            = $DARCH
has_gpu         = $HAS_GPU
has_nvidia      = $HAS_NVIDIA
has_amd         = $HAS_AMD
total_ram_mb    = $TOTAL_RAM_MB
is_laptop       = $IS_LAPTOP

[voice]
stt_engine      = vosk
stt_model       = /opt/agentos/models/vosk/$VOSK_MODEL
tts_engine      = $TTS_ENGINE
wake_word       = computer
stt_language    = en-us

[llm]
engine          = ollama
model           = $LLM_MODEL
host            = 127.0.0.1
port            = 11434
mesh_inference  = true
context_length  = 4096

[mesh]
enabled         = true
discovery_port  = 7700
rpc_port        = 7701
mesh_mount      = /mnt/mesh
nfs_export      = /mnt/mesh
sync_interval   = 30

[gui]
compositor      = qtile
wallpaper_mode  = agentos_live
launcher        = ulauncher
terminal        = alacritty
start_x_on_boot = true

[packages]
flatpak         = $INSTALL_FLATPAK
apt_backend     = nala
CONF

# Openwakeword init script
cat > "$TARGET/etc/init.d/agentos-voice" <<'INITEOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          agentos-voice
# Required-Start:    $local_fs ollama
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: AgentOS voice pipeline
### END INIT INFO
DAEMON=/opt/agentos/venv/bin/python3
DAEMON_ARGS="/opt/agentos/bin/voice_pipeline.py"
PIDFILE=/var/run/agentos-voice.pid
case "$1" in
    start) start-stop-daemon --start --background \
               --pidfile $PIDFILE --make-pidfile \
               --chuid $AGENTOS_USER \
               --exec $DAEMON -- $DAEMON_ARGS ;;
    stop)  start-stop-daemon --stop --pidfile $PIDFILE ;;
    restart) $0 stop; sleep 1; $0 start ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
exit 0
INITEOF
chmod +x "$TARGET/etc/init.d/agentos-voice"

# Mesh daemon init script
cat > "$TARGET/etc/init.d/agentos-mesh" <<'INITEOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          agentos-mesh
# Required-Start:    $network $local_fs
# Required-Stop:     $network $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: AgentOS mesh network daemon
### END INIT INFO
DAEMON=/opt/agentos/venv/bin/python3
DAEMON_ARGS="/opt/agentos/bin/mesh_daemon.py"
PIDFILE=/var/run/agentos-mesh.pid
case "$1" in
    start) start-stop-daemon --start --background \
               --pidfile $PIDFILE --make-pidfile \
               --exec $DAEMON -- $DAEMON_ARGS ;;
    stop)  start-stop-daemon --stop --pidfile $PIDFILE ;;
    restart) $0 stop; sleep 1; $0 start ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
exit 0
INITEOF
chmod +x "$TARGET/etc/init.d/agentos-mesh"

$IN_CHROOT update-rc.d agentos-mesh defaults

# ── Nala (nicer apt frontend) ──────────────────────────────────────────────────
$IN_CHROOT apt-get install -y nala 2>/dev/null || true

# ── Alacritty terminal ────────────────────────────────────────────────────────
$IN_CHROOT apt-get install -y alacritty 2>/dev/null || \
    $AGENTOS_PIP alacritty 2>/dev/null || \
    $IN_CHROOT apt-get install -y xterm  # fallback

# ── User account ──────────────────────────────────────────────────────────────
section "Creating user: $USERNAME"

$IN_CHROOT useradd -m -s /bin/bash -G audio,video,sudo,plugdev,netdev,bluetooth \
    "$USERNAME" 2>/dev/null || true
echo "$USERNAME:agentos" | $IN_CHROOT chpasswd
warn "Default password is 'agentos' — change it on first boot with: passwd"

# Auto-start X on login for the agent user
cat >> "$TARGET/home/$USERNAME/.bash_profile" <<'BASHEOF'
# Start Qtile automatically if on tty1 and X not already running
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx /opt/agentos/bin/start_agentos.sh
fi
BASHEOF

# Qtile config stub — full config delivered by agentos repo
mkdir -p "$TARGET/home/$USERNAME/.config/qtile"
cat > "$TARGET/home/$USERNAME/.config/qtile/config.py" <<'QTEOF'
# AgentOS Qtile config — minimal bootstrap
# Full config pulled from /opt/agentos/configs/qtile_config.py on first run
import subprocess, os
from libqtile import bar, layout, widget, hook
from libqtile.config import Click, Drag, Group, Key, Match, Screen
from libqtile.lazy import lazy

mod = "mod4"
terminal = "alacritty"

keys = [
    Key([mod], "Return", lazy.spawn(terminal)),
    Key([mod], "q", lazy.window.kill()),
    Key([mod, "shift"], "r", lazy.reload_config()),
    Key([mod], "space", lazy.spawn("ulauncher")),
]

groups = [Group(str(i)) for i in range(1, 6)]
for g in groups:
    keys += [
        Key([mod], g.name, lazy.group[g.name].toscreen()),
        Key([mod, "shift"], g.name, lazy.window.togroup(g.name)),
    ]

layouts = [
    layout.MonadTall(border_width=2, border_focus="#FF6600",
                     border_normal="#1a1a2e", margin=8),
    layout.Max(),
]

screens = [
    Screen(
        bottom=bar.Bar([
            widget.GroupBox(active="#FF6600", inactive="#666688",
                           this_current_screen_border="#FF6600"),
            widget.Sep(),
            widget.WindowName(foreground="#99AAFF"),
            widget.Spacer(),
            widget.CPU(format="CPU {load_percent}%", foreground="#FF9900"),
            widget.Sep(),
            widget.Memory(format="RAM {MemUsed:.0f}M", foreground="#CC88FF"),
            widget.Sep(),
            widget.Clock(format="%H:%M  %d/%m/%Y", foreground="#99CCFF"),
            widget.Sep(),
            widget.TextBox("AgentOS", foreground="#FF6600"),
        ], 28, background="#0d0d1a"),
    )
]

@hook.subscribe.startup_once
def autostart():
    subprocess.Popen(["/opt/agentos/bin/start_services.sh"])

mouse = [
    Drag([mod], "Button1", lazy.window.set_position_floating()),
    Drag([mod], "Button3", lazy.window.set_size_floating()),
]

dgroups_key_binder = None
follow_mouse_focus = True
bring_front_click = False
cursor_warp = False
floating_layout = layout.Floating()
auto_fullscreen = True
focus_on_window_activation = "smart"
QTEOF

$IN_CHROOT chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

# ── Bootloader ────────────────────────────────────────────────────────────────
section "Installing bootloader"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    $IN_CHROOT grub-install --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=AgentOS \
        --recheck
else
    $IN_CHROOT grub-install --target=i386-pc \
        --recheck \
        "$TARGET_DISK"
fi

cat >> "$TARGET/etc/default/grub" <<'GRUBEOF'
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 vt.global_cursor_default=0"
GRUB_DISTRIBUTOR="AgentOS"
GRUBEOF

$IN_CHROOT update-grub
log "Bootloader installed"

# ── NFS exports for mesh storage ───────────────────────────────────────────────
section "Configuring mesh storage (NFS)"

cat > "$TARGET/etc/exports" <<NFSEOF
# AgentOS mesh storage — shared with all mesh nodes
# Edit to restrict to specific IPs if desired
/mnt/mesh  *(rw,sync,no_subtree_check,no_root_squash)
NFSEOF
log "NFS exports configured — mesh storage will be shared on first boot"

# ── Summary ────────────────────────────────────────────────────────────────────
section "Installation complete"

log "AgentOS (Devuan $DEVUAN_SUITE) installed successfully"
echo ""
echo -e "  ${BOLD}Hardware profile:${NC}"
echo -e "    CPU:    $CPU_MODEL"
echo -e "    RAM:    ${TOTAL_RAM_MB}MB"
echo -e "    GPU:    $(${HAS_GPU} && echo "yes" || echo "CPU-only")"
echo -e "    Boot:   $BOOT_MODE"
echo -e "    Laptop: $(${IS_LAPTOP} && echo "yes" || echo "no")"
echo -e "    WiFi:   $(${HAS_WIFI} && echo "detected" || echo "not detected")"
echo ""
echo -e "  ${BOLD}Installed:${NC}"
echo -e "    Base OS:   Devuan $DEVUAN_SUITE ($DARCH)"
echo -e "    Init:      $INIT_SYSTEM (no systemd)"
echo -e "    STT:       Vosk ($VOSK_MODEL)"
echo -e "    TTS:       $TTS_ENGINE"
echo -e "    LLM:       Ollama + $LLM_MODEL"
echo -e "    Desktop:   Qtile"
echo -e "    Flatpak:   $INSTALL_FLATPAK"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. Reboot: ${CYAN}reboot${NC}"
echo -e "    2. Login as ${CYAN}$USERNAME${NC} (password: agentos)"
echo -e "    3. Change password: ${CYAN}passwd${NC}"
echo -e "    4. Pull LLM model: ${CYAN}ollama pull $LLM_MODEL${NC}"
echo -e "    5. Say ${CYAN}'computer'${NC} to activate voice control"
echo ""
warn "Remove the live USB before rebooting"

# ── Cleanup ────────────────────────────────────────────────────────────────────
for fs in dev/pts dev proc sys run; do
    umount "$TARGET/$fs" 2>/dev/null || true
done
[[ "$BOOT_MODE" == "uefi" ]] && umount "$TARGET/boot/efi" 2>/dev/null || true
umount "$TARGET" 2>/dev/null || true

log "Done. Safe to reboot."
