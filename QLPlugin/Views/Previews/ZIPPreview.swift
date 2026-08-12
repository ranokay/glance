import Foundation

class ZIPPreview: Preview {
	let byteCountFormatter = ByteCountFormatter()

	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let archiveSize = file.size
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.scanZIP(at: fileURL)
		}
		let fileTree = try makeFileTree(from: payload.entries)
		let uncompressedSize = try checkedInt(payload.uncompressedSize)

		let labelText = """
		Compressed: \(byteCountFormatter.string(for: archiveSize) ?? "--")
		Uncompressed: \(byteCountFormatter.string(for: uncompressedSize) ?? "--")
		Compression ratio: \(compressionRatioText(
			compressed: payload.compressedSize,
			uncompressed: payload.uncompressedSize
		)) %
		"""
		return OutlinePreviewVC(rootNodes: fileTree.root.childrenList, labelText: labelText)
	}

	private func makeFileTree(from entries: [ArchivePreviewEntry]) throws -> FileTree {
		let fileTree = FileTree()
		for entry in entries {
			let size = try checkedInt(entry.size)
			do {
				try fileTree.addNode(
					path: entry.path,
					isDirectory: entry.entryType == .directory,
					size: size,
					dateModified: entry.modifiedUnixSeconds.map(Date.init(timeIntervalSince1970:))
				)
			} catch let error as PreviewCoreBridgeError {
				throw error
			} catch {
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
			}
		}
		return fileTree
	}

	private func checkedInt(_ value: UInt64) throws -> Int {
		guard value <= UInt64(Int.max) else {
			throw ZIPPreviewError.metadataSizeLimitExceeded
		}
		return Int(value)
	}

	private func compressionRatioText(compressed: UInt64, uncompressed: UInt64) -> String {
		guard uncompressed != 0 else {
			return "0.0"
		}
		let ratio = 100.0 - Double(compressed) / Double(uncompressed) * 100.0
		return String(format: "%.1f", ratio)
	}
}

enum ZIPPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("ZIP archive metadata is too large to preview safely", comment: "")
	}
}
