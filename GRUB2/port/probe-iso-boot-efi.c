/* Standalone disposable EFI payload genuinely loaded FROM the ISO by the
 * authentic Ventoy EDK2 boot path. It is NOT an installer or a dummy marker
 * emitted by GRUB or by Ventoy itself. The marker is emitted inside efi_main.
 */
#include <efi.h>
#include <efilib.h>

EFI_STATUS
efi_main (EFI_HANDLE image, EFI_SYSTEM_TABLE *system)
{
  EFI_GUID serial_guid = EFI_SERIAL_IO_PROTOCOL_GUID;
  EFI_SERIAL_IO_PROTOCOL *serial = NULL;
  EFI_STATUS status;
  static CHAR8 message[] = "VT_ORIGINAL_ISO_EFI_STARTIMAGE_EXECUTED\r\n";
  UINTN length = sizeof (message) - 1;
  (void) image;
  if (!system || !system->BootServices)
    return EFI_INVALID_PARAMETER;
  status = uefi_call_wrapper (system->BootServices->LocateProtocol, 3,
                              &serial_guid, NULL, (VOID **)&serial);
  if (EFI_ERROR (status) || !serial)
    return EFI_NOT_FOUND;
  status = uefi_call_wrapper (serial->Write, 3, serial, &length, message);
  return status;
}
