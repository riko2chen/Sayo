import AppKit
import Sparkle
import SayoCore

/// Sayo schedules checks and presents progress; Sparkle owns downloads, verification and installation.
@MainActor public final class SparkleAppUpdater: NSObject, AppUpdateChecking, SPUUpdaterDelegate, SPUUserDriver {
    public private(set) var state: AppUpdateState = .notConfigured {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((AppUpdateState) -> Void)?
    public var onShowUpdate: (() -> Void)?
    private var updater: SPUUpdater?
    private var started = false
    private var automaticallyChecks = true
    private var automaticallyDownloads = true
    private var offeredUpdateAllowsAutomaticDownload = true
    private let defaults: UserDefaults
    private let now: () -> Date
    private let bundle: Bundle
    static let lastCheckKey = "SayoLastUpdateCheckDate"
    private var primaryAction: (() -> Void)?
    private var version = ""
    private var receivedBytes: UInt64 = 0
    private var expectedBytes: UInt64 = 0

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.bundle = bundle
        self.now = now
        super.init()
    }

    public func configure(automaticallyChecks: Bool, automaticallyDownloads: Bool) {
        let enableDownload = !self.automaticallyDownloads && automaticallyDownloads
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyDownloads
        if enableDownload, offeredUpdateAllowsAutomaticDownload, case .available = state { performPrimaryAction() }
    }

    public func start() {
        guard updater == nil, AppUpdateConfiguration(info: bundle.infoDictionary ?? [:]) != nil else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        // Sayo's launch/reopen throttle replaces Sparkle's timer. Downloads go through the
        // user driver so progress and the ready-to-install action are always visible.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            started = true
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func checkForUpdatesAutomatically() {
        guard automaticallyChecks, state.canCheck, started, let updater, !updater.sessionInProgress else { return }
        guard reserveCheck(automatically: true) else { return }
        state = .checking
        updater.checkForUpdatesInBackground()
    }

    public func checkForUpdates() {
        if primaryAction != nil {
            performPrimaryAction()
        } else if state.canCheck, started, let updater, updater.canCheckForUpdates {
            _ = reserveCheck(automatically: false)
            state = .checking
            updater.checkForUpdates()
        }
    }

    /// Reserve before starting a request so failures and quick reopens are throttled too.
    func reserveCheck(automatically: Bool) -> Bool {
        let date = now()
        if automatically {
            let cache = AppUpdateCheckCache(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date)
            guard automaticallyChecks, cache.shouldCheckAutomatically(at: date) else { return false }
        }
        defaults.set(date, forKey: Self.lastCheckKey)
        return true
    }

    private func performPrimaryAction() {
        let action = primaryAction
        primaryAction = nil // Sparkle replies must be invoked at most once.
        action?()
    }

    // Kept separate from the Sparkle item adapter so update stages can be exercised without a network feed.
    func receiveUpdate(version: String, downloaded: Bool, installing: Bool, automaticallyDownloadAllowed: Bool = true,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.version = version
        offeredUpdateAllowsAutomaticDownload = automaticallyDownloadAllowed
        state = downloaded || installing ? .readyToInstall(version: version) : .available(version: version)
        primaryAction = { [weak self] in
            self?.state = installing ? .installing(version: version) :
                (downloaded ? .preparing(version: version) : .downloading(version: version, progress: nil))
            reply(.install)
        }
        showReadyUpdateIfNeeded()
        if automaticallyDownloads && automaticallyDownloadAllowed && !downloaded && !installing { performPrimaryAction() }
    }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            version = appcastItem.displayVersionString
            self.state = .information(version: version)
            primaryAction = {
                if let url = appcastItem.infoURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                reply(.dismiss)
            }
            return
        }
        receiveUpdate(version: appcastItem.displayVersionString, downloaded: state.stage == .downloaded,
                      installing: state.stage == .installing, automaticallyDownloadAllowed: !appcastItem.isMajorUpgrade, reply: reply)
    }

    public func show(_ request: SPUUpdatePermissionRequest,
                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state = .checking
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        if reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) ||
            reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            state = .upToDate
        } else {
            state = .unavailable(error.localizedDescription)
        }
        acknowledgement()
    }

    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        primaryAction = nil
        state = .failed(error.localizedDescription)
        acknowledgement()
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedBytes = 0
        expectedBytes = 0
        state = .downloading(version: version, progress: nil)
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateProgress()
    }

    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (sum, overflow) = receivedBytes.addingReportingOverflow(length)
        receivedBytes = overflow ? .max : sum
        updateProgress()
    }

    private func updateProgress() {
        state = .downloading(version: version, progress: expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil)
    }

    public func showDownloadDidStartExtractingUpdate() { state = .preparing(version: version) }
    public func showExtractionReceivedProgress(_ progress: Double) {}

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state = .readyToInstall(version: version)
        primaryAction = { [weak self] in
            self?.state = .installing(version: self?.version ?? "")
            reply(.install)
        }
        showReadyUpdateIfNeeded()
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                     retryTerminatingApplication: @escaping () -> Void) {
        state = .installing(version: version)
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = .upToDate
        acknowledgement()
    }

    public func dismissUpdateInstallation() {
        primaryAction = nil
        switch state {
        case .failed, .upToDate, .unavailable, .installing: break
        default: state = .ready
        }
    }

    public func showUpdateInFocus() { showReadyUpdateIfNeeded() }

    private func showReadyUpdateIfNeeded() {
        guard case .readyToInstall = state else { return }
        onShowUpdate?()
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            // No-update is reported as an error by Sparkle, but is a successful check.
            if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == SUError.noUpdateError.rawValue {
                if state == .checking { state = .ready }
            } else {
                state = .failed(error.localizedDescription)
            }
        } else if state == .checking {
            state = .ready
        }
    }
}
