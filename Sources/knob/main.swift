import Foundation
import CoreAudio
import AppKit
import EQCore

// MARK: - Config helpers

func loadConfig() throws -> EQConfig {
    let path = EQConstants.configPath
    if !FileManager.default.fileExists(atPath: path) {
        let config = EQConfig()
        try saveConfig(config)
        return config
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var config = try JSONDecoder().decode(EQConfig.self, from: data)
    if config.presets["flat"] != nil && config.presets["flat"]!.bands.isEmpty {
        config.presets.removeValue(forKey: "flat")
    }
    return config
}

func saveConfig(_ config: EQConfig) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    let dir = EQConstants.configDir
    if !FileManager.default.fileExists(atPath: dir) {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try data.write(to: URL(fileURLWithPath: EQConstants.configPath))
}

func saveConfigAndReload(_ config: EQConfig) throws {
    try saveConfig(config)
    signalDaemon()
}

func signalDaemon() {
    let uid = getuid()
    let ret = runProcess("/bin/launchctl", ["kill", "SIGHUP", "gui/\(uid)/\(EQConstants.launchdLabel)"])
    if ret == 0 { return }

    if let pid = findDaemonPID() {
        kill(pid, SIGHUP)
    }
}

func daemonIsRunning() -> Bool {
    return findDaemonPID() != nil
}

func findDaemonPID() -> pid_t? {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "knobd"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = pid_t(str.components(separatedBy: "\n").first ?? "") else { return nil }
    return pid
}

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

func fail(_ msg: String) -> Never {
    fputs("\(msg)\n", stderr)
    exit(1)
}

// MARK: - Formatting

func formatDB(_ db: Double) -> String {
    let sign = db >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", db))dB"
}

func formatFreq(_ hz: Double) -> String {
    if hz >= 1000 {
        let k = hz / 1000
        if k == k.rounded() {
            return "\(Int(k))kHz"
        }
        return "\(String(format: "%.1f", k))kHz"
    }
    if hz == hz.rounded() {
        return "\(Int(hz))Hz"
    }
    return "\(String(format: "%.1f", hz))Hz"
}

func formatAppVolume(_ vol: Double) -> String {
    if vol < 0 { return "muted (\(String(format: "%.2f", -vol)))" }
    return String(format: "%.2f", vol)
}

func formatBand(_ band: Band) -> String {
    let gainStr = (band.type == .lowpass || band.type == .highpass) ? "" : " \(formatDB(band.gainDB))"
    return "\(formatFreq(band.frequency))\(gainStr) Q=\(String(format: "%.2f", band.q)) \(band.type.rawValue)"
}

// MARK: - Frequency parsing

func parseFrequency(_ s: String) -> Double? {
    let lower = s.lowercased()
    if lower.hasSuffix("khz") {
        guard let v = Double(String(lower.dropLast(3))) else { return nil }
        return v * 1000
    }
    if lower.hasSuffix("hz") {
        guard let v = Double(String(lower.dropLast(2))) else { return nil }
        return v
    }
    if lower.hasSuffix("k") {
        guard let v = Double(String(lower.dropLast(1))) else { return nil }
        return v * 1000
    }
    return Double(s)
}

func isFrequencyArg(_ s: String) -> Bool {
    let lower = s.lowercased()
    return lower.hasSuffix("khz") || lower.hasSuffix("hz") || lower.hasSuffix("k")
}

// MARK: - Gain parsing

func parseGain(_ s: String) -> Double? {
    let lower = s.lowercased()
    if lower.hasSuffix("db") {
        return Double(String(lower.dropLast(2)))
    }
    return Double(s)
}

func isGainArg(_ s: String) -> Bool {
    let lower = s.lowercased()
    if lower.hasSuffix("db") { return true }
    if s.hasPrefix("+") || s.hasPrefix("-") {
        return Double(s) != nil
    }
    return false
}

// MARK: - Q parsing

func parseQ(_ s: String) -> Double? {
    let lower = s.lowercased()
    if lower.hasPrefix("q=") {
        return Double(String(lower.dropFirst(2)))
    }
    if lower.hasSuffix("q") {
        return Double(String(lower.dropLast(1)))
    }
    return Double(s)
}

func isQArg(_ s: String) -> Bool {
    let lower = s.lowercased()
    return lower.hasPrefix("q=") || lower.hasSuffix("q")
}

// MARK: - Filter type parsing

func parseFilterType(_ s: String) -> FilterType? {
    let lower = s.lowercased().replacingOccurrences(of: "_", with: "")
    switch lower {
    case "peaking", "peak", "pea", "pe", "p": return .peaking
    case "lowshelf", "lowshel", "lowshe", "lowsh", "lows", "ls": return .lowShelf
    case "highshelf", "highshel", "highshe", "highsh", "highs", "hs": return .highShelf
    case "lowpass", "lowpas", "lowpa", "lowp", "lp": return .lowpass
    case "highpass", "highpas", "highpa", "highp", "hp": return .highpass
    // Also accept the raw codable values
    case "low_shelf": return .lowShelf
    case "high_shelf": return .highShelf
    default: return nil
    }
}

func isFilterTypeArg(_ s: String) -> Bool {
    return parseFilterType(s) != nil
}

// MARK: - Band arg parsing

struct BandParams {
    var frequency: Double?
    var gainDB: Double?
    var q: Double?
    var type: FilterType?
}

func parseBandArgs(_ args: [String]) -> BandParams {
    var params = BandParams()
    var positionalNumbers: [Double] = []

    for arg in args {
        if isFilterTypeArg(arg) {
            params.type = parseFilterType(arg)
        } else if isQArg(arg) {
            params.q = parseQ(arg)
        } else if isFrequencyArg(arg) {
            params.frequency = parseFrequency(arg)
        } else if isGainArg(arg) {
            params.gainDB = parseGain(arg)
        } else if let num = Double(arg) {
            positionalNumbers.append(num)
        } else {
            fail("unrecognized argument: \(arg)")
        }
    }

    // Fill in from positional numbers: freq, gain, Q
    for num in positionalNumbers {
        if params.frequency == nil {
            params.frequency = num
        } else if params.gainDB == nil {
            params.gainDB = num
        } else if params.q == nil {
            params.q = num
        } else {
            fail("too many numeric arguments")
        }
    }

    return params
}

func defaultQ(for type: FilterType) -> Double {
    switch type {
    case .lowShelf, .highShelf: return 0.707
    case .peaking, .lowpass, .highpass: return 1.0
    }
}

func findBandIndex(in bands: [Band], freq: Double) -> Int? {
    return bands.firstIndex { abs($0.frequency - freq) < 0.5 }
}

// MARK: - App fuzzy matching

func resolveApp(_ name: String, config: EQConfig) -> String {
    let runningApps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }

    // If it looks like a bundle ID, use directly
    if name.contains(".") && name.split(separator: ".").count >= 2 {
        return name
    }

    let lower = name.lowercased()
    var matches: [(bundleID: String, displayName: String)] = []

    for app in runningApps {
        let bundleID = app.bundleIdentifier!
        let displayName = app.localizedName ?? bundleID

        // Check localizedName first
        if displayName.lowercased().contains(lower) {
            matches.append((bundleID, displayName))
            continue
        }

        // Check bundle ID components (last to first)
        let components = bundleID.split(separator: ".").map(String.init)
        for component in components.reversed() {
            if component.lowercased().contains(lower) {
                matches.append((bundleID, displayName))
                break
            }
        }
    }

    // Deduplicate by bundle ID
    var seen = Set<String>()
    matches = matches.filter { seen.insert($0.bundleID).inserted }

    if matches.count == 1 {
        return matches[0].bundleID
    }

    if matches.count > 1 {
        fputs("ambiguous app name '\(name)'. specify the full bundle ID:\n\n", stderr)
        let colName = max(4, matches.map { $0.displayName.count }.max() ?? 0) + 2
        fputs("NAME".padding(toLength: colName, withPad: " ", startingAt: 0) + "BUNDLE ID\n", stderr)
        for m in matches {
            fputs(m.displayName.padding(toLength: colName, withPad: " ", startingAt: 0) + m.bundleID + "\n", stderr)
        }
        exit(1)
    }

    // No running match — check config's existing appVolumes keys
    let configMatches = config.appVolumes.keys.filter { bundleID in
        let components = bundleID.split(separator: ".").map(String.init)
        for component in components.reversed() {
            if component.lowercased().contains(lower) { return true }
        }
        return bundleID.lowercased().contains(lower)
    }

    if configMatches.count == 1 {
        return configMatches[0]
    }

    if configMatches.count > 1 {
        fputs("ambiguous app name '\(name)'. specify the full bundle ID:\n\n", stderr)
        fputs("BUNDLE ID\n", stderr)
        for id in configMatches {
            fputs("\(id)\n", stderr)
        }
        exit(1)
    }

    fail("no app matching '\(name)' found. use the full bundle ID for non-running apps.")
}

// MARK: - App bundle discovery

func findAppBundle() -> URL? {
    let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = execPath
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return appURL.pathExtension == "app" ? appURL : nil
}

// MARK: - Core Audio device helpers

func getDeviceName(_ deviceID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
    guard status == noErr, let cf = name?.takeRetainedValue() else {
        throw CLIError("Could not get device name")
    }
    return cf as String
}

func getDeviceUID(_ deviceID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let cf = uid?.takeRetainedValue() else {
        throw CLIError("Could not get device UID")
    }
    return cf as String
}

func getDefaultOutputDeviceID() throws -> AudioObjectID {
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
        throw CLIError("Could not get default output device")
    }
    return deviceID
}

func getDefaultOutputDeviceName() throws -> String {
    let deviceID = try getDefaultOutputDeviceID()
    let uid = try getDeviceUID(deviceID)
    if uid == EQConstants.driverDeviceUID {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/knob-devicename")),
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           name.hasSuffix(" (knob)") {
            return String(name.dropLast(7))
        }
        if let realDevice = findRealOutputDevice() {
            return try getDeviceName(realDevice)
        }
    }
    return try getDeviceName(deviceID)
}

func findRealOutputDevice() -> AudioObjectID? {
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
        guard let uid = try? getDeviceUID(deviceID), !uid.hasPrefix("com.csutora.knob.") else { continue }
        return deviceID
    }
    return nil
}

func listOutputDevices() throws -> [(uid: String, name: String)] {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    )
    guard status == noErr else { throw CLIError("Could not get device list") }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
    )
    guard status == noErr else { throw CLIError("Could not get device list") }

    var result: [(uid: String, name: String)] = []
    for deviceID in deviceIDs {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
        guard streamStatus == noErr, streamSize > 0 else { continue }
        guard let uid = try? getDeviceUID(deviceID),
              !uid.hasPrefix("com.csutora.knob."),
              let name = try? getDeviceName(deviceID) else { continue }
        result.append((uid: uid, name: name))
    }
    return result
}

// MARK: - Manual preset helper

func ensureManualPreset(_ config: inout EQConfig) {
    if config.activePreset != "manual" {
        config.presets["manual"] = config.activePresetValue()
        config.activePreset = "manual"
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

let command = args.first

do {
    switch command {
    case nil, "status":
        try handleStatus()
    case "bypass":
        try handleBypass(Array(args.dropFirst()))
    case "band", "bands":
        try handleBand(Array(args.dropFirst()))
    case "preamp", "pre":
        try handlePreamp(Array(args.dropFirst()))
    case "app", "apps":
        try handleApp(Array(args.dropFirst()))
    case "preset", "presets":
        try handlePreset(Array(args.dropFirst()))
    case "device", "devices":
        try handleDevice(Array(args.dropFirst()))
    case "start":
        try handleStart()
    case "stop":
        handleStop()
    case "restart":
        try handleRestart()
    case "completions":
        handleCompletions(Array(args.dropFirst()))
    case "help", "--help", "-h":
        printUsage()
    default:
        fail("unknown command: \(command!)")
    }
} catch {
    fail("error: \(error)")
}

// MARK: - Status

func handleStatus() throws {
    let config = try loadConfig()
    let running = daemonIsRunning()

    print("daemon:  \(running ? "running" : "stopped")")

    if let deviceName = try? getDefaultOutputDeviceName() {
        let assigned = config.devicePresets[deviceName]
        print("device:  \(deviceName)\(assigned != nil ? " → \(assigned!)" : "")")
    }

    print("preset:  \(config.activePreset)")

    let preset = config.activePresetValue()
    print("preamp:  \(formatDB(preset.preampGainDB))")

    var bypassParts: [String] = []
    if !config.eqEnabled { bypassParts.append("eq") }
    if config.appVolumesBypassed { bypassParts.append("app volumes") }
    if bypassParts.isEmpty {
        print("bypass:  off")
    } else {
        print("bypass:  \(bypassParts.joined(separator: ", "))")
    }

    if !preset.bands.isEmpty {
        print("bands:")
        for band in preset.bands {
            print("  \(formatBand(band))")
        }
    } else {
        print("bands:   (none)")
    }
}

// MARK: - Bypass

func handleBypass(_ args: [String]) throws {
    var config = try loadConfig()

    switch args.first {
    case nil:
        // Toggle both
        let newEQ = !config.eqEnabled
        config.eqEnabled = newEQ
        config.appVolumesBypassed = !newEQ
        try saveConfigAndReload(config)
        print(newEQ ? "bypass off" : "bypass on (eq + app volumes)")
    case "eq":
        config.eqEnabled = !config.eqEnabled
        try saveConfigAndReload(config)
        print(config.eqEnabled ? "eq bypass off" : "eq bypassed")
    case "app", "apps":
        config.appVolumesBypassed = !config.appVolumesBypassed
        try saveConfigAndReload(config)
        print(config.appVolumesBypassed ? "app volumes bypassed" : "app volume bypass off")
    default:
        fail("usage: knob bypass [eq | app]")
    }
}

// MARK: - Preamp

func handlePreamp(_ args: [String]) throws {
    guard let gainStr = args.first else {
        let config = try loadConfig()
        let preset = config.activePresetValue()
        print("preamp: \(formatDB(preset.preampGainDB))")
        return
    }
    guard let gain = parseGain(gainStr) else {
        fail("invalid gain: \(gainStr)")
    }

    var config = try loadConfig()
    ensureManualPreset(&config)
    config.presets["manual"]!.preampGainDB = gain
    try saveConfigAndReload(config)
    print("preamp: \(formatDB(gain))")
}

// MARK: - Band commands

func printBandList(_ config: EQConfig) {
    let preset = config.activePresetValue()
    if preset.bands.isEmpty {
        print("no bands in preset '\(config.activePreset)'")
        return
    }
    print("preset '\(config.activePreset)' (preamp: \(formatDB(preset.preampGainDB))):")
    for band in preset.bands {
        print("  \(formatBand(band))")
    }
}

func handleBand(_ args: [String]) throws {
    // Bare `knob band` or `knob band list`
    if args.isEmpty || args.first == "list" {
        let config = try loadConfig()
        printBandList(config)
        return
    }

    // `knob band pre/preamp <gain>`
    if args.first == "pre" || args.first == "preamp" {
        try handlePreamp(Array(args.dropFirst()))
        return
    }

    // `knob band remove ...`
    if args.first == "remove" || args.first == "delete" {
        let removeArgs = Array(args.dropFirst())
        guard let target = removeArgs.first else {
            fail("usage: knob band remove <freq> | all")
        }

        var config = try loadConfig()
        ensureManualPreset(&config)

        if target == "all" {
            config.presets["manual"]!.bands.removeAll()
            try saveConfigAndReload(config)
            print("removed all bands.")
            return
        }

        guard let freq = parseFrequency(target) else {
            fail("invalid frequency: \(target)")
        }

        guard let idx = findBandIndex(in: config.presets["manual"]!.bands, freq: freq) else {
            print("no band at \(formatFreq(freq)).")
            printBandList(config)
            return
        }

        let removed = config.presets["manual"]!.bands.remove(at: idx)
        try saveConfigAndReload(config)
        print("removed \(formatBand(removed))")
        return
    }

    // Parse band parameters
    let params = parseBandArgs(args)

    guard let freq = params.frequency else {
        fail("frequency is required. usage: knob band <freq> [gain] [q] [type]")
    }

    var config = try loadConfig()
    let preset = config.activePresetValue()

    // Just frequency alone — show that band
    if params.gainDB == nil && params.q == nil && params.type == nil {
        if let idx = findBandIndex(in: preset.bands, freq: freq) {
            print(formatBand(preset.bands[idx]))
        } else {
            print("no band at \(formatFreq(freq)).")
            printBandList(config)
        }
        return
    }

    ensureManualPreset(&config)
    var bands = config.presets["manual"]!.bands

    if let idx = findBandIndex(in: bands, freq: freq) {
        // Update existing band — only change provided params
        if let gain = params.gainDB { bands[idx].gainDB = gain }
        if let q = params.q { bands[idx].q = q }
        if let type = params.type { bands[idx].type = type }
        config.presets["manual"]!.bands = bands
        try saveConfigAndReload(config)
        print("updated \(formatBand(bands[idx]))")
    } else {
        // Create new band — gain is required
        guard let gain = params.gainDB else {
            fail("gain is required for new bands. usage: knob band <freq> <gain> [q] [type]")
        }
        let type = params.type ?? .peaking
        let q = params.q ?? defaultQ(for: type)

        guard bands.count < EQConstants.maxBands else {
            fail("maximum \(EQConstants.maxBands) bands reached.")
        }

        let band = Band(type: type, frequency: freq, gainDB: gain, q: q)
        config.presets["manual"]!.bands.append(band)
        try saveConfigAndReload(config)
        print("added \(formatBand(band))")
    }
}

// MARK: - App commands

func handleApp(_ args: [String]) throws {
    // Bare `knob app` or `knob app list`
    if args.isEmpty || args.first == "list" {
        try handleAppList()
        return
    }

    var config = try loadConfig()

    if args.first == "mute" {
        let appName = args.dropFirst().joined(separator: " ")
        guard !appName.isEmpty else { fail("usage: knob app mute <app name>") }
        let bundleID = resolveApp(appName, config: config)
        let current = config.appVolumes[bundleID] ?? 1.0
        if current < 0 {
            print("\(bundleID) is already muted.")
            return
        }
        // Store as negative to remember the pre-mute volume
        config.appVolumes[bundleID] = -current
        try saveConfigAndReload(config)
        print("muted \(bundleID)")
        return
    }

    if args.first == "unmute" {
        let appName = args.dropFirst().joined(separator: " ")
        guard !appName.isEmpty else { fail("usage: knob app unmute <app name>") }
        let bundleID = resolveApp(appName, config: config)
        guard let current = config.appVolumes[bundleID] else {
            print("no volume override for \(bundleID).")
            return
        }
        if current >= 0 {
            print("\(bundleID) is not muted.")
            return
        }
        // Restore the pre-mute volume
        let restored = -current
        if restored == 1.0 {
            config.appVolumes.removeValue(forKey: bundleID)
        } else {
            config.appVolumes[bundleID] = restored
        }
        try saveConfigAndReload(config)
        print("unmuted \(bundleID) → \(String(format: "%.2f", restored))")
        return
    }

    // `knob app <volume> <app name>`
    guard let volume = Double(args[0]) else {
        fail("usage: knob app <volume> <app name> | mute <app> | unmute <app>")
    }
    let appName = args.dropFirst().joined(separator: " ")
    guard !appName.isEmpty else { fail("usage: knob app <volume> <app name>") }
    let bundleID = resolveApp(appName, config: config)
    config.appVolumes[bundleID] = volume
    try saveConfigAndReload(config)
    print("set \(bundleID) to \(String(format: "%.2f", volume))")
}

func handleAppList() throws {
    let config = try loadConfig()
    let runningApps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }

    struct AppRow {
        let bundleID: String
        let name: String
        let pid: String
        let volume: String
        let isRunning: Bool
    }

    var rows: [AppRow] = []
    var seenBundleIDs: Set<String> = []

    for app in runningApps {
        let bundleID = app.bundleIdentifier!
        seenBundleIDs.insert(bundleID)
        let name = app.localizedName ?? "?"
        let pid = "\(app.processIdentifier)"
        let vol = config.appVolumes[bundleID]
        let volStr = vol.map { formatAppVolume($0) } ?? ""
        rows.append(AppRow(bundleID: bundleID, name: name, pid: pid, volume: volStr, isRunning: true))
    }

    for (bundleID, vol) in config.appVolumes {
        if seenBundleIDs.contains(bundleID) { continue }
        rows.append(AppRow(bundleID: bundleID, name: "--", pid: "--", volume: formatAppVolume(vol), isRunning: false))
    }

    if rows.isEmpty {
        print("no apps found.")
        return
    }

    let running = rows.filter { $0.isRunning }.sorted { $0.bundleID < $1.bundleID }
    let notRunning = rows.filter { !$0.isRunning }.sorted { $0.bundleID < $1.bundleID }
    let sorted = running + notRunning

    let headers = ("BUNDLE ID", "NAME", "PID", "VOLUME")
    let colBundle = max(headers.0.count, sorted.map { $0.bundleID.count }.max() ?? 0) + 2
    let colName = max(headers.1.count, sorted.map { $0.name.count }.max() ?? 0) + 2
    let colPID = max(headers.2.count, sorted.map { $0.pid.count }.max() ?? 0) + 2

    print(
        headers.0.padding(toLength: colBundle, withPad: " ", startingAt: 0) +
        headers.1.padding(toLength: colName, withPad: " ", startingAt: 0) +
        headers.2.padding(toLength: colPID, withPad: " ", startingAt: 0) +
        headers.3
    )

    for row in sorted {
        print(
            row.bundleID.padding(toLength: colBundle, withPad: " ", startingAt: 0) +
            row.name.padding(toLength: colName, withPad: " ", startingAt: 0) +
            row.pid.padding(toLength: colPID, withPad: " ", startingAt: 0) +
            row.volume
        )
    }
}

// MARK: - Preset commands

func handlePreset(_ args: [String]) throws {
    let sub = args.first

    switch sub {
    case nil, "list":
        let config = try loadConfig()
        let flatMarker = config.activePreset == "flat" ? " *" : ""
        print("flat\(flatMarker) (0 bands)")
        for name in config.presets.keys.sorted() where name != "flat" {
            let marker = name == config.activePreset ? " *" : ""
            let preset = config.presets[name]!
            print("\(name)\(marker) (\(preset.bands.count) bands)")
        }

    case "load":
        guard args.count >= 2 else { fail("usage: knob preset load <name>") }
        let name = args[1]
        var config = try loadConfig()
        if name == "flat" {
            config.activePreset = "flat"
        } else if name == "manual" {
            if config.presets["manual"] == nil {
                config.presets["manual"] = Preset()
            }
            config.activePreset = "manual"
        } else {
            guard config.presets[name] != nil else { fail("preset '\(name)' not found.") }
            config.activePreset = name
        }
        try saveConfigAndReload(config)
        print("loaded '\(name)'.")

    case "save":
        guard args.count >= 2 else { fail("usage: knob preset save <name>") }
        let name = args[1]
        if name == "flat" { fail("cannot save to 'flat' — it is built-in.") }
        if name == "manual" { fail("cannot save as 'manual' — it is reserved.") }
        var config = try loadConfig()
        let current = config.activePresetValue()
        let existed = config.presets[name] != nil
        config.presets[name] = current
        config.activePreset = name
        try saveConfigAndReload(config)
        print(existed ? "overwritten '\(name)'." : "saved '\(name)'.")

    case "rename":
        guard args.count >= 3 else { fail("usage: knob preset rename <old> <new>") }
        let oldName = args[1]
        let newName = args[2]
        if oldName == "flat" || oldName == "manual" { fail("cannot rename '\(oldName)'.") }
        if newName == "flat" { fail("cannot rename to 'flat' — it is built-in.") }
        if newName == "manual" { fail("cannot rename to 'manual' — it is reserved.") }
        var config = try loadConfig()
        guard let preset = config.presets.removeValue(forKey: oldName) else {
            fail("preset '\(oldName)' not found.")
        }
        config.presets[newName] = preset
        if config.activePreset == oldName { config.activePreset = newName }
        for (device, presetName) in config.devicePresets {
            if presetName == oldName { config.devicePresets[device] = newName }
        }
        try saveConfigAndReload(config)
        print("renamed '\(oldName)' to '\(newName)'.")

    case "delete", "remove":
        guard args.count >= 2 else { fail("usage: knob preset delete <name>") }
        let name = args[1]
        if name == "flat" { fail("cannot delete 'flat' — it is built-in.") }
        if name == "manual" { fail("cannot delete 'manual' — it is reserved.") }
        var config = try loadConfig()
        guard config.presets.removeValue(forKey: name) != nil else {
            fail("preset '\(name)' not found.")
        }
        if config.activePreset == name { config.activePreset = "flat" }
        try saveConfigAndReload(config)
        print("deleted '\(name)'.")

    default:
        fail("usage: knob preset <list | load | save | rename | delete>")
    }
}

// MARK: - Device commands

func handleDevice(_ args: [String]) throws {
    let sub = args.first

    switch sub {
    case nil, "list":
        let config = try loadConfig()
        let devices = try listOutputDevices()
        let currentName = try? getDefaultOutputDeviceName()

        for device in devices {
            let isCurrent = device.name == currentName ? " *" : ""
            let assigned = config.devicePresets[device.name]
            let mapping = assigned != nil ? " → \(assigned!)" : ""
            print("\(device.name)\(isCurrent)\(mapping)")
        }

    case "assign":
        guard args.count >= 2 else { fail("usage: knob device assign <device> [preset]") }
        let deviceName = args[1]

        if args.count < 3 {
            // No preset = clear assignment
            var config = try loadConfig()
            guard config.devicePresets.removeValue(forKey: deviceName) != nil else {
                print("no assignment for '\(deviceName)'.")
                return
            }
            try saveConfigAndReload(config)
            print("cleared assignment for '\(deviceName)'.")
        } else {
            let presetName = args[2]
            var config = try loadConfig()
            if presetName != "flat" && presetName != "manual" {
                guard config.presets[presetName] != nil else {
                    fail("preset '\(presetName)' not found.")
                }
            }
            config.devicePresets[deviceName] = presetName
            try saveConfigAndReload(config)
            print("assigned '\(deviceName)' → '\(presetName)'.")
        }

    default:
        fail("usage: knob device <list | assign>")
    }
}

// MARK: - Start/Stop/Restart

func handleStart() throws {
    if let pid = findDaemonPID() {
        print("knob is already running (pid \(pid)).")
        return
    }

    let uid = getuid()
    let label = EQConstants.launchdLabel
    let plistPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/\(label).plist"

    runProcess("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])

    let kickstart = runProcess("/bin/launchctl", ["kickstart", "gui/\(uid)/\(label)"])
    if kickstart == 0 {
        usleep(1_000_000)
        if let pid = findDaemonPID() {
            print("knob started (pid \(pid)).")
        } else {
            print("knob starting...")
        }
        return
    }

    if FileManager.default.fileExists(atPath: plistPath) {
        let bootstrap = runProcess("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        if bootstrap == 0 {
            usleep(1_000_000)
            if let pid = findDaemonPID() {
                print("knob started (pid \(pid)).")
            } else {
                print("knob starting...")
            }
            return
        }
    }

    // Find knobd next to knob CLI or in the app bundle
    let cliPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let siblingPath = cliPath.deletingLastPathComponent().appendingPathComponent("knobd").path

    var daemonPath: String?
    if FileManager.default.fileExists(atPath: siblingPath) {
        daemonPath = siblingPath
    } else if let appURL = findAppBundle() {
        let appDaemon = appURL.appendingPathComponent("Contents/MacOS/knobd").path
        if FileManager.default.fileExists(atPath: appDaemon) {
            daemonPath = appDaemon
        }
    }

    guard let path = daemonPath else {
        fail("could not locate knobd. ensure it is installed or use launchctl.")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.arguments = []
    try process.run()
    usleep(1_000_000)
    if let pid = findDaemonPID() {
        print("knob started (pid \(pid)).")
    } else {
        print("knob starting...")
    }
}

func handleStop() {
    guard findDaemonPID() != nil else {
        print("knob is not running.")
        return
    }

    let uid = getuid()
    let label = EQConstants.launchdLabel
    let plistPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/\(label).plist"

    runProcess("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])
    let bootout = runProcess("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    if bootout != 0 && FileManager.default.fileExists(atPath: plistPath) {
        runProcess("/bin/launchctl", ["unload", plistPath])
    }

    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-x", "knobd"]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()

    for _ in 0..<30 {
        usleep(100_000)
        if findDaemonPID() == nil { break }
    }

    if findDaemonPID() == nil {
        print("knob stopped.")
    } else {
        fputs("knob did not exit in time.\n", stderr)
    }
}

func handleRestart() throws {
    if findDaemonPID() != nil {
        handleStop()
        for _ in 0..<20 {
            usleep(100_000)
            if findDaemonPID() == nil { break }
        }
        usleep(500_000)
    }
    try handleStart()
}

// MARK: - Completions

func handleCompletions(_ args: [String]) {
    guard let shell = args.first else {
        fail("usage: knob completions <bash | zsh | fish | nu>")
    }

    switch shell {
    case "bash":
        print(bashCompletions())
    case "zsh":
        print(zshCompletions())
    case "fish":
        print(fishCompletions())
    case "nu", "nushell":
        print(nushellCompletions())
    default:
        fail("unsupported shell: \(shell). use bash, zsh, fish, or nu.")
    }
}

func bashCompletions() -> String {
    return """
    _knob() {
        local cur prev words cword
        _init_completion || return

        case "$cword" in
            1)
                COMPREPLY=($(compgen -W "status bypass band bands preamp pre app apps preset presets device devices start stop restart completions help" -- "$cur"))
                ;;
            2)
                case "${words[1]}" in
                    bypass) COMPREPLY=($(compgen -W "eq app apps" -- "$cur")) ;;
                    band|bands) COMPREPLY=($(compgen -W "list remove pre preamp $(knob band list 2>/dev/null | grep -oE '[0-9]+Hz|[0-9.]+kHz' | head -16)" -- "$cur")) ;;
                    app|apps) COMPREPLY=($(compgen -W "list mute unmute" -- "$cur")) ;;
                    preset|presets) COMPREPLY=($(compgen -W "list load save rename delete remove" -- "$cur")) ;;
                    device|devices) COMPREPLY=($(compgen -W "list assign" -- "$cur")) ;;
                    completions) COMPREPLY=($(compgen -W "bash zsh fish nu" -- "$cur")) ;;
                esac
                ;;
            3)
                case "${words[1]}" in
                    band|bands)
                        if [[ "${words[2]}" == "remove" ]]; then
                            COMPREPLY=($(compgen -W "all $(knob band list 2>/dev/null | grep -oE '[0-9]+Hz|[0-9.]+kHz' | head -16)" -- "$cur"))
                        fi
                        ;;
                    preset|presets)
                        case "${words[2]}" in
                            load|delete|remove|rename) COMPREPLY=($(compgen -W "$(knob preset list 2>/dev/null | awk '{print $1}')" -- "$cur")) ;;
                        esac
                        ;;
                    device|devices)
                        if [[ "${words[2]}" == "assign" ]]; then
                            COMPREPLY=($(compgen -W "$(knob device list 2>/dev/null | sed 's/ .*//')" -- "$cur"))
                        fi
                        ;;
                esac
                ;;
            4)
                case "${words[1]}" in
                    device|devices)
                        if [[ "${words[2]}" == "assign" ]]; then
                            COMPREPLY=($(compgen -W "$(knob preset list 2>/dev/null | awk '{print $1}')" -- "$cur"))
                        fi
                        ;;
                esac
                ;;
        esac
    }
    complete -F _knob knob
    """
}

func zshCompletions() -> String {
    return """
    #compdef knob

    _knob() {
        local -a subcommands
        subcommands=(
            'status:show status'
            'bypass:toggle bypass'
            'band:manage EQ bands'
            'bands:list EQ bands'
            'preamp:set preamp gain'
            'pre:set preamp gain'
            'app:manage per-app volumes'
            'apps:list apps and volumes'
            'preset:manage presets'
            'presets:list presets'
            'device:manage device assignments'
            'devices:list devices'
            'start:start daemon'
            'stop:stop daemon'
            'restart:restart daemon'
            'completions:generate shell completions'
            'help:show help'
        )

        if (( CURRENT == 2 )); then
            _describe 'command' subcommands
            return
        fi

        case "$words[2]" in
            bypass)
                if (( CURRENT == 3 )); then
                    local -a targets
                    targets=('eq:toggle EQ bypass only' 'app:toggle app volume bypass' 'apps:toggle app volume bypass')
                    _describe 'target' targets
                fi
                ;;
            band|bands)
                if (( CURRENT == 3 )); then
                    local -a band_cmds
                    band_cmds=('list:list bands' 'remove:remove band' 'pre:set preamp gain' 'preamp:set preamp gain')
                    _describe 'band command' band_cmds
                    local -a freqs
                    freqs=(${(f)"$(knob band list 2>/dev/null | grep -oE '[0-9]+Hz|[0-9.]+kHz')"})
                    (( ${#freqs} )) && compadd -a freqs
                elif (( CURRENT == 4 )) && [[ "$words[3]" == "remove" ]]; then
                    local -a freqs
                    freqs=(all ${(f)"$(knob band list 2>/dev/null | grep -oE '[0-9]+Hz|[0-9.]+kHz')"})
                    compadd -a freqs
                fi
                ;;
            app|apps)
                if (( CURRENT == 3 )); then
                    local -a app_cmds
                    app_cmds=('list:list apps and volumes' 'mute:mute app' 'unmute:unmute app')
                    _describe 'app command' app_cmds
                fi
                ;;
            preset|presets)
                if (( CURRENT == 3 )); then
                    local -a preset_cmds
                    preset_cmds=('list:list presets' 'load:switch to preset' 'save:save current state' 'rename:rename preset' 'delete:delete preset' 'remove:delete preset')
                    _describe 'preset command' preset_cmds
                elif (( CURRENT == 4 )); then
                    case "$words[3]" in
                        load|delete|remove|rename)
                            local -a presets
                            presets=(${(f)"$(knob preset list 2>/dev/null | awk '{print $1}')"})
                            compadd -a presets
                            ;;
                    esac
                fi
                ;;
            device|devices)
                if (( CURRENT == 3 )); then
                    local -a device_cmds
                    device_cmds=('list:list devices' 'assign:assign or clear device preset')
                    _describe 'device command' device_cmds
                elif (( CURRENT == 4 )) && [[ "$words[3]" == "assign" ]]; then
                    local -a devices
                    devices=(${(f)"$(knob device list 2>/dev/null | sed 's/ \\*.*//' | sed 's/ →.*//')"})
                    compadd -a devices
                elif (( CURRENT == 5 )) && [[ "$words[3]" == "assign" ]]; then
                    local -a presets
                    presets=(${(f)"$(knob preset list 2>/dev/null | awk '{print $1}')"})
                    compadd -a presets
                fi
                ;;
            completions)
                if (( CURRENT == 3 )); then
                    local -a shells
                    shells=('bash:bash completions' 'zsh:zsh completions' 'fish:fish completions' 'nu:nushell completions')
                    _describe 'shell' shells
                fi
                ;;
        esac
    }

    _knob "$@"
    """
}

func fishCompletions() -> String {
    return """
    # knob completions for fish

    set -l commands status bypass band bands preamp pre app apps preset presets device devices start stop restart completions help

    complete -c knob -f
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a status -d "Show status"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a bypass -d "Toggle bypass"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a band -d "Manage EQ bands"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a bands -d "List EQ bands"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a preamp -d "Set preamp gain"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a pre -d "Set preamp gain"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a app -d "Manage per-app volumes"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a apps -d "List apps and volumes"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a preset -d "Manage presets"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a presets -d "List presets"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a device -d "Manage devices"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a devices -d "List devices"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a start -d "Start daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a stop -d "Stop daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a restart -d "Restart daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a completions -d "Generate completions"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a help -d "Show help"

    complete -c knob -n "__fish_seen_subcommand_from bypass" -a "eq" -d "Toggle EQ bypass only"
    complete -c knob -n "__fish_seen_subcommand_from bypass" -a "app" -d "Toggle app volume bypass"
    complete -c knob -n "__fish_seen_subcommand_from bypass" -a "apps" -d "Toggle app volume bypass"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "list" -d "List bands"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "remove" -d "Remove band"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "pre" -d "Set preamp gain"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "preamp" -d "Set preamp gain"
    complete -c knob -n "__fish_seen_subcommand_from app apps" -a "list" -d "List apps and volumes"
    complete -c knob -n "__fish_seen_subcommand_from app apps" -a "mute" -d "Mute app"
    complete -c knob -n "__fish_seen_subcommand_from app apps" -a "unmute" -d "Unmute app"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "list" -d "List presets"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "load" -d "Switch to preset"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "save" -d "Save current state"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "rename" -d "Rename preset"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "delete" -d "Delete preset"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "remove" -d "Delete preset"
    complete -c knob -n "__fish_seen_subcommand_from device devices" -a "list" -d "List devices"
    complete -c knob -n "__fish_seen_subcommand_from device devices" -a "assign" -d "Assign or clear device preset"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "bash" -d "Bash completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "zsh" -d "Zsh completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "fish" -d "Fish completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "nu" -d "Nushell completions"
    """
}

func nushellCompletions() -> String {
    return """
    # knob completions for nushell

    def "nu-complete knob subcommands" [] {
        [{value: status, description: "show status"}
         {value: bypass, description: "toggle bypass"}
         {value: band, description: "manage EQ bands"}
         {value: bands, description: "list EQ bands"}
         {value: preamp, description: "set preamp gain"}
         {value: pre, description: "set preamp gain"}
         {value: app, description: "manage per-app volumes"}
         {value: apps, description: "list apps and volumes"}
         {value: preset, description: "manage presets"}
         {value: presets, description: "list presets"}
         {value: device, description: "manage device assignments"}
         {value: devices, description: "list devices"}
         {value: start, description: "start daemon"}
         {value: stop, description: "stop daemon"}
         {value: restart, description: "restart daemon"}
         {value: completions, description: "generate shell completions"}
         {value: help, description: "show help"}]
    }

    def "nu-complete knob bypass" [] {
        [{value: eq, description: "toggle EQ bypass only"}
         {value: app, description: "toggle app volume bypass only"}
         {value: apps, description: "toggle app volume bypass only"}]
    }

    def "nu-complete knob band" [] {
        [{value: list, description: "list bands"}
         {value: remove, description: "remove band"}
         {value: pre, description: "set preamp gain"}
         {value: preamp, description: "set preamp gain"}]
    }

    def "nu-complete knob app" [] {
        [{value: list, description: "list apps and volumes"}
         {value: mute, description: "mute app"}
         {value: unmute, description: "unmute app"}]
    }

    def "nu-complete knob preset" [] {
        [{value: list, description: "list presets"}
         {value: load, description: "switch to preset"}
         {value: save, description: "save current state"}
         {value: rename, description: "rename preset"}
         {value: delete, description: "delete preset"}
         {value: remove, description: "delete preset"}]
    }

    def "nu-complete knob device" [] {
        [{value: list, description: "list devices"}
         {value: assign, description: "assign or clear device preset"}]
    }

    def "nu-complete knob completions" [] {
        [{value: bash, description: "bash completions"}
         {value: zsh, description: "zsh completions"}
         {value: fish, description: "fish completions"}
         {value: nu, description: "nushell completions"}]
    }

    def "nu-complete knob filter-types" [] {
        [{value: peaking, description: "bell curve (default)"}
         {value: lowshelf, description: "boost/cut below frequency"}
         {value: highshelf, description: "boost/cut above frequency"}
         {value: lowpass, description: "pass below frequency"}
         {value: highpass, description: "pass above frequency"}
         {value: p, description: "peaking"} {value: ls, description: "lowshelf"}
         {value: hs, description: "highshelf"} {value: lp, description: "lowpass"}
         {value: hp, description: "highpass"}]
    }

    export extern "knob" [
        command?: string@"nu-complete knob subcommands"
        ...rest: string
    ]

    export extern "knob bypass" [target?: string@"nu-complete knob bypass"]
    export extern "knob band" [subcommand?: string@"nu-complete knob band" ...rest: string]
    export extern "knob app" [subcommand?: string@"nu-complete knob app" ...rest: string]
    export extern "knob preset" [subcommand?: string@"nu-complete knob preset" ...rest: string]
    export extern "knob device" [subcommand?: string@"nu-complete knob device" ...rest: string]
    export extern "knob completions" [shell?: string@"nu-complete knob completions"]
    """
}

// MARK: - Usage

func printUsage() {
    print("""
    knob 0.1.0

    parametric equalizer and per-app volume control for mac

    ---

    usage:

    knob
    | [  | status ]                 show status
    | [ -h | help ]                 show this help page
    | [ start | stop | restart ]    control whether knob is running

    knob bypass
    | [  ]                          toggle EQ and app volume bypass
    | eq                            toggle EQ bypass only
    | [ app | apps ]                toggle app volume bypass only

    knob preset
    | [  | list ]                   list presets (* = active)
    | load <name>                   switch to preset
    | save <name>                   save current state as preset
    | rename <old> <new>            rename preset
    | [ delete | remove ] <name>    delete preset

    knob band
    | [  | list ]                   list bands in active preset
    | [ pre | preamp ] <gain>       set preamp gain
    | <freq> [gain] [q] [type]      add or update band at frequency
    | remove <freq>                 remove band at frequency
    | remove all                    remove all bands

    knob app
    | [  | list ]                   list apps and volume overrides
    | <volume> <app name>           set per-app volume (fuzzy match)
    | mute <app name>               mute app
    | unmute <app name>             remove volume override

    knob device
    | [  | list ]                   list output devices and assignments
    | assign <device> <preset>      assign preset to device
    | assign <device>               clear device assignment

    knob completions <shell>        generate completions (bash/zsh/fish/nu)

    ---

    band parameters are positional and all optional except frequency.
    labeled forms (1khz, +3db, q=1.4, etc) can appear in any order.

    freq   1k, 1000, 1khz, 0.3k, 300hz           (k = ×1000, hz optional)
    gain   +3, -3, 3, 3db                        (sign or db suffix)
    q      1.4, q=1.4, 1.4q                      (default: 1.0 peak, 0.707 shelf)
    type   peaking (p), lowshelf (ls), highshelf (hs), lowpass (lp), highpass (hp)
           any unique prefix works too: peak, lows, highp, ...

    if a band at that frequency exists, only provided params are updated.
    if not, a new band is created (gain required).

    ---

    examples:

    knob                            show status
    knob band 1k +3                 add peaking band at 1kHz, +3dB, Q=1.0
    knob band 1k -1                 update gain to -1dB (keep Q, type)
    knob band 1k ls                 change type to lowshelf (keep gain, Q)
    knob band 1k q=2.0              change Q only
    knob band 1khz +3db pea 2.0q    fully labeled (any order)
    knob band remove 1k             remove band at 1kHz
    knob band pre -2                set preamp to -2dB
    knob app 0.5 spotify            set spotify volume to 50%
    knob app 1.5 discord            set discord volume to 150%
    knob app mute chrome            mute chrome
    knob bypass eq                  toggle EQ bypass
    knob preset save bright         save current EQ as "bright"
    knob device assign buds bright  auto-load "bright" when using "buds" audio device
    """)
}
