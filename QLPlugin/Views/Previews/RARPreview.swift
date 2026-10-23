import Foundation
import GlanceKit

class RARPreview: Preview {
	required init() {}

	@MainActor
	static func makePreview(file: File, depth: Int) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			format: .rar,
			depth: depth,
			scan: { try PreviewCoreBridge.scanRAR(at: fileURL) },
			policy: .rar
		)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		try await Self.makePreview(file: file, depth: 0)
	}
}

enum RARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("RAR archive metadata is too large to preview safely", comment: "")
	}
}
