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
#   xorriso, cpio, busybox-static, bash-static, gcc, libc-dev, debootstrap
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

# Strip Windows-style \r line endings from the installer script
sed -i 's/\r//' "$INSTALL_SCRIPT" 2>/dev/null || true

# Install required tools
PKGS_NEEDED=()
for pkg in xorriso cpio busybox-static bash-static isolinux syslinux-common \
           grub-pc-bin grub-efi-amd64-bin mtools debootstrap \
           binutils dosfstools gcc libc-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || PKGS_NEEDED+=("$pkg")
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "Installing: ${PKGS_NEEDED[*]}"
    apt-get install -y "${PKGS_NEEDED[@]}" \
        || die "Could not install required packages"
fi

# Verify critical files
[[ -f /usr/lib/ISOLINUX/isolinux.bin ]]             || die "isolinux.bin not found"
[[ -f /usr/lib/ISOLINUX/isohdpfx.bin ]]             || die "isohdpfx.bin not found"
[[ -f /usr/lib/syslinux/modules/bios/ldlinux.c32 ]] || die "ldlinux.c32 not found"
[[ -f /usr/bin/busybox ]]                            || die "busybox not found"

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
chmod 755 "$INITRD_DIR/bin/busybox"

# Explicit sh symlink — MUST be done before the applet loop.
# busybox --list omits 'sh' on some builds (compiled as a hardlink alias,
# not a standalone applet), so we cannot rely on the loop for this.
ln -sf busybox "$INITRD_DIR/bin/sh"
log "bin/sh symlink created explicitly"

# Create symlinks for every applet busybox provides.
# Use relative targets — never absolute paths inside initramfs.
# Absolute symlinks cause ELOOP (-40) at kernel boot.
for applet in $("$BUSYBOX_BIN" --list 2>/dev/null); do
    # Skip sh — already handled explicitly above
    [[ "$applet" == "sh" ]] && continue
    case "$applet" in
        blkid|fdisk|fsck|getty|halt|ifconfig|init|insmod|ip|\
        klogd|losetup|lsmod|mdev|mkdosfs|mkfs*|mkswap|modprobe|\
        pivot_root|poweroff|reboot|rmmod|route|runlevel|\
        sulogin|swapoff|swapon|switch_root|syslogd|udhcpd|uevent)
            ln -sf ../bin/busybox "$INITRD_DIR/sbin/$applet" 2>/dev/null || true
            ;;
        *)
            ln -sf busybox "$INITRD_DIR/bin/$applet" 2>/dev/null || true
            ;;
    esac
done

log "Busybox installed ($(ls "$INITRD_DIR/bin/" | wc -l) applets)"

# =============================================================================
# BASH STATIC — install.sh uses bash arrays and bashisms, needs real bash
# =============================================================================
BASH_STATIC=""
for candidate in /bin/bash-static /usr/bin/bash-static; do
    if [[ -f "$candidate" ]]; then
        BASH_STATIC="$candidate"
        break
    fi
done

if [[ -z "$BASH_STATIC" ]]; then
    apt-get install -y bash-static 2>/dev/null || true
    for candidate in /bin/bash-static /usr/bin/bash-static; do
        [[ -f "$candidate" ]] && BASH_STATIC="$candidate" && break
    done
fi

[[ -n "$BASH_STATIC" ]] || die "bash-static not found. Install with: apt-get install bash-static"

file "$BASH_STATIC" | grep -q "statically linked" \
    || die "$BASH_STATIC is not statically linked — ldd shows dependencies that won't exist in initramfs"

cp "$BASH_STATIC" "$INITRD_DIR/bin/bash"
chmod 755 "$INITRD_DIR/bin/bash"

ln -sf /bin/bash "$INITRD_DIR/usr/bin/bash"

BASH_SIZE=$(du -sh "$INITRD_DIR/bin/bash" | cut -f1)
log "bash-static installed: $BASH_SIZE"

# Warn if bash-static contains AVX/AVX2 instructions that would kill Ivy Bridge.
# We can't recompile it here, but we can warn loudly so the user knows where
# to look if the installer crashes after /init hands off successfully.
if command -v objdump >/dev/null 2>&1; then
    if objdump -d "$INITRD_DIR/bin/bash" 2>/dev/null \
            | grep -qE '\symm[0-9]|\szmm[0-9]|vpcmp|vpbroadcast|vmovd|vmovq'; then
        warn "bash-static may contain AVX/AVX2 instructions"
        warn "This could cause an illegal instruction fault on i5-3rd gen (Ivy Bridge)"
        warn "If boot fails after the LoomOS banner appears, rebuild bash-static"
        warn "from source with: CFLAGS='-march=x86-64 -O1' ./configure && make"
    else
        log "bash-static: no AVX/AVX2 instructions detected, safe for Ivy Bridge"
    fi
fi

# =============================================================================
# KERNEL MODULES — copy essential drivers for broad hardware support
# =============================================================================
info "Copying kernel modules..."

KMOD_SRC="/lib/modules/$KVER"

if [[ -d "$KMOD_SRC" ]]; then
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
# NETWORK — resolv.conf, hosts, udhcpc script
# =============================================================================
cat > "$INITRD_DIR/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

cat > "$INITRD_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
EOF

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
# /init.sh — THE SETUP LOGIC
# =============================================================================
# Executed by the static /init ELF binary below. No shebang line — bash is
# invoked explicitly by the C launcher so the kernel never parses a shebang.
# =============================================================================
cat > "$INITRD_DIR/init.sh" <<'INITEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential virtual filesystems
mount -t proc     proc     /proc     2>/dev/null
mount -t sysfs    sysfs    /sys      2>/dev/null
mount -t devtmpfs devtmpfs /dev      2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t tmpfs    tmpfs    /tmp      2>/dev/null
mount -t tmpfs    tmpfs    /run      2>/dev/null

# /dev/pts for terminal support
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Ensure essential device nodes exist (devtmpfs may have missed some)
[ -c /dev/console ] || mknod /dev/console  c 5 1
[ -c /dev/null ]    || mknod /dev/null     c 1 3
[ -c /dev/zero ]    || mknod /dev/zero     c 1 5
[ -c /dev/tty ]     || mknod /dev/tty      c 5 0
[ -c /dev/tty1 ]    || mknod /dev/tty1     c 4 1
[ -c /dev/tty2 ]    || mknod /dev/tty2     c 4 2
[ -c /dev/urandom ] || mknod /dev/urandom  c 1 9
[ -c /dev/random ]  || mknod /dev/random   c 1 8

hostname loomos-install 2>/dev/null || true

# Load essential storage and network modules
for mod in \
    ext4 jbd2 mbcache \
    vfat fat nls_cp437 nls_iso8859_1 \
    usb_storage xhci_hcd ehci_hcd uhci_hcd uas \
    ahci libata sd_mod sr_mod \
    nvme nvme_core nvme_fabrics \
    e1000 e1000e r8169 igb ixgbe tg3 \
    virtio_net virtio_blk virtio_pci; do
    modprobe "$mod" 2>/dev/null || true
done

sleep 2

# Bring up network interfaces
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
    ip link set "$iface" up 2>/dev/null || \
        ifconfig "$iface" up 2>/dev/null || true
done

# DHCP on ethernet interfaces — background, non-blocking
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -vE '^(lo|wl)'); do
    udhcpc -i "$iface" -t 8 -q -n \
        -s /usr/share/udhcpc/default.script \
        2>/dev/null &
done

sleep 4

# Redirect I/O to console
exec </dev/console
exec >/dev/console
exec 2>/dev/console

# Sanity checks before handing to installer
if [ ! -x /bin/bash ]; then
    echo "FATAL: /bin/bash not found or not executable in initramfs"
    echo "Dropping to sh shell for debugging"
    exec /bin/sh
fi

if [ ! -f /install.sh ]; then
    echo "FATAL: /install.sh not found in initramfs"
    exec /bin/sh
fi

chmod +x /install.sh
clear

exec /bin/bash /install.sh

# Should never reach here
echo "Installer exited or bash exec failed — dropping to shell"
echo "Run manually: bash /install.sh"
exec /bin/sh
INITEOF
chmod 755 "$INITRD_DIR/init.sh"
log "/init.sh written"

# =============================================================================
# /init — STATIC ELF BINARY (compiled from C)
# =============================================================================
# The kernel executes /init directly as PID 1. A shebang-based shell script
# is unreliable here for two reasons:
#
#   ENOEXEC (-8):  kernel cannot exec a script if its shebang interpreter is
#                  missing or the line has \r\n (Windows) line endings
#   ELOOP   (-40): absolute symlinks inside initramfs loop back on themselves
#                  because there is no host root to resolve against
#
# Solution: compile a tiny static C binary. The kernel sees a valid ELF,
# executes main(), which calls execve() directly — no shebang parsing, no
# symlink resolution, no dynamic linker required.
#
# CPU compatibility (-march=x86-64):
#   Ivy Bridge (i5 3rd gen, 2012) is x86_64 but lacks AVX2, BMI2, and later
#   ISA extensions. If gcc targets a newer microarchitecture baseline (e.g.
#   x86-64-v3 or -march=native on a modern build host), it can emit ymm/zmm
#   instructions that produce an illegal instruction fault (#UD) on Ivy Bridge
#   before a single line of init.sh executes — manifesting as exit code
#   0x00000100 and a kernel panic.
#
#   -march=x86-64  = SSE2-only baseline guaranteed on every x86_64 CPU
#   -mtune=generic = schedule for a mix of CPUs, not the build host
#   -O1            = avoids autovectorisation that can emit AVX even without
#                    an explicit -march=native flag on newer gcc versions
# =============================================================================
info "Compiling static /init launcher (x86-64 baseline, safe for Ivy Bridge)..."

cat > "$WORK/init_launcher.c" <<'EOF'
/*
 * LoomOS initramfs /init launcher
 *
 * Compiled as a static ELF so the kernel can exec it directly as PID 1.
 * Uses execve() to hand off to bash running /init.sh.
 * Three fallback levels ensure a debug shell is always reachable.
 *
 * Built with -march=x86-64 -O1 so only SSE2-baseline instructions are
 * emitted — safe on every x86_64 CPU including Ivy Bridge (i5 3rd gen, 2012).
 */
#include <unistd.h>

int main(void)
{
    /* Primary: bash-static running our setup script */
    {
        char *argv[] = { "/bin/bash", "/init.sh", (char *)0 };
        char *envp[] = { "PATH=/bin:/sbin:/usr/bin:/usr/sbin", (char *)0 };
        execve("/bin/bash", argv, envp);
    }

    /* Fallback 1: busybox ash running our setup script */
    {
        char *argv[] = { "/bin/sh", "/init.sh", (char *)0 };
        char *envp[] = { "PATH=/bin:/sbin:/usr/bin:/usr/sbin", (char *)0 };
        execve("/bin/sh", argv, envp);
    }

    /* Fallback 2: bare busybox ash for manual debugging */
    {
        char *argv[] = { "/bin/sh", (char *)0 };
        char *envp[] = { "PATH=/bin:/sbin:/usr/bin:/usr/sbin", (char *)0 };
        execve("/bin/sh", argv, envp);
    }

    /*
     * All three execve() calls failed — /bin/bash and /bin/sh are both
     * missing or non-executable. return 1 causes exit code 0x00000100
     * and a kernel panic. Check the initramfs verification output above.
     */
    return 1;
}
EOF

# -march=x86-64  : SSE2-only baseline — runs on every x86_64 CPU (inc. Ivy Bridge)
# -mtune=generic : schedule for mixed CPUs, not the build host
# -O1            : avoids autovectorisation that emits AVX on modern gcc
# -mno-avx       : belt-and-braces: explicitly prohibit AVX emission
# -mno-avx2      : belt-and-braces: explicitly prohibit AVX2 emission
gcc -static -O1 -march=x86-64 -mtune=generic -mno-avx -mno-avx2 \
    -o "$INITRD_DIR/init" "$WORK/init_launcher.c" \
    || die "Failed to compile static /init launcher — is gcc + libc-dev installed?"

chmod 755 "$INITRD_DIR/init"

# Verify statically linked
file "$INITRD_DIR/init" | grep -q "statically linked" \
    || die "/init compiled but is NOT statically linked — will fail as PID 1"

# Verify no AVX/AVX2 instructions slipped through
if command -v objdump >/dev/null 2>&1; then
    if objdump -d "$INITRD_DIR/init" 2>/dev/null \
            | grep -qE '\symm[0-9]|\szmm[0-9]|vpcmp|vpbroadcast|vmovd|vmovq'; then
        die "/init still contains AVX/AVX2 instructions despite -mno-avx -mno-avx2" \
            "— check your gcc version and toolchain configuration"
    else
        log "/init: baseline x86-64 only — safe for i5-3rd gen (Ivy Bridge)"
    fi
fi

INIT_SIZE=$(du -sh "$INITRD_DIR/init" | cut -f1)
log "Static /init compiled and verified: $INIT_SIZE"

# =============================================================================
# VERIFY INITRAMFS BEFORE PACKING
# =============================================================================
info "Verifying initramfs contents..."

VERIFY_FAIL=0
for check in \
    "bin/busybox:busybox binary" \
    "bin/bash:bash-static binary" \
    "bin/sh:sh symlink" \
    "init:static init ELF" \
    "init.sh:init setup script" \
    "install.sh:installer script" \
    "usr/share/udhcpc/default.script:udhcpc script"; do
    path="${check%%:*}"
    desc="${check##*:}"
    if [[ ! -e "$INITRD_DIR/$path" ]]; then
        warn "MISSING: $path ($desc)"
        VERIFY_FAIL=1
    fi
done

# /init must be a real ELF, not a symlink
if [[ -L "$INITRD_DIR/init" ]]; then
    warn "PROBLEM: /init is a symlink — kernel requires a real ELF binary"
    VERIFY_FAIL=1
fi

# /init must be statically linked
if [[ -f "$INITRD_DIR/init" ]]; then
    if file "$INITRD_DIR/init" | grep -q "dynamically linked"; then
        warn "PROBLEM: /init is dynamically linked — will fail as PID 1"
        VERIFY_FAIL=1
    else
        log "/init: statically linked ELF OK"
    fi
fi

# /bin/bash must be statically linked
if [[ -f "$INITRD_DIR/bin/bash" ]]; then
    if file "$INITRD_DIR/bin/bash" | grep -q "dynamically linked"; then
        warn "PROBLEM: /bin/bash is dynamically linked — will fail in initramfs"
        warn "         Install bash-static package on your build machine"
        VERIFY_FAIL=1
    else
        log "bash: statically linked OK"
    fi
fi

# /bin/sh must resolve (symlink is fine, -e follows it)
if [[ -e "$INITRD_DIR/bin/sh" ]]; then
    log "bin/sh: present OK"
else
    warn "bin/sh missing — creating fallback symlink"
    ln -sf busybox "$INITRD_DIR/bin/sh"
    log "bin/sh: fallback symlink created"
fi

[[ $VERIFY_FAIL -eq 0 ]] || die "Initramfs verification failed — fix above issues before continuing"
log "Initramfs verification passed"

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

cp /usr/lib/ISOLINUX/isolinux.bin             "$ISO_DIR/boot/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/boot/isolinux/"

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

grub-mkimage \
    --format=x86_64-efi \
    --output="$ISO_DIR/EFI/boot/bootx64.efi" \
    --prefix=/boot/grub \
    iso9660 normal boot linux echo all_video gfxterm \
    test search search_label part_gpt part_msdos \
    fat ext2 loadenv configfile \
    2>/dev/null || die "grub-mkimage failed"

mkdir -p "$ISO_DIR/boot/grub/x86_64-efi"
cp -r /usr/lib/grub/x86_64-efi/*.mod \
      "$ISO_DIR/boot/grub/x86_64-efi/" 2>/dev/null || true

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

[[ -f "$ISO_OUTPUT" ]] || die "ISO creation failed — $ISO_OUTPUT not found"

# =============================================================================
# VERIFY ISO
# =============================================================================
section "Verifying ISO"

xorriso -indev "$ISO_OUTPUT" \
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

rm -rf "$WORK"
log "Build workspace cleaned"
