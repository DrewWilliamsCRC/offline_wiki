import XCTest

/// Updates an older snapshot to the catalog's, then deletes it, for real: the best-known articles'
/// introductions (about 0.3 GB). It needs the app to hold an older snapshot of that book and
/// nothing else, which only the Mac can arrange, so it runs only when asked:
///   xcrun simctl uninstall <simulator> dev.offlinewiki.reader
///   xcrun simctl install <simulator> <WikiReader.app>
///   folder="$(xcrun simctl get_app_container <simulator> dev.offlinewiki.reader data)/Documents"
///   cp <the catalog's top_mini .zim> "$folder/wikipedia_en_top_mini_2026-06.zim"      # a month before it
///   cp <its .zim.idx> "$folder/wikipedia_en_top_mini_2026-06.zim.idx"
///   TEST_RUNNER_UPDATE=1 xcodebuild test-without-building ... -only-testing:WikiReaderUITests/UpdateUITests
/// The copy is the catalog's own file under an earlier name, which is all the app goes by.
final class UpdateUITests: XCTestCase {
    private var app: XCUIApplication!
    private let book = "wikipedia_en_top_mini"
    private let title = "Best-known articles, introductions only"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATE"] == "1",
                          "set TEST_RUNNER_UPDATE=1 after putting an older snapshot in the app (see the comment above)")
        app = XCUIApplication()
        app.launchArguments = ["-reading", "NO"]
        app.launch()
    }

    func testUpdateThenDelete() throws {
        // The older copy is open, and the downloads screen offers the newer one.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15), "the older copy did not open")
        app.buttons["Downloads"].tap()
        let first = app.buttons["action-\(book)"]
        XCTAssertTrue(reach(first), "the list of downloads did not load")
        XCTAssertTrue(text(beginningWith: "On this device: June 2026. A newer copy").exists, "no newer copy offered")
        XCTAssertEqual(first.label, "Update")
        XCTAssertEqual(app.buttons["second-\(book)"].label, "Delete")
        shot("u1-update-offered")

        // It downloads beside the old one, which goes once the new one is in place.
        first.tap()
        wait(for: first, label: "Open", timeout: 15 * 60)
        XCTAssertTrue(app.staticTexts["Downloaded. It is ready to read."].exists)
        shot("u2-updated")
        first.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15))

        // Deleting it asks first, then leaves nothing of it, and nothing to read.
        app.buttons["Downloads"].tap()
        XCTAssertTrue(reach(first))
        XCTAssertFalse(text(beginningWith: "On this device: June").exists, "the older copy was not deleted")
        wait(for: first, label: "Delete", timeout: 10)
        first.tap()
        // The question's own Delete, not the row's, which stays on screen beside it.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != %@", "action-\(book)")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "deleting did not ask first")
        shot("u3-delete-asked")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Not on this device."].waitForExistence(timeout: 10), "the book is still there")
        wait(for: first, label: "Download", timeout: 10)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Download Wikipedia…"].waitForExistence(timeout: 10), "the app still has a Wikipedia")
        shot("u4-deleted")
    }

    /// Scrolls down until `element` is on screen, once the list has loaded: a list only makes the
    /// rows it shows, and the smaller sizes come last.
    @discardableResult
    private func reach(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        guard app.staticTexts["All of English Wikipedia"].waitForExistence(timeout: timeout) else { return false }
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func text(beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Waits for `element` to say `label`, scrolling back to it if the rows above it grew and
    /// pushed it below the fold, where it does not exist.
    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists && element.label == label { return }
            if !element.exists || !element.isHittable { app.swipeUp() }
            sleep(2)
        }
        XCTFail("the button says \"\(element.exists ? element.label : "nothing")\", not \"\(label)\"")
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"], !folder.isEmpty {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
