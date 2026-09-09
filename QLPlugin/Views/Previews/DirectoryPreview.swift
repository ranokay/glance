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

protocol DirectoryPageLoading: Sendable {
	func page(at directoryURL: URL, offset: Int) async throws -> DirectoryPage
}

/// Keeps a stable name cursor for each directory page while retaining only one UI-sized batch.
/// Insertions or removals before the cursor cannot shift later pages into duplicates or omissions.
actor DirectoryPageLoader: DirectoryPageLoading {
	let fileManager: FileManager
	let pageSize: Int
	private var pageCursors = [URL: [Int: String]]()

	init(fileManager: sending FileManager, pageSize: Int) {
		self.fileManager = fileManager
		self.pageSize = pageSize
	}

	func page(at directoryURL: URL, offset: Int) async throws -> DirectoryPage {
		let pageURL = directoryURL.standardizedFileURL
		let safeOffset = max(0, offset)
		let afterName: String?
		if safeOffset == 0 {
			pageCursors[pageURL] = [:]
			afterName = nil
		} else {
			guard let cursor = pageCursors[pageURL]?[safeOffset] else {
				throw DirectoryPreviewError.directoryReadError(
					path: pageURL.path,
					message: "The directory page cursor is no longer available"
				)
			}
			afterName = cursor
		}

		let scanner = DirectoryPageScanner(fileManager: fileManager, pageSize: pageSize)
		let scanResult = try await PreviewExecutor.run {
			do {
				return try scanner.scan(
					directoryURL: pageURL,
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
				pageCursors[pageURL, default: [:]][nextOffset] = continuationName
			}
		}
		return scanResult.page
	}
}

class DirectoryPreview: Preview {
	static let defaultPageSize = 500
	// Kept as source compatibility for older tests and callers; traversal is now one level at a
	// time.
	static let defaultMaxItemCount = defaultPageSize
	static let defaultMaxDepth = 5
	private static let defaultExcludedRootURLs = [
		FileManager.default.temporaryDirectory,
		URL(fileURLWithPath: "/private/var/folders", isDirectory: true),
		URL(fileURLWithPath: "/var/folders", isDirectory: true),
		URL(fileURLWithPath: "/private/tmp", isDirectory: true),
		URL(fileURLWithPath: "/tmp", isDirectory: true),
	]

	private let pageLoader: any DirectoryPageLoading
	private let excludedRootURLs: [URL]

	required convenience init() {
		self.init(
			fileManager: .default,
			maxItemCount: Self.defaultPageSize,
			maxDepth: Self.defaultMaxDepth,
			excludedRootURLs: Self.defaultExcludedRootURLs
		)
	}

	init(
		fileManager: sending FileManager,
		maxItemCount: Int,
		maxDepth _: Int,
		excludedRootURLs: [URL]
	) {
		pageLoader = DirectoryPageLoader(
			fileManager: fileManager,
			pageSize: max(1, maxItemCount)
		)
		self.excludedRootURLs = excludedRootURLs.map(\.standardizedFileURL)
	}

	init(pageLoader: any DirectoryPageLoading, excludedRootURLs: [URL] = []) {
		self.pageLoader = pageLoader
		self.excludedRootURLs = excludedRootURLs.map(\.standardizedFileURL)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		guard file.isDirectory else {
			throw DirectoryPreviewError.notDirectory(path: file.path)
		}
		guard !isExcluded(file.url) else {
			throw DirectoryPreviewError.temporaryDirectory(path: file.path)
		}

		return try await Self.makeOutlinePreview(
			for: file.url,
			pageLoader: pageLoader
		)
	}

	@MainActor
	static func makeOutlinePreview(
		for directoryURL: URL,
		pageLoader: any DirectoryPageLoading
	) async throws -> OutlinePreviewVC {
		let page = try await pageLoader.page(at: directoryURL, offset: 0)
		try Task.checkCancellation()
		var rootNodes = makeNodes(from: page.entries)
		if let nextOffset = page.nextOffset {
			rootNodes.append(.loadMoreNode(offset: nextOffset))
		}
		return OutlinePreviewVC(
			rootNodes: rootNodes,
			labelText: itemCountText(
				loadedCount: page.entries.count,
				hasMore: page.nextOffset != nil
			),
			expandAll: false,
			showsFileThumbnails: true,
			directoryURL: directoryURL,
			directoryPageLoader: pageLoader
		)
	}

	@MainActor
	static func makeNodes(from entries: [DirectoryPreviewEntry]) -> [FileTreeNode] {
		entries.map { entry in
			FileTreeNode(
				name: entry.name,
				size: entry.size,
				isDirectory: entry.isDirectory,
				dateModified: entry.dateModified,
				fileURL: entry.fileURL,
				isPackage: entry.isPackage,
				isSymbolicLink: entry.isSymbolicLink,
				contentTypeIdentifier: entry.contentTypeIdentifier,
				directoryChildrenState: entry.isDirectory
					&& !entry.isPackage
					&& !entry.isSymbolicLink
					? .notLoaded
					: .loaded(nextOffset: nil)
			)
		}
	}

	static func itemCountText(loadedCount: Int, hasMore: Bool) -> String {
		let suffix = hasMore ? "+" : ""
		let noun = loadedCount == 1 && !hasMore ? "item" : "items"
		return "\(loadedCount)\(suffix) \(noun)"
	}

	private func isExcluded(_ url: URL) -> Bool {
		let path = url.standardizedFileURL.path
		return excludedRootURLs.contains { rootURL in
			let rootPath = rootURL.path
			return path == rootPath || path.hasPrefix("\(rootPath)/")
		}
	}
}

private struct DirectoryPageScanner: @unchecked Sendable {
	private static let sortLocale = Locale(identifier: "en_US_POSIX")
	private static let resourceKeys: Set<URLResourceKey> = [
		.contentModificationDateKey,
		.fileSizeKey,
		.isDirectoryKey,
		.isPackageKey,
		.isSymbolicLinkKey,
		.contentTypeKey,
	]

	let fileManager: FileManager
	let pageSize: Int

	func scan(
		directoryURL: URL,
		offset: Int,
		afterName: String?
	) throws -> (page: DirectoryPage, continuationName: String?) {
		try Task.checkCancellation()
		let retainedLimit = pageSize.addingReportingOverflow(1)
		guard !retainedLimit.overflow else {
			throw CocoaError(.fileReadTooLarge)
		}

		var enumerationError: Error?
		guard let enumerator = fileManager.enumerator(
			at: directoryURL,
			includingPropertiesForKeys: Array(Self.resourceKeys),
			options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
			errorHandler: { _, error in
				enumerationError = error
				return false
			}
		) else {
			throw CocoaError(.fileReadUnknown)
		}

		var retainedEntries = [DirectoryPreviewEntry]()
		var itemCount = 0
		for case let itemURL as URL in enumerator {
			try Task.checkCancellation()
			let values: URLResourceValues
			do {
				values = try itemURL.resourceValues(forKeys: Self.resourceKeys)
			} catch {
				Log.general.error(
					"Could not read item metadata \(itemURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				continue
			}

			let isDirectory = values.isDirectory ?? false
			let entry = DirectoryPreviewEntry(
				name: itemURL.lastPathComponent,
				isDirectory: isDirectory,
				size: isDirectory ? 0 : values.fileSize ?? 0,
				dateModified: values.contentModificationDate,
				fileURL: itemURL,
				isPackage: values.isPackage ?? false,
				isSymbolicLink: values.isSymbolicLink ?? false,
				contentTypeIdentifier: values.contentType?.identifier
			)
			itemCount += 1
			guard afterName.map({ Self.isOrderedAfter(entry.name, $0) }) ?? true else {
				continue
			}
			let insertionIndex = Self.insertionIndex(for: entry, in: retainedEntries)
			retainedEntries.insert(entry, at: insertionIndex)
			if retainedEntries.count > retainedLimit.partialValue {
				retainedEntries.removeLast()
			}
		}
		if let enumerationError {
			throw enumerationError
		}

		let hasMore = retainedEntries.count > pageSize
		if hasMore {
			retainedEntries.removeLast(retainedEntries.count - pageSize)
		}
		let nextOffsetValue = offset.addingReportingOverflow(retainedEntries.count)
		guard !nextOffsetValue.overflow else {
			throw CocoaError(.fileReadTooLarge)
		}
		let nextOffset = hasMore ? nextOffsetValue.partialValue : nil
		return (
			DirectoryPage(
				entries: retainedEntries,
				nextOffset: nextOffset,
				totalItemCount: itemCount
			),
			nextOffset == nil ? nil : retainedEntries.last?.name
		)
	}

	private static func insertionIndex(
		for entry: DirectoryPreviewEntry,
		in entries: [DirectoryPreviewEntry]
	) -> Int {
		var lowerBound = 0
		var upperBound = entries.count
		while lowerBound < upperBound {
			let index = lowerBound + (upperBound - lowerBound) / 2
			if isOrderedBefore(entry, entries[index]) {
				upperBound = index
			} else {
				lowerBound = index + 1
			}
		}
		return lowerBound
	}

	private static func isOrderedBefore(
		_ lhs: DirectoryPreviewEntry,
		_ rhs: DirectoryPreviewEntry
	) -> Bool {
		compareNames(lhs.name, rhs.name) == .orderedAscending
	}

	private static func isOrderedAfter(_ name: String, _ cursorName: String) -> Bool {
		compareNames(name, cursorName) == .orderedDescending
	}

	private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
		let comparison = lhs.compare(
			rhs,
			options: [.caseInsensitive, .numeric],
			range: nil,
			locale: sortLocale
		)
		if comparison != .orderedSame {
			return comparison
		}
		if lhs == rhs {
			return .orderedSame
		}
		return lhs < rhs ? .orderedAscending : .orderedDescending
	}
}
