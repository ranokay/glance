import Foundation
import GlanceKit

class RARPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			scan: { try PreviewCoreBridge.scanRAR(at: fileURL) },
			policy: .rar
		)
	}
}

enum RARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("RAR archive metadata is too large to preview safely", comment: "")
	}
}
