#!/usr/bin/env python3
"""Independent verification of GRUB-reported extents against a real ISO
and the raw, disposable GPT disk image used in the QEMU/OVMF test.

The verifier does NOT read GRUB's mapped data: it reconstructs the entire
file from the reported absolute offsets in the raw disk and compares every
byte to the original ISO. Noncontiguous backing allocation is mandatory.
"""
import hashlib
import re
import struct
import sys
from pathlib import Path


def checked(condition, description):
    if not condition:
        raise ValueError(description)


def gpt_first_partition_range(disk):
    disk.seek(512)
    header = disk.read(92)
    checked(header[:8] == b"EFI PART", "invalid GPT header")
    table_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    checked(128 <= entry_size <= 4096, "invalid GPT entry size")
    disk.seek(table_lba * 512)
    entry = disk.read(entry_size)
    checked(any(entry[:16]), "missing GPT partition")
    first, last = struct.unpack_from("<QQ", entry, 32)
    checked(0 < first <= last, "invalid GPT partition boundary")
    return first * 512, (last + 1) * 512


def main():
    checked(len(sys.argv) == 5,
            "usage: verify-extent-map.py QEMU-LOG ISO RAW-GPT-DISK REPORT")
    log, iso_path, disk_path, report_path = (Path(x) for x in sys.argv[1:])

    serial = log.read_text(errors="replace")
    serial = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", serial)
    serial = " ".join(serial.split())

    checked("VT_MAP_SUCCESS" in serial, "GRUB did not finish extent mapping")
    checked("VT_MAP_ERROR" not in serial, "GRUB printed a mapping error")
    header = re.search(
        r"VT_MAP_HEADER image_bytes=(\d+) count=(\d+) disk=hd1 part=1", serial
    )
    checked(header is not None, "no cross-disk extent-map header")
    expected_size, expected_count = map(int, header.groups())

    records = [
        tuple(map(int, groups))
        for groups in re.findall(
            r"VT_MAP extent=(\d+) logical=(\d+) physical=(\d+) size=(\d+)",
            serial,
        )
    ]
    checked(len(records) == expected_count,
            f"extent record count mismatch: {len(records)} != {expected_count}")
    checked(2 <= len(records) <= 16384,
            f"expected fragmented ISO and bounded map; extents={len(records)}")

    image_bytes = iso_path.stat().st_size
    checked(image_bytes == expected_size and image_bytes % 2048 == 0,
            "ISO size does not match GRUB or ISO9660 sector alignment")

    offset = 0
    previous_physical_end = None
    reconstructed = hashlib.sha256()
    original = hashlib.sha256()
    discontinuities = 0

    # Stream at most 1 MiB at a time, even for large installation ISOs.
    with iso_path.open("rb") as image, disk_path.open("rb") as disk:
        image.seek(32769)
        checked(image.read(5) == b"CD001", "input is not an ISO9660 image")
        partition_start, partition_end = gpt_first_partition_range(disk)
        disk.seek(0, 2)
        disk_bytes = disk.tell()

        for expected_index, (ix, logical, physical, size) in enumerate(records):
            checked(ix == expected_index, "non-sequential extent index")
            checked(logical == offset and size > 0,
                    "ISO map is not complete and sequential")
            checked(physical % 512 == 0 and logical % 512 == 0,
                    "ISO map starts at a non-sector boundary")
            checked(partition_start <= physical
                    and physical + size <= partition_end
                    and physical + size <= disk_bytes,
                    "extent points outside source GPT partition/disk")
            if previous_physical_end is not None:
                checked(physical != previous_physical_end,
                        "contiguous physical extents should have merged")
                discontinuities += 1

            image.seek(offset)
            disk.seek(physical)
            unread = size
            while unread:
                wanted = min(unread, 1024 * 1024)
                source = image.read(wanted)
                raw = disk.read(wanted)
                checked(len(source) == wanted and len(raw) == wanted,
                        "truncated source ISO or raw disk extent")
                checked(source == raw,
                        f"raw disk mismatch at ISO byte {offset + size - unread}")
                original.update(source)
                reconstructed.update(raw)
                unread -= wanted

            offset += size
            previous_physical_end = physical + size

    checked(offset == image_bytes, "extent coverage does not reach EOF")
    checked(reconstructed.digest() == original.digest(),
            "reconstructed SHA256 mismatch")
    checked(discontinuities >= 1, "no fragmentation actually validated")
    result = (
        "iso_map_verification=passed\n"
        "iso_format=iso9660\n"
        "source_disk=hd1,gpt1\n"
        f"image_bytes={image_bytes}\n"
        f"extent_count={len(records)}\n"
        f"physical_discontinuities={discontinuities}\n"
        f"source_sha256={original.hexdigest()}\n"
        f"reconstructed_sha256={reconstructed.hexdigest()}\n"
        "checked_bytes=all\n"
        "grub_core_patched=no\n"
        "physical_device_writes=no\n"
    )
    report_path.write_text(result)
    print(result, end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, struct.error) as exc:
        sys.stderr.write(f"ISO extent verification FAILED: {exc}\n")
        sys.exit(1)
