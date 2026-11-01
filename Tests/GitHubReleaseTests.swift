import XCTest

/// Deciding what, if anything, to offer. Getting this wrong either installs the wrong
/// thing or quietly stops offering updates at all, and neither announces itself.
final class GitHubReleaseTests: XCTestCase {
    /// Trimmed from a real `/releases` response, keeping the shape: a draft, a
    /// pre-release, a release with no asset, and the tag order the API actually returns.
    private let sample = """
    [
      {"tag_name":"0.5.0","name":"0.5.0 — unfinished","body":"wip","draft":true,
       "prerelease":false,"html_url":"https://example.invalid/5",
       "assets":[{"name":"RDP-Manager-0.5.0.zip","browser_download_url":"https://example.invalid/a.zip","size":1}]},
      {"tag_name":"0.4.2-beta","name":"0.4.2 beta","body":"testing","draft":false,
       "prerelease":true,"html_url":"https://example.invalid/42b",
       "assets":[{"name":"RDP-Manager-0.4.2-beta.zip","browser_download_url":"https://example.invalid/b.zip","size":2}]},
      {"tag_name":"0.4.1","name":"0.4.1 — fixes","body":"Fixed things.","draft":false,
       "prerelease":false,"html_url":"https://example.invalid/41",
       "assets":[{"name":"RDP-Manager-0.4.1.zip","browser_download_url":"https://example.invalid/c.zip","size":23741812}]},
      {"tag_name":"0.4.0","name":"0.4.0","body":"Discovery.","draft":false,
       "prerelease":false,"html_url":"https://example.invalid/40","assets":[]}
    ]
    """

    private func releases() throws -> [GitHubRelease] {
        try GitHubRelease.decodeList(Data(sample.utf8))
    }

    private func version(_ text: String) throws -> AppVersion {
        try XCTUnwrap(AppVersion(text))
    }

    // MARK: Reading the API

    func testEveryReleaseIsRead() throws {
        XCTAssertEqual(try releases().map(\.tag), ["0.5.0", "0.4.2-beta", "0.4.1", "0.4.0"])
    }

    func testAssetsAndNotesAreRead() throws {
        let release = try XCTUnwrap(try releases().first { $0.tag == "0.4.1" })
        XCTAssertEqual(release.notes, "Fixed things.")
        XCTAssertEqual(release.displayName, "0.4.1 — fixes")
        XCTAssertEqual(release.appAsset?.name, "RDP-Manager-0.4.1.zip")
        XCTAssertEqual(release.appAsset?.size, 23741812)
        XCTAssertEqual(release.pageURL?.absoluteString, "https://example.invalid/41")
    }

    /// An installed app cannot be fixed except by the updater, so the updater has to
    /// survive the API gaining fields it has never heard of.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        [{"tag_name":"9.9.9","surprising_new_field":{"nested":true},"draft":false,
          "assets":[{"name":"a.zip","browser_download_url":"https://example.invalid/a.zip",
                     "size":1,"uploader":{"login":"someone"}}]}]
        """
        let parsed = try GitHubRelease.decodeList(Data(json.utf8))
        XCTAssertEqual(parsed.first?.tag, "9.9.9")
        XCTAssertEqual(parsed.first?.appAsset?.name, "a.zip")
    }

    func testAReleaseWithoutATagIsSkipped() throws {
        let json = #"[{"name":"no tag","assets":[]},{"tag_name":"1.0.0","assets":[]}]"#
        XCTAssertEqual(try GitHubRelease.decodeList(Data(json.utf8)).map(\.tag), ["1.0.0"])
    }

    func testOnlyAZipCountsAsTheApp() throws {
        let json = """
        [{"tag_name":"1.0.0","draft":false,"prerelease":false,"assets":[
          {"name":"checksums.txt","browser_download_url":"https://example.invalid/c.txt","size":1},
          {"name":"RDP-Manager-1.0.0.zip","browser_download_url":"https://example.invalid/a.zip","size":2}]}]
        """
        let release = try XCTUnwrap(try GitHubRelease.decodeList(Data(json.utf8)).first)
        XCTAssertEqual(release.appAsset?.name, "RDP-Manager-1.0.0.zip")
    }

    // MARK: Choosing what to offer

    func testTheNewestFinalReleaseIsOffered() throws {
        let found = GitHubRelease.newest(in: try releases(), newerThan: try version("0.4.0"))
        XCTAssertEqual(found?.tag, "0.4.1")
    }

    func testDraftsAndPrereleasesAreNotOffered() throws {
        let found = GitHubRelease.newest(in: try releases(), newerThan: try version("0.4.1"))
        // 0.5.0 is a draft and 0.4.2-beta a pre-release, so nothing is left.
        XCTAssertNil(found)
    }

    /// Publishing a release with nothing attached must not produce an update that cannot
    /// be installed when the user clicks Update.
    func testAReleaseWithNoAssetIsNotOffered() throws {
        let found = GitHubRelease.newest(in: try releases(), newerThan: try version("0.3.0"))
        XCTAssertEqual(found?.tag, "0.4.1")
        XCTAssertNotEqual(found?.tag, "0.4.0")
    }

    func testTheSameVersionIsNotAnUpdate() throws {
        XCTAssertNil(GitHubRelease.newest(in: try releases(), newerThan: try version("0.4.1")))
        XCTAssertNil(GitHubRelease.newest(in: try releases(), newerThan: try version("9.0.0")))
    }

    func testASkippedVersionIsNotOffered() throws {
        let found = GitHubRelease.newest(in: try releases(), newerThan: try version("0.4.0"),
                                         skipping: "0.4.1")
        XCTAssertNil(found)
    }

    /// Skipping one release must not mean never hearing about another.
    func testSkippingOneVersionDoesNotHideALaterOne() throws {
        let json = """
        [{"tag_name":"0.4.2","draft":false,"prerelease":false,"assets":[
           {"name":"a.zip","browser_download_url":"https://example.invalid/a.zip","size":1}]},
         {"tag_name":"0.4.1","draft":false,"prerelease":false,"assets":[
           {"name":"b.zip","browser_download_url":"https://example.invalid/b.zip","size":1}]}]
        """
        let parsed = try GitHubRelease.decodeList(Data(json.utf8))
        let found = GitHubRelease.newest(in: parsed, newerThan: try version("0.4.0"),
                                         skipping: "0.4.1")
        XCTAssertEqual(found?.tag, "0.4.2")
    }

    /// Picked by version, not by the order the API listed them, so re-publishing an old
    /// release does not offer it as an update.
    func testTheHighestVersionWinsNotTheFirstListed() throws {
        let json = """
        [{"tag_name":"0.4.1","draft":false,"prerelease":false,"assets":[
           {"name":"a.zip","browser_download_url":"https://example.invalid/a.zip","size":1}]},
         {"tag_name":"0.10.0","draft":false,"prerelease":false,"assets":[
           {"name":"b.zip","browser_download_url":"https://example.invalid/b.zip","size":1}]}]
        """
        let parsed = try GitHubRelease.decodeList(Data(json.utf8))
        let found = GitHubRelease.newest(in: parsed, newerThan: try version("0.4.0"))
        XCTAssertEqual(found?.tag, "0.10.0")
    }

    func testAnEmptyListOffersNothing() throws {
        XCTAssertNil(GitHubRelease.newest(in: [], newerThan: try version("0.4.0")))
    }
}
