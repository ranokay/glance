import Foundation
import GlanceKit

/// Presentation adapter for TAR and gzip-compressed TAR metadata parsed by PreviewCore.
class TARPreview: Preview {
	private let maxEntryCount = 50000

	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let normalizedPath = file.path.lowercased()
		let isGzipped = normalizedPath.hasSuffix(".tar.gz") || normalizedPath.hasSuffix(".tgz")
		return try await ArchivePreview.makePreview(
			file: file,
			scan: { try PreviewCoreBridge.scanTAR(at: fileURL, isGzipped: isGzipped) },
			policy: .tar(isGzipped: isGzipped, maxEntryCount: maxEntryCount)
		)
	}
}

enum TARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		"TAR archive metadata is too large to preview safely"
	}
}
