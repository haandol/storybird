import Combine
import Foundation
import StorybirdCore

/// App-wide, explicitly requested release lookup. Construction and status reads
/// never start a task, including when a Settings view subscribes to this object.
@MainActor
final class StorybirdUpdateChecker: ObservableObject {
    @Published private(set) var status: AppUpdateStatus
    private let session: URLSession
    private var task: Task<Void, Never>?

    static let endpoint = URL(string: "https://api.github.com/repos/haandol/storybird/releases/latest")!
    static let timeout: TimeInterval = 10

    /// Read bundle metadata without networking; injected sessions keep tests offline.
    init(
        currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        buildNumber: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        session: URLSession? = nil
    ) {
        status = AppUpdateStatus(currentVersion: currentVersion, buildNumber: buildNumber)
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration(), delegate: ReleaseRequestDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Isolate public metadata traffic from browser cookies, credentials and disk caches.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Storybird-Update-Check"]
        return configuration
    }

    /// Always query the fixed endpoint without app version or user-specific input.
    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Storybird-Update-Check", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Returns immediately for MCP; simultaneous UI/MCP callers reuse this task.
    @discardableResult
    func startCheck() -> AppUpdateStatus {
        guard task == nil else { return status }
        status = AppUpdateStatus(currentVersion: status.currentVersion, buildNumber: status.buildNumber)
        guard let text = status.currentVersion, let current = AppVersion(text) else {
            status.state = .failed
            status.error = "The app version could not be read. Open a built Storybird app and try again."
            return status
        }
        status.state = .checking
        task = Task {
            defer { task = nil }
            do {
                let (data, response) = try await session.data(for: Self.request())
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw UpdateError.invalidResponse
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard let latest = AppVersion(release.tagName, allowingTagPrefix: true) else {
                    throw UpdateError.invalidVersion
                }
                guard Self.isAllowedReleaseURL(release.htmlURL, tag: release.tagName) else {
                    throw UpdateError.invalidLink
                }
                status.latestVersion = latest.description
                status.releaseURL = release.htmlURL
                status.state = latest > current ? .updateAvailable : .upToDate
            } catch {
                status.state = .failed
                status.error = (error as? UpdateError)?.errorDescription
                    ?? "Could not check for updates. Check your connection and try again."
            }
        }
        return status
    }

    /// Await the same in-progress lookup, allowing callers to observe its terminal state.
    func check() async {
        startCheck()
        await task?.value
    }

    /// Accept only a direct release path matching the validated tag, without URL extras.
    static func isAllowedReleaseURL(_ value: String, tag: String) -> Bool {
        guard AppVersion(tag, allowingTagPrefix: true) != nil,
              let url = URLComponents(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        return url.percentEncodedPath == "/haandol/storybird/releases/tag/\(tag)"
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse, invalidVersion, invalidLink
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "GitHub could not return the latest release. Try again later."
            case .invalidVersion: "The release version was not recognized. Try again later."
            case .invalidLink: "The release link was not a valid Storybird release. Try again later."
            }
        }
    }
}

/// The one approved endpoint cannot redirect into another network boundary or
/// prompt for credentials. GitHub's public metadata needs no authentication.
final class ReleaseRequestDelegate: NSObject, URLSessionTaskDelegate {
    /// Refuse redirects so a check never sends another request outside the endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Preserve normal TLS validation, but never answer a credentials challenge.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
