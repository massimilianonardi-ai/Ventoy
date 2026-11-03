/* Diagnostic-only original Ventoy chain header layout probe. */
#include <grub/types.h>
#include <grub/file.h>
#include <grub/misc.h>
#include <grub/ventoy.h>

void
vt_probe_handoff_layout (void)
{
  grub_printf ("VT_HANDOFF_LAYOUT head=%u os_param=%u chunk=%u location=%u\n",
               (unsigned) sizeof (ventoy_chain_head),
               (unsigned) sizeof (ventoy_os_param),
               (unsigned) sizeof (ventoy_img_chunk),
               (unsigned) sizeof (ventoy_image_location));
}
