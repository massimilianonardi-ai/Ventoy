#!/bin/sh
# Disposable, no-core-change GRUB module load proof with two QEMU disks.
# Uses only files under a newly created output directory; never a host disk.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 COMPILED-MOD OUTPUT-DIR [fat32|ext4]" >&2
  exit 2
fi

module=$1
output=$2
source_fs=${3:-fat32}
case "$source_fs" in
  fat32) expected_grub_fs='fs=fat'; min_extents=2 ;;
  ext4) expected_grub_fs='fs=ext2'; min_extents=1 ;;
  *) echo "Unsupported source filesystem: $source_fs" >&2; exit 2 ;;
esac
[ -s "$module" ] || { echo 'Nonempty compiled module required' >&2; exit 3; }
[ ! -e "$output" ] || { echo 'Output directory already exists' >&2; exit 4; }

for binary in grub-mkimage sgdisk mkfs.vfat mkfs.ext4 debugfs mmd mcopy mdel qemu-system-x86_64 timeout grep dd python3 cmp xorriso; do
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
echo VTOY_NO_CORE_PROBE_COMPLETED
halt
EOF

grub-mkimage --format=x86_64-efi \
  --directory=/usr/lib/grub/x86_64-efi \
  --prefix=/grub --config="$output/bootstrap.cfg" \
  --output="$output/BOOTX64.EFI" \
  part_gpt fat ext2 search search_fs_file serial terminal normal configfile test echo halt ls

# Each target is an isolated NEW GPT image, not a host or loop device.
for target in boot iso; do
  part="$output/$target-part.img"
  disk="$output/$target-disk.img"
  truncate -s 64M "$part"
  truncate -s 96M "$disk"
  type=8300
  if [ "$target" = boot ]; then
    type=ef00
  fi
  sgdisk --clear --new=1:2048:+64M --typecode="1:$type" "$disk" \
    > "$output/$target-gpt.log" 2>&1
  if [ "$target" = boot ] || [ "$source_fs" = fat32 ]; then
    mkfs.vfat -F 32 "$part" > "$output/$target-fat.log" 2>&1
  fi
done

mmd -i "$output/boot-part.img" ::/EFI ::/EFI/BOOT ::/grub ::/grub/x86_64-efi
mcopy -i "$output/boot-part.img" "$output/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$output/boot-part.img" "$module" ::/grub/x86_64-efi/ventoy_source_probe.mod
mcopy -i "$output/boot-part.img" "$output/runtime.cfg" ::/grub/runtime.cfg
echo 'bootloader marker' > "$output/vt-probe-boot.marker"
mcopy -i "$output/boot-part.img" "$output/vt-probe-boot.marker" ::/vt-probe-boot.marker

echo 'source-location fixture, not a bootable ISO' > "$output/vt-probe-image.iso"

# Create a genuine ISO9660 filesystem with deterministic, nonuniform data.
# The bytes are intentionally NOT a hand-written fake ISO header.
mkdir "$output/iso-content"
python3 - "$output/iso-content/payload.bin" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "wb") as stream:
    for index in range(4096):
        stream.write(hashlib.sha256(index.to_bytes(4, "big")).digest() * 16)
PY
xorriso -as mkisofs -quiet -R -J -V VTOY_MAP_TEST \
  -o "$output/vt-map-image.iso" "$output/iso-content" \
  > "$output/xorriso.log" 2>&1

# ISO9660 bytes 0..32767 are the reserved System Area. Nonzero data
# here makes the ext4 fixture's initial file blocks non-sparse when
# populated by mkfs.ext4 -d; the primary volume descriptor is untouched.
python3 - "$output/vt-map-image.iso" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "r+b") as stream:
    # Fill only the ISO9660 System Area (first 16 sectors of 2048 bytes)
    # and the known zero-only alignment gap in THIS xorriso-generated
    # diagnostic fixture. Do not modify actual installation ISOs.
    for index in range(1024):
        stream.write(hashlib.sha256(index.to_bytes(4, "big")).digest())
    for block in range(13, 16):
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
xorriso -indev "$output/vt-map-image.iso" -extract /payload.bin \
  "$output/extracted-payload.bin" >> "$output/xorriso.log" 2>&1
cmp "$output/iso-content/payload.bin" "$output/extracted-payload.bin"

if [ "$source_fs" = fat32 ]; then
  mcopy -i "$output/iso-part.img" "$output/vt-probe-image.iso" ::/vt-probe-image.iso

  # Force noncontiguous FAT allocation before copying the real ISO.
  truncate -s 1M "$output/filler-A.bin"
  truncate -s 1536K "$output/filler-B.bin"
  truncate -s 1M "$output/filler-C.bin"
  truncate -s 58M "$output/filler-D.bin"
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
  dd if="$output/$target-part.img" of="$output/$target-disk.img" \
    bs=1M seek=1 conv=notrunc status=none
done

# OVMF runs without Secure Boot on two file-backed virtual disks.
set +e
timeout 90 qemu-system-x86_64 -machine q35 -accel tcg -m 1024 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$output/vars.fd" \
  -drive "if=none,format=raw,file=$output/boot-disk.img,id=boot" \
  -device virtio-blk-pci,drive=boot,bootindex=1 \
  -drive "if=none,format=raw,file=$output/iso-disk.img,id=iso" \
  -device virtio-blk-pci,drive=iso,bootindex=2 \
  -display none -serial mon:stdio -snapshot \
  > "$output/qemu.log" 2>&1
qemu_status=$?
set -e

if grep -q 'VTOY_EXTENT_MAP_DONE' "$output/qemu.log" &&
   grep -q 'VT_CHAIN_SUCCESS' "$output/qemu.log" &&
   grep -q 'VT_MAP_SUCCESS' "$output/qemu.log" &&
   grep -q 'VTOY_NO_CORE_PROBE_COMPLETED' "$output/qemu.log" &&
   grep -q 'VTOY_BOOT_DEVICE=hd0,gpt1' "$output/qemu.log" &&
   grep -q 'VTOY_ISO_DEVICE=hd1,gpt1' "$output/qemu.log" &&
   grep -q 'source=(hd1,gpt1)/vt-probe-image.iso disk=hd1 partition=1' "$output/qemu.log" &&
   grep -q "$expected_grub_fs" "$output/qemu.log" &&
   grep -q 'bytes=44' "$output/qemu.log" &&
   ! grep -q 'error: ' "$output/qemu.log"; then
  {
    echo 'uefi_probe=passed'
    echo 'loaded_by=stock-GRUB-insmod'
    echo 'source_disk=separate-QEMU-GPT-disk'
    echo 'physical_device_writes=no'
    echo "qemu_exit=$qemu_status"
  } | tee "$output/runtime-result.txt"
  python3 "$(dirname "$0")/verify-extent-map.py" \
    "$output/qemu.log" "$output/vt-map-image.iso" \
    "$output/iso-disk.img" "$output/iso-map-verification.txt" \
    "$min_extents"
else
  echo 'uefi_probe=failed' | tee "$output/runtime-result.txt"
  echo "QEMU exit $qemu_status; last serial output:" >&2
  tail -n 85 "$output/qemu.log" >&2
  exit 7
fi
