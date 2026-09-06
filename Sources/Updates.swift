import Foundation

struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    // Older bundles used 1.0; release tags use v1.0.0. Compare both numerically.
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                && ($0.count == 1 || $0.first != "0")
        }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers.count == 3 ? numbers[2] : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum AppReleaseInfo {
    static let releasesURL = URL(string: "https://github.com/yqstar/PasteHistory/releases")!
    static let latestAPIURL = URL(string: "https://api.github.com/repos/yqstar/PasteHistory/releases/latest")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "本地构建"
    }
    static var bundledNotes: String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "此构建未附带版本记录。可点击“全部发布”查看在线记录。"
        }
        return text
    }

    static func isProjectURL(_ url: URL, pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && url.path.hasPrefix("/yqstar/PasteHistory/releases/" + pathPrefix)
    }
}

struct PublishedRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, state, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    var version: AppVersion? { AppVersion(tagName) }
    var notes: String {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "此版本未提供更新说明，可前往发布页面查看详情。"
        }
        return body
    }
    var downloadURL: URL? {
        guard let version else { return nil }
        let name = "PasteHistory-\(version)-universal.dmg"
        return assets.first {
            $0.name == name && $0.state == "uploaded" && $0.size > 0
                && AppReleaseInfo.isProjectURL($0.browserDownloadURL, pathPrefix: "download/")
                && $0.browserDownloadURL.path == "/yqstar/PasteHistory/releases/download/\(tagName)/\(name)"
        }?.browserDownloadURL
    }
}

enum UpdateCheckError: LocalizedError {
    case noRelease, rateLimited, server(Int), invalidResponse, invalidVersion, network

    var errorDescription: String? {
        switch self {
        case .noRelease: return "暂时没有可用的正式版本，可前往发布页面查看。"
        case .rateLimited: return "GitHub 暂时限制了检查频率，请稍后重试，或直接查看发布页面。"
        case .server(let code): return "更新服务暂时不可用（HTTP \(code)），请稍后重试。"
        case .invalidResponse: return "更新信息不完整或格式不受支持，请前往发布页面查看。"
        case .invalidVersion: return "无法识别当前应用版本，请前往发布页面查看。"
        case .network: return "无法连接 GitHub，请检查网络连接后重试。"
        }
    }
}

protocol ReleaseChecking {
    // Completion is always delivered on the main queue.
    func fetchLatest(completion: @escaping (Result<PublishedRelease, Error>) -> Void)
}

final class GitHubReleaseChecker: ReleaseChecking {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func fetchLatest(completion: @escaping (Result<PublishedRelease, Error>) -> Void) {
        var request = URLRequest(url: AppReleaseInfo.latestAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PasteHistory-UpdateChecker", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let result: Result<PublishedRelease, Error>
            if error != nil {
                result = .failure(UpdateCheckError.network)
            } else {
                result = Result { try Self.parse(data: data, response: response) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func parse(data: Data?, response: URLResponse?) throws -> PublishedRelease {
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 404: throw UpdateCheckError.noRelease
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.server(response.statusCode)
        }
        guard let data, data.count <= 2_000_000,
              let release = try? JSONDecoder().decode(PublishedRelease.self, from: data),
              !release.draft, !release.prerelease, release.version != nil,
              AppReleaseInfo.isProjectURL(release.htmlURL, pathPrefix: "tag/"),
              release.htmlURL.path == "/yqstar/PasteHistory/releases/tag/\(release.tagName)" else {
            throw UpdateCheckError.invalidResponse
        }
        return release
    }
}
