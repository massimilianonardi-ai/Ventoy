#!/bin/sh
# Build only an experimental GRUB .mod against the runner distro sources.
# Do not compile or patch GRUB core, stage a release, or write to devices.
set -eu

if [ "$#" -ne 2 ]; then
  echo 'usage: probe-standalone-module.sh DISTRO-GRUB-SOURCE OUTPUT-DIR' >&2
  exit 2
fi

source=$1
output=$2
here=$(CDPATH= cd "$(dirname "$0")" && pwd)

[ -f "$source/configure.ac" ] || { echo 'Distribution GRUB source missing' >&2; exit 3; }
[ ! -e "$output" ] || { echo 'Output directory already exists' >&2; exit 4; }
[ -f "$here/probe-source.c" ] || { echo 'Source-location test module missing' >&2; exit 5; }

mkdir "$output"
output=$(CDPATH= cd "$output" && pwd)
mkdir "$output/source"
cp -a "$source/." "$output/source/"
mkdir -p "$output/source/grub-core/ventoy"
cp "$here/probe-source.c" "$output/source/grub-core/ventoy/source_probe.c"

cat >> "$output/source/grub-core/Makefile.core.def" <<'EOF'

/* Experimental standalone source module: never include in releases. */
module = {
  name = ventoy_source_probe;
  common = ventoy/source_probe.c;
};
EOF

if ! (
  cd "$output/source"
  ./autogen.sh > "$output/autogen.log" 2>&1 &&
  ./configure --with-platform=efi --target=x86_64 \
    --prefix="$output/stage" > "$output/configure.log" 2>&1 &&
  make -C grub-core -j 4 ventoy_source_probe.module > "$output/build.log" 2>&1
); then
  printf 'module_build=failed\n' > "$output/result.txt"
  for name in autogen configure build; do
    if [ -f "$output/$name.log" ]; then
      echo "=== $name ===" >&2
      tail -n 70 "$output/$name.log" >&2
    fi
  done
  exit 6
fi

mod="$output/source/grub-core/ventoy_source_probe.mod"
if [ ! -s "$mod" ]; then
  printf 'module_build=missing-binary\n' > "$output/result.txt"
  echo 'Compiled .module target did not emit a nonempty .mod' >&2
  exit 7
fi

{
  echo 'module_build=passed'
  echo 'grub_core_patched=no'
  echo 'grub_core_recompiled=no'
  echo 'runtime_boot_tested=no'
  sha256sum "$mod"
  file "$mod"
} | tee "$output/result.txt"
