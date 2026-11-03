/* Test-only UEFI consumer of real ISO sectors selected by Ventoy chunks.
 * Never installs BlockIo, virtual media, boot components or GRUB patches.
 */
#include <efi.h>
#include <efilib.h>

static UINT64
word (const UINT8 *p, UINTN n)
{
  UINT64 x = 0;
  UINTN i;
  for (i = 0; i < n; ++i)
    x |= (UINT64)p[i] << (i * 8);
  return x;
}

static EFI_STATUS
disk_read (EFI_BLOCK_IO_PROTOCOL *disk, UINT64 lba, UINTN length, VOID *buf)
{
  if (!disk || !disk->Media || disk->Media->BlockSize != 512
      || !length || (length % 512) != 0
      || lba > disk->Media->LastBlock
      || length / 512 - 1 > disk->Media->LastBlock - lba)
    return EFI_BAD_BUFFER_SIZE;
  return uefi_call_wrapper (disk->ReadBlocks, 5, disk, disk->Media->MediaId,
                            (EFI_LBA)lba, length, buf);
}

static UINT32
crc_update (UINT32 crc, const UINT8 *data, UINTN bytes)
{
  UINTN i, j;
  for (i = 0; i < bytes; ++i)
    {
      crc ^= data[i];
      for (j = 0; j < 8; ++j)
        crc = (crc >> 1) ^ ((crc & 1U) ? 0xedb88320U : 0U);
    }
  return crc;
}

static EFI_STATUS
print_crc (EFI_SERIAL_IO_PROTOCOL *serial, UINT32 crc)
{
  static const CHAR8 key[] = "0123456789abcdef";
  static const CHAR8 label[] = "VT_EFI_BLOCKMAP_OK crc32=";
  CHAR8 message[sizeof (label) + 8 + 2];
  UINTN i, bytes;
  if (!serial)
    return EFI_NOT_FOUND;
  CopyMem (message, label, sizeof (label) - 1);
  for (i = 0; i < 8; ++i)
    message[sizeof (label) - 1 + i] =
      key[(crc >> ((7 - i) * 4)) & 15U];
  bytes = sizeof (label) - 1 + 8;
  message[bytes++] = '\r';
  message[bytes++] = '\n';
  return uefi_call_wrapper (serial->Write, 3, serial, &bytes, message);
}

/* This EFI-side proof selects a UNIQUE whole-disk BlockIo device by
 * original os_param size/MBR identity; never by Ventoy disk branding.
 * It fails on cloned/ambiguous matches rather than picking the first.
 */
EFI_STATUS
vt_check_efi_blockmap (EFI_SYSTEM_TABLE *system, const UINT8 *chain,
                       UINT64 length, EFI_SERIAL_IO_PROTOCOL *serial)
{
  EFI_GUID block_id = EFI_BLOCK_IO_PROTOCOL_GUID;
  EFI_HANDLE *handles = NULL;
  EFI_BLOCK_IO_PROTOCOL *source = NULL;
  EFI_STATUS status;
  UINT8 *allocation = NULL;
  UINT8 *buffer;
  UINTN handle_count = 0, matches = 0, i;
  UINT64 count, image_size, logical = 0, chunk_index;
  UINT32 crc = 0xffffffffU;

  if (!system || !chain || length < 2616
      || word (chain + 520, 4) != 512
      || word (chain + 2592, 4) != 2616)
    return EFI_INVALID_PARAMETER;
  count = word (chain + 2596, 4);
  image_size = word (chain + 524, 8);
  if (count == 0 || count > 16384 || image_size == 0
      || (image_size % 2048) || length != 2616 + count * 24
      || word (chain + 532, 8) != image_size
      || word (chain + 429, 8) != image_size)
    return EFI_COMPROMISED_DATA;

  status = uefi_call_wrapper (system->BootServices->LocateHandleBuffer, 5,
                              ByProtocol, &block_id, NULL, &handle_count,
                              &handles);
  if (EFI_ERROR (status))
    return status;
  allocation = AllocatePool (8192);
  if (!allocation)
    {
      status = EFI_OUT_OF_RESOURCES;
      goto done;
    }
  buffer = (UINT8 *)((((UINTN)allocation) + 4095) & ~(UINTN)4095);

  for (i = 0; i < handle_count; ++i)
    {
      EFI_BLOCK_IO_PROTOCOL *candidate = NULL;
      status = uefi_call_wrapper (system->BootServices->HandleProtocol, 3,
                                  handles[i], &block_id, (VOID **)&candidate);
      if (EFI_ERROR (status) || !candidate || !candidate->Media)
        continue;
      if (!candidate->Media->MediaPresent
          || candidate->Media->LogicalPartition
          || candidate->Media->BlockSize != 512
          || candidate->Media->IoAlign > 4096
          || candidate->Media->LastBlock >= (~(UINT64)0 / 512)
          || (candidate->Media->LastBlock + 1) * 512
             != word (chain + 33, 8))
        continue;
      status = disk_read (candidate, 0, 512, buffer);
      if (EFI_ERROR (status))
        continue;
      if (CompareMem (buffer + 0x180, chain + 17, 16)
          || CompareMem (buffer + 0x1b8, chain + 481, 4))
        continue;
      source = candidate;
      ++matches;
    }
  if (matches != 1)
    {
      status = matches ? EFI_SECURITY_VIOLATION : EFI_NOT_FOUND;
      goto done;
    }

  for (chunk_index = 0; chunk_index < count; ++chunk_index)
    {
      const UINT8 *chunk = chain + 2616 + chunk_index * 24;
      UINT64 begin = word (chunk, 4);
      UINT64 end = word (chunk + 4, 4);
      UINT64 disk_begin = word (chunk + 8, 8);
      UINT64 disk_end = word (chunk + 16, 8);
      UINT64 sector;
      if (begin != logical || end < begin || disk_end < disk_begin
          || (end - begin + 1) > (~(UINT64)0 / 4)
          || disk_end - disk_begin + 1 != (end - begin + 1) * 4
          || disk_end > source->Media->LastBlock)
        {
          status = EFI_COMPROMISED_DATA;
          goto done;
        }
      for (sector = begin; sector <= end; ++sector)
        {
          status = disk_read (source, disk_begin + (sector - begin) * 4,
                              2048, buffer);
          if (EFI_ERROR (status))
            goto done;
          if (sector == 16
              && (buffer[0] != 1 || CompareMem (buffer + 1, "CD001", 5)))
            {
              status = EFI_COMPROMISED_DATA;
              goto done;
            }
          crc = crc_update (crc, buffer, 2048);
        }
      logical = end + 1;
    }

  status = logical == image_size / 2048
           ? print_crc (serial, crc ^ 0xffffffffU)
           : EFI_COMPROMISED_DATA;

done:
  if (allocation)
    FreePool (allocation);
  if (handles)
    FreePool (handles);
  return status;
}
