#!/bin/sh
# Compile the unported Ventoy module against the runner's GRUB source to
# identify concrete API mismatches. Never use its output as a release.
set -eu

if [ "$#" -ne 2 ]
then
    echo "Usage: $0 DISTRO-GRUB-SOURCE OUTPUT-DIR" >&2
    exit 2
fi

source=$1
output=$2
overlay=$(CDPATH= cd "$(dirname "$0")/MOD_SRC/grub-2.04" && pwd)

[ -f "$source/configure.ac" ] || { echo "Missing distro GRUB source" >&2; exit 3; }
[ -s "$overlay/grub-core/ventoy/ventoy_cmd.c" ] || { echo "Missing Ventoy module source" >&2; exit 4; }
[ ! -e "$output" ] || { echo "Output already exists" >&2; exit 5; }

mkdir "$output"
output=$(CDPATH= cd "$output" && pwd)
mkdir "$output/source"
cp -a "$source/." "$output/source/"
cp -a "$overlay/grub-core/ventoy" "$output/source/grub-core/"
cp "$overlay/include/grub/ventoy.h" "$output/source/include/grub/ventoy.h"

# Add only the Ventoy module definition, not 2.04's Makefile/core rewrites.
cat >> "$output/source/grub-core/Makefile.core.def" <<'EOF'

/* Experimental module compile probe; no release until the complete port. */
module = {
  name = ventoy;
  common = ventoy/ventoy.c;
  common = ventoy/ventoy_cmd.c;
  common = ventoy/ventoy_linux.c;
  common = ventoy/ventoy_unix.c;
  common = ventoy/ventoy_windows.c;
  common = ventoy/ventoy_vhd.c;
  common = ventoy/ventoy_plugin.c;
  common = ventoy/ventoy_json.c;
  common = ventoy/ventoy_browser.c;
  common = ventoy/lzx.c;
  common = ventoy/xpress.c;
  common = ventoy/huffman.c;
  common = ventoy/miniz.c;
};
EOF

(
    cd "$output/source"
    ./autogen.sh > "$output/autogen.log" 2>&1
    ./configure --with-platform=efi --target=x86_64 \
        --prefix="$output/stage" > "$output/configure.log" 2>&1
    make -j 4 > "$output/build.log" 2>&1
) || {
    result=$?
    printf 'module_compile=failed\nexit_status=%s\n' "$result" > "$output/summary.txt"
    for name in autogen configure build
    do
        if [ -f "$output/$name.log" ]
        then
            echo "=== $name: last 50 lines ==="
            tail -n 50 "$output/$name.log"
        fi
    done
    exit "$result"
}

[ -s "$output/source/grub-core/ventoy.mod" ] || {
    echo 'Module build reported success but ventoy.mod is missing' >&2
    exit 6
}
printf 'module_compile=passed-source-only\n' > "$output/summary.txt"
