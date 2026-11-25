import Foundation
import RoamCore
import Security

/// Appends timestamped lines to ~/Library/Logs/WiFiHop.log.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WiFiHop.log")
    private static let queue = DispatchQueue(label: "local.wifihop.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Settings kept in UserDefaults.
final class Prefs {
    private let store = UserDefaults.standard

    /// The networks to switch between, as chosen in Settings.
    var managed: [String] {
        get { store.stringArray(forKey: "managedSSIDs") ?? [] }
        set { store.set(newValue, forKey: "managedSSIDs") }
    }

    var paused: Bool {
        get { store.bool(forKey: "paused") }
        set { store.set(newValue, forKey: "paused") }
    }

    var hasLaunchedBefore: Bool {
        get { store.bool(forKey: "hasLaunchedBefore") }
        set { store.set(newValue, forKey: "hasLaunchedBefore") }
    }

    var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: store.string(forKey: "sensitivity") ?? "") ?? .balanced }
        set { store.set(newValue.rawValue, forKey: "sensitivity") }
    }

    /// The chosen preset, with any single value overridden from Terminal, e.g.
    /// `defaults write local.wifihop weakRSSI -int -68`.
    var settings: RoamSettings {
        var s = sensitivity.settings
        if let v = store.object(forKey: "weakRSSI") as? Int { s.weakRSSI = v }
        if let v = store.object(forKey: "weakSamples") as? Int { s.weakSamplesNeeded = v }
        if let v = store.object(forKey: "minImprovement") as? Int { s.minImprovement = v }
        if let v = store.object(forKey: "switchCooldown") as? Double { s.switchCooldown = v }
        if let v = store.object(forKey: "rescanInterval") as? Double { s.rescanInterval = v }
        if let v = store.object(forKey: "failedJoinBackoff") as? Double { s.failedJoinBackoff = v }
        return s
    }
}

/// Wi-Fi passwords in the login Keychain, one item per network.
/// macOS keeps its own copies in the System keychain, but will not use them
/// on behalf of another app, so WiFiHop needs its own.
final class PasswordStore {
    private let service = "WiFiHop"

    private func query(_ ssid: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
        ]
    }

    func has(_ ssid: String) -> Bool {
        SecItemCopyMatching(query(ssid) as CFDictionary, nil) == errSecSuccess
    }

    func get(_ ssid: String) -> String? {
        var q = query(ssid)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any existing item rather than updating it. An item written by
    /// an earlier build of the app belongs to that build, and macOS would stop
    /// to ask for permission before letting this one change it.
    @discardableResult
    func set(_ password: String, for ssid: String) -> Bool {
        SecItemDelete(query(ssid) as CFDictionary)
        var q = query(ssid)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "WiFiHop: \(ssid)"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func remove(_ ssid: String) {
        SecItemDelete(query(ssid) as CFDictionary)
    }
}
