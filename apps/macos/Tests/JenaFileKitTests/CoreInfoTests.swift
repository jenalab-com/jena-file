import XCTest
@testable import JenaFileKit

final class CoreInfoTests: XCTestCase {
    func testCoreVersionIsReachableFromSwift() {
        XCTAssertFalse(CoreInfo.version.isEmpty)
    }
}
