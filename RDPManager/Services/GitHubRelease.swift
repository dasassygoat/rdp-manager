import Foundation

/// One published release, as the GitHub API describes it.
struct GitHubRelease: Equatable, Identifiable {
    struct Asset: Equatable {
        var name: String
        var url: URL
        var size: Int
    }

    var tag: String
    var name: String
    var notes: String
    var pageURL: URL?
    var isDraft: Bool
    var isPrerelease: Bool
    var assets: [Asset]

    var id: String { tag }
    var version: AppVersion? { AppVersion(tag) }

    /// The packaged app. `package.sh` writes exactly one zip per release, so the first is
    /// the one; anything else attached (checksums, notes) is not what gets installed.
    var appAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    /// A release worth offering: published, final, and carrying something to install.
    var isInstallable: Bool {
        !isDraft && !isPrerelease && version != nil && appAsset != nil
    }

    /// The title to show, falling back to the tag for a release published without one.
    var displayName: String { name.isEmpty ? tag : name }
}

extension GitHubRelease {
    /// Decodes the `/releases` listing. Unknown fields are ignored, so the API gaining
    /// them does not break an installed app that can no longer be fixed except by the
    /// updater this parses for.
    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String?
            var browser_download_url: String?
            var size: Int?
        }
        var tag_name: String?
        var name: String?
        var body: String?
        var html_url: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?
    }

    static func decodeList(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([Payload].self, from: data).compactMap { payload in
            guard let tag = payload.tag_name, !tag.isEmpty else { return nil }
            let assets: [Asset] = (payload.assets ?? []).compactMap { asset in
                guard let name = asset.name, let link = asset.browser_download_url,
                      let url = URL(string: link) else { return nil }
                return Asset(name: name, url: url, size: asset.size ?? 0)
            }
            return GitHubRelease(
                tag: tag,
                name: payload.name ?? "",
                notes: payload.body ?? "",
                pageURL: payload.html_url.flatMap(URL.init(string:)),
                isDraft: payload.draft ?? false,
                isPrerelease: payload.prerelease ?? false,
                assets: assets)
        }
    }

    /// The newest installable release that beats what is running, ignoring one the user
    /// chose to skip. Picked by version rather than by publication order, so re-publishing
    /// an older release does not offer it as an update.
    static func newest(in releases: [GitHubRelease], newerThan current: AppVersion,
                       skipping skipped: String? = nil) -> GitHubRelease? {
        let skippedVersion = skipped.flatMap(AppVersion.init)
        return releases
            .filter { $0.isInstallable }
            .filter { ($0.version ?? current) > current }
            .filter { release in
                guard let skippedVersion, let version = release.version else { return true }
                // Skipping 0.4.1 hides that release, not the 0.4.2 that follows it.
                return version > skippedVersion
            }
            .max { ($0.version ?? current) < ($1.version ?? current) }
    }
}
