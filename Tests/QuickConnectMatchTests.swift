import XCTest

/// Ranking matters more than matching here: with thirty machines almost any filter finds the
/// right one, but only a good order puts it first — and first is what Return connects to.
@MainActor
final class QuickConnectMatchTests: XCTestCase {

    private func machine(_ name: String, hostname: String = "", group: String = "",
                         tags: [String] = [], ip: String? = nil) -> Machine {
        var m = Machine()
        m.name = name
        m.hostname = hostname.isEmpty ? name : hostname
        m.group = group
        m.tags = tags
        m.lastIP = ip
        return m
    }

    private func names(_ machines: [Machine], _ query: String) -> [String] {
        QuickConnectMatch.rank(machines, query: query).map(\.machine.name)
    }

    func testAnEmptyQueryShowsEverythingInOrder() {
        let all = [machine("shop-pc"), machine("office-pc")]
        XCTAssertEqual(names(all, ""), ["shop-pc", "office-pc"],
                       "the box opens showing the list, not nothing")
        XCTAssertEqual(names(all, "   "), ["shop-pc", "office-pc"])
    }

    func testAPrefixBeatsEverythingElse() {
        let all = [machine("back-office-pc"), machine("office-pc")]
        XCTAssertEqual(names(all, "off").first, "office-pc")
    }

    func testAWordStartBeatsASubstring() {
        let all = [machine("undesirable-pc"), machine("front-desk-pc")]
        XCTAssertEqual(names(all, "desk").first, "front-desk-pc")
    }

    func testTheNameBeatsAMatchElsewhere() {
        let all = [machine("nas", group: "shop"), machine("shop-pc")]
        XCTAssertEqual(names(all, "shop").first, "shop-pc")
    }

    func testAMatchElsewhereStillCounts() {
        let all = [machine("nas", group: "Oak St"), machine("shop-pc")]
        XCTAssertEqual(names(all, "oak"), ["nas"])
    }

    func testTagsAndAddressesMatch() {
        let all = [machine("nas", tags: ["backup"], ip: "192.168.1.55")]
        XCTAssertEqual(names(all, "backup"), ["nas"])
        XCTAssertEqual(names(all, "1.55"), ["nas"])
    }

    func testScatteredLettersMatchLast() {
        let all = [machine("shop-pc"), machine("standby-print-core")]
        // "spc" is in order in both, but shop-pc also contains it as letters s,p,c close by.
        XCTAssertTrue(names(all, "spc").contains("shop-pc"))
    }

    func testScatteredIsWorseThanContaining() {
        let all = [machine("sample-print-case"), machine("the-spc-box")]
        XCTAssertEqual(names(all, "spc").first, "the-spc-box",
                       "a real substring beats letters that merely appear in order")
    }

    func testCaseAndAccentsDoNotMatter() {
        let all = [machine("Café-PC")]
        XCTAssertEqual(names(all, "cafe"), ["Café-PC"])
        XCTAssertEqual(names(all, "CAFÉ"), ["Café-PC"])
    }

    func testNoMatchIsNoResults() {
        XCTAssertTrue(names([machine("shop-pc"), machine("nas")], "zzz").isEmpty)
    }

    func testEqualQualityKeepsTheListOrder() {
        // All three are prefix matches; the order they came in is the order to show.
        let all = [machine("pc-alpha"), machine("pc-bravo"), machine("pc-charlie")]
        XCTAssertEqual(names(all, "pc"), ["pc-alpha", "pc-bravo", "pc-charlie"])
    }

    func testSubsequenceIsInOrderOnly() {
        XCTAssertTrue(QuickConnectMatch.isSubsequence("spc", of: "shop-pc"))
        XCTAssertFalse(QuickConnectMatch.isSubsequence("cps", of: "shop-pc"),
                       "the letters have to appear in the order typed")
        XCTAssertTrue(QuickConnectMatch.isSubsequence("", of: "anything"))
    }
}
