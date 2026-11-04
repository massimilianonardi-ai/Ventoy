#!/bin/sh
# Disposable, no-core-change GRUB module load proof with two QEMU disks.
# Uses only files under a newly created output directory; never a host disk.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 COMPILED-MOD OUTPUT-DIR [fat32|ext4|ext4-gpt3] [EFI-PROBE [diagnostic|original|original-negative|original-media|original-boot|original-overlay|linux-handoff]]" >&2
  exit 2
fi

module=$1
output=$2
source_fs=${3:-fat32}
efi_probe=${4:-}
efi_mode=${5:-diagnostic}
case "$efi_mode" in
  diagnostic|linux-handoff) ;;
  original|original-negative|original-media|original-boot|original-overlay) [ -n "$efi_probe" ] || { echo 'Original EFI binary required' >&2; exit 2; } ;;
  *) echo "Unknown EFI mode: $efi_mode" >&2; exit 2 ;;
esac
if [ -n "$efi_probe" ] && [ ! -s "$efi_probe" ]; then
  echo "Missing EFI diagnostic executable: $efi_probe" >&2
  exit 4
fi
case "$source_fs" in
  fat32) expected_grub_fs='fs=fat'; min_extents=2; part_num=1 ;;
  ext4) expected_grub_fs='fs=ext2'; min_extents=1; part_num=1 ;;
  ext4-gpt3) expected_grub_fs='fs=ext2'; min_extents=1; part_num=3 ;;
  *) echo "Unsupported source filesystem: $source_fs" >&2; exit 2 ;;
esac
if [ "$efi_mode" = linux-handoff ]; then
  test -s "${VTOY_LINUX_KERNEL:-}" || { echo 'Missing original Linux kernel binary' >&2; exit 4; }
  test -s "${VTOY_LINUX_INITRD:-}" || { echo 'Missing experimental Linux initramfs' >&2; exit 4; }
fi
if [ "$efi_mode" = original-boot ]; then
  test -s "${VTOY_ISO_BOOT_EFI:-}" || { echo 'Missing genuine EFI payload for ISO' >&2; exit 4; }
  test -s "${VTOY_ISO_DRIVER_EFI:-}" || { echo 'Missing original Ventoy ISO9660 EFI driver' >&2; exit 4; }
fi
[ -s "$module" ] || { echo 'Nonempty compiled module required' >&2; exit 3; }
[ ! -e "$output" ] || { echo 'Output directory already exists' >&2; exit 4; }

for binary in grub-mkimage sgdisk mkfs.vfat mkfs.ext4 debugfs mmd mcopy mdel qemu-system-x86_64 timeout grep dd python3 cmp awk xorriso; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "Missing test dependency: $binary" >&2
    exit 5
  }
done

code=
vars=
for dir in /usr/share/OVMF /usr/share/edk2/ovmf; do
  for suffix in '' _4M; do
    if [ -f "$dir/OVMF_CODE$suffix.fd" ] && [ -f "$dir/OVMF_VARS$suffix.fd" ]; then
      code="$dir/OVMF_CODE$suffix.fd"
      vars="$dir/OVMF_VARS$suffix.fd"
      break 2
    fi
  done
done
[ -n "$code" ] || { echo 'Missing compatible OVMF CODE/VARS pair' >&2; exit 6; }

mkdir "$output"
output=$(CDPATH= cd "$output" && pwd)
cp "$vars" "$output/vars.fd"

cat > "$output/bootstrap.cfg" <<'EOF'
serial --unit=0 --speed=115200
terminal_output serial
echo VTOY_NO_CORE_PROBE_BOOTSTRAP
search --file --set=bootpart /vt-probe-boot.marker
set prefix=($bootpart)/grub
configfile ($bootpart)/grub/runtime.cfg
EOF

cat > "$output/runtime.cfg" <<'EOF'
echo VTOY_NO_CORE_PROBE_START
search --file --set=bootpart /vt-probe-boot.marker
echo VTOY_BOOT_DEVICE=$bootpart
ls
search --file --set=isopart /vt-probe-image.iso
echo VTOY_ISO_DEVICE=$isopart
set prefix=($bootpart)/grub
insmod ($bootpart)/grub/x86_64-efi/ventoy_source_probe.mod
vt_source_probe ($isopart)/vt-probe-image.iso
echo VTOY_EXTENT_MAP_BEGIN
vt_extent_probe ($isopart)/vt-map-image.iso
echo VTOY_EXTENT_MAP_DONE
EOF

if [ "$efi_mode" = linux-handoff ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VT_UEFI_MAP_EXPORT_BEGIN
vt_publish_efi_map
echo VT_UEFI_MAP_EXPORT_RETURNED
linux ($bootpart)/vmlinuz console=ttyS0
initrd ($bootpart)/initrd.img
echo VT_UEFI_LINUX_KERNEL_START
boot
EOF
fi

if [ -n "$efi_probe" ] && [ "$efi_mode" = original-negative ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_ORIGINAL_BAD_GUID_BEGIN
if [ -n "$vt_probe_chain_addr" ]; then
  set VTOY_MBOOT_SECONDARY=1
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:00000000000000000000000000000000 env_param=$vt_probe_env_addr mboot_source_probe=1
  if boot; then
    echo VTOY_ORIGINAL_BAD_GUID_RETURNED
  else
    echo VTOY_ORIGINAL_BAD_GUID_BOOT_ERROR
  fi
  echo VTOY_ORIGINAL_BAD_GUID_STATUS=$vt_original_source_probe
else
  echo VTOY_ORIGINAL_BAD_GUID_MISSING
fi
EOF
elif [ -n "$efi_probe" ] && [ "$efi_mode" = original-boot ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_ORIGINAL_ISO_BOOT_BEGIN
if [ -n "$vt_probe_chain_addr" ]; then
  set VTOY_MBOOT_SECONDARY=1
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr mboot_boot_probe=1
  if boot; then
    echo VTOY_ORIGINAL_ISO_BOOT_RETURNED
  else
    echo VTOY_ORIGINAL_ISO_BOOT_FAILED
  fi
  echo VTOY_ORIGINAL_SOURCE_STATUS=$vt_original_source_probe
  echo VTOY_ORIGINAL_ISO_DRIVER=$vt_original_iso_driver
  echo VTOY_ORIGINAL_MEDIA_STATUS=$vt_original_media_probe
  echo VTOY_ORIGINAL_MEDIA_CRC32=$vt_original_virtual_crc32
  echo VTOY_ORIGINAL_MEDIA_UNINSTALLED=$vt_original_virtual_uninstalled
  echo VTOY_ORIGINAL_BOOT_STATUS=$vt_original_boot_probe
else
  echo VTOY_ORIGINAL_ISO_BOOT_MISSING
fi
EOF
elif [ -n "$efi_probe" ] && [ "$efi_mode" = original-overlay ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_ORIGINAL_OVERLAY_BEGIN
vt_overlay_probe ($isopart)/vt-map-image.iso ($bootpart)/vt-overlay.bin
if [ -n "$vt_probe_chain_addr" ]; then
  set VTOY_MBOOT_SECONDARY=1
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr mboot_overlay_probe=1
  if boot; then
    echo VTOY_ORIGINAL_OVERLAY_RETURNED
  else
    echo VTOY_ORIGINAL_OVERLAY_FAILED
  fi
  echo VTOY_ORIGINAL_SOURCE_STATUS=$vt_original_source_probe
  echo VTOY_ORIGINAL_MEDIA_STATUS=$vt_original_media_probe
  echo VTOY_ORIGINAL_MEDIA_PUBLISHED=$vt_original_virtual_published
  echo VTOY_ORIGINAL_MEDIA_CRC32=$vt_original_virtual_crc32
  echo VTOY_ORIGINAL_MEDIA_UNINSTALLED=$vt_original_virtual_uninstalled
else
  echo VTOY_ORIGINAL_OVERLAY_MISSING
fi
EOF
elif [ -n "$efi_probe" ] && [ "$efi_mode" = original-media ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_ORIGINAL_MEDIA_BEGIN
if [ -n "$vt_probe_chain_addr" ]; then
  set VTOY_MBOOT_SECONDARY=1
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr mboot_media_probe=1
  if boot; then
    echo VTOY_ORIGINAL_MEDIA_RETURNED
  else
    echo VTOY_ORIGINAL_MEDIA_FAILED
  fi
  echo VTOY_ORIGINAL_SOURCE_STATUS=$vt_original_source_probe
  echo VTOY_ORIGINAL_MEDIA_STATUS=$vt_original_media_probe
  echo VTOY_ORIGINAL_MEDIA_PUBLISHED=$vt_original_virtual_published
  echo VTOY_ORIGINAL_MEDIA_CRC32=$vt_original_virtual_crc32
  echo VTOY_ORIGINAL_MEDIA_UNINSTALLED=$vt_original_virtual_uninstalled
else
  echo VTOY_ORIGINAL_MEDIA_MISSING
fi
EOF
elif [ -n "$efi_probe" ] && [ "$efi_mode" = original ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_ORIGINAL_EFI_BEGIN
if [ -n "$vt_probe_chain_addr" ]; then
  set VTOY_MBOOT_SECONDARY=1
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr mboot_source_probe=1
  if boot; then
    echo VTOY_ORIGINAL_EFI_RETURNED
  else
    echo VTOY_ORIGINAL_EFI_FAILED
  fi
  echo VTOY_ORIGINAL_SOURCE_STATUS=$vt_original_source_probe
else
  echo VTOY_ORIGINAL_EFI_MISSING
fi
EOF
elif [ -n "$efi_probe" ]; then
  cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_EFI_MEMORY_BRIDGE_START
if [ -n "$vt_probe_chain_addr" ]; then
  chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr
  if boot; then
    echo VTOY_EFI_MEMORY_BRIDGE_RETURNED
  else
    echo VTOY_EFI_MEMORY_BRIDGE_FAILED
  fi
else
  echo VTOY_EFI_MEMORY_BRIDGE_MISSING
fi
EOF
fi

cat >> "$output/runtime.cfg" <<'EOF'
echo VTOY_NO_CORE_PROBE_COMPLETED
halt
EOF

grub-mkimage --format=x86_64-efi \
  --directory=/usr/lib/grub/x86_64-efi \
  --prefix=/grub --config="$output/bootstrap.cfg" \
  --output="$output/BOOTX64.EFI" \
  part_gpt fat ext2 chain search search_fs_file serial terminal normal configfile test echo halt ls linux

# Each target is an isolated NEW GPT image, not a host or loop device.
for target in boot iso; do
  part="$output/$target-part.img"
  disk="$output/$target-disk.img"
  truncate -s 64M "$part"
  if [ "$target" = iso ] && [ "$part_num" = 3 ]; then
    # Disposable m-boot-like GPT geometry: p1 BIOS, p2 EFI, p3 data.
    truncate -s 128M "$disk"
    sgdisk --clear --new=1:2048:+10M --typecode=1:ef02 \
      --new=2:0:+16M --typecode=2:ef00 \
      --new=3:0:+64M --typecode=3:8300 "$disk" \
      > "$output/$target-gpt.log" 2>&1
    iso_sector_start=$(sgdisk -i 3 "$disk" | \
      awk '/First sector:/ { print $3 }')
    case "$iso_sector_start" in
      ''|*[!0-9]*) echo 'Could not locate GPT3 source sector' >&2; exit 6 ;;
    esac
  else
    truncate -s 96M "$disk"
    type=8300
    if [ "$target" = boot ]; then
      type=ef00
    fi
    sgdisk --clear --new=1:2048:+64M --typecode="1:$type" "$disk" \
      > "$output/$target-gpt.log" 2>&1
  fi
  if [ "$target" = boot ] || [ "$source_fs" = fat32 ]; then
    mkfs.vfat -F 32 "$part" > "$output/$target-fat.log" 2>&1
  fi
done

mmd -i "$output/boot-part.img" ::/EFI ::/EFI/BOOT ::/grub ::/grub/x86_64-efi
mcopy -i "$output/boot-part.img" "$output/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$output/boot-part.img" "$module" ::/grub/x86_64-efi/ventoy_source_probe.mod
if [ "$efi_mode" = original-overlay ]; then
  # Replacement exists ONLY on the synthetic boot ESP fixture.
  python3 - "$output/vt-overlay.bin" <<'PYOVERLAY'
import hashlib
from pathlib import Path
import sys
data = b'VT_PROBE_ISO_REPLACEMENT\n'
data += b''.join(hashlib.sha256(i.to_bytes(4, 'little')).digest()
                 for i in range(384))
Path(sys.argv[1]).write_bytes(data)
PYOVERLAY
  mcopy -i "$output/boot-part.img" "$output/vt-overlay.bin" ::/vt-overlay.bin
fi
if [ "$efi_mode" = linux-handoff ]; then
  mcopy -i "$output/boot-part.img" "$VTOY_LINUX_KERNEL" ::/vmlinuz
  mcopy -i "$output/boot-part.img" "$VTOY_LINUX_INITRD" ::/initrd.img
fi
if [ -n "$efi_probe" ]; then
  mcopy -i "$output/boot-part.img" "$efi_probe" ::/EFI/BOOT/VTOYDIAG.EFI
fi
if [ "$efi_mode" = original-boot ]; then
  mmd -i "$output/boot-part.img" ::/ventoy-secondary ::/ventoy-secondary/ventoy
  mcopy -i "$output/boot-part.img" "$VTOY_ISO_DRIVER_EFI" \
    ::/ventoy-secondary/ventoy/iso9660_x64.efi
fi
mcopy -i "$output/boot-part.img" "$output/runtime.cfg" ::/grub/runtime.cfg
echo 'bootloader marker' > "$output/vt-probe-boot.marker"
mcopy -i "$output/boot-part.img" "$output/vt-probe-boot.marker" ::/vt-probe-boot.marker

echo 'source-location fixture, not a bootable ISO' > "$output/vt-probe-image.iso"

# Create a genuine ISO9660 filesystem with deterministic, nonuniform data.
# The bytes are intentionally NOT a hand-written fake ISO header.
mkdir "$output/iso-content"
printf "pve-efi-linux-poc-media-id-2026-11-04\\n" > "$output/iso-content/.pve-cd-id.txt"
python3 - "$output/iso-content/payload.bin" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "wb") as stream:
    for index in range(4096):
        stream.write(hashlib.sha256(index.to_bytes(4, "big")).digest() * 16)
PY
if [ "$efi_mode" = original-boot ]; then
  mkdir -p "$output/iso-content/EFI/BOOT"
  cp "$VTOY_ISO_BOOT_EFI" "$output/iso-content/EFI/BOOT/BOOTX64.EFI"
  truncate -s 4M "$output/iso-content/efiboot.img"
  mkfs.vfat -F 12 "$output/iso-content/efiboot.img" > "$output/efiboot-fat.log" 2>&1
  mmd -i "$output/iso-content/efiboot.img" ::/EFI ::/EFI/BOOT
  mcopy -i "$output/iso-content/efiboot.img" "$VTOY_ISO_BOOT_EFI" \
    ::/EFI/BOOT/BOOTX64.EFI
  xorriso -as mkisofs -quiet -no-pad -R -J -V VTOY_MAP_TEST \
    -eltorito-alt-boot -e efiboot.img -no-emul-boot \
    -o "$output/vt-map-image.iso" "$output/iso-content" \
    > "$output/xorriso.log" 2>&1
  xorriso -indev "$output/vt-map-image.iso" \
    -report_el_torito plain >> "$output/xorriso.log" 2>&1
  xorriso -osirrox on -indev "$output/vt-map-image.iso" \
    -extract /EFI/BOOT/BOOTX64.EFI "$output/extracted-boot-efi" \
    >> "$output/xorriso.log" 2>&1
  cmp "$VTOY_ISO_BOOT_EFI" "$output/extracted-boot-efi"
  python3 - "$output/vt-map-image.iso" "$output/boot-catalog-verification.txt" <<'PYCAT'
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
records = [data[2048*n:2048*(n+1)] for n in range(16, 48)]
entries = [r for r in records if len(r) == 2048 and r[0] == 0
           and r[1:6] == b'CD001'
           and r[7:30].startswith(b'EL TORITO SPECIFICATION')]
if len(entries) != 1:
    raise SystemExit('Expected exactly one genuine El Torito boot descriptor')
catalog_lba = struct.unpack_from('<I', entries[0], 71)[0]
catalog = data[catalog_lba*2048:(catalog_lba+1)*2048]
if len(catalog) != 2048 or catalog[0] != 1 or catalog[1] != 0xef:
    raise SystemExit('Missing El Torito EFI validation header')
if catalog[30:32] != bytes((0x55, 0xaa)) or catalog[32] != 0x88:
    raise SystemExit('Invalid boot catalog or non-bootable EFI entry')
if sum(struct.unpack('<16H', catalog[:32])) & 0xffff:
    raise SystemExit('El Torito validation checksum mismatch')
boot_lba = struct.unpack_from('<I', catalog, 40)[0]
if boot_lba < 16 or boot_lba*2048 >= len(data):
    raise SystemExit('El Torito EFI boot image outside ISO')
pathlib.Path(sys.argv[2]).write_text(
    f'el_torito_efi_catalog=verified\nboot_catalog_lba={catalog_lba}\n'
    f'efi_image_lba={boot_lba}\n'
)
PYCAT
else
  xorriso -as mkisofs -quiet -no-pad -R -J -V VTOY_MAP_TEST \
    -o "$output/vt-map-image.iso" "$output/iso-content" \
    > "$output/xorriso.log" 2>&1
fi

# ISO9660 bytes 0..32767 are the reserved System Area. Nonzero data
# here makes the ext4 fixture's initial file blocks non-sparse when
# populated by mkfs.ext4 -d; the primary volume descriptor is untouched.
python3 - "$output/vt-map-image.iso" "$efi_mode" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "r+b") as stream:
    # Fill only the ISO9660 System Area (first 16 sectors of 2048 bytes)
    # and the known zero-only alignment gap in THIS xorriso-generated
    # diagnostic fixture. Do not modify actual installation ISOs.
    for index in range(1024):
        stream.write(hashlib.sha256(index.to_bytes(4, "big")).digest())
    for block in (range(0) if sys.argv[2] == 'original-boot' else range(13, 16)):
        stream.seek(block * 4096)
        if any(stream.read(4096)):
            raise SystemExit("xorriso diagnostic ISO layout changed")
        stream.seek(block * 4096)
        for index in range(128):
            stream.write(hashlib.sha256(
                b"ext4-dense-fixture" + block.to_bytes(2, "big")
                + index.to_bytes(2, "big")
            ).digest())
PY
xorriso -indev "$output/vt-map-image.iso" -pvd_info \
  >> "$output/xorriso.log" 2>&1
xorriso -osirrox on -indev "$output/vt-map-image.iso" -extract /payload.bin \
  "$output/extracted-payload.bin" >> "$output/xorriso.log" 2>&1
cmp "$output/iso-content/payload.bin" "$output/extracted-payload.bin"

if [ "$source_fs" = fat32 ]; then
  mcopy -i "$output/iso-part.img" "$output/vt-probe-image.iso" ::/vt-probe-image.iso

  # Force noncontiguous FAT allocation before copying the real ISO.
  truncate -s 1M "$output/filler-A.bin"
  truncate -s 1536K "$output/filler-B.bin"
  truncate -s 1M "$output/filler-C.bin"
  truncate -s 58M "$output/filler-D.bin"
  if [ "$efi_mode" = original-boot ]; then
    # The El Torito fixture is larger than the normal ISO. Force it to
    # cross the freed B hole AND a limited final free span, rather than
    # allowing a contiguous fit into a much larger tail.
    truncate -s 54M "$output/filler-D.bin"
  fi
  mcopy -i "$output/iso-part.img" "$output/filler-A.bin" ::/A.FILL
  mcopy -i "$output/iso-part.img" "$output/filler-B.bin" ::/B.FILL
  mcopy -i "$output/iso-part.img" "$output/filler-C.bin" ::/C.FILL
  # Fill the tail BEFORE freeing B; force an ISO crossing a physical gap.
  mcopy -i "$output/iso-part.img" "$output/filler-D.bin" ::/D.FILL
  mdel -i "$output/iso-part.img" ::/B.FILL
  mcopy -i "$output/iso-part.img" "$output/vt-map-image.iso" ::/vt-map-image.iso
else
  # Rootless ext4 image population. The disk is an ordinary file, never
  # a loop-mounted host device. This checks the same module on m-boot's
  # selected data filesystem, without claiming ext4 fragmentation.
  mkdir "$output/ext4-content"
  cp "$output/vt-map-image.iso" "$output/ext4-content/vt-map-image.iso"
  cp "$output/vt-probe-image.iso" "$output/ext4-content/vt-probe-image.iso"
  mkfs.ext4 -F -b 4096 -d "$output/ext4-content" "$output/iso-part.img" \
    > "$output/iso-ext4.log" 2>&1
  debugfs -R 'stat /vt-map-image.iso' "$output/iso-part.img" \
    > "$output/iso-ext4-extents.log" 2>&1
fi

for target in boot iso; do
  if [ "$target" = iso ] && [ "$part_num" = 3 ]; then
    dd if="$output/iso-part.img" of="$output/iso-disk.img" \
      bs=512 seek="$iso_sector_start" conv=notrunc status=none
  else
    dd if="$output/$target-part.img" of="$output/$target-disk.img" \
      bs=1M seek=1 conv=notrunc status=none
  fi
done

# Third disposable disk collides in size, MBR identity and ISO bytes,
# but NOT primary GPT disk GUID. Check that the EFI probe selects hd1.
set --
if [ -n "$efi_probe" ]; then
  cp "$output/iso-disk.img" "$output/iso-collision-disk.img"
  sgdisk -G "$output/iso-collision-disk.img" > "$output/iso-collision-gpt.log" 2>&1
  sgdisk --verify "$output/iso-collision-disk.img" >> "$output/iso-collision-gpt.log" 2>&1
  python3 - "$output/iso-disk.img" "$output/iso-collision-disk.img" <<'PY'
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as f:
    source = f.read(1024)
with pathlib.Path(sys.argv[2]).open("rb") as f:
    rival = f.read(1024)
if source[0x180:0x190] != rival[0x180:0x190]:
    raise SystemExit("legacy MBR identity differs")
if source[0x1b8:0x1bc] != rival[0x1b8:0x1bc]:
    raise SystemExit("legacy MBR signature differs")
if source[568:584] == rival[568:584]:
    raise SystemExit("GPT disk GUID did not change")
PY
  set -- -drive "if=none,format=raw,file=$output/iso-collision-disk.img,id=rival" \
    -device virtio-blk-pci,drive=rival,bootindex=3
fi

# OVMF runs without Secure Boot on disposable file-backed virtual disks.
set +e
timeout 90 qemu-system-x86_64 -machine q35 -accel tcg -m 1024 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$output/vars.fd" \
  -drive "if=none,format=raw,file=$output/boot-disk.img,id=boot" \
  -device virtio-blk-pci,drive=boot,bootindex=1 \
  -drive "if=none,format=raw,file=$output/iso-disk.img,id=iso" \
  -device virtio-blk-pci,drive=iso,bootindex=2 \
  "$@" -display none -serial mon:stdio -snapshot \
  > "$output/qemu.log" 2>&1
qemu_status=$?
set -e

if [ "$efi_mode" = linux-handoff ]; then
  expected=$(sha256sum "$output/vt-map-image.iso" | awk '{print $1}')
  if grep -q 'VT_MAP_SUCCESS' "$output/qemu.log" &&
     grep -q 'VT_EFI_MAP_PUBLISHED' "$output/qemu.log" &&
     grep -q 'VT_LINUX_MAP_CONSUMED' "$output/qemu.log" &&
     grep -q "VT_LINUX_ISO_SHA256=$expected" "$output/qemu.log" &&
     grep -q 'VT_LINUX_ISO_IDENTITY_PASS' "$output/qemu.log" &&
     grep -q 'VT_LINUX_HANDOFF_PASS' "$output/qemu.log"; then
    printf 'grub_efi_to_linux_dm=passed\nsource=grub-original-ventoy-extent-map\nlinux_kernel=unchanged\n' | tee "$output/runtime-result.txt"
    python3 "$(dirname "$0")/verify-extent-map.py" \
       "$output/qemu.log" "$output/vt-map-image.iso" \
       "$output/iso-disk.img" "$output/iso-map-verification.txt" \
       "$min_extents" "$part_num"
    exit 0
  fi
  echo "grub_efi_to_linux_dm=failed (QEMU $qemu_status)" > "$output/runtime-result.txt"
  tail -n 120 "$output/qemu.log" >&2
  exit 7
fi

if grep -q 'VTOY_EXTENT_MAP_DONE' "$output/qemu.log" &&
   grep -q 'VT_CHAIN_SUCCESS' "$output/qemu.log" &&
   grep -q 'VT_MAP_SUCCESS' "$output/qemu.log" &&
   grep -q 'VTOY_NO_CORE_PROBE_COMPLETED' "$output/qemu.log" &&
   grep -q 'VTOY_BOOT_DEVICE=hd0,gpt1' "$output/qemu.log" &&
   grep -q "VTOY_ISO_DEVICE=hd1,gpt$part_num" "$output/qemu.log" &&
   grep -q "source=(hd1,gpt$part_num)/vt-probe-image.iso disk=hd1 partition=$part_num" "$output/qemu.log" &&
   grep -q "$expected_grub_fs" "$output/qemu.log" &&
   grep -q 'bytes=44' "$output/qemu.log" &&
   { [ "$efi_mode" = original-negative ] || ! grep -q 'error: ' "$output/qemu.log"; }; then
  {
    echo 'uefi_probe=passed'
    echo 'loaded_by=stock-GRUB-insmod'
    echo 'source_disk=separate-QEMU-GPT-disk'
    echo 'physical_device_writes=no'
    echo "qemu_exit=$qemu_status"
  } | tee "$output/runtime-result.txt"
  if [ -n "$efi_probe" ]; then
    if [ "$efi_mode" = original-overlay ]; then
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num"
      # Independent ISO9660 metadata+payload oracle, no trust in the
      # Ventoy module's reported virtual-sector count or its CRC.
      expected_crc=$(python3 - "$output/vt-map-image.iso" "$output/vt-overlay.bin" <<'PYCRC'
from pathlib import Path
import sys
import zlib
image = bytearray(Path(sys.argv[1]).read_bytes())
payload = Path(sys.argv[2]).read_bytes()
assert len(image) > 18*2048 and len(image)%2048 == 0 and payload
pvd = image[16*2048:17*2048]
assert pvd[:7] == b'\x01CD001\x01'
start = int.from_bytes(pvd[158:162], 'little')
size = int.from_bytes(pvd[166:170], 'little')
assert 0 < size <= 2048
base = start*2048
cursor = 0
entry = None
while cursor < size:
    length = image[base+cursor]
    if length == 0:
        break
    assert 34 <= length <= size-cursor
    name_bytes = image[base+cursor+32]
    name = image[base+cursor+33:base+cursor+33+name_bytes]
    if name == b'PAYLOAD.BIN;1':
        entry = base + cursor + 2
        break
    cursor += length
assert entry is not None
def both32(number):
    return number.to_bytes(4, 'little')+number.to_bytes(4, 'big')
old_sectors = len(image)//2048
new_sectors = old_sectors + (len(payload)+2047)//2048
image[16*2048+80:16*2048+88] = both32(new_sectors)
image[entry:entry+16] = both32(old_sectors)+both32(len(payload))
image.extend(payload.ljust((new_sectors-old_sectors)*2048, b'\0'))
assert len(image) == new_sectors*2048
print(f'{zlib.crc32(image):08x}')
PYCRC
)
      if ! grep -q 'VT_OVERLAY_ABI_READY' "$output/qemu.log" ||
         ! grep -q 'VT_OVERLAY_PREPARED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_OVERLAY_RETURNED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_SOURCE_STATUS=selected' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_STATUS=verified' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_PUBLISHED=yes' "$output/qemu.log" ||
         ! grep -q "VTOY_ORIGINAL_MEDIA_CRC32=$expected_crc" "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_UNINSTALLED=yes' "$output/qemu.log" ||
         grep -q 'VTOY_ORIGINAL_OVERLAY_FAILED' "$output/qemu.log"; then
        echo 'original_efi_iso_overlay=failed' >&2
        tail -n 125 "$output/qemu.log" >&2
        exit 8
      fi
      echo 'original_efi_iso_overlay=passed' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_blockio_full_crc32=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_iso_file_open=not-tested' >> "$output/runtime-result.txt"
    elif [ "$efi_mode" = original-negative ]; then
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num"
      if ! grep -q 'VTOY_ORIGINAL_BAD_GUID_STATUS=rejected' "$output/qemu.log" ||
         grep -q 'VTOY_ORIGINAL_BAD_GUID_STATUS=selected' "$output/qemu.log"; then
        echo 'original_efi_bad_gpt_guid=not-rejected' >&2
        tail -n 90 "$output/qemu.log" >&2
        exit 8
      fi
      echo 'original_ventoy_efi_app_executed=passed' >> "$output/runtime-result.txt"
      echo 'original_efi_bad_gpt_guid=rejected' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_cd_boot=not-tested' >> "$output/runtime-result.txt"
    elif [ "$efi_mode" = original-boot ]; then
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num"
      expected_crc=$(python3 - "$output/vt-map-image.iso" <<'PYCRC'
import pathlib
import sys
import zlib
print(f"{zlib.crc32(pathlib.Path(sys.argv[1]).read_bytes()):08x}")
PYCRC
)
      if ! grep -q 'VT_ORIGINAL_ISO_EFI_STARTIMAGE_EXECUTED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_ISO_BOOT_RETURNED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_SOURCE_STATUS=selected' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_ISO_DRIVER=started' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_STATUS=verified' "$output/qemu.log" ||
         ! grep -q "VTOY_ORIGINAL_MEDIA_CRC32=$expected_crc" "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_UNINSTALLED=yes' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_BOOT_STATUS=returned' "$output/qemu.log" ||
         grep -q 'VTOY_ORIGINAL_ISO_BOOT_FAILED' "$output/qemu.log"; then
        echo 'original_efi_iso_startimage=failed' >&2
        tail -n 130 "$output/qemu.log" >&2
        exit 8
      fi
      echo 'original_efi_iso_startimage=passed' >> "$output/runtime-result.txt"
      echo 'original_efi_el_torito_catalog=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_blockio_full_crc32=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_iso_driver=started' >> "$output/runtime-result.txt"
    elif [ "$efi_mode" = original-media ]; then
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num"
      expected_crc=$(python3 - "$output/vt-map-image.iso" <<'PYCRC'
import pathlib
import sys
import zlib
print(f"{zlib.crc32(pathlib.Path(sys.argv[1]).read_bytes()):08x}")
PYCRC
)
      if ! grep -q 'VTOY_ORIGINAL_MEDIA_RETURNED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_SOURCE_STATUS=selected' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_STATUS=verified' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_PUBLISHED=yes' "$output/qemu.log" ||
         ! grep -q "VTOY_ORIGINAL_MEDIA_CRC32=$expected_crc" "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_MEDIA_UNINSTALLED=yes' "$output/qemu.log" ||
         grep -q 'VTOY_ORIGINAL_MEDIA_FAILED' "$output/qemu.log"; then
        echo 'original_efi_virtual_media=failed' >&2
        tail -n 110 "$output/qemu.log" >&2
        exit 8
      fi
      echo 'original_ventoy_efi_virtual_media=passed' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_blockio_full_crc32=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_blockio_uninstalled=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_bootloader_start=not-tested' >> "$output/runtime-result.txt"
    elif [ "$efi_mode" = original ]; then
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num"
      if ! grep -q 'VTOY_ORIGINAL_EFI_RETURNED' "$output/qemu.log" ||
         ! grep -q 'VTOY_ORIGINAL_SOURCE_STATUS=selected' "$output/qemu.log" ||
         grep -q 'VTOY_ORIGINAL_EFI_FAILED' "$output/qemu.log"; then
        echo 'original_efi_source_probe=failed' >&2
        tail -n 95 "$output/qemu.log" >&2
        exit 8
      fi
      echo 'original_ventoy_efi_app_executed=passed' >> "$output/runtime-result.txt"
      echo 'original_efi_source_gpt_guid_crc=verified' >> "$output/runtime-result.txt"
      echo 'original_efi_legacy_mbr_collision=resolved' >> "$output/runtime-result.txt"
      echo 'original_efi_virtual_cd_boot=not-tested' >> "$output/runtime-result.txt"
    else
      python3 "$(dirname "$0")/verify-extent-map.py" \
        "$output/qemu.log" "$output/vt-map-image.iso" \
        "$output/iso-disk.img" "$output/iso-map-verification.txt" \
        "$min_extents" "$part_num" efi
      if ! grep -q 'VT_EFI_ORIGINAL_ENV_PARAM_GET_SET_OK' "$output/qemu.log" ||
       ! grep -q 'VT_EFI_GPT_DISK_SELECTED' "$output/qemu.log" ||
       ! grep -q 'VT_EFI_MEMORY_HANDOFF_OK' "$output/qemu.log" ||
       ! grep -q 'VT_EFI_BLOCKMAP_OK crc32=' "$output/qemu.log" ||
       ! grep -q 'VT_EFI_VIRTUAL_BLOCKIO_OK crc32=' "$output/qemu.log" ||
       ! grep -q 'VT_EFI_VIRTUAL_BLOCKIO_UNINSTALLED' "$output/qemu.log" ||
       grep -q 'VTOY_EFI_MEMORY_BRIDGE_FAILED' "$output/qemu.log" ||
       grep -q 'VT_EFI_BLOCKMAP_FAILED' "$output/qemu.log"; then
      echo 'efi_memory_bridge=failed' >&2
      tail -n 75 "$output/qemu.log" >&2
      exit 8
    fi
    echo 'efi_memory_bridge=passed' >> "$output/runtime-result.txt"
    echo 'efi_original_env_param_get_set=verified' >> "$output/runtime-result.txt"
    echo 'efi_gpt_collision=resolved' >> "$output/runtime-result.txt"
    echo 'efi_blockio_full_iso_crc32=verified' >> "$output/runtime-result.txt"
    echo 'efi_virtual_blockio_crc32=verified' >> "$output/runtime-result.txt"
    echo 'efi_virtual_blockio_uninstalled=verified' >> "$output/runtime-result.txt"
    fi
  else
    python3 "$(dirname "$0")/verify-extent-map.py" \
      "$output/qemu.log" "$output/vt-map-image.iso" \
      "$output/iso-disk.img" "$output/iso-map-verification.txt" \
      "$min_extents" "$part_num"
  fi
else
  echo 'uefi_probe=failed' | tee "$output/runtime-result.txt"
  echo "QEMU exit $qemu_status; last serial output:" >&2
  tail -n 85 "$output/qemu.log" >&2
  exit 7
fi
