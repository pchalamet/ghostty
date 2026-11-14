//
//  GhosttyTitlebarTabsUITests.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

final class GhosttyTitlebarTabsUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            macos-titlebar-style = tabs
            title = "GhosttyTitlebarTabsUITests"
            """
        )
    }

    @MainActor
    func testAboutTtyrexCreditsGhostty() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.menuBars.menuBarItems["Ttyrex"].click()
        app.menuItems["About Ttyrex"].click()

        let about = app.windows["About Ttyrex"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        XCTAssertTrue(about.staticTexts["A terminal emulator forked from Ghostty."].exists)
    }

    @MainActor
    func testViewMenuOmitsQuickTerminal() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.menuBars.menuBarItems["View"].click()

        XCTAssertTrue(app.menuItems["Terminal Inspector"].exists)
        XCTAssertFalse(app.menuItems["Quick Terminal"].exists)
    }

    @MainActor
    func testCustomTitlebar() throws {
        let app = try ghosttyApplication()
        app.launch()
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        app.typeKey("\n", modifierFlags: [.command, .shift])
        let resetZoomButton = app.groups.buttons["ResetZoom"]
        let windowTitle = app.windows.firstMatch.title
        let titleView = app.staticTexts.element(matching: NSPredicate(format: "value == '\(windowTitle)'"))

        XCTAssertEqual(titleView.frame.midY, resetZoomButton.frame.midY, accuracy: 1, "Window title should be vertically centered with reset zoom button: \(titleView.frame.midY) != \(resetZoomButton.frame.midY)")
    }

    @MainActor
    func testTabsGeometryInNormalWindow() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.tabs.count, 2, "There should be 2 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testCompactTabsStayVisibleWhenReturningToFirstTab() throws {
        try updateConfig("macos-titlebar-style = compact-tabs")
        let app = try ghosttyApplication()
        app.launch()

        let firstTab = app.buttons["CompactTabSelected"]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let terminal = window.groups["Terminal pane"].firstMatch
        XCTAssertGreaterThanOrEqual(firstTab.frame.minY - window.frame.minY, 4)
        XCTAssertGreaterThanOrEqual(terminal.frame.minY - firstTab.frame.maxY, 4)
        app.buttons["New Tab"].click()

        let inactiveTab = app.buttons["CompactTab"]
        XCTAssertTrue(inactiveTab.waitForExistence(timeout: 5))
        XCTAssertLessThan(inactiveTab.frame.minX, firstTab.frame.minX)
        inactiveTab.click()

        XCTAssertTrue(firstTab.waitForExistence(timeout: 5))
        XCTAssertTrue(inactiveTab.exists)
        XCTAssertLessThan(firstTab.frame.minX, inactiveTab.frame.minX)
        XCTAssertEqual(app.tabs.count, 0)

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Compact titlebar divider"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        window.typeKey("n", modifierFlags: .command)
        let backgroundWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(backgroundWindow.waitForExistence(timeout: 5))
        let inactiveScreenshot = XCTAttachment(screenshot: backgroundWindow.screenshot())
        inactiveScreenshot.name = "Inactive compact titlebar"
        inactiveScreenshot.lifetime = .keepAlways
        add(inactiveScreenshot)
    }

    @MainActor
    func testCompactTitlebarClickReactivatesSelectedTab() throws {
        try updateConfig("""
            macos-titlebar-style = compact-tabs
            window-width = 112
            cursor-style = block
            cursor-style-blink = false
            shell-integration-features = no-cursor
            """)
        let app = try ghosttyApplication()
        app.launch()

        XCTAssertTrue(app.buttons["CompactTabSelected"].waitForExistence(timeout: 5))
        app.buttons["New Tab"].click()

        XCTAssertTrue(app.buttons["CompactTab"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        let window = app.windows.element(boundBy: 1)
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let inactiveTab = window.buttons["CompactTab"]
        let titlebarGap = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: inactiveTab.frame.minX - window.frame.minX - 5,
                              dy: 5))

        XCTAssertFalse(window.buttons["CompactTabClose"].exists)
        titlebarGap.click()

        XCTAssertEqual(app.state, .runningForeground)
        let foregroundWindow = app.windows.firstMatch
        XCTAssertGreaterThan(foregroundWindow.buttons["CompactTabSelected"].frame.minX,
                             foregroundWindow.buttons["CompactTab"].frame.minX)
        XCTAssertTrue(foregroundWindow.textViews.firstMatch.debugDescription.contains("Keyboard Focused"))
        let screenshot = XCTAttachment(screenshot: foregroundWindow.screenshot())
        screenshot.name = "Terminal cursor after titlebar activation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.windows.firstMatch.buttons["CompactTabSelected"].hover()
        XCTAssertTrue(app.buttons["CompactTabClose"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCompactTabCloseButtonOnHover() throws {
        try updateConfig("macos-titlebar-style = compact-tabs")
        let app = try ghosttyApplication()
        app.launch()

        let selectedTab = app.buttons["CompactTabSelected"]
        XCTAssertTrue(selectedTab.waitForExistence(timeout: 5))
        app.buttons["New Tab"].click()

        let inactiveTab = app.buttons["CompactTab"]
        XCTAssertTrue(inactiveTab.waitForExistence(timeout: 5))
        let closeButton = app.buttons["CompactTabClose"]
        app.groups["Terminal pane"].firstMatch.hover()
        XCTAssertFalse(closeButton.exists)

        inactiveTab.hover()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(closeButton.frame.midX, selectedTab.frame.minX)
        let hoveredScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        hoveredScreenshot.name = "Hovered inactive compact tab"
        hoveredScreenshot.lifetime = .keepAlways
        add(hoveredScreenshot)
        closeButton.click()
        XCTAssertTrue(inactiveTab.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTab.exists)

        app.buttons["New Tab"].click()
        XCTAssertTrue(inactiveTab.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(selectedTab.frame.minX, inactiveTab.frame.minX)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(inactiveTab.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTab.exists)
    }

    @MainActor
    func testTabsGeometryInFullscreen() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.typeKey("f", modifierFlags: [.command, .control])
        // using app to type ⌘+t might not be able to create tabs
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.tabs.count, 2, "There should be 2 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsGeometryAfterMovingTabs() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")
        // create another 2 tabs
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        // move to the left
        app.menuItems["_zoomLeft:"].firstMatch.click()

        // create another window with 2 tabs
        app.windows.firstMatch.groups["Terminal pane"].typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 2, "There should be 2 windows")

        // move to the right
        app.menuItems["_zoomRight:"].firstMatch.click()

        // now second window is the first/main one in the list
        app.windows.firstMatch.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        app.windows.element(boundBy: 1).tabs.firstMatch.click() // focus first window

        // now the first window is the main one
        let firstTabInFirstWindow = app.windows.firstMatch.tabs.firstMatch
        let firstTabInSecondWindow = app.windows.element(boundBy: 1).tabs.firstMatch

        // drag a tab from one window to another
        firstTabInFirstWindow.press(forDuration: 0.2, thenDragTo: firstTabInSecondWindow)

        // check tabs in the first
        checkTabsGeometry(app.windows.firstMatch)
        // focus another window
        app.windows.element(boundBy: 1).tabs.firstMatch.click()
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsGeometryAfterMergingAllWindows() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")

        // create another 2 windows
        app.typeKey("n", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)

        // merge into one window, resulting 3 tabs
        app.menuItems["mergeAllWindows:"].firstMatch.click()

        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 3, timeout: 1), "There should be 3 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    func checkTabsGeometry(_ window: XCUIElement) {
        let closeTabButtons = window.buttons.matching(identifier: "_closeButton")

        XCTAssertEqual(closeTabButtons.count, window.tabs.count, "Close tab buttons count should match tabs count")

        var previousTabHeight: CGFloat?
        for idx in 0 ..< window.tabs.count {
            let currentTab = window.tabs.element(boundBy: idx)
            // focus
            currentTab.click()
            // switch to the tab
            window.typeKey("\(idx + 1)", modifierFlags: .command)
            // add a split
            window.typeKey("d", modifierFlags: .command)
            // zoom this split
            // haven't found a way to locate our reset zoom button yet..
            window.typeKey("\n", modifierFlags: [.command, .shift])
            window.typeKey("\n", modifierFlags: [.command, .shift])

            if let previousHeight = previousTabHeight {
                XCTAssertEqual(currentTab.frame.height, previousHeight, accuracy: 1, "The tab's height should stay the same")
            }
            previousTabHeight = currentTab.frame.height

            let titleFrame = currentTab.frame
            let shortcutLabelFrame = window.staticTexts.element(matching: NSPredicate(format: "value CONTAINS[c] '⌘\(idx + 1)'")).firstMatch.frame
            let closeButtonFrame = closeTabButtons.element(boundBy: idx).frame

            XCTAssertEqual(titleFrame.midY, shortcutLabelFrame.midY, accuracy: 1, "Tab title should be vertically centered with its shortcut label: \(titleFrame.midY) != \(shortcutLabelFrame.midY)")
            XCTAssertEqual(titleFrame.midY, closeButtonFrame.midY, accuracy: 1, "Tab title should be vertically centered with its close button: \(titleFrame.midY) != \(closeButtonFrame.midY)")
        }
    }
}
