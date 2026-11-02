import XCTest
@testable import JenaFileKit
import JenaFileCore

final class PendingStoreTests: XCTestCase {
    func testRoundTripAndEmptyRemovesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PendingStore(dataDir: dir)
        XCTAssertEqual(store.load(), [])
        let item = PendingTransfer(key: "a@h:22", upload: true, local: "/tmp/x", remote: "/srv/x", size: 9)
        store.save([item])
        XCTAssertEqual(store.load(), [item])
        store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testWhatCountsAsUnfinished() {
        XCTAssertTrue(PendingTransfer.unfinished(.waiting))
        XCTAssertTrue(PendingTransfer.unfinished(.failed(message: "x")))
        XCTAssertFalse(PendingTransfer.unfinished(.done))
        XCTAssertFalse(PendingTransfer.unfinished(.cancelled))
    }

    func testRouteKeyIsTheSameForQuickConnectAndSavedServers() {
        let t = Endpoint(host: "10.0.0.5", port: 22, user: "app")
        let b = Endpoint(host: "203.0.113.10", port: 22, user: "ops")
        XCTAssertEqual(RouteKey.of(t, viaKey: RouteKey.of(b)), "app@10.0.0.5:22 via ops@203.0.113.10:22")
        XCTAssertEqual(RouteKey.of(t, viaKey: nil), "app@10.0.0.5:22")
    }
}

final class FriendlyErrorTests: XCTestCase {
    override func setUp() { Localization.useEnglish = false }

    func testCommonNetworkFailures() {
        XCTAssertTrue(UserMessage.friendly(.target, "Connection refused (os error 61)").contains("거부"))
        XCTAssertTrue(UserMessage.friendly(.bastion, "failed to lookup address information: nodename nor servname provided").contains("주소를 찾을 수 없어요"))
        XCTAssertTrue(UserMessage.friendly(.target, "connection lost").contains("끊겼어요"))
        XCTAssertTrue(UserMessage.friendly(.target, "Operation timed out").contains("시간 초과"))
        XCTAssertTrue(UserMessage.friendly(.target, "weird").contains("(weird)"), "unknown text kept")
    }
}
