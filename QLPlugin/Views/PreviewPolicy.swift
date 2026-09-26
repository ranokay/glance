import Foundation
import GlanceKit

enum PreviewPolicy {
	static let maximumFileSize = 10_000_000 // 10 MB

	static func validateFileSize(_ file: File) throws {
		let isStreamedAudio = PreviewSupport.isStreamedAudio(fileURL: file.url)
		guard file.isDirectory || file.isArchive || isStreamedAudio
			|| file.size <= maximumFileSize
		else {
			throw PreviewError.fileSizeError(path: file.path)
		}
	}
}
