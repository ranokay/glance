import Foundation
import UniformTypeIdentifiers

class DirectoryPreview: Preview {
	static let defaultPageSize = 500
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
			excludedRootURLs: Self.defaultExcludedRootURLs
		)
	}

	init(
		fileManager: sending FileManager,
		maxItemCount: Int,
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
		let paginationSession = DirectoryPaginationSession()
		let page = try await pageLoader.page(
			at: directoryURL,
			offset: 0,
			session: paginationSession
		)
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
			directoryPageLoader: pageLoader,
			directoryPaginationSession: paginationSession
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
