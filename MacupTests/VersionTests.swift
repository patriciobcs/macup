import XCTest

@testable import Macup

final class VersionTests: XCTestCase {
    func testOrdering() {
        XCTAssertTrue(Version.isNewer("1.3.1", than: "1.2.3"))
        XCTAssertTrue(Version.isNewer("2.0.11.1", than: "2.0.8"))
        XCTAssertTrue(Version.isNewer("12.0.2", than: "10.9.7"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertTrue(Version.isNewer("1.0.0-rc.1", than: "1.0.0-beta.2"))
        XCTAssertTrue(Version.isNewer("1.2.3_1", than: "1.2.3"))
        XCTAssertFalse(Version.isNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(Version.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(Version.isNewer("v0.9.68", than: "0.9.67"))
    }
}

final class GoEscapeTests: XCTestCase {
    func testEscapesUppercase() {
        XCTAssertEqual(Registry.goEscape("github.com/BurntSushi/toml"), "github.com/!burnt!sushi/toml")
        XCTAssertEqual(Registry.goEscape("golang.org/x/tools"), "golang.org/x/tools")
    }
}

final class SelfUpdateVersionTests: XCTestCase {
    func testTagComparison() {
        XCTAssertTrue(Version.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("0.9.9", than: "1.0.0"))
    }
}
