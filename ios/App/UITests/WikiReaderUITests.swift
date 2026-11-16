import XCTest

/// Drives the app in the simulator against a real Wikipedia file.
///
/// The simulator can read the Mac's disk, so the tests point the app at a folder there:
///   TEST_RUNNER_WIKI_DIR=<folder with the .zim and .zim.idx> xcodebuild test ...
/// Set TEST_RUNNER_SHOT_DIR as well to have screenshots written to a folder on the Mac.
/// The expectations below hold for the full English Wikipedia and for Kiwix's "top" build.
final class WikiReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let folder = ProcessInfo.processInfo.environment["WIKI_DIR"] ?? ""
        try XCTSkipIf(folder.isEmpty, "set TEST_RUNNER_WIKI_DIR to a folder holding a .zim and its .zim.idx")
        app = XCUIApplication()
        app.launchEnvironment["WIKI_DIR"] = folder
        app.launch()
    }

    func testSearchReadAndNavigate() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the search screen did not appear")
        shot("01-start")

        // Typing part of a title lists the article, well-known ones first.
        field.tap()
        field.typeText("photosyn")
        let result = app.staticTexts["Photosynthesis"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no Photosynthesis result")
        shot("02-results")

        // Opening it shows the article, served from the Wikipedia file.
        result.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Photosynthesis"].waitForExistence(timeout: 20), "the article did not load")
        shot("03-article")

        // A link inside the article opens the next article in the same view.
        let link = web.links["algae"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no link to follow")
        link.tap()
        XCTAssertTrue(app.navigationBars["Algae"].waitForExistence(timeout: 20), "the linked article did not open")
        shot("04-linked-article")

        // The toolbar goes back to the previous article.
        app.buttons["Previous article"].tap()
        XCTAssertTrue(app.navigationBars["Photosynthesis"].waitForExistence(timeout: 20), "going back did not return")

        app.buttons["Larger text"].tap()
        app.buttons["Larger text"].tap()
        shot("05-larger-text")
        app.buttons["Smaller text"].tap()
        app.buttons["Smaller text"].tap()

        // Leaving the article returns to the search screen, which now remembers both articles.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.buttons["Clear text"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Recently read"].waitForExistence(timeout: 10), "no reading history")
        XCTAssertTrue(app.staticTexts["Algae"].exists)
        shot("06-recently-read")
    }

    func testOtherNamesLeadToTheArticle() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("usa")
        // "USA" is another name for the United States article; the list says which name matched.
        XCTAssertTrue(app.staticTexts["United States"].waitForExistence(timeout: 10), "USA did not find United States")
        XCTAssertTrue(app.staticTexts["also: USA"].exists)
        shot("07-other-name")
        app.staticTexts["United States"].tap()
        XCTAssertTrue(app.navigationBars["United States"].waitForExistence(timeout: 30), "the article did not open")
        shot("08-large-article")
    }

    func testDarkAppearance() throws {
        // The appearance is read when the app starts, so set it and start again.
        app.terminate()
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("nvidia")
        let result = app.staticTexts["Nvidia"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.navigationBars["Nvidia"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Nvidia"].waitForExistence(timeout: 20))
        sleep(1)
        shot("09-dark")
        // An article is mostly background, so a dark page has a low average brightness.
        XCTAssertLessThan(brightness(of: XCUIScreen.main.screenshot().image), 0.3, "the article is not dark")
    }

    /// Average brightness of an image, 0 (black) to 1 (white), from a small scaled-down copy.
    private func brightness(of image: UIImage) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return Double(total) / Double(side * side * 3 * 255)
    }

    /// Keeps a screenshot with the test results and, if asked, writes it to a folder on the Mac.
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
