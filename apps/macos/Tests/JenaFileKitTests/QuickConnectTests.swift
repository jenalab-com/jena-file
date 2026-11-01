import XCTest
@testable import JenaFileKit

final class QuickConnectTests: XCTestCase {
    func testPlainFields() {
        XCTAssertEqual(QuickConnectInput.parse(host: "example.com", user: "jena", port: ""),
                       QuickConnectInput(host: "example.com", user: "jena", port: 22))
    }

    func testUserHostPortInHostFieldWins() {
        XCTAssertEqual(QuickConnectInput.parse(host: "sftp://ops@10.0.0.5:2201/", user: "other", port: "22"),
                       QuickConnectInput(host: "10.0.0.5", user: "ops", port: 2201))
    }

    func testMissingUserOrBadPortIsRejected() {
        XCTAssertNil(QuickConnectInput.parse(host: "example.com", user: "", port: "22"))
        XCTAssertNil(QuickConnectInput.parse(host: "a@example.com:99999", user: "", port: ""))
    }
}

final class RemotePathTests: XCTestCase {
    func testJoinAndParent() {
        XCTAssertEqual(RemotePath.join("/home/jena", "logs"), "/home/jena/logs")
        XCTAssertEqual(RemotePath.join("/", "etc"), "/etc")
        XCTAssertEqual(RemotePath.parent("/home/jena"), "/home")
        XCTAssertEqual(RemotePath.parent("/home"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
    }

    func testPermissions() {
        XCTAssertEqual(Format.permissions(0o40755), "rwxr-xr-x")
        XCTAssertEqual(Format.permissions(0o100640), "rw-r-----")
    }
}

final class ShellQuoteTests: XCTestCase {
    func testQuotesSpacesAndApostrophes() {
        XCTAssertEqual(ShellQuote.quote("/var/www"), "'/var/www'")
        XCTAssertEqual(ShellQuote.quote("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }
}

final class TerminalLocaleTests: XCTestCase {
    func testLangFromLocale() {
        XCTAssertEqual(TerminalLocale.lang(for: Locale(identifier: "ko_KR")), "ko_KR.UTF-8")
        XCTAssertEqual(TerminalLocale.lang(for: Locale(identifier: "en_US")), "en_US.UTF-8")
        XCTAssertEqual(TerminalLocale.lang(for: Locale(identifier: "ko")), "en_US.UTF-8")
    }
}
