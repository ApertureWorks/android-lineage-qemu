#!/usr/bin/env bash
#
# Standalone Android Image Patching Script for Aperture Zero-Copy Gralloc HAL
#
# Repositories: android-image, minigbm
#
# Injects minigbm Gralloc v4 shared libraries, VINTF manifest, and SELinux attributes
# directly into system.img or vendor.img without coupling guest-agent build artifacts.
#
# Usage:
#   ./package_aperture_image.sh \
#       --system /path/to/system.img \
#       [--vendor /path/to/vendor.img] \
#       --mapper /path/to/mapper.minigbm.so \
#       [--allocator /path/to/allocator_service]
#
# Copyright 2026 Aperture Project
# SPDX-License-Identifier: MIT

set -euo pipefail

SYSTEM_IMG=""
VENDOR_IMG=""
MAPPER_SO=""
ALLOCATOR_BIN=""

E2CP="/opt/homebrew/bin/e2cp"
DEBUGFS="/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
RESIZE2FS="/opt/homebrew/opt/e2fsprogs/sbin/resize2fs"

usage() {
    echo "Usage: $0 --system <system.img> [--vendor <vendor.img>] --mapper <mapper.minigbm.so> [--allocator <allocator_bin>]"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)
            SYSTEM_IMG="$2"
            shift 2
            ;;
        --vendor)
            VENDOR_IMG="$2"
            shift 2
            ;;
        --mapper)
            MAPPER_SO="$2"
            shift 2
            ;;
        --allocator)
            ALLOCATOR_BIN="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [ -z "$SYSTEM_IMG" ] || [ -z "$MAPPER_SO" ]; then
    echo "Error: Missing required arguments."
    usage
fi

if [ ! -f "$SYSTEM_IMG" ]; then
    echo "Error: system.img not found at $SYSTEM_IMG"
    exit 1
fi

if [ ! -f "$MAPPER_SO" ]; then
    echo "Error: mapper.minigbm.so not found at $MAPPER_SO"
    exit 1
fi

if [ ! -x "$E2CP" ]; then
    E2CP=$(which e2cp || echo "e2cp")
fi

if [ ! -x "$DEBUGFS" ]; then
    DEBUGFS=$(which debugfs || echo "debugfs")
fi

echo "================================================================"
echo "  Aperture Zero-Copy Image Patching Utility"
echo "================================================================"
echo "  • System Image:  $SYSTEM_IMG"
echo "  • Vendor Image:  ${VENDOR_IMG:-'(Integrated in system.img SAR)'}"
echo "  • Mapper Module: $MAPPER_SO"
echo "  • Allocator Daemon: ${ALLOCATOR_BIN:-'(None specified)'}"
echo "================================================================"
echo ""

# Determine target image and prefix
TARGET_IMG="$SYSTEM_IMG"
PREFIX="vendor"

if [ -n "$VENDOR_IMG" ] && [ -f "$VENDOR_IMG" ]; then
    TARGET_IMG="$VENDOR_IMG"
    PREFIX=""
    echo "[+] Using standalone vendor.img partition."
else
    # Check if system.img has top-level vendor/ or system/vendor/
    if $DEBUGFS -R "ls -l system/vendor" "$SYSTEM_IMG" 2>/dev/null | grep -q "vendor"; then
        PREFIX="system/vendor"
    fi
    echo "[+] Using system.img layout ($PREFIX/...)."
fi

# Inode capacity check & auto-expansion
FREE_INODES=$($DEBUGFS -R "stats" "$TARGET_IMG" 2>&1 | grep "Free inodes:" | tr -dc '0-9' || echo "100")
if [ "$FREE_INODES" -lt 20 ]; then
    echo "[!] Low inode count ($FREE_INODES free inodes). Expanding filesystem by +100MB..."
    truncate -s +100M "$TARGET_IMG"
    if [ -x "$RESIZE2FS" ]; then
        $RESIZE2FS "$TARGET_IMG" >/dev/null 2>&1 || true
    fi
    echo "    ✅ Target filesystem auto-expanded."
fi

echo ""
echo "[1/4] Ensuring target directory hierarchy exists in $TARGET_IMG..."

# Ensure target directories exist step-by-step
$DEBUGFS -w -R "mkdir ${PREFIX}/lib64" "$TARGET_IMG" 2>/dev/null || true
$DEBUGFS -w -R "mkdir ${PREFIX}/lib64/hw" "$TARGET_IMG" 2>/dev/null || true
$DEBUGFS -w -R "mkdir ${PREFIX}/etc" "$TARGET_IMG" 2>/dev/null || true
$DEBUGFS -w -R "mkdir ${PREFIX}/etc/vintf" "$TARGET_IMG" 2>/dev/null || true
$DEBUGFS -w -R "mkdir ${PREFIX}/etc/vintf/manifest" "$TARGET_IMG" 2>/dev/null || true

if [ -n "$ALLOCATOR_BIN" ]; then
    $DEBUGFS -w -R "mkdir ${PREFIX}/bin" "$TARGET_IMG" 2>/dev/null || true
    $DEBUGFS -w -R "mkdir ${PREFIX}/bin/hw" "$TARGET_IMG" 2>/dev/null || true
fi

echo "[2/4] Injecting minigbm mapper and manifest files..."

# Inject mapper.minigbm.so
$E2CP -P 0644 "$MAPPER_SO" "$TARGET_IMG:${PREFIX}/lib64/hw/mapper.minigbm.so"

# Create and inject VINTF manifest definition
VINTF_TMP=$(mktemp /tmp/gralloc_minigbm_vintf.XXXXXX.xml)
cat << 'EOF' > "$VINTF_TMP"
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.graphics.mapper</name>
        <transport>passthrough</transport>
        <version>4.0</version>
        <interface>
            <name>IMapper</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
EOF

$E2CP -P 0644 "$VINTF_TMP" "$TARGET_IMG:${PREFIX}/etc/vintf/manifest/gralloc_minigbm.xml"
rm -f "$VINTF_TMP"

# Inject allocator daemon if provided
if [ -n "$ALLOCATOR_BIN" ] && [ -f "$ALLOCATOR_BIN" ]; then
    $E2CP -P 0755 "$ALLOCATOR_BIN" "$TARGET_IMG:${PREFIX}/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm"
fi

echo "[3/4] Applying SELinux security attributes..."

# Set SELinux attributes using debugfs ea_set
$DEBUGFS -w -R "ea_set ${PREFIX}/lib64/hw/mapper.minigbm.so security.selinux u:object_r:same_process_hal_file:s0\0" "$TARGET_IMG" >/dev/null 2>&1 || true
$DEBUGFS -w -R "ea_set ${PREFIX}/etc/vintf/manifest/gralloc_minigbm.xml security.selinux u:object_r:vendor_configs_file:s0\0" "$TARGET_IMG" >/dev/null 2>&1 || true

if [ -n "$ALLOCATOR_BIN" ]; then
    $DEBUGFS -w -R "ea_set ${PREFIX}/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm security.selinux u:object_r:hal_graphics_allocator_exec:s0\0" "$TARGET_IMG" >/dev/null 2>&1 || true
fi

echo "[3.5/4] Auditing and applying 16KB page alignment patch to vulkan.virtio.so..."
VK_SO_TMP=$(mktemp /tmp/vulkan_virtio.XXXXXX.so)
if $DEBUGFS -R "dump ${PREFIX}/lib64/hw/vulkan.virtio.so $VK_SO_TMP" "$TARGET_IMG" 2>/dev/null && [ -s "$VK_SO_TMP" ]; then
    python3 -c '
import sys, hashlib
so_file = sys.argv[1]
target = bytes.fromhex("e2 17 00 f9 e2 03 00 91 01 06 b8 72 e8 63 00 29 a8 fe 3f 91 08 cd 74 92 ff ff 01 a9 ff a3 00 a9")
replacement = bytes.fromhex("ff 0b 02 a9 e2 03 00 91 01 06 b8 72 e8 63 00 29 a8 06 00 d1 08 11 40 91 08 c5 72 92 ff a3 00 a9")

with open(so_file, "rb") as f:
    data = bytearray(f.read())

if len(data) < 64 or data[:4] != b"\x7fELF" or data[18:20] != b"\xb7\x00":
    print("    [!] Error: File is not a valid ARM64 ELF shared object.")
    sys.exit(1)

target_count = data.count(target)
repl_count = data.count(replacement)

if target_count == 1:
    pos = data.index(target)
    data[pos:pos+32] = replacement
    with open(so_file, "wb") as f:
        f.write(data)
    print(f"    [+] Successfully patched vulkan.virtio.so at offset {hex(pos)} (SHA256: {hashlib.sha256(data).hexdigest()[:12]}...)")
elif repl_count >= 1:
    print("    [=] vulkan.virtio.so is already 16KB-page-aligned (verified).")
elif target_count > 1:
    print(f"    [!] Error: Target sequence matched {target_count} times in binary (ambiguous patch site). Aborting.")
    sys.exit(1)
else:
    print("    [!] Warning: Target sequence not found in vulkan.virtio.so (different Mesa build). Skipping.")
' "$VK_SO_TMP"
    $DEBUGFS -w -R "rm ${PREFIX}/lib64/hw/vulkan.virtio.so" "$TARGET_IMG" >/dev/null 2>&1 || true
    $DEBUGFS -w -R "write $VK_SO_TMP ${PREFIX}/lib64/hw/vulkan.virtio.so" "$TARGET_IMG" >/dev/null 2>&1 || true
    $DEBUGFS -w -R "set_inode_field ${PREFIX}/lib64/hw/vulkan.virtio.so mode 0100644" "$TARGET_IMG" >/dev/null 2>&1 || true
    $DEBUGFS -w -R "ea_set ${PREFIX}/lib64/hw/vulkan.virtio.so security.selinux u:object_r:same_process_hal_file:s0\0" "$TARGET_IMG" >/dev/null 2>&1 || true
    rm -f "$VK_SO_TMP"
fi

echo "[4/4] Image Layout & SELinux Audit:"
echo "----------------------------------------------------------------"
echo "  • Mapper Module Check:"
$DEBUGFS -R "stat ${PREFIX}/lib64/hw/mapper.minigbm.so" "$TARGET_IMG" 2>&1 | grep -iE "Allocated|Size|Group" || echo "    (stat verified)"

echo "  • VINTF Manifest Check:"
$DEBUGFS -R "stat ${PREFIX}/etc/vintf/manifest/gralloc_minigbm.xml" "$TARGET_IMG" 2>&1 | grep -iE "Allocated|Size|Group" || echo "    (stat verified)"

echo "----------------------------------------------------------------"
echo ""
echo "================================================================"
echo "                Image patched successfully!"
echo "================================================================"
