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
    checked(len(sys.argv) in (5, 6),
            "usage: verify-extent-map.py QEMU-LOG ISO RAW-GPT-DISK REPORT "
            "[MIN-EXTENTS]")
    log, iso_path, disk_path, report_path = (
        Path(x) for x in sys.argv[1:5]
    )
    min_extents = int(sys.argv[5]) if len(sys.argv) == 6 else 2
    checked(1 <= min_extents <= 16384, "invalid minimum extent count")

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
    checked(min_extents <= len(records) <= 16384,
            f"expected >= {min_extents} extents; got {len(records)}")

    # Check the REAL Ventoy structures emitted by the GRUB module, not
    # only its generic physical byte ranges. These fields correspond to
    # ventoy_img_chunk and ventoy_image_disk_region in upstream ventoy.h.
    chain_head = re.search(
        r"VT_CHAIN_HEADER count=(\\d+) image_sector=(\\d+) "
        r"disk_sector=(\\d+)", serial
    )
    chain_end = re.search(
        r"VT_CHAIN_SUCCESS count=(\\d+) image_bytes=(\\d+)", serial
    )
    checked(chain_head is not None and chain_end is not None,
            "no complete Ventoy ABI image-sector map")
    chain_count, image_sector_bytes, disk_sector_bytes = (
        int(x) for x in chain_head.groups()
    )
    checked((chain_count, image_sector_bytes, disk_sector_bytes)
            == (len(records), 2048, 512),
            "invalid Ventoy chunk geometry or record count")
    checked(tuple(map(int, chain_end.groups())) ==
            (len(records), expected_size), "Ventoy chunk coverage mismatch")

    chunks = [
        tuple(map(int, row))
        for row in re.findall(
            r"VT_CHAIN_CHUNK i=(\\d+) is=(\\d+) ie=(\\d+) "
            r"ds=(\\d+) de=(\\d+)", serial
        )
    ]
    regions = [
        tuple(map(int, row))
        for row in re.findall(
            r"VT_LOCATION_REGION i=(\\d+) is=(\\d+) n=(\\d+) ds=(\\d+)",
            serial
        )
    ]
    checked(len(chunks) == len(regions) == len(records),
            "missing Ventoy chain or image-location entries")

    for index, (extent, chunk, region) in enumerate(
            zip(records, chunks, regions)):
        ex_index, logical, physical, size = extent
        chunk_index, img_start, img_end, disk_start, disk_end = chunk
        region_index, region_start, region_count, region_disk = region
        checked(ex_index == chunk_index == region_index == index,
                "Ventoy record ordering mismatch")
        checked(logical % 2048 == physical % 2048 == size % 2048 == 0,
                "Ventoy cannot encode unaligned ISO extents")
        checked(img_start == logical // 2048 and
                img_end == (logical + size) // 2048 - 1 and
                disk_start == physical // 512 and
                disk_end == (physical + size) // 512 - 1,
                "Ventoy image-chunk fields disagree with raw extent")
        checked((region_start, region_count, region_disk) ==
                (img_start, img_end - img_start + 1, disk_start),
                "Ventoy image-location region disagrees with chunk")

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
    checked(discontinuities >= min_extents - 1,
            "required fragmentation was not observed")
    result = (
        "iso_map_verification=passed\n"
        "iso_format=iso9660\n"
        "ventoy_chunk_abi=verified\n"
        "ventoy_image_location_abi=verified\n"
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
