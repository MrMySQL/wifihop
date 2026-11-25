import Foundation

/// How eagerly to leave a weakening network. Homes differ: thick walls make
/// the signal fall off a cliff, open plans make it fade slowly.
public enum Sensitivity: String, CaseIterable {
    case sooner, balanced, later

    public var settings: RoamSettings {
        var s = RoamSettings()
        switch self {
        case .sooner:
            s.weakRSSI = -65
            s.minImprovement = 8
        case .balanced:
            break
        case .later:
            s.weakRSSI = -75
            s.minImprovement = 12
        }
        return s
    }
}

/// A plain-words reading of a signal strength in dBm.
public enum SignalQuality: Equatable {
    case strong, good, weak

    public init(rssi: Int) {
        if rssi >= -60 {
            self = .strong
        } else if rssi >= -70 {
            self = .good
        } else {
            self = .weak
        }
    }
}

/// One line of the "which networks are yours" list.
public struct SetupRow: Equatable {
    public let ssid: String
    /// Signal in dBm, or nil when the network is not in range.
    public let rssi: Int?
    public let selected: Bool

    public init(ssid: String, rssi: Int?, selected: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.selected = selected
    }
}

/// Builds the setup list: networks in range first with the strongest on top,
/// then the rest by name. Out-of-range networks are left out unless asked for,
/// since a Mac that has travelled remembers hundreds. A selected network is
/// always listed, so it can be unticked even when far away or forgotten.
public func setupRows(
    saved: [String], selected: [String], inRange: [String: Int], showOutOfRange: Bool
) -> [SetupRow] {
    var names: [String] = []
    for name in saved + selected where !names.contains(name) {
        names.append(name)
    }
    let rows = names
        .map { SetupRow(ssid: $0, rssi: inRange[$0], selected: selected.contains($0)) }
        .filter { $0.rssi != nil || $0.selected || showOutOfRange }
    let near = rows.filter { $0.rssi != nil }.sorted { $0.rssi! > $1.rssi! }
    let far = rows.filter { $0.rssi == nil }
        .sorted { $0.ssid.localizedCaseInsensitiveCompare($1.ssid) == .orderedAscending }
    return near + far
}
