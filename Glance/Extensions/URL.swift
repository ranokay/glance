import Cocoa

extension URL {
	func open() {
		NSWorkspace.shared.open(self)
	}
}
