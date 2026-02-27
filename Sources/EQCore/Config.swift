import Foundation

public enum FilterType: String, Codable, Sendable {
    case peaking
    case lowShelf = "low_shelf"
    case highShelf = "high_shelf"
    case lowpass
    case highpass
}

public struct Band: Codable, Sendable {
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(type: FilterType, frequency: Double, gainDB: Double, q: Double) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    enum CodingKeys: String, CodingKey {
        case type
        case frequency
        case gainDB = "gain_db"
        case q
    }
}

public struct Preset: Codable, Sendable {
    public var preampGainDB: Double
    public var bands: [Band]

    public init(preampGainDB: Double = 0, bands: [Band] = []) {
        self.preampGainDB = preampGainDB
        self.bands = bands
    }

    enum CodingKeys: String, CodingKey {
        case preampGainDB = "preamp_gain_db"
        case bands
    }
}

public struct EQConfig: Codable, Sendable {
    public var activePreset: String
    public var presets: [String: Preset]
    public var devicePresets: [String: String]
    public var appVolumes: [String: Double]
    public var eqEnabled: Bool
    public var appVolumesBypassed: Bool

    public init(
        activePreset: String = "flat",
        presets: [String: Preset] = [:],
        devicePresets: [String: String] = [:],
        appVolumes: [String: Double] = [:],
        eqEnabled: Bool = true,
        appVolumesBypassed: Bool = false
    ) {
        self.activePreset = activePreset
        self.presets = presets
        self.devicePresets = devicePresets
        self.appVolumes = appVolumes
        self.eqEnabled = eqEnabled
        self.appVolumesBypassed = appVolumesBypassed
    }

    enum CodingKeys: String, CodingKey {
        case activePreset = "active_preset"
        case presets
        case devicePresets = "device_presets"
        case appVolumes = "app_volumes"
        case eqEnabled = "eq_enabled"
        case appVolumesBypassed = "app_volumes_bypassed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activePreset = try container.decode(String.self, forKey: .activePreset)
        presets = try container.decode([String: Preset].self, forKey: .presets)
        devicePresets = try container.decodeIfPresent([String: String].self, forKey: .devicePresets) ?? [:]
        appVolumes = try container.decodeIfPresent([String: Double].self, forKey: .appVolumes) ?? [:]
        eqEnabled = try container.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
        appVolumesBypassed = try container.decodeIfPresent(Bool.self, forKey: .appVolumesBypassed) ?? false
    }

    public func activePresetValue() -> Preset {
        if activePreset == "flat" { return Preset() }
        return presets[activePreset] ?? Preset()
    }
}
