import Cocoa

/// View controller for rendering previews of a specific file type.
protocol PreviewVC: NSViewController {
	func tearDown()
}

extension PreviewVC {
	func tearDown() {}
}

@MainActor
protocol PreviewStatusProviding: AnyObject {
	var previewStatusText: String { get }
	var previewStatusDidChange: (@MainActor (String) -> Void)? { get set }
}

/// Class that can be used to create an instance of a `PreviewVC` for the corresponding file type.
protocol Preview {
	init()
	@MainActor
	func createPreviewVC(file: File) throws -> PreviewVC
}
