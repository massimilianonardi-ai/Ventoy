/* Diagnostic-only preparation of an ORIGINAL Ventoy chain layout.
 * Does not invoke an EFI image, expose a virtual CD or retain pointers.
 */
#include <grub/types.h>
#include <grub/file.h>
#include <grub/disk.h>
#include <grub/partition.h>
#include <grub/fs.h>
#include <grub/mm.h>
#include <grub/misc.h>
#include <grub/err.h>
#include <grub/ventoy.h>

grub_err_t vt_probe_handoff (grub_file_t file, const char *path,
                            const ventoy_img_chunk *chunks,
                            grub_uint32_t count);

grub_err_t
vt_probe_handoff (grub_file_t file, const char *path,
                  const ventoy_img_chunk *chunks, grub_uint32_t count)
{
  grub_disk_t disk = 0;
  ventoy_chain_head *chain = 0;
  ventoy_os_param *os;
  const grub_uint8_t *raw;
  grub_uint8_t sector[512];
  const char *end;
  const char *relative;
  grub_uint8_t sum = 0;
  grub_uint32_t i, j;
  grub_size_t length;
  grub_err_t error = GRUB_ERR_NONE;

  if (!file || !file->device || !file->device->disk
      || !file->device->disk->partition || !file->fs
      || !path || path[0] != '(' || !chunks || !count)
    return grub_error (GRUB_ERR_BAD_ARGUMENT, "missing image source");
  end = grub_strchr (path, ')');
  if (!end || end[1] != '/' || grub_strlen (end + 1) >= 384)
    return grub_error (GRUB_ERR_BAD_ARGUMENT, "invalid ISO path");
  relative = end + 1;

  disk = grub_disk_open (file->device->disk->name);
  if (!disk)
    return grub_errno;
  if (disk->partition || disk->log_sector_size != 9)
    {
      error = grub_error (GRUB_ERR_BAD_DEVICE, "expected a whole 512B disk");
      goto done;
    }
  if (grub_disk_read (disk, 0, 0, sizeof (sector), sector))
    {
      error = grub_errno;
      goto done;
    }
  if (sector[510] != 0x55 || sector[511] != 0xaa)
    {
      error = grub_error (GRUB_ERR_BAD_FS, "missing whole-disk MBR");
      goto done;
    }

  length = sizeof (*chain) + (grub_size_t) count * sizeof (*chunks);
  chain = grub_zalloc (length);
  if (!chain)
    {
      error = grub_errno;
      goto done;
    }
  os = &chain->os_param;
  {
    ventoy_guid guid = VENTOY_GUID;
    os->guid = guid;
  }
  grub_memcpy (os->vtoy_disk_guid, sector + 0x180, 16);
  grub_memcpy (os->vtoy_disk_signature, sector + 0x1b8, 4);
  os->vtoy_disk_size = disk->total_sectors << 9;
  os->vtoy_disk_part_id = file->device->disk->partition->number + 1;
  if (grub_strcmp (file->fs->name, "fat") == 0)
    os->vtoy_disk_part_type = ventoy_fs_fat;
  else if (grub_strcmp (file->fs->name, "ext2") == 0)
    os->vtoy_disk_part_type = ventoy_fs_ext;
  else
    {
      error = grub_error (GRUB_ERR_BAD_FS, "unsupported source filesystem");
      goto done;
    }
  grub_strcpy (os->vtoy_img_path, relative);
  os->vtoy_img_size = file->size;
  os->vtoy_reserved[2] = ventoy_chain_linux;
  os->chksum = 0;
  raw = (const grub_uint8_t *) os;
  for (i = 0; i < sizeof (*os); ++i)
    sum += raw[i];
  os->chksum = (grub_uint8_t) (0U - sum);

  chain->disk_sector_size = 512;
  chain->real_img_size_in_bytes = file->size;
  chain->virt_img_size_in_bytes = file->size;
  chain->img_chunk_offset = sizeof (*chain);
  chain->img_chunk_num = count;
  chain->override_chunk_offset = length;
  chain->virt_chunk_offset = length;
  grub_memcpy ((grub_uint8_t *) chain + chain->img_chunk_offset,
               chunks, (grub_size_t) count * sizeof (*chunks));

  grub_printf ("VT_HANDOFF head=%u bytes=%u offset=%u count=%u\n",
               (unsigned) sizeof (*chain), (unsigned) length,
               (unsigned) chain->img_chunk_offset, (unsigned) count);
  for (i = 0; i < sizeof (*os) / 16; ++i)
    {
      grub_printf ("VT_OS_BYTES i=%u hex=", (unsigned) i);
      for (j = 0; j < 16; ++j)
        grub_printf ("%02x", (unsigned) raw[i * 16 + j]);
      grub_printf ("\n");
    }
  grub_printf ("VT_HANDOFF_PREPARED efi_invoke=no catalog_unverified=yes\n");

done:
  grub_free (chain);
  if (disk)
    grub_disk_close (disk);
  return error;
}
