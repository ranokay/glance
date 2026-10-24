import AppKit
@testable import Glance
import XCTest

@MainActor
final class StatusItemMarkTests: XCTestCase {
	func testMarkIsAnEighteenPointTemplate() {
		let mark = StatusItemMark.make()

		XCTAssertTrue(mark.isTemplate)
		XCTAssertEqual(mark.size, NSSize(width: 18, height: 18))
	}

	func testMarkKeepsItsEyeSilhouetteAtMenuBarSize() throws {
		let mark = StatusItemMark.make()

		XCTAssertEqual(try alpha(of: mark, at: NSPoint(x: 9, y: 5.5)), 1, "eye body")
		XCTAssertEqual(try alpha(of: mark, at: NSPoint(x: 9, y: 9)), 1, "pupil")
		XCTAssertEqual(try alpha(of: mark, at: NSPoint(x: 9, y: 6.4)), 0, "iris ring")
		XCTAssertEqual(try alpha(of: mark, at: NSPoint(x: 1.5, y: 1.5)), 0, "corner")
	}

	private func alpha(of image: NSImage, at point: NSPoint) throws -> CGFloat {
		let scale: CGFloat = 4
		let side = Int(image.size.width * scale)
		let bitmap = try XCTUnwrap(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: side,
			pixelsHigh: side,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0,
		))
		bitmap.size = image.size

		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
		image.draw(in: NSRect(origin: .zero, size: image.size))
		NSGraphicsContext.restoreGraphicsState()

		let color = try XCTUnwrap(bitmap.colorAt(
			x: Int(point.x * scale),
			y: Int(point.y * scale),
		))
		return color.alphaComponent
	}
}
