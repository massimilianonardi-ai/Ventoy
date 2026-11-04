/*
 * Experimental source-location proof for an unmodified GRUB 2.12 runtime.
 *
 * NOT Ventoy's ISO chainloader and NOT a production command/module.
 * This validates the core invariant required for a core-independent
 * Ventoy port: a loadable GRUB module can inspect an image on an arbitrary
 * GRUB-accessible partition without a virtual link or core-file patch.
 */
#include <grub/dl.h>
#include <grub/command.h>
#include <grub/file.h>
#include <grub/disk.h>
#include <grub/partition.h>
#include <grub/fs.h>
#include <grub/misc.h>
#include <grub/err.h>

GRUB_MOD_LICENSE ("GPLv3+");

extern void vt_register_extent_probe (void);
extern void vt_unregister_extent_probe (void);
extern void vt_release_handoff_probe (void);
extern void vt_register_efi_publish_probe (void);
extern void vt_register_overlay_probe (void);
extern void vt_unregister_overlay_probe (void);
extern void vt_unregister_efi_publish_probe (void);

static grub_command_t source_probe_command;

static grub_err_t
probe_image_source (grub_command_t command __attribute__ ((unused)),
                    int argc, char **args)
{
  grub_file_t file;
  grub_disk_t disk;
  grub_partition_t part;
  grub_err_t result = GRUB_ERR_NONE;

  if (argc != 1)
    return grub_error (GRUB_ERR_BAD_ARGUMENT,
                       "usage: vt_source_probe (device)/path/to/image.iso");

  file = grub_file_open (args[0], GRUB_FILE_TYPE_NONE);
  if (!file)
    return grub_errno;

  disk = file->device ? file->device->disk : 0;
  part = disk ? disk->partition : 0;

  if (!disk || !part || !file->fs)
    result = grub_error (GRUB_ERR_BAD_DEVICE,
                         "image is not on a readable disk partition");
  else
    grub_printf ("source=%s disk=%s partition=%u start=%llu fs=%s bytes=%llu\n",
                 args[0], disk->name, (unsigned) part->number + 1,
                 (unsigned long long) part->start, file->fs->name,
                 (unsigned long long) file->size);

  grub_file_close (file);
  return result;
}

GRUB_MOD_INIT (ventoy_source_probe)
{
  source_probe_command =
    grub_register_command ("vt_source_probe", probe_image_source,
                           "FILE", "Inspect real image source without VLNK.");
  vt_register_extent_probe ();
  vt_register_efi_publish_probe ();
  vt_register_overlay_probe ();
}

GRUB_MOD_FINI (ventoy_source_probe)
{
  vt_unregister_overlay_probe ();
  vt_unregister_efi_publish_probe ();
  vt_unregister_extent_probe ();
  vt_release_handoff_probe ();
  grub_unregister_command (source_probe_command);
}
