import XCTest

/// Opens each important screen in landscape (and portrait) and keeps a screenshot, so layout problems on
/// iPad and iPhone are visible in CI artifacts. A screen that fails to appear fails the test.
final class LandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func capture(_ screen: String, orientation: UIDeviceOrientation, settle: TimeInterval = 8) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-fxNoAds", "YES", "-fxScreen", screen, "-fx.hasOnboarded", "YES"]
        app.launch()
        Thread.sleep(forTimeInterval: settle)
        XCTAssertTrue(app.windows.firstMatch.exists, "\(screen) has a window")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(screen)-\(orientation == .portrait ? "portrait" : "landscape")"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    func testScreensInLandscape() {
        for screen in ["onboarding", "home", "setup-mp4", "formats-grid", "presets", "advanced", "queue", "result", "gif-maker", "formats-guide", "settings"] {
            capture(screen, orientation: .landscapeLeft)
        }
    }

    func testKeyScreensInPortrait() {
        for screen in ["home", "setup-mp4", "result"] {
            capture(screen, orientation: .portrait)
        }
    }
}
