#!/usr/bin/env bash
# Run an experimental x86_64 UEFI boot disk on an ARM64 Ubuntu host.
# The operator's USB is read ONLY through a qcow2 raw backing file.
set -euo pipefail

usage()
{
  cat <<'HELP'
Usage: run-physical-usb-uefi.sh ISO-PATH BOOT-BUNDLE-DIR OUTPUT-DIR
All arguments must already exist. Uses a new private workspace in OUTPUT-DIR.

The ISO must be /m/boot/iso/proxmox-ve_9.2-1.iso on a mounted ext4
MBOOTDATA partition 3 of an actual USB-transport GPT disk.
After inspecting the USB identity, type the requested confirmation.
Only then the script unmounts this USB data partition from the host.

No ISO copies, no physical USB writes: the USB is backing storage of a
NEW qcow2 overlay, and QEMU also uses -snapshot. QEMU monitor is disabled.
If needed, the logged-in user gets a TEMPORARY read-only USB-device ACL;
it is revoked when QEMU exits, including on errors or Ctrl-C.
Host architecture may be ARM64; guest architecture is x86_64 UEFI.
Close the QEMU window after observing Proxmox; do not install to a disk.
HELP
}
fail() { printf 'm-boot physical USB: ERROR: %s\n' "$1" >&2; exit 1; }
note() { printf 'm-boot physical USB: %s\n' "$1"; }
if [[ $# -eq 1 && "$1" == "--help" ]]; then usage; exit 0; fi
[[ $# -eq 3 ]] || { usage >&2; exit 2; }
iso=$1
bundle=$2
output=$3
[[ -f "$iso" && -r "$iso" && ! -L "$iso" ]] ||
  fail 'source ISO must be a readable regular file (not a symlink)'
[[ -d "$bundle" && ! -L "$bundle" && -d "$output" && ! -L "$output" ]] ||
  fail 'bundle/output must be existing real directories'
iso=$(readlink -f -- "$iso")
bundle=$(cd -- "$bundle" && pwd -P)
output=$(cd -- "$output" && pwd -P)
[[ "$iso" == */m/boot/iso/proxmox-ve_9.2-1.iso ]] ||
  fail 'unexpected source ISO pathname'
[[ "$(stat -c %d "$iso")" != "$(stat -c %d "$output")" ]] ||
  fail 'output directory is on the physical USB'
for tool in qemu-system-x86_64 qemu-img sgdisk lsblk findmnt \
            sha256sum gzip dd awk grep sudo getfacl setfacl; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "missing executable: $tool"
done
[[ -s "$bundle/boot-disk.raw.gz" &&
   -s "$bundle/SHA256SUMS" && -s "$bundle/RAW-SHA256SUMS" &&
   -s "$bundle/BUILD-INFO.txt" && -s "$bundle/test-result.txt" ]] ||
  fail 'boot bundle not complete; use the published verified bundle'
grep -Fx 'architecture=x86_64-efi' "$bundle/BUILD-INFO.txt" >/dev/null ||
  fail 'wrong boot architecture'
grep -Fx 'source_iso_guest_path=/m/boot/iso/proxmox-ve_9.2-1.iso' \
  "$bundle/BUILD-INFO.txt" >/dev/null ||
  fail 'boot image expects another source ISO'
grep -Fx 'synthetic_ext4_gpt_source_efi_startimage=passed' \
  "$bundle/test-result.txt" >/dev/null ||
  fail 'missing boot image firmware test result'

[[ "$(findmnt -n -o FSTYPE -T "$iso")" == ext4 ]] ||
  fail 'expected ext4 source'
part=$(readlink -f -- "$(findmnt -n -o SOURCE -T "$iso")")
[[ -b "$part" ]] || fail 'ISO is not on a block partition'
[[ "$(lsblk -n -o PARTN "$part" | awk 'NR==1 {print $1}')" == 3 ]] ||
  fail 'expected USB GPT partition 3'
[[ "$(lsblk -n -o LABEL "$part" | awk 'NR==1 {print $1}')" == MBOOTDATA ]] ||
  fail 'expected MBOOTDATA ext4 partition'
parent=$(lsblk -n -o PKNAME "$part" | awk 'NR==1 {print $1}')
[[ -n "$parent" && "$parent" != */* ]] ||
  fail 'cannot determine USB parent'
device="/dev/$parent"
[[ -b "$device" ]] || fail 'USB device not found'
[[ "$(lsblk -dn -o TYPE "$device" | awk '{print $1}')" == disk ]] ||
  fail 'parent is not a disk'
[[ "$(lsblk -dn -o TRAN "$device" | awk '{print $1}')" == usb ]] ||
  fail 'disk is not USB transport'
[[ "$(lsblk -dn -o LOG-SEC "$device" | awk '{print $1}')" == 512 ]] ||
  fail 'disk is not 512-byte-sector media'
[[ "$(lsblk -dn -o PTTYPE "$device" | awk '{print $1}')" == gpt ]] ||
  fail 'disk has no GPT'
root_src=$(findmnt -n -o SOURCE -T /)
[[ "$root_src" != "$device"* ]] || fail 'selected device holds the system root'
for node in $(lsblk -nrpo NAME "$device"); do
  if [[ "$node" != "$part" ]] &&
     findmnt -n -S "$node" >/dev/null; then
    fail "another USB partition is mounted: $node"
  fi
done

code=; vars=
for dir in /usr/share/OVMF /usr/share/edk2/ovmf; do
  for suffix in _4M ''; do
    if [[ -s "$dir/OVMF_CODE$suffix.fd" &&
       -s "$dir/OVMF_VARS$suffix.fd" ]]; then
      code="$dir/OVMF_CODE$suffix.fd"
      vars="$dir/OVMF_VARS$suffix.fd"
      break 2
    fi
  done
done
[[ -n "$code" && -n "$vars" ]] || fail 'no matching OVMF CODE/VARS'
umask 077
work=$(mktemp -d "$output/mboot-usb.XXXXXXXX") ||
  fail 'cannot make private workspace'
overlay="$work/usb-write-overlay.qcow2"
acl_changed=no
finish()
{
  status=$?
  trap - EXIT
  if [[ "$acl_changed" == yes ]]; then
    sudo setfacl -x "u:$(id -un)" "$device" ||
      echo "WARNING: manually revoke temporary user ACL on $device" >&2
  fi
  if [[ -f "$overlay" ]]; then
    rm -f -- "$overlay"
  fi
  exit "$status"
}
trap finish EXIT

( cd "$bundle" && sha256sum -c SHA256SUMS )
raw_sha=$(awk '$2=="boot-disk.raw" {print $1}' "$bundle/RAW-SHA256SUMS")
[[ "$raw_sha" =~ ^[0-9a-f]{64}$ ]] || fail 'raw SHA256 manifest invalid'
gzip -dc "$bundle/boot-disk.raw.gz" |
  dd of="$work/boot-disk.raw" bs=4M iflag=fullblock \
    conv=sparse,fsync status=none
[[ "$(sha256sum "$work/boot-disk.raw" | awk '{print $1}')" == "$raw_sha" ]] ||
  fail 'boot disk raw hash mismatch'
sgdisk --verify "$work/boot-disk.raw" > "$work/gpt-verify.log" 2>&1 ||
  fail 'boot disk GPT invalid'
cp -- "$vars" "$work/vars.fd"
printf 'target=%s\nsource_iso=%s\n' "$device" "$iso" |
  tee "$work/test-info.txt"
lsblk -o NAME,TYPE,TRAN,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$device"
note "The real USB ($device) will be UNMOUNTED, not modified."
note 'The guest uses a disposable qcow2 overlay and snapshot isolation.'
printf 'Type exactly TEST %s to continue: ' "$device"
IFS= read -r answer
[[ "$answer" == "TEST $device" ]] || fail 'not confirmed'
sudo -v
sudo umount "$part" || fail 'failed unmount of USB data partition'
for node in $(lsblk -nrpo NAME "$device"); do
  if findmnt -n -S "$node" >/dev/null; then
    fail "USB is still mounted: $node"
  fi
done
if [[ ! -r "$device" ]]; then
  if getfacl -cp "$device" | grep -Fq "user:$(id -un):"; then
    fail 'existing device user ACL cannot be overridden automatically'
  fi
  sudo setfacl -m "u:$(id -un):r--" "$device" ||
    fail 'cannot grant temporary read-only access to the USB'
  acl_changed=yes
fi
[[ -r "$device" ]] || fail 'cannot read physical USB'
qemu-img create -f qcow2 -F raw -b "$device" "$overlay" |
  tee "$work/overlay-create.log"
qemu-img info "$overlay" > "$work/overlay-info.txt"
grep -F "backing file: $device" "$work/overlay-info.txt" >/dev/null ||
  fail 'qcow2 has incorrect backing device'

note "QEMU starting. Log: $work/qemu.log"
note 'Observe initial Proxmox installer only; do not start installation.'
set -- -machine q35 -accel tcg -m 3072 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$work/vars.fd" \
  -drive "if=none,id=mboot,format=raw,file=$work/boot-disk.raw" \
  -device virtio-blk-pci,drive=mboot,bootindex=1 \
  -drive "if=none,id=usbiso,format=qcow2,file=$overlay" \
  -device virtio-blk-pci,drive=usbiso,bootindex=2 \
  -snapshot -no-reboot -monitor none -serial stdio
set +e
qemu-system-x86_64 "$@" 2>&1 | tee "$work/qemu.log"
qemu_rc=$?
set -e
printf 'qemu_exit=%s\n' "$qemu_rc" >> "$work/test-info.txt"
note "QEMU exit $qemu_rc. Logs remain in $work"
note 'Installer boot status requires actual GUI observation.'
exit "$qemu_rc"
