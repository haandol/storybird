import StorybirdCore
import XCTest

final class AppVersionTests: XCTestCase {
    func test_numericVersion_ordersEachComponentAndIgnoresTagPrefix() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.99")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.99.99")), try XCTUnwrap(AppVersion("1.0.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.0.2")), try XCTUnwrap(AppVersion("1.0.10")))
        XCTAssertEqual(AppVersion("v0.1.13", allowingTagPrefix: true), AppVersion("0.1.13"))
        XCTAssertEqual(AppVersion("0.01.13")?.description, "0.1.13")
    }

    func test_invalidVersion_rejectsMissingExtraNonNumericAndOverflowComponents() {
        for value in ["", "0.1", "0.1.2.3", "0..1", ".1.2", "0.1.", "0.1.-1", "0.1.+1", "0.1.１",
                      " 0.1.13", "0.1.13\n", "0.1.13-beta", "0.1.13+14", "V0.1.13", "vv0.1.13",
                      "99999999999999999999999.1.2"] {
            XCTAssertNil(AppVersion(value, allowingTagPrefix: true), value)
        }
        XCTAssertNil(AppVersion("v0.1.13"), "Only GitHub tags may have the prefix.")
    }
}
