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

class DirectoryPreview: Preview {
	static let defaultMaxItemCount = 500
	static let defaultMaxDepth = 5
	private static let defaultExcludedRootURLs = [
		FileManager.default.temporaryDirectory,
		URL(fileURLWithPath: "/private/var/folders", isDirectory: true),
		URL(fileURLWithPath: "/var/folders", isDirectory: true),
		URL(fileURLWithPath: "/private/tmp", isDirectory: true),
		URL(fileURLWithPath: "/tmp", isDirectory: true),
	]

	private let fileManager: FileManager
	private let maxItemCount: Int
	private let maxDepth: Int
	private let excludedRootURLs: [URL]

	required convenience init() {
		self.init(
			fileManager: .default,
			maxItemCount: Self.defaultMaxItemCount,
			maxDepth: Self.defaultMaxDepth,
			excludedRootURLs: Self.defaultExcludedRootURLs
		)
	}

	init(
		fileManager: FileManager,
		maxItemCount: Int,
		maxDepth: Int,
		excludedRootURLs: [URL]
	) {
		self.fileManager = fileManager
		self.maxItemCount = max(0, maxItemCount)
		self.maxDepth = max(0, maxDepth)
		self.excludedRootURLs = excludedRootURLs.map(\.standardizedFileURL)
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		guard file.isDirectory else {
			throw DirectoryPreviewError.notDirectory(path: file.path)
		}
		guard !isExcluded(file.url) else {
			throw DirectoryPreviewError.temporaryDirectory(path: file.path)
		}

		let rootURL = file.url
		let scanner = DirectoryScanner(
			fileManager: fileManager,
			maxItemCount: maxItemCount,
			maxDepth: maxDepth
		)
		let scanResult = try await PreviewExecutor.run {
			try scanner.scan(rootURL: rootURL)
		}
		let fileTree = makeFileTree(from: scanResult.entries)
		let itemSuffix = scanResult.isTruncated ? "+" : ""
		let itemNoun = scanResult.itemCount == 1 && !scanResult.isTruncated ? "item" : "items"
		let labelText = "\(scanResult.itemCount)\(itemSuffix) \(itemNoun)"

		return OutlinePreviewVC(
			rootNodes: fileTree.root.childrenList,
			labelText: labelText,
			expandAll: true,
			showsFileThumbnails: true
		)
	}

	private func makeFileTree(from entries: [DirectoryPreviewEntry]) -> FileTree {
		let fileTree = FileTree()
		for entry in entries {
			do {
				try fileTree.addNode(
					path: entry.relativePath,
					isDirectory: entry.isDirectory,
					size: entry.size,
					dateModified: entry.dateModified,
					fileURL: entry.fileURL,
					isPackage: entry.isPackage,
					isSymbolicLink: entry.isSymbolicLink,
					contentTypeIdentifier: entry.contentTypeIdentifier
				)
			} catch {
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
			}
		}
		return fileTree
	}

	private func isExcluded(_ url: URL) -> Bool {
		let path = url.standardizedFileURL.path
		return excludedRootURLs.contains { rootURL in
			let rootPath = rootURL.path
			return path == rootPath || path.hasPrefix("\(rootPath)/")
		}
	}
}

private struct DirectoryScanResult {
	let entries: [DirectoryPreviewEntry]
	let itemCount: Int
	let isTruncated: Bool
}

private struct DirectoryPreviewEntry {
	let relativePath: String
	let isDirectory: Bool
	let size: Int
	let dateModified: Date?
	let fileURL: URL
	let isPackage: Bool
	let isSymbolicLink: Bool
	let contentTypeIdentifier: String?
}

/// FileManager instances are confined to the detached scan that owns this value.
private struct DirectoryScanner: @unchecked Sendable {
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
	let maxItemCount: Int
	let maxDepth: Int

	func scan(rootURL: URL) throws -> DirectoryScanResult {
		var entries = [DirectoryPreviewEntry]()
		var itemCount = 0
		var isTruncated = false
		try scanDirectory(
			at: rootURL,
			relativePath: "",
			depth: 0,
			isRoot: true,
			entries: &entries,
			itemCount: &itemCount,
			isTruncated: &isTruncated
		)
		return DirectoryScanResult(
			entries: entries,
			itemCount: itemCount,
			isTruncated: isTruncated
		)
	}

	private func scanDirectory(
		at directoryURL: URL,
		relativePath: String,
		depth: Int,
		isRoot: Bool,
		entries: inout [DirectoryPreviewEntry],
		itemCount: inout Int,
		isTruncated: inout Bool
	) throws {
		try Task.checkCancellation()
		guard depth < maxDepth else {
			return
		}

		let contents: [URL]
		let hasMoreContents: Bool
		do {
			(contents, hasMoreContents) = try sortedDirectoryContents(
				at: directoryURL,
				retaining: maxItemCount - itemCount + 1
			)
		} catch {
			if isRoot {
				throw DirectoryPreviewError.directoryReadError(
					path: directoryURL.path,
					message: error.localizedDescription
				)
			}
			Log.general.error(
				"Could not read directory \(directoryURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			return
		}

		for itemURL in contents {
			try Task.checkCancellation()
			guard itemCount < maxItemCount else {
				isTruncated = true
				return
			}
			let resourceValues: URLResourceValues
			do {
				resourceValues = try itemURL.resourceValues(forKeys: Self.resourceKeys)
			} catch {
				Log.general.error(
					"Could not read item metadata \(itemURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				continue
			}

			let isDirectory = resourceValues.isDirectory ?? false
			let itemRelativePath = relativePath.isEmpty
				? itemURL.lastPathComponent
				: "\(relativePath)/\(itemURL.lastPathComponent)"
			entries.append(
				DirectoryPreviewEntry(
					relativePath: itemRelativePath,
					isDirectory: isDirectory,
					size: isDirectory ? 0 : resourceValues.fileSize ?? 0,
					dateModified: resourceValues.contentModificationDate,
					fileURL: itemURL,
					isPackage: resourceValues.isPackage ?? false,
					isSymbolicLink: resourceValues.isSymbolicLink ?? false,
					contentTypeIdentifier: resourceValues.contentType?.identifier
				)
			)
			itemCount += 1

			guard isDirectory,
			      resourceValues.isSymbolicLink != true,
			      resourceValues.isPackage != true
			else {
				continue
			}
			try scanDirectory(
				at: itemURL,
				relativePath: itemRelativePath,
				depth: depth + 1,
				isRoot: false,
				entries: &entries,
				itemCount: &itemCount,
				isTruncated: &isTruncated
			)
		}
		isTruncated = isTruncated || hasMoreContents
	}

	/// Retains only the deterministic prefix needed by the global item limit.
	private func sortedDirectoryContents(
		at directoryURL: URL,
		retaining requestedLimit: Int
	) throws -> (contents: [URL], hasMoreContents: Bool) {
		let limit = max(1, requestedLimit)
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

		var contents = [URL]()
		var itemTotal = 0
		for case let itemURL as URL in enumerator {
			try Task.checkCancellation()
			itemTotal += 1
			let insertionIndex = Self.insertionIndex(for: itemURL, in: contents)
			contents.insert(itemURL, at: insertionIndex)
			if contents.count > limit {
				contents.removeLast()
			}
		}
		if let enumerationError {
			throw enumerationError
		}
		return (contents, itemTotal > limit)
	}

	private static func insertionIndex(for itemURL: URL, in contents: [URL]) -> Int {
		var lowerBound = 0
		var upperBound = contents.count
		while lowerBound < upperBound {
			let index = lowerBound + (upperBound - lowerBound) / 2
			if isOrderedBefore(itemURL, contents[index]) {
				upperBound = index
			} else {
				lowerBound = index + 1
			}
		}
		return lowerBound
	}

	private static func isOrderedBefore(_ lhsURL: URL, _ rhsURL: URL) -> Bool {
		let lhsName = lhsURL.lastPathComponent
		let rhsName = rhsURL.lastPathComponent
		let comparison = lhsName.compare(
			rhsName,
			options: [.caseInsensitive, .numeric],
			range: nil,
			locale: sortLocale
		)
		return comparison == .orderedSame ? lhsName < rhsName : comparison == .orderedAscending
	}
}
