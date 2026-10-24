import Foundation
import GlanceKit

class ZIPPreview: Preview {
	required init() {}

	@MainActor
	static func makePreview(file: File, depth: Int) async throws -> PreviewVC {
		let fileURL = file.url
		return try await ArchivePreview.makePreview(
			file: file,
			format: .zip,
			depth: depth,
			scan: { try PreviewCoreBridge.scanZIP(at: fileURL) },
			policy: .zip
		)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		try await Self.makePreview(file: file, depth: 0)
	}
}

enum ZIPPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("ZIP archive metadata is too large to preview safely", comment: "")
	}
}
