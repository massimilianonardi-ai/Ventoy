#!/bin/bash
# Disposable x86_64 UEFI test launched from Ubuntu ARM64 (QEMU TCG).
# Never opens a host physical device or writes the input ISO/USB.
set -euo pipefail

help() {
  cat <<'HELP'
Usage: run-usb-iso-arm64-host.sh --bundle DIR --iso /mounted/usb/file.iso
                                --output DIR [--headless] [--prepare-only]
                                [--timeout-sec N] [--expect-marker TEXT]
                                [--firmware-code FILE --firmware-vars FILE]
Creates two NEW file-backed GPT disks and boots a QEMU x86_64 UEFI guest:
  boot-disk.raw from the experimental Ventoy/stock-GRUB boot bundle;
  iso-disk.raw with a byte-identical FAT32 copy of the USB ISO.
The input ISO is NEVER written or mounted by this script. No loop devices,
sudo, real disks, firmware NVRAM, or USB writes. QEMU uses -snapshot.
The guest is x86_64 EMULATED on ARM64, not an ARM64-native Ventoy test.
The FAT32 transport requires an ISO under 4 GiB. Boot into the actual
installer must be OBSERVED; QEMU exit alone is not an installer PASS.
HELP
}
fail() { printf 'usb-iso-qemu: ERROR: %s\n' "$1" >&2; exit 1; }
say() { printf 'usb-iso-qemu: %s\n' "$1"; }
bundle=; iso=; output=; code=; vars=; headless=no; prepare=no
marker=; duration=0
while (( $# )); do
  case "$1" in
    --bundle|--iso|--output|--firmware-code|--firmware-vars|--expect-marker|--timeout-sec)
      (( $# >= 2 )) && [[ -n "$2" ]] || fail "missing argument for $1"
      case "$1" in
        --bundle) bundle=$2 ;;
        --iso) iso=$2 ;;
        --output) output=$2 ;;
        --firmware-code) code=$2 ;;
        --firmware-vars) vars=$2 ;;
        --expect-marker) marker=$2 ;;
        --timeout-sec) duration=$2 ;;
      esac
      shift 2 ;;
    --headless) headless=yes; shift ;;
    --prepare-only) prepare=yes; shift ;;
    -h|--help) help; exit 0 ;;
    *) fail "unexpected argument $1" ;;
  esac
done
[[ -n "$bundle" && -n "$iso" && -n "$output" ]] || { help >&2; exit 2; }
[[ "$duration" =~ ^[0-9]+$ ]] || fail 'invalid timeout seconds'
[[ "$(uname -s)" == Linux ]] || fail 'requires Linux'
[[ -f "$iso" && -r "$iso" && ! -L "$iso" ]] ||
  fail 'ISO must be a readable regular file (no devices or symlinks)'
[[ -d "$bundle" && ! -L "$bundle" && -d "$output" && ! -L "$output" ]] ||
  fail 'bundle and output must be existing directories'
iso=$(realpath -- "$iso")
bundle=$(cd "$bundle" && pwd -P)
output=$(cd "$output" && pwd -P)
[[ "$iso" != /dev/* && "$output" != /dev/* ]] ||
  fail 'physical device path is forbidden'
[[ "$(stat -c %d "$iso")" != "$(stat -c %d "$output")" ]] ||
  fail 'output must be on a filesystem different from the ISO/USB'
for tool in qemu-system-x86_64 sgdisk mkfs.vfat mcopy mtype \
            sha256sum gzip python3 stat realpath truncate awk grep timeout tee; do
  command -v "$tool" >/dev/null || fail "missing utility: $tool"
done
[[ -s "$bundle/boot-disk.raw.gz" && -s "$bundle/SHA256SUMS" &&
   -s "$bundle/BUILD-INFO.txt" ]] || fail 'incomplete prepared boot bundle'
grep -Fx 'architecture=x86_64-efi' "$bundle/BUILD-INFO.txt" >/dev/null ||
  fail 'bundle is not x86_64 UEFI'
grep -Fx 'fixture=m-boot-experimental-x86_64-uefi-usb-iso' \
  "$bundle/BUILD-INFO.txt" >/dev/null || fail 'unknown fixture'
if [[ -z "$code" && -z "$vars" ]]; then
  for dir in /usr/share/OVMF /usr/share/edk2/ovmf; do
    for suffix in _4M ''; do
      if [[ -s "$dir/OVMF_CODE$suffix.fd" && -s "$dir/OVMF_VARS$suffix.fd" ]]; then
        code="$dir/OVMF_CODE$suffix.fd"
        vars="$dir/OVMF_VARS$suffix.fd"
        break 2
      fi
    done
  done
fi
[[ -s "$code" && -s "$vars" && "$code" != "$vars" ]] ||
  fail 'missing matching x86_64 OVMF CODE/VARS (pass firmware paths)'
size=$(stat -c %s "$iso")
(( size > 32768 && size < 4294967295 && size % 2048 == 0 )) ||
  fail 'ISO size must be 2048-byte aligned, larger than 32 KiB, under 4 GiB'
python3 - "$iso" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    f.seek(32768)
    signature = f.read(7)
if signature != b'\x01CD001\x01':
    raise SystemExit('usb-iso-qemu: invalid ISO9660 primary descriptor')
PY

umask 077
work=$(mktemp -d "$output/m-boot-usb-iso.XXXXXXXX") ||
  fail 'cannot create private disk workspace'
say "workspace=$work"
cp -- "$vars" "$work/vars.fd"
gz_hash=$(awk '$2 == "boot-disk.raw.gz" {print $1}' "$bundle/SHA256SUMS")
raw_hash=$(awk '$2 == "boot-disk.raw" {print $1}' "$bundle/SHA256SUMS")
[[ "$gz_hash" =~ ^[[:xdigit:]]{64}$ && "$raw_hash" =~ ^[[:xdigit:]]{64}$ ]] ||
  fail 'invalid SHA256 manifest'
read_hash=$(sha256sum "$bundle/boot-disk.raw.gz" | awk '{print $1}')
[[ "$read_hash" == "$gz_hash" ]] || fail 'compressed boot image hash mismatch'
gzip -dc -- "$bundle/boot-disk.raw.gz" > "$work/boot-disk.raw"
read_hash=$(sha256sum "$work/boot-disk.raw" | awk '{print $1}')
[[ "$read_hash" == "$raw_hash" ]] || fail 'boot image hash mismatch'
sgdisk --verify "$work/boot-disk.raw" > "$work/boot-gpt-check.log" 2>&1 ||
  fail 'boot GPT invalid'

# mtools and mkfs.fat offset operate ONLY on this file-backed image.
# No loop device or mount of a real USB partition is needed.
iso_hash=$(sha256sum "$iso" | awk '{print $1}')
part_mib=$(( (size + 256*1048576 + 1048575) / 1048576 ))
(( part_mib >= 512 )) || part_mib=512
truncate -s "$(((part_mib+16)*1048576))" "$work/iso-disk.raw"
sgdisk --clear --new="1:2048:+$part_mib"M --typecode=1:0700 \
  "$work/iso-disk.raw" > "$work/iso-gpt.log" 2>&1 ||
  fail 'source file-backed GPT creation failed'
mkfs.vfat -F 32 --offset 2048 -n MBOOTISO \
  "$work/iso-disk.raw" "$((part_mib*1024))" \
  > "$work/iso-fat.log" 2>&1 ||
  fail 'source file-backed FAT32 format failed'
mcopy -i "$work/iso-disk.raw@@1M" "$iso" ::/vt-usb.iso \
  > "$work/iso-copy.log" 2>&1 ||
  fail 'copy of USB ISO to new FAT32 disk failed'
sgdisk --verify "$work/iso-disk.raw" >> "$work/iso-gpt.log" 2>&1 ||
  fail 'source file-backed GPT no longer valid'
copy_hash=$(mtype -i "$work/iso-disk.raw@@1M" ::/vt-usb.iso |
  sha256sum | awk '{print $1}')
[[ "$iso_hash" == "$copy_hash" ]] || fail 'ISO source/copy SHA256 differs'
{
  printf 'host_arch=%s\n' "$(uname -m)"
  printf 'guest_arch=x86_64\n'
  printf 'usb_iso_path=%s\n' "$iso"
  printf 'usb_iso_sha256=%s\n' "$iso_hash"
  printf 'copied_iso_sha256=%s\n' "$copy_hash"
  printf 'boot_disk_sha256=%s\n' "$raw_hash"
  printf 'source_usb_writes=no\nphysical_device_writes=no\n'
  printf 'installer_boot_verified=no\n'
} > "$work/test-info.txt"
say "verified USB ISO copy SHA256=$copy_hash"
say "boot image: $work/boot-disk.raw"
say "ISO image: $work/iso-disk.raw"
if [[ "$prepare" == yes ]]; then
  say 'PREPARED: no firmware boot attempted'
  exit 0
fi
if [[ "$headless" == no && -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" ]]; then
  fail 'no desktop display; use --headless (OS graphics not visible)'
fi

set -- -machine q35 -accel tcg -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$work/vars.fd" \
  -drive "if=none,format=raw,file=$work/boot-disk.raw,id=mboot" \
  -device virtio-blk-pci,drive=mboot,bootindex=1 \
  -drive "if=none,format=raw,file=$work/iso-disk.raw,id=source" \
  -device virtio-blk-pci,drive=source,bootindex=2 \
  -snapshot -serial mon:stdio
if [[ "$headless" == yes ]]; then
  set -- "$@" -display none
fi
say 'running QEMU x86_64 UEFI via TCG (Ubuntu ARM64 is host, NOT EFI guest)'
set +e
if (( duration > 0 )); then
  timeout --signal=INT "$duration" qemu-system-x86_64 "$@" \
    2>&1 | tee "$work/qemu.log"
  result=$?
else
  qemu-system-x86_64 "$@" 2>&1 | tee "$work/qemu.log"
  result=$?
fi
set -e
printf 'qemu_exit=%s\n' "$result" >> "$work/test-info.txt"
if [[ -n "$marker" ]]; then
  if grep -Fq -- "$marker" "$work/qemu.log"; then
    say "PASS: explicit test EFI marker observed ($marker)"
    printf 'known_efi_marker=passed\n' >> "$work/test-info.txt"
    exit 0
  fi
  fail "expected EFI marker absent; inspect $work/qemu.log"
fi
say "QEMU exited with status $result; manual OS boot observation still required"
say "saved log: $work/qemu.log"
if (( result != 0 && result != 124 && result != 130 )); then
  fail "QEMU failed with code $result"
fi
