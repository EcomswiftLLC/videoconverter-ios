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
        let label = orientation == .portrait ? "portrait" : "landscape"
        let snapshotPath = "/tmp/fxsnap-\(screen)-\(label).png"
        try? FileManager.default.removeItem(atPath: snapshotPath)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-fxNoAds", "YES", "-fxScreen", screen, "-fx.hasOnboarded", "YES", "-fxSnapshot", snapshotPath]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        // Rotate after launch, then let the layout settle.
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: settle + 3)
        XCTAssertTrue(app.windows.firstMatch.exists, "\(screen) has a window")
        // The app's own render of its window is the picture to review: the simulator's capture of a rotated app is cropped and sideways.
        if let data = FileManager.default.contents(atPath: snapshotPath), let image = UIImage(data: data) {
            let shot = XCTAttachment(image: image)
            shot.name = "\(screen)-\(label)"
            shot.lifetime = .keepAlways
            add(shot)
        } else {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(screen)-\(label)-raw"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.terminate()
    }

    func testScreensInLandscape() {
        for screen in ["onboarding", "home", "setup-mp4", "formats-grid", "presets", "advanced", "queue", "result", "gif-maker", "formats-guide", "settings"] {
            capture(screen, orientation: .landscapeLeft, settle: screen == "result" ? 70 : 8)
        }
    }

    func testKeyScreensInPortrait() {
        for screen in ["home", "setup-mp4", "result"] {
            capture(screen, orientation: .portrait, settle: screen == "result" ? 70 : 8)
        }
    }
}
