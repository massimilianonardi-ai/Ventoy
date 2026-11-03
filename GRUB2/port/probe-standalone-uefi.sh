#!/bin/sh
# Disposable, no-core-change GRUB module load proof with two QEMU disks.
# Uses only files under a newly created output directory; never a host disk.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 COMPILED-MOD OUTPUT-DIR" >&2
  exit 2
fi

module=$1
output=$2
[ -s "$module" ] || { echo 'Nonempty compiled module required' >&2; exit 3; }
[ ! -e "$output" ] || { echo 'Output directory already exists' >&2; exit 4; }

for binary in grub-mkimage sgdisk mkfs.vfat mmd mcopy qemu-system-x86_64 timeout grep dd; do
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
echo VTOY_BOOT_DEVICE=$bootpart
ls
search --file --set=isopart /vt-probe-image.iso
echo VTOY_ISO_DEVICE=$isopart
if [ -z "$bootpart" ] || [ -z "$isopart" ] || [ "$bootpart" = "$isopart" ]; then
  echo VTOY_NO_CORE_PROBE_DIFFERENT_DISKS_REQUIRED
  halt
fi
set prefix=($bootpart)/grub
insmod ($bootpart)/grub/x86_64-efi/ventoy_source_probe.mod
if vt_source_probe ($isopart)/vt-probe-image.iso; then
  echo VTOY_NO_CORE_PROBE_SUCCESS
else
  echo VTOY_NO_CORE_PROBE_SOURCE_FAILED
fi
halt
EOF

grub-mkimage --format=x86_64-efi \
  --directory=/usr/lib/grub/x86_64-efi \
  --prefix=/grub --config="$output/bootstrap.cfg" \
  --output="$output/BOOTX64.EFI" \
  part_gpt fat search search_fs_file serial terminal normal configfile test echo halt ls

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
  mkfs.vfat -F 32 "$part" > "$output/$target-fat.log" 2>&1
done

mmd -i "$output/boot-part.img" ::/EFI ::/EFI/BOOT ::/grub ::/grub/x86_64-efi
mcopy -i "$output/boot-part.img" "$output/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$output/boot-part.img" "$module" ::/grub/x86_64-efi/ventoy_source_probe.mod
mcopy -i "$output/boot-part.img" "$output/runtime.cfg" ::/grub/runtime.cfg
echo 'bootloader marker' > "$output/vt-probe-boot.marker"
mcopy -i "$output/boot-part.img" "$output/vt-probe-boot.marker" ::/vt-probe-boot.marker

echo 'source-location fixture, not a bootable ISO' > "$output/vt-probe-image.iso"
mcopy -i "$output/iso-part.img" "$output/vt-probe-image.iso" ::/vt-probe-image.iso

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
  -device virtio-blk-pci,drive=iso \
  -display none -serial mon:stdio -snapshot \
  > "$output/qemu.log" 2>&1
qemu_status=$?
set -e

if grep -q 'VTOY_NO_CORE_PROBE_SUCCESS' "$output/qemu.log" &&
   grep -q 'source=.*disk=.*partition=.*fs=.*bytes=' "$output/qemu.log" &&
   ! grep -q 'VTOY_NO_CORE_PROBE_DIFFERENT_DISKS_REQUIRED' "$output/qemu.log"; then
  {
    echo 'uefi_probe=passed'
    echo 'loaded_by=stock-GRUB-insmod'
    echo 'source_disk=separate-QEMU-GPT-disk'
    echo 'physical_device_writes=no'
    echo "qemu_exit=$qemu_status"
  } | tee "$output/runtime-result.txt"
else
  echo 'uefi_probe=failed' | tee "$output/runtime-result.txt"
  echo "QEMU exit $qemu_status; last serial output:" >&2
  tail -n 85 "$output/qemu.log" >&2
  exit 7
fi
