import Cocoa

/// The app icon reduced to a menu-bar template glyph: a solid eye silhouette
/// with the iris ring knocked out, so it holds its shape at 18 pt on light,
/// dark, and tinted menu bars.
enum StatusItemMark {
	static func make() -> NSImage {
		let size = NSSize(width: 18, height: 18)
		let image = NSImage(size: size, flipped: false) { _ in
			NSColor.black.setFill()
			path(in: NSRect(origin: .zero, size: size)).fill()
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = "Glance"
		return image
	}

	private static func path(in rect: NSRect) -> NSBezierPath {
		let center = NSPoint(x: rect.midX, y: rect.midY)
		let half = rect.width * 0.39
		let lift = rect.height * 0.34

		let path = NSBezierPath()
		path.move(to: NSPoint(x: center.x - half, y: center.y))
		path.curve(
			to: NSPoint(x: center.x + half, y: center.y),
			controlPoint1: NSPoint(x: center.x - half * 0.6, y: center.y + lift),
			controlPoint2: NSPoint(x: center.x + half * 0.6, y: center.y + lift),
		)
		path.curve(
			to: NSPoint(x: center.x - half, y: center.y),
			controlPoint1: NSPoint(x: center.x + half * 0.6, y: center.y - lift),
			controlPoint2: NSPoint(x: center.x - half * 0.6, y: center.y - lift),
		)
		path.close()

		// Even-odd subpaths punch the iris ring out of the silhouette, leaving
		// the pupil as an island.
		let iris = rect.width * 0.18
		let pupil = rect.width * 0.105
		for radius in [iris, pupil] {
			path.appendOval(in: NSRect(
				x: center.x - radius,
				y: center.y - radius,
				width: radius * 2,
				height: radius * 2,
			))
		}
		path.windingRule = .evenOdd
		return path
	}
}
