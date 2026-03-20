/*
 * RightMicDriver.c
 *
 * CoreAudio AudioServerPlugIn driver that creates a virtual input device
 * called "RightMic".  Audio data is read from a POSIX shared-memory ring
 * buffer that the companion app writes to.
 *
 * This driver is loaded by coreaudiod and runs in its process space.
 * It must never crash, block, or leak memory.
 */

#include "RightMicDriver.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

/* ================================================================
 * Section 1 – Constants & Global State
 * ================================================================ */

#pragma mark - Constants

/* UUIDs (must match Info.plist) */
#define kRightMic_DriverFactoryUUID \
    CFUUIDGetConstantUUIDWithBytes(NULL, \
        0xF2, 0xB9, 0xC7, 0xE4, 0x6A, 0x1D, 0x4B, 0x8E, \
        0x9C, 0x3F, 0xD5, 0xE7, 0xA2, 0xB1, 0xC0, 0xD8)

static os_log_t sLog;

#define LOG_INFO(fmt, ...)  os_log_info(sLog,  "[RightMic] " fmt, ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) os_log_error(sLog, "[RightMic] " fmt, ##__VA_ARGS__)

#pragma mark - Driver State

static AudioServerPlugInHostInterface const * sHost       = NULL;
static _Atomic UInt32                          sRefCount   = 0;
static _Atomic Boolean                         sDeviceIsRunning = false;
static _Atomic UInt32                          sClientCount = 0;

/* Timestamp state */
static mach_timebase_info_data_t sTimebaseInfo;
static uint64_t sIO_StartHostTime        = 0;
static uint64_t sIO_HostTicksPerPeriod   = 0;

/* Shared memory */
static int                      sShm_FD   = -1;
static void *                   sShm_Ptr  = MAP_FAILED;
static RightMicRingBufferHeader *sRingHeader = NULL;
static float *                  sRingData   = NULL;

/* Driver-local read head (avoids needing write access to shared memory) */
static uint64_t sLocalReadHead = 0;

/* Overflow event counter — rate-limits log messages from the IO thread */
static uint64_t sOverflowCount = 0;

/* Size of the currently-mapped shared memory region */
static size_t sShm_MapSize = 0;

/* Dynamic control table (V2 shared memory, may be NULL for old-format files) */
static RightMicControlTable *sControlTable    = NULL;
static uint32_t              sLastCtrlVersion = 0;

/* Local cache of control entries (updated from main queue on version change).
 * Read by property functions without locks; updated atomically via sLocalCtrlCount. */
static uint32_t              sLocalCtrlCount  = 0;
static RightMicControlEntry  sLocalControls[kRightMic_MaxControls];

/* Value set by macOS via SetPropertyData on the STATIC mute control (objectID 4).
 * This is separate from the dynamic table so the mute works even when the
 * real device has no controls to proxy (e.g. AirPods Pro stem button). */
static _Atomic UInt32 sStaticMuteValue = 0;

/* Per-slot values set by macOS via SetPropertyData for DYNAMIC controls (objectIDs 5+).
 * ORed with the app-reported values to determine effective control state. */
static _Atomic UInt32 sDriverValues[kRightMic_MaxControls];

/* ================================================================
 * Section 2 – Forward Declarations
 * ================================================================ */

#pragma mark - Forward Declarations

/* Control table */
static void RightMic_UpdateControlCache(void);

/* IUnknown */
static HRESULT  RightMic_QueryInterface(void *, REFIID, LPVOID *);
static ULONG    RightMic_AddRef(void *);
static ULONG    RightMic_Release(void *);

/* Initialization */
static OSStatus RightMic_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus RightMic_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus RightMic_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);

/* Client Management */
static OSStatus RightMic_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus RightMic_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);

/* Configuration Change */
static OSStatus RightMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus RightMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);

/* Properties */
static Boolean  RightMic_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus RightMic_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus RightMic_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus RightMic_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus RightMic_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);

/* IO */
static OSStatus RightMic_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus RightMic_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus RightMic_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus RightMic_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus RightMic_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus RightMic_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus RightMic_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

/* ================================================================
 * Section 3 – Interface vtable & Entry Point
 * ================================================================ */

#pragma mark - Interface

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL, /* _reserved */
    RightMic_QueryInterface,
    RightMic_AddRef,
    RightMic_Release,
    RightMic_Initialize,
    RightMic_CreateDevice,
    RightMic_DestroyDevice,
    RightMic_AddDeviceClient,
    RightMic_RemoveDeviceClient,
    RightMic_PerformDeviceConfigurationChange,
    RightMic_AbortDeviceConfigurationChange,
    RightMic_HasProperty,
    RightMic_IsPropertySettable,
    RightMic_GetPropertyDataSize,
    RightMic_GetPropertyData,
    RightMic_SetPropertyData,
    RightMic_StartIO,
    RightMic_StopIO,
    RightMic_GetZeroTimeStamp,
    RightMic_WillDoIOOperation,
    RightMic_BeginIOOperation,
    RightMic_DoIOOperation,
    RightMic_EndIOOperation,
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;

/* The factory function called by CoreAudio when the plug-in is loaded. */
void *RightMic_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;

    sLog = os_log_create("com.rightmic.driver", "HAL");

    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        LOG_ERROR("Factory called with wrong type UUID");
        return NULL;
    }

    LOG_INFO("Driver factory invoked");
    atomic_store(&sRefCount, 1);
    return &gDriverInterfacePtr;
}

/* ================================================================
 * Section 4 – IUnknown Methods
 * ================================================================ */

#pragma mark - IUnknown

static HRESULT RightMic_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    CFUUIDRef cfUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean isIUnknown = CFEqual(cfUUID, IUnknownUUID);
    Boolean isPlugin   = CFEqual(cfUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(cfUUID);

    if (isIUnknown || isPlugin) {
        atomic_fetch_add(&sRefCount, 1);
        *outInterface = inDriver;
        return S_OK;
    }

    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG RightMic_AddRef(void *inDriver)
{
    (void)inDriver;
    return atomic_fetch_add(&sRefCount, 1) + 1;
}

static ULONG RightMic_Release(void *inDriver)
{
    (void)inDriver;
    UInt32 old = atomic_load(&sRefCount);
    if (old > 0) old = atomic_fetch_sub(&sRefCount, 1) - 1;
    return old;
}

/* ================================================================
 * Section 5 – Initialization
 * ================================================================ */

#pragma mark - Initialization

static OSStatus RightMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    sHost = inHost;
    mach_timebase_info(&sTimebaseInfo);
    LOG_INFO("Driver initialized");
    return kAudioHardwareNoError;
}

static OSStatus RightMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                       const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus RightMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

/* ================================================================
 * Section 6 – Client Management
 * ================================================================ */

#pragma mark - Clients

/* Helper: notify macOS that the control list (and thus owned objects) changed.
 * Called when the first client opens or the last client closes the device.
 * This makes the static mute control appear/disappear dynamically so the
 * AirPods Pro stem button only acts as mic-mute when an app (Zoom, FaceTime, …)
 * is actively using RightMic — otherwise the stem retains its normal
 * play/pause behaviour for media apps on the Mac. */
static void RightMic_NotifyControlListChanged(void)
{
    if (sHost == NULL) return;
    AudioObjectPropertyAddress addrs[2] = {
        { kAudioObjectPropertyControlList,  kAudioObjectPropertyScopeGlobal,
          kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
          kAudioObjectPropertyElementMain },
    };
    sHost->PropertiesChanged(sHost, kRightMicObjectID_Device, 2, addrs);
}

static OSStatus RightMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    UInt32 count = atomic_fetch_add(&sClientCount, 1) + 1;
    LOG_INFO("Client added (total: %u)", count);
    /* First client: mute control becomes visible so macOS can route stem-button presses */
    if (count == 1) RightMic_NotifyControlListChanged();
    return kAudioHardwareNoError;
}

static OSStatus RightMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                             const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    UInt32 old = atomic_load(&sClientCount);
    UInt32 count = (old > 0) ? (atomic_fetch_sub(&sClientCount, 1) - 1) : 0;
    LOG_INFO("Client removed (total: %u)", count);
    /* Last client gone: hide mute control so stem reverts to play/pause for media */
    if (count == 0) RightMic_NotifyControlListChanged();
    return kAudioHardwareNoError;
}

/* ================================================================
 * Section 7 – Configuration Change
 * ================================================================ */

#pragma mark - Configuration

static OSStatus RightMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                           UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus RightMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

/* ================================================================
 * Section 8 – Property Helpers
 * ================================================================ */

#pragma mark - Property Helpers

/* Helper to build a standard Float32 linear PCM AudioStreamBasicDescription. */
static AudioStreamBasicDescription RightMic_ASBD(void)
{
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = kRightMic_SampleRate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat
                           | kAudioFormatFlagsNativeEndian
                           | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket   = kRightMic_BytesPerFrame;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = kRightMic_BytesPerFrame;
    asbd.mChannelsPerFrame = kRightMic_ChannelCount;
    asbd.mBitsPerChannel   = kRightMic_BitsPerChannel;
    return asbd;
}

/* ================================================================
 * Section 9 – HasProperty
 * ================================================================ */

#pragma mark - HasProperty

static Boolean RightMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                     pid_t inClientProcessID,
                                     const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver; (void)inClientProcessID;

    switch (inObjectID) {

    /* ── Plugin ──────────────────────────────────────────────── */
    case kRightMicObjectID_Plugin:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        break;

    /* ── Device ──────────────────────────────────────────────── */
    case kRightMicObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyMute:
            return true;
        }
        break;

    /* ── Input Stream ────────────────────────────────────────── */
    case kRightMicObjectID_InputStream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        break;

    /* ── Static Mute Control (objectID 4) ───────────────────────── */
    /* Only visible when at least one client (Zoom, FaceTime, …) has the device open.
     * When no client is present the stem button reverts to play/pause on the Mac. */
    case kRightMicObjectID_MuteControl:
        if (atomic_load(&sClientCount) == 0) break;
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioBooleanControlPropertyValue:
            return true;
        }
        break;

    /* ── Dynamic Control Objects (objectIDs 5+) ─────────────────── */
    default: {
        UInt32 localCount = sLocalCtrlCount;
        if (inObjectID >= kRightMicObjectID_FirstDynControl &&
            inObjectID < kRightMicObjectID_FirstDynControl + localCount) {
            UInt32 idx = inObjectID - kRightMicObjectID_FirstDynControl;
            UInt32 cls = sLocalControls[idx].classID;
            switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyName:
                return true;
            case kAudioBooleanControlPropertyValue:
                return (cls == kAudioMuteControlClassID ||
                        cls == kAudioBooleanControlClassID);
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
                return (cls == kAudioLevelControlClassID);
            default:
                break;
            }
        }
        break;
    }
    }

    return false;
}

/* ================================================================
 * Section 10 – IsPropertySettable
 * ================================================================ */

#pragma mark - IsPropertySettable

static OSStatus RightMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                             pid_t inClientProcessID,
                                             const AudioObjectPropertyAddress *inAddress,
                                             Boolean *outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;

    if (!RightMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    /* Nearly all properties are read-only.  Settable ones: sample rate,
       buffer size, stream format, device mute, and control values. */
    switch (inObjectID) {
    case kRightMicObjectID_Device:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
            inAddress->mSelector == kAudioDevicePropertyBufferFrameSize  ||
            inAddress->mSelector == kAudioDevicePropertyMute) {
            *outIsSettable = true;
            return kAudioHardwareNoError;
        }
        break;
    case kRightMicObjectID_InputStream:
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
            *outIsSettable = true;
            return kAudioHardwareNoError;
        }
        break;
    case kRightMicObjectID_MuteControl:
        if (inAddress->mSelector == kAudioBooleanControlPropertyValue) {
            *outIsSettable = true;
            return kAudioHardwareNoError;
        }
        break;
    default: {
        UInt32 localCount = sLocalCtrlCount;
        if (inObjectID >= kRightMicObjectID_FirstDynControl &&
            inObjectID < kRightMicObjectID_FirstDynControl + localCount) {
            UInt32 idx = inObjectID - kRightMicObjectID_FirstDynControl;
            UInt32 cls = sLocalControls[idx].classID;
            if ((inAddress->mSelector == kAudioBooleanControlPropertyValue &&
                 (cls == kAudioMuteControlClassID || cls == kAudioBooleanControlClassID)) ||
                (inAddress->mSelector == kAudioLevelControlPropertyScalarValue &&
                 cls == kAudioLevelControlClassID)) {
                *outIsSettable = true;
                return kAudioHardwareNoError;
            }
        }
        break;
    }
    }

    *outIsSettable = false;
    return kAudioHardwareNoError;
}

/* ================================================================
 * Section 11 – GetPropertyDataSize
 * ================================================================ */

#pragma mark - GetPropertyDataSize

static OSStatus RightMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              UInt32 inQualifierDataSize, const void *inQualifierData,
                                              UInt32 *outDataSize)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    if (!RightMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {

    /* ── Plugin ──────────────────────────────────────────────── */
    case kRightMicObjectID_Plugin:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        break;

    /* ── Device ──────────────────────────────────────────────── */
    case kRightMicObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyBufferFrameSize:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                /* stream + static mute (4, if client present) + dynamic controls (5+) */
                UInt32 muteVisible = (atomic_load(&sClientCount) > 0) ? 1 : 0;
                *outDataSize = (1 + muteVisible + sLocalCtrlCount) * sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyIsHidden:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                *outDataSize = sizeof(AudioObjectID); /* 1 input stream */
            } else {
                *outDataSize = 0; /* no output streams */
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList: {
            /* Static mute (4, only when a client is present) + dynamic controls (5+) */
            UInt32 muteVisible = (atomic_load(&sClientCount) > 0) ? 1 : 0;
            *outDataSize = (muteVisible + sLocalCtrlCount) * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyMute:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSizeRange:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        break;

    /* ── Input Stream ────────────────────────────────────────── */
    case kRightMicObjectID_InputStream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        break;

    /* ── Static Mute Control (objectID 4) ───────────────────────── */
    case kRightMicObjectID_MuteControl:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioBooleanControlPropertyValue:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        break;

    /* ── Dynamic Control Objects (objectIDs 5+) ─────────────────── */
    default: {
        UInt32 localCount = sLocalCtrlCount;
        if (inObjectID >= kRightMicObjectID_FirstDynControl &&
            inObjectID < kRightMicObjectID_FirstDynControl + localCount) {
            UInt32 idx = inObjectID - kRightMicObjectID_FirstDynControl;
            UInt32 cls = sLocalControls[idx].classID;
            switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioBooleanControlPropertyValue:
                if (cls == kAudioMuteControlClassID || cls == kAudioBooleanControlClassID) {
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                }
                break;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
                if (cls == kAudioLevelControlClassID) {
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                }
                break;
            case kAudioLevelControlPropertyDecibelRange:
                if (cls == kAudioLevelControlClassID) {
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }
                break;
            default:
                break;
            }
        }
        break;
    }
    }

    return kAudioHardwareUnknownPropertyError;
}

/* ================================================================
 * Section 12 – GetPropertyData
 * ================================================================ */

#pragma mark - GetPropertyData

static OSStatus RightMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress,
                                          UInt32 inQualifierDataSize, const void *inQualifierData,
                                          UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    switch (inObjectID) {

    /* ── Plugin ──────────────────────────────────────────────── */
    case kRightMicObjectID_Plugin:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioPlugInClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kAudioObjectPlugInObject;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kRightMic_Manufacturer);
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kRightMicObjectID_Device;
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            CFStringRef uid = *(CFStringRef *)inQualifierData;
            *outDataSize = sizeof(AudioObjectID);
            if (CFStringCompare(uid, CFSTR(kRightMic_DeviceUID), 0) == kCFCompareEqualTo) {
                *(AudioObjectID *)outData = kRightMicObjectID_Device;
            } else {
                *(AudioObjectID *)outData = kAudioObjectUnknown;
            }
            return kAudioHardwareNoError;
        }

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR("");
            return kAudioHardwareNoError;
        }
        break;

    /* ── Device ──────────────────────────────────────────────── */
    case kRightMicObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioDeviceClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kRightMicObjectID_Plugin;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kRightMic_DeviceName);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kRightMic_Manufacturer);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kRightMic_DeviceUID);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kRightMic_ModelUID);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyTransportType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kRightMicObjectID_Device;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 1;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsRunning:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = atomic_load(&sDeviceIsRunning) ? 1 : 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            /* Allow as default input device (return 1 for input and global scope, 0 for output) */
            *(UInt32 *)outData = (inAddress->mScope != kAudioObjectPropertyScopeOutput) ? 1 : 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0; /* not a system sound device */
            return kAudioHardwareNoError;

        case kAudioDevicePropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertySafetyOffset:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *outDataSize = sizeof(AudioObjectID);
                *(AudioObjectID *)outData = kRightMicObjectID_InputStream;
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;

        case kAudioObjectPropertyControlList: {
            /* Static mute (4, only when a client is present) + dynamic controls (5+) */
            UInt32 muteVisible = (atomic_load(&sClientCount) > 0) ? 1 : 0;
            UInt32 localCount = sLocalCtrlCount;
            UInt32 total = muteVisible + localCount;
            UInt32 needed = total * sizeof(AudioObjectID);
            UInt32 toReturn = (inDataSize < needed) ? inDataSize : needed;
            *outDataSize = toReturn;
            AudioObjectID *ids = (AudioObjectID *)outData;
            UInt32 n = toReturn / sizeof(AudioObjectID);
            UInt32 idx = 0;
            if (muteVisible && idx < n) ids[idx++] = kRightMicObjectID_MuteControl;
            for (UInt32 i = 0; idx < n; i++, idx++) {
                ids[idx] = kRightMicObjectID_FirstDynControl + i;
            }
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyMute: {
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            /* Effective mute = static mute OR app-side header mute */
            UInt32 staticMuted = atomic_load_explicit(&sStaticMuteValue, memory_order_relaxed);
            UInt32 appMuted    = sRingHeader
                                 ? atomic_load_explicit(&sRingHeader->muted, memory_order_relaxed)
                                 : 0;
            *(UInt32 *)outData = (staticMuted || appMuted) ? 1 : 0;
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(Float64);
            *(Float64 *)outData = kRightMic_SampleRate;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioValueRange);
            AudioValueRange *range = (AudioValueRange *)outData;
            range->mMinimum = kRightMic_SampleRate;
            range->mMaximum = kRightMic_SampleRate;
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = kRightMic_BufferFrameSize;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyClockIsStable:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 1;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0; /* visible */
            return kAudioHardwareNoError;

        case kAudioDevicePropertyBufferFrameSize:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = kRightMic_BufferFrameSize;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyBufferFrameSizeRange: {
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioValueRange);
            AudioValueRange *range = (AudioValueRange *)outData;
            range->mMinimum = kRightMic_BufferFrameSize;
            range->mMaximum = kRightMic_BufferFrameSize;
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyOwnedObjects: {
            if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                /* Stream + static mute (4, only when client present) + dynamic controls (5+) */
                UInt32 muteVisible = (atomic_load(&sClientCount) > 0) ? 1 : 0;
                UInt32 localCount = sLocalCtrlCount;
                UInt32 total = 1 + muteVisible + localCount;
                UInt32 toReturn = (inDataSize / sizeof(AudioObjectID));
                if (toReturn > total) toReturn = total;
                *outDataSize = toReturn * sizeof(AudioObjectID);
                AudioObjectID *ids = (AudioObjectID *)outData;
                UInt32 idx = 0;
                if (idx < toReturn) ids[idx++] = kRightMicObjectID_InputStream;
                if (muteVisible && idx < toReturn) ids[idx++] = kRightMicObjectID_MuteControl;
                for (UInt32 i = 0; idx < toReturn; i++, idx++) {
                    ids[idx] = kRightMicObjectID_FirstDynControl + i;
                }
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = 2 * sizeof(UInt32);
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            return kAudioHardwareNoError;
        }
        break;

    /* ── Input Stream ────────────────────────────────────────── */
    case kRightMicObjectID_InputStream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioStreamClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kRightMicObjectID_Device;
            return kAudioHardwareNoError;

        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 1;
            return kAudioHardwareNoError;

        case kAudioStreamPropertyDirection:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 1; /* input */
            return kAudioHardwareNoError;

        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = kAudioStreamTerminalTypeMicrophone;
            return kAudioHardwareNoError;

        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 1;
            return kAudioHardwareNoError;

        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            *(UInt32 *)outData = 0;
            return kAudioHardwareNoError;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            *(AudioStreamBasicDescription *)outData = RightMic_ASBD();
            return kAudioHardwareNoError;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            AudioStreamRangedDescription *desc = (AudioStreamRangedDescription *)outData;
            desc->mFormat = RightMic_ASBD();
            desc->mSampleRateRange.mMinimum = kRightMic_SampleRate;
            desc->mSampleRateRange.mMaximum = kRightMic_SampleRate;
            return kAudioHardwareNoError;
        }
        }
        break;

    /* ── Static Mute Control (objectID 4) ───────────────────────── */
    /* Only responds when at least one client has the device open. */
    case kRightMicObjectID_MuteControl:
        if (atomic_load(&sClientCount) == 0) break;
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioBooleanControlClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID *)outData = kAudioMuteControlClassID;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = kRightMicObjectID_Device;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyName: {
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(CFStringRef);
            CFRetain(CFSTR("Mute"));
            *(CFStringRef *)outData = CFSTR("Mute");
            return kAudioHardwareNoError;
        }

        case kAudioBooleanControlPropertyValue:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            {
                UInt32 staticMuted = atomic_load_explicit(&sStaticMuteValue, memory_order_relaxed);
                UInt32 appMuted    = sRingHeader
                                     ? atomic_load_explicit(&sRingHeader->muted, memory_order_relaxed)
                                     : 0;
                *(UInt32 *)outData = (staticMuted || appMuted) ? 1 : 0;
            }
            return kAudioHardwareNoError;
        }
        break;

    /* ── Dynamic Control Objects (objectIDs 5+) ─────────────────── */
    default: {
        UInt32 localCount = sLocalCtrlCount;
        if (inObjectID >= kRightMicObjectID_FirstDynControl &&
            inObjectID < kRightMicObjectID_FirstDynControl + localCount) {
            UInt32 idx = inObjectID - kRightMicObjectID_FirstDynControl;
            UInt32 cls = sLocalControls[idx].classID;

            switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *outDataSize = sizeof(AudioClassID);
                *(AudioClassID *)outData = (cls == kAudioMuteControlClassID)
                    ? kAudioBooleanControlClassID
                    : kAudioObjectClassID;
                return kAudioHardwareNoError;

            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *outDataSize = sizeof(AudioClassID);
                *(AudioClassID *)outData = cls;
                return kAudioHardwareNoError;

            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *outDataSize = sizeof(AudioObjectID);
                *(AudioObjectID *)outData = kRightMicObjectID_Device;
                return kAudioHardwareNoError;

            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                return kAudioHardwareNoError;

            case kAudioObjectPropertyName: {
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *outDataSize = sizeof(CFStringRef);
                CFStringRef name = (cls == kAudioMuteControlClassID) ? CFSTR("Mute") : CFSTR("Level");
                CFRetain(name);
                *(CFStringRef *)outData = name;
                return kAudioHardwareNoError;
            }

            case kAudioBooleanControlPropertyValue:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                if (cls == kAudioMuteControlClassID || cls == kAudioBooleanControlClassID) {
                    *outDataSize = sizeof(UInt32);
                    UInt32 dv = atomic_load_explicit(&sDriverValues[idx], memory_order_relaxed);
                    UInt32 av = sControlTable
                                ? atomic_load_explicit(&sControlTable->entries[idx].uintValue,
                                                       memory_order_relaxed)
                                : 0;
                    *(UInt32 *)outData = (dv || av) ? 1 : 0;
                    return kAudioHardwareNoError;
                }
                break;

            case kAudioLevelControlPropertyScalarValue:
                if (cls == kAudioLevelControlClassID) {
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(Float32);
                    Float32 av = sControlTable
                                 ? atomic_load_explicit(&sControlTable->entries[idx].floatValue,
                                                        memory_order_relaxed)
                                 : 1.0f;
                    *(Float32 *)outData = av;
                    return kAudioHardwareNoError;
                }
                break;

            case kAudioLevelControlPropertyDecibelValue:
                if (cls == kAudioLevelControlClassID) {
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(Float32);
                    Float32 scalar = sControlTable
                                     ? atomic_load_explicit(&sControlTable->entries[idx].floatValue,
                                                            memory_order_relaxed)
                                     : 1.0f;
                    float minDB = sLocalControls[idx].minDB;
                    float maxDB = sLocalControls[idx].maxDB;
                    float db = minDB + scalar * (maxDB - minDB);
                    *(Float32 *)outData = db;
                    return kAudioHardwareNoError;
                }
                break;

            case kAudioLevelControlPropertyDecibelRange:
                if (cls == kAudioLevelControlClassID) {
                    if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioValueRange);
                    AudioValueRange *r = (AudioValueRange *)outData;
                    r->mMinimum = sLocalControls[idx].minDB;
                    r->mMaximum = sLocalControls[idx].maxDB;
                    return kAudioHardwareNoError;
                }
                break;

            default:
                break;
            }
        }
        break;
    }
    }

    return kAudioHardwareUnknownPropertyError;
}

/* ================================================================
 * Section 13 – SetPropertyData
 * ================================================================ */

#pragma mark - SetPropertyData

static OSStatus RightMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress,
                                          UInt32 inQualifierDataSize, const void *inQualifierData,
                                          UInt32 inDataSize, const void *inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    switch (inObjectID) {
    case kRightMicObjectID_Device:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            /* We only support one sample rate, so accept and ignore */
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            Float64 requested = *(const Float64 *)inData;
            if (requested != kRightMic_SampleRate) {
                LOG_ERROR("Unsupported sample rate: %f", requested);
                return kAudioDeviceUnsupportedFormatError;
            }
            return kAudioHardwareNoError;
        }
        if (inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
            /* Accept any requested buffer size (we always use our fixed size) */
            return kAudioHardwareNoError;
        }
        if (inAddress->mSelector == kAudioDevicePropertyMute) {
            /* Convenience property — routes to the static mute control */
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 v = *(const UInt32 *)inData;
            atomic_store_explicit(&sStaticMuteValue, v, memory_order_relaxed);
            /* Notify: static mute control value changed */
            AudioObjectPropertyAddress ctrlAddr = {
                kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            sHost->PropertiesChanged(sHost, kRightMicObjectID_MuteControl, 1, &ctrlAddr);
            /* Notify: device-level mute convenience property */
            AudioObjectPropertyAddress devMuteAddr = {
                kAudioDevicePropertyMute,
                kAudioObjectPropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            sHost->PropertiesChanged(sHost, kRightMicObjectID_Device, 1, &devMuteAddr);
            LOG_INFO("Device mute set to %u", v);
            return kAudioHardwareNoError;
        }
        break;

    case kRightMicObjectID_InputStream:
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
            /* Accept only our exact format */
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *requested = (const AudioStreamBasicDescription *)inData;
            AudioStreamBasicDescription ours = RightMic_ASBD();
            if (requested->mSampleRate != ours.mSampleRate ||
                requested->mChannelsPerFrame != ours.mChannelsPerFrame ||
                requested->mFormatID != ours.mFormatID) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return kAudioHardwareNoError;
        }
        break;

    case kRightMicObjectID_MuteControl:
        /* Static mute control — receives AirPods Pro stem button press etc. */
        if (inAddress->mSelector == kAudioBooleanControlPropertyValue) {
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 v = *(const UInt32 *)inData;
            atomic_store_explicit(&sStaticMuteValue, v, memory_order_relaxed);
            AudioObjectPropertyAddress ctrlAddr = {
                kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            sHost->PropertiesChanged(sHost, kRightMicObjectID_MuteControl, 1, &ctrlAddr);
            AudioObjectPropertyAddress devMuteAddr = {
                kAudioDevicePropertyMute,
                kAudioObjectPropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            sHost->PropertiesChanged(sHost, kRightMicObjectID_Device, 1, &devMuteAddr);
            LOG_INFO("Static mute control set to %u", v);
            return kAudioHardwareNoError;
        }
        break;

    default: {
        /* Dynamic control object */
        UInt32 localCount = sLocalCtrlCount;
        if (inObjectID >= kRightMicObjectID_FirstDynControl &&
            inObjectID < kRightMicObjectID_FirstDynControl + localCount) {
            UInt32 idx = inObjectID - kRightMicObjectID_FirstDynControl;
            UInt32 cls = sLocalControls[idx].classID;

            if (inAddress->mSelector == kAudioBooleanControlPropertyValue &&
                (cls == kAudioMuteControlClassID || cls == kAudioBooleanControlClassID)) {
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 v = *(const UInt32 *)inData;
                atomic_store_explicit(&sDriverValues[idx], v, memory_order_relaxed);
                /* Notify the control value changed */
                AudioObjectPropertyAddress ctrlAddr = {
                    kAudioBooleanControlPropertyValue,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                sHost->PropertiesChanged(sHost, inObjectID, 1, &ctrlAddr);
                /* Also notify device mute (convenience property) */
                AudioObjectPropertyAddress devMuteAddr = {
                    kAudioDevicePropertyMute,
                    kAudioObjectPropertyScopeInput,
                    kAudioObjectPropertyElementMain
                };
                sHost->PropertiesChanged(sHost, kRightMicObjectID_Device, 1, &devMuteAddr);
                LOG_INFO("Control %u (mute) set to %u", idx, v);
                return kAudioHardwareNoError;
            }

            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue &&
                cls == kAudioLevelControlClassID) {
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32 v = *(const Float32 *)inData;
                /* Write into the shared memory entry (app-side) if available */
                if (sControlTable) {
                    atomic_store_explicit(&sControlTable->entries[idx].floatValue,
                                          v, memory_order_relaxed);
                }
                AudioObjectPropertyAddress ctrlAddr = {
                    kAudioLevelControlPropertyScalarValue,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                sHost->PropertiesChanged(sHost, inObjectID, 1, &ctrlAddr);
                LOG_INFO("Control %u (level) scalar set to %.3f", idx, v);
                return kAudioHardwareNoError;
            }
        }
        break;
    }
    }

    return kAudioHardwareUnknownPropertyError;
}

/* ================================================================
 * Section 14 – Dynamic Control Cache
 * ================================================================ */

#pragma mark - Control Cache

/* Called on the main queue whenever the app bumps the control table version.
 * Copies the shared memory entries into the local cache (safe to read from
 * property functions without locks) and notifies CoreAudio of the change. */
static void RightMic_UpdateControlCache(void)
{
    if (sControlTable == NULL) {
        sLocalCtrlCount = 0;
        return;
    }

    uint32_t count = atomic_load_explicit(&sControlTable->count, memory_order_acquire);
    if (count > kRightMic_MaxControls) count = kRightMic_MaxControls;

    for (uint32_t i = 0; i < count; i++) {
        sLocalControls[i].classID    = sControlTable->entries[i].classID;
        sLocalControls[i].scope      = sControlTable->entries[i].scope;
        sLocalControls[i].element    = sControlTable->entries[i].element;
        sLocalControls[i].minDB      = sControlTable->entries[i].minDB;
        sLocalControls[i].maxDB      = sControlTable->entries[i].maxDB;
        /* Atomic reads for values that the app may update concurrently */
        sLocalControls[i].uintValue  = (uint32_t)atomic_load_explicit(
            &sControlTable->entries[i].uintValue, memory_order_relaxed);
        sLocalControls[i].floatValue = atomic_load_explicit(
            &sControlTable->entries[i].floatValue, memory_order_relaxed);
    }
    sLocalCtrlCount = count;

    LOG_INFO("Control cache updated: %u controls", count);

    if (sHost != NULL) {
        AudioObjectPropertyAddress addrs[2] = {
            { kAudioObjectPropertyControlList,
              kAudioObjectPropertyScopeGlobal,
              kAudioObjectPropertyElementMain },
            { kAudioObjectPropertyOwnedObjects,
              kAudioObjectPropertyScopeGlobal,
              kAudioObjectPropertyElementMain },
        };
        sHost->PropertiesChanged(sHost, kRightMicObjectID_Device, 2, addrs);
    }
}

/* ================================================================
 * Section 15 – Shared Memory Ring Buffer
 * ================================================================ */

#pragma mark - Shared Memory

static void RightMic_OpenSharedMemory(void)
{
    if (sShm_Ptr != MAP_FAILED) return; /* already open */

    sShm_FD = open(kRightMic_SharedMemoryPath, O_RDONLY | O_NOFOLLOW);
    if (sShm_FD < 0) {
        LOG_INFO("Shared memory file not yet created by companion app");
        return;
    }

    /* Verify the file is the expected size and is a regular file */
    struct stat st;
    if (fstat(sShm_FD, &st) != 0 || st.st_size < (off_t)kRightMic_SharedMemorySize) {
        LOG_INFO("Shared memory file too small (%lld bytes, need %lu), retrying later",
                 (long long)st.st_size, (unsigned long)kRightMic_SharedMemorySize);
        close(sShm_FD);
        sShm_FD = -1;
        return;
    }
    if (!S_ISREG(st.st_mode)) {
        LOG_ERROR("Shared memory path is not a regular file, refusing to map");
        close(sShm_FD);
        sShm_FD = -1;
        return;
    }

    /* Map V2 size if the app has already written the control table, V1 otherwise */
    bool hasControlTable = (st.st_size >= (off_t)kRightMic_SharedMemorySizeV2);
    sShm_MapSize = hasControlTable ? kRightMic_SharedMemorySizeV2 : kRightMic_SharedMemorySize;

    sShm_Ptr = mmap(NULL, sShm_MapSize, PROT_READ, MAP_SHARED, sShm_FD, 0);
    if (sShm_Ptr == MAP_FAILED) {
        LOG_ERROR("Failed to mmap shared memory file");
        close(sShm_FD);
        sShm_FD = -1;
        sShm_MapSize = 0;
        return;
    }

    sRingHeader = (RightMicRingBufferHeader *)sShm_Ptr;
    sRingData   = (float *)((uint8_t *)sShm_Ptr + sizeof(RightMicRingBufferHeader));

    if (hasControlTable) {
        sControlTable = (RightMicControlTable *)((uint8_t *)sShm_Ptr + kRightMic_ControlTableOffset);
        LOG_INFO("Shared memory mapped (V2, %zu bytes, control table present)", sShm_MapSize);
    } else {
        sControlTable = NULL;
        LOG_INFO("Shared memory mapped (V1, %zu bytes, no control table)", sShm_MapSize);
    }
}

static void RightMic_CloseSharedMemory(void)
{
    if (sShm_Ptr != MAP_FAILED) {
        munmap(sShm_Ptr, sShm_MapSize > 0 ? sShm_MapSize : kRightMic_SharedMemorySize);
        sShm_Ptr = MAP_FAILED;
        sShm_MapSize = 0;
    }
    if (sShm_FD >= 0) {
        close(sShm_FD);
        sShm_FD = -1;
    }
    sRingHeader   = NULL;
    sRingData     = NULL;
    sControlTable = NULL;
}

/* ================================================================
 * Section 15 – IO Operations
 * ================================================================ */

#pragma mark - IO Operations

static OSStatus RightMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    sIO_StartHostTime = mach_absolute_time();

    /* Compute host ticks per IO period */
    Float64 nsPerPeriod = ((Float64)kRightMic_BufferFrameSize / kRightMic_SampleRate) * 1000000000.0;
    sIO_HostTicksPerPeriod = (uint64_t)(nsPerPeriod * (Float64)sTimebaseInfo.denom / (Float64)sTimebaseInfo.numer);

    sLocalReadHead = 0;
    sOverflowCount = 0;
    RightMic_OpenSharedMemory();

    atomic_store(&sDeviceIsRunning, true);
    LOG_INFO("IO started (client %u)", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus RightMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    atomic_store(&sDeviceIsRunning, false);
    RightMic_CloseSharedMemory();
    LOG_INFO("IO stopped (client %u)", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus RightMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID,
                                           Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    uint64_t currentHostTime = mach_absolute_time();
    uint64_t ticksSinceStart = currentHostTime - sIO_StartHostTime;
    uint64_t numPeriods = ticksSinceStart / sIO_HostTicksPerPeriod;

    *outSampleTime = (Float64)(numPeriods * kRightMic_BufferFrameSize);
    *outHostTime   = sIO_StartHostTime + (numPeriods * sIO_HostTicksPerPeriod);
    *outSeed       = 1;

    return kAudioHardwareNoError;
}

static OSStatus RightMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID, UInt32 inOperationID,
                                            Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    /* We only support reading input data. */
    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
        *outWillDo        = true;
        *outWillDoInPlace = true;
        return kAudioHardwareNoError;
    default:
        *outWillDo        = false;
        *outWillDoInPlace = true;
        return kAudioHardwareNoError;
    }
}

static OSStatus RightMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus RightMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                        void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID;
    (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareNoError;
    }

    float *outBuffer = (float *)ioMainBuffer;
    UInt32 framesToFill = inIOBufferFrameSize;
    UInt32 samplesToFill = framesToFill * kRightMic_ChannelCount;

    /* Try to re-open shared memory if not yet available */
    if (sShm_Ptr == MAP_FAILED) {
        RightMic_OpenSharedMemory();
    }

    /* Check if control table version changed; dispatch cache update on main queue.
     * Done before filling the buffer so it runs every IO cycle regardless of path. */
    if (sControlTable != NULL) {
        uint32_t newVer = (uint32_t)atomic_load_explicit(&sControlTable->version, memory_order_relaxed);
        if (newVer != sLastCtrlVersion) {
            sLastCtrlVersion = newVer;
            dispatch_async(dispatch_get_main_queue(), ^{ RightMic_UpdateControlCache(); });
        }
    }

    /* Fill output buffer: copy from ring buffer if data is available, else silence */
    bool filledFromRing = false;
    if (sRingHeader != NULL && atomic_load_explicit(&sRingHeader->active, memory_order_acquire)) {
        uint64_t wHead = atomic_load_explicit(&sRingHeader->writeHead, memory_order_acquire);

        /* Sync local read head to writer on first IO or after a reset.
         * The app resets writeHead to 0 when switching devices, so if
         * writeHead is behind our read position, re-sync immediately
         * instead of waiting for it to catch up (which takes ~45s). */
        if (sLocalReadHead == 0 || wHead < sLocalReadHead) {
            if (wHead > framesToFill) {
                sLocalReadHead = wHead - framesToFill;
            } else {
                sLocalReadHead = 0;
            }
        }

        uint64_t available = wHead - sLocalReadHead;

        /* Overflow: the writer has lapped the reader due to clock drift
         * between the app's hardware sample clock and the driver's
         * mach_absolute_time-based clock.  Re-sync the read head to just
         * behind the write head so the next copy reads valid (recent)
         * data.  This trades a single ~10ms glitch for preventing
         * sustained garbled output. */
        if (available > kRightMic_RingBufferFrames) {
            sOverflowCount++;
            if (sOverflowCount == 1 || (sOverflowCount % 100) == 0) {
                LOG_INFO("Ring buffer overflow #%llu (available=%llu, ring=%d). Re-syncing read head.",
                         (unsigned long long)sOverflowCount, (unsigned long long)available, kRightMic_RingBufferFrames);
            }
            sLocalReadHead = wHead - framesToFill;
            available = framesToFill;
        }

        if (available >= framesToFill) {
            UInt32 framesRead = 0;
            while (framesRead < framesToFill) {
                uint64_t ringIndex = (sLocalReadHead + framesRead) % kRightMic_RingBufferFrames;
                UInt32 contiguous = (UInt32)(kRightMic_RingBufferFrames - ringIndex);
                UInt32 chunk = framesToFill - framesRead;
                if (chunk > contiguous) chunk = contiguous;

                memcpy(outBuffer + (framesRead * kRightMic_ChannelCount),
                       sRingData + (ringIndex * kRightMic_ChannelCount),
                       chunk * kRightMic_BytesPerFrame);
                framesRead += chunk;
            }
            sLocalReadHead += framesToFill;
            filledFromRing = true;
        }
    }

    if (!filledFromRing) {
        memset(outBuffer, 0, samplesToFill * sizeof(float));
    }

    /* Apply mute: zero the buffer if any mute source is active.
     * Sources checked in priority order:
     *   1. Static mute control (objectID 4) — AirPods Pro stem button, system mute
     *   2. App-side header mute — real device muted externally (listener → header->muted)
     *   3. Dynamic mute controls (objectIDs 5+) — proxied real device mute controls
     * Read heads are always advanced even when muted to prevent stale burst on unmute. */
    bool muted = atomic_load_explicit(&sStaticMuteValue, memory_order_relaxed) != 0;
    if (!muted && sRingHeader != NULL) {
        muted = atomic_load_explicit(&sRingHeader->muted, memory_order_relaxed) != 0;
    }
    if (!muted && sControlTable != NULL) {
        for (uint32_t i = 0; i < sLocalCtrlCount && !muted; i++) {
            if (sLocalControls[i].classID == kAudioMuteControlClassID) {
                uint32_t av = (uint32_t)atomic_load_explicit(
                    &sControlTable->entries[i].uintValue, memory_order_relaxed);
                uint32_t dv = (uint32_t)atomic_load_explicit(&sDriverValues[i], memory_order_relaxed);
                muted = (av != 0) || (dv != 0);
            }
        }
    }
    if (muted) {
        memset(outBuffer, 0, samplesToFill * sizeof(float));
    }

    return kAudioHardwareNoError;
}

static OSStatus RightMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
