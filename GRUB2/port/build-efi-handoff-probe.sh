#!/bin/sh
# Build a disposable EFI metadata consumer from GNU-EFI, not Ventoy's app.
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 NEW-OUTPUT-DIR" >&2; exit 2; }
output=$1
[ ! -e "$output" ] || { echo "Output exists: $output" >&2; exit 3; }
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
mkdir "$output"
output=$(CDPATH= cd "$output" && pwd)

linker=$(find /usr/lib -name elf_x86_64_efi.lds -print -quit)
startup=$(find /usr/lib -name crt0-efi-x86_64.o -print -quit)
[ -n "$linker" ] && [ -n "$startup" ] || {
  echo 'Missing GNU-EFI development objects' >&2
  exit 4
}
libdir=$(dirname "$linker")
test -f "$libdir/libefi.a" || { echo 'GNU-EFI libefi.a missing' >&2; exit 5; }
test -f "$libdir/libgnuefi.a" || { echo 'GNU-EFI libgnuefi.a missing' >&2; exit 6; }
printf 'gnuefi_libdir=%s\n' "$libdir" > "$output/provenance.txt"

gcc -std=gnu11 -O2 -fpic -fshort-wchar -mno-red-zone \
  -fno-stack-protector -fno-builtin -DEFI_FUNCTION_WRAPPER \
  -I/usr/include/efi -I/usr/include/efi/x86_64 \
  -Wall -Wextra -Werror -c "$here/probe-efi-app.c" \
  -o "$output/probe-efi-app.o" > "$output/build.log" 2>&1
ld -nostdlib -znocombreloc -T "$linker" -shared -Bsymbolic \
  -L"$libdir" -o "$output/probe-efi-app.so" \
  "$startup" "$output/probe-efi-app.o" -lefi -lgnuefi \
  >> "$output/build.log" 2>&1
objcopy -j .text -j .sdata -j .data -j .dynamic -j .dynsym \
  -j .rel -j .rela -j .reloc -O efi-app-x86_64 \
  "$output/probe-efi-app.so" "$output/VTOYDIAG.EFI" \
  >> "$output/build.log" 2>&1
test -s "$output/VTOYDIAG.EFI"
file "$output/VTOYDIAG.EFI" | tee "$output/efi-file.txt"
