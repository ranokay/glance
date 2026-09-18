import Foundation

/// Presentation adapter for TAR and gzip-compressed TAR metadata parsed by PreviewCore.
class TARPreview: Preview {
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
		let scannedSize = payload.scannedUncompressedSize ?? 0
		_ = try checkedInt64(scannedSize)
		let labelText: String = if isGzipped {
			ArchiveStatusFormatter.status(
				compressed: UInt64(max(0, archiveSize)),
				uncompressed: scannedSize,
				uncompressedPrefix: payload.truncated ? "at least " : "",
				trailingNote: payload.truncated ? "Preview truncated" : nil,
				includesPercentage: !payload.truncated
			)
		} else {
			ArchiveStatusFormatter.size(
				UInt64(max(0, archiveSize)),
				trailingNote: payload.truncated
					? "Preview truncated after \(maxEntryCount) entries"
					: nil
			)
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
}

private enum TARPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		"TAR archive metadata is too large to preview safely"
	}
}
