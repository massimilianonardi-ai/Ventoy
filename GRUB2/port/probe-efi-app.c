/*
 * Disposable UEFI diagnostic. Read the ORIGINAL Ventoy "mem:0x...:size:..."
 * LoadOptions and validate a chain header still owned by GRUB.
 * The diagnostic installs and removes temporary read-only BlockIo; it
 * never boots an installer or modifies Ventoy's original EDK2 ABI.
 */
#include <efi.h>
#include <efilib.h>

extern EFI_STATUS vt_check_efi_blockmap (EFI_SYSTEM_TABLE *system,
                                         const UINT8 *chain, UINT64 length,
                                         const UINT8 gpt_guid[16],
                                         EFI_SERIAL_IO_PROTOCOL *serial);

static UINTN
hex_digit (CHAR16 c)
{
  if (c >= L'0' && c <= L'9') return (UINTN)(c - L'0');
  if (c >= L'a' && c <= L'f') return (UINTN)(c - L'a' + 10);
  if (c >= L'A' && c <= L'F') return (UINTN)(c - L'A' + 10);
  return 255;
}

static UINT64
little (const UINT8 *p, UINTN n)
{
  UINT64 value = 0;
  UINTN i;
  for (i = 0; i < n; ++i)
    value |= (UINT64)p[i] << (i * 8);
  return value;
}

static EFI_STATUS
check_chain (EFI_LOADED_IMAGE *loaded, const UINT8 **chain_out,
             UINT64 *length_out)
{
  CHAR16 *p = (CHAR16 *)loaded->LoadOptions;
  UINTN chars = loaded->LoadOptionsSize / sizeof (CHAR16);
  UINTN i = 0, digit, seen = 0;
  UINT64 addr = 0, size = 0, chunks;
  const UINT8 *b;
  UINT8 sum = 0;
  UINT8 ventoy_guid[16] = {
    0x20, 0x20, 0x77, 0x77, 0x77, 0x2e, 0x76, 0x65,
    0x6e, 0x74, 0x6f, 0x79, 0x2e, 0x6e, 0x65, 0x74
  };

  if (!p || chars < 15 || chars > 128)
    return EFI_INVALID_PARAMETER;
  if (p[i++] != L'm' || p[i++] != L'e' || p[i++] != L'm'
      || p[i++] != L':' || p[i++] != L'0' || p[i++] != L'x')
    return EFI_INVALID_PARAMETER;
  while (i < chars && (digit = hex_digit (p[i])) != 255)
    {
      if (addr > ((~(UINT64)0 - digit) >> 4))
        return EFI_INVALID_PARAMETER;
      addr = addr * 16 + digit;
      ++i;
      ++seen;
    }
  if (!seen || i + 6 >= chars || p[i++] != L':'
      || p[i++] != L's' || p[i++] != L'i' || p[i++] != L'z'
      || p[i++] != L'e' || p[i++] != L':')
    return EFI_INVALID_PARAMETER;
  seen = 0;
  while (i < chars && p[i] >= L'0' && p[i] <= L'9')
    {
      digit = (UINTN)(p[i++] - L'0');
      if (size > ((~(UINT64)0 - digit) / 10))
        return EFI_INVALID_PARAMETER;
      size = size * 10 + digit;
      ++seen;
    }
  if (!seen || addr == 0 || size < 2616 || size > 1024 * 1024
      || addr > (UINT64)(UINTN)(~(UINTN)0))
    return EFI_INVALID_PARAMETER;

  b = (const UINT8 *)(UINTN)addr;
  for (i = 0; i < 16; ++i)
    if (b[i] != ventoy_guid[i])
      return EFI_COMPROMISED_DATA;
  for (i = 0; i < 512; ++i)
    sum = (UINT8)(sum + b[i]);
  if (sum || little (b + 429, 8) == 0
      || little (b + 2592, 4) != 2616
      || little (b + 524, 8) != little (b + 429, 8)
      || little (b + 532, 8) != little (b + 429, 8))
    return EFI_COMPROMISED_DATA;
  chunks = little (b + 2596, 4);
  if (!chunks || chunks > 16384 || size != 2616 + chunks * 24)
    return EFI_COMPROMISED_DATA;
  *chain_out = b;
  *length_out = size;
  return EFI_SUCCESS;
}

/* Extra test-only LoadOptions token, NOT the upstream env_param ABI. */
static EFI_STATUS
parse_gpt_guid (EFI_LOADED_IMAGE *image, UINT8 guid[16])
{
  static const CHAR16 keyword[] = L"gptguid:";
  const CHAR16 *option = (const CHAR16 *)image->LoadOptions;
  UINTN count, i, j;

  if (!option || (image->LoadOptionsSize % sizeof (CHAR16)) != 0)
    return EFI_INVALID_PARAMETER;
  count = image->LoadOptionsSize / sizeof (CHAR16);
  for (i = 0; i + 40 <= count; ++i)
    {
      if (i && option[i - 1] != L' ')
        continue;
      for (j = 0; j < 8 && option[i + j] == keyword[j]; ++j)
        ;
      if (j != 8)
        continue;
      if (i + 40 < count && option[i + 40] != L' '
          && option[i + 40] != 0)
        return EFI_INVALID_PARAMETER;
      for (j = 0; j < 16; ++j)
        {
          UINTN high = hex_digit (option[i + 8 + j * 2]);
          UINTN low = hex_digit (option[i + 9 + j * 2]);
          if (high == 255 || low == 255)
            return EFI_INVALID_PARAMETER;
          guid[j] = (UINT8) ((high << 4) | low);
        }
      return EFI_SUCCESS;
    }
  return EFI_INVALID_PARAMETER;
}

EFI_STATUS EFIAPI
efi_main (EFI_HANDLE image, EFI_SYSTEM_TABLE *system)
{
  EFI_GUID loaded_guid = LOADED_IMAGE_PROTOCOL;
  EFI_GUID serial_guid = SERIAL_IO_PROTOCOL;
  EFI_LOADED_IMAGE *loaded = NULL;
  EFI_SERIAL_IO_PROTOCOL *serial = NULL;
  EFI_STATUS status;
  const UINT8 *chain = NULL;
  UINT64 chain_length = 0;
  UINT8 gpt_guid[16];
  UINTN bytes;
  CHAR8 message[] = "VT_EFI_MEMORY_HANDOFF_OK\r\n";

  InitializeLib (image, system);

  status = uefi_call_wrapper (system->BootServices->HandleProtocol, 3,
                              image, &loaded_guid, (VOID **)&loaded);
  if (EFI_ERROR (status))
    return status;
  status = check_chain (loaded, &chain, &chain_length);
  if (EFI_ERROR (status))
    return status;
  status = parse_gpt_guid (loaded, gpt_guid);
  if (EFI_ERROR (status))
    return status;

  status = uefi_call_wrapper (system->BootServices->LocateProtocol, 3,
                              &serial_guid, NULL, (VOID **)&serial);
  if (EFI_ERROR (status) || !serial)
    return EFI_NOT_FOUND;

  {
    CHAR8 begin[] = "VT_EFI_BLOCKMAP_BEGIN\r\n";
    bytes = sizeof (begin) - 1;
    uefi_call_wrapper (serial->Write, 3, serial, &bytes, begin);
  }
  status = vt_check_efi_blockmap (system, chain, chain_length, gpt_guid,
                                  serial);
  if (EFI_ERROR (status))
    {
      static const CHAR8 hex[] = "0123456789abcdef";
      static const CHAR8 prefix[] = "VT_EFI_BLOCKMAP_FAILED status=0x";
      CHAR8 failed[sizeof (prefix) + 16 + 2];
      UINTN i;
      CopyMem (failed, prefix, sizeof (prefix) - 1);
      for (i = 0; i < 16; ++i)
        failed[sizeof (prefix) - 1 + i] =
          hex[((UINT64)status >> ((15 - i) * 4)) & 15U];
      bytes = sizeof (prefix) - 1 + 16;
      failed[bytes++] = '\r';
      failed[bytes++] = '\n';
      uefi_call_wrapper (serial->Write, 3, serial, &bytes, failed);
      return status;
    }

  bytes = sizeof (message) - 1;
  status = uefi_call_wrapper (serial->Write, 3, serial, &bytes, message);
  return status;
}
