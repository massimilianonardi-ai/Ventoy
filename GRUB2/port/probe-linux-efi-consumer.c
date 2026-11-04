/*
 * Experimental early Linux consumer for the GRUB source probe's volatile
 * EFI Runtime Services variable.  Not a driver, release API, or Proxmox hook.
 * Only validates the original ventoy_img_chunk ABI on a disposable GPT disk.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VAR "/sys/firmware/efi/efivars/VtDmMapProbe-0e5e24d4-168b-4f9e-a397-0951f757111e"
#define MAX_MAP 16384
#define OS_PARAM_BYTES 512
#define HEADER_BYTES 40
#define CHUNK_BYTES 24

static uint8_t buffer[MAX_MAP + 4];

static void die(const char *cause)
{
    fprintf(stderr, "VT_LINUX_HANDOFF_ERROR %s errno=%d\n", cause, errno);
    exit(1);
}
static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rd64(const uint8_t *p)
{
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}
static void read_exact(int fd, void *target, size_t size, off_t off)
{
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(fd, (char *)target + done, size - done,
                          off + (off_t)done);
        if (n <= 0) die("read physical GPT failed");
        done += (size_t)n;
    }
}

/* Identify the WHOLE disk by real primary GPT GUID, never trust /dev/vdb.
 * Also verify physical size against the original Ventoy os_param field. */
static int locate_disk(const uint8_t *guid, uint64_t expected_bytes,
                       char *whole, size_t capacity)
{
    DIR *dir = opendir("/sys/block");
    struct dirent *entry;
    int matches = 0;
    if (!dir) die("missing /sys/block");
    while ((entry = readdir(dir)) != NULL) {
        const char *name = entry->d_name;
        char path[256];
        uint8_t gpt[512];
        uint64_t bytes = 0;
        int fd;
        if (strncmp(name, "vd", 2) && strncmp(name, "sd", 2)
            && strncmp(name, "nvme", 4) && strncmp(name, "mmcblk", 6))
            continue;
        if (snprintf(path, sizeof(path), "/dev/%s", name) >= (int)sizeof(path))
            continue;
        fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, BLKGETSIZE64, &bytes) != 0 || bytes != expected_bytes) {
            close(fd);
            continue;
        }
        memset(gpt, 0, sizeof(gpt));
        if (pread(fd, gpt, sizeof(gpt), 512) != (ssize_t)sizeof(gpt)
            || memcmp(gpt, "EFI PART", 8)
            || memcmp(gpt + 56, guid, 16)) {
            close(fd);
            continue;
        }
        if (++matches == 1) {
            if (snprintf(whole, capacity, "%s", path) >= (int)capacity)
                die("source device name too long");
        }
        close(fd);
    }
    closedir(dir);
    if (matches != 1) die("source GPT identity missing or ambiguous");
    return 0;
}

int main(int argc, char **argv)
{
    int fd, src;
    ssize_t n;
    const uint8_t *p, *os, *chunks;
    uint32_t count;
    uint64_t iso_bytes, expected = 0;
    uint16_t part;
    char whole[256] = {0}, partition[256], sys_start[300];
    char line[128];
    unsigned long long start_sector;
    uint64_t partition_last, disk_size;
    uint8_t gpt[512], entry[128];
    FILE *table, *sys;
    uint32_t i;
    unsigned os_sum = 0;
    static const uint8_t expected_ventoy_guid[16] = {
        0x20,0x20,0x77,0x77,0x77,0x2e,0x76,0x65,
        0x6e,0x74,0x6f,0x79,0x2e,0x6e,0x65,0x74
    };
    if (argc != 2) die("usage: probe-linux-efi-consumer TABLE_PATH");
    fd = open(VAR, O_RDONLY | O_CLOEXEC);
    if (fd < 0) die("efi runtime variable is not visible after ExitBootServices");
    n = read(fd, buffer, sizeof(buffer));
    close(fd);
    if (n <= 0 || n < 4 + HEADER_BYTES + OS_PARAM_BYTES
        || (rd32(buffer) & 6) != 6)
        die("invalid EFI runtime variable");
    p = buffer + 4;
    if (memcmp(p, "VTDMAP01", 8)) die("invalid UEFI map magic");
    count = rd32(p + 8);
    iso_bytes = rd64(p + 16);
    if (!count || count > 640 || rd32(p + 12) != CHUNK_BYTES ||
        (size_t)n != 4 + HEADER_BYTES + OS_PARAM_BYTES
                      + count * CHUNK_BYTES ||
        !iso_bytes || iso_bytes % 2048)
        die("invalid original chunk array bounds");
    os = p + HEADER_BYTES;
    chunks = os + OS_PARAM_BYTES;
    if (memcmp(os, expected_ventoy_guid, 16)) die("original Ventoy GUID mismatch");
    for (i = 0; i < OS_PARAM_BYTES; ++i) os_sum += os[i];
    if (os_sum % 256) die("original Ventoy os_param checksum mismatch");
    disk_size = rd64(os + 33);
    part = rd16(os + 41);
    if (!part || part > 128 || rd64(os + 429) != iso_bytes)
        die("Ventoy source partition/image size mismatch");

    locate_disk(p + 24, disk_size, whole, sizeof(whole));
    src = open(whole, O_RDONLY | O_CLOEXEC);
    if (src < 0) die("cannot open identified source disk");
    read_exact(src, gpt, sizeof(gpt), 512);
    if (memcmp(gpt, "EFI PART", 8) || rd32(gpt + 84) != 128)
        die("unsupported source GPT entry size");
    read_exact(src, entry, sizeof(entry),
               (off_t)rd64(gpt + 72) * 512 + (part - 1) * 128);
    close(src);
    start_sector = rd64(entry + 32);
    partition_last = rd64(entry + 40);
    if (!start_sector || partition_last < start_sector)
        die("invalid GPT partition range");
    if (strstr(whole, "/nvme") || strstr(whole, "/mmcblk")) {
        if (snprintf(partition, sizeof(partition), "%sp%u", whole, part)
            >= (int)sizeof(partition)) die("partition pathname too long");
    } else if (snprintf(partition, sizeof(partition), "%s%u", whole, part)
               >= (int)sizeof(partition)) die("partition pathname too long");
    if (snprintf(sys_start, sizeof(sys_start),
                 "/sys/class/block/%s/start", strrchr(partition, '/') + 1)
        >= (int)sizeof(sys_start)) die("sysfs path too long");
    sys = fopen(sys_start, "r");
    if (!sys || !fgets(line, sizeof(line), sys))
        die("partition sysfs start missing");
    fclose(sys);
    if (strtoull(line, NULL, 10) != start_sector)
        die("partition sysfs disagrees with primary GPT");

    table = fopen(argv[1], "w");
    if (!table) die("cannot write Linux dm table");
    for (i = 0; i < count; ++i) {
        const uint8_t *ch = chunks + i * CHUNK_BYTES;
        uint64_t is = rd32(ch), ie = rd32(ch + 4);
        uint64_t ds = rd64(ch + 8), de = rd64(ch + 16);
        uint64_t length;
        if (is != expected || ie < is) die("gapped/overlapping image map");
        length = (ie - is + 1) * 4;
        if (de < ds || de - ds + 1 != length
            || ds < start_sector || de > partition_last)
            die("mapped sectors outside the actual source GPT partition");
        if (fprintf(table, "%" PRIu64 " %" PRIu64 " linear %s %" PRIu64 "\n",
                    is * 4, length, partition, (uint64_t)(ds - start_sector)) < 0)
            die("cannot serialize Linux dm table");
        expected = ie + 1;
    }
    if (fclose(table)) die("could not complete Linux dm table");
    if (expected != iso_bytes / 2048) die("ISO extent coverage incomplete");
    printf("VT_LINUX_MAP_CONSUMED count=%u iso_bytes=%" PRIu64
           " source=%s partition=%s\n", count, iso_bytes, whole, partition);
    fflush(stdout);
    return 0;
}
