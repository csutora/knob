import Foundation
import CoreAudio
import AudioToolbox
import EQCore

// (Bridge ring buffer removed — daemon now reads directly from driver's shared memory)

// MARK: - Logging

nonisolated(unsafe) let logFile: UnsafeMutablePointer<FILE>? = fopen("/tmp/knob.log", "a")
nonisolated(unsafe) let logDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()

func log(_ message: String) {
    let ts = logDateFormatter.string(from: Date())
    let line = "[\(ts)] \(message)\n"
    fputs(line, stderr)
    if let f = logFile { fputs(line, f); fflush(f) }
}

func fourCC(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
        return "'\(String(bytes.map { Character(UnicodeScalar($0)) }))'"
    }
    return "\(status)"
}

// MARK: - Kill existing instances

do {
    let myPID = getpid()
    var killed = false

    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size: Int = 0
    sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
    let count = size / MemoryLayout<kinfo_proc>.stride
    let procs = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: count)
    defer { procs.deallocate() }
    sysctl(&mib, UInt32(mib.count), procs, &size, nil, 0)
    let actualCount = size / MemoryLayout<kinfo_proc>.stride

    for i in 0..<actualCount {
        let proc = procs[i]
        let pid = proc.kp_proc.p_pid
        if pid == myPID || pid <= 0 { continue }

        let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        if name == "knobd" {
            kill(pid, SIGTERM)
            log("killed existing knobd (pid \(pid))")
            killed = true
        }
    }

    if killed {
        usleep(500_000)
    }
}

// MARK: - Config

if !FileManager.default.fileExists(atPath: EQConstants.configDir) {
    try FileManager.default.createDirectory(atPath: EQConstants.configDir, withIntermediateDirectories: true)
}

if !FileManager.default.fileExists(atPath: EQConstants.configPath) {
    let defaultConfig = EQConfig()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(defaultConfig)
    FileManager.default.createFile(atPath: EQConstants.configPath, contents: data)
    log("created default config at \(EQConstants.configPath)")
}

nonisolated(unsafe) var config: EQConfig = {
    let data = try! Data(contentsOf: URL(fileURLWithPath: EQConstants.configPath))
    var c = try! JSONDecoder().decode(EQConfig.self, from: data)
    // Migrate: remove built-in "flat" from presets dictionary
    if c.presets["flat"] != nil && c.presets["flat"]!.bands.isEmpty {
        c.presets.removeValue(forKey: "flat")
    }
    return c
}()
log("loaded config: preset=\(config.activePreset) eq=\(config.eqEnabled ? "on" : "off")")

// MARK: - DSP state

nonisolated(unsafe) var currentSampleRate: Double = 48000.0

nonisolated(unsafe) let filterBank = UnsafeMutablePointer<FilterBank>.allocate(capacity: 1)
filterBank.initialize(to: FilterBank())

nonisolated(unsafe) var keepAlive: [Any] = []

func applyActivePreset() {
    let preset = config.activePresetValue()
    filterBank.pointee.configure(from: preset, sampleRate: currentSampleRate)
    filterBank.pointee.enabled = config.eqEnabled
    log("preset '\(config.activePreset)': \(preset.bands.count) bands, preamp=\(String(format: "%.1f", preset.preampGainDB))dB, eq=\(config.eqEnabled ? "on" : "off")")
}

func syncAppVolumesToDriver() {
    // Negative values = muted (volume stored for restore). Send 0.0 to driver for muted apps.
    let dict: [String: Double] = config.appVolumesBypassed ? [:] : config.appVolumes.mapValues { max(0.0, $0) }
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8) else { return }
    let status = setStringProperty(on: driverDeviceID, selector: 0x6b6e6176, value: json)  // 'knav'
    if status != noErr {
        log("failed to sync app volumes to driver: \(fourCC(status))")
    }
}

func reloadConfig() {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: EQConstants.configPath))
        config = try JSONDecoder().decode(EQConfig.self, from: data)
        applyActivePreset()
        syncAppVolumesToDriver()
        log("config reloaded")
    } catch {
        log("config reload failed: \(error)")
    }
}

// MARK: - Daemon State Persistence

struct DaemonState: Codable {
    var lastDeviceUID: String?
}

nonisolated(unsafe) var daemonState = DaemonState()

func loadDaemonState() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: EQConstants.statePath)),
          let state = try? JSONDecoder().decode(DaemonState.self, from: data) else { return }
    daemonState = state
}

func saveDaemonState() {
    guard let data = try? JSONEncoder().encode(daemonState) else { return }
    try? data.write(to: URL(fileURLWithPath: EQConstants.statePath))
}

// MARK: - CoreAudio Helpers

/// Set a CFString property on an audio object, avoiding temporary-pointer warnings.
func setStringProperty(on objectID: AudioObjectID, selector: AudioObjectPropertySelector, value: String) -> OSStatus {
    var cfStr = value as CFString
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    return withUnsafeMutablePointer(to: &cfStr) { ptr in
        AudioObjectSetPropertyData(objectID, &address, 0, nil,
            UInt32(MemoryLayout<CFString>.size), ptr)
    }
}

// MARK: - Audio Device Helpers

let kDriverDeviceUID = EQConstants.driverDeviceUID

func findDeviceByUID(_ uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDeviceForUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uidCF: CFString = uid as CFString
    var deviceID: AudioObjectID = kAudioObjectUnknown
    let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
        withUnsafeMutablePointer(to: &deviceID) { devPtr in
            var translation = AudioValueTranslation(
                mInputData: uidPtr,
                mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                mOutputData: devPtr,
                mOutputDataSize: UInt32(MemoryLayout<AudioObjectID>.size)
            )
            var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation
            )
        }
    }
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func getDeviceUID(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
    return cf as String
}

func getDefaultOutputDeviceID() -> AudioObjectID {
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    return deviceID
}

func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> OSStatus {
    var id = deviceID
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size), &id
    )
}

func getDeviceName(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
    guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
    return cf as String
}

func getDeviceSampleRate(_ deviceID: AudioObjectID) -> Float64 {
    var sampleRate: Float64 = 48000.0
    var size = UInt32(MemoryLayout<Float64>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
    return sampleRate
}

/// Find an output device by name.
func findDeviceByName(_ name: String) -> AudioObjectID? {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }

    for deviceID in deviceIDs {
        guard let uid = getDeviceUID(deviceID), uid != kDriverDeviceUID, !uid.hasPrefix("com.csutora.knob.") else { continue }
        guard let deviceName = getDeviceName(deviceID), deviceName == name else { continue }
        return deviceID
    }
    return nil
}

/// Find a non-driver hardware output device. Prefers the device matching `preferredUID` if available.
func findRealOutputDevice(preferredUID: String? = nil) -> AudioObjectID? {
    // Try preferred device first
    if let uid = preferredUID, uid != kDriverDeviceUID, !uid.hasPrefix("com.csutora.knob."),
       let deviceID = findDeviceByUID(uid) {
        // Verify it has output streams
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
           streamSize > 0 {
            return deviceID
        }
    }

    // Fall back to first non-driver output device
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }

    for deviceID in deviceIDs {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
              streamSize > 0 else { continue }

        guard let uid = getDeviceUID(deviceID), uid != kDriverDeviceUID else { continue }
        if uid.hasPrefix("com.csutora.knob.") { continue }

        return deviceID
    }
    return nil
}

// MARK: - Driver Device Configuration

func setDriverSampleRate(_ rate: Float64) {
    var sampleRate = rate
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectSetPropertyData(
        driverDeviceID, &address, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &sampleRate
    )
    if status != noErr {
        log("failed to set driver sample rate to \(rate): \(fourCC(status))")
    }
}

func updateDriverDeviceName() {
    guard let realName = getDeviceName(realOutputDeviceID) else { return }
    let newName = "\(realName) (knob)"

    // Set via custom CoreAudio property 'kndn' — driver handles it and fires PropertiesChanged
    let status = setStringProperty(on: driverDeviceID, selector: 0x6b6e646e, value: newName)  // 'kndn'
    if status != noErr {
        log("failed to set driver name: \(fourCC(status))")
    }

    // Also write file for knob CLI to read
    try? newName.write(toFile: "/tmp/knob-devicename", atomically: true, encoding: .utf8)
    log("driver device name → \(newName)")
}

// MARK: - Driver Device Visibility

private let kKnobSetHidden: AudioObjectPropertySelector = 0x6b6e6468  // 'kndh'

func setDriverHidden(_ hidden: Bool) {
    let status = setStringProperty(on: driverDeviceID, selector: kKnobSetHidden, value: hidden ? "1" : "0")
    if status == noErr {
        log("driver device \(hidden ? "hidden" : "shown")")
    } else {
        log("failed to set driver hidden=\(hidden): \(fourCC(status))")
    }
}

// MARK: - Volume & Mute Forwarding

nonisolated(unsafe) var isForwardingVolume = false
nonisolated(unsafe) var isForwardingMute = false
nonisolated(unsafe) var volumeListenerInstalled = false
nonisolated(unsafe) var lastMuteState: Bool = false

// After a device switch, macOS animates the driver's volume to its cached value
// over ~1 second, firing many listener events. While this is set, ALL forwarding
// is suppressed. A debounced timer clears it and syncs the correct volume.
nonisolated(unsafe) var volumeSwitchActive = false
nonisolated(unsafe) var volumeSwitchSettleItem: DispatchWorkItem? = nil

// Per-device volume state. macOS contaminates hardware volume during device switches
// (restores stale cached values during the debounce window before we can act).
// We maintain our own map so we always know the correct volume for each device.
nonisolated(unsafe) var deviceVolumeMap: [String: (volume: Float32, muted: Bool)] = [:]

// Cached control IDs (populated by installVolumeForwarder)
nonisolated(unsafe) var driverVolumeControlID: AudioObjectID = kAudioObjectUnknown
nonisolated(unsafe) var driverMuteControlID: AudioObjectID = kAudioObjectUnknown

nonisolated(unsafe) let volumeChangeListenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
    if isForwardingVolume { return noErr }
    DispatchQueue.main.async { forwardVolumeToHardware() }
    return noErr
}

nonisolated(unsafe) let muteChangeListenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
    if isForwardingMute { return noErr }
    DispatchQueue.main.async { forwardMuteToHardware() }
    return noErr
}

// MARK: Control enumeration helpers

func findControls(on deviceID: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> (volume: [AudioObjectID], mute: [AudioObjectID])
{
    var controlAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyControlList,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var controlSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &controlAddr, 0, nil, &controlSize) == noErr,
          controlSize > 0 else { return ([], []) }

    let count = Int(controlSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(deviceID, &controlAddr, 0, nil, &controlSize, &ids) == noErr else { return ([], []) }

    var volumeIDs: [AudioObjectID] = []
    var muteIDs: [AudioObjectID] = []
    var classAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyClass,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    for id in ids {
        var classID: AudioClassID = 0
        var classSize = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &classAddr, 0, nil, &classSize, &classID) == noErr else { continue }
        if classID == kAudioVolumeControlClassID { volumeIDs.append(id) }
        else if classID == kAudioMuteControlClassID { muteIDs.append(id) }
    }
    return (volumeIDs, muteIDs)
}

func setMuteOnDevice(_ deviceID: AudioObjectID, muted: Bool, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) {
    let (_, muteIDs) = findControls(on: deviceID, scope: scope)
    guard !muteIDs.isEmpty else { return }
    var val = UInt32(muted ? 1 : 0)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioBooleanControlPropertyValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    for id in muteIDs {
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }
}

func getMuteFromDevice(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool? {
    let (_, muteIDs) = findControls(on: deviceID, scope: scope)
    guard let id = muteIDs.first else { return nil }
    var val: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioBooleanControlPropertyValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
    return val != 0
}

// MARK: Volume forwarding (driver → hardware)

func forwardVolumeToHardware() {
    if isForwardingVolume { return }

    // During a device switch, macOS animates the driver's volume to its cached
    // value over ~1s. Ignore all of it — the settle timer will sync correctly.
    // Each suppressed event restarts the timer so it fires shortly after the
    // last animation step, rather than a fixed delay from the switch.
    if volumeSwitchActive {
        restartSettleTimer()
        return
    }

    // Normal operation: read driver volume, forward to hardware
    guard driverVolumeControlID != kAudioObjectUnknown else { return }

    var scalar: Float32 = 1.0
    var size = UInt32(MemoryLayout<Float32>.size)
    var scalarAddr = AudioObjectPropertyAddress(
        mSelector: kAudioLevelControlPropertyScalarValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(driverVolumeControlID, &scalarAddr, 0, nil, &size, &scalar) == noErr else { return }

    isForwardingVolume = true
    isForwardingMute = true
    defer { isForwardingVolume = false; isForwardingMute = false }

    let (hwVolumeIDs, _) = findControls(on: realOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
    for id in hwVolumeIDs {
        var vol = scalar
        AudioObjectSetPropertyData(id, &scalarAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
    }

    // Mute/unmute: volume→0 mutes, volume>0 unmutes if was muted
    if scalar <= 0.0 && !lastMuteState {
        setMuteOnDevice(realOutputDeviceID, muted: true)
        if driverMuteControlID != kAudioObjectUnknown {
            var muteVal = UInt32(1)
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBooleanControlPropertyValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(driverMuteControlID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        lastMuteState = true
    } else if scalar > 0.0 && lastMuteState {
        setMuteOnDevice(realOutputDeviceID, muted: false)
        if driverMuteControlID != kAudioObjectUnknown {
            var muteVal = UInt32(0)
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBooleanControlPropertyValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(driverMuteControlID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        lastMuteState = false
    }

    // Keep per-device volume map up to date
    if let uid = getDeviceUID(realOutputDeviceID) {
        deviceVolumeMap[uid] = (volume: scalar, muted: lastMuteState)
    }
}

// MARK: Mute forwarding (driver → hardware)

func forwardMuteToHardware() {
    if isForwardingMute { return }
    if volumeSwitchActive {
        restartSettleTimer()
        return
    }

    guard driverMuteControlID != kAudioObjectUnknown else { return }

    // Read mute from driver
    var val: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioBooleanControlPropertyValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(driverMuteControlID, &addr, 0, nil, &size, &val) == noErr else { return }

    let muted = val != 0

    isForwardingMute = true
    isForwardingVolume = true
    defer { isForwardingMute = false; isForwardingVolume = false }

    setMuteOnDevice(realOutputDeviceID, muted: muted)
    lastMuteState = muted

    // Keep per-device volume map up to date
    if let uid = getDeviceUID(realOutputDeviceID) {
        deviceVolumeMap[uid]?.muted = muted
    }
}

// MARK: Install listeners

func installVolumeForwarder() {
    guard !volumeListenerInstalled else { return }

    // Find driver controls
    let (driverVols, driverMutes) = findControls(on: driverDeviceID)
    guard let volID = driverVols.first else { return }
    driverVolumeControlID = volID
    if let muteID = driverMutes.first {
        driverMuteControlID = muteID
    }

    // Listen for volume changes on driver
    var volAddr = AudioObjectPropertyAddress(
        mSelector: kAudioLevelControlPropertyScalarValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    if AudioObjectAddPropertyListener(volID, &volAddr, volumeChangeListenerProc, nil) == noErr {
        volumeListenerInstalled = true
    }

    // Listen for mute changes on driver
    if driverMuteControlID != kAudioObjectUnknown {
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioBooleanControlPropertyValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(driverMuteControlID, &muteAddr, muteChangeListenerProc, nil)
    }
}

// MARK: Sync from hardware

/// Scan output devices and refresh the volume map from hardware.
/// Optionally skips a specific device (the one macOS just made default during
/// a debounce — its volume is contaminated).
func scanDeviceVolumes(excludeDeviceID: AudioObjectID = kAudioObjectUnknown) {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return }

    for deviceID in deviceIDs {
        if deviceID == excludeDeviceID { continue }
        guard let uid = getDeviceUID(deviceID), uid != kDriverDeviceUID, !uid.hasPrefix("com.csutora.knob.") else { continue }

        // Must have output streams
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
              streamSize > 0 else { continue }

        let (volumeIDs, _) = findControls(on: deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard let volID = volumeIDs.first else { continue }

        var vol: Float32 = 0.5
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(volID, &scalarAddr, 0, nil, &volSize, &vol) == noErr else { continue }

        let muted = getMuteFromDevice(deviceID) ?? (vol <= 0.0)
        deviceVolumeMap[uid] = (volume: vol, muted: muted)

        let name = getDeviceName(deviceID) ?? uid
        log("volume map: \(name) = \(String(format: "%.2f", vol)) muted=\(muted)")
    }
}

/// Suppress forwarding during a device switch. macOS will animate the driver's
/// volume to its cached value — we ignore all of it. Each suppressed event
/// restarts the settle timer. Once no more events arrive for 0.5s, the timer
/// syncs the correct volume from our map to both driver and hardware.
func beginVolumeSwitch() {
    volumeSwitchActive = true
    restartSettleTimer()

    if let uid = getDeviceUID(realOutputDeviceID), let saved = deviceVolumeMap[uid] {
        log("switch active: target volume=\(String(format: "%.2f", saved.volume)) muted=\(saved.muted)")
    }
}

private func restartSettleTimer() {
    volumeSwitchSettleItem?.cancel()

    let item = DispatchWorkItem {
        volumeSwitchActive = false
        syncVolumeToDriver()
        // Also write correct volume to hardware (macOS contaminated it during debounce)
        guard let uid = getDeviceUID(realOutputDeviceID),
              let saved = deviceVolumeMap[uid] else { return }
        let (hwVolumeIDs, _) = findControls(on: realOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        isForwardingVolume = true
        isForwardingMute = true
        defer { isForwardingVolume = false; isForwardingMute = false }
        for id in hwVolumeIDs {
            var vol = saved.volume
            AudioObjectSetPropertyData(id, &scalarAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
        setMuteOnDevice(realOutputDeviceID, muted: saved.muted)
        lastMuteState = saved.muted
        log("volume settled: \(String(format: "%.2f", saved.volume)) muted=\(saved.muted)")
    }
    volumeSwitchSettleItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
}

/// Set the driver's volume and mute to match the current output device.
/// Uses the per-device volume map (never reads hardware during a switch).
func syncVolumeToDriver() {
    guard let uid = getDeviceUID(realOutputDeviceID),
          let saved = deviceVolumeMap[uid] else {
        log("sync: no saved volume for \(getDeviceName(realOutputDeviceID) ?? "unknown")")
        return
    }
    let targetVolume = saved.volume
    let targetMuted = saved.muted

    isForwardingVolume = true
    isForwardingMute = true
    defer { isForwardingVolume = false; isForwardingMute = false }

    var scalarAddr = AudioObjectPropertyAddress(
        mSelector: kAudioLevelControlPropertyScalarValue,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    if driverVolumeControlID != kAudioObjectUnknown {
        var vol = targetVolume
        AudioObjectSetPropertyData(driverVolumeControlID, &scalarAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
    }

    lastMuteState = targetMuted
    if driverMuteControlID != kAudioObjectUnknown {
        var muteVal = UInt32(targetMuted ? 1 : 0)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioBooleanControlPropertyValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(driverMuteControlID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
    }

    log("synced to driver: volume=\(String(format: "%.2f", targetVolume)) muted=\(targetMuted)")
}

// MARK: - Audio Processing State

nonisolated(unsafe) var driverDeviceID: AudioObjectID = kAudioObjectUnknown
nonisolated(unsafe) var realOutputDeviceID: AudioObjectID = kAudioObjectUnknown
nonisolated(unsafe) var savedDefaultDeviceID: AudioObjectID = kAudioObjectUnknown

nonisolated(unsafe) var hardwareIOProcID: AudioDeviceIOProcID?

nonisolated(unsafe) var isSettingDefaultDevice = false
nonisolated(unsafe) var deviceChangeListenerInstalled = false

// Shared memory IPC — daemon reads audio directly from driver's ring buffer
// Memory is obtained via Mach IPC from knob-ipc helper (kernel-enforced read-only)
private let kShmHeaderSize = 64
private let kShmRingFrames = 65536
private let kShmChannelCount = 2

nonisolated(unsafe) var shmBase: UnsafeMutableRawPointer? = nil
nonisolated(unsafe) var shmWritePos: UnsafeMutablePointer<Int64>? = nil
nonisolated(unsafe) var shmSamples: UnsafeMutablePointer<Float>? = nil
nonisolated(unsafe) var shmReadPosition: Int64 = 0

func openSharedMemory() -> Bool {
    let totalSize = kShmHeaderSize + kShmRingFrames * kShmChannelCount * MemoryLayout<Float>.size

    // Connect to knob-ipc helper via Mach IPC
    let conn = xpc_connection_create_mach_service("com.csutora.knob.ipc", nil, 0)
    xpc_connection_set_event_handler(conn) { _ in }
    xpc_connection_resume(conn)

    let msg = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(msg, "request", "memory")
    let reply = xpc_connection_send_message_with_reply_sync(conn, msg)
    xpc_connection_cancel(conn)

    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
        log("shared memory: failed to connect to knob-ipc helper")
        return false
    }

    if let err = xpc_dictionary_get_string(reply, "error") {
        log("shared memory: access denied — \(String(cString: err))")
        return false
    }

    let port = xpc_dictionary_copy_mach_send(reply, "memory")
    guard port != MACH_PORT_NULL else {
        log("shared memory: no memory port in reply")
        return false
    }

    // Map shared memory as read-only (kernel-enforced)
    var addr: mach_vm_address_t = 0
    let kr = mach_vm_map(
        mach_task_self_, &addr, mach_vm_size_t(totalSize),
        0, VM_FLAGS_ANYWHERE, port, 0, 0,
        VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE)
    mach_port_deallocate(mach_task_self_, port)

    guard kr == KERN_SUCCESS else {
        log("shared memory: mach_vm_map failed: \(kr)")
        return false
    }

    let base = UnsafeMutableRawPointer(bitPattern: UInt(addr))!
    shmBase = base
    shmWritePos = base.assumingMemoryBound(to: Int64.self)
    shmSamples = base.advanced(by: kShmHeaderSize).assumingMemoryBound(to: Float.self)
    shmReadPosition = shmWritePos!.pointee
    log("shared memory mapped via Mach IPC (read-only)")
    return true
}

// MARK: - Hardware Format Detection

nonisolated(unsafe) var hwOutputIsFloat: Bool = true
nonisolated(unsafe) var hwOutputBytesPerSample: Int = 4
nonisolated(unsafe) var hwOutputBitDepth: Int = 32

func getHardwareStreamFormat() -> AudioStreamBasicDescription? {
    var streamAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(realOutputDeviceID, &streamAddr, 0, nil, &streamSize) == noErr,
          streamSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }

    var streamID: AudioObjectID = kAudioObjectUnknown
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(realOutputDeviceID, &streamAddr, 0, nil, &sz, &streamID) == noErr else { return nil }

    var formatAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(streamID, &formatAddr, 0, nil, &formatSize, &format) == noErr else { return nil }

    return format
}

func trySetHardwareFormatToFloat() -> Bool {
    var streamAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(realOutputDeviceID, &streamAddr, 0, nil, &streamSize) == noErr,
          streamSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return false }

    var streamID: AudioObjectID = kAudioObjectUnknown
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(realOutputDeviceID, &streamAddr, 0, nil, &sz, &streamID) == noErr else { return false }

    var format = AudioStreamBasicDescription()
    format.mSampleRate = currentSampleRate
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    format.mChannelsPerFrame = 2
    format.mBitsPerChannel = 32
    format.mBytesPerFrame = 8
    format.mBytesPerPacket = 8
    format.mFramesPerPacket = 1

    var formatAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(streamID, &formatAddr, 0, nil,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr
}

func setupHardwareFormat() {
    if trySetHardwareFormatToFloat() {
        hwOutputIsFloat = true
        hwOutputBytesPerSample = 4
        hwOutputBitDepth = 32
        log("hardware format: float32 (set)")
        return
    }

    if let format = getHardwareStreamFormat() {
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        hwOutputIsFloat = isFloat
        hwOutputBitDepth = Int(format.mBitsPerChannel)
        hwOutputBytesPerSample = format.mChannelsPerFrame > 0
            ? Int(format.mBytesPerFrame / format.mChannelsPerFrame) : 4
        log("hardware format: \(isFloat ? "float" : "int")\(format.mBitsPerChannel) (\(hwOutputBytesPerSample) bytes/sample)")
    } else {
        hwOutputIsFloat = true
        hwOutputBytesPerSample = 4
        hwOutputBitDepth = 32
        log("hardware format: unknown, assuming float32")
    }
}

// MARK: - Media Key Simulation (for AirPods ear detection)

nonisolated(unsafe) var mrSendCommand: (@convention(c) (UInt32, AnyObject?) -> Void)? = nil

func loadMediaRemote() {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
          let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
        log("MediaRemote: framework not available")
        return
    }
    mrSendCommand = unsafeBitCast(sym, to: (@convention(c) (UInt32, AnyObject?) -> Void).self)
    log("MediaRemote loaded")
}

func simulateMediaPlayPause() {
    guard let sendCommand = mrSendCommand else {
        log("MediaRemote: not loaded, cannot toggle play/pause")
        return
    }
    sendCommand(2, nil)  // kMRTogglePlayPause = 2
    log("sent media toggle play/pause")
}

// MARK: - Device Transport & Data Source Listener (AirPods)

func getDeviceTransportType(_ deviceID: AudioObjectID) -> UInt32 {
    var transportType: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
    return transportType
}

nonisolated(unsafe) var dataSourceListenerInstalled = false
nonisolated(unsafe) var dataSourceRealDeviceID: AudioObjectID = kAudioObjectUnknown

nonisolated(unsafe) let dataSourceListenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
    DispatchQueue.main.async { handleDataSourceChange() }
    return noErr
}

func installDataSourceListener() {
    removeDataSourceListener()

    let transportType = getDeviceTransportType(realOutputDeviceID)
    guard transportType == kAudioDeviceTransportTypeBluetooth ||
          transportType == kAudioDeviceTransportTypeBluetoothLE else { return }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(realOutputDeviceID, &address, dataSourceListenerProc, nil)
    if status == noErr {
        dataSourceListenerInstalled = true
        dataSourceRealDeviceID = realOutputDeviceID
        log("data source listener installed (Bluetooth device)")
    }
}

func removeDataSourceListener() {
    guard dataSourceListenerInstalled else { return }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(dataSourceRealDeviceID, &address, dataSourceListenerProc, nil)
    dataSourceListenerInstalled = false
    dataSourceRealDeviceID = kAudioObjectUnknown
}

nonisolated(unsafe) var dataSourceDebounceItem: DispatchWorkItem?

func handleDataSourceChange() {
    var dataSource: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(realOutputDeviceID, &addr, 0, nil, &size, &dataSource)
    log("BT data source changed: \(fourCC(OSStatus(dataSource)))")
    // macOS handles AirPods ear detection natively via Now Playing framework.
    // Intervening with simulateMediaPlayPause() causes double-toggle issues.
}

// MARK: - Device List Listener (device removal/fallback)

nonisolated(unsafe) var deviceListListenerInstalled = false

nonisolated(unsafe) let deviceListListenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
    DispatchQueue.main.async { handleDeviceListChange() }
    return noErr
}

func installDeviceListListener() {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &address, deviceListListenerProc, nil)
    if status == noErr {
        deviceListListenerInstalled = true
    }
}

func removeDeviceListListener() {
    guard deviceListListenerInstalled else { return }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &address, deviceListListenerProc, nil)
    deviceListListenerInstalled = false
}

func isDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
    return status == noErr && alive != 0
}

func handleDeviceListChange() {
    // Only act if our real output device disappeared
    guard !isDeviceAlive(realOutputDeviceID) else { return }

    let oldName = getDeviceName(realOutputDeviceID) ?? "unknown"
    log("device removed: \(oldName)")

    stopHardwareIO()
    removeDataSourceListener()

    guard let fallback = findRealOutputDevice(preferredUID: daemonState.lastDeviceUID) else {
        log("no fallback device found")
        return
    }

    realOutputDeviceID = fallback
    savedDefaultDeviceID = fallback
    daemonState.lastDeviceUID = getDeviceUID(fallback)
    saveDaemonState()
    let newName = getDeviceName(fallback) ?? "unknown"
    log("switching to fallback: \(newName)")

    updateDriverDeviceName()

    let newRate = getDeviceSampleRate(fallback)
    if newRate != currentSampleRate {
        currentSampleRate = newRate
        setDriverSampleRate(newRate)
        applyActivePreset()
        log("sample rate: \(newRate)Hz")
    }

    setupHardwareFormat()
    syncAppVolumesToDriver()
    beginVolumeSwitch()

    if let presetName = config.devicePresets[newName],
       presetName == "flat" || config.presets[presetName] != nil {
        config.activePreset = presetName
        applyActivePreset()
    }
    filterBank.pointee.resetState()

    shmReadPosition = max(0, shmWritePos?.pointee ?? 0)
    startHardwareIO()
    installDataSourceListener()
}

// MARK: - IO Management

nonisolated(unsafe) var ioScratchBuffer: UnsafeMutablePointer<Float>? = nil
nonisolated(unsafe) var hardwareIODeviceID: AudioObjectID = kAudioObjectUnknown

// IO diagnostics — logged periodically to detect underruns/drift issues
nonisolated(unsafe) var ioDiagCallbackCount: Int = 0
nonisolated(unsafe) var ioDiagUnderrunCount: Int = 0
nonisolated(unsafe) var ioDiagDriftSkipCount: Int = 0
nonisolated(unsafe) var ioDiagDriftRepeatCount: Int = 0
nonisolated(unsafe) var ioDiagHardResetCount: Int = 0

// Silence gating — stop hardware IO when no app is producing audio
nonisolated(unsafe) var wpStaleCount: Int = 0
nonisolated(unsafe) var lastSeenWritePos: Int64 = 0
nonisolated(unsafe) var isInSilenceMode = false
nonisolated(unsafe) var silencePollTimer: DispatchSourceTimer?
private let kWPStaleThreshold = 47  // ~0.5s at 48kHz/512 frames (~94 callbacks/sec)

func enterSilenceMode() {
    guard !isInSilenceMode, let procID = hardwareIOProcID else { return }
    AudioDeviceStop(hardwareIODeviceID, procID)
    isInSilenceMode = true
    log("no active audio, hardware IO paused")

    let stoppedWP = shmWritePos?.pointee ?? 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.001, repeating: 0.001, leeway: .never)  // 1ms polling
    timer.setEventHandler {
        guard isInSilenceMode else { timer.cancel(); return }
        let currentWP = shmWritePos?.pointee ?? 0
        if currentWP != stoppedWP {
            // shmWritePos advanced — an app started IO
            exitSilenceMode()
            timer.cancel()
        }
    }
    timer.resume()
    silencePollTimer = timer
}

func exitSilenceMode() {
    guard isInSilenceMode, let procID = hardwareIOProcID else { return }
    isInSilenceMode = false
    wpStaleCount = 0
    lastSeenWritePos = shmWritePos?.pointee ?? 0
    shmReadPosition = max(0, (shmWritePos?.pointee ?? 0) - 1024)  // start near-live

    // For Bluetooth devices, briefly set real device as default to trigger
    // macOS's native AirPods reclaim if they were grabbed by another device.
    let transportType = getDeviceTransportType(realOutputDeviceID)
    if transportType == kAudioDeviceTransportTypeBluetooth ||
       transportType == kAudioDeviceTransportTypeBluetoothLE {
        beginVolumeSwitch()
        isSettingDefaultDevice = true
        _ = setDefaultOutputDevice(realOutputDeviceID)
        usleep(100_000)  // 100ms for macOS to process handoff
        _ = setDefaultOutputDevice(driverDeviceID)
        isSettingDefaultDevice = false
        log("BT device reclaim triggered")
    }

    AudioDeviceStart(hardwareIODeviceID, procID)
    log("audio resumed, hardware IO restarted")
}

func stopHardwareIO() {
    silencePollTimer?.cancel()
    silencePollTimer = nil
    isInSilenceMode = false
    wpStaleCount = 0
    if let procID = hardwareIOProcID {
        AudioDeviceStop(hardwareIODeviceID, procID)
        AudioDeviceDestroyIOProcID(hardwareIODeviceID, procID)
        hardwareIOProcID = nil
        hardwareIODeviceID = kAudioObjectUnknown
    }
    ioScratchBuffer?.deallocate()
    ioScratchBuffer = nil
}

func startHardwareIO() {
    guard let samples = shmSamples, let wpPtr = shmWritePos else {
        log("cannot start hardware IO — shared memory not open")
        return
    }
    let fb = filterBank
    let ringSize = kShmRingFrames
    let ch = kShmChannelCount
    let isFloat = hwOutputIsFloat
    let bytesPerSample = hwOutputBytesPerSample
    let bitDepth = hwOutputBitDepth

    // Pre-allocate scratch buffer for non-float format conversion (avoids malloc on RT thread)
    if !isFloat {
        ioScratchBuffer?.deallocate()
        let scratchSize = 4096 * ch  // 4096 frames max — more than any IO buffer
        ioScratchBuffer = .allocate(capacity: scratchSize)
    }
    let scratch = ioScratchBuffer

    // Exponential moving average of fill level for drift compensation.
    // Smooths out the ±frameCount oscillation from unsynchronized IO phases,
    // revealing only the slow clock drift (~50ppm = ~2.4 samples/sec at 48kHz).
    var avgFill: Double = 0
    var avgFillInitialized = false
    // Output silence for the first few callbacks to let the ring buffer stabilize
    // after a device switch. Prevents transient pop from stale/partial data.
    var warmupCallbacks = 4

    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(
        &procID,
        realOutputDeviceID,
        nil
    ) { _, _, _, outOutputData, _ in
        let outputABLP = UnsafeMutableAudioBufferListPointer(outOutputData)
        for buf in outputABLP {
            guard let data = buf.mData else { continue }
            let bufCh = Int(buf.mNumberChannels)
            guard bufCh > 0 else { continue }
            let frameCount = Int(buf.mDataByteSize) / (bytesPerSample * bufCh)
            guard frameCount > 0 else { continue }

            if warmupCallbacks > 0 {
                memset(data, 0, Int(buf.mDataByteSize))
                warmupCallbacks -= 1
                shmReadPosition = max(0, wpPtr.pointee)
                continue
            }

            let wp = wpPtr.pointee
            OSMemoryBarrier()  // Ensure subsequent ring buffer reads see data written before wp
            var rp = shmReadPosition
            var available = Int(wp - rp)

            // Hard reset if way off (negative or huge)
            if available < 0 || available > frameCount * 8 {
                rp = max(0, wp - Int64(frameCount * 2))
                available = Int(wp - rp)
                ioDiagHardResetCount += 1
            }

            if available < frameCount {
                memset(data, 0, Int(buf.mDataByteSize))
                shmReadPosition = max(0, wp)
                ioDiagUnderrunCount += 1
                continue
            }

            // Soft skip if too far behind
            if available > frameCount * 4 {
                rp = max(0, wp - Int64(frameCount * 2))
            }

            // Safe modulo — Swift % preserves sign, so handle negative rp
            var startFrame = Int(rp % Int64(ringSize))
            if startFrame < 0 { startFrame += ringSize }

            if isFloat && bufCh == ch {
                // Fast path: float format, matching channels — memcpy from ring buffer
                let floats = data.assumingMemoryBound(to: Float.self)
                let bytesPerFrame = ch * MemoryLayout<Float>.size
                let firstChunk = min(frameCount, ringSize - startFrame)
                memcpy(floats, samples.advanced(by: startFrame * ch), firstChunk * bytesPerFrame)
                if firstChunk < frameCount {
                    let remaining = frameCount - firstChunk
                    memcpy(floats.advanced(by: firstChunk * ch), samples, remaining * bytesPerFrame)
                }

                fb.pointee.process(buffer: floats, frameCount: frameCount, channelCount: bufCh)

            } else if !isFloat, let floatBuf = scratch {
                // Non-float: read floats from shm into scratch, apply EQ, convert to int
                let totalSamples = frameCount * bufCh
                let bytesPerFrame = ch * MemoryLayout<Float>.size

                if bufCh == ch {
                    let firstChunk = min(frameCount, ringSize - startFrame)
                    memcpy(floatBuf, samples.advanced(by: startFrame * ch), firstChunk * bytesPerFrame)
                    if firstChunk < frameCount {
                        let remaining = frameCount - firstChunk
                        memcpy(floatBuf.advanced(by: firstChunk * ch), samples, remaining * bytesPerFrame)
                    }
                } else {
                    for frame in 0..<frameCount {
                        var pos = Int((rp + Int64(frame)) % Int64(ringSize))
                        if pos < 0 { pos += ringSize }
                        let base = pos * ch
                        for c in 0..<min(bufCh, ch) {
                            floatBuf[frame * bufCh + c] = samples[base + c]
                        }
                    }
                }

                fb.pointee.process(buffer: floatBuf, frameCount: frameCount, channelCount: bufCh)

                // Convert float → integer output format
                switch bitDepth {
                case 16:
                    let out = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<totalSamples {
                        let clamped = max(-1.0, min(1.0, floatBuf[i]))
                        out[i] = Int16(clamped * 32767.0)
                    }
                case 24:
                    let out = data.assumingMemoryBound(to: Int32.self)
                    for i in 0..<totalSamples {
                        let clamped = max(-1.0, min(1.0, floatBuf[i]))
                        out[i] = Int32(clamped * 8388607.0) << 8
                    }
                case 32:
                    let out = data.assumingMemoryBound(to: Int32.self)
                    for i in 0..<totalSamples {
                        let clamped = max(-1.0, min(1.0, floatBuf[i]))
                        out[i] = Int32(clamped * 2147483647.0)
                    }
                default:
                    memset(data, 0, Int(buf.mDataByteSize))
                }

            } else {
                // Float format, channel mismatch — per-frame copy fallback
                let floats = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    var pos = Int((rp + Int64(frame)) % Int64(ringSize))
                    if pos < 0 { pos += ringSize }
                    let base = pos * ch
                    for c in 0..<min(bufCh, ch) {
                        floats[frame * bufCh + c] = samples[base + c]
                    }
                }

                fb.pointee.process(buffer: floats, frameCount: frameCount, channelCount: bufCh)
            }

            // Advance read position with filtered drift compensation.
            // The instantaneous fill oscillates ±frameCount per callback due to
            // unsynchronized IO phases. Use an exponential moving average to smooth
            // this out and only correct for actual clock drift (~50ppm).
            shmReadPosition = rp + Int64(frameCount)
            let fill = Int(wp - shmReadPosition)
            let targetFill = frameCount * 2
            if !avgFillInitialized {
                avgFill = Double(fill)
                avgFillInitialized = true
            } else {
                avgFill += (Double(fill) - avgFill) * 0.002  // ~500 callback time constant
            }
            if avgFill > Double(targetFill + frameCount) {
                shmReadPosition += 1  // falling behind — skip 1 sample
                ioDiagDriftSkipCount += 1
            } else if avgFill < Double(targetFill - frameCount), fill > 0 {
                shmReadPosition -= 1  // getting ahead — repeat 1 sample
                ioDiagDriftRepeatCount += 1
            }

            ioDiagCallbackCount += 1
            if ioDiagCallbackCount % 500 == 0 {
                // Log diagnostics every ~5 seconds (500 callbacks at ~94/sec)
                let u = ioDiagUnderrunCount
                let s = ioDiagDriftSkipCount
                let r = ioDiagDriftRepeatCount
                let h = ioDiagHardResetCount
                let f = fill
                let a = avgFill
                DispatchQueue.main.async {
                    log("IO diag: callbacks=\(ioDiagCallbackCount) underruns=\(u) skip=\(s) repeat=\(r) hardReset=\(h) fill=\(f) avgFill=\(String(format: "%.1f", a))")
                }
            }

            // Track shmWritePos staleness — detect when no app is doing IO
            let currentWP = wpPtr.pointee
            if currentWP != lastSeenWritePos {
                lastSeenWritePos = currentWP
                wpStaleCount = 0
            } else {
                wpStaleCount += 1
                if wpStaleCount >= kWPStaleThreshold {
                    wpStaleCount = 0  // prevent repeated dispatch
                    DispatchQueue.main.async { enterSilenceMode() }
                }
            }
        }
    }

    guard status == noErr, let id = procID else {
        log("hardware IO proc create failed: \(fourCC(status))")
        return
    }
    hardwareIOProcID = id
    hardwareIODeviceID = realOutputDeviceID

    let startStatus = AudioDeviceStart(realOutputDeviceID, id)
    if startStatus != noErr {
        log("hardware IO start failed: \(fourCC(startStatus))")
    } else {
        log("hardware IO started → \(getDeviceName(realOutputDeviceID) ?? "unknown")")
    }
}

// MARK: - Device Change Listener

nonisolated(unsafe) var deviceChangeWorkItem: DispatchWorkItem?

nonisolated(unsafe) let deviceChangeListenerProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
    // Debounce: cancel pending handler, wait 200ms for device changes to settle
    deviceChangeWorkItem?.cancel()
    let item = DispatchWorkItem { handleDeviceChange() }
    deviceChangeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    return noErr
}

func installDeviceChangeListener() {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceChangeListenerProc,
        nil
    )
    if status == noErr {
        deviceChangeListenerInstalled = true
    }
}

func removeDeviceChangeListener() {
    guard deviceChangeListenerInstalled else { return }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceChangeListenerProc,
        nil
    )
    deviceChangeListenerInstalled = false
}

func handleDeviceChange() {
    if isSettingDefaultDevice { return }

    let newDefault = getDefaultOutputDeviceID()
    guard newDefault != kAudioObjectUnknown else { return }
    if let uid = getDeviceUID(newDefault), uid == kDriverDeviceUID { return }

    let newName = getDeviceName(newDefault) ?? "unknown"
    log("output device changed → \(newName)")

    stopHardwareIO()
    removeDataSourceListener()

    realOutputDeviceID = newDefault
    savedDefaultDeviceID = newDefault
    daemonState.lastDeviceUID = getDeviceUID(newDefault)
    saveDaemonState()

    updateDriverDeviceName()

    let newRate = getDeviceSampleRate(newDefault)
    if newRate != currentSampleRate {
        currentSampleRate = newRate
        setDriverSampleRate(newRate)
        applyActivePreset()
        log("sample rate: \(newRate)Hz")
    }

    setupHardwareFormat()
    syncAppVolumesToDriver()

    // Suppress forwarding while macOS animates its cached volume restore on the
    // driver. The settle timer will sync the correct volume after it finishes.
    beginVolumeSwitch()

    isSettingDefaultDevice = true
    let status = setDefaultOutputDevice(driverDeviceID)
    isSettingDefaultDevice = false
    if status != noErr {
        log("failed to re-set driver as default: \(fourCC(status))")
    }

    if let presetName = config.devicePresets[newName],
       presetName == "flat" || config.presets[presetName] != nil {
        config.activePreset = presetName
        applyActivePreset()
    }
    filterBank.pointee.resetState()

    shmReadPosition = max(0, shmWritePos?.pointee ?? 0)
    startHardwareIO()
    installDataSourceListener()

    // Pick up any new devices (e.g., hot-plugged USB DAC) that aren't in the map yet.
    // Exclude realOutputDeviceID — macOS just contaminated its volume during the debounce.
    scanDeviceVolumes(excludeDeviceID: realOutputDeviceID)
}

// MARK: - Daemon startup

func startDaemon() {
    // 0. Write PID file so the driver can identify us by process ID
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
        toFile: EQConstants.pidPath, atomically: true, encoding: .utf8
    )

    // 0b. Load saved state (last device UID, etc.)
    loadDaemonState()

    // 1. Find driver device
    guard let driverID = findDeviceByUID(kDriverDeviceUID) else {
        log("driver device not found — is knob-driver.driver installed in /Library/Audio/Plug-Ins/HAL/?")
        log("install with: sudo cp -R .build/release/knob-driver.driver /Library/Audio/Plug-Ins/HAL/ && sudo launchctl kickstart -k system/com.apple.audio.coreaudiod")
        exit(1)
    }
    driverDeviceID = driverID
    log("driver device: \(driverID)")

    // 2. Determine the real output device
    let currentDefault = getDefaultOutputDeviceID()
    let currentUID = getDeviceUID(currentDefault)

    if currentUID == kDriverDeviceUID {
        // Driver is already the default (e.g., crash recovery) — find the real device
        // Try saved state first, then device name file, then any available device
        var realID: AudioObjectID? = nil
        if let uid = daemonState.lastDeviceUID {
            realID = findDeviceByUID(uid)
        }
        if realID == nil,
           let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/knob-devicename")),
           let savedName = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           savedName.hasSuffix(" (knob)") {
            let targetName = String(savedName.dropLast(7))
            realID = findDeviceByName(targetName)
        }
        if realID == nil { realID = findRealOutputDevice() }
        guard let id = realID else {
            log("no real output device found")
            exit(1)
        }
        realOutputDeviceID = id
        savedDefaultDeviceID = id
        log("recovered: real output = \(getDeviceName(id) ?? "unknown")")
    } else {
        realOutputDeviceID = currentDefault
        savedDefaultDeviceID = currentDefault
        log("real output: \(getDeviceName(currentDefault) ?? "unknown")")
    }

    // Save last device UID for future fallback/recovery
    daemonState.lastDeviceUID = getDeviceUID(realOutputDeviceID)
    saveDaemonState()

    // 2b. Scan all output devices and record their volumes.
    // This is the one safe moment — no device switching has happened yet,
    // so macOS hasn't contaminated any hardware volume controls.
    scanDeviceVolumes()

    // 3. Configure audio pipeline
    currentSampleRate = getDeviceSampleRate(realOutputDeviceID)
    setDriverSampleRate(currentSampleRate)
    applyActivePreset()
    log("sample rate: \(currentSampleRate)Hz")

    updateDriverDeviceName()
    syncAppVolumesToDriver()

    guard openSharedMemory() else {
        log("failed to open shared memory — driver may need reinstall")
        exit(1)
    }

    setupHardwareFormat()

    // 4. Suppress forwarding, set driver as default, let macOS animate its cached
    // volume, then the settle timer syncs the correct volume from our map.
    installVolumeForwarder()
    beginVolumeSwitch()

    setDriverHidden(false)
    isSettingDefaultDevice = true
    let status = setDefaultOutputDevice(driverID)
    isSettingDefaultDevice = false
    if status != noErr {
        log("failed to set driver as default output: \(fourCC(status))")
        exit(1)
    }
    log("driver set as default output")

    // 5. Start hardware IO
    startHardwareIO()

    // 6. Install remaining listeners
    loadMediaRemote()
    installDeviceChangeListener()
    installDeviceListListener()
    installDataSourceListener()

    // 7. Config file watcher (debounced to prevent double-reload from atomic writes)
    var configReloadWorkItem: DispatchWorkItem?
    let configFD = open(EQConstants.configPath, O_EVTONLY)
    if configFD >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: configFD,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler {
            configReloadWorkItem?.cancel()
            let item = DispatchWorkItem { reloadConfig() }
            configReloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
        source.setCancelHandler { close(configFD) }
        source.resume()
        keepAlive.append(source)
    }

    // 8. Signal handlers
    signal(SIGHUP, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    sighupSource.setEventHandler { reloadConfig() }
    sighupSource.resume()
    keepAlive.append(sighupSource)

    func cleanShutdown() {
        log("shutting down...")
        removeDeviceChangeListener()
        removeDeviceListListener()
        removeDataSourceListener()
        stopHardwareIO()

        // Restore original default output device, then hide driver
        isSettingDefaultDevice = true
        let restoreStatus = setDefaultOutputDevice(savedDefaultDeviceID)
        isSettingDefaultDevice = false
        if restoreStatus == noErr {
            log("restored default output: \(getDeviceName(savedDefaultDeviceID) ?? "unknown")")
        } else {
            log("failed to restore default output: \(fourCC(restoreStatus))")
        }
        setDriverHidden(true)

        try? FileManager.default.removeItem(atPath: EQConstants.pidPath)
        filterBank.pointee.deallocate()
        filterBank.deinitialize(count: 1)
        filterBank.deallocate()
        exit(0)
    }

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler { cleanShutdown() }
    sigtermSource.resume()
    keepAlive.append(sigtermSource)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler { cleanShutdown() }
    sigintSource.resume()
    keepAlive.append(sigintSource)

    log("knob started (pid \(ProcessInfo.processInfo.processIdentifier))")
}

// MARK: - Entry point

startDaemon()
dispatchMain()
