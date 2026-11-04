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
#include <grub/efi/efi.h>
#include <grub/efi/api.h>
#include <grub/command.h>

/* Keep both original Ventoy ABI objects in GRUB memory until StartImage
 * returns or this module is unloaded. Neither survives GRUB teardown. */
static ventoy_chain_head *vt_pending_chain;
static ventoy_grub_param *vt_pending_env;


/*
 * Experimental, volatile UEFI Runtime Services handoff.
 * Transport original upstream Ventoy os_param + img_chunk records,
 * supplemented only with the GPT disk GUID to identify the physical
 * backing device in Linux after ExitBootServices.
 *
 * Wire header is private to this isolated probe, not a product API.
 * x86_64 little endian only; the existing firmware probe is x86_64 EFI.
 */
struct __attribute__ ((packed)) vt_efi_map_payload
{
  grub_uint8_t magic[8];       /* "VTDMAP01" */
  grub_uint32_t count;
  grub_uint32_t chunk_bytes;
  grub_uint64_t iso_bytes;
  grub_uint8_t gpt_guid[16];
  ventoy_os_param os_param;    /* ORIGINAL upstream layout */
  ventoy_img_chunk chunks[1]; /* ORIGINAL upstream layout */
};

void vt_register_efi_publish_probe (void);
void vt_unregister_efi_publish_probe (void);
static grub_command_t vt_efi_publish_command;
/* The GUID is encoded in UEFI wire byte order to remain compatible
 * with distro GRUB versions that represent grub_efi_guid_t differently. */
static const grub_uint8_t vt_efi_probe_guid_bytes[16] = {
  0xd4, 0x24, 0x5e, 0x0e, 0x8b, 0x16, 0x9e, 0x4f,
  0xa3, 0x97, 0x09, 0x51, 0xf7, 0x57, 0x11, 0x1e
};
static grub_efi_char16_t vt_efi_probe_var[] =
  { 'V', 't', 'D', 'm', 'M', 'a', 'p', 'P', 'r', 'o', 'b', 'e', 0 };

static int
vt_hex_val (char x)
{
  if (x >= '0' && x <= '9')
    return x - '0';
  if (x >= 'a' && x <= 'f')
    return x - 'a' + 10;
  if (x >= 'A' && x <= 'F')
    return x - 'A' + 10;
  return -1;
}

/* Can only be called after vt_extent_probe succeeded and retained
 * the original Ventoy chain in live GRUB memory. */
static grub_err_t
vt_publish_efi_map (grub_command_t command __attribute__ ((unused)),
                    int argc, char **args __attribute__ ((unused)))
{
  const char *guid_text = grub_env_get ("vt_probe_gpt_guid");
  const ventoy_chain_head *chain = vt_pending_chain;
  struct vt_efi_map_payload *payload = 0;
  grub_size_t data_bytes;
  grub_uint32_t i;
  grub_efi_status_t status;
  grub_guid_t probe_guid;
  static const grub_uint8_t magic[] = "VTDMAP01";

  if (argc != 0)
    return grub_error (GRUB_ERR_BAD_ARGUMENT, "usage: vt_publish_efi_map");
  if (!chain || !guid_text || grub_strlen (guid_text) != 32
      || chain->img_chunk_num == 0 || chain->img_chunk_num > 16384
      || chain->img_chunk_offset != sizeof (*chain)
      || chain->disk_sector_size != 512
      || chain->real_img_size_in_bytes != chain->virt_img_size_in_bytes)
    return grub_error (GRUB_ERR_BAD_ARGUMENT,
                       "no complete original Ventoy image map available");
  /* UEFI volatile variable size depends on firmware: stay deliberately
   * small for this transport proof, fail rather than silently truncate. */
  data_bytes = sizeof (*payload) - sizeof (payload->chunks)
               + (grub_size_t) chain->img_chunk_num
                 * sizeof (ventoy_img_chunk);
  if (data_bytes > 16384)
    return grub_error (GRUB_ERR_OUT_OF_RANGE,
                       "probe EFI variable exceeds 16 KiB budget");

  payload = grub_zalloc (data_bytes);
  if (!payload)
    return grub_errno;
  grub_memcpy (payload->magic, magic, sizeof (payload->magic));
  payload->count = chain->img_chunk_num;
  payload->chunk_bytes = sizeof (ventoy_img_chunk);
  payload->iso_bytes = chain->real_img_size_in_bytes;
  payload->os_param = chain->os_param;
  grub_memcpy (payload->chunks,
               (const grub_uint8_t *) chain + chain->img_chunk_offset,
               (grub_size_t) chain->img_chunk_num * sizeof (ventoy_img_chunk));
  for (i = 0; i != 16; ++i)
    {
      int high = vt_hex_val (guid_text[2 * i]);
      int low = vt_hex_val (guid_text[2 * i + 1]);
      if (high < 0 || low < 0)
        {
          grub_free (payload);
          return grub_error (GRUB_ERR_BAD_ARGUMENT,
                             "invalid source GPT identifier");
        }
      payload->gpt_guid[i] = (grub_uint8_t) ((high << 4) | low);
    }

  if (!grub_efi_system_table || !grub_efi_system_table->runtime_services
      || !grub_efi_system_table->runtime_services->set_variable)
    {
      grub_free (payload);
      return grub_error (GRUB_ERR_BAD_DEVICE, "UEFI Runtime Services absent");
    }
  if (sizeof (probe_guid) != sizeof (vt_efi_probe_guid_bytes))
    {
      grub_free (payload);
      return grub_error (GRUB_ERR_BAD_DEVICE,
                         "unsupported GRUB EFI GUID layout");
    }
  grub_memcpy (&probe_guid, vt_efi_probe_guid_bytes, sizeof (probe_guid));
  status = grub_efi_system_table->runtime_services->set_variable
    (vt_efi_probe_var, &probe_guid,
     GRUB_EFI_VARIABLE_BOOTSERVICE_ACCESS
     | GRUB_EFI_VARIABLE_RUNTIME_ACCESS,
     data_bytes, payload);
  grub_free (payload);
  if (status != GRUB_EFI_SUCCESS)
    return grub_error (GRUB_ERR_BAD_DEVICE, "UEFI SetVariable returned %llu",
                       (unsigned long long) status);
  grub_printf ("VT_EFI_MAP_PUBLISHED count=%u bytes=%lu iso_bytes=%llu\\n",
               (unsigned) chain->img_chunk_num, (unsigned long) data_bytes,
               (unsigned long long) chain->real_img_size_in_bytes);
  return GRUB_ERR_NONE;
}

void
vt_register_efi_publish_probe (void)
{
  vt_efi_publish_command =
    grub_register_command ("vt_publish_efi_map", vt_publish_efi_map,
                           0, "Publish original extent map to volatile EFI runtime variable.");
}

void
vt_unregister_efi_publish_probe (void)
{
  if (vt_efi_publish_command)
    grub_unregister_command (vt_efi_publish_command);
}


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
