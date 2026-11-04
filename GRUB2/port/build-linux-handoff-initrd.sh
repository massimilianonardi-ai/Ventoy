#!/bin/sh
# Build a temporary early Linux initramfs for actual QEMU EFI->kernel test.
# Uses the distribution's UNMODIFIED vmlinuz and matching kernel modules.
set -eu
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo "usage: $0 NEW-OUTPUT-DIRECTORY" >&2
  exit 2
fi
for cmd in gcc python3 cpio gzip modprobe busybox dmsetup ldconfig; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing Linux-initramfs fixture prerequisite: $cmd" >&2; exit 3;
  }
done
out=$1
mkdir "$out"
out=$(CDPATH= cd "$out" && pwd -P)
here=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*generic' -type f -print | sort -V | tail -n 1)
[ -n "$kernel" ] && [ -s "$kernel" ] || {
  echo 'No installed Ubuntu generic kernel image' >&2; exit 4;
}
version=${kernel##*/vmlinuz-}
[ -d "/lib/modules/$version" ] || { echo "Missing matching Linux modules: $version" >&2; exit 5; }
cp "$kernel" "$out/vmlinuz"
root="$out/root"
mkdir -p "$root/bin" "$root/usr/sbin" "$root/dev" "$root/proc" \
  "$root/sys" "$root/run" "$root/mnt/iso" "$root/lib/modules" \
  "$root/etc" "$root/tmp"
cp "$(command -v busybox)" "$root/bin/busybox"
ln -s busybox "$root/bin/sh"
gcc -O2 -static -Wall -Wextra -Werror \
    -o "$root/bin/map-consumer" "$here/probe-linux-efi-consumer.c"
cp "$(command -v dmsetup)" "$root/usr/sbin/dmsetup"
chmod 0755 "$root/usr/sbin/dmsetup"

# Copy the actual shared-library closure and loader for dmsetup, without
# assuming a particular libdevmapper or Ubuntu glibc filesystem layout.
python3 - "$root" "$(command -v dmsetup)" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, binary = Path(sys.argv[1]), sys.argv[2]
output = subprocess.check_output(['ldd', binary], text=True)
paths = set(re.findall(r'=>\s+(/[^ ]+)', output))
paths.update(re.findall(r'^\s*(/[^ ]+)\s+\(', output, re.MULTILINE))
if not paths or 'not found' in output:
    raise SystemExit(f'dmsetup runtime library closure unavailable: {output}')
for pathname in sorted(paths):
    src = Path(pathname)
    if not src.exists():
        raise SystemExit(f'missing runtime library: {pathname}')
    dest = root / pathname.lstrip('/')
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    if 'ld-linux' in src.name and not (dest.stat().st_mode & 0o111):
        raise SystemExit(f'guest ELF loader not executable: {dest}')
print(f'guest_dmsetup_libraries={len(paths)}')
PY

# Preserve real modprobe dependency order. Compressed host modules are
# expanded into .ko files for BusyBox insmod in the guest.
python3 - "$root" "$version" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
loaded = set()
commands = []
for name in ('virtio_pci', 'virtio_blk', 'dm_mod', 'isofs', 'efivarfs'):
    result = subprocess.run(
        ['modprobe', '-S', version, '--show-depends', name],
        text=True, capture_output=True,
    )
    if result.returncode:
        raise SystemExit(f'cannot resolve real {name} kernel module: {result.stderr}')
    for line in result.stdout.splitlines():
        if not line.startswith('insmod '):
            continue
        original = Path(line.split()[1])
        if original in loaded:
            continue
        loaded.add(original)
        if not original.is_file():
            raise SystemExit(f'missing actual Linux kernel module: {original}')
        base = str(original)
        target = root / base.lstrip('/')
        if target.suffix in ('.zst', '.xz', '.gz'):
            target = target.with_suffix('')
        target.parent.mkdir(parents=True, exist_ok=True)
        if original.suffix == '.zst':
            with target.open('wb') as fp:
                subprocess.run(['zstd', '-dc', str(original)], check=True, stdout=fp)
        elif original.suffix == '.xz':
            with target.open('wb') as fp:
                subprocess.run(['xz', '-dc', str(original)], check=True, stdout=fp)
        elif original.suffix == '.gz':
            with target.open('wb') as fp:
                subprocess.run(['gzip', '-dc', str(original)], check=True, stdout=fp)
        else:
            target.write_bytes(original.read_bytes())
        commands.append(f'/bin/busybox insmod /{target.relative_to(root)}')
(root / 'modules.load').write_text('#!/bin/sh\nset -eu\n' + '\n'.join(commands) + '\n')
print(f'guest_kernel_module_count={len(commands)}')
PY

cat > "$root/init" <<'EOF'
#!/bin/sh
# Genuine guest kernel early userspace, not host-side parser simulation.
export PATH=/bin:/usr/sbin
echo VT_LINUX_INITRAMFS_STARTED
/bin/busybox mount -t proc proc /proc || exit 10
/bin/busybox mount -t sysfs sysfs /sys || exit 11
/bin/busybox mount -t devtmpfs devtmpfs /dev || exit 12
exec >/dev/console 2>&1
/bin/busybox mkdir -p /sys/firmware/efi/efivars /run /dev/mapper /mnt/iso
sh /modules.load || { echo VT_LINUX_MODULE_LOAD_FAILED; exit 13; }
/bin/busybox mount -t efivarfs efivarfs /sys/firmware/efi/efivars ||
  { echo VT_LINUX_EFIVARFS_FAILED; exit 14; }
# Only the variable written at GRUB runtime is accepted; no fallback map.
if ! /bin/map-consumer /run/iso-table; then
  echo VT_LINUX_MAP_CONSUMER_FAILED
  exit 15
fi
/usr/sbin/dmsetup create vt_iso_poc --readonly --table "$(/bin/busybox cat /run/iso-table)" ||
  { echo VT_LINUX_DM_CREATE_FAILED; exit 16; }
/bin/busybox test -b /dev/mapper/vt_iso_poc ||
  { echo VT_LINUX_DM_DEVICE_MISSING; exit 17; }
/bin/busybox sha256sum /dev/mapper/vt_iso_poc > /run/iso.sha ||
  { echo VT_LINUX_DM_READ_FAILED; exit 18; }
read digest rest < /run/iso.sha
echo "VT_LINUX_ISO_SHA256=$digest"
/bin/busybox mount -t iso9660 -o ro /dev/mapper/vt_iso_poc /mnt/iso ||
  { echo VT_LINUX_ISO9660_MOUNT_FAILED; exit 19; }
if [ "$(/bin/busybox cat /mnt/iso/.pve-cd-id.txt)" != pve-efi-linux-poc-media-id-2026-11-04 ]; then
  echo VT_LINUX_ISO_IDENTITY_FAILED
  exit 20
fi
echo VT_LINUX_ISO_IDENTITY_PASS
echo VT_LINUX_HANDOFF_PASS
/bin/busybox poweroff -f
EOF
chmod 0755 "$root/init" "$root/modules.load"
(
  cd "$root"
  find . -print0 | cpio -o -0 --format=newc 2>/dev/null | gzip -1
) > "$out/initrd.img"
[ -s "$out/initrd.img" ]
# The installed Ubuntu /boot/vmlinuz is root-readable; the disposable
# copies must be readable by the unprivileged QEMU/GRUB fixture builder.
chmod 0644 "$out/vmlinuz" "$out/initrd.img"
{
  printf 'linux_version=%s\n' "$version"
  printf 'kernel_original=%s\n' "$kernel"
  printf 'kernel_sha256=%s\n' "$(sha256sum "$kernel" | awk '{print $1}')"
  printf 'efi_runtime_handoff=unvalidated_until_qemu\n'
  printf 'module_bundle=actual_distribution_modules\n'
} > "$out/provenance.txt"
printf 'LINUX_INITRD_PREPARED kernel=%s initrd_bytes=%s\n' \
    "$version" "$(stat -c %s "$out/initrd.img")"
