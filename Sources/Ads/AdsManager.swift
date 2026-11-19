import SwiftUI
import UIKit
import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform

/// Ad request rules that do not need the SDK, so they can be unit tested.
enum AdsRequestPolicy {
    /// Google content rating values ("G", "PG", "T", "MA").
    enum ContentRating: String {
        case general = "G"
        case parentalGuidance = "PG"
        case teen = "T"
        case matureAudience = "MA"
    }

    /// The App Store age rating answers give 4+ ("Advertising: Yes", every content descriptor None),
    /// so ads are limited to general audiences. Change this and `AdsManager.applyRequestConfiguration()` together.
    static let maxContentRating: ContentRating = .general

    /// Fluxa is a general photo editor and is not child-directed. These tags stay unset (nil), which is the SDK default.
    static let tagForChildDirectedTreatment: Bool? = nil
    static let tagForUnderAgeOfConsent: Bool? = nil

    /// Ads may be requested only after consent allows it and the SDK has finished starting.
    static func adsReady(canRequestAds: Bool, sdkReady: Bool) -> Bool {
        canRequestAds && sdkReady
    }

    /// Minimum gap between automatic restarts of the start sequence when the app becomes active.
    static let restartThrottle: TimeInterval = 30

    /// True when the start sequence should run again on becoming active: it ran before, ads are still not allowed,
    /// and something that can change by itself got in the way (no window for the form, or no network for the update).
    static func shouldRestartOnActive(
        startAttempted: Bool,
        canRequestAds: Bool,
        blockedByEnvironment: Bool,
        secondsSinceLastStart: TimeInterval?
    ) -> Bool {
        guard startAttempted, !canRequestAds, blockedByEnvironment else { return false }
        guard let elapsed = secondsSinceLastStart else { return true }
        return elapsed >= restartThrottle
    }
}

/// Owns the consent, tracking prompt and SDK start sequence.
///
/// Order: UMP consent -> (only if ads are allowed) ATT prompt -> MobileAds start.
/// Nothing here can crash when there is no window, no network, or no ad id.
@MainActor
final class AdsManager: ObservableObject {
    static let shared = AdsManager()

    /// Mirrors `ConsentInformation.shared.canRequestAds`. False until the first consent update finishes.
    @Published private(set) var canRequestAds: Bool = false

    /// True once `MobileAds.shared.start` reported completion. Banners and rewarded loads wait for it.
    @Published private(set) var sdkReady: Bool = false

    /// Bumped whenever consent state is re-read, so views that show the privacy row refresh.
    @Published private(set) var consentRevision: Int = 0

    /// Consent allows ads and the SDK is running.
    var adsReady: Bool { AdsRequestPolicy.adsReady(canRequestAds: canRequestAds, sdkReady: sdkReady) }

    private var startTask: Task<Void, Never>?
    private var sdkStarted = false
    private var startAttempted = false
    private var lastStartDate: Date?
    /// Set when the last run could not finish because there was no window or no network.
    private var blockedByEnvironment = false
    private var activeObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidBecomeActive() }
        }
    }

    /// True when Google says the user must be able to reopen their privacy choices (Settings row).
    var privacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    // MARK: Start

    /// Safe to call more than once. Concurrent callers share one run.
    func start() async {
        if let running = startTask {
            await running.value
            return
        }
        let task = Task { await self.runStartSequence() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func runStartSequence() async {
        startAttempted = true
        lastStartDate = Date()
        blockedByEnvironment = false

        // The consent form and the ATT prompt both need a foreground app with a window.
        await waitUntilReadyToPresent(timeout: 10)
        let hadWindow = AdsPresenter.isReady

        // 1. Consent (UMP). Offline or failed updates are tolerated: a cached decision may still allow ads.
        let updateError = await requestConsentInfoUpdate()
        if let updateError = updateError {
            AdsLog.logger.info("Consent info update failed: \(updateError.localizedDescription, privacy: .public)")
            blockedByEnvironment = true
        } else if let presenter = AdsPresenter.topViewController() {
            do {
                try await ConsentForm.loadAndPresentIfRequired(from: presenter)
            } catch {
                AdsLog.logger.info("Consent form failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            blockedByEnvironment = true
        }
        if !hadWindow { blockedByEnvironment = true }
        refreshConsentState()
        guard canRequestAds else { return }
        blockedByEnvironment = false

        // 2. ATT, only after consent allows ads. The system shows this at most once.
        await requestTrackingIfNeeded()

        // 3. Start the SDK once.
        startSDKIfNeeded()
    }

    /// B6: if the first run had no window (or no network) and ads are still not allowed, try again when the app is active.
    private func handleDidBecomeActive() {
        let elapsed = lastStartDate.map { Date().timeIntervalSince($0) }
        guard startTask == nil,
              AdsRequestPolicy.shouldRestartOnActive(
                startAttempted: startAttempted,
                canRequestAds: canRequestAds,
                blockedByEnvironment: blockedByEnvironment,
                secondsSinceLastStart: elapsed
              ) else { return }
        Task { await self.start() }
    }

    private func requestConsentInfoUpdate() async -> Error? {
        let parameters = consentRequestParameters()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func consentRequestParameters() -> RequestParameters {
        let parameters = RequestParameters()
        #if DEBUG
        let ids = AdsConfiguration.testDeviceIdentifiers
        if !ids.isEmpty {
            let debug = DebugSettings()
            debug.testDeviceIdentifiers = ids
            // debug.geography = .EEA   // uncomment to test the European consent form
            parameters.debugSettings = debug
        }
        #endif
        return parameters
    }

    private func requestTrackingIfNeeded() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        // The system ignores the request unless the app is active.
        await waitUntilReadyToPresent(timeout: 10)
        guard UIApplication.shared.applicationState == .active else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// Request settings shared by every ad. Must run before `MobileAds.shared.start`.
    private func applyRequestConfiguration() {
        let configuration = MobileAds.shared.requestConfiguration
        let ids = AdsConfiguration.testDeviceIdentifiers
        if !ids.isEmpty {
            configuration.testDeviceIdentifiers = ids
        }
        // Matches AdsRequestPolicy.maxContentRating (.general, "G") and the 4+ age rating.
        configuration.maxAdContentRating = .general
        // tagForChildDirectedTreatment and tagForUnderAgeOfConsent are deliberately left unset: the app is not child-directed.
    }

    private func startSDKIfNeeded() {
        guard !sdkStarted else { return }
        sdkStarted = true
        applyRequestConfiguration()
        MobileAds.shared.start(completionHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.sdkReady { self.sdkReady = true }
            }
        })
    }

    private func waitUntilReadyToPresent(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !AdsPresenter.isReady && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func refreshConsentState() {
        let allowed = ConsentInformation.shared.canRequestAds
        if canRequestAds != allowed { canRequestAds = allowed }
        consentRevision += 1
    }

    // MARK: Privacy options (Settings row)

    /// Shows Google's privacy options form. Does nothing when it is not required or no window exists.
    func presentPrivacyOptions() {
        guard privacyOptionsRequired, let presenter = AdsPresenter.topViewController() else { return }
        Task { [weak self] in
            do {
                try await ConsentForm.presentPrivacyOptionsForm(from: presenter)
            } catch {
                AdsLog.logger.info("Privacy options form failed: \(error.localizedDescription, privacy: .public)")
            }
            guard let self = self else { return }
            self.refreshConsentState()
            if self.canRequestAds && !self.sdkStarted {
                await self.start()
            }
        }
    }

    #if DEBUG
    /// Debug only: forget the stored consent so the form can be tested again.
    func resetConsentForTesting() {
        ConsentInformation.shared.reset()
        canRequestAds = false
        sdkStarted = false
        sdkReady = false
        consentRevision += 1
    }
    #endif
}
