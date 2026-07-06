import XCTest

final class KLMSiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureMainScreen() throws {
        try captureMainScreen(runningFixture: false)
    }

    @MainActor
    func testCaptureRunningMainScreen() throws {
        try captureMainScreen(runningFixture: true)
    }

    @MainActor
    private func captureMainScreen(runningFixture: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments.append("KLMS_UI_TEST_CAPTURE")
        if runningFixture {
            app.launchArguments.append("KLMS_UI_TEST_RUNNING_STATE")
        }
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12), "KLMS Sync did not enter the foreground.")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "KLMS Sync did not show a window.")

        normalizeCaptureOrientation()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attachScreenshot(named: screenshotName(prefix: "main"))
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func screenshotName(prefix: String) -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let scale = Int(UIScreen.main.scale.rounded())
        return "klms-\(idiom)-\(prefix)-@\(scale)x"
    }

    @MainActor
    private func normalizeCaptureOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeRight
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }
}
