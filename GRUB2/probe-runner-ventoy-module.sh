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

# Explicit in-fork port patch, applied only to the runner-source copy.
# The inherited 2.04 overlay remains unchanged for audit and comparison.
if ! patch --batch --fuzz=0 --forward -p1 -d "$output/source" \
    < "$(dirname "$0")/port/runner-efi-api.patch" \
    > "$output/efi-port-apply.log" 2>&1
then
    echo "EFI API port patch did not apply to the distribution tree" >&2
    cat "$output/efi-port-apply.log" >&2
    exit 7
fi

if ! patch --batch --fuzz=0 --forward -p1 -d "$output/source" \
    < "$(dirname "$0")/port/runner-browser-api.patch" \
    > "$output/browser-port-apply.log" 2>&1
then
    echo "GRUB 2.12 browser API port patch did not apply" >&2
    cat "$output/browser-port-apply.log" >&2
    exit 9
fi

if ! patch --batch --fuzz=0 --forward -p1 -d "$output/source" \
    < "$(dirname "$0")/port/runner-file-api.patch" \
    > "$output/file-port-apply.log" 2>&1
then
    echo "File API port patch did not apply" >&2
    cat "$output/file-port-apply.log" >&2
    exit 10
fi

# Ventoy's former GRUB core owns these policy variables. Restore their
# definitions in the runner-source core; do not invent module-local stubs.
if grep -q 'g_sys_sb' "$output/source/grub-core/kern/env.c"
then
    echo "Distribution GRUB already defines Ventoy Secure Boot state" >&2
    exit 8
fi
cat >> "$output/source/grub-core/kern/env.c" <<'EOF'

/* Ventoy Secure Boot state, ported from the upstream GRUB core overlay. */
grub_uint8_t g_sys_sb = 0;
grub_uint8_t g_sb_policy = VTOY_SB_POLICY_BYPASS;
EOF

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
    TARGET_CFLAGS="-Os -Wno-error=misleading-indentation" \
      ./configure --with-platform=efi --target=x86_64 \
        --prefix="$output/stage" > "$output/configure.log" 2>&1
    make -C grub-core -j 4 ventoy.module > "$output/build.log" 2>&1
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
