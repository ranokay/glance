import AppKit
import XCTest

@MainActor
final class WindowAppearanceTests: XCTestCase {
	func testWindowAppearanceUsesOneAdaptiveMaterialBackground() throws {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)

		let firstMaterialView = try XCTUnwrap(WindowAppearance.apply(to: window))
		let secondMaterialView = try XCTUnwrap(WindowAppearance.apply(to: window))

		XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
		XCTAssertTrue(window.titlebarAppearsTransparent)
		XCTAssertFalse(window.isOpaque)
		XCTAssertEqual(window.backgroundColor, .clear)
		XCTAssertIdentical(firstMaterialView, secondMaterialView)
		XCTAssertEqual(
			window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.count,
			1
		)
		XCTAssertEqual(firstMaterialView.material, .underWindowBackground)
		XCTAssertEqual(firstMaterialView.blendingMode, .behindWindow)
		XCTAssertEqual(firstMaterialView.state, .followsWindowActiveState)
	}

	func testSupportedFilesWindowContainsEveryStructuredSection() throws {
		let controller = SupportedFilesWC()
		let window = try XCTUnwrap(controller.window)

		XCTAssertTrue(window.styleMask.contains(.resizable))
		XCTAssertGreaterThanOrEqual(window.minSize.width, 420)
		XCTAssertGreaterThanOrEqual(window.minSize.height, 300)
		XCTAssertEqual(
			controller.sectionsStackView.arrangedSubviews.count,
			SupportedFilesWC.sections.count
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.map(\.title),
			[
				"Source Code",
				"Markdown",
				"Archive",
				"Jupyter Notebook",
				"Tab-separated Values",
				"Folders",
			]
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Tab-separated Values" }?.details,
			".tab, .tsv"
		)
	}

	func testSupportedFileDetailsWrapAndExposeAccessibilityLabels() throws {
		let controller = SupportedFilesWC()
		let labels = controller.sectionsStackView.arrangedSubviews
			.flatMap(allTextFields(in:))
		let sourceDetails = try XCTUnwrap(labels.first {
			$0.identifier?.rawValue == "SupportedFiles.Source Code.Details"
		})

		XCTAssertEqual(sourceDetails.maximumNumberOfLines, 0)
		XCTAssertEqual(sourceDetails.alignment, .center)
		XCTAssertEqual(sourceDetails.accessibilityLabel(), sourceDetails.stringValue)
	}

	private func allTextFields(in view: NSView) -> [NSTextField] {
		let directTextFields = view.subviews.compactMap { $0 as? NSTextField }
		return directTextFields + view.subviews.flatMap(allTextFields(in:))
	}
}
