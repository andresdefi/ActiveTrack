import XCTest

final class ActiveTrackUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSmokeWindowStartPauseAndTargetReveal() {
        let app = makeApp(arguments: [
            "-open-ui-smoke-window"
        ])

        app.launch()

        XCTAssertTrue(app.windows["ActiveTrack Smoke Tests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["activeTrack.uiSmokeTitle"].exists)

        let timerToggleButton = app.buttons["activeTrack.timerToggleButton"]
        XCTAssertTrue(timerToggleButton.waitForExistence(timeout: 2))
        timerToggleButton.click()
        XCTAssertTrue(timerToggleButton.label.contains("Pause"))

        let targetToggle = app.descendants(matching: .any)["activeTrack.targetToggle"]
        XCTAssertTrue(targetToggle.waitForExistence(timeout: 2))
        let targetSetButton = app.buttons["activeTrack.targetSetButton"]
        if !targetSetButton.exists {
            targetToggle.click()
        }

        XCTAssertTrue(targetSetButton.waitForExistence(timeout: 2))
    }

    func testDashboardWindowLaunchesWithSeededHistory() {
        let app = makeApp(arguments: [
            "-open-dashboard-on-launch",
            "-seed-sample-history"
        ])

        app.launch()

        XCTAssertTrue(app.windows["ActiveTrack Dashboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activeTrack.overviewButton"].waitForExistence(timeout: 2))
    }

    func testSettingsWindowShowsDataTools() {
        let app = makeApp(arguments: [
            "-open-settings-on-launch"
        ])

        app.launch()

        XCTAssertTrue(app.windows["ActiveTrack Settings"].waitForExistence(timeout: 5))

        let dataTab = app.descendants(matching: .any)["Data"]
        XCTAssertTrue(dataTab.waitForExistence(timeout: 2))
        dataTab.click()

        XCTAssertTrue(app.buttons["activeTrack.exportCSVButton"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["activeTrack.createBackupButton"].exists)
    }

    private func makeApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + arguments
        return app
    }
}
