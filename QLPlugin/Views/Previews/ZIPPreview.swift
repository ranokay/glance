import Foundation
import GlanceKit

class ZIPPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			scan: { try PreviewCoreBridge.scanZIP(at: fileURL) },
			policy: .zip
		)
	}
}

enum ZIPPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("ZIP archive metadata is too large to preview safely", comment: "")
	}
}
