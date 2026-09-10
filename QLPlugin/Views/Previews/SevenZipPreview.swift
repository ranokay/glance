import Foundation

class SevenZipPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let archiveSize = file.size
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.scanSevenZip(at: fileURL)
		}
		let fileTree = try makeFileTree(from: payload.entries)
		_ = try checkedInt(payload.uncompressedSize)

		let labelText = ArchiveStatusFormatter.status(
			compressed: UInt64(max(0, archiveSize)),
			uncompressed: payload.uncompressedSize
		)
		return OutlinePreviewVC(rootNodes: fileTree.root.childrenList, labelText: labelText)
	}

	private func makeFileTree(from entries: [ArchivePreviewEntry]) throws -> FileTree {
		let fileTree = FileTree()
		for entry in entries {
			do {
				try fileTree.addNode(
					path: entry.path,
					isDirectory: entry.entryType == .directory,
					size: try checkedInt(entry.size),
					dateModified: entry.modifiedUnixSeconds.map(Date.init(timeIntervalSince1970:))
				)
			} catch let error as SevenZipPreviewError {
				throw error
			} catch {
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
			}
		}
		return fileTree
	}

	private func checkedInt(_ value: UInt64) throws -> Int {
		guard value <= UInt64(Int.max) else {
			throw SevenZipPreviewError.metadataSizeLimitExceeded
		}
		return Int(value)
	}
}

private enum SevenZipPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("7z archive metadata is too large to preview safely", comment: "")
	}
}
