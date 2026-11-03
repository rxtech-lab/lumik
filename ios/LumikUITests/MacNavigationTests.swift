#if os(macOS)
  import XCTest

  final class MacNavigationTests: XCTestCase {
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
      app.activate()
      let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    @MainActor func testScannerSheetOpensWithoutStartingHardware() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--ui-preview"]
      app.launch()
      let group = app.staticTexts["Travel receipts"].firstMatch
      XCTAssertTrue(group.waitForExistence(timeout: 10))
      group.click()
      app.descendants(matching: .any)["Document actions"].firstMatch.click()
      app.menuItems["Scan from Scanner"].click()
      let sheet = app.sheets.firstMatch
      XCTAssertTrue(sheet.waitForExistence(timeout: 5))
      XCTAssertTrue(sheet.buttons["Scan Settings"].exists)
      XCTAssertTrue(sheet.buttons["Start Scanning"].exists)
      XCTAssertFalse(sheet.buttons["Upload"].isEnabled)
      let done = sheet.buttons["Done"]
      let title = sheet.staticTexts["Scan Documents"].firstMatch
      XCTAssertTrue(title.exists)
      XCTAssertLessThan(title.frame.minY - sheet.frame.minY, 60)
      done.click()
      XCTAssertFalse(sheet.exists)
    }

    @MainActor func testSidebarOpensGroupsDocumentsAndSheets() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--ui-preview"]
      app.launch()
      app.activate()
      // A restored selection also shows the group's name as the detail title.
      let group = app.staticTexts["Travel receipts"].firstMatch
      XCTAssertTrue(group.waitForExistence(timeout: 10))
      XCTAssertTrue(app.textFields["Ask Lumik…"].waitForExistence(timeout: 5))
      capture(app, "Launch")
      group.click()
      let document = app.buttons["2026-11-01-acme.pdf, Ready, 48 KB"]
      XCTAssertTrue(document.waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["Statistics"].waitForExistence(timeout: 5))
      capture(app, "Group")
      app.staticTexts["Total spent"].click()
      XCTAssertTrue(app.staticTexts["$42.00"].waitForExistence(timeout: 5))
      capture(app, "Statistic")
      app.buttons["Back"].firstMatch.click()
      XCTAssertTrue(document.waitForExistence(timeout: 5))
      app.descendants(matching: .any)["Filters"].firstMatch.click()
      app.menuItems["By vendor"].click()
      XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 5))
      capture(app, "Filter sheet")
      app.buttons["Cancel"].firstMatch.click()
      document.click()
      // Lumik stays beside the PDF, following it, and details share the same panel.
      XCTAssertTrue(app.staticTexts["agent-context"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.staticTexts["agent-context"].label, "2026-11-01-acme.pdf")
      XCTAssertTrue(app.textFields["Ask Lumik…"].exists)
      capture(app, "Document with Lumik")
      app.buttons["agent-toggle"].click()
      XCTAssertFalse(app.textFields["Ask Lumik…"].exists)
      app.buttons["document-details-toggle"].click()
      XCTAssertTrue(app.staticTexts["Extracted details"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["Also in this PDF"].exists)
      XCTAssertTrue(app.staticTexts["Receipt number R-1042"].exists)
      capture(app, "Document details")
      app.buttons["agent-toggle"].click()
      XCTAssertTrue(app.textFields["Ask Lumik…"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.staticTexts["agent-context"].label, "2026-11-01-acme.pdf")
      app.descendants(matching: .any)["Group actions"].firstMatch.click()
      app.menuItems["New group"].click()
      XCTAssertTrue(app.staticTexts["Group details"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.descendants(matching: .any)["extract-additional"].firstMatch.exists)
      capture(app, "New group sheet")
      app.descendants(matching: .any)["schema-editor-link"].firstMatch.click()
      XCTAssertTrue(app.buttons["Add field"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.descendants(matching: .any)["Schema actions"].firstMatch.exists)
      // The title collapses toward the middle of the sheet if the content stops filling it.
      let sheet = app.sheets.firstMatch
      let back = sheet.buttons["Back"]
      XCTAssertLessThan(back.frame.minY - sheet.frame.minY, 40)
      capture(app, "Empty schema")
      app.buttons["Add field"].click()
      let fieldName = app.descendants(matching: .any)["save-field"].firstMatch
      XCTAssertTrue(fieldName.waitForExistence(timeout: 5))
      capture(app, "Add field sheet")
      app.buttons["Cancel"].firstMatch.click()
      XCTAssertTrue(app.buttons["Add field"].waitForExistence(timeout: 5))
      back.click()
      XCTAssertTrue(app.staticTexts["Group details"].waitForExistence(timeout: 5))
      app.buttons["Cancel"].click()
      app.staticTexts["Account"].firstMatch.click()
      XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 5))
      capture(app, "Account")
    }
  }
#endif
