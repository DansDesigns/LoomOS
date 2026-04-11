#!/bin/bash
# =============================================================================
# LoomOS ISO Builder
# =============================================================================
# Builds a bootable hybrid BIOS+UEFI installer ISO from scratch.
# No base ISO needed. Output boots directly into the LoomOS installer.
#
# Repository: https://github.com/DansDesigns/LoomOS
#
# Requirements (installed automatically if missing):
#   xorriso, cpio, busybox-static, debootstrap
#
# Usage:
#   chmod +x build-iso.sh
#   sudo ./build-iso.sh
#
# Output: loomos-installer-YYYY-MM-DD.iso (~25MB)
# Write:  dd if=loomos-installer-*.iso of=/dev/sdX bs=4M status=progress
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIG
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
ISO_OUTPUT="loomos-installer-$(date +%Y-%m-%d).iso"
ISO_LABEL="LOOMOS_INST"
WORK="/tmp/loomos_iso_build"
INITRD_DIR="$WORK/initramfs"
ISO_DIR="$WORK/iso"
KVER=""         # set after kernel install
VMLINUZ=""      # set after kernel install

# =============================================================================
# COLOURS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[+]${NC} $*"; }
info()    { echo -e "${CYAN}[i]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# =============================================================================
# PREFLIGHT
# =============================================================================
section "LoomOS ISO Builder"

[[ $EUID -eq 0 ]] || die "Must run as root: sudo ./build-iso.sh"
[[ -f "$INSTALL_SCRIPT" ]] || die "install.sh not found in $SCRIPT_DIR"

# Install required tools
PKGS_NEEDED=()
for pkg in xorriso cpio busybox-static isolinux syslinux-common \
           grub-pc-bin grub-efi-amd64-bin mtools debootstrap \
           binutils dosfstools; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || PKGS_NEEDED+=("$pkg")
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "Installing: ${PKGS_NEEDED[*]}"
    apt-get install -y "${PKGS_NEEDED[@]}" \
        || die "Could not install required packages"
fi

# Verify critical files
[[ -f /usr/lib/ISOLINUX/isolinux.bin ]]            || die "isolinux.bin not found"
[[ -f /usr/lib/ISOLINUX/isohdpfx.bin ]]            || die "isohdpfx.bin not found"
[[ -f /usr/lib/syslinux/modules/bios/ldlinux.c32 ]] || die "ldlinux.c32 not found"
[[ -f /usr/bin/busybox ]]                           || die "busybox not found"

log "All tools present"

# =============================================================================
# KERNEL — install linux-image-amd64 and extract vmlinuz
# =============================================================================
section "Acquiring Kernel"

# Fix debootstrap for excalibur if needed
if [[ ! -f /usr/share/debootstrap/scripts/excalibur ]]; then
    if [[ -f /usr/share/debootstrap/scripts/trixie ]]; then
        ln -sf /usr/share/debootstrap/scripts/trixie \
               /usr/share/debootstrap/scripts/excalibur
        log "debootstrap: excalibur → trixie symlink created"
    fi
fi

# Install kernel package if not already present
if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
    info "Installing kernel package..."
    apt-get install -y --no-install-recommends linux-image-amd64 \
        || apt-get install -y --no-install-recommends linux-image-generic \
        || die "Could not install kernel package"
fi

# Find the newest vmlinuz
VMLINUZ=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1)
[[ -f "$VMLINUZ" ]] || die "No vmlinuz found in /boot after kernel install"
KVER=$(basename "$VMLINUZ" | sed 's/vmlinuz-//')
info "Kernel: $KVER"
info "vmlinuz: $VMLINUZ"

# =============================================================================
# WORKSPACE
# =============================================================================
section "Building Initramfs"

rm -rf "$WORK"

# ISO directory structure
mkdir -p "$ISO_DIR/boot/isolinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/boot"

# Initramfs directory structure
for d in bin sbin etc proc sys dev tmp run mnt newroot \
         usr/bin usr/sbin lib lib64 var/log \
         "lib/modules/$KVER"; do
    mkdir -p "$INITRD_DIR/$d"
done

# =============================================================================
# BUSYBOX — static binary, provides entire userland
# =============================================================================
BUSYBOX_BIN=$(find /usr -name "busybox" -type f 2>/dev/null | head -1)
[[ -f "$BUSYBOX_BIN" ]] || die "busybox binary not found"

cp "$BUSYBOX_BIN" "$INITRD_DIR/bin/busybox"
chmod +x "$INITRD_DIR/bin/busybox"

# Create symlinks for every applet busybox provides
for applet in $("$BUSYBOX_BIN" --list 2>/dev/null); do
    # Put in bin unless it's traditionally in sbin
    case "$applet" in
        blkid|fdisk|fsck|getty|halt|ifconfig|init|insmod|ip|\
        klogd|losetup|lsmod|mdev|mkdosfs|mkfs*|mkswap|modprobe|\
        pivot_root|poweroff|reboot|rmmod|route|runlevel|start-stop-daemon|\
        sulogin|swapoff|swapon|switch_root|syslogd|udhcpd|uevent)
            ln -sf /bin/busybox "$INITRD_DIR/sbin/$applet" 2>/dev/null || true
            ;;
        *)
            ln -sf /bin/busybox "$INITRD_DIR/bin/$applet"  2>/dev/null || true
            ;;
    esac
done

log "Busybox installed ($(ls "$INITRD_DIR/bin/" | wc -l) applets)"

# =============================================================================
# KERNEL MODULES — copy essential drivers for broad hardware support
# =============================================================================
info "Copying kernel modules..."

KMOD_SRC="/lib/modules/$KVER"

if [[ -d "$KMOD_SRC" ]]; then
    # Copy modules needed to boot and find storage on most hardware
    ESSENTIAL_MODS=(
        "kernel/fs/ext4"
        "kernel/fs/jbd2"
        "kernel/fs/fat"
        "kernel/fs/nls"
        "kernel/drivers/ata"
        "kernel/drivers/nvme/host"
        "kernel/drivers/mmc"
        "kernel/drivers/usb/host"
        "kernel/drivers/usb/storage"
        "kernel/drivers/net/ethernet/intel"
        "kernel/drivers/net/ethernet/realtek"
        "kernel/drivers/net/ethernet/broadcom"
        "kernel/net/ipv4"
        "kernel/lib"
    )

    for mod_dir in "${ESSENTIAL_MODS[@]}"; do
        src="$KMOD_SRC/$mod_dir"
        dst="$INITRD_DIR/lib/modules/$KVER/$mod_dir"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            cp -a "$src/." "$dst/" 2>/dev/null || true
        fi
    done

    # Copy module metadata files
    for f in modules.dep modules.dep.bin modules.alias modules.alias.bin \
              modules.order modules.builtin modules.builtin.bin \
              modules.symbols modules.symbols.bin; do
        [[ -f "$KMOD_SRC/$f" ]] && cp "$KMOD_SRC/$f" \
            "$INITRD_DIR/lib/modules/$KVER/$f" 2>/dev/null || true
    done

    log "Kernel modules copied ($(du -sh "$INITRD_DIR/lib/modules" | cut -f1))"
else
    warn "No kernel modules found for $KVER — hardware support will be limited"
fi

# =============================================================================
# NETWORK TOOLS — wget and udhcpc are in busybox, but we need resolv.conf
# =============================================================================
cat > "$INITRD_DIR/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

cat > "$INITRD_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
EOF

# udhcpc script — busybox udhcpc needs this to actually set IP
mkdir -p "$INITRD_DIR/usr/share/udhcpc"
cat > "$INITRD_DIR/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ;;
    bound|renew)
        ip addr add "$ip/$mask" dev "$interface" 2>/dev/null || \
            ifconfig "$interface" "$ip" netmask "$subnet" 2>/dev/null
        [ -n "$router" ] && ip route add default via "$router" 2>/dev/null || \
            route add default gw "$router" 2>/dev/null
        echo "nameserver $dns" > /etc/resolv.conf 2>/dev/null
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        ;;
esac
exit 0
EOF
chmod +x "$INITRD_DIR/usr/share/udhcpc/default.script"

# =============================================================================
# EMBED THE INSTALLER SCRIPT
# =============================================================================
cp "$INSTALL_SCRIPT" "$INITRD_DIR/install.sh"
chmod +x "$INITRD_DIR/install.sh"
log "install.sh embedded"

# =============================================================================
# /init — THE ENTRY POINT
# This is what the kernel runs first. It sets up the environment
# then launches our installer. devtmpfs populates /dev automatically.
# =============================================================================
cat > "$INITRD_DIR/init" <<'INITEOF'
#!/bin/sh
# LoomOS initramfs /init
# Sets up minimal environment then launches installer

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential virtual filesystems
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || \
    mount -t tmpfs tmpfs /dev

# Create essential /dev entries if devtmpfs didn't provide them
[ -c /dev/console ]  || mknod /dev/console  c 5 1
[ -c /dev/null ]     || mknod /dev/null     c 1 3
[ -c /dev/zero ]     || mknod /dev/zero     c 1 5
[ -c /dev/tty ]      || mknod /dev/tty      c 5 0
[ -c /dev/tty1 ]     || mknod /dev/tty1     c 4 1
[ -c /dev/urandom ]  || mknod /dev/urandom  c 1 9
[ -c /dev/random ]   || mknod /dev/random   c 1 8

mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Set hostname
hostname loomos-install 2>/dev/null || true

# Load essential kernel modules
for mod in ext4 vfat fat nls_cp437 nls_iso8859_1 \
           usb_storage xhci_hcd ehci_hcd uhci_hcd \
           ahci libata sd_mod nvme nvme_core \
           e1000 e1000e r8169 igb ixgbe \
           virtio_net virtio_blk virtio_pci; do
    modprobe "$mod" 2>/dev/null || true
done

# Give hardware time to settle
sleep 2

# Set up network on all interfaces
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
    ip link set "$iface" up 2>/dev/null || \
        ifconfig "$iface" up 2>/dev/null || true
done

# Try DHCP on ethernet interfaces (background, non-blocking)
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|en|em|eno|ens|enp)'); do
    udhcpc -i "$iface" -t 8 -q -n \
        -s /usr/share/udhcpc/default.script \
        2>/dev/null &
done
# Brief wait for at least one interface to get an address
sleep 4

# Clear screen and launch installer
clear
exec /install.sh

# If installer exits, drop to shell
echo ""
echo "Installer exited. Dropping to shell."
echo "Run /install.sh to restart installer."
exec /bin/sh
INITEOF
chmod +x "$INITRD_DIR/init"

log "/init written"

# =============================================================================
# PACK INITRAMFS
# =============================================================================
info "Packing initramfs..."

INITRD_IMG="$ISO_DIR/boot/initrd.img"

cd "$INITRD_DIR"
find . | cpio -H newc -o --quiet 2>/dev/null | gzip -9 > "$INITRD_IMG"
cd - >/dev/null

INITRD_SIZE=$(du -sh "$INITRD_IMG" | cut -f1)
log "Initramfs packed: $INITRD_SIZE"

# =============================================================================
# KERNEL INTO ISO
# =============================================================================
cp "$VMLINUZ" "$ISO_DIR/boot/vmlinuz"
VMLINUZ_SIZE=$(du -sh "$ISO_DIR/boot/vmlinuz" | cut -f1)
log "Kernel copied: $VMLINUZ_SIZE"

# =============================================================================
# BIOS BOOT — isolinux
# =============================================================================
section "Configuring Boot"

cp /usr/lib/ISOLINUX/isolinux.bin      "$ISO_DIR/boot/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/boot/isolinux/"

# Copy optional menu modules if present
for mod in libcom32.c32 libutil.c32 menu.c32 vesamenu.c32; do
    src="/usr/lib/syslinux/modules/bios/$mod"
    [[ -f "$src" ]] && cp "$src" "$ISO_DIR/boot/isolinux/" || true
done

cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" <<'ISOLINUX_EOF'
DEFAULT install
PROMPT 0
TIMEOUT 10
ONTIMEOUT install

LABEL install
  LINUX  /boot/vmlinuz
  APPEND initrd=/boot/initrd.img quiet
  IPAPPEND 2

LABEL install-verbose
  LINUX  /boot/vmlinuz
  APPEND initrd=/boot/initrd.img
ISOLINUX_EOF

log "BIOS boot (isolinux) configured"

# =============================================================================
# UEFI BOOT — GRUB EFI
# =============================================================================
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUBEOF'
set default=0
set timeout=3
set timeout_style=hidden

menuentry "LoomOS Installer" {
    search --no-floppy --label --set=root LOOMOS_INST
    linux  /boot/vmlinuz quiet
    initrd /boot/initrd.img
}

menuentry "LoomOS Installer (verbose)" {
    search --no-floppy --label --set=root LOOMOS_INST
    linux  /boot/vmlinuz
    initrd /boot/initrd.img
}

menuentry "LoomOS Installer (safe — no KMS)" {
    search --no-floppy --label --set=root LOOMOS_INST
    linux  /boot/vmlinuz nomodeset
    initrd /boot/initrd.img
}
GRUBEOF

# Build GRUB EFI image
grub-mkimage \
    --format=x86_64-efi \
    --output="$ISO_DIR/EFI/boot/bootx64.efi" \
    --prefix=/boot/grub \
    iso9660 normal boot linux echo all_video gfxterm \
    test search search_label part_gpt part_msdos \
    fat ext2 loadenv configfile \
    2>/dev/null || die "grub-mkimage failed"

# Copy GRUB EFI modules
mkdir -p "$ISO_DIR/boot/grub/x86_64-efi"
cp -r /usr/lib/grub/x86_64-efi/*.mod \
      "$ISO_DIR/boot/grub/x86_64-efi/" 2>/dev/null || true

# Build EFI system partition image (FAT32, embedded in ISO)
# This is required for proper UEFI booting from ISO
EFI_IMG="$ISO_DIR/boot/grub/efi.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=4 2>/dev/null
mkfs.fat -F32 "$EFI_IMG" >/dev/null 2>&1
mmd    -i "$EFI_IMG" ::/EFI ::/EFI/boot
mcopy  -i "$EFI_IMG" "$ISO_DIR/EFI/boot/bootx64.efi" ::/EFI/boot/

log "UEFI boot (GRUB EFI) configured"

# =============================================================================
# ISO METADATA
# =============================================================================
mkdir -p "$ISO_DIR/.disk"
echo "LoomOS Installer $(date +%Y-%m-%d)" > "$ISO_DIR/.disk/info"
echo "Kernel: $KVER"                       >> "$ISO_DIR/.disk/info"
echo "https://github.com/DansDesigns/LoomOS" >> "$ISO_DIR/.disk/info"

# =============================================================================
# BUILD THE ISO
# =============================================================================
section "Building ISO: $ISO_OUTPUT"

# Extract MBR from isolinux for hybrid boot
dd if=/usr/lib/ISOLINUX/isohdpfx.bin \
   of="$WORK/mbr.bin" bs=432 count=1 2>/dev/null

xorriso -as mkisofs \
    -o "$ISO_OUTPUT" \
    \
    -iso-level 3 \
    -full-iso9660-filenames \
    -rational-rock \
    -joliet \
    -volid "$ISO_LABEL" \
    -appid "LoomOS Installer" \
    -publisher "https://github.com/DansDesigns/LoomOS" \
    \
    -eltorito-boot      boot/isolinux/isolinux.bin \
    -eltorito-catalog   boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    \
    --eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    \
    -isohybrid-mbr "$WORK/mbr.bin" \
    \
    "$ISO_DIR" \
    2>&1 | grep -v "^xorriso" || true

# Verify ISO was created
[[ -f "$ISO_OUTPUT" ]] || die "ISO creation failed — $ISO_OUTPUT not found"

# =============================================================================
# VERIFY BOOT SECTORS ARE PRESENT AND CORRECT
# =============================================================================
section "Verifying ISO"

# Check ISO is valid
xorriso -indev "$ISO_OUTPUT" -report_about WARNING \
    -find / -type f -name "vmlinuz" \
    2>/dev/null | grep -q "vmlinuz" \
    && log "Kernel found in ISO" \
    || warn "Could not verify kernel in ISO"

xorriso -indev "$ISO_OUTPUT" \
    -find / -type f -name "initrd.img" \
    2>/dev/null | grep -q "initrd" \
    && log "Initrd found in ISO" \
    || warn "Could not verify initrd in ISO"

xorriso -indev "$ISO_OUTPUT" \
    -find / -type f -name "isolinux.bin" \
    2>/dev/null | grep -q "isolinux" \
    && log "BIOS boot sector verified" \
    || warn "BIOS boot sector not found"

xorriso -indev "$ISO_OUTPUT" \
    -find / -type f -name "bootx64.efi" \
    2>/dev/null | grep -q "bootx64" \
    && log "UEFI boot loader verified" \
    || warn "UEFI boot loader not found"

# Check MBR contains boot code (first 2 bytes should not be 00 00)
MBR_CHECK=$(dd if="$ISO_OUTPUT" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$MBR_CHECK" != "0000" ]] \
    && log "MBR boot code present (hybrid boot verified)" \
    || warn "MBR may be empty — BIOS boot might not work"

# =============================================================================
# REPORT
# =============================================================================
ISO_SIZE=$(du -sh "$ISO_OUTPUT" | cut -f1)
ISO_SHA256=$(sha256sum "$ISO_OUTPUT" | cut -d' ' -f1)
echo "$ISO_SHA256  $ISO_OUTPUT" > "${ISO_OUTPUT%.iso}.sha256"

echo ""
echo -e "${GREEN}${BOLD}══ ISO Build Complete ══${NC}"
echo ""
echo -e "  File:    ${CYAN}$ISO_OUTPUT${NC}"
echo -e "  Size:    $ISO_SIZE"
echo -e "  Kernel:  $KVER"
echo -e "  SHA256:  $ISO_SHA256"
echo ""
echo -e "  ${BOLD}Write to USB:${NC}"
echo -e "  ${CYAN}sudo dd if=$ISO_OUTPUT of=/dev/sdX bs=4M status=progress oflag=sync${NC}"
echo -e "  (replace sdX with your USB device — check with lsblk)"
echo ""
echo -e "  ${BOLD}Test in QEMU (BIOS):${NC}"
echo -e "  ${CYAN}qemu-system-x86_64 -m 2G -cdrom $ISO_OUTPUT -boot d -enable-kvm${NC}"
echo ""
echo -e "  ${BOLD}Test in QEMU (UEFI):${NC}"
echo -e "  ${CYAN}apt install ovmf${NC}"
echo -e "  ${CYAN}qemu-system-x86_64 -m 2G -cdrom $ISO_OUTPUT -boot d -enable-kvm \\${NC}"
echo -e "  ${CYAN}    -bios /usr/share/ovmf/OVMF.fd${NC}"
echo ""

# Cleanup
rm -rf "$WORK"
log "Build workspace cleaned"
