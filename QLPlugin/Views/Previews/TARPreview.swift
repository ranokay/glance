import Foundation

/// Presentation adapter for TAR and gzip-compressed TAR metadata parsed by PreviewCore.
class TARPreview: Preview {
	let byteCountFormatter = ByteCountFormatter()
	private let maxEntryCount = 50_000

	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let archiveSize = file.size
		let normalizedPath = file.path.lowercased()
		let isGzipped = normalizedPath.hasSuffix(".tar.gz") || normalizedPath.hasSuffix(".tgz")
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.scanTAR(at: fileURL, isGzipped: isGzipped)
		}
		let fileTree = makeFileTree(from: payload.entries)
		let scannedSize = try checkedInt64(payload.scannedUncompressedSize ?? 0)
		var labelText =
			"\(isGzipped ? "Compressed" : "Size"): \(byteCountFormatter.string(fromByteCount: Int64(archiveSize)))"

		if isGzipped {
			let uncompressedPrefix = payload.truncated ? "at least " : ""
			labelText += """

			Uncompressed: \(uncompressedPrefix)\(byteCountFormatter
				.string(fromByteCount: scannedSize))
			"""
			if payload.truncated {
				labelText +=
					"\nPreview truncated after scanning \(byteCountFormatter.string(fromByteCount: scannedSize))"
			} else {
				labelText +=
					"\nCompression ratio: \(compressionRatioText(compressed: Int64(archiveSize), uncompressed: scannedSize)) %"
			}
		} else if payload.truncated {
			labelText += "\nPreview truncated after \(maxEntryCount) entries"
		}

		return OutlinePreviewVC(rootNodes: fileTree.root.childrenList, labelText: labelText)
	}

	private func makeFileTree(from entries: [ArchivePreviewEntry]) -> FileTree {
		let fileTree = FileTree()
		for entry in entries {
			do {
				try fileTree.addNode(
					path: entry.path,
					isDirectory: entry.entryType == .directory,
					size: clampedInt(entry.size),
					dateModified: entry.modifiedUnixSeconds.map(Date.init(timeIntervalSince1970:))
				)
			} catch {
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
			}
		}
		return fileTree
	}

	private func checkedInt64(_ value: UInt64) throws -> Int64 {
		guard value <= UInt64(Int64.max) else {
			throw TARPreviewError.metadataSizeLimitExceeded
		}
		return Int64(value)
	}

	private func clampedInt(_ value: UInt64) -> Int {
		value > UInt64(Int.max) ? Int.max : Int(value)
	}

	private func compressionRatioText(compressed: Int64, uncompressed: Int64) -> String {
		guard uncompressed != 0 else {
			return "0.0"
		}
		let ratio = 100.0 - Double(compressed) / Double(uncompressed) * 100.0
		return String(format: "%.1f", ratio)
	}
}

private enum TARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		"TAR archive metadata is too large to preview safely"
	}
}
