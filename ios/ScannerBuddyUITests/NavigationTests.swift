#if os(iOS)
  import XCTest

  final class NavigationTests: XCTestCase {
    @MainActor func testDocumentDetailOpensThePDF() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--ui-preview"]
      app.launch()
      XCTAssertTrue(app.staticTexts["Travel receipts"].waitForExistence(timeout: 10))
      app.staticTexts["Travel receipts"].tap()
      let document = app.staticTexts["2026-11-01-acme.pdf"]
      XCTAssertTrue(document.waitForExistence(timeout: 5))
      document.tap()
      XCTAssertTrue(app.staticTexts["Extracted details"].waitForExistence(timeout: 5))
      let detail = XCTAttachment(screenshot: app.screenshot())
      detail.name = "Document"
      detail.lifetime = .keepAlways
      add(detail)
      let open = app.buttons["Open PDF"]
      XCTAssertTrue(open.waitForExistence(timeout: 5))
      open.tap()
      XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
      let reader = XCTAttachment(screenshot: app.screenshot())
      reader.name = "PDF reader"
      reader.lifetime = .keepAlways
      add(reader)
    }
    @MainActor func testGroupEditorIsPresentedSeparately() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--ui-preview"]
      app.launch()
      XCTAssertTrue(app.staticTexts["Travel receipts"].waitForExistence(timeout: 10))
      let library = XCTAttachment(screenshot: app.screenshot())
      library.name = "Library"
      library.lifetime = .keepAlways
      add(library)
      let actions = app.buttons["Group actions"]
      XCTAssertTrue(actions.waitForExistence(timeout: 5))
      actions.tap()
      app.buttons["New group"].tap()
      XCTAssertTrue(app.textFields["Group name"].waitForExistence(timeout: 5))
      app.textFields["Group name"].tap()
      app.textFields["Group name"].typeText("Invoices")
      app.buttons["schema-editor-link"].tap()
      XCTAssertTrue(app.navigationBars["Extraction schema"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons["Schema actions"].exists)
      app.buttons["Add field"].tap()
      let fieldName = app.textFields["Name, e.g. invoice_number"]
      XCTAssertTrue(fieldName.waitForExistence(timeout: 5))
      fieldName.tap()
      fieldName.typeText("vendor")
      app.buttons["save-field"].tap()
      XCTAssertTrue(app.staticTexts["vendor"].waitForExistence(timeout: 5))
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Schema editor"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
  }
#endif
