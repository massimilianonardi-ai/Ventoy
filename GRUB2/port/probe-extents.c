/*
 * Diagnostic ISO9660 extent mapper, built as part of the external
 * ventoy_source_probe.mod against stock, version-matched GRUB.
 *
 * Not a Ventoy chainloader. No virtual links or GRUB core modifications.
 * Every reported byte extent is independently checked against raw QEMU
 * disk image bytes by verify-extent-map.py.
 */
#include <grub/types.h>
#include <grub/command.h>
#include <grub/disk.h>
#include <grub/partition.h>
#include <grub/file.h>
#include <grub/mm.h>
#include <grub/misc.h>
#include <grub/err.h>

#define VT_MAP_READ_BUFFER 32768U
#define VT_MAP_MAX_EXTENTS 16384U
#define VT_MAP_SECTOR_BITS 9U
#define VT_MAP_SECTOR_SIZE (1U << VT_MAP_SECTOR_BITS)

struct vt_map_extent
{
  grub_uint64_t logical;
  grub_uint64_t physical;
  grub_uint64_t length;
};

struct vt_map_context
{
  struct vt_map_extent *extents;
  grub_uint32_t count;
  grub_uint32_t capacity;
  grub_uint64_t partition_sector;
  grub_uint64_t mapped;
  int bad;
};

static grub_command_t vt_map_command;

void vt_register_extent_probe (void);
void vt_unregister_extent_probe (void);

static grub_err_t
vt_map_hook (grub_disk_addr_t sector, unsigned offset,
             unsigned length, char *buf __attribute__ ((unused)),
             void *data)
{
  struct vt_map_context *ctx = (struct vt_map_context *) data;
  struct vt_map_extent *last;
  grub_uint64_t physical;
  grub_uint64_t logical;
  grub_uint64_t span;

  if (ctx->bad || !length)
    return GRUB_ERR_NONE;

  /* On the runner's GRUB 2.12 the file read hook reports physical
     sectors on the WHOLE disk, not partition-relative sectors. This
     was established by the independent raw-GPT-byte verification:
     adding partition->start twice produced a provably wrong map. */
  if (offset >= VT_MAP_SECTOR_SIZE
      || sector < ctx->partition_sector
      || sector > (~(grub_uint64_t) 0 >> VT_MAP_SECTOR_BITS))
    {
      ctx->bad = 1;
      return GRUB_ERR_NONE;
    }

  physical = (sector << VT_MAP_SECTOR_BITS) + offset;
  logical = ctx->mapped;
  span = (grub_uint64_t) length;

  if (logical > ~(grub_uint64_t) 0 - span
      || physical > ~(grub_uint64_t) 0 - span)
    {
      ctx->bad = 1;
      return GRUB_ERR_NONE;
    }

  if (ctx->count)
    {
      last = &ctx->extents[ctx->count - 1];
      if (last->physical + last->length == physical
          && last->logical + last->length == logical)
        {
          last->length += span;
          ctx->mapped += span;
          return GRUB_ERR_NONE;
        }
    }

  if (ctx->count == ctx->capacity)
    {
      grub_uint32_t capacity = ctx->capacity ? ctx->capacity * 2U : 64U;
      struct vt_map_extent *extended;

      if (capacity > VT_MAP_MAX_EXTENTS)
        capacity = VT_MAP_MAX_EXTENTS;
      if (ctx->count == capacity)
        {
          ctx->bad = 2;
          return GRUB_ERR_NONE;
        }

      extended = grub_realloc (ctx->extents,
                                capacity * sizeof (struct vt_map_extent));
      if (!extended)
        {
          ctx->bad = 3;
          return GRUB_ERR_NONE;
        }
      ctx->extents = extended;
      ctx->capacity = capacity;
    }

  last = &ctx->extents[ctx->count++];
  last->logical = logical;
  last->physical = physical;
  last->length = span;
  ctx->mapped += span;
  return GRUB_ERR_NONE;
}

/* Read a real ISO9660 PVD without including these metadata lookups in
   the reported map. The mapping pass itself starts at offset zero. */
static int
vt_map_is_iso9660 (grub_file_t file)
{
  char signature[5];
  if (file->size < 17ULL * 2048ULL || (file->size % 2048) != 0)
    return 0;
  if (grub_file_seek (file, 16ULL * 2048ULL + 1) == (grub_off_t) -1)
    return 0;
  if (grub_file_read (file, signature, sizeof (signature))
      != (grub_ssize_t) sizeof (signature))
    return 0;
  return grub_memcmp (signature, "CD001", 5) == 0;
}

static grub_err_t
vt_probe_extent_map (grub_command_t cmd __attribute__ ((unused)),
                     int argc, char **args)
{
  grub_file_t file = 0;
  grub_disk_t disk;
  grub_partition_t partition;
  struct vt_map_context map;
  grub_uint8_t *buffer = 0;
  grub_off_t remaining;
  grub_uint32_t i;
  grub_err_t err = GRUB_ERR_NONE;

  grub_memset (&map, 0, sizeof (map));

  if (argc != 1)
    return grub_error (GRUB_ERR_BAD_ARGUMENT,
                       "usage: vt_extent_probe (device)/image.iso");

  file = grub_file_open (args[0], GRUB_FILE_TYPE_NONE);
  if (!file)
    return grub_errno;

  disk = file->device ? file->device->disk : 0;
  partition = disk ? disk->partition : 0;
  if (!disk || !partition || !file->fs)
    {
      err = grub_error (GRUB_ERR_BAD_DEVICE, "ISO must be on a disk partition");
      goto out;
    }

  /* This first proof supports 512-byte GRUB sectors and ISO9660
     regular files. Other filesystems can be added with real tests. */
  if (!vt_map_is_iso9660 (file))
    {
      err = grub_error (GRUB_ERR_BAD_FILE_TYPE, "invalid ISO9660 image");
      goto out;
    }

  map.partition_sector = partition->start;
  buffer = grub_malloc (VT_MAP_READ_BUFFER);
  if (!buffer)
    {
      err = grub_errno;
      goto out;
    }

  if (grub_file_seek (file, 0) == (grub_off_t) -1)
    {
      err = grub_errno;
      goto out;
    }

  file->read_hook = vt_map_hook;
  file->read_hook_data = &map;

  remaining = file->size;
  while (remaining)
    {
      grub_size_t amount = remaining > VT_MAP_READ_BUFFER
                           ? VT_MAP_READ_BUFFER : (grub_size_t) remaining;
      grub_ssize_t got = grub_file_read (file, buffer, amount);

      if (got != (grub_ssize_t) amount || map.bad)
        {
          err = grub_error (GRUB_ERR_READ_ERROR,
                            "ISO extent capture failed (read=%ld, map=%d)",
                            (long) got, map.bad);
          break;
        }
      remaining -= amount;
    }

  file->read_hook = 0;
  file->read_hook_data = 0;

  if (err)
    goto out;

  if (map.mapped != (grub_uint64_t) file->size || !map.count)
    {
      err = grub_error (GRUB_ERR_BAD_FS,
                        "ISO extent coverage incomplete");
      goto out;
    }

  grub_printf ("VT_MAP_HEADER image_bytes=%llu count=%u disk=%s part=%u\n",
               (unsigned long long) file->size, (unsigned) map.count,
               disk->name, (unsigned) partition->number + 1U);

  for (i = 0; i < map.count; ++i)
    grub_printf ("VT_MAP extent=%u logical=%llu physical=%llu size=%llu\n",
                 (unsigned) i,
                 (unsigned long long) map.extents[i].logical,
                 (unsigned long long) map.extents[i].physical,
                 (unsigned long long) map.extents[i].length);

  grub_printf ("VT_MAP_SUCCESS extents=%u total=%llu\n",
               (unsigned) map.count, (unsigned long long) map.mapped);

out:
  if (file)
    {
      file->read_hook = 0;
      file->read_hook_data = 0;
      grub_file_close (file);
    }
  grub_free (map.extents);
  grub_free (buffer);
  return err;
}

void
vt_register_extent_probe (void)
{
  vt_map_command =
    grub_register_command ("vt_extent_probe", vt_probe_extent_map,
                           "FILE", "Capture and report real ISO file extents.");
}

void
vt_unregister_extent_probe (void)
{
  if (vt_map_command)
    grub_unregister_command (vt_map_command);
}
