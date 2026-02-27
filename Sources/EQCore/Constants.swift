import Foundation

public enum EQConstants {
    public static let configDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/knob"
    }()

    public static var configPath: String { "\(configDir)/config.json" }

    public static let launchdLabel = "com.csutora.knob"

    public static let maxBands = 16

    public static let driverDeviceUID = "com.csutora.knob.loopback"
    public static let pidPath = "/tmp/knob.pid"
    public static var statePath: String { "\(configDir)/state.json" }
}
