import Foundation
import GlanceKit

/// Presentation adapter for TAR and gzip-compressed TAR metadata parsed by PreviewCore.
class TARPreview: Preview {
	required init() {}

	@MainActor
	static func makePreview(file: File, depth: Int) async throws -> PreviewVC {
		let fileURL = file.url
		let normalizedPath = file.path.lowercased()
		let isGzipped = normalizedPath.hasSuffix(".tar.gz") || normalizedPath.hasSuffix(".tgz")
		return try await ArchivePreview.makePreview(
			file: file,
			format: isGzipped ? .tarGz : .tar,
			depth: depth,
			scan: { try PreviewCoreBridge.scanTAR(at: fileURL, isGzipped: isGzipped) },
			policy: .tar(isGzipped: isGzipped, maxEntryCount: 50000)
		)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		try await Self.makePreview(file: file, depth: 0)
	}
}

enum TARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		"TAR archive metadata is too large to preview safely"
	}
}
