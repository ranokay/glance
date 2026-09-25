import Foundation
import GlanceKit

enum PreviewPolicy {
	static let maximumFileSize = 10_000_000 // 10 MB

	static func validateFileSize(_ file: File) throws {
		let isStreamedMedia = PreviewSupport.getPreviewFileType(fileURL: file.url) == .flac
		guard file.isDirectory || file.isArchive || isStreamedMedia
			|| file.size <= maximumFileSize
		else {
			throw PreviewError.fileSizeError(path: file.path)
		}
	}
}
