import XCTest

/// Reading who signed something. This decides whether a download is allowed to replace the
/// running app, so "cannot tell" has to mean no.
final class CodeSignatureTests: XCTestCase {
    /// As `codesign -d --verbose=4` prints it, in among everything else it says.
    private let signed = """
    Executable=/Applications/RDP Manager.app/Contents/MacOS/RDP Manager
    Identifier=com.lanservices.rdpmanager
    Format=app bundle with Mach-O universal (x86_64 arm64)
    Signature size=9065
    Authority=Developer ID Application: Lan Services Fbg LLC (LT92GD6MBZ)
    Authority=Developer ID Certification Authority
    TeamIdentifier=LT92GD6MBZ
    Runtime Version=26.0.0
    Sealed Resources version=2 rules=13 files=120
    """

    func testTheTeamIsRead() {
        XCTAssertEqual(CodeSignature.parseTeamIdentifier(signed), "LT92GD6MBZ")
    }

    /// An ad-hoc signed build — which is what a local Debug build is — has no team, and
    /// "not set" is the words codesign uses for that, not a team called "not set".
    func testAnAdHocBuildHasNoTeam() {
        let adHoc = """
        Executable=/tmp/RDP Manager.app/Contents/MacOS/RDP Manager
        Identifier=com.lanservices.rdpmanager
        Signature=adhoc
        TeamIdentifier=not set
        """
        XCTAssertNil(CodeSignature.parseTeamIdentifier(adHoc))
    }

    func testUnsignedOutputHasNoTeam() {
        XCTAssertNil(CodeSignature.parseTeamIdentifier(""))
        XCTAssertNil(CodeSignature.parseTeamIdentifier("code object is not signed at all"))
        XCTAssertNil(CodeSignature.parseTeamIdentifier("Identifier=com.example.app"))
    }

    /// The team is read from its own field, not from the authority line that happens to
    /// contain the same characters in brackets.
    func testTheTeamIsNotTakenFromTheAuthorityLine() {
        let reordered = """
        Authority=Developer ID Application: Someone Else (AAAAAAAAAA)
        TeamIdentifier=BBBBBBBBBB
        """
        XCTAssertEqual(CodeSignature.parseTeamIdentifier(reordered), "BBBBBBBBBB")
    }

    /// The running test bundle is signed the way the Debug app is, so this exercises the
    /// real tool rather than only the parser.
    func testReadingTheTeamOfSomethingRealDoesNotCrash() {
        let url = Bundle(for: Self.self).bundleURL
        // Debug builds are ad-hoc signed, so nil is the expected answer here; what
        // matters is that it answers rather than trapping or hanging.
        _ = CodeSignature.teamIdentifier(of: url)
    }

    /// Verification must refuse something that is not an app bundle at all.
    func testVerifyingSomethingThatIsNotAnAppFails() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-an-app-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try CodeSignature.verify(app: url, team: "LT92GD6MBZ",
                                     identifier: "com.lanservices.rdpmanager"))
    }
}
