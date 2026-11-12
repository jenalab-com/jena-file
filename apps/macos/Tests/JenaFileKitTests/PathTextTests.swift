import XCTest
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
