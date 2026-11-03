/* Disposable EFI virtual media proof based on Ventoy's BlockIo design.
 * Installs a read-only 2048-byte BlockIo handle with original Ventoy vendor
 * device path and removes it BEFORE this diagnostic EFI image returns.
 * Not an EFI boot driver; no virtual device persists after StartImage.
 */
#include <efi.h>
#include <efilib.h>

#define VT_HEAD_BYTES 2616U
#define VT_CHUNK_BYTES 24U
#define VT_ISO_BLOCK 2048U
#define VT_RAW_BLOCK 512U
#define VT_BATCH_BLOCKS 32U

extern UINT32 vt_probe_crc32_update (UINT32 crc, const UINT8 *data, UINTN size);

typedef struct
{
  EFI_BLOCK_IO_PROTOCOL block;
  EFI_BLOCK_IO_MEDIA media;
  EFI_BLOCK_IO_PROTOCOL *backing;
  const UINT8 *chain;
  UINT64 count;
  UINT8 *scratch_allocation;
  UINT8 *scratch;
  EFI_HANDLE handle;
  UINT8 path[24];
} VT_VIRTUAL_MEDIA;

static UINT64
vt_load_le (const UINT8 *data, UINTN size)
{
  UINT64 result = 0;
  UINTN i;
  for (i = 0; i < size; ++i)
    result |= (UINT64)data[i] << (8 * i);
  return result;
}

static EFI_STATUS EFIAPI
vt_media_reset (EFI_BLOCK_IO_PROTOCOL *block, BOOLEAN extended)
{
  (void)extended;
  return block && block->Media ? EFI_SUCCESS : EFI_INVALID_PARAMETER;
}

static EFI_STATUS EFIAPI
vt_media_write (EFI_BLOCK_IO_PROTOCOL *block, UINT32 media_id,
                EFI_LBA lba, UINTN bytes, VOID *buffer)
{
  (void)lba;
  (void)bytes;
  (void)buffer;
  if (!block || !block->Media)
    return EFI_INVALID_PARAMETER;
  if (media_id != block->Media->MediaId)
    return EFI_MEDIA_CHANGED;
  return EFI_WRITE_PROTECTED;
}

static EFI_STATUS EFIAPI
vt_media_flush (EFI_BLOCK_IO_PROTOCOL *block)
{
  return block && block->Media ? EFI_SUCCESS : EFI_INVALID_PARAMETER;
}

static EFI_STATUS EFIAPI
vt_media_read (EFI_BLOCK_IO_PROTOCOL *block, UINT32 media_id,
               EFI_LBA lba, UINTN bytes, VOID *buffer)
{
  VT_VIRTUAL_MEDIA *ctx = (VT_VIRTUAL_MEDIA *)block;
  UINT64 cursor = lba;
  UINT64 remaining;
  UINT8 *destination = (UINT8 *)buffer;

  if (!block || !block->Media || !ctx->backing || !ctx->scratch)
    return EFI_INVALID_PARAMETER;
  if (media_id != ctx->media.MediaId)
    return EFI_MEDIA_CHANGED;
  if (bytes == 0)
    return EFI_SUCCESS;
  if (!buffer || (bytes % VT_ISO_BLOCK) != 0)
    return EFI_BAD_BUFFER_SIZE;
  remaining = bytes / VT_ISO_BLOCK;
  if (cursor > ctx->media.LastBlock ||
      remaining - 1 > ctx->media.LastBlock - cursor)
    return EFI_INVALID_PARAMETER;

  while (remaining)
    {
      UINT64 i;
      UINT64 start = 0, end = 0, disk_start = 0, disk_end = 0;
      UINT64 available;
      UINTN take;
      EFI_STATUS status;
      for (i = 0; i < ctx->count; ++i)
        {
          const UINT8 *chunk = ctx->chain + VT_HEAD_BYTES + i * VT_CHUNK_BYTES;
          start = vt_load_le (chunk, 4);
          end = vt_load_le (chunk + 4, 4);
          if (start <= cursor && cursor <= end)
            {
              disk_start = vt_load_le (chunk + 8, 8);
              disk_end = vt_load_le (chunk + 16, 8);
              break;
            }
        }
      if (i == ctx->count)
        return EFI_COMPROMISED_DATA;
      available = end - cursor + 1;
      if (available > remaining)
        available = remaining;
      if (available > VT_BATCH_BLOCKS)
        available = VT_BATCH_BLOCKS;
      take = (UINTN)available;
      if (disk_start > ~(UINT64)0 - (cursor - start) * 4
          || disk_start + (cursor - start) * 4 > disk_end
          || available * 4 - 1 >
             disk_end - (disk_start + (cursor - start) * 4))
        return EFI_COMPROMISED_DATA;
      status = uefi_call_wrapper (ctx->backing->ReadBlocks, 5,
                                  ctx->backing, ctx->backing->Media->MediaId,
                                  (EFI_LBA)(disk_start + (cursor - start) * 4),
                                  take * VT_ISO_BLOCK, ctx->scratch);
      if (EFI_ERROR (status))
        return status;
      CopyMem (destination, ctx->scratch, take * VT_ISO_BLOCK);
      destination += take * VT_ISO_BLOCK;
      cursor += take;
      remaining -= take;
    }
  return EFI_SUCCESS;
}

static EFI_STATUS
vt_print_crc (EFI_SERIAL_IO_PROTOCOL *serial, UINT32 crc)
{
  static const CHAR8 digits[] = "0123456789abcdef";
  static const CHAR8 prefix[] = "VT_EFI_VIRTUAL_BLOCKIO_OK crc32=";
  CHAR8 message[sizeof (prefix) + 10];
  UINTN i, size;
  CopyMem (message, prefix, sizeof (prefix) - 1);
  for (i = 0; i < 8; ++i)
    message[sizeof (prefix) - 1 + i] =
      digits[(crc >> ((7 - i) * 4)) & 15U];
  size = sizeof (prefix) - 1 + 8;
  message[size++] = '\r';
  message[size++] = '\n';
  return uefi_call_wrapper (serial->Write, 3, serial, &size, message);
}

EFI_STATUS vt_probe_virtual_media (EFI_SYSTEM_TABLE *system,
                                   EFI_BLOCK_IO_PROTOCOL *backing,
                                   const UINT8 *chain, UINT64 chain_size,
                                   UINT32 source_crc,
                                   EFI_SERIAL_IO_PROTOCOL *serial);

EFI_STATUS
vt_probe_virtual_media (EFI_SYSTEM_TABLE *system,
                        EFI_BLOCK_IO_PROTOCOL *backing,
                        const UINT8 *chain, UINT64 chain_size,
                        UINT32 source_crc, EFI_SERIAL_IO_PROTOCOL *serial)
{
  EFI_GUID block_guid = EFI_BLOCK_IO_PROTOCOL_GUID;
  EFI_GUID path_guid = DEVICE_PATH_PROTOCOL;
  VT_VIRTUAL_MEDIA media;
  EFI_BLOCK_IO_PROTOCOL *published = NULL;
  EFI_HANDLE *handles = NULL;
  UINT8 *test_allocation = NULL;
  UINT8 *buffer = NULL;
  EFI_STATUS status, cleanup;
  UINTN count = 0, i, found = 0;
  UINT64 sectors, next;
  UINT32 crc = 0xffffffffU;
  static const UINT8 original_vendor_path[24] = {
    0x01,0x04,0x14,0x00,
    0xc6,0x7a,0xb8,0x37,0x80,0xc1,0x83,0x45,
    0xa7,0x05,0x41,0x4d,0xa8,0xf7,0x7e,0xd2,
    0x7f,0xff,0x04,0x00
  };

  if (!system || !backing || !backing->Media || !serial
      || !chain || chain_size < VT_HEAD_BYTES
      || backing->Media->IoAlign > 4096)
    return EFI_INVALID_PARAMETER;
  sectors = vt_load_le (chain + 524, 8) / VT_ISO_BLOCK;
  if (!sectors || sectors > 0xffffffffULL
      || chain_size != VT_HEAD_BYTES
         + vt_load_le (chain + 2596, 4) * VT_CHUNK_BYTES)
    return EFI_COMPROMISED_DATA;

  SetMem (&media, sizeof (media), 0);
  media.backing = backing;
  media.chain = chain;
  media.count = vt_load_le (chain + 2596, 4);
  CopyMem (media.path, original_vendor_path, sizeof (media.path));
  media.media.MediaId = 0x56544f59U;
  media.media.MediaPresent = TRUE;
  media.media.RemovableMedia = TRUE;
  media.media.ReadOnly = TRUE;
  media.media.BlockSize = VT_ISO_BLOCK;
  media.media.IoAlign = 1;
  media.media.LastBlock = sectors - 1;
  media.block.Revision = EFI_BLOCK_IO_PROTOCOL_REVISION;
  media.block.Media = &media.media;
  media.block.Reset = vt_media_reset;
  media.block.ReadBlocks = vt_media_read;
  media.block.WriteBlocks = vt_media_write;
  media.block.FlushBlocks = vt_media_flush;

  media.scratch_allocation = AllocatePool (65536 + 4096);
  test_allocation = AllocatePool (65536 + 4096);
  if (!media.scratch_allocation || !test_allocation)
    {
      status = EFI_OUT_OF_RESOURCES;
      goto done;
    }
  media.scratch = (UINT8 *)((((UINTN)media.scratch_allocation) + 4095)
                             & ~(UINTN)4095);
  buffer = (UINT8 *)((((UINTN)test_allocation) + 4095) & ~(UINTN)4095);

  status = uefi_call_wrapper (system->BootServices->InstallMultipleProtocolInterfaces,
                              6, &media.handle, &block_guid, &media.block,
                              &path_guid, media.path, NULL);
  if (EFI_ERROR (status))
    goto done;

  status = uefi_call_wrapper (system->BootServices->LocateHandleBuffer, 5,
                              ByProtocol, &block_guid, NULL, &count, &handles);
  if (EFI_ERROR (status))
    goto unmount;
  for (i = 0; i < count; ++i)
    if (handles[i] == media.handle)
      ++found;
  if (found != 1)
    {
      status = EFI_NOT_FOUND;
      goto unmount;
    }

  status = uefi_call_wrapper (system->BootServices->HandleProtocol, 3,
                              media.handle, &block_guid, (VOID **)&published);
  if (EFI_ERROR (status) || published != &media.block)
    {
      status = EFI_COMPROMISED_DATA;
      goto unmount;
    }
  if (published->Media->BlockSize != VT_ISO_BLOCK
      || !published->Media->ReadOnly || !published->Media->MediaPresent)
    {
      status = EFI_COMPROMISED_DATA;
      goto unmount;
    }

  /* Negative protocol semantics: invalid media, unaligned size,
   * out-of-range LBA and attempts to modify the virtual CD. */
  if (uefi_call_wrapper (published->ReadBlocks, 5,
                         published, 0, 0, VT_ISO_BLOCK, buffer)
      != EFI_MEDIA_CHANGED
      || uefi_call_wrapper (published->ReadBlocks, 5,
                            published, media.media.MediaId, 0, 512, buffer)
         != EFI_BAD_BUFFER_SIZE
      || uefi_call_wrapper (published->ReadBlocks, 5,
                            published, media.media.MediaId, sectors, 2048,
                            buffer) != EFI_INVALID_PARAMETER
      || uefi_call_wrapper (published->WriteBlocks, 5,
                            published, media.media.MediaId, 0, 2048,
                            buffer) != EFI_WRITE_PROTECTED)
    {
      status = EFI_COMPROMISED_DATA;
      goto unmount;
    }

  for (next = 0; next < sectors;)
    {
      UINT64 remaining = sectors - next;
      UINTN blocks = remaining > VT_BATCH_BLOCKS
                     ? VT_BATCH_BLOCKS : (UINTN)remaining;
      status = uefi_call_wrapper (published->ReadBlocks, 5,
                                  published, media.media.MediaId,
                                  (EFI_LBA)next, blocks * VT_ISO_BLOCK, buffer);
      if (EFI_ERROR (status))
        goto unmount;
      if (next <= 16 && next + blocks > 16)
        {
          const UINT8 *pvd = buffer + (UINTN)(16 - next) * VT_ISO_BLOCK;
          if (pvd[0] != 1 || CompareMem (pvd + 1, "CD001", 5))
            {
              status = EFI_COMPROMISED_DATA;
              goto unmount;
            }
        }
      crc = vt_probe_crc32_update (crc, buffer, blocks * VT_ISO_BLOCK);
      next += blocks;
    }
  crc ^= 0xffffffffU;
  if (crc != source_crc)
    status = EFI_CRC_ERROR;
  else
    status = vt_print_crc (serial, crc);

unmount:
  cleanup = uefi_call_wrapper (
      system->BootServices->UninstallMultipleProtocolInterfaces, 6,
      media.handle, &block_guid, &media.block, &path_guid, media.path, NULL);
  if (EFI_ERROR (cleanup))
    {
      /* Do not pretend that callbacks were removed. CI must fail. */
      status = cleanup;
    }
  else if (!EFI_ERROR (status))
    {
      static CHAR8 message[] = "VT_EFI_VIRTUAL_BLOCKIO_UNINSTALLED\r\n";
      UINTN bytes = sizeof (message) - 1;
      status = uefi_call_wrapper (serial->Write, 3, serial, &bytes, message);
    }

done:
  if (handles)
    FreePool (handles);
  if (test_allocation)
    FreePool (test_allocation);
  if (media.scratch_allocation)
    FreePool (media.scratch_allocation);
  return status;
}
