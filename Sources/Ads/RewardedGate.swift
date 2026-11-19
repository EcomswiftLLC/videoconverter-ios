import SwiftUI
import UIKit
import GoogleMobileAds

/// Pure rules for the rewarded export gate, so they can be unit tested.
struct RewardedPolicy: Equatable {
    /// One watched ad covers every export for this long, so saving and then sharing the same result asks only once.
    static let graceInterval: TimeInterval = 120

    /// Longest an export that a watched ad paid for is assumed to be running (a safety net if it never reports back).
    static let longestExport: TimeInterval = 30 * 60

    private(set) var lastReward: Date?
    /// Set when the export a watched ad paid for starts, cleared when that export ends.
    private(set) var coveredExportStart: Date?

    /// True when the person should be offered an ad before this export. Never when no ad is ready.
    func shouldOffer(adReady: Bool, now: Date = Date()) -> Bool {
        guard adReady else { return false }
        if isWithinGrace(now: now) { return false }
        return true
    }

    /// A watched ad pays for the export that follows it.
    mutating func didEarnReward(now: Date = Date()) {
        lastReward = now
        coveredExportStart = now
    }

    /// The export the ad paid for ended, whether it worked, failed or was cancelled. The two minutes count from here, so
    /// a long render followed by Save and then Share still asks only once.
    mutating func exportDidEnd(now: Date = Date()) {
        guard coveredExportStart != nil else { return }
        coveredExportStart = nil
        lastReward = now
    }

    /// True while a watched ad still covers exports: during the export it paid for, and for two minutes after it ends.
    func isWithinGrace(now: Date = Date()) -> Bool {
        if let start = coveredExportStart, now.timeIntervalSince(start) < Self.longestExport { return true }
        guard let lastReward else { return false }
        return now.timeIntervalSince(lastReward) < Self.graceInterval
    }

    /// What to do when the person asks to save or share.
    enum Decision: Equatable {
        /// Run the export now (no ads, no ad ready and none coming, or an ad was just watched).
        case exportNow
        /// Ask whether to watch the ready ad.
        case offerAd
        /// The ad was closed early and a new one is loading right now: wait for it (briefly) instead of letting an
        /// immediate second tap export for free.
        case waitForAd
    }

    /// `reloadInFlightAfterEarlyClose` is true only after an ad was closed before its reward and its replacement is still
    /// loading. Waiting is capped by the caller (`maxWait`), so an export is never blocked for good.
    func decision(adsReady: Bool, adReady: Bool, reloadInFlightAfterEarlyClose: Bool, now: Date = Date()) -> Decision {
        guard adsReady else { return .exportNow }
        if shouldOffer(adReady: adReady, now: now) { return .offerAd }
        if !adReady && reloadInFlightAfterEarlyClose && !isWithinGrace(now: now) { return .waitForAd }
        return .exportNow
    }

    /// Longest a tap waits for the replacement ad after an early close, in seconds.
    static let maxWait: TimeInterval = 6
}

/// Fluxa is free. Saving or sharing a finished photo is paid for by watching one short rewarded ad, which the person
/// chooses to watch. When no ad is ready (offline, no fill, consent still pending) the export simply goes ahead.
@MainActor
final class RewardedGate: NSObject, FullScreenContentDelegate {
    static let shared = RewardedGate()

    private var ad: RewardedAd?
    private var loadedAt: Date?
    private var loading = false
    private var policy = RewardedPolicy()
    private let maxAge: TimeInterval = 55 * 60

    private var failedLoads = 0
    private let retryDelays: [UInt64] = [5, 15, 45]

    private var earned = false
    private var proceed: (() -> Void)?
    /// Set when an ad is closed before its reward, until the replacement ad is ready (or the person gave up waiting).
    private var earlyCloseReloadPending = false
    private var waiting = false
    private var waitCancelled = false

    private override init() { super.init() }

    private var hasUsableAd: Bool {
        guard ad != nil, let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < maxAge
    }

    /// Call when the app may request ads (after consent and SDK start), and again after each ad.
    func preloadIfPossible() {
        guard AdsManager.shared.adsReady, !loading, !hasUsableAd else { return }
        guard let unitID = AdsConfiguration.rewardedUnitID else { return }
        loading = true
        Task { [weak self] in
            do {
                let loaded = try await RewardedAd.load(with: unitID, request: Request())
                guard let self else { return }
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.loadedAt = Date()
                self.loading = false
                self.failedLoads = 0
                self.earlyCloseReloadPending = false
            } catch {
                AdsLog.logger.info("Rewarded ad failed to load: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.loading = false
                // One no-fill or network hiccup must not leave the session without an ad: try again a few times.
                if self.failedLoads < self.retryDelays.count {
                    let delay = self.retryDelays[self.failedLoads]
                    self.failedLoads += 1
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    self.preloadIfPossible()
                }
            }
        }
    }

    /// Runs `action` right away when no ad is needed, otherwise asks first. The action runs only after the ad was
    /// watched to the end, or when the ad could not be shown. "Not now" runs nothing.
    func requestExport(_ action: @escaping () -> Void) {
        guard !waiting else { return }
        let decision = policy.decision(
            adsReady: AdsManager.shared.adsReady,
            adReady: hasUsableAd,
            reloadInFlightAfterEarlyClose: earlyCloseReloadPending && loading
        )
        switch decision {
        case .exportNow:
            action()
            preloadIfPossible()
        case .offerAd:
            guard let presenter = AdsPresenter.topViewController() else {
                action()
                preloadIfPossible()
                return
            }
            presentOffer(from: presenter, action: action)
        case .waitForAd:
            waitForReplacement(then: action)
        }
    }

    private func presentOffer(from presenter: UIViewController, action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "Watch a short ad to export",
            message: "Fluxa is free because of ads. Watch one ad to the end to save or share your animation.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Watch ad", style: .default) { [weak self] _ in
            self?.show(then: action)
        })
        presenter.present(alert, animated: true)
    }

    /// After an early close the next ad is already loading. Wait up to `RewardedPolicy.maxWait` seconds for it. If it does
    /// not arrive in time, the export goes ahead, so a missing ad never blocks anyone for good.
    private func waitForReplacement(then action: @escaping () -> Void) {
        guard let presenter = AdsPresenter.topViewController() else {
            earlyCloseReloadPending = false
            action()
            preloadIfPossible()
            return
        }
        waiting = true
        waitCancelled = false
        let alert = UIAlertController(title: "Getting the next ad ready", message: "Just a moment.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.waitCancelled = true
        })
        presenter.present(alert, animated: true)
        Task { [weak self] in
            var waited: TimeInterval = 0
            while waited < RewardedPolicy.maxWait {
                guard let current = self else { return }
                if current.waitCancelled || current.hasUsableAd || !current.loading { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            guard let gate = self else { return }
            gate.waiting = false
            if gate.waitCancelled {
                alert.dismiss(animated: true)
                return
            }
            gate.earlyCloseReloadPending = false
            alert.dismiss(animated: true) {
                if gate.hasUsableAd, let top = AdsPresenter.topViewController() {
                    gate.presentOffer(from: top, action: action)
                } else {
                    action()
                    gate.preloadIfPossible()
                }
            }
        }
    }

    /// Call when an export finishes, fails or is cancelled. Restarts the two-minute cover of a watched ad.
    func exportEnded() {
        policy.exportDidEnd()
    }

    private func show(then action: @escaping () -> Void) {
        guard let ad, let presenter = AdsPresenter.topViewController() else {
            action()
            return
        }
        self.ad = nil
        earned = false
        proceed = action
        ad.present(from: presenter) { [weak self] in
            self?.earned = true
        }
    }

    // MARK: FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        let action = proceed
        proceed = nil
        if earned {
            policy.didEarnReward()
            earned = false
            earlyCloseReloadPending = false
            action?()
        } else if action != nil {
            // Closed before the reward: nothing is exported, and the person is told why. The next ad is loading now, so a
            // quick second tap waits for it (see `requestExport`) instead of exporting for free.
            earlyCloseReloadPending = true
            preloadIfPossible()
            notifyEarlyClose()
            return
        }
        preloadIfPossible()
    }

    private func notifyEarlyClose() {
        guard let presenter = AdsPresenter.topViewController() else { return }
        let alert = UIAlertController(
            title: "Watch the whole ad to export",
            message: "The ad was closed before it finished, so nothing was saved or shared. Tap Save or Share to try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        AdsLog.logger.info("Rewarded ad failed to present: \(error.localizedDescription, privacy: .public)")
        // The ad is what failed, not the person: let the export through.
        let action = proceed
        proceed = nil
        earned = false
        action?()
        preloadIfPossible()
    }
}
