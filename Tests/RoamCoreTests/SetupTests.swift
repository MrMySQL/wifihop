import XCTest
@testable import RoamCore

final class SensitivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// True when three readings at this signal make the decider ask for a scan.
    private func scans(at rssi: Int, with sensitivity: Sensitivity) -> Bool {
        var d = RoamDecider(settings: sensitivity.settings)
        _ = d.shouldScan(rssi: rssi, now: t0)
        _ = d.shouldScan(rssi: rssi, now: t0.addingTimeInterval(10))
        return d.shouldScan(rssi: rssi, now: t0.addingTimeInterval(20))
    }

    func testBalancedMatchesTheDefaultSettings() {
        XCTAssertEqual(Sensitivity.balanced.settings.weakRSSI, RoamSettings().weakRSSI)
        XCTAssertEqual(Sensitivity.balanced.settings.minImprovement, RoamSettings().minImprovement)
    }

    func testSoonerReactsToASignalBalancedStillAccepts() {
        XCTAssertTrue(scans(at: -67, with: .sooner))
        XCTAssertFalse(scans(at: -67, with: .balanced))
    }

    func testLaterToleratesASignalBalancedCallsWeak() {
        XCTAssertTrue(scans(at: -73, with: .balanced))
        XCTAssertFalse(scans(at: -73, with: .later))
    }

    func testSoonerSwitchesForASmallerGainThanLater() {
        let seen = [SeenNetwork(ssid: "B", rssi: -70, channel: 44)]
        let sooner = RoamDecider(settings: Sensitivity.sooner.settings)
        let later = RoamDecider(settings: Sensitivity.later.settings)
        XCTAssertEqual(sooner.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0), "B")
        XCTAssertNil(later.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0))
    }
}

final class SignalQualityTests: XCTestCase {
    func testStrongFromMinusSixtyUp() {
        XCTAssertEqual(SignalQuality(rssi: -45), .strong)
        XCTAssertEqual(SignalQuality(rssi: -60), .strong)
    }

    func testGoodBetweenMinusSixtyOneAndMinusSeventy() {
        XCTAssertEqual(SignalQuality(rssi: -61), .good)
        XCTAssertEqual(SignalQuality(rssi: -70), .good)
    }

    func testWeakBelowMinusSeventy() {
        XCTAssertEqual(SignalQuality(rssi: -71), .weak)
        XCTAssertEqual(SignalQuality(rssi: -90), .weak)
    }
}

final class SetupRowsTests: XCTestCase {
    func testNetworksInRangeComeFirstStrongestOnTop() {
        let rows = setupRows(saved: ["Far", "Near", "Mid"], selected: [],
                             inRange: ["Far": -80, "Near": -40, "Mid": -60], showOutOfRange: false)
        XCTAssertEqual(rows.map(\.ssid), ["Near", "Mid", "Far"])
        XCTAssertEqual(rows.map(\.rssi), [-40, -60, -80])
    }

    func testSavedNetworksOutOfRangeAreHiddenByDefault() {
        let rows = setupRows(saved: ["Home", "Cafe"], selected: [],
                             inRange: ["Home": -50], showOutOfRange: false)
        XCTAssertEqual(rows.map(\.ssid), ["Home"])
    }

    func testOutOfRangeNetworksFollowInAlphabeticalOrderWhenAskedFor() {
        let rows = setupRows(saved: ["zeta", "Home", "Alpha"], selected: [],
                             inRange: ["Home": -50], showOutOfRange: true)
        XCTAssertEqual(rows.map(\.ssid), ["Home", "Alpha", "zeta"])
        XCTAssertEqual(rows.map(\.rssi), [-50, nil, nil])
    }

    func testASelectedNetworkStaysListedWhenOutOfRange() {
        let rows = setupRows(saved: ["Upstairs", "Downstairs"], selected: ["Upstairs"],
                             inRange: ["Downstairs": -50], showOutOfRange: false)
        XCTAssertEqual(rows, [
            SetupRow(ssid: "Downstairs", rssi: -50, selected: false),
            SetupRow(ssid: "Upstairs", rssi: nil, selected: true),
        ])
    }

    func testASelectedNetworkStaysListedAfterTheMacForgetsIt() {
        let rows = setupRows(saved: [], selected: ["Old"], inRange: [:], showOutOfRange: false)
        XCTAssertEqual(rows, [SetupRow(ssid: "Old", rssi: nil, selected: true)])
    }

    func testEachNetworkIsListedOnce() {
        let rows = setupRows(saved: ["Home", "Home"], selected: ["Home"],
                             inRange: ["Home": -50], showOutOfRange: true)
        XCTAssertEqual(rows.map(\.ssid), ["Home"])
    }
}
