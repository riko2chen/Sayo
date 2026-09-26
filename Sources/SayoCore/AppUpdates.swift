import Foundation

public enum AppUpdateState: Equatable, Sendable {
    case notConfigured
    case ready
    case checking
    case available(version: String)
    case information(version: String)
    case downloading(version: String, progress: Double?)
    case preparing(version: String)
    case readyToInstall(version: String)
    case installing(version: String)
    case upToDate
    case unavailable(String)
    case failed(String)

    public var canCheck: Bool {
        switch self {
        case .ready, .upToDate, .unavailable, .failed: return true
        default: return false
        }
    }
}

@MainActor public protocol AppUpdateChecking: AnyObject {
    var state: AppUpdateState { get }
    var onStateChange: ((AppUpdateState) -> Void)? { get set }
    var onShowUpdate: (() -> Void)? { get set }
    func start()
    func configure(automaticallyChecks: Bool, automaticallyDownloads: Bool)
    func checkForUpdatesAutomatically()
    func checkForUpdates()
}

/// Tracks attempts, including failures and manual checks, across application launches.
public struct AppUpdateCheckCache {
    public static let interval: TimeInterval = 3600
    public var lastCheck: Date?

    public init(lastCheck: Date? = nil) { self.lastCheck = lastCheck }

    public func shouldCheckAutomatically(at now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= Self.interval
    }
}

public struct AppUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    /// Unpublished local builds have no feed or key and do not start a network check.
    public init?(info: [String: Any]) {
        guard let rawURL = info["SUFeedURL"] as? String,
              let components = URLComponents(string: rawURL),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32
        else { return nil }
        feedURL = url
        publicKey = key
    }
}
