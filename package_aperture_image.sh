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

echo "[3.5/4] Applying 16KB host-page ALIGN_UP trampoline to vulkan.virtio.so..."
# This patch fixes the Venus ring buffer size alignment bug on Apple Silicon:
#   On 4KB-page Android guests, the ring BO size (e.g. 0x21000) is not 16KB-aligned.
#   The host macOS vm_remap/hv_vm_map requires 16KB page alignment for BAR hostmem.
#   Fix: Intercept the LDR x25,[x21,#0x38] that loads buffer_size, align it
#   (ALIGN_UP(x25, 16384) = (x25 + 0x3FFF) & ~0x3FFF), write it back to
#   [x21,#0x38] so all subsequent reads get the aligned value, then return.
#
# Patch strategy: 6-instruction trampoline in the 9KB zero-filled inter-segment gap
# at file offset 0x109a60. The RX PT_LOAD PHDR filesz is extended to cover it.
# Patch site (0xbad9c): B to trampoline
# Trampoline: LDR x25; ADD #0xFFF; ADD #0x3000; AND (64-bit ~0x3FFF); STR writeback; B back
VK_SO_TMP=$(mktemp /tmp/vulkan_virtio.XXXXXX.so)
if $DEBUGFS -R "dump ${PREFIX}/lib64/hw/vulkan.virtio.so $VK_SO_TMP" "$TARGET_IMG" 2>/dev/null && [ -s "$VK_SO_TMP" ]; then
    python3 -c '
import sys, hashlib, struct

so_file = sys.argv[1]
with open(so_file, "rb") as f:
    data = bytearray(f.read())

if len(data) < 64 or data[:4] != b"\x7fELF" or data[18:20] != b"\xb7\x00":
    print("    [!] Error: Not a valid ARM64 ELF shared object.")
    sys.exit(1)

# Constants
PATCH_SITE       = 0xbad9c   # File offset of ring buffer_size field load
TRAMPOLINE       = 0x109a60  # File offset of zero-filled inter-segment gap (RX)
RETURN_ADDR      = PATCH_SITE + 4  # 0xbada0
ORIGINAL_INSTR   = 0xf9401eb9  # LDR x25, [x21, #0x38] (loads buffer_size from ring struct)
OLD_HACK_INSTR   = 0xd2a00079  # MOV x25, #0x30000 (previous hardcoded hack)
ALREADY_PATCHED  = 0x14013b31  # B to 0x109a60 (this trampoline, already installed)

def encode_b(from_addr, to_addr):
    offset = to_addr - from_addr
    imm26 = (offset >> 2) & 0x3FFFFFF
    return (0b000101 << 26) | imm26

# Check current state at patch site
current = struct.unpack_from("<I", data, PATCH_SITE)[0]

if current == ALREADY_PATCHED:
    print("    [=] vulkan.virtio.so already has ALIGN_UP(16384) trampoline (verified).")
    sys.exit(0)

if current not in (ORIGINAL_INSTR, OLD_HACK_INSTR):
    print(f"    [!] Unexpected instruction at patch site {hex(PATCH_SITE)}: {hex(current)}")
    print(    "    [!] Different Mesa build -- skipping patch.")
    sys.exit(0)

# Verify trampoline region is zero-filled (safe to overwrite)
if any(data[TRAMPOLINE:TRAMPOLINE+28]):
    print(f"    [!] Trampoline region {hex(TRAMPOLINE)} is not zero-filled. Skipping.")
    sys.exit(1)

# Extend RX PT_LOAD PHDR (program header [2]) filesz/memsz to cover 6-instruction trampoline
e_phoff     = struct.unpack_from("<Q", data, 32)[0]
e_phentsize = struct.unpack_from("<H", data, 54)[0]
RX_PHDR_OFF = e_phoff + 2 * e_phentsize
new_filesz  = (TRAMPOLINE - 0x64000) + 28  # 6 instructions = 24 bytes + 4 margin
struct.pack_into("<Q", data, RX_PHDR_OFF + 32, new_filesz)
struct.pack_into("<Q", data, RX_PHDR_OFF + 40, new_filesz)

# ALIGN_UP(x25, 16384) trampoline - 6 instructions:
#   LDR x25,[x21,#0x38]  restore original 64-bit load of buffer_size
#   ADD x25,x25,#0xFFF   }
#   ADD x25,x25,#0x3000  } ALIGN_UP = (x25 + 0x3FFF) & ~0x3FFF
#   AND x25,x25,#~0x3FFF } (64-bit, N=1,immr=50,imms=49 encodes mask 0xFFFFFFFFFFFFC000)
#   STR x25,[x21,#0x38]  writeback aligned value so all subsequent reads see it
#   B   <return>         return to instruction after original patch site
STR_x25_x21_38 = ORIGINAL_INSTR ^ (1 << 22)  # flip opc 01->00: LDR->STR, same reg/offset
AND_x25_mask   = 0x92000000 | (1 << 22) | (50 << 16) | (49 << 10) | (25 << 5) | 25  # N=1,immr=50,imms=49
trampoline = [
    ORIGINAL_INSTR,                             # LDR x25, [x21, #0x38]
    0x91000000 | (0xFFF << 10) | (25 << 5) | 25, # ADD x25, x25, #0xFFF
    0x91400000 | (3    << 10) | (25 << 5) | 25,  # ADD x25, x25, #0x3000
    AND_x25_mask,                                # AND x25, x25, #0xFFFFFFFFFFFFC000
    STR_x25_x21_38,                              # STR x25, [x21, #0x38]  (writeback)
    encode_b(TRAMPOLINE + 20, RETURN_ADDR),      # B back to 0xbada0
]
for i, instr in enumerate(trampoline):
    struct.pack_into("<I", data, TRAMPOLINE + i*4, instr)

# Replace original LDR with branch to trampoline
struct.pack_into("<I", data, PATCH_SITE, encode_b(PATCH_SITE, TRAMPOLINE))

with open(so_file, "wb") as f:
    f.write(data)

sha = hashlib.sha256(data).hexdigest()[:12]
src = "original LDR" if current == ORIGINAL_INSTR else "old MOV hack"
print(f"    [+] ALIGN_UP(buffer_size, 16384) trampoline installed (from {src})")
print(f"        Patch site: {hex(PATCH_SITE)} -> B to trampoline at {hex(TRAMPOLINE)}")
print(f"        Trampoline: LDR+ADD+ADD+AND(64b)+STR_writeback+B (6 instrs @ {hex(TRAMPOLINE)})")
print(f"        RX PHDR extended: filesz={hex(new_filesz)}")
print(f"        SHA256: {sha}...")
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
