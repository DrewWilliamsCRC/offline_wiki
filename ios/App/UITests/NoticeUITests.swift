import XCTest

/// Says when a download has finished with the app out of sight, for real: the best-known articles'
/// introductions (about 0.3 GB), from Kiwix and from this repository's "downloads" release. So it
/// runs only when asked, with that size not on the device yet:
///   TEST_RUNNER_DOWNLOAD=1 xcodebuild test ... -only-testing:WikiReaderUITests/NoticeUITests
/// It deletes what it downloaded at the end. Allow five minutes or more.
final class NoticeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let book = "wikipedia_en_top_mini"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOWNLOAD"] == "1",
                          "set TEST_RUNNER_DOWNLOAD=1 to download about 0.3 GB")
        app = XCUIApplication()
        app.launchArguments = ["-reading", "NO"]
        app.launch()
    }

    func testSaysWhenADownloadHasArrived() throws {
        // Started with the app in front. The first download asks whether the app may notify.
        openDownloads()
        let button = app.buttons["action-\(book)"]
        XCTAssertTrue(reach(button), "the book is not on offer")
        XCTAssertEqual(button.label, "Download", "the book is already here: delete it first")
        button.tap()
        allowNotifications()
        wait(for: button, label: "Pause", timeout: 30)

        // Then the reader leaves, and hears of it when it has arrived and been checked.
        XCUIDevice.shared.press(.home)
        let notice = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Downloaded. It is ready to read.")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20 * 60), "no notification said the download had arrived")
        shot("n1-arrived")

        // Tapped, it brings the app forward.
        notice.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the notification did not open the app")

        // Deleted again, so that the test can run another time.
        app.terminate()
        app.launch()
        openDownloads()
        XCTAssertTrue(reach(button))
        wait(for: button, label: "Delete", timeout: 10)
        button.tap()
        // The question's own Delete, not the row's, which stays on screen beside it.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != %@", "action-\(book)")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "deleting did not ask first")
        confirm.tap()
        wait(for: button, label: "Download", timeout: 10)
    }

    /// From the search screen, or from the setup screen when there is no Wikipedia yet.
    private func openDownloads() {
        let setup = app.buttons["Download Wikipedia…"]
        let search = app.buttons["Downloads"]
        let either = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in setup.exists || search.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [either], timeout: 20), .completed, "the app offers no downloads")
        (setup.exists ? setup : search).tap()
        XCTAssertTrue(app.staticTexts["All of English Wikipedia"].waitForExistence(timeout: 30),
                      "the list of downloads did not load")
    }

    /// Answers iOS's question about notifications, which comes only the first time.
    private func allowNotifications() {
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
    }

    /// Scrolls down until `element` is on screen: a list only makes the rows it shows, and the
    /// smaller sizes come last.
    @discardableResult
    private func reach(_ element: XCUIElement) -> Bool {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists && element.isHittable
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
