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
