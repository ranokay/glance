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
	private static let sortLocale = Locale(identifier: "en_US_POSIX")

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

	func createPreviewVC(file: File) throws -> PreviewVC {
		guard file.isDirectory else {
			throw DirectoryPreviewError.notDirectory(path: file.path)
		}
		guard !isExcluded(file.url) else {
			throw DirectoryPreviewError.temporaryDirectory(path: file.path)
		}

		let scanResult = try scanDirectory(rootURL: file.url)
		let itemSuffix = scanResult.isTruncated ? "+" : ""
		let itemNoun = scanResult.itemCount == 1 && !scanResult.isTruncated ? "item" : "items"
		let labelText = "\(scanResult.itemCount)\(itemSuffix) \(itemNoun)"

		return OutlinePreviewVC(
			rootNodes: scanResult.fileTree.root.childrenList,
			labelText: labelText,
			expandAll: true,
			showsFileThumbnails: true,
			searchEnabled: true,
			searchItemLimitReached: scanResult.isTruncated
		)
	}

	private func scanDirectory(rootURL: URL) throws -> DirectoryScanResult {
		let fileTree = FileTree()
		var itemCount = 0
		var isTruncated = false
		try scanDirectory(
			at: rootURL,
			relativePath: "",
			depth: 0,
			isRoot: true,
			fileTree: fileTree,
			itemCount: &itemCount,
			isTruncated: &isTruncated
		)
		return DirectoryScanResult(
			fileTree: fileTree,
			itemCount: itemCount,
			isTruncated: isTruncated
		)
	}

	private func scanDirectory(
		at directoryURL: URL,
		relativePath: String,
		depth: Int,
		isRoot: Bool,
		fileTree: FileTree,
		itemCount: inout Int,
		isTruncated: inout Bool
	) throws {
		guard depth < maxDepth else {
			return
		}

		let contents: [URL]
		do {
			let directoryContents = try fileManager.contentsOfDirectory(
				at: directoryURL,
				includingPropertiesForKeys: [
					.contentModificationDateKey,
					.fileSizeKey,
					.isDirectoryKey,
					.isPackageKey,
					.isSymbolicLinkKey,
					.contentTypeKey,
				],
				options: [.skipsHiddenFiles]
			)
			contents = directoryContents.sorted { lhsURL, rhsURL in
				let lhsName = lhsURL.lastPathComponent
				let rhsName = rhsURL.lastPathComponent
				let comparison = lhsName.compare(
					rhsName,
					options: [.caseInsensitive, .numeric],
					range: nil,
					locale: Self.sortLocale
				)
				if comparison == .orderedSame {
					return lhsName < rhsName
				}
				return comparison == .orderedAscending
			}
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
			guard itemCount < maxItemCount else {
				isTruncated = true
				return
			}

			let resourceValues: URLResourceValues
			do {
				resourceValues = try itemURL.resourceValues(forKeys: [
					.contentModificationDateKey,
					.fileSizeKey,
					.isDirectoryKey,
					.isPackageKey,
					.isSymbolicLinkKey,
					.contentTypeKey,
				])
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
			do {
				try fileTree.addNode(
					path: itemRelativePath,
					isDirectory: isDirectory,
					size: isDirectory ? 0 : resourceValues.fileSize ?? 0,
					dateModified: resourceValues.contentModificationDate,
					fileURL: itemURL,
					isPackage: resourceValues.isPackage ?? false,
					isSymbolicLink: resourceValues.isSymbolicLink ?? false,
					contentTypeIdentifier: resourceValues.contentType?.identifier
				)
				itemCount += 1
			} catch {
				Log.parse.error("\(error.localizedDescription, privacy: .private)")
				continue
			}

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
				fileTree: fileTree,
				itemCount: &itemCount,
				isTruncated: &isTruncated
			)
		}
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
	let fileTree: FileTree
	let itemCount: Int
	let isTruncated: Bool
}
