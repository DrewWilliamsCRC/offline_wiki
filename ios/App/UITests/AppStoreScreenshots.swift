import XCTest

/// Takes the App Store's screenshots (see ios/AppStore.md), against the full English Wikipedia.
/// Run on a fresh app, so the lists hold only what this test reads, once on a 6.9" iPhone and once
/// on a 13" iPad:
///   xcrun simctl uninstall <simulator> dev.offlinewiki.reader
///   xcrun simctl status_bar <simulator> override --time 9:41 --batteryState charged --batteryLevel 100
///   TEST_RUNNER_WIKI_DIR=<folder> TEST_RUNNER_APP_STORE_SHOT_DIR=<folder> xcodebuild test ... \
///     -only-testing:WikiReaderUITests/AppStoreScreenshots
/// The downloads screen reads the published catalog, so this needs the network.
final class AppStoreScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var folder = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let wiki = ProcessInfo.processInfo.environment["WIKI_DIR"] ?? ""
        folder = ProcessInfo.processInfo.environment["APP_STORE_SHOT_DIR"] ?? ""
        try XCTSkipIf(wiki.isEmpty || folder.isEmpty, "set TEST_RUNNER_WIKI_DIR and TEST_RUNNER_APP_STORE_SHOT_DIR")
        app = XCUIApplication()
        app.launchEnvironment["WIKI_DIR"] = wiki
        app.launchArguments = ["-reading", "NO"]
        app.launch()
    }

    func testScreenshots() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the search screen did not appear")

        // Search: results as the reader types, well-known articles first.
        field.tap()
        field.typeText("apollo")
        XCTAssertTrue(app.staticTexts["Apollo 11"].waitForExistence(timeout: 10), "no results")
        sleep(1)
        shot("2-search")

        // Sections: the menu of a long article, opened at its top.
        backToSearch()
        field.tap()
        field.typeText("photosyn")
        open("Photosynthesis")
        app.buttons["Sections"].tap()
        let section = "Light-dependent reactions"
        XCTAssertTrue(app.buttons[section].waitForExistence(timeout: 10), "the menu does not list the section")
        sleep(1)
        shot("3-sections")
        app.buttons[section].tap()
        sleep(3) // the place is noted a moment after the page stops moving
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10), "the menu has no Save")
        app.buttons["Save"].tap()
        sleep(1)

        // An article: Paris, with its infobox.
        search("Moon")
        search("Paris")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Country"].waitForExistence(timeout: 20), "the infobox did not load")
        sleep(2)
        shot("1-article")

        // The search screen with nothing typed: Saved, and Recently read with how far each got.
        // Started afresh, so that the search field is not active and the keyboard is down.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 20), "no Saved list")
        XCTAssertTrue(app.staticTexts["Recently read"].exists, "no Recently read list")
        sleep(1)
        shot("4-lists")

        // Downloads: every size, from the published catalog.
        app.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["All of English Wikipedia"].waitForExistence(timeout: 30), "the list of downloads did not load")
        sleep(2)
        shot("5-downloads")
        app.buttons["Done"].tap()
    }

    /// From an article or the search screen, opens the article titled `title` by searching for it.
    private func search(_ title: String) {
        backToSearch()
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText(title.lowercased())
        open(title)
    }

    private func open(_ title: String) {
        let result = app.staticTexts[title].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no \(title) result")
        result.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts[title].firstMatch.waitForExistence(timeout: 20), "\(title) did not load")
    }

    /// Leaves an article, if one is showing, and empties the search field. (On iPad the field
    /// loses the keyboard when emptied, so callers tap it before typing.)
    private func backToSearch() {
        let field = app.searchFields.firstMatch
        // A tap on Back while a menu is still closing can go nowhere, so it is tried again.
        for _ in 0..<3 where !field.waitForExistence(timeout: 3) {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search screen did not come back")
        if field.buttons["Clear text"].exists { field.buttons["Clear text"].firstMatch.tap() }
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}
