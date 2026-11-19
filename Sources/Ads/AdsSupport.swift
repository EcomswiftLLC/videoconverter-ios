import UIKit
import os

/// Shared logger for everything in the Ads module. Never log personal data here.
enum AdsLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ecomswift.fluxa",
        category: "Ads"
    )
}

/// Reads ad configuration from Info.plist (filled from Config/*.xcconfig). Ids are never hardcoded in Swift.
enum AdsConfiguration {
    static let bannerKey = "FXBannerAdUnitID"
    static let rewardedKey = "FXRewardedAdUnitID"

    static var bannerUnitID: String? { unitID(forKey: bannerKey) }
    static var rewardedUnitID: String? { unitID(forKey: rewardedKey) }

    static func unitID(forKey key: String, bundle: Bundle = .main) -> String? {
        normalizedUnitID(bundle.object(forInfoDictionaryKey: key))
    }

    /// Returns nil for a missing value, a non-string, an empty string, or an unresolved build setting such as "$(ADMOB_BANNER_UNIT_ID)".
    static func normalizedUnitID(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("$(") || trimmed.hasPrefix("${") { return nil }
        return trimmed
    }

    // MARK: Test devices (debug builds only)

    /// DEBUG ONLY. Add your own device's hashed id between the brackets to get test ads on a real device.
    /// The id is printed in the Xcode console on the first ad request, in the line that starts with
    /// "To get test ads on this device, set: ...". Leave this list empty for anything you commit or ship.
    ///
    /// To test the consent form for Europe, also set `debug.geography = .EEA` in `AdsManager.consentRequestParameters()`.
    private static let debugTestDeviceIdentifiers: [String] = [
        // "00000000000000000000000000000000",
    ]

    /// Always empty in Release builds.
    static var testDeviceIdentifiers: [String] {
        #if DEBUG
        return debugTestDeviceIdentifiers
        #else
        return []
        #endif
    }
}

/// Finds the view controller that ads, consent forms and share sheets should be presented from.
@MainActor
enum AdsPresenter {
    /// Returns nil (never crashes) when the app has no window yet, for example very early in launch.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        guard let scene = scene else { return nil }
        let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// True when the app is in the foreground and a presenter exists.
    static var isReady: Bool {
        UIApplication.shared.applicationState == .active && topViewController() != nil
    }
}
