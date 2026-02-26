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
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
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
static UInt32                                  sRefCount   = 0;
static Boolean                                 sDeviceIsRunning = false;
static UInt32                                  sClientCount = 0;

/* Timestamp state */
static mach_timebase_info_data_t sTimebaseInfo;
static uint64_t sIO_StartHostTime        = 0;
static uint64_t sIO_HostTicksPerPeriod   = 0;

/* Shared memory */
static int                      sShm_FD   = -1;
static void *                   sShm_Ptr  = MAP_FAILED;
static RightMicRingBufferHeader *sRingHeader = NULL;
static float *                  sRingData   = NULL;

/* ================================================================
 * Section 2 – Forward Declarations
 * ================================================================ */

#pragma mark - Forward Declarations

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
    sRefCount = 1;
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
        sRefCount++;
        *outInterface = inDriver;
        return S_OK;
    }

    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG RightMic_AddRef(void *inDriver)
{
    (void)inDriver;
    return ++sRefCount;
}

static ULONG RightMic_Release(void *inDriver)
{
    (void)inDriver;
    if (sRefCount > 0) sRefCount--;
    return sRefCount;
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

static OSStatus RightMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    sClientCount++;
    LOG_INFO("Client added (total: %u)", sClientCount);
    return kAudioHardwareNoError;
}

static OSStatus RightMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                             const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    if (sClientCount > 0) sClientCount--;
    LOG_INFO("Client removed (total: %u)", sClientCount);
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
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyIsHidden:
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

    /* Nearly all properties are read-only.  The only settable one we
       advertise is the nominal sample rate (though we only support one). */
    switch (inObjectID) {
    case kRightMicObjectID_Device:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
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
    default:
        break;
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
        case kAudioObjectPropertyControlList:
            *outDataSize = 0; /* no controls */
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
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
            *(UInt32 *)outData = sDeviceIsRunning ? 1 : 0;
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *outDataSize = sizeof(UInt32);
            /* Allow as default input device */
            *(UInt32 *)outData = (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                                  inAddress->mScope == kAudioObjectPropertyScopeGlobal) ? 1 : 0;
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

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

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

    default:
        break;
    }

    return kAudioHardwareUnknownPropertyError;
}

/* ================================================================
 * Section 14 – Shared Memory Ring Buffer
 * ================================================================ */

#pragma mark - Shared Memory

static void RightMic_OpenSharedMemory(void)
{
    if (sShm_Ptr != MAP_FAILED) return; /* already open */

    sShm_FD = open(kRightMic_SharedMemoryPath, O_RDONLY);
    if (sShm_FD < 0) {
        LOG_INFO("Shared memory file not yet created by companion app");
        return;
    }

    sShm_Ptr = mmap(NULL, kRightMic_SharedMemorySize, PROT_READ, MAP_SHARED, sShm_FD, 0);
    if (sShm_Ptr == MAP_FAILED) {
        LOG_ERROR("Failed to mmap shared memory file");
        close(sShm_FD);
        sShm_FD = -1;
        return;
    }

    sRingHeader = (RightMicRingBufferHeader *)sShm_Ptr;
    sRingData   = (float *)((uint8_t *)sShm_Ptr + sizeof(RightMicRingBufferHeader));
    LOG_INFO("Shared memory mapped successfully");
}

static void RightMic_CloseSharedMemory(void)
{
    if (sShm_Ptr != MAP_FAILED) {
        munmap(sShm_Ptr, kRightMic_SharedMemorySize);
        sShm_Ptr = MAP_FAILED;
    }
    if (sShm_FD >= 0) {
        close(sShm_FD);
        sShm_FD = -1;
    }
    sRingHeader = NULL;
    sRingData   = NULL;
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

    RightMic_OpenSharedMemory();

    sDeviceIsRunning = true;
    LOG_INFO("IO started (client %u)", inClientID);
    return kAudioHardwareNoError;
}

static OSStatus RightMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    sDeviceIsRunning = false;
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

    /* Read from shared memory ring buffer if available and active */
    if (sRingHeader != NULL && atomic_load_explicit(&sRingHeader->active, memory_order_acquire)) {
        uint64_t wHead = atomic_load_explicit(&sRingHeader->writeHead, memory_order_acquire);
        uint64_t rHead = atomic_load_explicit(&sRingHeader->readHead, memory_order_relaxed);
        uint64_t available = (wHead >= rHead) ? (wHead - rHead) : 0;

        if (available >= framesToFill) {
            /* Copy frames from the ring buffer */
            UInt32 framesRead = 0;
            while (framesRead < framesToFill) {
                uint64_t ringIndex = (rHead + framesRead) % kRightMic_RingBufferFrames;
                UInt32 contiguous = (UInt32)(kRightMic_RingBufferFrames - ringIndex);
                UInt32 chunk = framesToFill - framesRead;
                if (chunk > contiguous) chunk = contiguous;

                memcpy(outBuffer + (framesRead * kRightMic_ChannelCount),
                       sRingData + (ringIndex * kRightMic_ChannelCount),
                       chunk * kRightMic_BytesPerFrame);
                framesRead += chunk;
            }

            /* Advance the read head */
            atomic_store_explicit(&sRingHeader->readHead, rHead + framesToFill, memory_order_release);
            return kAudioHardwareNoError;
        }
        /* Not enough data – fall through to silence */
    }

    /* Fill with silence */
    memset(outBuffer, 0, samplesToFill * sizeof(float));
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
