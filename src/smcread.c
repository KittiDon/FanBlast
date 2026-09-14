#include "bridge.h"

#include <string.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_KEYINFO  9

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit_t;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo_t;

typedef struct {
    UInt32        key;
    SMCVers_t     vers;
    SMCPLimit_t   pLimitData;
    SMCKeyInfo_t  keyInfo;
    char          result, status, data8;
    UInt32        data32;
    unsigned char bytes[32];
} SMCKeyData_t;

static io_connect_t conn = 0;

static UInt32 str2key(const char *s) {
    UInt32 k = 0;
    for (int i = 0; i < 4; i++) k = (k << 8) | (unsigned char)(s[i] ? s[i] : ' ');
    return k;
}

static void type2str(UInt32 t, char *out) {
    out[0] = (t >> 24) & 0xff; out[1] = (t >> 16) & 0xff;
    out[2] = (t >>  8) & 0xff; out[3] =  t        & 0xff; out[4] = 0;
}

int smc_start(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == kIOReturnSuccess ? 0 : -1;
}

void smc_stop(void) {
    if (conn) { IOServiceClose(conn); conn = 0; }
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                                     in, sizeof(SMCKeyData_t), out, &outSize);
}

double smc_number(const char *key) {
    if (!conn && smc_start() != 0) return -1.0;

    SMCKeyData_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);

    in.key = str2key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return -1.0;

    UInt32 size = out.keyInfo.dataSize, type = out.keyInfo.dataType;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return -1.0;

    const unsigned char *b = out.bytes;
    char t[5]; type2str(type, t);

    // fpe2 (fan RPM on pre-2016 Macs) and flt (newer) cover the fan keys;
    // sp78 covers temperatures; ui8/ui16 cover FNum and the FS! force bitmask.
    if (!strcmp(t, "fpe2") && size == 2) return (double)((b[0] << 8) | b[1]) / 4.0;
    if (!strcmp(t, "flt ") && size == 4) { float f; memcpy(&f, b, 4); return (double)f; }
    if (!strcmp(t, "sp78") && size == 2) return (double)(signed char)b[0] + (double)b[1] / 256.0;
    if (!strcmp(t, "ui8 ") && size == 1) return (double)b[0];
    if (!strcmp(t, "ui16") && size == 2) return (double)((b[0] << 8) | b[1]);
    return -1.0;
}
