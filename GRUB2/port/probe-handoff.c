/* Diagnostic-only preparation of original Ventoy chain and env_param
 * structures for a stock-GRUB-to-GNU-EFI memory bridge.
 * No ISO boot or runtime EFI virtual device is implemented here.
 */
#include <grub/types.h>
#include <grub/file.h>
#include <grub/disk.h>
#include <grub/partition.h>
#include <grub/fs.h>
#include <grub/mm.h>
#include <grub/misc.h>
#include <grub/err.h>
#include <grub/env.h>
#include <grub/ventoy.h>

/* Keep both original Ventoy ABI objects in GRUB memory until StartImage
 * returns or this module is unloaded. Neither survives GRUB teardown. */
static ventoy_chain_head *vt_pending_chain;
static ventoy_grub_param *vt_pending_env;

void vt_release_handoff_probe (void);

void
vt_release_handoff_probe (void)
{
  grub_free (vt_pending_chain);
  grub_free (vt_pending_env);
  vt_pending_chain = 0;
  vt_pending_env = 0;
  grub_env_unset ("vt_probe_env_addr");
  grub_env_unset ("VTOY_CHKDEV_RESULT_STRING");
  grub_env_unset ("vt_probe_chain_addr");
  grub_env_unset ("vt_probe_chain_size");
  grub_env_unset ("vt_probe_gpt_guid");
}

grub_err_t vt_probe_handoff (grub_file_t file, const char *path,
                            const ventoy_img_chunk *chunks,
                            grub_uint32_t count);

grub_err_t
vt_probe_handoff (grub_file_t file, const char *path,
                  const ventoy_img_chunk *chunks, grub_uint32_t count)
{
  grub_disk_t disk = 0;
  ventoy_chain_head *chain = 0;
  ventoy_grub_param *env_param = 0;
  ventoy_os_param *os;
  const grub_uint8_t *raw;
  grub_uint8_t sector[512];
  grub_uint8_t gpt[512];
  char gpt_guid[33];
  grub_uint32_t header_size;
  static const char digits[] = "0123456789abcdef";
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

  vt_release_handoff_probe ();
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
  if (grub_disk_read (disk, 1, 0, sizeof (gpt), gpt))
    {
      error = grub_errno;
      goto done;
    }
  header_size = (grub_uint32_t) gpt[12]
                | ((grub_uint32_t) gpt[13] << 8)
                | ((grub_uint32_t) gpt[14] << 16)
                | ((grub_uint32_t) gpt[15] << 24);
  if (grub_memcmp (gpt, "EFI PART", 8)
      || header_size < 92 || header_size > sizeof (gpt))
    {
      error = grub_error (GRUB_ERR_BAD_FS, "invalid primary GPT header");
      goto done;
    }
  /* Keep upstream os_param's MBR identity unchanged. */
  for (i = 0; i < 16; ++i)
    {
      gpt_guid[2 * i] = digits[gpt[56 + i] >> 4];
      gpt_guid[2 * i + 1] = digits[gpt[56 + i] & 15];
    }
  gpt_guid[32] = 0;

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

  /* Populate the original GRUB-side Ventoy ABI with REAL exported
   * functions, as upstream ventoy_cmd.c does. The preceding source,
   * GPT and extent checks provide the diagnostic device-check result.
   * This is NOT a statement of compatibility with the full Ventoy
   * standard two-partition layout or successful installer boot. */
  env_param = grub_zalloc (sizeof (*env_param));
  if (!env_param)
    {
      error = grub_errno;
      goto done;
    }
  env_param->grub_env_get = grub_env_get;
  env_param->grub_env_set = (grub_env_set_pf) grub_env_set;
  env_param->grub_env_printf = (grub_env_printf_pf) grub_printf;
  if (grub_env_set ("VTOY_CHKDEV_RESULT_STRING", "0"))
    {
      error = grub_errno;
      goto done;
    }

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
  {
    char addr[40];
    char size[40];
    grub_snprintf (addr, sizeof (addr), "0x%llx",
                   (unsigned long long) (grub_addr_t) chain);
    grub_snprintf (size, sizeof (size), "%llu",
                   (unsigned long long) length);
    char env_addr[40];
    grub_snprintf (env_addr, sizeof (env_addr), "0x%llx",
                   (unsigned long long) (grub_addr_t) env_param);
    grub_env_set ("vt_probe_chain_addr", addr);
    grub_env_set ("vt_probe_chain_size", size);
    grub_env_set ("vt_probe_gpt_guid", gpt_guid);
    grub_env_set ("vt_probe_env_addr", env_addr);
    grub_printf ("VT_GPT_GUID hex=%s\n", gpt_guid);
    grub_printf ("VT_ENV_PARAM bytes=%u live_get=1 live_set=1\n",
                 (unsigned) sizeof (*env_param));
    vt_pending_env = env_param;
    vt_pending_chain = chain;
    env_param = 0;
    chain = 0; /* module owns both objects through EFI StartImage */
  }
  grub_printf ("VT_HANDOFF_PREPARED efi_invoke=no catalog_unverified=yes\n");

done:
  if (error)
    grub_env_unset ("VTOY_CHKDEV_RESULT_STRING");
  grub_free (env_param);
  grub_free (chain);
  if (disk)
    grub_disk_close (disk);
  return error;
}
