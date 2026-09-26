import Foundation
import GlanceKit

/// Shared scan → tree → outline pipeline for archive previews.
///
/// ZIP, RAR, 7z, and TAR previews are adapters over this module: each declares
/// its scan, entry-size policy, and label, while the pipeline owns tree
/// building. Per-format error and label behavior is preserved exactly.
enum ArchivePreview {
	struct Policy {
		var entrySize: (UInt64) throws -> Int
		var rethrowsEntryError: (Error) -> Bool
		var validateTotal: (ArchivePreviewPayload) throws -> Void
		var label: @MainActor (File, ArchivePreviewPayload) -> String

		private init(
			entrySize: @escaping (UInt64) throws -> Int,
			rethrowsEntryError: @escaping (Error) -> Bool,
			validateTotal: @escaping (ArchivePreviewPayload) throws -> Void,
			label: @escaping @MainActor (File, ArchivePreviewPayload) -> String
		) {
			self.entrySize = entrySize
			self.rethrowsEntryError = rethrowsEntryError
			self.validateTotal = validateTotal
			self.label = label
		}
	}

	@MainActor
	static func makePreview(
		file: File,
		scan: @Sendable @escaping () throws -> ArchivePreviewPayload,
		policy: Policy
	) async throws -> PreviewVC {
		let payload = try await PreviewExecutor.run(scan)
		let fileTree = try buildTree(from: payload.entries, policy: policy)
		try policy.validateTotal(payload)
		return OutlinePreviewVC(
			rootNodes: fileTree.root.childrenList,
			labelText: policy.label(file, payload)
		)
	}

	static func buildTree(
		from entries: [ArchivePreviewEntry],
		policy: Policy
	) throws -> FileTree {
		let fileTree = FileTree()
		for entry in entries {
			do {
				try fileTree.addNode(
					path: entry.path,
					isDirectory: entry.entryType == .directory,
					size: try policy.entrySize(entry.size),
					dateModified: entry.modifiedUnixSeconds.map(Date.init(timeIntervalSince1970:))
				)
			} catch {
				if policy.rethrowsEntryError(error) {
					throw error
				}
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
			}
		}
		return fileTree
	}

	static func boundedInt(_ value: UInt64, overLimit error: Error) throws -> Int {
		guard value <= UInt64(Int.max) else {
			throw error
		}
		return Int(value)
	}

	static func boundedInt64(_ value: UInt64, overLimit error: Error) throws -> Int64 {
		guard value <= UInt64(Int64.max) else {
			throw error
		}
		return Int64(value)
	}

	@MainActor
	static func standardLabel(file: File, payload: ArchivePreviewPayload) -> String {
		ArchiveStatusFormatter.status(
			compressed: UInt64(max(0, file.size)),
			uncompressed: payload.uncompressedSize
		)
	}
}

extension ArchivePreview.Policy {
	static var zip: Self {
		Self(
			entrySize: {
				try ArchivePreview.boundedInt(
					$0,
					overLimit: ZIPPreviewError.metadataSizeLimitExceeded
				)
			},
			// Bridge match never fires; kept byte-identical pending #82.
			rethrowsEntryError: { $0 is ZIPPreviewError || $0 is PreviewCoreBridgeError },
			validateTotal: {
				_ = try ArchivePreview.boundedInt(
					$0.uncompressedSize,
					overLimit: ZIPPreviewError.metadataSizeLimitExceeded
				)
			},
			label: ArchivePreview.standardLabel
		)
	}

	static var rar: Self {
		Self(
			entrySize: {
				try ArchivePreview.boundedInt(
					$0,
					overLimit: RARPreviewError.metadataSizeLimitExceeded
				)
			},
			rethrowsEntryError: { $0 is RARPreviewError },
			validateTotal: {
				_ = try ArchivePreview.boundedInt(
					$0.uncompressedSize,
					overLimit: RARPreviewError.metadataSizeLimitExceeded
				)
			},
			label: ArchivePreview.standardLabel
		)
	}

	static var sevenZip: Self {
		Self(
			entrySize: {
				try ArchivePreview.boundedInt(
					$0,
					overLimit: SevenZipPreviewError.metadataSizeLimitExceeded
				)
			},
			rethrowsEntryError: { $0 is SevenZipPreviewError },
			validateTotal: {
				_ = try ArchivePreview.boundedInt(
					$0.uncompressedSize,
					overLimit: SevenZipPreviewError.metadataSizeLimitExceeded
				)
			},
			label: ArchivePreview.standardLabel
		)
	}

	static func tar(isGzipped: Bool, maxEntryCount: Int) -> Self {
		Self(
			entrySize: { $0 > UInt64(Int.max) ? Int.max : Int($0) },
			rethrowsEntryError: { _ in false },
			validateTotal: {
				_ = try ArchivePreview.boundedInt64(
					$0.scannedUncompressedSize ?? 0,
					overLimit: TARPreviewError.metadataSizeLimitExceeded
				)
			},
			label: { @MainActor file, payload in
				let archiveSize = file.size
				if isGzipped {
					return ArchiveStatusFormatter.status(
						compressed: UInt64(max(0, archiveSize)),
						uncompressed: payload.scannedUncompressedSize ?? 0,
						uncompressedPrefix: payload.truncated ? "at least " : "",
						trailingNote: payload.truncated ? "Preview truncated" : nil,
						includesPercentage: !payload.truncated
					)
				} else {
					return ArchiveStatusFormatter.size(
						UInt64(max(0, archiveSize)),
						trailingNote: payload.truncated
							? "Preview truncated after \(maxEntryCount) entries"
							: nil
					)
				}
			}
		)
	}
}
