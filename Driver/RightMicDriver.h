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
/* Object 4 is a static mute control that is ALWAYS present so   */
/* macOS can route AirPods Pro stem-button presses to RightMic.  */
/* Dynamic controls proxied from the real device start at 5.     */
enum {
    kRightMicObjectID_Plugin          = 1,   /* kAudioObjectPlugInObject */
    kRightMicObjectID_Device          = 2,
    kRightMicObjectID_InputStream     = 3,
    kRightMicObjectID_MuteControl     = 4,   /* static mute, always present */
    kRightMicObjectID_FirstDynControl = 5,   /* dynamic controls from control table */
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
    _Atomic uint32_t muted;        /* 1 = app-side mute override           */
    uint32_t         _pad[8];      /* pad header to 64 bytes               */
} RightMicRingBufferHeader;

#define kRightMic_RingBufferDataBytes \
    (kRightMic_RingBufferFrames * kRightMic_BytesPerFrame)

#define kRightMic_SharedMemorySize \
    (sizeof(RightMicRingBufferHeader) + kRightMic_RingBufferDataBytes)

/* ── Dynamic Control Table ────────────────────────────────────── */
/* Appended after the ring buffer audio data.  The companion app  */
/* enumerates the real device's CoreAudio controls and writes     */
/* them here; the driver reads them and dynamically exposes the   */
/* same controls on the virtual device.                           */

#define kRightMic_MaxControls 4

/*
 * One entry per proxied control.  Boolean controls (mute) use
 * uintValue; level controls use floatValue + minDB/maxDB.
 * 28 bytes each.
 */
typedef struct {
    uint32_t         classID;      /* AudioClassID (kAudioMuteControlClassID, etc.)  */
    uint32_t         scope;        /* AudioObjectPropertyScope                        */
    uint32_t         element;      /* AudioObjectPropertyElement                      */
    _Atomic uint32_t uintValue;    /* boolean controls: 0 = unmuted, 1 = muted        */
    _Atomic float    floatValue;   /* level controls: 0.0–1.0 scalar                  */
    float            minDB;        /* level controls: minimum dB (e.g. -96.0)         */
    float            maxDB;        /* level controls: maximum dB (e.g.   0.0)         */
} RightMicControlEntry;            /* 28 bytes                                        */

/*
 * Header + 4 control slots = 128 bytes total.
 *
 * The app increments `version` after writing all control data so
 * the driver can detect changes with a single atomic read.
 */
typedef struct {
    _Atomic uint32_t  version;                           /* bumped by app on each update  */
    _Atomic uint32_t  count;                             /* number of active controls 0–4 */
    RightMicControlEntry entries[kRightMic_MaxControls]; /* 4 × 28 = 112 bytes            */
    uint32_t          _pad[2];                           /* pad to 128 bytes              */
} RightMicControlTable;            /* 128 bytes                                       */

/* The control table is stored at this byte offset within the mapped file. */
#define kRightMic_ControlTableOffset  kRightMic_SharedMemorySize
#define kRightMic_ControlTableSize    sizeof(RightMicControlTable)

/* Total size of the shared memory file including the control table. */
#define kRightMic_SharedMemorySizeV2 \
    (kRightMic_SharedMemorySize + kRightMic_ControlTableSize)

/* ── Driver Bundle ────────────────────────────────────────────── */
/* Installation path for the .driver bundle. */
#define kRightMic_DriverInstallPath \
    "/Library/Audio/Plug-Ins/HAL/RightMic.driver"

#endif /* RightMicDriver_h */
