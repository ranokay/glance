import Foundation

class ZIPPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let archiveSize = file.size
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.scanZIP(at: fileURL)
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
}

enum ZIPPreviewError: LocalizedError {
	case metadataSizeLimitExceeded

	var errorDescription: String? {
		NSLocalizedString("ZIP archive metadata is too large to preview safely", comment: "")
	}
}
