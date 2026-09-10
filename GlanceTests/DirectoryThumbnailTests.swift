import Cocoa
import UniformTypeIdentifiers
import XCTest

@MainActor
final class DirectoryThumbnailTests: XCTestCase {
	func testDirectoryMetadataIsStoredOnTreeNodes() throws {
		let fileTree = FileTree()
		let fileURL = URL(fileURLWithPath: "/tmp/example.png")
		try fileTree.addNode(
			path: "folder/example.png",
			isDirectory: false,
			size: 12,
			dateModified: nil,
			fileURL: fileURL,
			isPackage: false,
			isSymbolicLink: false,
			contentTypeIdentifier: UTType.png.identifier
		)

		let node = try XCTUnwrap(fileTree.root.children["folder"]?.children["example.png"])
		XCTAssertEqual(node.fileURL, fileURL)
		XCTAssertFalse(node.isPackage)
		XCTAssertFalse(node.isSymbolicLink)
		XCTAssertEqual(node.contentTypeIdentifier, UTType.png.identifier)
	}

	func testIconTransformerPrefersThumbnailThenFileSpecificIconThenArchiveFallback() {
		let fileURL = URL(fileURLWithPath: "/tmp/movie.mp4")
		let fileIcon = NSImage(size: NSSize(width: 16, height: 16))
		let thumbnail = NSImage(size: NSSize(width: 32, height: 32))
		let provider = RecordingFileIconProvider(icon: fileIcon)
		let transformer = IconTransformer(fileIconProvider: provider)
		let fileNode = FileTreeNode(
			name: "movie.mp4",
			size: 1,
			isDirectory: false,
			dateModified: nil,
			fileURL: fileURL
		)

		XCTAssertIdentical(transformer.transformedValue(fileNode) as? NSImage, fileIcon)
		XCTAssertEqual(provider.requestedURLs, [fileURL])

		fileNode.icon = thumbnail
		XCTAssertIdentical(transformer.transformedValue(fileNode) as? NSImage, thumbnail)
		XCTAssertEqual(provider.requestedURLs, [fileURL])

		let packageURL = URL(fileURLWithPath: "/tmp/Project.screenstudio")
		let packageNode = FileTreeNode(
			name: packageURL.lastPathComponent,
			size: 1,
			isDirectory: true,
			dateModified: nil,
			fileURL: packageURL,
			isPackage: true
		)
		XCTAssertIdentical(transformer.transformedValue(packageNode) as? NSImage, fileIcon)
		XCTAssertEqual(provider.requestedURLs, [fileURL, packageURL])

		let archiveNode = FileTreeNode(name: "virtual.txt", size: 1, isDirectory: false)
		XCTAssertNotNil(transformer.transformedValue(archiveNode) as? NSImage)
		XCTAssertEqual(provider.requestedURLs, [fileURL, packageURL])
	}

	func testThumbnailEligibilityAllowsOnlyNativeImageMovieAndPDFNodes() {
		XCTAssertTrue(DirectoryThumbnailLoader.isEligible(node(type: .png, path: "image.png")))
		XCTAssertTrue(
			DirectoryThumbnailLoader.isEligible(node(type: .mpeg4Movie, path: "movie.mp4"))
		)
		XCTAssertTrue(DirectoryThumbnailLoader.isEligible(node(type: .pdf, path: "document.pdf")))
		XCTAssertFalse(
			DirectoryThumbnailLoader.isEligible(node(type: .plainText, path: "notes.txt"))
		)
		XCTAssertFalse(
			DirectoryThumbnailLoader.isEligible(
				node(type: .png, path: "image.png", isDirectory: true)
			)
		)
		XCTAssertFalse(
			DirectoryThumbnailLoader.isEligible(node(
				type: .png,
				path: "Bundle.app",
				isPackage: true
			))
		)
		XCTAssertFalse(
			DirectoryThumbnailLoader.isEligible(
				node(type: .png, path: "image.png", isSymbolicLink: true)
			)
		)
		XCTAssertFalse(
			DirectoryThumbnailLoader.isEligible(node(type: .png, path: "README.md"))
		)
	}

	func testThumbnailLoaderBoundsConcurrencyCachesAndIgnoresCancelledCallbacks() {
		let generator = ControllableThumbnailGenerator()
		let loader = DirectoryThumbnailLoader(generator: generator, maxConcurrentRequests: 2)
		let nodes = (0 ..< 4).map { node(type: .png, path: "image-\($0).png") }
		var updatedNodes = [FileTreeNode]()

		for node in nodes {
			loader.requestThumbnail(for: node, scale: 2) { updatedNodes.append($0) }
		}
		XCTAssertEqual(generator.outstandingRequests.count, 2)
		XCTAssertEqual(
			generator.requestedSizes,
			[.init(width: 32, height: 32), .init(width: 32, height: 32)]
		)

		let firstImage = NSImage(size: NSSize(width: 32, height: 32))
		generator.completeFirst(with: firstImage)
		XCTAssertEqual(generator.outstandingRequests.count, 2)
		XCTAssertIdentical(nodes[0].icon, firstImage)
		XCTAssertEqual(updatedNodes.count, 1)

		loader.requestThumbnail(for: nodes[0], scale: 2) { updatedNodes.append($0) }
		XCTAssertEqual(generator.generatedURLs.count, 3)
		XCTAssertEqual(updatedNodes.count, 2)

		let activeTokens = Set(generator.outstandingRequests.map(\.token))
		loader.cancelAll()
		XCTAssertEqual(Set(generator.cancelledTokens), activeTokens)
		generator.completeAll(with: NSImage(size: NSSize(width: 32, height: 32)))
		XCTAssertNil(nodes[1].icon)
		XCTAssertNil(nodes[2].icon)
		XCTAssertNil(nodes[3].icon)
	}

	func testThumbnailLoaderDoesNotRetryFailedURLsDuringTheSamePreview() {
		let generator = ControllableThumbnailGenerator()
		let loader = DirectoryThumbnailLoader(generator: generator)
		let imageNode = node(type: .png, path: "missing-thumbnail.png")

		loader.requestThumbnail(for: imageNode, scale: 2) { _ in
			XCTFail("A failed thumbnail must not produce an update")
		}
		generator.completeFirst(with: nil)
		loader.requestThumbnail(for: imageNode, scale: 2) { _ in
			XCTFail("A failed URL must not be retried")
		}

		XCTAssertEqual(generator.generatedURLs.count, 1)
		XCTAssertEqual(generator.generatedURLs.first, imageNode.fileURL)
	}

	func testLateCancelledCallbackDoesNotReplaceAReissuedRequestForTheSameURL() {
		let generator = ControllableThumbnailGenerator()
		let loader = DirectoryThumbnailLoader(generator: generator)
		let imageNode = node(type: .png, path: "reissued.png")
		var updatedNodes = [FileTreeNode]()

		loader.requestThumbnail(for: imageNode, scale: 2) { updatedNodes.append($0) }
		loader.cancelAll()
		loader.requestThumbnail(for: imageNode, scale: 2) { updatedNodes.append($0) }
		XCTAssertEqual(generator.outstandingRequests.count, 2)

		let staleImage = NSImage(size: NSSize(width: 16, height: 16))
		generator.completeFirst(with: staleImage)
		XCTAssertNil(imageNode.icon)
		XCTAssertTrue(updatedNodes.isEmpty)
		XCTAssertEqual(generator.outstandingRequests.count, 1)

		let currentImage = NSImage(size: NSSize(width: 32, height: 32))
		generator.completeFirst(with: currentImage)
		XCTAssertIdentical(imageNode.icon, currentImage)
		XCTAssertEqual(updatedNodes.count, 1)
	}

	func testOutlineRequestsThumbnailsOnlyForVisibleRows() {
		let generator = ControllableThumbnailGenerator()
		let loader = DirectoryThumbnailLoader(generator: generator, maxConcurrentRequests: 4)
		let nodes = (0 ..< 100).map { node(type: .png, path: "image-\($0).png") }
		let previewVC = OutlinePreviewVC(
			nibName: NSNib.Name("OutlinePreviewVC"),
			bundle: OutlinePreviewVC.resourceBundle,
			rootNodes: nodes,
			labelText: nil,
			expandAll: true,
			showsFileThumbnails: true,
			thumbnailLoader: loader
		)

		previewVC.loadViewIfNeeded()
		previewVC.view.layoutSubtreeIfNeeded()
		while !generator.outstandingRequests.isEmpty {
			generator.completeFirst(with: NSImage(size: NSSize(width: 32, height: 32)))
		}

		XCTAssertGreaterThan(generator.generatedURLs.count, 0)
		XCTAssertLessThan(generator.generatedURLs.count, nodes.count)
	}

	func testFolderIconGeometryAndExpansionStayStableAcrossSorting() async throws {
		let child = node(type: .plainText, path: "Folder/child.txt")
		let folder = node(type: .folder, path: "Folder", isDirectory: true)
		folder.children = [child.name: child]
		let collapsedChild = node(type: .plainText, path: "Collapsed/child.txt")
		let collapsedFolder = node(type: .folder, path: "Collapsed", isDirectory: true)
		collapsedFolder.children = [collapsedChild.name: collapsedChild]
		let previewVC = OutlinePreviewVC(
			rootNodes: [
				folder,
				collapsedFolder,
				node(type: .png, path: "image.png"),
				node(type: .plainText, path: "notes.txt"),
			],
			labelText: "4 items",
			expandAll: true,
			showsFileThumbnails: true
		)
		previewVC.loadViewIfNeeded()
		previewVC.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
		previewVC.view.layoutSubtreeIfNeeded()
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))
		let scrollView = try XCTUnwrap(outlineView.enclosingScrollView)
		XCTAssertFalse(scrollView.drawsBackground)
		XCTAssertFalse(scrollView.contentView.drawsBackground)
		XCTAssertEqual(outlineView.backgroundColor, .clear)
		let initialCollapsedItem = try outlineItem(for: collapsedFolder, in: outlineView)
		outlineView.collapseItem(initialCollapsedItem)

		try assertFolderCellGeometry(in: outlineView)
		for sortDescriptor in [
			NSSortDescriptor(key: "name", ascending: false),
			NSSortDescriptor(key: "dateModified", ascending: true),
			NSSortDescriptor(key: "size", ascending: false),
		] {
			previewVC.customSortDescriptors = [sortDescriptor]
			await Task.yield()
			await Task.yield()
			previewVC.view.layoutSubtreeIfNeeded()
			try assertFolderCellGeometry(in: outlineView)
			XCTAssertTrue(outlineView.isItemExpanded(try outlineItem(for: folder, in: outlineView)))
			XCTAssertFalse(
				outlineView.isItemExpanded(try outlineItem(for: collapsedFolder, in: outlineView))
			)
		}

		let folderItem = try outlineItem(for: folder, in: outlineView)
		outlineView.collapseItem(folderItem)
		outlineView.expandItem(folderItem)
		previewVC.view.layoutSubtreeIfNeeded()
		try assertFolderCellGeometry(in: outlineView)
	}

	private func outlineItem(
		for node: FileTreeNode,
		in outlineView: NSOutlineView
	) throws -> Any {
		let row = try XCTUnwrap((0 ..< outlineView.numberOfRows).first { row in
			let treeNode = outlineView.item(atRow: row) as? NSTreeNode
			return (treeNode?.representedObject as? FileTreeNode) === node
		})
		return try XCTUnwrap(outlineView.item(atRow: row))
	}

	private func assertFolderCellGeometry(in outlineView: NSOutlineView) throws {
		for row in 0 ..< outlineView.numberOfRows {
			let cellView = try XCTUnwrap(
				outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
			)
			let imageView = try XCTUnwrap(cellView.imageView)
			let textField = try XCTUnwrap(cellView.textField)
			cellView.layoutSubtreeIfNeeded()
			XCTAssertEqual(imageView.frame.size, NSSize(width: 24, height: 24))
			XCTAssertEqual(textField.frame.minX - imageView.frame.maxX, 4, accuracy: 0.5)
		}
	}

	private func firstSubview<View: NSView>(of _: View.Type, in view: NSView) -> View? {
		if let matchingView = view as? View {
			return matchingView
		}
		return view.subviews.lazy.compactMap { self.firstSubview(of: View.self, in: $0) }.first
	}

	private func node(
		type: UTType,
		path: String,
		isDirectory: Bool = false,
		isPackage: Bool = false,
		isSymbolicLink: Bool = false
	) -> FileTreeNode {
		FileTreeNode(
			name: URL(fileURLWithPath: path).lastPathComponent,
			size: 1,
			isDirectory: isDirectory,
			dateModified: nil,
			fileURL: URL(fileURLWithPath: "/tmp").appendingPathComponent(path),
			isPackage: isPackage,
			isSymbolicLink: isSymbolicLink,
			contentTypeIdentifier: type.identifier
		)
	}
}

private final class RecordingFileIconProvider: FileIconProviding {
	let icon: NSImage
	private(set) var requestedURLs = [URL]()

	init(icon: NSImage) {
		self.icon = icon
	}

	func icon(for fileURL: URL) -> NSImage {
		requestedURLs.append(fileURL)
		return icon
	}
}

@MainActor
private final class ControllableThumbnailGenerator: DirectoryThumbnailGenerating {
	struct Request {
		let token: DirectoryThumbnailToken
		let fileURL: URL
		let completion: @MainActor @Sendable (NSImage?) -> Void
	}

	private(set) var outstandingRequests = [Request]()
	private(set) var generatedURLs = [URL]()
	private(set) var requestedSizes = [CGSize]()
	private(set) var cancelledTokens = [DirectoryThumbnailToken]()

	func generateThumbnail(
		for fileURL: URL,
		size: CGSize,
		scale _: CGFloat,
		completion: @escaping @MainActor @Sendable (NSImage?) -> Void
	) -> DirectoryThumbnailToken {
		let token = DirectoryThumbnailToken()
		generatedURLs.append(fileURL)
		requestedSizes.append(size)
		outstandingRequests.append(
			Request(token: token, fileURL: fileURL, completion: completion)
		)
		return token
	}

	func cancel(_ token: DirectoryThumbnailToken) {
		cancelledTokens.append(token)
	}

	func completeFirst(with image: NSImage?) {
		guard !outstandingRequests.isEmpty else {
			return
		}
		let request = outstandingRequests.removeFirst()
		request.completion(image)
	}

	func completeAll(with image: NSImage?) {
		let requests = outstandingRequests
		outstandingRequests.removeAll()
		for request in requests {
			request.completion(image)
		}
	}
}
