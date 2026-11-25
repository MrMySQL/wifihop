import CoreWLAN
import Foundation
import RoamCore

/// Thin wrapper over CoreWLAN. Use from one queue only.
final class WiFiService {
    struct Reading {
        let powerOn: Bool
        let rssi: Int
        let channel: Int?
        let reportedSSID: String?
    }

    private let client = CWWiFiClient.shared()

    func reading() -> Reading? {
        guard let iface = client.interface() else { return nil }
        return Reading(
            powerOn: iface.powerOn(),
            rssi: iface.rssiValue(),
            channel: iface.wlanChannel()?.channelNumber,
            reportedSSID: iface.ssid()
        )
    }

    /// Looks for each named network. Asking by name works without Location
    /// permission, which a general scan does not.
    func scan(for ssids: [String]) -> [SeenNetwork] {
        guard let iface = client.interface() else { return [] }
        var seen: [SeenNetwork] = []
        for ssid in ssids {
            do {
                let found = try iface.scanForNetworks(withName: ssid)
                for network in found {
                    seen.append(SeenNetwork(
                        ssid: ssid,
                        rssi: network.rssiValue,
                        channel: network.wlanChannel?.channelNumber ?? 0
                    ))
                }
            } catch {
                Log.write("Scan for \(ssid) failed: \(error.localizedDescription)")
            }
        }
        return seen
    }

    /// Joins a network through Apple's `networksetup` tool. macOS refuses the
    /// CoreWLAN join call from an app that is not signed by a registered
    /// developer, and it will not reuse its own saved password for the tool,
    /// so the password has to be passed along.
    func join(_ ssid: String, password: String) throws {
        // The tool runs its own scan and can miss a network ours just saw, so
        // give it a few tries. A miss leaves the current connection untouched.
        for _ in 1...3 {
            // The tool exits 0 even when the join fails; it is silent only on success.
            let output = try Self.networksetup(["-setairportnetwork", interfaceName, ssid, password])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty { return }
            if output.contains("Could not find network") { continue }
            let reason = output.split(separator: "\n").first.map(String.init) ?? output
            throw JoinError(reason: reason, networkNotFound: false)
        }
        throw JoinError(reason: "Could not find network \(ssid)", networkNotFound: true)
    }

    /// Names of the networks this Mac has joined before. CoreWLAN returns an
    /// empty list to an app like this one, so ask Apple's `networksetup` tool.
    func savedSSIDs() -> [String] {
        let output = (try? Self.networksetup(["-listpreferredwirelessnetworks", interfaceName])) ?? ""
        // The first line is a heading; each network follows on a tab-indented line.
        return output.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Strongest signal of each of the given networks that is in range right now.
    func survey(_ ssids: [String]) -> [String: Int] {
        guard let iface = client.interface() else { return [:] }
        // One general scan refreshes the system's cache, which makes the
        // by-name lookups below quick even with a long list of saved networks.
        _ = try? iface.scanForNetworks(withName: nil)
        var found: [String: Int] = [:]
        for ssid in ssids {
            guard let results = try? iface.scanForNetworks(withName: ssid),
                  let best = results.map(\.rssiValue).max() else { continue }
            found[ssid] = best
        }
        return found
    }

    private var interfaceName: String {
        client.interface()?.interfaceName ?? "en0"
    }

    /// Runs `networksetup` and returns what it printed.
    private static func networksetup(_ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct JoinError: LocalizedError {
    let reason: String
    /// The network never showed up, so no join was attempted and nothing dropped.
    let networkNotFound: Bool
    var errorDescription: String? { reason }
}

/// What the menu shows.
struct Snapshot {
    var connected = false
    var ssid: String?
    var rssi = 0
    /// Strongest signal last seen for each managed network.
    var seen: [String: Int] = [:]
    var lastEvent: String?
    /// A switch is waiting on this network's password.
    var needsPassword: String?
    /// How many networks are ticked in Settings. Fewer than two leaves nothing to switch between.
    var managedCount = 0
}

/// Samples the signal on a timer and switches networks when the decider says so.
final class Roamer {
    static let interval: TimeInterval = 10

    var onUpdate: ((Snapshot) -> Void)?

    private let wifi = WiFiService()
    private let prefs: Prefs
    private let passwords: PasswordStore
    private let queue = DispatchQueue(label: "local.wifihop.roamer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var decider = RoamDecider()
    private var snapshot = Snapshot()
    private var currentSSID: String?
    /// The channel the current network was last identified on. A change of
    /// channel means the Mac moved to another network.
    private var identifiedChannel: Int?
    private var lastIdentifyAttempt = Date.distantPast
    /// While the current network is unknown, look again this often. A scan can
    /// come back empty when the radio is busy.
    private static let identifyRetry: TimeInterval = 120

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(prefs: Prefs, passwords: PasswordStore) {
        self.prefs = prefs
        self.passwords = passwords
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick(forceScan: false) }
        t.resume()
        timer = t
    }

    /// Call after the list of networks changes.
    func networksChanged() {
        queue.async {
            self.snapshot.needsPassword = nil
            self.snapshot.seen = [:]
            self.tick(forceScan: true)
        }
    }

    func passwordChanged(for ssid: String) {
        queue.async {
            self.decider.clearFailure(ssid: ssid)
            if self.snapshot.needsPassword == ssid { self.snapshot.needsPassword = nil }
            self.publish()
        }
    }

    /// Finds the networks this Mac knows and which of them are in range.
    func survey(_ completion: @escaping (_ saved: [String], _ inRange: [String: Int]) -> Void) {
        queue.async {
            let saved = self.wifi.savedSSIDs()
            let inRange = self.wifi.survey(Array(Set(saved + self.prefs.managed)))
            onMain { completion(saved, inRange) }
        }
    }

    private func publish() {
        onUpdate?(snapshot)
    }

    private func tick(forceScan: Bool) {
        decider.settings = prefs.settings
        let now = Date()
        let managed = prefs.managed
        snapshot.managedCount = managed.count

        guard let reading = wifi.reading(), reading.powerOn, reading.rssi != 0 else {
            _ = decider.shouldScan(rssi: 0, now: now)
            currentSSID = nil
            identifiedChannel = nil
            snapshot.connected = false
            snapshot.ssid = nil
            snapshot.rssi = 0
            publish()
            return
        }

        if let reported = reading.reportedSSID {
            currentSSID = reported
        } else if reading.channel != identifiedChannel {
            currentSSID = nil
        }
        snapshot.connected = true
        snapshot.ssid = currentSSID
        snapshot.rssi = reading.rssi

        // While paused, feed a "not connected" reading so no weak streak builds up.
        let weak = decider.shouldScan(rssi: prefs.paused ? 0 : reading.rssi, now: now)
        let unidentified = currentSSID == nil
            && (reading.channel != identifiedChannel
                || now.timeIntervalSince(lastIdentifyAttempt) >= Self.identifyRetry)
        guard !managed.isEmpty, weak || unidentified || forceScan else {
            publish()
            return
        }

        let seen = wifi.scan(for: managed)
        lastIdentifyAttempt = Date()
        if weak { decider.noteScanned(at: Date()) }

        // The scan takes a few seconds, so compare against a fresh reading.
        let fresh = wifi.reading() ?? reading
        currentSSID = inferCurrentSSID(
            reported: fresh.reportedSSID, channel: fresh.channel, rssi: fresh.rssi, seen: seen)
        identifiedChannel = fresh.channel
        snapshot.ssid = currentSSID
        snapshot.rssi = fresh.rssi
        snapshot.seen = Dictionary(seen.map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)
        let summary = snapshot.seen.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")

        guard weak else {
            Log.write("Scan: on \(currentSSID ?? "another network") at \(fresh.rssi) dBm. Seen: \(summary)")
            publish()
            return
        }
        guard let current = currentSSID, managed.contains(current) else {
            Log.write("Weak signal (\(fresh.rssi) dBm) but not on one of your networks, leaving it alone. Seen: \(summary)")
            publish()
            return
        }
        guard let target = decider.target(
            currentSSID: current, currentRSSI: fresh.rssi, seen: seen, now: Date()) else {
            Log.write("Weak signal on \(current) (\(fresh.rssi) dBm), nothing enough stronger. Seen: \(summary)")
            publish()
            return
        }
        guard let password = passwords.get(target) else {
            Log.write("Want to switch \(current) -> \(target) but have no password for it")
            snapshot.needsPassword = target
            publish()
            return
        }

        let targetRSSI = snapshot.seen[target] ?? 0
        Log.write("Switching \(current) (\(fresh.rssi) dBm) -> \(target) (\(targetRSSI) dBm)")
        let time = Self.clock.string(from: Date())
        do {
            try wifi.join(target, password: password)
            decider.noteSwitched(at: Date())
            currentSSID = target
            identifiedChannel = wifi.reading()?.channel
            snapshot.ssid = target
            snapshot.rssi = wifi.reading()?.rssi ?? targetRSSI
            snapshot.lastEvent = "Switched to \(target) at \(time)"
            Log.write("Joined \(target)")
        } catch let error as JoinError where error.networkNotFound {
            decider.noteScanned(at: Date())
            Log.write("\(target) did not show up for the join, will look again shortly")
        } catch {
            // macOS rejoins a known network by itself within a few seconds.
            decider.noteJoinFailed(ssid: target, at: Date())
            currentSSID = nil
            identifiedChannel = nil
            snapshot.lastEvent = "Couldn't join \(target) at \(time). Check its password."
            Log.write("Joining \(target) failed: \(error.localizedDescription)")
        }
        publish()
    }
}
