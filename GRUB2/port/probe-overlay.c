/* GRUB ISO9660 root-file shadow probe for original Ventoy overlay ABI.
 * Only for disposable fixture; no custom core or virtual link.
 */
#include <grub/types.h>
#include <grub/command.h>
#include <grub/file.h>
#include <grub/mm.h>
#include <grub/misc.h>
#include <grub/err.h>

#define VT_ISO_SECTOR 2048U
#define VT_OVERLAY_MAX_BYTES (64U * 1024U)

static grub_command_t vt_overlay_command;

extern grub_err_t vt_probe_set_overlay (grub_uint64_t record_offset,
                                        const grub_uint8_t *data,
                                        grub_size_t length);

static grub_uint32_t
vt_le32 (const grub_uint8_t *p)
{
  return (grub_uint32_t) p[0] | ((grub_uint32_t) p[1] << 8)
       | ((grub_uint32_t) p[2] << 16) | ((grub_uint32_t) p[3] << 24);
}

static int
vt_read_iso_sector (grub_file_t iso, grub_uint32_t lba,
                    grub_uint8_t buf[VT_ISO_SECTOR])
{
  if (grub_file_seek (iso, (grub_off_t) lba * VT_ISO_SECTOR)
      == (grub_off_t) -1)
    return 0;
  return grub_file_read (iso, buf, VT_ISO_SECTOR) == VT_ISO_SECTOR;
}

/* The synthetic fixture contains PAYLOAD.BIN;1 in the primary ISO root.
 * Read the original PVD/dirent from stock GRUB's ISO file, not host hints. */
static grub_err_t
vt_find_fixture_record (grub_file_t iso, grub_uint64_t *record)
{
  grub_uint8_t pvd[VT_ISO_SECTOR], root[VT_ISO_SECTOR];
  grub_uint32_t root_lba, root_size, cursor = 0;
  static const char name[] = "PAYLOAD.BIN;1";

  if (!vt_read_iso_sector (iso, 16, pvd)
      || grub_memcmp (pvd, "\001CD001\001", 7))
    return grub_error (GRUB_ERR_BAD_FS, "missing ISO9660 primary volume");
  root_lba = vt_le32 (pvd + 158);
  root_size = vt_le32 (pvd + 166);
  if (!root_size || root_size > VT_ISO_SECTOR
      || ((grub_uint64_t) root_lba + 1) * VT_ISO_SECTOR > iso->size
      || !vt_read_iso_sector (iso, root_lba, root))
    return grub_error (GRUB_ERR_BAD_FS, "fixture root directory invalid");

  while (cursor < root_size)
    {
      grub_uint32_t len = root[cursor];
      grub_uint8_t namelen;
      if (!len)
        break;
      if (len < 34 || len > root_size - cursor)
        return grub_error (GRUB_ERR_BAD_FS, "invalid ISO directory entry");
      namelen = root[cursor + 32];
      if (namelen == sizeof (name) - 1
          && namelen <= len - 33
          && grub_memcmp (root + cursor + 33, name, namelen) == 0)
        {
          grub_uint32_t lba = vt_le32 (root + cursor + 2);
          grub_uint32_t size = vt_le32 (root + cursor + 10);
          if ((root[cursor + 25] & 2) || !size
              || (grub_uint64_t) lba * VT_ISO_SECTOR + size > iso->size)
            return grub_error (GRUB_ERR_BAD_FS,
                               "invalid original ISO file extent");
          *record = (grub_uint64_t) root_lba * VT_ISO_SECTOR
                    + cursor + 2;
          return GRUB_ERR_NONE;
        }
      cursor += len;
    }
  return grub_error (GRUB_ERR_FILE_NOT_FOUND,
                     "fixture PAYLOAD.BIN;1 not found");
}

static grub_err_t
vt_overlay_probe (grub_command_t cmd __attribute__ ((unused)),
                  int argc, char **args)
{
  grub_file_t iso = 0, payload = 0;
  grub_uint8_t *data = 0;
  grub_uint64_t record = 0;
  grub_err_t error = GRUB_ERR_NONE;
  grub_size_t length;

  if (argc != 2)
    return grub_error (GRUB_ERR_BAD_ARGUMENT,
                       "usage: vt_overlay_probe ISO REPLACEMENT");
  iso = grub_file_open (args[0], GRUB_FILE_TYPE_NONE);
  if (!iso)
    return grub_errno;
  error = vt_find_fixture_record (iso, &record);
  if (error)
    goto out;
  payload = grub_file_open (args[1], GRUB_FILE_TYPE_NONE);
  if (!payload)
    {
      error = grub_errno;
      goto out;
    }
  if (!payload->size || payload->size > VT_OVERLAY_MAX_BYTES)
    {
      error = grub_error (GRUB_ERR_BAD_ARGUMENT,
                          "replacement exceeds bounded probe size");
      goto out;
    }
  length = (grub_size_t) payload->size;
  data = grub_malloc (length);
  if (!data)
    {
      error = grub_errno;
      goto out;
    }
  if (grub_file_read (payload, data, length) != (grub_ssize_t) length)
    {
      error = grub_error (GRUB_ERR_READ_ERROR,
                          "replacement file could not be read");
      goto out;
    }
  error = vt_probe_set_overlay (record, data, length);
  if (!error)
    grub_printf ("VT_OVERLAY_PREPARED record=%llu bytes=%lu\n",
                 (unsigned long long) record, (unsigned long) length);
out:
  grub_free (data);
  if (payload)
    grub_file_close (payload);
  grub_file_close (iso);
  return error;
}

void vt_register_overlay_probe (void);
void vt_unregister_overlay_probe (void);

void
vt_register_overlay_probe (void)
{
  vt_overlay_command = grub_register_command
    ("vt_overlay_probe", vt_overlay_probe,
     "ISO REPLACEMENT", "Prepare one disposable ISO file shadow.");
}

void
vt_unregister_overlay_probe (void)
{
  if (vt_overlay_command)
    grub_unregister_command (vt_overlay_command);
}
