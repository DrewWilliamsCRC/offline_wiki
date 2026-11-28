import XCTest

/// Chooses which of two copies of Wikipedia on the device to read, on the downloads screen. It
/// needs the app to hold two of the catalog's books, which only the Mac can arrange, so it runs
/// only when asked. Clones (`cp -c`) take no room, even of the 53 GB file:
///   xcrun simctl install <simulator> <WikiReader.app>
///   folder="$(xcrun simctl get_app_container <simulator> dev.offlinewiki.reader data)/Documents"
///   for f in wikipedia_en_all_nopic_2026-06 wikipedia_en_top_nopic_2026-09; do
///     cp -c data/zim/$f.zim data/zim/$f.zim.idx "$folder/"; done     # the catalog's own files
///   TEST_RUNNER_CHOOSE=1 xcodebuild test-without-building ... -only-testing:WikiReaderUITests/ChooseUITests
/// It needs the network, for the catalog, and ends with the biggest chosen again.
final class ChooseUITests: XCTestCase {
    private var app: XCUIApplication!
    private let all = "wikipedia_en_all_nopic"
    private let top = "wikipedia_en_top_nopic"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOOSE"] == "1",
                          "set TEST_RUNNER_CHOOSE=1 after putting two books in the app (see the comment above)")
        app = XCUIApplication()
        app.launchArguments = ["-reading", "NO"]
        app.launch()
    }

    func testChooseWhichToRead() throws {
        // The biggest opens first, and the search screen says which copy it is.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15), "no Wikipedia opened")
        XCTAssertTrue(footer("every article, without pictures").waitForExistence(timeout: 10), "the biggest is not the one open")
        shot("c1-biggest")

        // The other one can be opened in its place; the one open says so, and can only be deleted.
        footer("every article").tap()
        let openTop = app.buttons["action-\(top)"]
        XCTAssertTrue(reach(app.buttons["second-\(top)"]), "the list of downloads did not load") // the lower of its two
        XCTAssertEqual(openTop.label, "Open")
        XCTAssertEqual(app.buttons["second-\(top)"].label, "Delete")
        shot("c2-other-offered")
        openTop.tap()
        XCTAssertTrue(footer("the best-known articles, without pictures").waitForExistence(timeout: 15), "Open did not open it")
        shot("c3-chosen")

        // The choice stays when the app starts again.
        app.terminate()
        app.launch()
        XCTAssertTrue(footer("the best-known articles, without pictures").waitForExistence(timeout: 15), "the choice was not kept")

        // And the biggest can be chosen back.
        footer("the best-known articles").tap()
        XCTAssertTrue(reach(openTop))
        XCTAssertEqual(openTop.label, "Delete", "the copy open offers Open")
        XCTAssertTrue(text(beginningWith: "On this device: September 2026. This is the one open.").exists)
        let openAll = app.buttons["action-\(all)"]
        for _ in 0..<8 where !(openAll.exists && openAll.isHittable) { app.swipeDown() }
        XCTAssertEqual(openAll.label, "Open")
        openAll.tap()
        XCTAssertTrue(footer("every article, without pictures").waitForExistence(timeout: 15), "the biggest could not be chosen back")
    }

    /// The search screen's last line, naming the copy that is open.
    private func footer(_ kind: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wikipedia as of ' AND label CONTAINS %@", kind)).firstMatch
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
