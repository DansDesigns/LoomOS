#!/bin/bash
# =============================================================================
# AgentOS Welcome Screen
# Displayed immediately after boot on tty1 before installer launches
# =============================================================================

# Colours
R='\033[0;31m'   # red
O='\033[0;33m'   # orange (dark yellow)
C='\033[0;36m'   # cyan
W='\033[1;37m'   # white bold
G='\033[0;32m'   # green
Y='\033[1;33m'   # yellow bold
D='\033[2m'      # dim
NC='\033[0m'     # reset
BOLD='\033[1m'

# Clear screen and hide cursor
clear
tput civis 2>/dev/null || true

# Terminal width
COLS=$(tput cols 2>/dev/null || echo 80)

# Centre a string
centre() {
    local str="$1"
    local len="${#str}"
    # Strip ANSI for length calc
    local plain=$(echo -e "$str" | sed 's/\x1b\[[0-9;]*m//g')
    local plen="${#plain}"
    local pad=$(( (COLS - plen) / 2 ))
    printf "%${pad}s" ""
    echo -e "$str"
}

# Horizontal rule
hrule() {
    local char="${1:-─}"
    printf "${D}"
    printf '%*s' "$COLS" '' | tr ' ' "$char"
    printf "${NC}\n"
}

echo ""
echo ""
hrule "═"

echo ""
centre "${O}${BOLD}  ▄▄▄   ▄▄▄  ▄▄▄▄▄ ▄▄  ▄▄ ▄▄▄▄▄  ▄▄▄  ▄▄▄${NC}"
centre "${O}${BOLD} ██  █ ██    ██    ███▄██    ██   ██  █ ██${NC}"
centre "${O}${BOLD} ███▀█ ██ ▄▄ █████ ██▀███    ██   ███▀█ ▄▄▄${NC}"
centre "${Y}${BOLD} ▄▄  ▄▄ ▄▄  ▄▄ ▄▄▄▄▄ ▄▄▄▄▄▄${NC}"
centre "${Y}${BOLD} ██  ██ ██  ██ ██    ██${NC}"
centre "${Y}${BOLD} ██████ ██  ██ ████  █████${NC}"
centre "${Y}${BOLD} ██  ██ ████▀  ██       ██${NC}"
centre "${Y}${BOLD} ██  ██  ████  ██████ ████${NC}"

echo ""
centre "${D}Devuan Excalibur · No systemd · Voice-first · Mesh-native${NC}"
echo ""
hrule "═"
echo ""

# System info gathered quickly
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || echo "?")
TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
ARCH=$(uname -m)

# GPU
GPU_INFO="CPU-only"
if lspci 2>/dev/null | grep -qi nvidia; then
    GPU_INFO="NVIDIA"
elif lspci 2>/dev/null | grep -qi 'amd\|radeon'; then
    GPU_INFO="AMD"
elif lspci 2>/dev/null | grep -qi 'intel.*graphics'; then
    GPU_INFO="Intel integrated"
fi

# Boot mode
BOOT_MODE="BIOS"
[[ -d /sys/firmware/efi ]] && BOOT_MODE="UEFI"

# Network
NET_STATUS="${R}no connection${NC}"
if ping -c1 -W2 pkgmaster.devuan.org >/dev/null 2>&1; then
    NET_STATUS="${G}connected${NC}"
fi

# Available disks
DISKS=$(lsblk -d -o NAME,SIZE -n 2>/dev/null | grep -v "loop\|rom\|sr" | \
        awk '{printf "  %-10s %s\n", $1, $2}' || echo "  none detected")

PAD="    "
echo -e "${PAD}${W}Detected hardware${NC}"
echo -e "${PAD}${D}CPU:   ${NC}${C}$CPU_MODEL${NC} (${CPU_CORES} cores)"
echo -e "${PAD}${D}RAM:   ${NC}${C}${TOTAL_RAM_MB}MB${NC}"
echo -e "${PAD}${D}GPU:   ${NC}${C}$GPU_INFO${NC}"
echo -e "${PAD}${D}Arch:  ${NC}${C}$ARCH${NC}"
echo -e "${PAD}${D}Boot:  ${NC}${C}$BOOT_MODE${NC}"
echo -e "${PAD}${D}Net:   ${NC}$NET_STATUS"
echo ""
echo -e "${PAD}${W}Available disks${NC}"
echo -e "${C}${DISKS}${NC}"
echo ""
hrule

echo ""
echo -e "${PAD}${W}What happens next:${NC}"
echo ""
echo -e "${PAD}${G}1.${NC} The installer will ask which disk to install to"
echo -e "${PAD}${G}2.${NC} It detects your hardware and selects the right packages"
echo -e "${PAD}${G}3.${NC} Devuan Excalibur is bootstrapped from the internet"
echo -e "${PAD}${G}4.${NC} AgentOS components are installed (STT, TTS, LLM, mesh)"
echo -e "${PAD}${G}5.${NC} System reboots into AgentOS — say ${O}'computer'${NC} to begin"
echo ""
echo -e "${PAD}${D}Need WiFi? Press Ctrl+C, connect with:${NC}"
echo -e "${PAD}${C}wpa_supplicant -B -i wlan0 -c <(wpa_passphrase SSID PASSWORD)${NC}"
echo -e "${PAD}${C}dhcpcd wlan0${NC}"
echo ""
hrule

echo ""

# If no network, warn and wait
if ! ping -c1 -W2 pkgmaster.devuan.org >/dev/null 2>&1; then
    echo -e "${PAD}${R}${BOLD}WARNING: No network detected.${NC}"
    echo -e "${PAD}The installer requires internet access to download packages."
    echo -e "${PAD}Connect via ethernet or configure WiFi before continuing."
    echo ""
    echo -e "${PAD}Press ${W}Enter${NC} to retry network, or wait 30 seconds to try anyway..."
    read -t 30 -r || true

    # Retry DHCP
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        dhcpcd "$iface" -t 8 2>/dev/null &
    done
    sleep 5
fi

echo -e "${PAD}${Y}${BOLD}Starting installer in 3 seconds...${NC}"
echo -e "${PAD}${D}(Press Ctrl+C to drop to shell)${NC}"
echo ""
sleep 3

# Restore cursor
tput cnorm 2>/dev/null || true

# Hand off to the main installer
exec /usr/local/bin/agentos-install
