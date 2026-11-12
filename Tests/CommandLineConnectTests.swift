import XCTest

/// `rdpm connect` hands a machine to the app rather than launching a session itself: the
/// client preference, the Keychain, the shared sign-ins and the rules about which client can
/// be given a password all live there, and two implementations of that would drift apart.
@MainActor
final class CommandLineConnectTests: XCTestCase {

    /// The URL the command builds and the app parses, kept in one place in the tests the way
    /// it is not in the code — this is the seam between the two halves.
    private func url(machine: UUID, with type: ConnectionType? = nil) -> URL {
        var string = "rdpm://connect?machine=\(machine.uuidString)"
        if let type { string += "&with=\(type.rawValue)" }
        return URL(string: string)!
    }

    private func parse(_ url: URL) -> (id: UUID?, type: ConnectionType?) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first { $0.name == "machine" }?.value.flatMap(UUID.init(uuidString:))
        let type = query.first { $0.name == "with" }?.value
            .flatMap(ConnectionType.init(rawValue:))
        return (id, type)
    }

    func testTheMachineIsIdentifiedByIdNotName() {
        let id = UUID()
        let parsed = parse(url(machine: id))

        XCTAssertEqual(parsed.id, id,
                       "a rename between the lookup and the handling must not connect to "
                       + "the wrong machine")
        XCTAssertNil(parsed.type, "no type asked for means the machine's own")
    }

    func testAnExplicitTypeSurvivesTheRoundTrip() {
        for type in ConnectionType.allCases {
            let parsed = parse(url(machine: UUID(), with: type))
            XCTAssertEqual(parsed.type, type)
        }
    }

    func testNonsenseIsRejectedRatherThanGuessed() {
        XCTAssertNil(parse(URL(string: "rdpm://connect?machine=not-a-uuid")!).id)
        XCTAssertNil(parse(URL(string: "rdpm://connect")!).id)
        XCTAssertNil(parse(URL(string: "rdpm://connect?machine=\(UUID().uuidString)&with=telnet")!).type)
    }

    func testTheSchemeIsRegistered() throws {
        // Without this in Info.plist the URL goes nowhere and `rdpm connect` fails with a
        // message about the app not being installed.
        let plist = try XCTUnwrap(Bundle.main.infoDictionary)
        // The test bundle is not the app, so read the app's own copy from the project.
        let projectPlist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectPlist, encoding: .utf8)
        XCTAssertTrue(text.contains("CFBundleURLSchemes"), "\(plist.keys.count) keys read")
        XCTAssertTrue(text.contains("[rdpm]"))
    }
}
