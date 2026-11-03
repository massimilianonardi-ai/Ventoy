#!/bin/sh
# Compare the upstream Ventoy GRUB overlay with the runner distribution source.
# This does not make GRUB 2.04 the release version. It is the patch baseline.
set -eu

usage()
{
    echo "Usage: $0 ORIGINAL-GRUB-2.04-SOURCE DISTRO-GRUB-SOURCE OUTPUT-DIR" >&2
    exit 2
}

[ "$#" -eq 3 ] || usage

baseline=$1
distro=$2
output=$3
overlay=$(CDPATH= cd -- "$(dirname -- "$0")/MOD_SRC/grub-2.04" && pwd)

[ -f "$baseline/configure.ac" ] || { echo "Missing original GRUB source" >&2; exit 3; }
[ -f "$distro/configure.ac" ] || { echo "Missing distribution GRUB source" >&2; exit 4; }
[ -f "$overlay/grub-core/ventoy/ventoy_cmd.c" ] || { echo "Missing Ventoy source overlay" >&2; exit 5; }
[ ! -e "$output" ] || { echo "Output already exists: $output" >&2; exit 6; }

mkdir -p -- "$output"
output=$(CDPATH= cd -- "$output" && pwd)
mkdir -- "$output/original" "$output/modified" "$output/target"
cp -a -- "$baseline/." "$output/original/"
cp -a -- "$baseline/." "$output/modified/"
cp -a -- "$overlay/." "$output/modified/"
cp -a -- "$distro/." "$output/target/"

(
    cd -- "$output"
    diff -ruN original modified > ventoy-source-delta.patch
) || status=$?
if [ "${status:-0}" -ne 1 ]
then
    echo "Could not derive Ventoy changes from GRUB baseline (diff status ${status:-0})" >&2
    exit 7
fi
[ -s "$output/ventoy-source-delta.patch" ] || { echo "Empty Ventoy source delta" >&2; exit 8; }

# Record a source tree that is safe to inspect even when some patches conflict.
# This probes the whole overlay; no upstream 2.04 binary/modules are used.
if (
    cd -- "$output"
    patch --dry-run --batch --fuzz=0 --forward -p1 -d target \
        < ventoy-source-delta.patch > port-check.log 2>&1
   )
then
    echo "port_status=clean-dry-run" | tee "$output/port-status.txt"
    (
        cd -- "$output"
        patch --batch --fuzz=0 --forward -p1 -d target \
            < ventoy-source-delta.patch > port-apply.log 2>&1
    )
    [ -f "$output/target/grub-core/ventoy/ventoy_cmd.c" ] || {
        echo "Port applied without custom Ventoy command module" >&2
        exit 9
    }
else
    echo "port_status=source-conflicts" | tee "$output/port-status.txt"
    echo "The GRUB 2.04 delta does not apply cleanly to the runner GRUB source." >&2
    echo "See port-check.log; do not release or reuse mixed-version modules." >&2
    exit 10
fi
