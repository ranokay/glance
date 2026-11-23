import Cocoa
@testable import Glance
import XCTest

@MainActor
final class AppLaunchTests: XCTestCase {
	func testTestHostLaunchedWithLiveApplicationDelegate() {
		XCTAssertTrue(NSApp.delegate is AppDelegate)
		XCTAssertNotNil(
			NSApp.mainMenu,
			"Test host launched without a main menu: applicationWillFinishLaunching never ran",
		)
	}

	func testTestHostRegisteredStatusItemWithImageAndMenu() throws {
		let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
		let statusItem = try XCTUnwrap(delegate.statusItem)

		XCTAssertTrue(statusItem.isVisible)
		XCTAssertNotNil(statusItem.button?.image)
		XCTAssertEqual(statusItem.button?.toolTip, "Glance")
		let menu = try XCTUnwrap(statusItem.menu)
		XCTAssertTrue(menu.items.contains { $0.title == "Quit Glance" && $0.target === delegate })
	}
}
