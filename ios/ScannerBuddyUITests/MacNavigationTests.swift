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
    @MainActor func testSidebarOpensGroupsDocumentsAndSheets() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--ui-preview"]
      app.launch()
      app.activate()
      // A restored selection also shows the group's name as the detail title.
      let group = app.staticTexts["Travel receipts"].firstMatch
      XCTAssertTrue(group.waitForExistence(timeout: 10))
      capture(app, "Launch")
      group.click()
      let document = app.buttons["2026-11-01-acme.pdf, Ready, 48 KB"]
      XCTAssertTrue(document.waitForExistence(timeout: 5))
      capture(app, "Group")
      document.click()
      XCTAssertTrue(app.staticTexts["Extracted details"].waitForExistence(timeout: 5))
      capture(app, "Document")
      app.descendants(matching: .any)["Group actions"].firstMatch.click()
      app.menuItems["New group"].click()
      XCTAssertTrue(app.staticTexts["Group details"].waitForExistence(timeout: 5))
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
      app.staticTexts["Buddy"].firstMatch.click()
      XCTAssertTrue(app.textFields["Ask Buddy…"].waitForExistence(timeout: 5))
      capture(app, "Buddy")
      app.staticTexts["Account"].firstMatch.click()
      XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 5))
      capture(app, "Account")
    }
  }
#endif
