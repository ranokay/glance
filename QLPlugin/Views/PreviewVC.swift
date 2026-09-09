import Cocoa

enum PreviewPolicy {
	static let maximumFileSize = 10_000_000 // 10 MB

	static func validateFileSize(_ file: File) throws {
		guard file.isDirectory || file.isArchive || file.size <= maximumFileSize else {
			throw PreviewError.fileSizeError(path: file.path)
		}
	}
}

/// View controller for rendering previews of a specific file type.
protocol PreviewVC: NSViewController {
	func tearDown()
}

extension PreviewVC {
	func tearDown() {}
}

@MainActor
protocol PreviewStatusProviding: AnyObject {
	var previewStatusText: String { get }
	var previewStatusDidChange: (@MainActor (String) -> Void)? { get set }
}

/// Class that can be used to create an instance of a `PreviewVC` for the corresponding file type.
protocol Preview {
	init()
	@MainActor
	func createPreviewVC(file: File) async throws -> PreviewVC
}

enum ArchiveStatusFormatter {
	@MainActor
	static func status(
		compressed: UInt64,
		uncompressed: UInt64,
		compressedLabel: String = "Compressed",
		uncompressedPrefix: String = "",
		trailingNote: String? = nil,
		includesPercentage: Bool = true
	) -> String {
		let byteCountFormatter = ByteCountFormatter()
		let compressedText = byteCountFormatter.string(
			fromByteCount: clampedByteCount(compressed)
		)
		let uncompressedText = byteCountFormatter.string(
			fromByteCount: clampedByteCount(uncompressed)
		)
		var components = [
			"\(compressedLabel) \(compressedText)",
			"Uncompressed \(uncompressedPrefix)\(uncompressedText)",
		]
		if includesPercentage, uncompressed > 0 {
			let change = (Double(uncompressed) - Double(compressed)) / Double(uncompressed) * 100
			let label = change >= 0 ? "Saved" : "Overhead"
			components.append("\(label) \(String(format: "%.1f", abs(change)))%")
		}
		if let trailingNote, !trailingNote.isEmpty {
			components.append(trailingNote)
		}
		return components.joined(separator: " • ")
	}

	@MainActor
	static func size(
		_ size: UInt64,
		trailingNote: String? = nil
	) -> String {
		let byteCountFormatter = ByteCountFormatter()
		var components = [
			"Size \(byteCountFormatter.string(fromByteCount: clampedByteCount(size)))",
		]
		if let trailingNote, !trailingNote.isEmpty {
			components.append(trailingNote)
		}
		return components.joined(separator: " • ")
	}

	private static func clampedByteCount(_ value: UInt64) -> Int64 {
		value > UInt64(Int64.max) ? Int64.max : Int64(value)
	}
}
