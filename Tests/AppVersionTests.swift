import XCTest

final class AppVersionTests: XCTestCase {
    private func version(_ text: String) throws -> AppVersion {
        try XCTUnwrap(AppVersion(text), "\(text) should parse")
    }

    func testTagsParseWithOrWithoutAV() throws {
        XCTAssertEqual(try version("0.4.0").description, "0.4.0")
        XCTAssertEqual(try version("v0.4.0").description, "0.4.0")
        XCTAssertEqual(try version("V1.2.3").description, "1.2.3")
        XCTAssertEqual(try version(" 1.2.3 ").description, "1.2.3")
    }

    /// The bug this type exists to prevent: compared as strings, 0.10.0 sorts below 0.9.0
    /// and an updater silently stops offering anything.
    func testTenComesAfterNine() throws {
        XCTAssertTrue(try version("0.9.0") < version("0.10.0"))
        XCTAssertTrue(try version("1.9.9") < version("1.10.0"))
        XCTAssertTrue(try version("0.4.0") < version("0.4.10"))
    }

    func testOrderingAcrossEachComponent() throws {
        XCTAssertTrue(try version("0.4.0") < version("0.4.1"))
        XCTAssertTrue(try version("0.4.9") < version("0.5.0"))
        XCTAssertTrue(try version("0.9.9") < version("1.0.0"))
        XCTAssertFalse(try version("0.4.1") < version("0.4.1"))
    }

    func testAMissingComponentIsZero() throws {
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertEqual(try version("1"), try version("1.0.0"))
        XCTAssertTrue(try version("1.2") < version("1.2.1"))
    }

    /// A pre-release leads to the version it is named for, so it must not look newer.
    func testAPrereleaseComesBeforeItsRelease() throws {
        XCTAssertTrue(try version("1.0.0-beta") < version("1.0.0"))
        XCTAssertTrue(try version("1.0.0-alpha") < version("1.0.0-beta"))
        XCTAssertTrue(try version("0.9.0") < version("1.0.0-beta"))
        XCTAssertNotEqual(try version("1.0.0-beta"), try version("1.0.0"))
    }

    func testThingsThatAreNotVersionsAreRejected() {
        for text in ["", "v", "latest", "1.2.x", "..", "1..2", "-1.0", "nightly-build"] {
            XCTAssertNil(AppVersion(text), "\(text) should not parse")
        }
    }
}
