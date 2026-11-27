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
        // The app opens where it was left, which for most of these tests is inside an article.
        // This overrides what it remembers for one launch, so that each test starts at the search
        // screen whatever the one before it did.
        app.launchArguments = ["-reading", "NO"]
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

    func testLeftoversOfMissingPicturesAreHidden() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("paris")
        let result = app.staticTexts["Paris"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        // The infobox is shown...
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Country"].waitForExistence(timeout: 20), "the infobox did not load")
        shot("10-infobox")
        web.swipeUp()
        shot("11-infobox-scrolled")
        // ...but not what is left of the pictures "no images" builds leave out: a location map's
        // place-name labels, which land on top of the rows around it, and its caption...
        XCTAssertFalse(web.staticTexts["Location of Paris"].exists, "a location map without its picture is shown")
        // ...nor the captions of the flag, coat of arms and logo, a link in one build and text in the other.
        XCTAssertFalse(web.staticTexts["Coat of arms"].exists || web.links["Coat of arms"].exists,
                       "a coat of arms caption without its picture is shown")
    }

    func testSectionsMenuJumpsToASection() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("photosyn")
        let result = app.staticTexts["Photosynthesis"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Photosynthesis"].waitForExistence(timeout: 20), "the article did not load")

        // A section well down the article: its heading is in the page but not on the screen.
        let name = "Light-dependent reactions"
        let heading = web.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the article has no such heading")
        XCTAssertFalse(heading.isHittable, "the heading is on screen before any jump")

        // The menu lists the article's sections; choosing one brings its heading onto the screen,
        // clear of the bars at the top and bottom.
        app.buttons["Sections"].tap()
        let row = app.buttons[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the menu does not list the section")
        XCTAssertTrue(app.buttons["(Top)"].exists)
        shot("12-sections")
        row.tap()
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: heading)
        waitForExpectations(timeout: 10)
        // The article's name leaves the title bar while the menu is up and returns as it closes.
        XCTAssertTrue(app.navigationBars["Photosynthesis"].waitForExistence(timeout: 10), "the title bar lost the article's name")
        shot("13-section")

        // The first row goes back to the top of the article.
        app.buttons["Sections"].tap()
        XCTAssertTrue(app.buttons["(Top)"].waitForExistence(timeout: 10))
        app.buttons["(Top)"].tap()
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: heading)
        waitForExpectations(timeout: 10)
    }

    func testReopensWhereTheReaderLeftOff() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("photosyn")
        let result = app.staticTexts["Photosynthesis"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Photosynthesis"].waitForExistence(timeout: 20), "the article did not load")

        // Read on to a section well down the article.
        let name = "Light-dependent reactions"
        func heading() -> XCUIElement {
            app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        func waitUntilOnScreen(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 20), "the article has no such heading")
            expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
            waitForExpectations(timeout: 10)
        }
        app.buttons["Sections"].tap()
        let row = app.buttons[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the menu does not list the section")
        row.tap()
        waitUntilOnScreen(heading())
        sleep(3) // the place is kept a moment after the page stops moving

        // Started again, the app is back in the article and at that section, not at its top.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.navigationBars["Photosynthesis"].waitForExistence(timeout: 20), "the app did not reopen the article")
        waitUntilOnScreen(heading())
        shot("14-reopened")

        // The list of recent articles says how far each was read, and opens one at that place.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Recently read"].waitForExistence(timeout: 10), "no reading history")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "% read")).firstMatch.exists,
                      "the list does not say how far the article was read")
        shot("15-how-far")
        app.staticTexts["Photosynthesis"].firstMatch.tap()
        waitUntilOnScreen(heading())
        // The title bar still names the article once the page has loaded. (The web view sometimes
        // reports a page finished before it knows its title, which used to blank the bar.)
        XCTAssertTrue(app.navigationBars["Photosynthesis"].waitForExistence(timeout: 20), "the title bar lost the article's name")

        // Left at the search screen, the app starts there.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Recently read"].waitForExistence(timeout: 10))
        sleep(1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Recently read"].waitForExistence(timeout: 20), "the app did not start at the search screen")
        XCTAssertFalse(app.buttons["Sections"].exists, "an article is showing")
    }

    /// The list of what can be downloaded comes from this repository's GitHub release, so this one
    /// needs the network. DownloadUITests downloads for real.
    func testDownloadsListsWhatCanBeDownloaded() throws {
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15))
        app.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["All of English Wikipedia"].waitForExistence(timeout: 30), "the list of downloads did not load")
        XCTAssertTrue(app.staticTexts["Best-known articles"].exists)
        // The smallest is last, and on a phone below the fold.
        for _ in 0..<6 where !app.staticTexts["Best-known articles, introductions only"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Best-known articles, introductions only"].exists, "the sizes are not all offered")
        // WIKI_DIR is not where downloads go, so neither counts as on this device unless downloaded.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " GB")).count >= 2, "no sizes shown")
        shot("16-downloads")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Done did not return to the search screen")
    }

    /// The article's menu finds a word far down it with the system's find bar, offers to share it,
    /// and opens it at its own address on wikipedia.org in Safari. (Safari shows the address it was
    /// given whether or not it can load it.)
    func testFindShareAndOpenOnWikipedia() throws {
        let heading = openArticle(typing: "photosyn", choosing: "Photosynthesis")
        XCTAssertTrue(heading.isHittable, "the article's heading is not on screen at first")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Find in Article"].waitForExistence(timeout: 10), "the menu has no Find")
        XCTAssertTrue(app.buttons["Share"].exists, "the menu has no Share")
        XCTAssertTrue(app.buttons["Open on Wikipedia"].exists, "the menu has no Open on Wikipedia")
        shot("17-article-menu")
        app.buttons["Find in Article"].tap()
        sleep(1)
        app.typeText("Ingenhousz") // in the article's history, far below its top
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: heading)
        waitForExpectations(timeout: 10)
        shot("18-found")
        app.typeText("\n")

        app.buttons["More"].tap()
        app.buttons["Open on Wikipedia"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not open")
        let address = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS 'en.wikipedia.org' OR label CONTAINS 'en.wikipedia.org'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 20), "Safari was not given the article's address on en.wikipedia.org")
        app.activate()
    }

    /// Articles start at the system's text size, as the rest of the app does.
    func testArticlesFollowTheSystemTextSize() throws {
        let standard = openArticle(typing: "photosyn", choosing: "Photosynthesis").frame.height
        app.terminate()
        app.launchArguments = ["-reading", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        let larger = openArticle(typing: "photosyn", choosing: "Photosynthesis").frame.height
        shot("19-larger-system-text")
        // The largest standard size makes body text about a third bigger.
        XCTAssertGreaterThan(larger, standard * 1.2, "the article's text did not grow with the system's")
    }

    /// The search screen says when this copy of Wikipedia was made, and only while its field is empty.
    func testSaysHowOldTheCopyIs() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let age = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Wikipedia as of '")).firstMatch
        XCTAssertTrue(age.waitForExistence(timeout: 10), "the search screen does not say how old the copy is")
        field.tap()
        field.typeText("paris")
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 10))
        XCTAssertFalse(age.exists, "the age shows over search results")
    }

    /// Searches for `query`, opens the result titled `title`, and returns the article's heading.
    private func openArticle(typing query: String, choosing title: String) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(query)
        let result = app.staticTexts[title]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no \(title) result")
        result.tap()
        let heading = app.webViews.firstMatch.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the article did not load")
        return heading
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
