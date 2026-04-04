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
    if hz == hz.rounded() {
        return "\(Int(hz))Hz"
    }
    return "\(String(format: "%.1f", hz))Hz"
}

func formatAppVolume(_ vol: Double) -> String {
    if vol < 0 { return "muted (\(String(format: "%.2f", -vol)))" }
    if vol == 1.0 { return "" }
    return String(format: "%.2f", vol)
}

func formatBandColumns(_ band: Band) -> (freq: String, gain: String, q: String, type: String) {
    let freq = band.frequency == band.frequency.rounded() ? "\(Int(band.frequency))" : String(format: "%.1f", band.frequency)
    let gain = (band.type == .lowpass || band.type == .highpass) ? "--" : String(format: "%+.1f", band.gainDB)
    let q = String(format: "%.2f", band.q)
    return (freq, gain, q, band.type.rawValue)
}

func formatBand(_ band: Band) -> String {
    let c = formatBandColumns(band)
    return "\(c.freq) \(c.gain) \(c.q) \(c.type)"
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
        // Aliases for knob band preamp
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
    case "plot":
        try handlePlot(Array(args.dropFirst()))
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
        print("device:  \(deviceName)\(assigned != nil ? " -> \(assigned!)" : "")")
    }

    print("preset:  \(config.activePreset)")

    let preset = config.activePresetValue()
    print("preamp:  \(formatDB(preset.preampGainDB))")

    var bypassParts: [String] = []
    if !config.eqEnabled { bypassParts.append("equalizer") }
    if config.appVolumesBypassed { bypassParts.append("app volumes") }
    if bypassParts.isEmpty {
        print("bypass:  off")
    } else {
        print("bypass:  \(bypassParts.joined(separator: ", "))")
    }

    if !preset.bands.isEmpty {
        let pad = 3
        print("bands:")
        let cols = preset.bands.map { formatBandColumns($0) }
        let wFreq = cols.map { $0.freq.count }.max()! + pad
        let wGain = cols.map { $0.gain.count }.max()! + pad
        let wQ = cols.map { $0.q.count }.max()! + pad
        for c in cols {
            print("  \(c.freq.padding(toLength: wFreq, withPad: " ", startingAt: 0))\(c.gain.padding(toLength: wGain, withPad: " ", startingAt: 0))\(c.q.padding(toLength: wQ, withPad: " ", startingAt: 0))\(c.type)")
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
        print(newEQ ? "bypass off" : "bypass on (equalizer + app volumes)")
    case "eq":
        config.eqEnabled = !config.eqEnabled
        try saveConfigAndReload(config)
        print(config.eqEnabled ? "equalizer bypass off" : "equalizer bypassed")
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
    let pad = 3

    struct BandRow { let freq: String; let gain: String; let q: String; let type: String }
    var rows = [BandRow(freq: "preamp", gain: String(format: "%+.1f", preset.preampGainDB), q: "", type: "")]
    for band in preset.bands {
        let c = formatBandColumns(band)
        rows.append(BandRow(freq: c.freq, gain: c.gain, q: c.q, type: c.type))
    }

    let headers = ("FREQ (Hz)", "GAIN (dB)", "Q", "TYPE")
    let wFreq = max(headers.0.count, rows.map { $0.freq.count }.max()!) + pad
    let wGain = max(headers.1.count, rows.map { $0.gain.count }.max()!) + pad
    let wQ = max(headers.2.count, rows.map { $0.q.count }.max()!) + pad
    print(
        headers.0.padding(toLength: wFreq, withPad: " ", startingAt: 0) +
        headers.1.padding(toLength: wGain, withPad: " ", startingAt: 0) +
        headers.2.padding(toLength: wQ, withPad: " ", startingAt: 0) +
        headers.3)
    for r in rows {
        print(
            r.freq.padding(toLength: wFreq, withPad: " ", startingAt: 0) +
            r.gain.padding(toLength: wGain, withPad: " ", startingAt: 0) +
            r.q.padding(toLength: wQ, withPad: " ", startingAt: 0) +
            r.type)
    }
}

func handleBand(_ args: [String]) throws {
    // Bare `knob band` or `knob band list`
    if args.isEmpty || args.first == "list" || args.first == "-m" {
        let config = try loadConfig()
        if args.contains("-m") {
            let preset = config.activePresetValue()
            var items: [[String: Any]] = [["type": "preamp", "gain": preset.preampGainDB]]
            for b in preset.bands {
                items.append(["freq": b.frequency, "gain": b.gainDB, "q": b.q, "type": b.type.rawValue])
            }
            let data = try JSONSerialization.data(withJSONObject: items)
            print(String(data: data, encoding: .utf8)!)
        } else {
            printBandList(config)
        }
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
    if args.isEmpty || args.first == "list" || args.first == "-m" {
        try handleAppList(machine: args.contains("-m"))
        return
    }

    // `knob app <name> <volume|mute|unmute>`
    // Last arg is the action/value, everything before is the app name
    guard args.count >= 2 else {
        fail("usage: knob app <app name> <volume | mute | unmute>")
    }

    let action = args.last!
    let appName = args.dropLast().joined(separator: " ")
    guard !appName.isEmpty else { fail("usage: knob app <app name> <volume | mute | unmute>") }

    var config = try loadConfig()
    let bundleID = resolveApp(appName, config: config)

    if action == "mute" {
        let current = config.appVolumes[bundleID] ?? 1.0
        if current < 0 {
            print("\(bundleID) is already muted.")
            return
        }
        config.appVolumes[bundleID] = -current
        try saveConfigAndReload(config)
        print("muted \(bundleID)")
    } else if action == "unmute" {
        guard let current = config.appVolumes[bundleID] else {
            print("no volume override for \(bundleID).")
            return
        }
        if current >= 0 {
            print("\(bundleID) is not muted.")
            return
        }
        let restored = -current
        if restored == 1.0 {
            config.appVolumes.removeValue(forKey: bundleID)
        } else {
            config.appVolumes[bundleID] = restored
        }
        try saveConfigAndReload(config)
        print("unmuted \(bundleID) -> \(String(format: "%.2f", restored))")
    } else if let volume = Double(action) {
        if volume == 1.0 {
            config.appVolumes.removeValue(forKey: bundleID)
        } else {
            config.appVolumes[bundleID] = volume
        }
        try saveConfigAndReload(config)
        print("set \(bundleID) to \(String(format: "%.2f", volume))")
    } else {
        fail("usage: knob app <app name> <volume | mute | unmute>")
    }
}

func handleAppList(machine: Bool = false) throws {
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
        if machine { print("[]") }
        else { print("no apps found.") }
        return
    }

    let running = rows.filter { $0.isRunning }.sorted { $0.bundleID < $1.bundleID }
    let notRunning = rows.filter { !$0.isRunning }.sorted { $0.bundleID < $1.bundleID }
    let sorted = running + notRunning

    if machine {
        let items = sorted.map { r -> [String: Any] in
            var item: [String: Any] = ["bundle_id": r.bundleID, "name": r.name, "running": r.isRunning]
            if !r.volume.isEmpty { item["volume"] = r.volume }
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: items)
        print(String(data: data, encoding: .utf8)!)
        return
    }

    let headers = ("BUNDLE ID", "NAME", "PID", "VOLUME")
    let colBundle = max(headers.0.count, sorted.map { $0.bundleID.count }.max() ?? 0) + 3
    let colName = max(headers.1.count, sorted.map { $0.name.count }.max() ?? 0) + 3
    let colPID = max(headers.2.count, sorted.map { $0.pid.count }.max() ?? 0) + 3

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
    case nil, "list", "-m":
        let config = try loadConfig()
        let isM = args.contains("-m")
        if isM {
            var items: [[String: Any]] = [["name": "flat", "bands": 0, "active": config.activePreset == "flat"]]
            for name in config.presets.keys.sorted() {
                items.append(["name": name, "bands": config.presets[name]!.bands.count, "active": config.activePreset == name])
            }
            let data = try JSONSerialization.data(withJSONObject: items)
            print(String(data: data, encoding: .utf8)!)
        } else {
            struct PresetRow { let name: String; let bands: String; let active: String }
            var rows = [PresetRow(name: "flat", bands: "0 bands", active: config.activePreset == "flat" ? "*" : "")]
            for name in config.presets.keys.sorted() {
                let p = config.presets[name]!
                rows.append(PresetRow(name: name, bands: "\(p.bands.count) bands", active: config.activePreset == name ? "*" : ""))
            }
            let pad = 3
            let headers = ("PRESET", "BANDS")
            let wName = max(headers.0.count, rows.map { $0.name.count }.max()!) + pad
            let wBands = max(headers.1.count, rows.map { $0.bands.count }.max()!) + pad
            print(
                headers.0.padding(toLength: wName, withPad: " ", startingAt: 0) +
                headers.1.padding(toLength: wBands, withPad: " ", startingAt: 0))
            for r in rows {
                print(
                    r.name.padding(toLength: wName, withPad: " ", startingAt: 0) +
                    r.bands.padding(toLength: wBands, withPad: " ", startingAt: 0) +
                    r.active)
            }
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
        fail("usage: knob preset <list | load | save | rename | remove>")
    }
}

// MARK: - Device commands

func handleDevice(_ args: [String]) throws {
    let sub = args.first

    switch sub {
    case nil, "list", "-m":
        let config = try loadConfig()
        let devices = try listOutputDevices()
        let currentName = try? getDefaultOutputDeviceName()
        let isM = args.contains("-m")
        if isM {
            var items: [[String: Any]] = []
            for d in devices {
                var item: [String: Any] = ["name": d.name, "active": d.name == currentName]
                if let p = config.devicePresets[d.name] { item["preset"] = p }
                items.append(item)
            }
            let data = try JSONSerialization.data(withJSONObject: items)
            print(String(data: data, encoding: .utf8)!)
        } else {
            struct DevRow { let name: String; let preset: String; let active: String }
            var rows: [DevRow] = []
            for d in devices {
                let preset = config.devicePresets[d.name] ?? ""
                let active = d.name == currentName ? "*" : ""
                rows.append(DevRow(name: d.name, preset: preset, active: active))
            }
            let pad = 3
            let headers = ("DEVICE", "PRESET")
            let wName = max(headers.0.count, rows.map { $0.name.count }.max()!) + pad
            let wPreset = max(headers.1.count, rows.map { $0.preset.count }.max()!) + pad
            print(
                headers.0.padding(toLength: wName, withPad: " ", startingAt: 0) +
                headers.1.padding(toLength: wPreset, withPad: " ", startingAt: 0))
            for r in rows {
                print(
                    r.name.padding(toLength: wName, withPad: " ", startingAt: 0) +
                    r.preset.padding(toLength: wPreset, withPad: " ", startingAt: 0) +
                    r.active)
            }
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
            print("assigned '\(deviceName)' -> '\(presetName)'.")
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
    return ##"""
    _knob() {
        local cur prev words cword
        _init_completion || return

        _knob_band_freqs() { knob band -m 2>/dev/null | python3 -c "import sys,json;[print(str(int(b['freq']) if b['freq']==int(b['freq']) else b['freq'])+'Hz') for b in json.load(sys.stdin) if b.get('type','')!='preamp']" 2>/dev/null; }
        _knob_preset_names() { knob preset -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null; }
        _knob_device_names() { knob device -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null; }
        _knob_app_names() { knob app -m 2>/dev/null | python3 -c "import sys,json;[print(a['name']) for a in json.load(sys.stdin)]" 2>/dev/null; }

        case "$cword" in
            1)
                COMPREPLY=($(compgen -W "status bypass band app preset device plot start stop restart completions help" -- "$cur"))
                ;;
            2)
                case "${words[1]}" in
                    bypass) COMPREPLY=($(compgen -W "eq app" -- "$cur")) ;;
                    band|bands) COMPREPLY=($(compgen -W "list remove preamp $(_knob_band_freqs)" -- "$cur")) ;;
                    app|apps) COMPREPLY=($(compgen -W "list $(_knob_app_names)" -- "$cur")) ;;
                    preset|presets) COMPREPLY=($(compgen -W "list load save rename remove" -- "$cur")) ;;
                    device|devices) COMPREPLY=($(compgen -W "list assign" -- "$cur")) ;;
                    completions) COMPREPLY=($(compgen -W "bash zsh fish nu" -- "$cur")) ;;
                esac
                ;;
            3)
                case "${words[1]}" in
                    band|bands)
                        if [[ "${words[2]}" == "remove" ]]; then
                            COMPREPLY=($(compgen -W "all $(_knob_band_freqs)" -- "$cur"))
                        fi
                        ;;
                    app|apps)
                        COMPREPLY=($(compgen -W "mute unmute" -- "$cur"))
                        ;;
                    plot) COMPREPLY=($(compgen -W "$(_knob_preset_names)" -- "$cur")) ;;
                    preset|presets)
                        case "${words[2]}" in
                            load|remove|rename) COMPREPLY=($(compgen -W "$(_knob_preset_names)" -- "$cur")) ;;
                        esac
                        ;;
                    device|devices)
                        if [[ "${words[2]}" == "assign" ]]; then
                            COMPREPLY=($(compgen -W "$(_knob_device_names)" -- "$cur"))
                        fi
                        ;;
                esac
                ;;
            4)
                case "${words[1]}" in
                    device|devices)
                        if [[ "${words[2]}" == "assign" ]]; then
                            COMPREPLY=($(compgen -W "$(_knob_preset_names)" -- "$cur"))
                        fi
                        ;;
                esac
                ;;
        esac
    }
    complete -F _knob knob
    """##
}

func zshCompletions() -> String {
    return ##"""
    #compdef knob

    _knob_band_freqs() { knob band -m 2>/dev/null | python3 -c "import sys,json;[print(str(int(b['freq']) if b['freq']==int(b['freq']) else b['freq'])+'Hz') for b in json.load(sys.stdin) if b.get('type','')!='preamp']" 2>/dev/null; }
    _knob_preset_names() { knob preset -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null; }
    _knob_device_names() { knob device -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null; }
    _knob_app_names() { knob app -m 2>/dev/null | python3 -c "import sys,json;[print(a['name']) for a in json.load(sys.stdin)]" 2>/dev/null; }

    _knob() {
        local -a subcommands
        subcommands=(
            'status:show status'
            'bypass:toggle bypass'
            'band:manage equalizer bands'
            'app:manage per-app volumes'
            'preset:manage presets'
            'device:manage device assignments'
            'plot:plot frequency response'
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
                    targets=('eq:toggle equalizer bypass' 'app:toggle app volume bypass')
                    _describe 'target' targets
                fi
                ;;
            band|bands)
                if (( CURRENT == 3 )); then
                    local -a band_cmds
                    band_cmds=('list:list bands' 'remove:remove band' 'preamp:set preamp gain')
                    _describe 'band command' band_cmds
                    local -a freqs
                    freqs=(${(f)"$(_knob_band_freqs)"})
                    (( ${#freqs} )) && compadd -a freqs
                elif (( CURRENT == 4 )) && [[ "$words[3]" == "remove" ]]; then
                    local -a freqs
                    freqs=(all ${(f)"$(_knob_band_freqs)"})
                    compadd -a freqs
                fi
                ;;
            app|apps)
                if (( CURRENT == 3 )); then
                    local -a app_cmds
                    app_cmds=('list:list apps and volumes')
                    _describe 'app command' app_cmds
                    local -a apps
                    apps=(${(f)"$(_knob_app_names)"})
                    (( ${#apps} )) && compadd -a apps
                elif (( CURRENT == 4 )); then
                    local -a actions
                    actions=('mute:mute app' 'unmute:unmute app')
                    _describe 'action' actions
                fi
                ;;
            preset|presets)
                if (( CURRENT == 3 )); then
                    local -a preset_cmds
                    preset_cmds=('list:list presets' 'load:switch to preset' 'save:save current state' 'rename:rename preset' 'remove:remove preset')
                    _describe 'preset command' preset_cmds
                elif (( CURRENT == 4 )); then
                    case "$words[3]" in
                        load|remove|rename)
                            local -a presets
                            presets=(${(f)"$(_knob_preset_names)"})
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
                    devices=(${(f)"$(_knob_device_names)"})
                    compadd -Q -a devices
                elif (( CURRENT == 5 )) && [[ "$words[3]" == "assign" ]]; then
                    local -a presets
                    presets=(${(f)"$(_knob_preset_names)"})
                    compadd -a presets
                fi
                ;;
            plot)
                if (( CURRENT == 3 )); then
                    local -a presets
                    presets=(${(f)"$(_knob_preset_names)"})
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
    """##
}

func fishCompletions() -> String {
    return ##"""
    # knob completions for fish

    function __knob_band_freqs
        knob band -m 2>/dev/null | python3 -c "import sys,json;[print(str(int(b['freq']) if b['freq']==int(b['freq']) else b['freq'])+'Hz') for b in json.load(sys.stdin) if b.get('type','')!='preamp']" 2>/dev/null
    end
    function __knob_preset_names
        knob preset -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null
    end
    function __knob_device_names
        knob device -m 2>/dev/null | python3 -c "import sys,json;[print(p['name']) for p in json.load(sys.stdin)]" 2>/dev/null
    end
    function __knob_app_names
        knob app -m 2>/dev/null | python3 -c "import sys,json;[print(a['name']) for a in json.load(sys.stdin)]" 2>/dev/null
    end

    set -l commands status bypass band app preset device plot start stop restart completions help

    complete -c knob -f
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a status -d "Show status"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a bypass -d "Toggle bypass"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a band -d "Manage equalizer bands"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a app -d "Manage per-app volumes"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a preset -d "Manage presets"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a device -d "Manage devices"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a plot -d "Plot frequency response"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a start -d "Start daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a stop -d "Stop daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a restart -d "Restart daemon"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a completions -d "Generate completions"
    complete -c knob -n "not __fish_seen_subcommand_from $commands" -a help -d "Show help"

    complete -c knob -n "__fish_seen_subcommand_from bypass" -a "eq" -d "Toggle equalizer bypass"
    complete -c knob -n "__fish_seen_subcommand_from bypass" -a "app" -d "Toggle app volume bypass"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "list" -d "List bands"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "remove" -d "Remove band"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "preamp" -d "Set preamp gain"
    complete -c knob -n "__fish_seen_subcommand_from band bands" -a "(__knob_band_freqs)"
    complete -c knob -n "__fish_seen_subcommand_from app apps" -a "list" -d "List apps and volumes"
    complete -c knob -n "__fish_seen_subcommand_from app apps" -a "(__knob_app_names)"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "list" -d "List presets"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "load" -d "Switch to preset"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "save" -d "Save current state"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "rename" -d "Rename preset"
    complete -c knob -n "__fish_seen_subcommand_from preset presets" -a "remove" -d "Remove preset"
    complete -c knob -n "__fish_seen_subcommand_from device devices" -a "list" -d "List devices"
    complete -c knob -n "__fish_seen_subcommand_from device devices" -a "assign" -d "Assign or clear device preset"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "bash" -d "Bash completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "zsh" -d "Zsh completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "fish" -d "Fish completions"
    complete -c knob -n "__fish_seen_subcommand_from completions" -a "nu" -d "Nushell completions"
    """##
}

func nushellCompletions() -> String {
    return ##"""
    def "nu-complete knob" [context: string, position: int] {
        let ctx = ($context | str substring ..$position)
        let has_space = ($ctx | str ends-with ' ')
        let tokens = ($ctx | str trim | split row -r '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)' | each { str replace -a '"' '' })
        let arg_pos = if $has_space { $tokens | length } else { ($tokens | length) - 1 }

        # --- inline helpers using -m JSON output ---
        let q = { |val| if ($val | str contains ' ') { $"\"($val)\"" } else { $val } }

        let get_bands = { ||
            let j = (do { ^knob band -m 2>/dev/null } | complete).stdout
            try { $j | from json } catch { [] } | where ($it.type? | default '') != 'preamp'
        }

        let get_apps = { ||
            let j = (do { ^knob app -m 2>/dev/null } | complete).stdout
            try { $j | from json } catch { [] }
        }

        let get_presets = { ||
            let j = (do { ^knob preset -m 2>/dev/null } | complete).stdout
            try { $j | from json } catch { [] } | each { |p|
                let desc = if ($p.active? | default false) { $"($p.bands) bands *" } else { $"($p.bands) bands" }
                {value: (do $q $p.name), description: $desc}
            }
        }

        let get_devices = { ||
            let j = (do { ^knob device -m 2>/dev/null } | complete).stdout
            try { $j | from json } catch { [] } | each { |d|
                let active = ($d.active? | default false)
                let preset = ($d.preset? | default '')
                let desc = (if $active and $preset != '' { $"preset: ($preset) *" }
                    else if $preset != '' { $"preset: ($preset)" }
                    else if $active { "*" }
                    else { "" })
                {value: (do $q $d.name), description: $desc}
            }
        }

        # --- position 1: top-level commands ---
        if $arg_pos <= 1 {
            return [{value: status, description: "show status"}
                    {value: bypass, description: "toggle bypass"}
                    {value: band, description: "manage equalizer bands"}
                    {value: app, description: "manage per-app volumes"}
                    {value: preset, description: "manage presets"}
                    {value: device, description: "manage device assignments"}
                    {value: plot, description: "plot frequency response"}
                    {value: start, description: "start daemon"}
                    {value: stop, description: "stop daemon"}
                    {value: restart, description: "restart daemon"}
                    {value: completions, description: "generate shell completions"}
                    {value: help, description: "show help"}]
        }

        let cmd = ($tokens | get 1)

        # --- position 2: subcommands ---
        if $arg_pos == 2 {
            match $cmd {
                bypass => {
                    [{value: eq, description: "toggle equalizer bypass"}
                     {value: app, description: "toggle app volume bypass"}]
                }
                band | bands => {
                    let bands = (do $get_bands)
                    let items = ($bands | each { |b|
                        let f = if ($b.freq | math round) == $b.freq { $"($b.freq | into int)Hz" } else { $"($b.freq)Hz" }
                        let g = if $b.gain >= 0 { $"+($b.gain | math round --precision 1)dB" } else { $"($b.gain | math round --precision 1)dB" }
                        {value: $f, description: $"($g) ($b.q)Q ($b.type)"}
                    })
                    [{value: preamp, description: "set preamp gain"}
                     {value: remove, description: "remove band"}
                     ...$items]
                }
                app | apps => {
                    let apps = (do $get_apps)
                    let vol_str = { |a| $a.volume? | default '' }
                    let items = ($apps | each { |a| {value: (do $q $a.name), description: (do $vol_str $a)} })
                    [{value: list, description: "list apps and volumes"}
                     ...$items]
                }
                preset | presets => {
                    [{value: list, description: "list presets"}
                     {value: load, description: "switch to preset"}
                     {value: save, description: "save current as preset"}
                     {value: rename, description: "rename preset"}
                     {value: remove, description: "remove preset"}]
                }
                device | devices => {
                    [{value: list, description: "list devices"}
                     {value: assign, description: "assign or clear device preset"}]
                }
                plot => { do $get_presets }
                completions => {
                    [{value: bash, description: "bash completions"}
                     {value: zsh, description: "zsh completions"}
                     {value: fish, description: "fish completions"}
                     {value: nu, description: "nushell completions"}]
                }
                _ => { [] }
            }
        } else if $arg_pos == 3 {
            # --- position 3 ---
            let sub = ($tokens | get -o 2 | default '')
            # Helper: match freq token (e.g., "1262Hz") to JSON band by numeric freq
            let find_band = { |tok|
                let hz = ($tok | str replace -r '(?i)hz' '' | into float)
                do $get_bands | where { |b| ($b.freq - $hz | math abs) < 0.5 } | first
            }
            let fmt_gain = { |g| if $g >= 0 { $"+($g | math round --precision 1)dB" } else { $"($g | math round --precision 1)dB" } }
            match $cmd {
                band | bands => {
                    if $sub == "remove" {
                        let bands = (do $get_bands)
                        let freqs = ($bands | each { |b|
                            let f = if ($b.freq | math round) == $b.freq { $"($b.freq | into int)Hz" } else { $"($b.freq)Hz" }
                            {value: $f}
                        })
                        [{value: all, description: "remove all bands"} ...$freqs]
                    } else {
                        let band = (try { do $find_band $sub } catch { null })
                        if $band != null {
                            [{value: (do $fmt_gain $band.gain), description: "gain"}]
                        } else if $sub == "preamp" {
                            let all = (do { ^knob band -m 2>/dev/null } | complete).stdout
                            let preamp = (try { $all | from json } catch { [] } | where ($it.type? | default '') == 'preamp' | first)
                            if $preamp != null { [{value: (do $fmt_gain $preamp.gain), description: "current preamp"}] } else { [] }
                        } else { [] }
                    }
                }
                app | apps => {
                    # After app name, offer mute/unmute/volume
                    [{value: mute, description: "mute app"}
                     {value: unmute, description: "unmute app"}]
                }
                preset | presets => {
                    if $sub in [load remove rename] { do $get_presets } else { [] }
                }
                device | devices => {
                    if $sub == "assign" { do $get_devices } else { [] }
                }
                _ => { [] }
            }
        } else if $arg_pos == 4 {
            # --- position 4 ---
            let find_band = { |tok|
                let hz = ($tok | str replace -r '(?i)hz' '' | into float)
                do $get_bands | where { |b| ($b.freq - $hz | math abs) < 0.5 } | first
            }
            match $cmd {
                band | bands => {
                    let freq = ($tokens | get -o 2 | default '')
                    let band = (try { do $find_band $freq } catch { null })
                    if $band != null {
                        [{value: $"($band.q)Q", description: "Q factor"}]
                    } else { [] }
                }
                device | devices => {
                    let sub = ($tokens | get -o 2 | default '')
                    if $sub == "assign" { do $get_presets } else { [] }
                }
                _ => { [] }
            }
        } else if $arg_pos == 5 {
            # --- position 5 ---
            let find_band = { |tok|
                let hz = ($tok | str replace -r '(?i)hz' '' | into float)
                do $get_bands | where { |b| ($b.freq - $hz | math abs) < 0.5 } | first
            }
            match $cmd {
                band | bands => {
                    let freq = ($tokens | get -o 2 | default '')
                    let band = (try { do $find_band $freq } catch { null })
                    if $band != null {
                        [{value: $band.type, description: "filter type"}]
                    } else { [] }
                }
                _ => { [] }
            }
        } else { [] }
    }

    export extern "knob" [
        ...args: string@"nu-complete knob"
    ]
    """##
}

// MARK: - Plot

func handlePlot(_ args: [String]) throws {
    let config = try loadConfig()

    let preset: Preset
    if let name = args.first {
        if name == "flat" {
            preset = Preset()
        } else {
            guard let p = config.presets[name] else { fail("preset '\(name)' not found.") }
            preset = p
        }
    } else {
        preset = config.activePresetValue()
    }

    // Get terminal width
    var ws = winsize()
    let termWidth: Int
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
        termWidth = Int(ws.ws_col)
    } else {
        termWidth = 80
    }

    // Layout: left label (7 chars) + plot area + right margin (1)
    let labelWidth = 7
    let plotWidth = termWidth - labelWidth - 1
    guard plotWidth > 20 else { fail("terminal too narrow") }

    // Braille: each cell is 2 dots wide, 4 dots tall
    let dotsX = plotWidth * 2
    let plotRows = 12
    let dotsY = plotRows * 4

    // Frequency range: 20Hz to 20kHz, log-scaled
    let fMin = log10(20.0)
    let fMax = log10(20000.0)

    // Sample rate for coefficient computation (doesn't matter much for response shape,
    // but needs to be high enough that 20kHz is well below Nyquist)
    let sampleRate = 96000.0

    // Compute magnitude response at each horizontal dot position
    var magnitudeDB = [Double](repeating: 0.0, count: dotsX)

    for x in 0..<dotsX {
        let freq = pow(10.0, fMin + (fMax - fMin) * Double(x) / Double(dotsX - 1))

        // Start with preamp
        var totalDB = preset.preampGainDB

        // Add each band's contribution
        for band in preset.bands {
            let omega = 2.0 * Double.pi * band.frequency / sampleRate
            let sinW = sin(omega)
            let cosW = cos(omega)
            let alpha = sinW / (2.0 * band.q)
            let A = pow(10.0, band.gainDB / 40.0)

            var b0, b1, b2, a0, a1, a2: Double

            switch band.type {
            case .peaking:
                b0 = 1.0 + alpha * A; b1 = -2.0 * cosW; b2 = 1.0 - alpha * A
                a0 = 1.0 + alpha / A; a1 = -2.0 * cosW; a2 = 1.0 - alpha / A
            case .lowShelf:
                let t = 2.0 * sqrt(A) * alpha
                b0 = A * ((A+1) - (A-1)*cosW + t); b1 = 2*A*((A-1) - (A+1)*cosW); b2 = A*((A+1) - (A-1)*cosW - t)
                a0 = (A+1) + (A-1)*cosW + t; a1 = -2*((A-1) + (A+1)*cosW); a2 = (A+1) + (A-1)*cosW - t
            case .highShelf:
                let t = 2.0 * sqrt(A) * alpha
                b0 = A * ((A+1) + (A-1)*cosW + t); b1 = -2*A*((A-1) + (A+1)*cosW); b2 = A*((A+1) + (A-1)*cosW - t)
                a0 = (A+1) - (A-1)*cosW + t; a1 = 2*((A-1) - (A+1)*cosW); a2 = (A+1) - (A-1)*cosW - t
            case .lowpass:
                b0 = (1-cosW)/2; b1 = 1-cosW; b2 = (1-cosW)/2
                a0 = 1+alpha; a1 = -2*cosW; a2 = 1-alpha
            case .highpass:
                b0 = (1+cosW)/2; b1 = -(1+cosW); b2 = (1+cosW)/2
                a0 = 1+alpha; a1 = -2*cosW; a2 = 1-alpha
            }

            // Evaluate H(e^jw) at the target frequency
            let w = 2.0 * Double.pi * freq / sampleRate
            let cw = cos(w)
            let cw2 = cos(2.0 * w)
            let sw = sin(w)
            let sw2 = sin(2.0 * w)

            let numRe = b0/a0 + b1/a0 * cw + b2/a0 * cw2
            let numIm = -(b1/a0 * sw + b2/a0 * sw2)
            let denRe = 1.0 + a1/a0 * cw + a2/a0 * cw2
            let denIm = -(a1/a0 * sw + a2/a0 * sw2)

            let numMag2 = numRe * numRe + numIm * numIm
            let denMag2 = denRe * denRe + denIm * denIm

            if denMag2 > 0 {
                totalDB += 10.0 * log10(numMag2 / denMag2)
            }
        }

        magnitudeDB[x] = totalDB
    }

    // Auto-scale Y axis with 15% padding
    let minDB = magnitudeDB.min()!
    let maxDB = magnitudeDB.max()!
    let range = max(maxDB - minDB, 1.0)
    let padding = range * 0.15
    let yMin = minDB - padding
    let yMax = maxDB + padding

    // If the range is small (flat-ish), center around 0dB with at least +-3dB
    let (plotYMin, plotYMax): (Double, Double)
    if yMax - yMin < 6.0 {
        let center = (yMin + yMax) / 2.0
        plotYMin = center - 3.0
        plotYMax = center + 3.0
    } else {
        plotYMin = yMin
        plotYMax = yMax
    }

    // Build braille grid
    var grid = [[Bool]](repeating: [Bool](repeating: false, count: dotsX), count: dotsY)

    for x in 0..<dotsX {
        let normalized = (magnitudeDB[x] - plotYMin) / (plotYMax - plotYMin)
        let y = Int((normalized * Double(dotsY - 1)).rounded())
        if y >= 0 && y < dotsY {
            grid[dotsY - 1 - y][x] = true

            // Fill vertically toward the 0dB line for visual weight
            let zeroY = Int(((0.0 - plotYMin) / (plotYMax - plotYMin) * Double(dotsY - 1)).rounded())
            let zeroRow = dotsY - 1 - zeroY
            let curRow = dotsY - 1 - y
            // Only fill if we're close (within 2 dots) for a subtle thickness
        }
    }

    // Also draw the 0dB baseline as dots
    let zeroNorm = (0.0 - plotYMin) / (plotYMax - plotYMin)
    let zeroRow = dotsY - 1 - Int((zeroNorm * Double(dotsY - 1)).rounded())
    if zeroRow >= 0 && zeroRow < dotsY {
        for x in stride(from: 0, to: dotsX, by: 4) {
            grid[zeroRow][x] = true
        }
    }

    // Render braille characters
    // Braille Unicode: U+2800 + dot pattern
    // Dot positions in a 2x4 cell:
    //   0 3
    //   1 4
    //   2 5
    //   6 7
    var output = ""
    for row in stride(from: 0, to: dotsY, by: 4) {
        // Y label for this row (top of cell = highest dB)
        let rowDB = plotYMax - (plotYMax - plotYMin) * Double(row) / Double(dotsY)
        let label = String(format: "%+5.1f ", rowDB)
        output += label

        for col in stride(from: 0, to: dotsX, by: 2) {
            var codePoint: UInt32 = 0x2800
            // Map grid positions to braille dot bits
            for dy in 0..<4 {
                for dx in 0..<2 {
                    let gy = row + dy
                    let gx = col + dx
                    if gy < dotsY && gx < dotsX && grid[gy][gx] {
                        let bit: UInt32
                        switch (dx, dy) {
                        case (0, 0): bit = 0
                        case (0, 1): bit = 1
                        case (0, 2): bit = 2
                        case (1, 0): bit = 3
                        case (1, 1): bit = 4
                        case (1, 2): bit = 5
                        case (0, 3): bit = 6
                        case (1, 3): bit = 7
                        default: bit = 0
                        }
                        codePoint |= 1 << bit
                    }
                }
            }
            output += String(UnicodeScalar(codePoint)!)
        }
        output += "\n"
    }

    // Frequency axis labels
    let freqLabels: [(Double, String)] = [
        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k")
    ]

    var axisLine = String(repeating: " ", count: labelWidth)
    var axisChars = [Character](repeating: " ", count: plotWidth)

    for (freq, label) in freqLabels {
        var pos = Int((log10(freq) - fMin) / (fMax - fMin) * Double(plotWidth - 1))
        // Right-align if it would overflow
        if pos + label.count > plotWidth { pos = plotWidth - label.count }
        if pos >= 0 {
            for (i, ch) in label.enumerated() {
                axisChars[pos + i] = ch
            }
        }
    }
    axisLine += String(axisChars)
    output += axisLine

    print(output)
}

// MARK: - Usage

func printUsage() {
    print("""
    knob 0.1.4

    parametric equalizer and per-app volume control for mac

    ---

    usage:

    knob
    | [  | status ]                 show status
    | help                          show this help page
    | [ start | stop | restart ]    control knob daemon

    knob bypass
    | [  ]                          toggle equalizer and app volume bypass
    | eq                            toggle equalizer bypass only
    | [ app | apps ]                toggle app volume bypass only

    knob preset
    | [  | list ]                   list presets (* = active)
    | load <name>                   switch to preset
    | save <name>                   save current state as preset
    | rename <old> <new>            rename preset
    | [ remove | delete ] <name>    remove preset

    knob band
    | [  | list ]                   list bands in active preset
    | [ pre | preamp ] <gain>       set preamp gain
    | <freq> [gain] [q] [type]      add or update band at frequency
    | remove <freq>                 remove band at frequency
    | remove all                    remove all bands

    knob app
    | [  | list ]                   list apps and volume overrides
    | <app name> <volume>           set per-app volume (fuzzy match)
    | <app name> mute               mute app
    | <app name> unmute             unmute app

    knob device
    | [  | list ]                   list output devices and assignments
    | assign <device> <preset>      assign preset to device
    | assign <device>               clear device assignment

    knob plot
    | [  ]                          plot current preset's frequency response
    | <preset name>                 plot a specific preset's frequency response

    knob completions <shell>        generate completions (bash/zsh/fish/nu)

    append -m to any list command for machine-readable json output.

    ---

    band parameters are positional and all optional except frequency.
    labeled forms (1khz, +3db, q=1.4, etc) can appear in any order.

    freq   1k, 1000, 1khz, 0.3k, 300hz           (k = x1000, hz optional)
    gain   +3, -3, 3, 3db                        (sign or db suffix)
    q      1.4, q=1.4, 1.4q                      (default: 1.0 peak, 0.707 shelf)
    type   peaking (p), lowshelf (ls), highshelf (hs), lowpass (lp), highpass (hp)
           any unique prefix works too: peak, lows, highp, ...

    if a band at that frequency exists, only provided params are updated.
    if not, a new band is created (gain required).

    ---

    examples:

    knob                              show status
    knob start                        start the daemon

    knob band preamp -2               set preamp to -2dB
    knob band 300 -3                  add peaking band at 300Hz, -3dB
    knob band 300 -2.5                update gain (keep Q, type)
    knob band 4khz +2.1db             labeled gain
    knob band 6200hz 3.2db 0.63q hs   fully labeled, any order
    knob band list                    list all bands

    knob preset save testing          save current preset as "testing"
    knob preset list                  list all presets
    knob preset load flat             switch to flat preset

    knob device list                  list devices and assignments
    knob device assign buds testing   auto-load "testing" on buds

    knob app list                     list apps and volumes
    knob app music 0.5                set music to 50%
    knob app com.apple.Music 0.6      use bundle id directly
    knob app music mute               mute music
    knob app music unmute             unmute music

    knob bypass app                   toggle app volume bypass
    knob bypass eq                    toggle equalizer bypass
    """)
}
