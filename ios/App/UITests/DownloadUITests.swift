import XCTest

/// Downloads Wikipedia in the app for real: the best-known articles (about 3 GB, big enough to
/// pause on the way), from Kiwix and from this repository's "downloads" release. So it runs only
/// when asked:
///   xcrun simctl uninstall <simulator> dev.offlinewiki.reader      # a fresh app, with nothing in it
///   TEST_RUNNER_DOWNLOAD=1 xcodebuild test ... -only-testing:WikiReaderUITests/DownloadUITests
/// TEST_RUNNER_SHOT_DIR writes screenshots, as for the other tests. Allow ten minutes or more.
final class DownloadUITests: XCTestCase {
    private var app: XCUIApplication!
    private let book = "wikipedia_en_top_nopic"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOWNLOAD"] == "1",
                          "set TEST_RUNNER_DOWNLOAD=1 to download about 3 GB (and uninstall the app first)")
        app = XCUIApplication()
        app.launchArguments = ["-reading", "NO"]
        app.launch()
    }

    func testDownloadPauseCarryOnAndRead() throws {
        // With nothing in it, the app offers to download Wikipedia.
        openDownloads()
        XCTAssertTrue(app.staticTexts["All of English Wikipedia"].exists, "the full Wikipedia is not on offer")
        let button = app.buttons["action-\(book)"]
        XCTAssertTrue(reach(button), "the book is not on offer")
        XCTAssertEqual(button.label, "Download", "the small Wikipedia is already here: uninstall the app first")
        shot("d1-offered")

        // It starts, and says how far it has got: the index first, then Wikipedia.
        button.tap()
        wait(for: button, label: "Pause", timeout: 30)
        XCTAssertTrue(text(beginningWith: "Downloading").waitForExistence(timeout: 120), "no progress shown")
        shot("d2-downloading")

        // Paused, it keeps what has arrived, and carries on from there.
        button.tap()
        wait(for: button, label: "Carry on", timeout: 30)
        XCTAssertTrue(text(beginningWith: "Paused: ").exists, "a pause does not say how much is here")
        shot("d3-paused")
        button.tap()
        wait(for: button, label: "Pause", timeout: 30)

        // Closed and opened again, the download is still there: going on, or waiting to carry on.
        sleep(10)
        app.terminate()
        app.launch()
        openDownloads()
        reach(button)
        if button.label == "Carry on" { button.tap() }
        wait(for: button, label: "Pause", timeout: 30)

        // Once it has arrived and its checksum matches, the app opens it by itself, and the
        // downloads sheet goes with the setup screen it was shown over.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 40 * 60), "the download did not arrive")
        let sheet = app.staticTexts["Downloaded. It is ready to read."]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the downloads sheet stayed up")
        shot("d4-arrived")

        // The downloads screen now has it on the device, with nothing to do.
        app.buttons["Downloads"].tap()
        XCTAssertTrue(reach(button))
        XCTAssertTrue(text(beginningWith: "On this device: ").exists, "the book is not shown as on the device")
        XCTAssertEqual(button.label, "Delete", "a book on the device offers no way to delete it")
        shot("d5-on-device")
        app.buttons["Done"].tap()

        // And it can be searched.
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("paris")
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 10), "the downloaded Wikipedia cannot be searched")
    }

    private func openDownloads() {
        let start = app.buttons["Download Wikipedia…"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the app does not offer a download")
        start.tap()
        XCTAssertTrue(app.staticTexts["All of English Wikipedia"].waitForExistence(timeout: 30),
                      "the list of downloads did not load")
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

    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "the button says \"\(element.label)\", not \"\(label)\"")
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
