import XCTest
import JenaFileCore
@testable import JenaFileKit

final class PathTextTests: XCTestCase {
    func testCopyTextForNameRelativeAbsolute() {
        let paths = ["/home/jena/www/index.html", "/etc/hosts"]
        XCTAssertEqual(PathText.text(paths, .name, home: "/home/jena"), "index.html\nhosts")
        XCTAssertEqual(PathText.text(paths, .relative, home: "/home/jena"), "www/index.html\n/etc/hosts", "outside home stays absolute")
        XCTAssertEqual(PathText.text(paths, .absolute, home: "/home/jena"), "/home/jena/www/index.html\n/etc/hosts")
        XCTAssertEqual(PathText.relative("/home/jena", to: "/home/jena/"), ".")
        XCTAssertEqual(PathText.relative("/home/jenafile/x", to: "/home/jena"), "/home/jenafile/x", "prefix must end at a folder")
    }

    func testRenameProblems() {
        let siblings = ["a.txt", "b"]
        XCTAssertNotNil(PathText.renameProblem("", current: "a.txt", siblings: siblings))
        XCTAssertNotNil(PathText.renameProblem("x/y", current: "a.txt", siblings: siblings))
        XCTAssertNotNil(PathText.renameProblem("..", current: "a.txt", siblings: siblings))
        XCTAssertNotNil(PathText.renameProblem("b", current: "a.txt", siblings: siblings))
        XCTAssertNil(PathText.renameProblem("a.txt", current: "a.txt", siblings: siblings))
        XCTAssertNil(PathText.renameProblem("새 이름.txt", current: "a.txt", siblings: siblings))
    }
}

@MainActor
final class TransferLightTests: XCTestCase {
    private func info(_ id: UInt64, _ state: TransferState) -> TransferInfo {
        TransferInfo(id: id, connection: 1, direction: .upload, localPath: "/a", remotePath: "/b", size: 1,
                     transferred: 0, bytesPerSec: 0, state: state)
    }

    func testLightFollowsTheQueue() {
        let list = TransferList()
        XCTAssertNil(list.light, "nothing to show for an empty list")
        list.update(info(1, .running))
        list.update(info(2, .queued))
        XCTAssertEqual(list.light, .active)
        list.update(info(1, .failed(message: "x")))
        XCTAssertEqual(list.light, .active, "still moving: stays green")
        list.update(info(2, .done))
        XCTAssertEqual(list.light, .failed)
        list.update(info(1, .waiting))
        XCTAssertEqual(list.light, .active, "waiting for reconnect counts as in progress")
        list.update(info(1, .done))
        XCTAssertEqual(list.light, .finished)
    }
}
