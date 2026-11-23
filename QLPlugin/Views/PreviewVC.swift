import Cocoa

/// View controller for rendering previews of a specific file type.
protocol PreviewVC: NSViewController {
	func tearDown()
}

extension PreviewVC {
	func tearDown() {}
}

/// A preview that can rebuild itself from the file on disk without being replaced.
@MainActor
protocol RefreshablePreview: AnyObject {
	/// `false` for preview kinds that cannot regenerate their content.
	var isRefreshable: Bool { get }
	func refreshFromDisk() async throws
}

extension RefreshablePreview {
	var isRefreshable: Bool {
		true
	}
}

enum PreviewRefreshError: Error {
	case unavailable
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
	func createPreviewVC(file: File) async throws -> PreviewVC
}
