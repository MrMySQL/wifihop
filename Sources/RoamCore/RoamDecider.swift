import Foundation

public struct RoamSettings {
    /// Signal below this (in dBm) counts as weak.
    public var weakRSSI = -70
    /// How many weak readings in a row before looking for a better network.
    public var weakSamplesNeeded = 3
    /// Another network must be at least this many dB stronger to be worth a switch.
    public var minImprovement = 10
    /// After a switch, leave the connection alone for this long.
    public var switchCooldown: TimeInterval = 60
    /// After a scan that found nothing better, wait this long before scanning again.
    public var rescanInterval: TimeInterval = 30
    /// A network that refused a join is left alone for this long.
    public var failedJoinBackoff: TimeInterval = 600

    public init() {}
}

/// A network found by a scan.
public struct SeenNetwork: Equatable {
    public let ssid: String
    public let rssi: Int
    public let channel: Int

    public init(ssid: String, rssi: Int, channel: Int) {
        self.ssid = ssid
        self.rssi = rssi
        self.channel = channel
    }
}

/// Decides when to look for a better network and which one to move to.
/// Holds no Wi-Fi state of its own, so it can be tested without a radio.
public struct RoamDecider {
    public var settings: RoamSettings
    private var weakSamples = 0
    private var quietUntil = Date.distantPast
    private var blockedUntil: [String: Date] = [:]

    public init(settings: RoamSettings = RoamSettings()) {
        self.settings = settings
    }

    /// Feed one signal reading. Returns true when it is time to scan.
    /// An RSSI of 0 means the Mac is not connected, which macOS handles itself.
    public mutating func shouldScan(rssi: Int, now: Date) -> Bool {
        guard rssi != 0, rssi < settings.weakRSSI else {
            weakSamples = 0
            return false
        }
        weakSamples += 1
        return weakSamples >= settings.weakSamplesNeeded && now >= quietUntil
    }

    /// The network to move to, or nil to stay put.
    public func target(currentSSID: String, currentRSSI: Int, seen: [SeenNetwork], now: Date) -> String? {
        let best = seen
            .filter { $0.ssid != currentSSID && now >= (blockedUntil[$0.ssid] ?? .distantPast) }
            .max { $0.rssi < $1.rssi }
        guard let best, best.rssi - currentRSSI >= settings.minImprovement else { return nil }
        return best.ssid
    }

    public mutating func noteSwitched(at now: Date) {
        weakSamples = 0
        quietUntil = now.addingTimeInterval(settings.switchCooldown)
    }

    /// A join that failed costs a dropped connection, so back off like a switch
    /// and stop offering that network for a while.
    public mutating func noteJoinFailed(ssid: String, at now: Date) {
        blockedUntil[ssid] = now.addingTimeInterval(settings.failedJoinBackoff)
        noteSwitched(at: now)
    }

    public mutating func clearFailure(ssid: String) {
        blockedUntil[ssid] = nil
    }

    public mutating func noteScanned(at now: Date) {
        quietUntil = max(quietUntil, now.addingTimeInterval(settings.rescanInterval))
    }
}

/// Works out which network the Mac is on. macOS only reports the name to apps
/// with Location permission; without it, fall back to the one scanned network
/// that sits on the channel the radio is tuned to and whose signal matches.
/// The signal check keeps a hotspot on a shared channel from being mistaken
/// for a router.
public func inferCurrentSSID(reported: String?, channel: Int?, rssi: Int, seen: [SeenNetwork]) -> String? {
    if let reported { return reported }
    guard let channel else { return nil }
    let matching = Set(seen.filter { $0.channel == channel && abs($0.rssi - rssi) <= 15 }.map(\.ssid))
    return matching.count == 1 ? matching.first : nil
}
