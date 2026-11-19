import XCTest

/// Walks the real first-run path on the simulator: welcome -> sample clip -> convert -> result.
/// Ads are switched off for the run (`-fxNoAds YES`) so a consent form cannot cover the controls.
final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], onboarded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fxNoAds", "YES", "-fx.hasOnboarded", onboarded ? "YES" : "NO"] + extra
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFirstRunToConvertedFile() throws {
        let app = launch()
        let start = app.buttons["getStarted"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "welcome screen")
        attach(app, "01-welcome")
        start.tap()

        let sample = app.buttons["sample-waterfall"]
        XCTAssertTrue(sample.waitForExistence(timeout: 20), "home screen with sample clips")
        attach(app, "02-home")
        sample.tap()

        let convert = app.buttons["convertButton"]
        XCTAssertTrue(convert.waitForExistence(timeout: 30), "setup screen")
        attach(app, "03-setup")

        // Pick a different target to prove the format grid responds.
        let mov = app.buttons["format-mov"]
        if mov.waitForExistence(timeout: 5) { mov.tap() }
        convert.tap()

        let done = app.buttons["done"]
        XCTAssertTrue(done.waitForExistence(timeout: 180), "the conversion should finish and show the result")
        attach(app, "04-result")
        XCTAssertTrue(app.buttons["shareAll"].exists || app.buttons["saveFiles"].exists, "result actions")
    }

    func testAudioExtractionFromSample() throws {
        let app = launch(onboarded: true)
        let sample = app.buttons["sample-waterfall"]
        XCTAssertTrue(sample.waitForExistence(timeout: 20))
        sample.tap()
        let m4a = app.buttons["format-m4a"]
        XCTAssertTrue(m4a.waitForExistence(timeout: 30))
        if !m4a.isHittable { app.swipeUp() }
        m4a.tap()
        let convert = app.buttons["convertButton"]
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        convert.tap()
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 180))
        attach(app, "audio-result")
    }
}
