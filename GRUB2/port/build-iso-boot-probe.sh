#!/bin/sh
# Build a genuine, small X64 EFI ISO boot payload with GNU-EFI.
# For experimental QEMU/OVMF only, NEVER deploy as an installer.
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 OUTPUT-DIRECTORY" >&2; exit 2; }
output=$1
[ ! -e "$output" ] || { echo "Output exists: $output" >&2; exit 3; }
mkdir "$output"
output=$(CDPATH= cd "$output" && pwd)
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
linker=$(find /usr/lib -name elf_x86_64_efi.lds -print -quit)
startup=$(find /usr/lib -name crt0-efi-x86_64.o -print -quit)
[ -n "$linker" ] && [ -n "$startup" ] || {
  echo 'GNU-EFI toolchain missing' >&2
  exit 4
}
libdir=$(dirname "$linker")
test -s "$libdir/libefi.a"
test -s "$libdir/libgnuefi.a"

gcc -std=gnu11 -O2 -fpic -fshort-wchar -mno-red-zone \
  -fno-stack-protector -fno-builtin -DGNU_EFI_USE_MS_ABI \
  -I/usr/include/efi -I/usr/include/efi/x86_64 \
  -Wall -Wextra -Werror -c "$here/probe-iso-boot-efi.c" \
  -o "$output/probe-iso-boot-efi.o" > "$output/build.log" 2>&1
ld -nostdlib -znocombreloc -T "$linker" -shared -Bsymbolic \
  -L"$libdir" -o "$output/probe-iso-boot-efi.so" \
  "$startup" "$output/probe-iso-boot-efi.o" -lefi -lgnuefi \
  >> "$output/build.log" 2>&1
objcopy -j .text -j .sdata -j .data -j .dynamic -j .dynsym \
  -j .rel -j .rela -j .reloc -O efi-app-x86_64 \
  "$output/probe-iso-boot-efi.so" "$output/BOOTX64.EFI" \
  >> "$output/build.log" 2>&1
test -s "$output/BOOTX64.EFI"
file "$output/BOOTX64.EFI" | tee "$output/efi-file.txt"
file "$output/BOOTX64.EFI" | grep -q 'EFI application'
sha256sum "$output/BOOTX64.EFI" | tee "$output/efi-sha256.txt"
