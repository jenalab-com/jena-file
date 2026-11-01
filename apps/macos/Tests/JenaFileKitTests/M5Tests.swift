import XCTest
@testable import JenaFileKit
import JenaFileCore

final class KeychainStoreTests: XCTestCase {
    func testSaveReadUpdateDelete() {
        let store = KeychainStore(service: "com.jenalab.jena-file.tests")
        let account = "test-\(UUID().uuidString)"
        defer { store.delete(account) }
        XCTAssertNil(store.read(account))
        XCTAssertTrue(store.save("first", for: account))
        XCTAssertEqual(store.read(account), "first")
        XCTAssertTrue(store.save("second", for: account), "update in place")
        XCTAssertEqual(store.read(account), "second")
        store.delete(account)
        XCTAssertNil(store.read(account))
    }
}

final class AppSettingsTests: XCTestCase {
    func testDefaultsAndClamping() {
        let suite = "jenafile.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        XCTAssertEqual(s.transferLimit, 3)
        XCTAssertEqual(s.onConflict, .ask)
        XCTAssertNil(s.onConflict.action)
        XCTAssertTrue(s.showTerminal)
        s.transferLimit = 99
        XCTAssertEqual(s.transferLimit, 10)
        s.onConflict = .skip
        XCTAssertEqual(AppSettings(defaults: d).onConflict.action, .skip)
    }
}

final class ProfileRouteTests: XCTestCase {
    func testDirectSavedBastionAndInlineBastion() throws {
        var bastion = Profile.blank()
        bastion.id = "b1"; bastion.name = "gate"; bastion.host = "203.0.113.10"; bastion.user = "ops"
        var app = Profile.blank()
        app.id = "a1"; app.host = "10.0.0.5"; app.user = "app"; app.via = .server(id: "b1")

        let direct = try XCTUnwrap(ProfileRoute(bastion, all: [bastion, app]))
        XCTAssertNil(direct.via)
        XCTAssertEqual(direct.targetAccount, "b1")

        let viaSaved = try XCTUnwrap(ProfileRoute(app, all: [bastion, app]))
        XCTAssertEqual(viaSaved.via, .endpoint(endpoint: Endpoint(host: "203.0.113.10", port: 22, user: "ops")))
        XCTAssertEqual(viaSaved.bastionAccount, "b1")
        XCTAssertEqual(viaSaved.bastionTitle, "gate")

        XCTAssertNil(ProfileRoute(app, all: [app]), "missing bastion")

        app.via = .endpoint(host: "gw", port: 2200, user: "u"); app.savePassword = false
        let inline = try XCTUnwrap(ProfileRoute(app, all: [app]))
        XCTAssertEqual(inline.bastionTitle, "u@gw:2200")
        XCTAssertNil(inline.bastionAccount)
        XCTAssertNil(inline.targetAccount)
    }
}
