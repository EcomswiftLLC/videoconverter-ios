import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - Pure rules

/// Load and retry rules for one banner slot. No SDK, so it can be unit tested.
struct BannerSlotLogic: Equatable {
    enum Status: Equatable { case idle, loading, loaded, failed }
    enum FailureAction: Equatable {
        /// A refresh failed after an ad was shown. The SDK keeps the previous ad on screen, so do nothing.
        case ignore
        case retry(after: TimeInterval)
        case giveUp
    }

    static let maxRetries = 3
    static let retryDelay: TimeInterval = 60
    /// A banner is requested again only when the width moved by at least this many points (a rotation or a split-view
    /// resize does; a 1 pt layout wobble does not), so layout churn cannot cause a stream of ad requests.
    static let minWidthChange: CGFloat = 16

    private(set) var status: Status = .idle
    private(set) var width: CGFloat = 0
    private(set) var hasLoadedAd = false
    private(set) var retryCount = 0

    var isShowing: Bool { status == .loaded }

    /// Returns true when a new request must be sent for the new width (B7: the status is reset).
    /// The first width always counts; later ones only when they differ enough (see `minWidthChange`).
    mutating func widthChanged(to newWidth: CGFloat) -> Bool {
        let rounded = newWidth.rounded(.down)
        guard rounded >= 1 else { return false }
        if width >= 1, abs(rounded - width) < Self.minWidthChange { return false }
        width = rounded
        status = .loading
        hasLoadedAd = false
        retryCount = 0
        return true
    }

    mutating func didReceiveAd() {
        status = .loaded
        hasLoadedAd = true
        retryCount = 0
    }

    /// B5: a failure after a successful load is a refresh failure and is ignored.
    mutating func didFail() -> FailureAction {
        if hasLoadedAd { return .ignore }
        status = .failed
        guard retryCount < Self.maxRetries else { return .giveUp }
        retryCount += 1
        return .retry(after: Self.retryDelay)
    }

    /// Ads stopped being allowed, or the slot was torn down.
    mutating func reset() {
        self = BannerSlotLogic()
    }
}

/// Size rules for banners. Inline adaptive is the right size for scrolling content.
enum BannerSizing {
    /// Upper bound for the inline adaptive height, so a banner never dominates a browse screen.
    static let inlineMaxHeight: CGFloat = 150
    /// Spacing kept around an inline banner once it shows (at least 16 pt from neighbouring rows).
    static let inlineTopSpacing: CGFloat = 24
    static let inlineBottomSpacing: CGFloat = 16
}

// MARK: - Slot (one BannerView per screen)

/// Owns one `BannerView` for one screen. Keep it in a `@StateObject` on the screen (B4), so List row recycling
/// or a rebuilt row reuses the same banner instead of sending a new request.
@MainActor
final class BannerAdSlot: NSObject, ObservableObject, BannerViewDelegate {
    @Published private(set) var logic = BannerSlotLogic()
    /// Height of the ad that is on screen. Inline adaptive ads choose their own height.
    @Published private(set) var loadedHeight: CGFloat = 0

    private var banner: BannerView?
    private var retryTask: Task<Void, Never>?
    private var isVisible = false
    private var retryWhenVisible = false

    var isShowing: Bool { logic.isShowing && loadedHeight > 0 }

    /// Returns the banner, creating it once. Called by the UIKit bridge.
    func bannerView(unitID: String) -> BannerView {
        if let existing = banner { return existing }
        let view = BannerView()
        view.adUnitID = unitID
        view.delegate = self
        view.rootViewController = AdsPresenter.topViewController()
        banner = view
        return view
    }

    /// Loads for a width. Only sends a request when the width really changed.
    func apply(width: CGFloat) {
        guard let banner = banner else { return }
        guard logic.widthChanged(to: width) else { return }
        cancelRetry()
        loadedHeight = 0
        banner.adSize = inlineAdaptiveBanner(width: logic.width, maxHeight: BannerSizing.inlineMaxHeight)
        if banner.rootViewController == nil {
            banner.rootViewController = AdsPresenter.topViewController()
        }
        banner.load(Request())
    }

    /// Ads are not allowed any more (consent withdrawn) or the screen no longer wants a banner.
    func suspend() {
        cancelRetry()
        banner?.delegate = nil
        banner?.removeFromSuperview()
        banner = nil
        logic.reset()
        loadedHeight = 0
    }

    /// Retries are cancelled while the banner is off screen and resumed when it comes back.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            if retryWhenVisible {
                retryWhenVisible = false
                scheduleRetry(after: 1)
            }
        } else if retryTask != nil {
            cancelRetry()
            retryWhenVisible = true
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func scheduleRetry(after delay: TimeInterval) {
        cancelRetry()
        guard isVisible else {
            retryWhenVisible = true
            return
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self = self, let banner = self.banner else { return }
            self.retryTask = nil
            guard AdsManager.shared.adsReady else { return }
            banner.load(Request())
        }
    }

    // MARK: BannerViewDelegate

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        logic.didReceiveAd()
        // Inline adaptive ads report their real height in `adSize` once loaded. Fall back to the standard 50 pt.
        let reported = bannerView.adSize.size.height
        let height = reported > 0 ? reported : max(bannerView.frame.height, 50)
        if abs(height - loadedHeight) >= 0.5 { loadedHeight = height }
        bannerView.superview?.setNeedsLayout()
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        AdsLog.logger.info("Banner failed to load: \(error.localizedDescription, privacy: .public)")
        switch logic.didFail() {
        case .ignore, .giveUp:
            break
        case .retry(let delay):
            scheduleRetry(after: delay)
        }
    }
}

// MARK: - SwiftUI views

/// Adaptive banner for browse screens only (Home, My Resumes, Templates, Cover Letters, Profile).
///
/// Takes zero height until an ad has loaded, and stays collapsed when the unit id is missing, consent does not allow ads,
/// or the SDK has not finished starting. Place it as the last item of scrolling content (inline adaptive size),
/// never next to a primary button, never on empty, no-results or error states, and never on the editor, preview or
/// export screens. Prefer `CKInlineBanner`, which adds the spacing and the "Advertisement" label.
@MainActor
struct BannerAdView: View {
    @StateObject private var ownSlot = BannerAdSlot()
    private let externalSlot: BannerAdSlot?
    private let spacing: EdgeInsets
    private let showsLabel: Bool

    /// Contract initialiser: the view owns its slot.
    init() {
        self.externalSlot = nil
        self.spacing = EdgeInsets()
        self.showsLabel = false
    }

    /// Uses a slot owned by the screen (`@StateObject private var bannerSlot = BannerAdSlot()`), so the same
    /// banner survives List row recycling. `spacing` and the label apply only while an ad is showing.
    init(slot: BannerAdSlot, spacing: EdgeInsets = EdgeInsets(), showsLabel: Bool = false) {
        self.externalSlot = slot
        self.spacing = spacing
        self.showsLabel = showsLabel
    }

    var body: some View {
        BannerAdContent(slot: externalSlot ?? ownSlot, spacing: spacing, showsLabel: showsLabel)
    }
}

/// End-of-content banner with built-in spacing: 24 pt above, 16 pt below and a small "Advertisement" label,
/// all only while an ad is showing. Collapses to nothing otherwise. Use this on every browse screen.
@MainActor
struct CKInlineBanner: View {
    @StateObject private var ownSlot = BannerAdSlot()
    private let externalSlot: BannerAdSlot?

    init() { self.externalSlot = nil }

    /// Pass the screen's own slot when the banner sits inside a List.
    init(slot: BannerAdSlot) { self.externalSlot = slot }

    var body: some View {
        BannerAdContent(
            slot: externalSlot ?? ownSlot,
            spacing: EdgeInsets(
                top: BannerSizing.inlineTopSpacing,
                leading: 0,
                bottom: BannerSizing.inlineBottomSpacing,
                trailing: 0
            ),
            showsLabel: true
        )
    }
}

@MainActor
private struct BannerAdContent: View {
    @ObservedObject var slot: BannerAdSlot
    let spacing: EdgeInsets
    let showsLabel: Bool

    @ObservedObject private var ads = AdsManager.shared
    @State private var availableWidth: CGFloat = 0

    private var unitID: String? { AdsConfiguration.bannerUnitID }

    private var canShow: Bool {
        unitID != nil && ads.adsReady && availableWidth >= 1
    }

    var body: some View {
        let showing = slot.isShowing
        VStack(spacing: FX.Space.xs) {
            if let unitID = unitID, canShow {
                if showsLabel && showing {
                    Text("Advertisement")
                        .font(FX.Font.caption)
                        .foregroundStyle(FX.Palette.mist)
                        .accessibilityHidden(true)
                }
                BannerRepresentable(slot: slot, unitID: unitID, width: availableWidth)
                    .frame(width: availableWidth, height: showing ? slot.loadedHeight : 0)
                    .clipped()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Advertisement"))
                    .accessibilityHidden(!showing)
            }
        }
        .padding(showing ? spacing : EdgeInsets())
        .frame(maxWidth: .infinity)
        .background(widthReader)
        .onAppear { slot.setVisible(true) }
        .onDisappear { slot.setVisible(false) }
        .onChange(of: ads.adsReady) { _, ready in
            if !ready { slot.suspend() }
        }
    }

    /// Measures the width offered by the parent without taking any space of its own.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { updateWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, newValue in updateWidth(newValue) }
        }
    }

    private func updateWidth(_ width: CGFloat) {
        let rounded = width.rounded(.down)
        if abs(rounded - availableWidth) >= 1 { availableWidth = rounded }
    }
}

// MARK: - UIKit bridge

private struct BannerRepresentable: UIViewRepresentable {
    let slot: BannerAdSlot
    let unitID: String
    let width: CGFloat

    func makeUIView(context: Context) -> BannerContainerView {
        let container = BannerContainerView()
        container.install(slot.bannerView(unitID: unitID))
        scheduleApply()
        return container
    }

    func updateUIView(_ uiView: BannerContainerView, context: Context) {
        uiView.install(slot.bannerView(unitID: unitID))
        scheduleApply()
    }

    /// The slot publishes changes, so it is updated after the current SwiftUI update pass.
    private func scheduleApply() {
        let slot = self.slot
        let width = self.width
        Task { @MainActor in slot.apply(width: width) }
    }
}

/// Hosts the banner at its natural size and clips it, so SwiftUI can collapse the row to zero height.
final class BannerContainerView: UIView {
    private weak var banner: BannerView?

    /// Moves the slot's banner into this container (a rebuilt row gets the same banner, no new request).
    func install(_ view: BannerView) {
        clipsToBounds = true
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        banner = view
        setNeedsLayout()
        updateRootViewController()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let banner = banner else { return }
        let size = banner.adSize.size
        let width = size.width > 0 ? size.width : bounds.width
        let height = size.height > 0 ? size.height : bounds.height
        banner.frame = CGRect(
            x: max(0, (bounds.width - width) / 2),
            y: 0,
            width: width,
            height: height
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRootViewController()
    }

    private func updateRootViewController() {
        guard window != nil, let banner = banner else { return }
        if let owner = nearestViewController() {
            banner.rootViewController = owner
        }
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
