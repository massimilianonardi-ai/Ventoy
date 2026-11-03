#!/bin/bash
# Builds a new, disposable x86_64 UEFI boot-only GPT disk for the optional
# ORIGINAL Ventoy EDK2 secondary source path. Never opens a host block device.
# The actual ISO lives on a SECOND file-backed GPT disk prepared by the host.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 GRUB-MODULE VENTOY-X64-EFI ISO9660-X64-EFI NEW-OUTPUT-DIR" >&2
  exit 2
fi
module=$1
ventoy=$2
driver=$3
output=$4
for name in "$module" "$ventoy" "$driver"; do
  [[ -s "$name" && -f "$name" && ! -L "$name" ]] || {
    echo "missing regular input: $name" >&2; exit 3;
  }
done
[[ ! -e "$output" && ! -L "$output" ]] || {
  echo "refusing to overwrite destination: $output" >&2; exit 4;
}
for tool in grub-mkimage sgdisk mkfs.vfat mmd mcopy dd gzip sha256sum; do
  command -v "$tool" >/dev/null || { echo "missing utility: $tool" >&2; exit 5; }
done
mkdir -p "$output"
output=$(cd "$output" && pwd -P)

cat > "$output/bootstrap.cfg" <<'GRUB'
serial --unit=0 --speed=115200
terminal_output serial
echo VT_USB_BOOTSTRAP
search --file --set=bootpart /vt-usb-boot.marker
set prefix=($bootpart)/grub
configfile ($bootpart)/grub/runtime.cfg
GRUB

cat > "$output/runtime.cfg" <<'GRUB'
echo VT_USB_RUNTIME_START
search --file --set=bootpart /vt-usb-boot.marker
echo VT_USB_BOOT_DEVICE=$bootpart
search --file --set=isopart /vt-usb.iso
echo VT_USB_ISO_DEVICE=$isopart
if [ -z "$isopart" ]; then
  echo VT_USB_ISO_MISSING
else
  set prefix=($bootpart)/grub
  insmod ($bootpart)/grub/x86_64-efi/ventoy_source_probe.mod
  echo VT_USB_MAP_BEGIN
  vt_extent_probe ($isopart)/vt-usb.iso
  echo VT_USB_MAP_DONE
  if [ -n "$vt_probe_chain_addr" ]; then
    set VTOY_MBOOT_SECONDARY=1
    echo VT_USB_VENTOY_START
    chainloader ($bootpart)/EFI/BOOT/VTOYDIAG.EFI mem:$vt_probe_chain_addr:size:$vt_probe_chain_size gptguid:$vt_probe_gpt_guid env_param=$vt_probe_env_addr mboot_boot_probe=1
    if boot; then
      echo VT_USB_VENTOY_RETURNED
    else
      echo VT_USB_VENTOY_FAILED
    fi
    echo VT_USB_SOURCE_STATUS=$vt_original_source_probe
    echo VT_USB_DRIVER_STATUS=$vt_original_iso_driver
    echo VT_USB_MEDIA_STATUS=$vt_original_media_probe
    echo VT_USB_CRC32=$vt_original_virtual_crc32
    echo VT_USB_PVD_STATUS=$vt_original_virtual_pvd
    echo VT_USB_BOOT_STATUS=$vt_original_boot_probe
    echo VT_USB_TEARDOWN_STATUS=$vt_original_virtual_uninstalled
  else
    echo VT_USB_MAP_UNSUPPORTED
  fi
fi
echo VT_USB_GRUB_FINISHED
halt
GRUB

grub-mkimage --format=x86_64-efi \
  --directory=/usr/lib/grub/x86_64-efi \
  --prefix=/grub --config="$output/bootstrap.cfg" \
  --output="$output/BOOTX64.EFI" \
  part_gpt fat ext2 chain search search_fs_file serial terminal normal configfile test echo halt ls

truncate -s 96M "$output/boot-disk.raw"
sgdisk --clear --new=1:2048:+64M --typecode=1:ef00 \
  "$output/boot-disk.raw" > "$output/gpt.log" 2>&1
sgdisk --verify "$output/boot-disk.raw" >> "$output/gpt.log" 2>&1
truncate -s 64M "$output/boot-part.img"
mkfs.vfat -F 32 -n VTOYBOOT "$output/boot-part.img" > "$output/fat.log" 2>&1
mmd -i "$output/boot-part.img" ::/EFI ::/EFI/BOOT \
  ::/grub ::/grub/x86_64-efi ::/ventoy-secondary \
  ::/ventoy-secondary/ventoy
mcopy -i "$output/boot-part.img" "$output/BOOTX64.EFI" \
  ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$output/boot-part.img" "$ventoy" \
  ::/EFI/BOOT/VTOYDIAG.EFI
mcopy -i "$output/boot-part.img" "$module" \
  ::/grub/x86_64-efi/ventoy_source_probe.mod
mcopy -i "$output/boot-part.img" "$driver" \
  ::/ventoy-secondary/ventoy/iso9660_x64.efi
mcopy -i "$output/boot-part.img" "$output/runtime.cfg" \
  ::/grub/runtime.cfg
printf 'original Ventoy USB-source boot fixture\n' > "$output/vt-usb-boot.marker"
mcopy -i "$output/boot-part.img" "$output/vt-usb-boot.marker" \
  ::/vt-usb-boot.marker
dd if="$output/boot-part.img" of="$output/boot-disk.raw" \
  bs=1M seek=1 conv=notrunc status=none
sgdisk --verify "$output/boot-disk.raw" >> "$output/gpt.log" 2>&1

gzip -n -9 -c "$output/boot-disk.raw" > "$output/boot-disk.raw.gz"
(
  cd "$output"
  sha256sum boot-disk.raw boot-disk.raw.gz > SHA256SUMS
)
{
  echo 'fixture=m-boot-experimental-x86_64-uefi-usb-iso'
  echo 'architecture=x86_64-efi'
  echo 'source_iso=separate-disposable-GPT-FAT32-disk'
  echo 'native_arm64_efi_tested=no'
  echo 'physical_usb_writes=no'
  echo 'grub_core_patched=no'
  echo 'original_ventoy_source=experimental-branch'
} > "$output/BUILD-INFO.txt"
echo "prepared_boot_disk=$output/boot-disk.raw.gz"
