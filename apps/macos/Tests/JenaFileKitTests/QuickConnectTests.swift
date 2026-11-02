import XCTest
import AppKit
@testable import JenaFileKit
import JenaFileCore

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

final class QuickConnectFillTests: XCTestCase {
    override func setUp() { Localization.useEnglish = false }

    /// The author's `ssh -L` habit (example addresses).
    func testLocalForwardCommandFillsBastionAndTarget() throws {
        let parsed = try XCTUnwrap(parseSshCommand(text: "ssh -L 2222:10.0.2.6:22 ops@203.0.113.10"))
        let fill = try XCTUnwrap(QuickConnectFill(parsed))
        XCTAssertEqual(fill.host, "10.0.2.6")
        XCTAssertEqual(fill.user, "")
        XCTAssertEqual(fill.port, "")
        XCTAssertEqual(fill.bastion, "ops@203.0.113.10")
        XCTAssertTrue(fill.note.contains("로컬 포트 2222"))
        XCTAssertTrue(fill.note.contains("사용자 이름을 입력"))
    }

    func testJumpCommandWithUsers() throws {
        let parsed = try XCTUnwrap(parseSshCommand(text: "ssh -J jump@b.example:2200 app@10.0.0.5"))
        let fill = try XCTUnwrap(QuickConnectFill(parsed))
        XCTAssertEqual(fill.user, "app")
        XCTAssertEqual(fill.bastion, "jump@b.example:2200")
    }
}

final class TransferFormatTests: XCTestCase {
    func testEtaAndSpeed() {
        XCTAssertEqual(Format.eta(remaining: 100 << 20, bytesPerSec: 10 << 20), "0:10")
        XCTAssertEqual(Format.eta(remaining: 10 << 30, bytesPerSec: 1 << 20), "2:50:40")
        XCTAssertEqual(Format.eta(remaining: 5, bytesPerSec: 0), "")
        XCTAssertEqual(Format.speed(0), "")
        XCTAssertTrue(Format.speed(12_500_000).hasSuffix("/s"))
    }
}

@MainActor
final class LocalBrowserTests: XCTestCase {
    func testListsFoldersFirstAndNavigates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("h".utf8).write(to: root.appendingPathComponent(".hidden"))
        defer { try? FileManager.default.removeItem(at: root) }

        let b = LocalBrowser(path: root.path)
        b.refresh()
        XCTAssertEqual(b.entries.map(\.name), ["zeta", "a.txt"], "dot-files hidden by default")
        b.showsHidden = true
        XCTAssertEqual(b.entries.map(\.name), ["zeta", ".hidden", "a.txt"])
        b.showsHidden = false
        XCTAssertEqual(b.entries[1].size, 1)
        b.enter(b.entries[0])
        XCTAssertTrue(b.path.hasSuffix("/zeta"))
        b.goUp()
        XCTAssertEqual(b.path, root.standardizedFileURL.path)
    }

    /// /Volumes has the hidden flag; it must still show at "/" so external drives are reachable.
    func testRootShowsVolumesButNotOtherHiddenFolders() throws {
        let names = try LocalBrowser.list(URL(fileURLWithPath: "/")).map(\.name)
        XCTAssertTrue(names.contains("Volumes"))
        XCTAssertFalse(names.contains("private"), "other hidden-flag folders stay hidden")
        XCTAssertTrue(LocalBrowser.volumes().allSatisfy { $0.path.hasPrefix("/Volumes/") })
    }
}
