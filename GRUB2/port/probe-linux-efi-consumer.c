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

/*
 * GPT and source-extent validation happens before opening any dm table.
 * The producer's checksummed os_param / disk GUID are identity hints,
 * not authentication of UEFI variables or on-disk content.
 */
static uint32_t crc32_gpt(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    size_t i;
    unsigned bit;
    for (i = 0; i < length; ++i) {
        crc ^= bytes[i];
        for (bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1U) ? 0xedb88320U : 0U);
    }
    return ~crc;
}

static uint64_t sysfs_uint64(const char *path, const char *failure)
{
    char line[128], *end;
    unsigned long long number;
    FILE *stream = fopen(path, "r");
    if (!stream) die(failure);
    if (!fgets(line, sizeof(line), stream)) die(failure);
    if (fclose(stream) != 0) die(failure);
    errno = 0;
    number = strtoull(line, &end, 10);
    if (errno || end == line || (*end != '\n' && *end != '\0'))
        die(failure);
    return (uint64_t)number;
}

/* On-disk primary GPT geometry, CRCs and selected partition identity. */
static void verify_gpt(const char *whole, const uint8_t *guid,
                       uint64_t disk_bytes, uint16_t part,
                       uint64_t *first, uint64_t *last)
{
    uint8_t gpt[512], entries[128 * 128];
    uint8_t empty_type[16] = {0};
    uint32_t stored_crc, header_bytes, entry_count, entry_bytes;
    uint64_t sectors, first_usable, last_usable, entry_lba, entry_sectors;
    const uint8_t *entry;
    int src;

    if (disk_bytes < 128U * 512U || disk_bytes % 512U
        || disk_bytes > INT64_MAX)
        die("invalid source disk size for 512-byte GPT");
    sectors = disk_bytes / 512U;
    src = open(whole, O_RDONLY | O_CLOEXEC);
    if (src < 0) die("cannot open identified source disk");
    read_exact(src, gpt, sizeof(gpt), 512);
    header_bytes = rd32(gpt + 12);
    if (memcmp(gpt, "EFI PART", 8) || header_bytes < 92
        || header_bytes > sizeof(gpt)
        || rd64(gpt + 24) != 1 || rd64(gpt + 32) != sectors - 1
        || rd32(gpt + 20) != 0 || memcmp(gpt + 56, guid, 16))
        die("invalid primary GPT header identity or geometry");
    stored_crc = rd32(gpt + 16);
    memset(gpt + 16, 0, 4);
    if (crc32_gpt(gpt, header_bytes) != stored_crc)
        die("primary GPT header CRC mismatch");

    entry_count = rd32(gpt + 80);
    entry_bytes = rd32(gpt + 84);
    entry_lba = rd64(gpt + 72);
    first_usable = rd64(gpt + 40);
    last_usable = rd64(gpt + 48);
    /* The existing probe only understands 128 entries of 128 bytes. */
    if (entry_count != 128 || entry_bytes != 128
        || part > entry_count
        || first_usable < 2 || first_usable > last_usable
        || last_usable >= sectors - 1)
        die("unsupported GPT partition entry geometry");
    entry_sectors = (uint64_t)entry_count * entry_bytes / 512U;
    if (entry_lba < 2 || entry_lba >= sectors
        || entry_sectors > sectors - entry_lba
        || entry_lba >= first_usable
        || entry_sectors > first_usable - entry_lba)
        die("GPT entry array extends outside reserved header area");
    read_exact(src, entries, sizeof(entries), (off_t)(entry_lba * 512U));
    close(src);
    if (crc32_gpt(entries, sizeof(entries)) != rd32(gpt + 88))
        die("primary GPT partition entry CRC mismatch");

    entry = entries + (part - 1U) * 128U;
    if (!memcmp(entry, empty_type, sizeof(empty_type)))
        die("selected GPT partition entry is empty");
    *first = rd64(entry + 32);
    *last = rd64(entry + 40);
    if (*first < first_usable || *last > last_usable || *last < *first)
        die("selected GPT partition extends outside usable disk");
}

static void verify_source_partition(const char *whole, uint16_t part,
                                    uint64_t first, uint64_t last,
                                    char *partition, size_t capacity)
{
    char sys_start[300], sys_size[300];
    const char *leaf;
    if (strstr(whole, "/nvme") || strstr(whole, "/mmcblk")) {
        if (snprintf(partition, capacity, "%sp%u", whole, part)
            >= (int)capacity) die("partition pathname too long");
    } else if (snprintf(partition, capacity, "%s%u", whole, part)
               >= (int)capacity) die("partition pathname too long");
    leaf = strrchr(partition, '/');
    if (!leaf) die("partition path missing device basename");
    ++leaf;
    if (snprintf(sys_start, sizeof(sys_start), "/sys/class/block/%s/start",
                 leaf) >= (int)sizeof(sys_start)
        || snprintf(sys_size, sizeof(sys_size), "/sys/class/block/%s/size",
                    leaf) >= (int)sizeof(sys_size))
        die("partition sysfs path too long");
    if (sysfs_uint64(sys_start, "partition sysfs start missing or malformed")
        != first)
        die("partition sysfs start disagrees with primary GPT");
    if (sysfs_uint64(sys_size, "partition sysfs size missing or malformed")
        != last - first + 1U)
        die("partition sysfs size disagrees with primary GPT");
}

/* Validation has no output side effects and rejects any physical overlap. */
static void verify_extents(const uint8_t *chunks, uint32_t count,
                           uint64_t iso_bytes, uint64_t first, uint64_t last)
{
    uint64_t next = 0;
    uint32_t i, j;
    for (i = 0; i < count; ++i) {
        const uint8_t *ch = chunks + i * CHUNK_BYTES;
        uint64_t is = rd32(ch), ie = rd32(ch + 4);
        uint64_t ds = rd64(ch + 8), de = rd64(ch + 16);
        uint64_t length;
        if (is != next || ie < is || ie >= iso_bytes / 2048U)
            die("gapped/overlapping image map");
        length = (ie - is + 1U) * 4U;
        if (de < ds || ds < first || de > last
            || de - ds != length - 1U)
            die("mapped sectors outside the actual source GPT partition");
        for (j = 0; j < i; ++j) {
            const uint8_t *previous = chunks + j * CHUNK_BYTES;
            uint64_t old_start = rd64(previous + 8);
            uint64_t old_end = rd64(previous + 16);
            if (!(de < old_start || old_end < ds))
                die("overlapping physical source extents");
        }
        next = ie + 1U;
    }
    if (next != iso_bytes / 2048U)
        die("ISO extent coverage incomplete");
}

int main(int argc, char **argv)
{
    int fd;
    ssize_t n;
    const uint8_t *p, *os, *chunks;
    uint32_t count, i;
    uint64_t iso_bytes, disk_size, first, last;
    uint16_t part;
    unsigned os_sum = 0;
    char whole[256] = {0}, partition[256];
    FILE *table;
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
    verify_gpt(whole, p + 24, disk_size, part, &first, &last);
    verify_source_partition(whole, part, first, last,
                            partition, sizeof(partition));
    verify_extents(chunks, count, iso_bytes, first, last);

    /* No table exists on *any* rejected variable, GPT or extent input. */
    table = fopen(argv[1], "w");
    if (!table) die("cannot write Linux dm table");
    for (i = 0; i < count; ++i) {
        const uint8_t *ch = chunks + i * CHUNK_BYTES;
        uint64_t is = rd32(ch), ie = rd32(ch + 4);
        uint64_t ds = rd64(ch + 8);
        uint64_t length = (ie - is + 1U) * 4U;
        if (fprintf(table, "%" PRIu64 " %" PRIu64 " linear %s %" PRIu64 "\n",
                    is * 4U, length, partition, ds - first) < 0)
            die("cannot serialize Linux dm table");
    }
    if (fclose(table)) die("could not complete Linux dm table");
    printf("VT_LINUX_MAP_CONSUMED count=%u iso_bytes=%" PRIu64
           " source=%s partition=%s\n", count, iso_bytes, whole, partition);
    fflush(stdout);
    return 0;
}
