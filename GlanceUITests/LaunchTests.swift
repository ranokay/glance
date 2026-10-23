import XCTest

/// Deterministic UI gate: the menu-bar app launches in the background and
/// leaves a screenshot attachment as evidence. Deeper window driving would
/// need menu-bar interaction (flaky under automation); window and appearance
/// behavior stays covered by WindowAppearanceTests plus the manual Quick Look
/// capture convention in docs/agents/verification.md.
final class LaunchTests: XCTestCase {
	@MainActor
	func testMenuBarAppLaunches() {
		let app = XCUIApplication(bundleIdentifier: "com.chamburr.Glance")
		app.launch()
		XCTAssertTrue(
			app.wait(for: .runningBackground, timeout: 30),
			"Glance did not launch as a background menu-bar app"
		)
		let screenshot = XCTAttachment(screenshot: app.screenshot())
		screenshot.name = "launch"
		screenshot.lifetime = .keepAlways
		add(screenshot)
		app.terminate()
	}
}
