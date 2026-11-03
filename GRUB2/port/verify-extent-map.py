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
import zlib
from pathlib import Path


def checked(condition, description):
    if not condition:
        raise ValueError(description)


def gpt_partition_range(disk, part_number):
    disk.seek(512)
    header = disk.read(92)
    checked(header[:8] == b"EFI PART", "invalid GPT header")
    table_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    checked(128 <= entry_size <= 4096, "invalid GPT entry size")
    disk.seek(table_lba * 512 + (part_number - 1) * entry_size)
    entry = disk.read(entry_size)
    checked(any(entry[:16]), "missing GPT partition")
    first, last = struct.unpack_from("<QQ", entry, 32)
    checked(0 < first <= last, "invalid GPT partition boundary")
    return first * 512, (last + 1) * 512


def main():
    checked(len(sys.argv) in (5, 6, 7, 8),
            "usage: verify-extent-map.py QEMU-LOG ISO RAW-GPT-DISK REPORT "
            "[MIN-EXTENTS [PARTITION-NUMBER [efi]]]")
    log, iso_path, disk_path, report_path = (
        Path(x) for x in sys.argv[1:5]
    )
    min_extents = int(sys.argv[5]) if len(sys.argv) >= 6 else 2
    part_num = int(sys.argv[6]) if len(sys.argv) >= 7 else 1
    verify_efi = len(sys.argv) == 8 and sys.argv[7] == "efi"
    checked(len(sys.argv) != 8 or verify_efi, "invalid EFI verification option")
    checked(1 <= min_extents <= 16384, "invalid minimum extent count")
    checked(1 <= part_num <= 128, "invalid GPT partition number")

    serial = log.read_text(errors="replace")
    serial = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", serial)
    serial = " ".join(serial.split())

    checked("VT_MAP_SUCCESS" in serial, "GRUB did not finish extent mapping")
    checked("VT_MAP_ERROR" not in serial, "GRUB printed a mapping error")
    header = re.search(
        rf"VT_MAP_HEADER image_bytes=(\d+) count=(\d+) "
        rf"disk=hd1 part={part_num}", serial
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
        r"VT_CHAIN_HEADER count=(\d+) image_sector=(\d+) "
        r"disk_sector=(\d+)", serial
    )
    chain_end = re.search(
        r"VT_CHAIN_SUCCESS count=(\d+) image_bytes=(\d+)", serial
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
            r"VT_CHAIN_CHUNK i=(\d+) is=(\d+) ie=(\d+) "
            r"ds=(\d+) de=(\d+)", serial
        )
    ]
    regions = [
        tuple(map(int, row))
        for row in re.findall(
            r"VT_LOCATION_REGION i=(\d+) is=(\d+) n=(\d+) ds=(\d+)",
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

    # Reconstruct the actual 512-byte upstream ventoy_os_param from
    # the GRUB module's byte-level diagnostic dump. Compare legacy disk
    # identifiers with the REAL whole-disk MBR, not an invented device ID.
    handoff = re.search(
        r"VT_HANDOFF head=(\d+) bytes=(\d+) offset=(\d+) count=(\d+)",
        serial
    )
    checked(handoff is not None, "missing native Ventoy chain header")
    head_len, package_len, chunk_off, chunk_count = map(int, handoff.groups())
    checked(head_len == 2616 and chunk_off == head_len
            and chunk_count == len(records)
            and package_len == head_len + len(records) * 24,
            "invalid original Ventoy chain-head/chunk ABI size")
    checked("VT_HANDOFF_PREPARED efi_invoke=no catalog_unverified=yes" in serial,
            "handoff diagnostic must not claim EFI boot")

    serialized = [
        (int(n), bytes.fromhex(payload))
        for n, payload in re.findall(
            r"VT_OS_BYTES i=(\d+) hex=([0-9a-f]{32})", serial
        )
    ]
    checked(len(serialized) == 32 and
            all(n == i for i, (n, _) in enumerate(serialized)),
            "incomplete or reordered native os_param byte serialization")
    os_param = b"".join(payload for _, payload in serialized)
    checked(len(os_param) == 512 and sum(os_param) % 256 == 0,
            "Ventoy os_param has invalid size/checksum")
    checked(os_param[:16] ==
            bytes.fromhex("20207777772e76656e746f792e6e6574"),
            "unexpected original Ventoy GUID")
    checked(struct.unpack_from("<Q", os_param, 33)[0] ==
            disk_path.stat().st_size, "wrong real backing-disk size")
    checked(struct.unpack_from("<H", os_param, 41)[0] == part_num,
            "wrong backing GPT partition index")
    checked(struct.unpack_from("<H", os_param, 43)[0] in (2, 5),
            "unexpected Ventoy source FS type")
    checked(os_param[45:429].split(b"\0", 1)[0] == b"/vt-map-image.iso",
            "Ventoy os_param lost actual ISO path")
    checked(struct.unpack_from("<Q", os_param, 429)[0] == expected_size,
            "Ventoy os_param image size mismatch")
    checked(os_param[437:449] == b"\0" * 12
            and os_param[451] == 0 and os_param[455] == 0,
            "unsupported memory pointer, chain type or VLNK flag")

    with disk_path.open("rb") as disk_ident:
        mbr = disk_ident.read(512)
    checked(os_param[17:33] == mbr[0x180:0x190]
            and os_param[481:485] == mbr[0x1b8:0x1bc],
            "Ventoy handoff disk identifiers disagree with raw disk")

    image_bytes = iso_path.stat().st_size
    checked(image_bytes == expected_size and image_bytes % 2048 == 0,
            "ISO size does not match GRUB or ISO9660 sector alignment")

    offset = 0
    previous_physical_end = None
    reconstructed = hashlib.sha256()
    original = hashlib.sha256()
    efi_crc32 = 0
    discontinuities = 0

    # Stream at most 1 MiB at a time, even for large installation ISOs.
    with iso_path.open("rb") as image, disk_path.open("rb") as disk:
        image.seek(32769)
        checked(image.read(5) == b"CD001", "input is not an ISO9660 image")
        partition_start, partition_end = gpt_partition_range(disk, part_num)
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
                efi_crc32 = zlib.crc32(source, efi_crc32)
                unread -= wanted

            offset += size
            previous_physical_end = physical + size

    checked(offset == image_bytes, "extent coverage does not reach EOF")
    checked(reconstructed.digest() == original.digest(),
            "reconstructed SHA256 mismatch")
    checked(discontinuities >= min_extents - 1,
            "required fragmentation was not observed")
    if verify_efi:
        actual_crc = re.search(r"VT_EFI_BLOCKMAP_OK crc32=([0-9a-f]{8})",
                               serial)
        checked(actual_crc is not None,
                "EFI did not read the full ISO from native BlockIo")
        checked(int(actual_crc.group(1), 16) == efi_crc32,
                f"EFI BlockIo CRC mismatch: {actual_crc.group(1)} "
                f"vs source {efi_crc32:08x}")
    result = (
        "iso_map_verification=passed\n"
        "iso_format=iso9660\n"
        "ventoy_chunk_abi=verified\n"
        "ventoy_os_param_abi=verified\n"
        "ventoy_chain_head_abi=verified\n"
        "ventoy_image_location_abi=verified\n"
        f"source_disk=hd1,gpt{part_num}\n"
        f"image_bytes={image_bytes}\n"
        f"extent_count={len(records)}\n"
        f"physical_discontinuities={discontinuities}\n"
        f"source_sha256={original.hexdigest()}\n"
        f"reconstructed_sha256={reconstructed.hexdigest()}\n"
        "checked_bytes=all\n"
        f"efi_blockio_full_iso_crc32={'verified' if verify_efi else 'not-tested'}\n"
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
