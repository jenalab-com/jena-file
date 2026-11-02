import XCTest
import JenaFileCore
@testable import JenaFileKit

final class ServerTreeTests: XCTestCase {
    private func server(_ name: String, group: String = "") -> Profile {
        var p = Profile.blank(group: group)
        p.id = name
        p.name = name
        return p
    }

    func testGroupsFromSettingsAndProfilesThenRootServers() {
        let tree = ServerTree(profiles: [server("a", group: "home"), server("b"), server("c", group: "Client")],
                              groupNames: ["Empty", "home"])
        XCTAssertEqual(tree.groups.map(\.name), ["Client", "Empty", "home"], "sorted, no duplicates, empty kept")
        XCTAssertEqual(tree.groups.map { $0.servers.map(\.id) }, [["c"], [], ["a"]])
        XCTAssertEqual(tree.root.map(\.id), ["b"])
    }

    func testGroupNameProblems() {
        let tree = ServerTree(profiles: [server("a", group: "Client")], groupNames: [])
        XCTAssertNotNil(tree.problem(withGroupName: ""))
        XCTAssertNotNil(tree.problem(withGroupName: "client"), "case-insensitive duplicate")
        XCTAssertNil(tree.problem(withGroupName: "client", renaming: "Client"), "renaming to itself (case change) is fine")
        XCTAssertNil(tree.problem(withGroupName: "개인"))
    }
}
