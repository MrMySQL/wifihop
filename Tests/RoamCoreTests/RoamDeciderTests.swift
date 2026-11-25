import XCTest
@testable import RoamCore

final class RoamDeciderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: when to scan

    func testStrongSignalNeverAsksForScan() {
        var d = RoamDecider()
        for i in 0..<10 {
            XCTAssertFalse(d.shouldScan(rssi: -50, now: at(Double(i) * 10)))
        }
    }

    func testWeakSignalAsksForScanOnThirdConsecutiveSample() {
        var d = RoamDecider()
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(0)))
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(10)))
        XCTAssertTrue(d.shouldScan(rssi: -75, now: at(20)))
    }

    func testSignalExactlyAtThresholdIsNotWeak() {
        var d = RoamDecider()
        for i in 0..<5 {
            XCTAssertFalse(d.shouldScan(rssi: -70, now: at(Double(i) * 10)))
        }
    }

    func testStrongSampleResetsWeakCount() {
        var d = RoamDecider()
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(0)))
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(10)))
        XCTAssertFalse(d.shouldScan(rssi: -50, now: at(20)))
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(30)))
        XCTAssertFalse(d.shouldScan(rssi: -75, now: at(40)))
        XCTAssertTrue(d.shouldScan(rssi: -75, now: at(50)))
    }

    func testNotAssociatedNeverAsksForScan() {
        var d = RoamDecider()
        for i in 0..<5 {
            XCTAssertFalse(d.shouldScan(rssi: 0, now: at(Double(i) * 10)))
        }
    }

    func testNoScanDuringCooldownAfterSwitch() {
        var d = RoamDecider()
        d.noteSwitched(at: at(0))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(10)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(20)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(30)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(59)))
    }

    func testScansAgainOnceCooldownHasPassedAndSignalIsStillWeak() {
        var d = RoamDecider()
        d.noteSwitched(at: at(0))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(40)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(50)))
        XCTAssertTrue(d.shouldScan(rssi: -80, now: at(60)))
    }

    func testAfterFruitlessScanWaitsBeforeScanningAgain() {
        var d = RoamDecider()
        _ = d.shouldScan(rssi: -80, now: at(0))
        _ = d.shouldScan(rssi: -80, now: at(10))
        XCTAssertTrue(d.shouldScan(rssi: -80, now: at(20)))
        d.noteScanned(at: at(20))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(30)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(40)))
        XCTAssertTrue(d.shouldScan(rssi: -80, now: at(50)))
    }

    // MARK: where to go

    func testPicksOtherNetworkThatIsTenDecibelsStronger() {
        let d = RoamDecider()
        let seen = [
            SeenNetwork(ssid: "A", rssi: -78, channel: 6),
            SeenNetwork(ssid: "B", rssi: -55, channel: 44),
        ]
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0), "B")
    }

    func testStaysWhenOtherNetworkIsNotEnoughStronger() {
        let d = RoamDecider()
        let seen = [SeenNetwork(ssid: "B", rssi: -69, channel: 44)]
        XCTAssertNil(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0))
    }

    func testSwitchesWhenImprovementIsExactlyTheMinimum() {
        let d = RoamDecider()
        let seen = [SeenNetwork(ssid: "B", rssi: -68, channel: 44)]
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0), "B")
    }

    func testNeverPicksTheCurrentNetwork() {
        let d = RoamDecider()
        let seen = [SeenNetwork(ssid: "A", rssi: -40, channel: 6)]
        XCTAssertNil(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0))
    }

    func testPicksTheStrongestOfSeveralCandidates() {
        let d = RoamDecider()
        let seen = [
            SeenNetwork(ssid: "B", rssi: -60, channel: 44),
            SeenNetwork(ssid: "C", rssi: -50, channel: 1),
            SeenNetwork(ssid: "C", rssi: -66, channel: 36),
        ]
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: t0), "C")
    }

    func testStaysWhenNothingElseIsSeen() {
        let d = RoamDecider()
        XCTAssertNil(d.target(currentSSID: "A", currentRSSI: -78, seen: [], now: t0))
    }

    // MARK: which network am I on

    func testReportedNameWins() {
        let seen = [SeenNetwork(ssid: "B", rssi: -50, channel: 6)]
        XCTAssertEqual(inferCurrentSSID(reported: "A", channel: 6, rssi: -45, seen: seen), "A")
    }

    func testSignalTellsApartTwoNetworksOnTheSameChannel() {
        let seen = [
            SeenNetwork(ssid: "A", rssi: -45, channel: 6),
            SeenNetwork(ssid: "B", rssi: -75, channel: 6),
        ]
        XCTAssertEqual(inferCurrentSSID(reported: nil, channel: 6, rssi: -47, seen: seen), "A")
    }

    func testFallsBackToTheOnlyNetworkOnTheCurrentChannel() {
        let seen = [
            SeenNetwork(ssid: "A", rssi: -45, channel: 6),
            SeenNetwork(ssid: "B", rssi: -91, channel: 44),
        ]
        XCTAssertEqual(inferCurrentSSID(reported: nil, channel: 6, rssi: -45, seen: seen), "A")
    }

    func testUnknownWhenTwoNetworksShareTheChannelWithSimilarSignal() {
        let seen = [
            SeenNetwork(ssid: "A", rssi: -45, channel: 6),
            SeenNetwork(ssid: "B", rssi: -52, channel: 6),
        ]
        XCTAssertNil(inferCurrentSSID(reported: nil, channel: 6, rssi: -45, seen: seen))
    }

    func testUnknownWhenNoNetworkIsOnTheCurrentChannel() {
        let seen = [SeenNetwork(ssid: "B", rssi: -70, channel: 44)]
        XCTAssertNil(inferCurrentSSID(reported: nil, channel: 6, rssi: -45, seen: seen))
        XCTAssertNil(inferCurrentSSID(reported: nil, channel: nil, rssi: -45, seen: seen))
    }

    func testUnknownWhenSignalDoesNotMatchTheNetworkOnTheChannel() {
        // On a phone hotspot at -80 that happens to share channel 6 with a router at -45.
        let seen = [SeenNetwork(ssid: "A", rssi: -45, channel: 6)]
        XCTAssertNil(inferCurrentSSID(reported: nil, channel: 6, rssi: -80, seen: seen))
    }

    // MARK: failed joins

    func testNetworkThatFailedToJoinIsSkippedForTenMinutes() {
        var d = RoamDecider()
        d.noteJoinFailed(ssid: "B", at: at(0))
        let seen = [SeenNetwork(ssid: "B", rssi: -50, channel: 44)]
        XCTAssertNil(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: at(599)))
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: at(600)), "B")
    }

    func testFailedJoinFallsThroughToNextBestNetwork() {
        var d = RoamDecider()
        d.noteJoinFailed(ssid: "B", at: at(0))
        let seen = [
            SeenNetwork(ssid: "B", rssi: -50, channel: 44),
            SeenNetwork(ssid: "C", rssi: -60, channel: 1),
        ]
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: at(10)), "C")
    }

    func testFailedJoinStartsTheSameCooldownAsASwitch() {
        var d = RoamDecider()
        d.noteJoinFailed(ssid: "B", at: at(0))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(10)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(20)))
        XCTAssertFalse(d.shouldScan(rssi: -80, now: at(30)))
        XCTAssertTrue(d.shouldScan(rssi: -80, now: at(60)))
    }

    func testClearingAFailureMakesTheNetworkEligibleAgain() {
        var d = RoamDecider()
        d.noteJoinFailed(ssid: "B", at: at(0))
        d.clearFailure(ssid: "B")
        let seen = [SeenNetwork(ssid: "B", rssi: -50, channel: 44)]
        XCTAssertEqual(d.target(currentSSID: "A", currentRSSI: -78, seen: seen, now: at(10)), "B")
    }
}
