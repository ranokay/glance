import Foundation
import GlanceKit

class SevenZipPreview: Preview {
	required init() {}

	@MainActor
	static func makePreview(file: File, depth: Int) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			format: .sevenZip,
			depth: depth,
			scan: { try PreviewCoreBridge.scanSevenZip(at: fileURL) },
			policy: .sevenZip,
		)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		try await Self.makePreview(file: file, depth: 0)
	}
}

enum SevenZipPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("7z archive metadata is too large to preview safely", comment: "")
	}
}
