import XCTest
import AppKit
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

final class DropPathsTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("jenafile.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// The bug: dragging remote rows (strings only) inserted nothing.
    func testRemoteRowsArriveAsStrings() {
        let pb = board()
        pb.writeObjects(["/home/jena/.bashrc" as NSString, "/home/jena/my file" as NSString])
        XCTAssertEqual(DropPaths.read(pb), ["/home/jena/.bashrc", "/home/jena/my file"])
    }

    func testFinderFilesArriveAsFileURLs() {
        let pb = board()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL])
        XCTAssertEqual(DropPaths.read(pb), ["/tmp/a b.txt"])
    }
}
