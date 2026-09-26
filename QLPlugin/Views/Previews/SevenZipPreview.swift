import Foundation
import GlanceKit

class SevenZipPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			scan: { try PreviewCoreBridge.scanSevenZip(at: fileURL) },
			policy: .sevenZip
		)
	}
}

enum SevenZipPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("7z archive metadata is too large to preview safely", comment: "")
	}
}
