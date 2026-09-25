import Foundation
import UniformTypeIdentifiers

enum DirectoryPreviewError: LocalizedError {
	case directoryReadError(path: String, message: String)
	case notDirectory(path: String)
	case temporaryDirectory(path: String)

	var errorDescription: String? {
		switch self {
			case let .directoryReadError(path, message):
				"Could not read directory at path \(path): \(message)"
			case let .notDirectory(path):
				"Directory preview expected a directory at path \(path)"
			case let .temporaryDirectory(path):
				"Temporary directory at path \(path) is not previewed"
		}
	}
}

struct DirectoryPreviewEntry {
	let name: String
	let isDirectory: Bool
	let size: Int
	let dateModified: Date?
	let fileURL: URL
	let isPackage: Bool
	let isSymbolicLink: Bool
	let contentTypeIdentifier: String?
}

struct DirectoryPage {
	let entries: [DirectoryPreviewEntry]
	let nextOffset: Int?
	let totalItemCount: Int
}

struct DirectoryPaginationSession: Hashable {
	private let id = UUID()
}

protocol DirectoryPageLoading: Sendable {
	func page(
		at directoryURL: URL,
		offset: Int,
		session: DirectoryPaginationSession
	) async throws -> DirectoryPage
}

/// Keeps stable name cursors and lightweight ordered snapshots for each retained directory view.
/// Snapshots are invalidated by directory modification time and released after the last page.
actor DirectoryPageLoader: DirectoryPageLoading {
	let fileManager: FileManager
	let pageSize: Int
	private var pageCursors = [DirectoryPaginationSession: [URL: [Int: String]]]()
	private var directorySnapshots = [DirectoryPaginationSession: [URL: DirectorySnapshot]]()

	init(fileManager: sending FileManager, pageSize: Int) {
		self.fileManager = fileManager
		self.pageSize = pageSize
	}

	func page(
		at directoryURL: URL,
		offset: Int,
		session: DirectoryPaginationSession
	) async throws -> DirectoryPage {
		let pageURL = directoryURL.standardizedFileURL
		let safeOffset = max(0, offset)
		let afterName: String?
		if safeOffset == 0 {
			pageCursors[session, default: [:]][pageURL] = [:]
			directorySnapshots[session, default: [:]][pageURL] = nil
			afterName = nil
		} else {
			guard let cursor = pageCursors[session]?[pageURL]?[safeOffset] else {
				throw DirectoryPreviewError.directoryReadError(
					path: pageURL.path,
					message: "The directory page cursor is no longer available"
				)
			}
			afterName = cursor
		}

		let scanner = DirectoryPageScanner(fileManager: fileManager, pageSize: pageSize)
		let currentModificationDate = try await PreviewExecutor.run {
			try scanner.modificationDate(for: pageURL)
		}
		let cachedSnapshot = directorySnapshots[session]?[pageURL]
		let snapshot: DirectorySnapshot
		if let cachedSnapshot,
		   let currentModificationDate,
		   cachedSnapshot.modificationDate == currentModificationDate
		{
			snapshot = cachedSnapshot
		} else {
			snapshot = try await PreviewExecutor.run {
				try scanner.snapshot(directoryURL: pageURL)
			}
			try Task.checkCancellation()
			directorySnapshots[session, default: [:]][pageURL] = snapshot
		}
		let scanResult = try await PreviewExecutor.run {
			do {
				return try scanner.page(
					from: snapshot,
					offset: safeOffset,
					afterName: afterName
				)
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				throw DirectoryPreviewError.directoryReadError(
					path: pageURL.path,
					message: error.localizedDescription
				)
			}
		}
		try Task.checkCancellation()
		if let nextOffset = scanResult.page.nextOffset {
			if let continuationName = scanResult.continuationName {
				pageCursors[session, default: [:]][pageURL, default: [:]][
					nextOffset
				] = continuationName
			}
		} else {
			directorySnapshots[session]?[pageURL] = nil
		}
		return scanResult.page
	}
}
