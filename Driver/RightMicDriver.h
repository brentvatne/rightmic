/*
 * RightMicDriver.h
 * Shared definitions between the HAL driver and the RightMic companion app.
 *
 * The driver creates a virtual input device ("RightMic") backed by a POSIX
 * shared-memory ring buffer.  The companion app captures audio from the real
 * microphone and writes it into this buffer; the driver serves that audio to
 * any application (Zoom, Meet, FaceTime, etc.) that selects "RightMic" as
 * its input device.
 */

#ifndef RightMicDriver_h
#define RightMicDriver_h

#include <stdint.h>

/* ── Object IDs ───────────────────────────────────────────────── */
/* Each AudioObject managed by the plug-in gets a unique ID.     */
enum {
    kRightMicObjectID_Plugin       = 1,   /* kAudioObjectPlugInObject */
    kRightMicObjectID_Device       = 2,
    kRightMicObjectID_InputStream  = 3,
};

/* ── Audio Format ─────────────────────────────────────────────── */
#define kRightMic_SampleRate        48000.0
#define kRightMic_ChannelCount      2
#define kRightMic_BitsPerChannel    32
#define kRightMic_BytesPerFrame     (kRightMic_ChannelCount * (kRightMic_BitsPerChannel / 8))
#define kRightMic_BufferFrameSize   512

/* ── Identifiers ──────────────────────────────────────────────── */
#define kRightMic_DeviceUID         "com.rightmic.device"
#define kRightMic_ModelUID          "com.rightmic.model"
#define kRightMic_DeviceName        "RightMic"
#define kRightMic_Manufacturer      "RightMic"
#define kRightMic_BundleID          "com.rightmic.driver"

/* ── Shared Memory Ring Buffer ────────────────────────────────── */
/* Both the driver and the app mmap this file for IPC. */
#define kRightMic_SharedMemoryPath  "/tmp/com.rightmic.audio"
#define kRightMic_RingBufferFrames  16384  /* ~341 ms at 48 kHz */

/*
 * Layout of the memory-mapped region:
 *
 *   [ RightMicRingBufferHeader ][ audio data ... ]
 *
 * Audio data is kRightMic_RingBufferFrames * kRightMic_BytesPerFrame bytes
 * of interleaved Float32 samples arranged as a circular buffer.
 *
 * The companion app writes frames and advances `writeHead`.
 * The driver reads frames in DoIOOperation and advances `readHead`.
 * Both heads are frame indices (not byte offsets) that wrap via modulo.
 */
typedef struct {
    _Atomic uint64_t writeHead;    /* next frame the app will write        */
    _Atomic uint64_t readHead;     /* next frame the driver will read      */
    _Atomic uint32_t active;       /* 1 = app is actively writing audio    */
    uint32_t         sampleRate;   /* negotiated sample rate               */
    uint32_t         channels;     /* negotiated channel count             */
    uint32_t         _pad[5];      /* pad header to 64 bytes               */
} RightMicRingBufferHeader;

#define kRightMic_RingBufferDataBytes \
    (kRightMic_RingBufferFrames * kRightMic_BytesPerFrame)

#define kRightMic_SharedMemorySize \
    (sizeof(RightMicRingBufferHeader) + kRightMic_RingBufferDataBytes)

/* ── Driver Bundle ────────────────────────────────────────────── */
/* Installation path for the .driver bundle. */
#define kRightMic_DriverInstallPath \
    "/Library/Audio/Plug-Ins/HAL/RightMic.driver"

#endif /* RightMicDriver_h */
