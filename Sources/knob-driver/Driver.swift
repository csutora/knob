@preconcurrency import CoreAudio
import CAPlugIn
import Foundation
import os

// MARK: - Constants

// AudioServerPlugIn.h constants not bridged to Swift
private let kPlugInObjectID: AudioObjectID = 1  // kAudioObjectPlugInObject
private let kDeviceObjectID: AudioObjectID = 2
private let kOutputStreamObjectID: AudioObjectID = 3
private let kInputStreamObjectID: AudioObjectID = 4
private let kVolumeControlObjectID: AudioObjectID = 5
private let kMuteControlObjectID: AudioObjectID = 6

private let kAudioPlugInPropertyResourceBundle: AudioObjectPropertySelector = 0x72737263  // 'rsrc'
private let kAudioDevicePropertyZeroTimeStampPeriod: AudioObjectPropertySelector = 0x72696E67  // 'ring'
private let kAudioServerPlugInIOOperationReadInput: UInt32 = 0x72656164  // 'read'
private let kAudioServerPlugInIOOperationWriteMix: UInt32 = 0x72697465  // 'rite'

private let kDeviceUID: CFString = "com.csutora.knob.loopback" as CFString
private let kDeviceModelUID: CFString = "com.csutora.knob.loopback.model" as CFString
nonisolated(unsafe) var gDeviceName: CFString = "knob" as CFString
nonisolated(unsafe) var gDeviceNameLock = os_unfair_lock()
private let kManufacturer: CFString = "knob" as CFString
// Shared memory header layout: bytes 0-7 = write position (Int64), bytes 8-63 = reserved
/// Store a retained CFString into a HAL property output buffer.
/// Uses Unmanaged to avoid SE-0349 storeBytes restriction on non-trivial types.
private func storeCFString(_ str: CFString, into outData: UnsafeMutableRawPointer, outSize: UnsafeMutablePointer<UInt32>) {
    outData.assumingMemoryBound(to: Unmanaged<CFString>.self).pointee = Unmanaged.passRetained(str)
    outSize.pointee = UInt32(MemoryLayout<CFString>.size)
}

private let kChannelCount: UInt32 = 2
private let kBitsPerChannel: UInt32 = 32
private let kBytesPerFrame: UInt32 = kChannelCount * (kBitsPerChannel / 8)
// Custom property selectors for daemon IPC (eqMac/BGM pattern)
private let kKnobSetDeviceName: AudioObjectPropertySelector = 0x6b6e646e  // 'kndn'
private let kKnobSetAppVolumes: AudioObjectPropertySelector = 0x6b6e6176  // 'knav'
private let kKnobSetHidden: AudioObjectPropertySelector = 0x6b6e6468    // 'kndh'
private let kAudioObjectPropertyCustomPropertyInfoList: AudioObjectPropertySelector = 0x63757374  // 'cust'
private let kCustomPropertyDataTypeCFString: UInt32 = 0x63667374  // 'cfst'

// AudioServerPlugInCustomPropertyInfo is not bridged to Swift — define a compatible struct
private struct CustomPropertyInfo {
    var mSelector: AudioObjectPropertySelector
    var mPropertyDataType: UInt32
    var mQualifierDataType: UInt32
}

private let driverLog = OSLog(subsystem: "com.csutora.knob.driver", category: "driver")

private let kDefaultSampleRate: Float64 = 48000.0
private let kSupportedSampleRates: [Float64] = [44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0]
private let kRingBufferFrames = 65536
private let kDefaultBufferFrameSize: UInt32 = 512
private let kLatencyFrames: UInt32 = 0

// MARK: - Global Driver State

// nonisolated(unsafe) because these are accessed from CoreAudio's real-time thread
nonisolated(unsafe) var gHost: AudioServerPlugInHostRef?
nonisolated(unsafe) var gRefCount: UInt32 = 0
nonisolated(unsafe) var gSampleRate: Float64 = kDefaultSampleRate
nonisolated(unsafe) var gBufferFrameSize: UInt32 = kDefaultBufferFrameSize
nonisolated(unsafe) var gRingBuffer: AudioRingBuffer? = nil
nonisolated(unsafe) var gIOIsRunning: Bool = false
nonisolated(unsafe) var gIOClientCount: UInt32 = 0
nonisolated(unsafe) var gVolumeScalar: Float32 = 0.0  // daemon sets correct value on startup
nonisolated(unsafe) var gMuted: Bool = true            // daemon unmutes after syncing from hardware
nonisolated(unsafe) var gHidden: Bool = true  // Start hidden; daemon shows us when ready

// Clock state
nonisolated(unsafe) var gClockAnchorHostTime: UInt64 = 0
nonisolated(unsafe) var gClockAnchorSampleTime: Float64 = 0.0
nonisolated(unsafe) var gClockTicksPerFrame: Float64 = 0.0
nonisolated(unsafe) var gClockSeed: UInt64 = 1

// Shared memory for daemon IPC (avoids mic permission requirement)
private let kShmHeaderSize = 64  // cache-line aligned header
nonisolated(unsafe) var gShmBase: UnsafeMutableRawPointer? = nil
nonisolated(unsafe) var gShmWritePos: UnsafeMutablePointer<Int64>? = nil

// Client tracking — daemon clients only do ReadInput, not WriteMix
private let kDaemonBundleID = "com.csutora.knob"
nonisolated(unsafe) var gDaemonClientIDs: Set<UInt32> = []

// Per-app volume: clientID → bundleID (control thread only), appVolumes (from config)
private let kMaxClients = 256
nonisolated(unsafe) var gClientBundleIDs: [UInt32: String] = [:]
nonisolated(unsafe) var gAppVolumes: [String: Float] = [:]
nonisolated(unsafe) var gHasAppVolumes: Bool = false

// RT-safe per-client volume lookup (written on control thread, read on IO thread)
struct ClientVolume {
    var clientID: UInt32 = 0
    var volume: Float32 = 1.0
}
nonisolated(unsafe) var gClientVolumeLookup: UnsafeMutablePointer<ClientVolume> = {
    let p = UnsafeMutablePointer<ClientVolume>.allocate(capacity: kMaxClients)
    p.initialize(repeating: ClientVolume(), count: kMaxClients)
    return p
}()
nonisolated(unsafe) var gClientVolumeLookupCount: Int = 0
nonisolated(unsafe) var gVolumeLookupLock = os_unfair_lock()

/// Rebuild the RT-safe client volume lookup from current state.
/// Called on control thread only (AddDeviceClient, RemoveDeviceClient, SetPropertyData).
/// Uses os_unfair_lock to synchronize with the IO thread reading the lookup.
private func rebuildClientVolumeLookup() {
    var temp = [ClientVolume](repeating: ClientVolume(), count: kMaxClients)
    var count = 0
    for (clientID, bundleID) in gClientBundleIDs {
        if count >= kMaxClients { break }
        let vol = gAppVolumes[bundleID] ?? 1.0
        temp[count] = ClientVolume(clientID: clientID, volume: vol)
        if vol != 1.0 {
            os_log(.debug, log: driverLog, "rebuild: clientID=%u bundleID=%{public}s vol=%.2f", clientID, bundleID, vol)
        }
        count += 1
    }
    os_unfair_lock_lock(&gVolumeLookupLock)
    for i in 0..<count { gClientVolumeLookup[i] = temp[i] }
    gClientVolumeLookupCount = count
    gHasAppVolumes = !gAppVolumes.isEmpty
    os_unfair_lock_unlock(&gVolumeLookupLock)
    os_log(.debug, log: driverLog, "rebuildLookup: count=%d hasAppVols=%d appVolsCount=%d", count, gHasAppVolumes ? 1 : 0, gAppVolumes.count)
}

// MARK: - Interface vtable

nonisolated(unsafe) var gDriverInterface = AudioServerPlugInDriverInterface(
    _reserved: nil,
    QueryInterface: driverQueryInterface,
    AddRef: driverAddRef,
    Release: driverRelease,
    Initialize: driverInitialize,
    CreateDevice: driverCreateDevice,
    DestroyDevice: driverDestroyDevice,
    AddDeviceClient: driverAddDeviceClient,
    RemoveDeviceClient: driverRemoveDeviceClient,
    PerformDeviceConfigurationChange: driverPerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange: driverAbortDeviceConfigurationChange,
    HasProperty: driverHasProperty,
    IsPropertySettable: driverIsPropertySettable,
    GetPropertyDataSize: driverGetPropertyDataSize,
    GetPropertyData: driverGetPropertyData,
    SetPropertyData: driverSetPropertyData,
    StartIO: driverStartIO,
    StopIO: driverStopIO,
    GetZeroTimeStamp: driverGetZeroTimeStamp,
    WillDoIOOperation: driverWillDoIOOperation,
    BeginIOOperation: driverBeginIOOperation,
    DoIOOperation: driverDoIOOperation,
    EndIOOperation: driverEndIOOperation
)

nonisolated(unsafe) var gDriverRefStorage: UnsafeMutablePointer<AudioServerPlugInDriverInterface>? = nil

// MARK: - Factory Function

@_cdecl("knob_driver_create")
public func knob_driver_create(
    _ allocator: CFAllocator?,
    _ requestedTypeUUID: CFUUID
) -> UnsafeMutableRawPointer? {
    // kAudioServerPlugInTypeUUID
    let typeUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x44, 0x3A, 0xBA, 0xB8, 0xE7, 0xB3, 0x49, 0x1A,
        0xB9, 0x85, 0xBE, 0xB9, 0x18, 0x70, 0x30, 0xDB)

    guard CFEqual(requestedTypeUUID, typeUUID) else { return nil }

    gDriverRefStorage = withUnsafeMutablePointer(to: &gDriverInterface) { $0 }
    gRefCount = 1
    return UnsafeMutableRawPointer(&gDriverRefStorage)
}

// MARK: - IUnknown

private func driverQueryInterface(
    _ inDriver: UnsafeMutableRawPointer?,
    _ inUUID: REFIID,
    _ outInterface: UnsafeMutablePointer<LPVOID?>?
) -> HRESULT {
    // kAudioServerPlugInDriverInterfaceUUID
    let driverUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1,
        0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17)
    // IUnknownUUID
    let iunknownUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)

    var requestedBytes = inUUID  // REFIID is CFUUIDBytes (value type)
    var driverBytes = CFUUIDGetUUIDBytes(driverUUID)
    var iunknownBytes = CFUUIDGetUUIDBytes(iunknownUUID)

    if memcmp(&requestedBytes, &driverBytes, MemoryLayout<CFUUIDBytes>.size) == 0 ||
       memcmp(&requestedBytes, &iunknownBytes, MemoryLayout<CFUUIDBytes>.size) == 0 {
        _ = driverAddRef(inDriver)
        outInterface?.pointee = inDriver
        return HRESULT(bitPattern: 0)  // S_OK
    }

    outInterface?.pointee = nil
    return HRESULT(bitPattern: 0x80004002)  // E_NOINTERFACE
}

private func driverAddRef(_ inDriver: UnsafeMutableRawPointer?) -> ULONG {
    gRefCount += 1
    return ULONG(gRefCount)
}

private func driverRelease(_ inDriver: UnsafeMutableRawPointer?) -> ULONG {
    if gRefCount > 0 { gRefCount -= 1 }
    return ULONG(gRefCount)
}

// MARK: - Basic Operations

private func driverInitialize(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inHost: AudioServerPlugInHostRef
) -> OSStatus {
    gHost = inHost

    // Connect to knob-ipc helper to get shared memory via Mach IPC (kernel-enforced access control)
    let dataSize = kRingBufferFrames * Int(kChannelCount) * MemoryLayout<Float>.size
    let totalSize = kShmHeaderSize + dataSize
    var shmMapped = false

    let conn = xpc_connection_create_mach_service("com.csutora.knob.ipc", nil, 0)
    xpc_connection_set_event_handler(conn) { _ in }
    xpc_connection_resume(conn)

    let msg = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(msg, "request", "memory")
    let reply = xpc_connection_send_message_with_reply_sync(conn, msg)

    if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
        let port = xpc_dictionary_copy_mach_send(reply, "memory")
        if port != MACH_PORT_NULL {
            var addr: mach_vm_address_t = 0
            let mapResult = mach_vm_map(
                mach_task_self_, &addr, mach_vm_size_t(totalSize),
                0, VM_FLAGS_ANYWHERE, port, 0, 0,
                VM_PROT_READ | VM_PROT_WRITE,
                VM_PROT_READ | VM_PROT_WRITE,
                VM_INHERIT_NONE)
            mach_port_deallocate(mach_task_self_, port)
            if mapResult == KERN_SUCCESS {
                let base = UnsafeMutableRawPointer(bitPattern: UInt(addr))!
                gShmBase = base
                gShmWritePos = base.assumingMemoryBound(to: Int64.self)
                let samplesPtr = base.advanced(by: kShmHeaderSize).assumingMemoryBound(to: Float.self)
                gRingBuffer = AudioRingBuffer(externalBuffer: samplesPtr, frameCapacity: kRingBufferFrames, channelCount: Int(kChannelCount))
                shmMapped = true
                os_log(.info, log: driverLog, "shared memory mapped via Mach IPC (%d bytes)", totalSize)
            } else {
                os_log(.error, log: driverLog, "mach_vm_map failed: %d", mapResult)
            }
        }
    }
    xpc_connection_cancel(conn)

    if !shmMapped {
        os_log(.info, log: driverLog, "Mach IPC unavailable, using local ring buffer")
        gRingBuffer = AudioRingBuffer(frameCapacity: kRingBufferFrames, channelCount: Int(kChannelCount))
    }

    var tbInfo = mach_timebase_info_data_t()
    mach_timebase_info(&tbInfo)
    let nanosPerTick = Double(tbInfo.numer) / Double(tbInfo.denom)
    gClockTicksPerFrame = 1_000_000_000.0 / (gSampleRate * nanosPerTick)

    // Load device name from file if present (written by daemon in a previous session).
    // Do NOT fire PropertiesChanged during init — HAL hasn't finished setup.
    // Once running, daemon sets name via custom property 'kndn'.
    let namePath = "/tmp/knob-devicename"
    if let data = try? Data(contentsOf: URL(fileURLWithPath: namePath)),
       let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !name.isEmpty {
        os_unfair_lock_lock(&gDeviceNameLock)
        gDeviceName = name as CFString
        os_unfair_lock_unlock(&gDeviceNameLock)
    }

    return noErr
}


private func driverCreateDevice(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDescription: CFDictionary,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>,
    _ outDeviceObjectID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus {
    return kAudioHardwareUnsupportedOperationError
}

private func driverDestroyDevice(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID
) -> OSStatus {
    return kAudioHardwareUnsupportedOperationError
}

private func driverAddDeviceClient(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>
) -> OSStatus {
    let clientID = inClientInfo.pointee.mClientID

    if let bundleRef = inClientInfo.pointee.mBundleID {
        let bundleID = bundleRef.takeUnretainedValue() as String
        gClientBundleIDs[clientID] = bundleID
        os_log(.debug, log: driverLog, "AddDeviceClient: clientID=%u bundleID=%{public}s total=%d", clientID, bundleID, gClientBundleIDs.count)
    } else {
        os_log(.debug, log: driverLog, "AddDeviceClient: clientID=%u (no bundleID)", clientID)
    }

    rebuildClientVolumeLookup()
    return noErr
}

private func driverRemoveDeviceClient(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>
) -> OSStatus {
    let clientID = inClientInfo.pointee.mClientID
    os_log(.debug, log: driverLog, "RemoveDeviceClient: clientID=%u", clientID)
    gClientBundleIDs.removeValue(forKey: clientID)
    gDaemonClientIDs.remove(clientID)
    // Don't rebuild lookup here — WriteMix won't be called for removed clients,
    // so stale lookup entries are harmless. Rebuilding here would clear the lookup
    // during device switches before the new clients are added back.
    return noErr
}

private func driverPerformDeviceConfigurationChange(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inChangeAction: UInt64,
    _ inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    // Called by the HAL after IO has been stopped. Apply the new sample rate.
    // The HAL will detect the changed properties and notify listeners automatically.
    let newRate = Float64(bitPattern: inChangeAction)
    guard kSupportedSampleRates.contains(newRate) else { return noErr }

    gSampleRate = newRate
    var tbInfo = mach_timebase_info_data_t()
    mach_timebase_info(&tbInfo)
    let nanosPerTick = Double(tbInfo.numer) / Double(tbInfo.denom)
    gClockTicksPerFrame = 1_000_000_000.0 / (gSampleRate * nanosPerTick)
    gRingBuffer?.reset()
    gShmWritePos?.pointee = 0  // Reset so daemon detects the discontinuity

    return noErr
}

private func driverAbortDeviceConfigurationChange(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inChangeAction: UInt64,
    _ inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    return noErr
}

// MARK: - Property Operations

private func driverHasProperty(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientProcessID: pid_t,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>
) -> DarwinBoolean {
    let sel = inAddress.pointee.mSelector
    switch inObjectID {
    case kPlugInObjectID:
        return DarwinBoolean(plugInHasProperty(sel))
    case kDeviceObjectID:
        return DarwinBoolean(deviceHasProperty(sel, scope: inAddress.pointee.mScope))
    case kOutputStreamObjectID, kInputStreamObjectID:
        return DarwinBoolean(streamHasProperty(sel))
    case kVolumeControlObjectID:
        return DarwinBoolean(volumeControlHasProperty(sel))
    case kMuteControlObjectID:
        return DarwinBoolean(muteControlHasProperty(sel))
    default:
        return false
    }
}

private func driverIsPropertySettable(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientProcessID: pid_t,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ outIsSettable: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
    let sel = inAddress.pointee.mSelector
    switch inObjectID {
    case kDeviceObjectID:
        switch sel {
        case kAudioDevicePropertyNominalSampleRate,
             kAudioDevicePropertyPreferredChannelsForStereo,
             kKnobSetDeviceName, kKnobSetAppVolumes, kKnobSetHidden:
            outIsSettable.pointee = true
        default:
            outIsSettable.pointee = false
        }
    case kVolumeControlObjectID:
        switch sel {
        case kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue:
            outIsSettable.pointee = true
        default:
            outIsSettable.pointee = false
        }
    case kMuteControlObjectID:
        switch sel {
        case kAudioBooleanControlPropertyValue:
            outIsSettable.pointee = true
        default:
            outIsSettable.pointee = false
        }
    default:
        outIsSettable.pointee = false
    }
    return noErr
}

private func driverGetPropertyDataSize(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientProcessID: pid_t,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ outDataSize: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let sel = inAddress.pointee.mSelector
    switch inObjectID {
    case kPlugInObjectID:
        return plugInGetPropertyDataSize(sel, outSize: outDataSize)
    case kDeviceObjectID:
        return deviceGetPropertyDataSize(sel, scope: inAddress.pointee.mScope, outSize: outDataSize)
    case kOutputStreamObjectID, kInputStreamObjectID:
        return streamGetPropertyDataSize(sel, outSize: outDataSize)
    case kVolumeControlObjectID:
        return volumeControlGetPropertyDataSize(sel, outSize: outDataSize)
    case kMuteControlObjectID:
        return muteControlGetPropertyDataSize(sel, outSize: outDataSize)
    default:
        return kAudioHardwareUnknownPropertyError
    }
}

private func driverGetPropertyData(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientProcessID: pid_t,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ inDataSize: UInt32,
    _ outDataSize: UnsafeMutablePointer<UInt32>,
    _ outData: UnsafeMutableRawPointer
) -> OSStatus {
    let sel = inAddress.pointee.mSelector
    switch inObjectID {
    case kPlugInObjectID:
        return plugInGetPropertyData(sel, outSize: outDataSize, outData: outData, inDataSize: inDataSize)
    case kDeviceObjectID:
        return deviceGetPropertyData(sel, scope: inAddress.pointee.mScope, outSize: outDataSize, outData: outData, inDataSize: inDataSize)
    case kOutputStreamObjectID:
        return streamGetPropertyData(sel, streamID: kOutputStreamObjectID, isInput: false, outSize: outDataSize, outData: outData, inDataSize: inDataSize)
    case kInputStreamObjectID:
        return streamGetPropertyData(sel, streamID: kInputStreamObjectID, isInput: true, outSize: outDataSize, outData: outData, inDataSize: inDataSize)
    case kVolumeControlObjectID:
        return volumeControlGetPropertyData(sel, outSize: outDataSize, outData: outData)
    case kMuteControlObjectID:
        return muteControlGetPropertyData(sel, outSize: outDataSize, outData: outData)
    default:
        return kAudioHardwareUnknownPropertyError
    }
}

private func driverSetPropertyData(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientProcessID: pid_t,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ inDataSize: UInt32,
    _ inData: UnsafeRawPointer
) -> OSStatus {
    let sel = inAddress.pointee.mSelector
    switch inObjectID {
    case kDeviceObjectID:
        if sel == kKnobSetAppVolumes {
            // Custom property: daemon pushes per-app volume map as JSON
            let jsonRef = inData.load(as: Unmanaged<CFString>.self).takeUnretainedValue()
            let jsonStr = jsonRef as String
            if let jsonData = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Double] {
                gAppVolumes = dict.mapValues { Float($0) }
                os_log(.debug, log: driverLog, "setAppVolumes: %d entries, clientBundleIDs=%d", gAppVolumes.count, gClientBundleIDs.count)
                rebuildClientVolumeLookup()
            } else {
                os_log(.error, log: driverLog, "setAppVolumes: JSON parse failed")
            }
            return noErr
        } else if sel == kKnobSetDeviceName {
            // Custom property: daemon sets the display name
            let newNameRef = inData.load(as: Unmanaged<CFString>.self).takeUnretainedValue()
            let newName = newNameRef as String
            os_unfair_lock_lock(&gDeviceNameLock)
            let changed = (newName != gDeviceName as String)
            if changed { gDeviceName = newName as CFString }
            os_unfair_lock_unlock(&gDeviceNameLock)
            if changed, let host = gHost {
                var changedAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                _ = host.pointee.PropertiesChanged(host, kDeviceObjectID, 1, &changedAddr)
            }
            return noErr
        } else if sel == kKnobSetHidden {
            let valRef = inData.load(as: Unmanaged<CFString>.self).takeUnretainedValue()
            let newHidden = (valRef as String) != "0"
            if newHidden != gHidden {
                gHidden = newHidden
                if let host = gHost {
                    var changedAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyIsHidden,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain)
                    _ = host.pointee.PropertiesChanged(host, kDeviceObjectID, 1, &changedAddr)
                }
                os_log(.info, log: driverLog, "device hidden: %d", newHidden ? 1 : 0)
            }
            return noErr
        } else if sel == kAudioDevicePropertyNominalSampleRate {
            let newRate = inData.load(as: Float64.self)
            guard kSupportedSampleRates.contains(newRate), newRate != gSampleRate else {
                return noErr
            }
            // Don't change state here — request a config change so the HAL
            // stops IO first, then calls PerformDeviceConfigurationChange.
            // The HAL handles PropertiesChanged notifications automatically.
            DispatchQueue.global(qos: .default).async {
                guard let host = gHost else { return }
                _ = host.pointee.RequestDeviceConfigurationChange(
                    host, kDeviceObjectID, UInt64(newRate.bitPattern), nil)
            }
            return noErr
        }
    case kMuteControlObjectID:
        if sel == kAudioBooleanControlPropertyValue {
            let val = inData.load(as: UInt32.self)
            gMuted = val != 0
            var changedAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBooleanControlPropertyValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if let host = gHost { _ = host.pointee.PropertiesChanged(host, kMuteControlObjectID, 1, &changedAddr) }
            return noErr
        }
    case kVolumeControlObjectID:
        if sel == kAudioLevelControlPropertyScalarValue {
            gVolumeScalar = inData.load(as: Float32.self)
            var changedAddrs = [
                AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyScalarValue,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
                AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyDecibelValue,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            ]
            if let host = gHost { _ = host.pointee.PropertiesChanged(host, kVolumeControlObjectID,
                UInt32(changedAddrs.count), &changedAddrs) }
            return noErr
        } else if sel == kAudioLevelControlPropertyDecibelValue {
            let db = inData.load(as: Float32.self)
            gVolumeScalar = db <= -96.0 ? 0.0 : powf(10.0, db / 20.0)
            var changedAddrs = [
                AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyScalarValue,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
                AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyDecibelValue,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            ]
            if let host = gHost { _ = host.pointee.PropertiesChanged(host, kVolumeControlObjectID,
                UInt32(changedAddrs.count), &changedAddrs) }
            return noErr
        }
    default:
        break
    }
    return noErr
}

// MARK: - IO Operations

private func driverStartIO(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32
) -> OSStatus {
    if gIOClientCount == 0 {
        gRingBuffer?.reset()
        gShmWritePos?.pointee = 0  // Reset so new sample times (starting from 0) will be accepted
        gClockAnchorHostTime = mach_absolute_time()
        gClockAnchorSampleTime = 0.0
        gClockSeed += 1
        gIOIsRunning = true
    }
    gIOClientCount += 1
    return noErr
}

private func driverStopIO(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32
) -> OSStatus {
    if gIOClientCount > 0 { gIOClientCount -= 1 }
    if gIOClientCount == 0 {
        gIOIsRunning = false
    }
    return noErr
}

private func driverGetZeroTimeStamp(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ outSampleTime: UnsafeMutablePointer<Float64>,
    _ outHostTime: UnsafeMutablePointer<UInt64>,
    _ outSeed: UnsafeMutablePointer<UInt64>
) -> OSStatus {
    let currentHostTime = mach_absolute_time()
    let elapsedTicks = Double(currentHostTime - gClockAnchorHostTime)
    let elapsedFrames = elapsedTicks / gClockTicksPerFrame

    // Snap to IO buffer boundaries
    let period = Double(gBufferFrameSize)
    let completedPeriods = floor(elapsedFrames / period)
    let sampleTime = gClockAnchorSampleTime + completedPeriods * period
    let hostTime = gClockAnchorHostTime + UInt64(completedPeriods * period * gClockTicksPerFrame)

    outSampleTime.pointee = sampleTime
    outHostTime.pointee = hostTime
    outSeed.pointee = gClockSeed

    return noErr
}

private func driverWillDoIOOperation(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ inOperationID: UInt32,
    _ outWillDo: UnsafeMutablePointer<DarwinBoolean>,
    _ outWillDoInPlace: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
    switch inOperationID {
    case kAudioServerPlugInIOOperationWriteMix,
         kAudioServerPlugInIOOperationReadInput:
        outWillDo.pointee = true
        outWillDoInPlace.pointee = true
    default:
        outWillDo.pointee = false
        outWillDoInPlace.pointee = true
    }
    return noErr
}

private func driverBeginIOOperation(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
    return noErr
}

private func driverDoIOOperation(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inStreamObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>,
    _ ioMainBuffer: UnsafeMutableRawPointer?,
    _ ioSecondaryBuffer: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let buffer = ioMainBuffer, let ring = gRingBuffer else { return noErr }

    switch inOperationID {
    case kAudioServerPlugInIOOperationWriteMix:
        // Apply per-client volume before storing
        var clientVol: Float32 = 1.0
        os_unfair_lock_lock(&gVolumeLookupLock)
        if gHasAppVolumes {
            let count = gClientVolumeLookupCount
            for i in 0..<count {
                if gClientVolumeLookup[i].clientID == inClientID {
                    clientVol = gClientVolumeLookup[i].volume
                    break
                }
            }
        }
        os_unfair_lock_unlock(&gVolumeLookupLock)

        let vol = clientVol  // Device volume (gVolumeScalar) is forwarded to real hardware by daemon
        if vol != 1.0 {
            let floats = buffer.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inIOBufferFrameSize) * Int(kChannelCount)
            for i in 0..<sampleCount {
                floats[i] *= vol
            }
        }

        // Store into ring buffer at output sample time (accumulates for multiple clients)
        let writeSampleTime = Int(inIOCycleInfo.pointee.mOutputTime.mSampleTime)
        ring.store(buffer, frameCount: Int(inIOBufferFrameSize), sampleTime: writeSampleTime)

        // Ensure ring buffer writes are visible to daemon before updating write position.
        // Without this barrier on ARM64, the daemon (separate process reading shared memory)
        // could see the updated shmWritePos before the ring buffer sample stores are flushed.
        OSMemoryBarrier()

        // Update shared memory write position so daemon knows data is available
        let endSampleTime = writeSampleTime + Int(inIOBufferFrameSize)
        if let wp = gShmWritePos, Int64(endSampleTime) > wp.pointee {
            wp.pointee = Int64(endSampleTime)
        }

        // Zero the output buffer after storing — prevents audio from "playing" through the device
        memset(buffer, 0, Int(inIOBufferFrameSize) * Int(kChannelCount) * MemoryLayout<Float>.size)

    case kAudioServerPlugInIOOperationReadInput:
        // Fetch from one IO period behind — ReadInput runs before WriteMix in each cycle,
        // so we read data that WriteMix stored in the previous cycle.
        let readSampleTime = Int(inIOCycleInfo.pointee.mInputTime.mSampleTime) - Int(inIOBufferFrameSize)
        ring.fetch(buffer, frameCount: Int(inIOBufferFrameSize), sampleTime: readSampleTime)
    default:
        break
    }
    return noErr
}

private func driverEndIOOperation(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inDeviceObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
    return noErr
}

// MARK: - PlugIn Properties

private func plugInHasProperty(_ sel: AudioObjectPropertySelector) -> Bool {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
         kAudioObjectPropertyManufacturer, kAudioPlugInPropertyDeviceList,
         kAudioPlugInPropertyTranslateUIDToDevice, kAudioPlugInPropertyResourceBundle:
        return true
    default:
        return false
    }
}

private func plugInGetPropertyDataSize(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner:
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyManufacturer:
        outSize.pointee = UInt32(MemoryLayout<CFString>.size)
    case kAudioPlugInPropertyDeviceList:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioPlugInPropertyTranslateUIDToDevice:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioPlugInPropertyResourceBundle:
        outSize.pointee = UInt32(MemoryLayout<CFString>.size)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

private func plugInGetPropertyData(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>, outData: UnsafeMutableRawPointer, inDataSize: UInt32) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass:
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyClass:
        outData.storeBytes(of: kAudioPlugInClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outData.storeBytes(of: kAudioObjectUnknown, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyManufacturer:
        storeCFString(kManufacturer, into: outData, outSize: outSize)
    case kAudioPlugInPropertyDeviceList:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioPlugInPropertyTranslateUIDToDevice:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioPlugInPropertyResourceBundle:
        storeCFString("" as CFString, into: outData, outSize: outSize)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

// MARK: - Device Properties

private func deviceHasProperty(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Bool {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
         kAudioObjectPropertyName, kAudioObjectPropertyManufacturer,
         kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID,
         kAudioDevicePropertyTransportType, kAudioDevicePropertyRelatedDevices,
         kAudioDevicePropertyClockDomain, kAudioDevicePropertyDeviceIsAlive,
         kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
         kAudioDevicePropertyLatency, kAudioDevicePropertyStreams,
         kAudioObjectPropertyControlList, kAudioDevicePropertyNominalSampleRate,
         kAudioDevicePropertyAvailableNominalSampleRates,
         kAudioDevicePropertyIsHidden, kAudioDevicePropertyZeroTimeStampPeriod,
         kAudioDevicePropertyIcon, kAudioDevicePropertySafetyOffset,
         kAudioDevicePropertyPreferredChannelsForStereo,
         kAudioDevicePropertyPreferredChannelLayout,
         kKnobSetDeviceName, kKnobSetAppVolumes, kKnobSetHidden,
         kAudioObjectPropertyCustomPropertyInfoList:
        return true
    default:
        return false
    }
}

private func deviceGetPropertyDataSize(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass:
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyName, kAudioObjectPropertyManufacturer,
         kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID:
        outSize.pointee = UInt32(MemoryLayout<CFString>.size)
    case kAudioDevicePropertyTransportType, kAudioDevicePropertyClockDomain,
         kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
         kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
         kAudioDevicePropertyLatency, kAudioDevicePropertyIsHidden,
         kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertySafetyOffset:
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyRelatedDevices:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioDevicePropertyStreams:
        if scope == kAudioObjectPropertyScopeInput {
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) // 1 input stream
        } else if scope == kAudioObjectPropertyScopeOutput {
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) // 1 output stream
        } else {
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) * 2 // both
        }
    case kAudioObjectPropertyControlList:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) * 2 // volume + mute controls
    case kAudioDevicePropertyNominalSampleRate:
        outSize.pointee = UInt32(MemoryLayout<Float64>.size)
    case kAudioDevicePropertyAvailableNominalSampleRates:
        outSize.pointee = UInt32(MemoryLayout<AudioValueRange>.size) * UInt32(kSupportedSampleRates.count)
    case kAudioDevicePropertyPreferredChannelsForStereo:
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size) * 2
    case kAudioDevicePropertyPreferredChannelLayout:
        outSize.pointee = UInt32(MemoryLayout<AudioChannelLayout>.size)
    case kAudioDevicePropertyIcon:
        outSize.pointee = UInt32(MemoryLayout<CFURL>.size)
    case kKnobSetDeviceName, kKnobSetAppVolumes:
        outSize.pointee = UInt32(MemoryLayout<CFString>.size)
    case kKnobSetHidden:
        outSize.pointee = UInt32(MemoryLayout<CFString>.size)
    case kAudioObjectPropertyCustomPropertyInfoList:
        outSize.pointee = UInt32(MemoryLayout<CustomPropertyInfo>.size) * 3  // 3 custom properties
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

private func deviceGetPropertyData(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, outSize: UnsafeMutablePointer<UInt32>, outData: UnsafeMutableRawPointer, inDataSize: UInt32) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass:
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyClass:
        outData.storeBytes(of: kAudioDeviceClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outData.storeBytes(of: kPlugInObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyName:
        os_unfair_lock_lock(&gDeviceNameLock)
        let name = gDeviceName
        os_unfair_lock_unlock(&gDeviceNameLock)
        storeCFString(name, into: outData, outSize: outSize)
    case kAudioObjectPropertyManufacturer:
        storeCFString(kManufacturer, into: outData, outSize: outSize)
    case kAudioDevicePropertyDeviceUID:
        storeCFString(kDeviceUID, into: outData, outSize: outSize)
    case kAudioDevicePropertyModelUID:
        storeCFString(kDeviceModelUID, into: outData, outSize: outSize)
    case kAudioDevicePropertyTransportType:
        outData.storeBytes(of: kAudioDeviceTransportTypeVirtual, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyRelatedDevices:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioDevicePropertyClockDomain:
        outData.storeBytes(of: UInt32(0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyDeviceIsAlive:
        outData.storeBytes(of: UInt32(1), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyDeviceIsRunning:
        outData.storeBytes(of: UInt32(gIOIsRunning ? 1 : 0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        outData.storeBytes(of: UInt32(1), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        outData.storeBytes(of: UInt32(1), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyLatency:
        outData.storeBytes(of: kLatencyFrames, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyStreams:
        if scope == kAudioObjectPropertyScopeInput {
            outData.storeBytes(of: kInputStreamObjectID, as: AudioObjectID.self)
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
        } else if scope == kAudioObjectPropertyScopeOutput {
            outData.storeBytes(of: kOutputStreamObjectID, as: AudioObjectID.self)
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
        } else {
            let ids = outData.assumingMemoryBound(to: AudioObjectID.self)
            ids[0] = kOutputStreamObjectID
            ids[1] = kInputStreamObjectID
            outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) * 2
        }
    case kAudioObjectPropertyControlList:
        let controls = outData.assumingMemoryBound(to: AudioObjectID.self)
        controls[0] = kVolumeControlObjectID
        controls[1] = kMuteControlObjectID
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size) * 2
    case kAudioDevicePropertyNominalSampleRate:
        outData.storeBytes(of: gSampleRate, as: Float64.self)
        outSize.pointee = UInt32(MemoryLayout<Float64>.size)
    case kAudioDevicePropertyAvailableNominalSampleRates:
        let ranges = outData.assumingMemoryBound(to: AudioValueRange.self)
        for (i, rate) in kSupportedSampleRates.enumerated() {
            ranges[i] = AudioValueRange(mMinimum: rate, mMaximum: rate)
        }
        outSize.pointee = UInt32(MemoryLayout<AudioValueRange>.size) * UInt32(kSupportedSampleRates.count)
    case kAudioDevicePropertyIsHidden:
        outData.storeBytes(of: UInt32(gHidden ? 1 : 0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyZeroTimeStampPeriod:
        outData.storeBytes(of: gBufferFrameSize, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertySafetyOffset:
        outData.storeBytes(of: UInt32(0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioDevicePropertyPreferredChannelsForStereo:
        let chans = outData.assumingMemoryBound(to: UInt32.self)
        chans[0] = 1
        chans[1] = 2
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size) * 2
    case kAudioDevicePropertyPreferredChannelLayout:
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        outData.storeBytes(of: layout, as: AudioChannelLayout.self)
        outSize.pointee = UInt32(MemoryLayout<AudioChannelLayout>.size)
    case kAudioDevicePropertyIcon:
        outSize.pointee = 0
        return noErr
    case kKnobSetDeviceName:
        os_unfair_lock_lock(&gDeviceNameLock)
        let name = gDeviceName
        os_unfair_lock_unlock(&gDeviceNameLock)
        storeCFString(name, into: outData, outSize: outSize)
    case kKnobSetAppVolumes:
        storeCFString("" as CFString, into: outData, outSize: outSize)
    case kKnobSetHidden:
        let val = (gHidden ? "1" : "0") as CFString
        storeCFString(val, into: outData, outSize: outSize)
    case kAudioObjectPropertyCustomPropertyInfoList:
        let info = outData.assumingMemoryBound(to: CustomPropertyInfo.self)
        info[0] = CustomPropertyInfo(
            mSelector: kKnobSetDeviceName,
            mPropertyDataType: kCustomPropertyDataTypeCFString,
            mQualifierDataType: 0)
        info[1] = CustomPropertyInfo(
            mSelector: kKnobSetAppVolumes,
            mPropertyDataType: kCustomPropertyDataTypeCFString,
            mQualifierDataType: 0)
        info[2] = CustomPropertyInfo(
            mSelector: kKnobSetHidden,
            mPropertyDataType: kCustomPropertyDataTypeCFString,
            mQualifierDataType: 0)
        outSize.pointee = UInt32(MemoryLayout<CustomPropertyInfo>.size) * 3
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

// MARK: - Stream Properties

private func streamHasProperty(_ sel: AudioObjectPropertySelector) -> Bool {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
         kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
         kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
         kAudioStreamPropertyLatency, kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
        return true
    default:
        return false
    }
}

private func streamGetPropertyDataSize(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass:
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
         kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
         kAudioStreamPropertyLatency:
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
        outSize.pointee = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    case kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats:
        outSize.pointee = UInt32(MemoryLayout<AudioStreamRangedDescription>.size) * UInt32(kSupportedSampleRates.count)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

private func streamGetPropertyData(_ sel: AudioObjectPropertySelector, streamID: AudioObjectID, isInput: Bool, outSize: UnsafeMutablePointer<UInt32>, outData: UnsafeMutableRawPointer, inDataSize: UInt32) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass:
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyClass:
        outData.storeBytes(of: kAudioStreamClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioStreamPropertyIsActive:
        outData.storeBytes(of: UInt32(1), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyDirection:
        outData.storeBytes(of: UInt32(isInput ? 1 : 0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyTerminalType:
        let type: UInt32 = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker
        outData.storeBytes(of: type, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyStartingChannel:
        outData.storeBytes(of: UInt32(1), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyLatency:
        outData.storeBytes(of: UInt32(0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
        var desc = AudioStreamBasicDescription()
        desc.mSampleRate = gSampleRate
        desc.mFormatID = kAudioFormatLinearPCM
        desc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        desc.mBytesPerPacket = kBytesPerFrame
        desc.mFramesPerPacket = 1
        desc.mBytesPerFrame = kBytesPerFrame
        desc.mChannelsPerFrame = kChannelCount
        desc.mBitsPerChannel = kBitsPerChannel
        outData.storeBytes(of: desc, as: AudioStreamBasicDescription.self)
        outSize.pointee = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    case kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats:
        let ranged = outData.assumingMemoryBound(to: AudioStreamRangedDescription.self)
        for (i, rate) in kSupportedSampleRates.enumerated() {
            var desc = AudioStreamBasicDescription()
            desc.mSampleRate = rate
            desc.mFormatID = kAudioFormatLinearPCM
            desc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            desc.mBytesPerPacket = kBytesPerFrame
            desc.mFramesPerPacket = 1
            desc.mBytesPerFrame = kBytesPerFrame
            desc.mChannelsPerFrame = kChannelCount
            desc.mBitsPerChannel = kBitsPerChannel
            ranged[i] = AudioStreamRangedDescription(
                mFormat: desc,
                mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate)
            )
        }
        outSize.pointee = UInt32(MemoryLayout<AudioStreamRangedDescription>.size) * UInt32(kSupportedSampleRates.count)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

// MARK: - Volume Control Properties

private func volumeControlHasProperty(_ sel: AudioObjectPropertySelector) -> Bool {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects, kAudioControlPropertyScope,
         kAudioControlPropertyElement, kAudioLevelControlPropertyScalarValue,
         kAudioLevelControlPropertyDecibelValue, kAudioLevelControlPropertyDecibelRange:
        return true
    default:
        return false
    }
}

private func volumeControlGetPropertyDataSize(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass:
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyOwnedObjects:
        outSize.pointee = 0
    case kAudioControlPropertyScope, kAudioControlPropertyElement:
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue:
        outSize.pointee = UInt32(MemoryLayout<Float32>.size)
    case kAudioLevelControlPropertyDecibelRange:
        outSize.pointee = UInt32(MemoryLayout<AudioValueRange>.size)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

private func volumeControlGetPropertyData(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>, outData: UnsafeMutableRawPointer) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass:
        outData.storeBytes(of: kAudioLevelControlClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyClass:
        outData.storeBytes(of: kAudioVolumeControlClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyOwnedObjects:
        outSize.pointee = 0
    case kAudioControlPropertyScope:
        outData.storeBytes(of: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioControlPropertyElement:
        outData.storeBytes(of: kAudioObjectPropertyElementMain, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioLevelControlPropertyScalarValue:
        outData.storeBytes(of: gVolumeScalar, as: Float32.self)
        outSize.pointee = UInt32(MemoryLayout<Float32>.size)
    case kAudioLevelControlPropertyDecibelValue:
        let db: Float32 = gVolumeScalar <= 0 ? -96.0 : 20.0 * log10f(gVolumeScalar)
        outData.storeBytes(of: db, as: Float32.self)
        outSize.pointee = UInt32(MemoryLayout<Float32>.size)
    case kAudioLevelControlPropertyDecibelRange:
        let range = AudioValueRange(mMinimum: -96.0, mMaximum: 0.0)
        outData.storeBytes(of: range, as: AudioValueRange.self)
        outSize.pointee = UInt32(MemoryLayout<AudioValueRange>.size)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

// MARK: - Mute Control Properties

private func muteControlHasProperty(_ sel: AudioObjectPropertySelector) -> Bool {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects, kAudioControlPropertyScope,
         kAudioControlPropertyElement, kAudioBooleanControlPropertyValue:
        return true
    default:
        return false
    }
}

private func muteControlGetPropertyDataSize(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass:
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyOwnedObjects:
        outSize.pointee = 0
    case kAudioControlPropertyScope, kAudioControlPropertyElement,
         kAudioBooleanControlPropertyValue:
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}

private func muteControlGetPropertyData(_ sel: AudioObjectPropertySelector, outSize: UnsafeMutablePointer<UInt32>, outData: UnsafeMutableRawPointer) -> OSStatus {
    switch sel {
    case kAudioObjectPropertyBaseClass:
        outData.storeBytes(of: kAudioBooleanControlClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyClass:
        outData.storeBytes(of: kAudioMuteControlClassID, as: AudioClassID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioClassID>.size)
    case kAudioObjectPropertyOwner:
        outData.storeBytes(of: kDeviceObjectID, as: AudioObjectID.self)
        outSize.pointee = UInt32(MemoryLayout<AudioObjectID>.size)
    case kAudioObjectPropertyOwnedObjects:
        outSize.pointee = 0
    case kAudioControlPropertyScope:
        outData.storeBytes(of: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioControlPropertyElement:
        outData.storeBytes(of: kAudioObjectPropertyElementMain, as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    case kAudioBooleanControlPropertyValue:
        outData.storeBytes(of: UInt32(gMuted ? 1 : 0), as: UInt32.self)
        outSize.pointee = UInt32(MemoryLayout<UInt32>.size)
    default:
        return kAudioHardwareUnknownPropertyError
    }
    return noErr
}
