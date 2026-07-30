import Cocoa
import UniformTypeIdentifiers
import XCTest

@MainActor
final class NestedPreviewTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlanceNestedTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: temporaryDirectory,
			withIntermediateDirectories: true
		)
	}

	override func tearDownWithError() throws {
		if let temporaryDirectory {
			try? FileManager.default.removeItem(at: temporaryDirectory)
		}
		try super.tearDownWithError()
	}

	func testProviderRoutesSupportedTextAndArchivesToGlanceAndMediaAndPackagesToNative() {
		let provider = DefaultNestedPreviewProvider()

		assertGlanceRoute(
			provider.route(for: node(named: "README.md", type: .plainText)),
			expected: MarkdownPreview.self
		)
		assertGlanceRoute(
			provider.route(for: node(named: "source.swift", type: .sourceCode)),
			expected: CodePreview.self
		)
		assertGlanceRoute(
			provider.route(for: node(named: "archive.zip", type: .zip)),
			expected: ZIPPreview.self
		)
		assertNativeRoute(provider.route(for: node(named: "image.png", type: .png)))
		assertNativeRoute(provider.route(for: node(named: "unknown.bin", type: .data)))
		assertNativeRoute(provider.route(for: node(
			named: "Project.screenstudio",
			type: .package,
			isDirectory: true,
			isPackage: true
		)))
	}

	func testProviderBuildsSupportedAndNativeControllers() throws {
		let markdownURL = try writeFile(named: "README.md", contents: "# Nested")
		let imageURL = try writeFile(named: "image.png", contents: "")
		let provider = DefaultNestedPreviewProvider()
		let markdownNode = node(named: markdownURL.lastPathComponent, type: .plainText)
		markdownNode.fileURL = markdownURL
		let imageNode = node(named: imageURL.lastPathComponent, type: .png)
		imageNode.fileURL = imageURL

		XCTAssertTrue(try provider.makePreviewController(for: markdownNode) is WebPreviewVC)
		let nativePreview = try XCTUnwrap(
			provider.makePreviewController(for: imageNode) as? NativePreviewVC
		)
		XCTAssertEqual(nativePreview.fileURL, imageURL)
	}

	func testOutlineSelectionTogglesDirectoriesPreviewsPackagesAndIgnoresSymlinks() throws {
		let child = node(named: "child.txt", type: .plainText)
		let directory = node(named: "Folder", type: .folder, isDirectory: true)
		directory.children = [child.name: child]
		let package = node(
			named: "Project.screenstudio",
			type: .package,
			isDirectory: true,
			isPackage: true
		)
		let symlink = node(named: "link.txt", type: .symbolicLink, isSymbolicLink: true)
		let interactionDelegate = RecordingOutlineInteractionDelegate()
		let previewVC = makeOutline(rootNodes: [directory, package, symlink])
		previewVC.interactionDelegate = interactionDelegate
		previewVC.loadViewIfNeeded()
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))

		let directoryRow = try XCTUnwrap(row(named: directory.name, in: outlineView))
		outlineView.selectRowIndexes(IndexSet(integer: directoryRow), byExtendingSelection: false)
		XCTAssertIdentical(interactionDelegate.selectedNode, directory)
		let directoryItem = try XCTUnwrap(outlineView.item(atRow: directoryRow))
		XCTAssertTrue(outlineView.isItemExpanded(directoryItem))
		XCTAssertTrue(previewVC.activateOutlineSelection())
		XCTAssertFalse(outlineView.isItemExpanded(directoryItem))

		let packageRow = try XCTUnwrap(row(named: package.name, in: outlineView))
		outlineView.selectRowIndexes(IndexSet(integer: packageRow), byExtendingSelection: false)
		XCTAssertTrue(previewVC.activateOutlineSelection())
		XCTAssertIdentical(interactionDelegate.previewedNode, package)

		let symlinkRow = try XCTUnwrap(row(named: symlink.name, in: outlineView))
		outlineView.selectRowIndexes(IndexSet(integer: symlinkRow), byExtendingSelection: false)
		XCTAssertFalse(previewVC.activateOutlineSelection())
		XCTAssertIdentical(interactionDelegate.previewedNode, package)
	}

	func testBackRestoresTheRetainedFolderControllerAndItsState() throws {
		let folderURL = try makeDirectory(named: "folder")
		let fileURL = try writeFile(named: "folder/file.txt", contents: "nested")
		let fileNode = node(named: fileURL.lastPathComponent, type: .plainText)
		fileNode.fileURL = fileURL
		let folderNode = node(named: "Nested", type: .folder, isDirectory: true)
		folderNode.children = [fileNode.name: fileNode]
		for index in 0 ..< 40 {
			let fillerNode = node(named: "file-\(index).txt", type: .plainText)
			folderNode.children[fillerNode.name] = fillerNode
		}
		let previewVC = makeOutline(rootNodes: [folderNode])
		let nestedController = StubPreviewVC()
		let provider = StubNestedPreviewProvider(result: .success(nestedController))
		let mainVC = MainVC()
		mainVC.nestedPreviewProvider = provider
		mainVC.loadViewIfNeeded()
		mainVC.installTopLevelPreview(previewVC, file: try File(url: folderURL))
		previewVC.applySearchQuery("file")
		previewVC.customSortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))
		let fileRow = try XCTUnwrap(row(named: fileNode.name, in: outlineView))
		outlineView.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
		let retainedSelection = previewVC.selectedNode
		let retainedFolderItem = try XCTUnwrap(outlineView.item(atRow: 0))
		XCTAssertTrue(outlineView.isItemExpanded(retainedFolderItem))
		let clipView = try XCTUnwrap(outlineView.enclosingScrollView?.contentView)
		clipView.scroll(to: NSPoint(x: 0, y: 140))
		outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
		let retainedScrollOrigin = clipView.bounds.origin

		mainVC.outlinePreview(previewVC, requestPreviewOf: try XCTUnwrap(retainedSelection))

		XCTAssertIdentical(mainVC.currentPreviewController, nestedController)
		XCTAssertFalse(mainVC.backButton.isHidden)
		XCTAssertTrue(previewVC.view.isHidden)

		mainVC.showFolderPreview()

		XCTAssertIdentical(mainVC.currentPreviewController, previewVC)
		XCTAssertIdentical(mainVC.folderPreviewController, previewVC)
		XCTAssertEqual(previewVC.currentSearchQuery, "file")
		XCTAssertIdentical(previewVC.selectedNode, retainedSelection)
		XCTAssertFalse(previewVC.customSortDescriptors[0].ascending)
		XCTAssertTrue(outlineView.isItemExpanded(retainedFolderItem))
		XCTAssertEqual(clipView.bounds.origin, retainedScrollOrigin)
		XCTAssertFalse(previewVC.view.isHidden)
		XCTAssertTrue(mainVC.backButton.isHidden)
	}

	func testFailedNestedPreviewLeavesFolderVisibleAndShowsNonmodalError() throws {
		let folderURL = try makeDirectory(named: "failure-folder")
		let fileURL = try writeFile(named: "failure-folder/file.bin", contents: "data")
		let fileNode = node(named: fileURL.lastPathComponent, type: .data)
		fileNode.fileURL = fileURL
		let previewVC = makeOutline(rootNodes: [fileNode])
		let mainVC = MainVC()
		mainVC.nestedPreviewProvider = StubNestedPreviewProvider(
			result: .failure(TestNestedPreviewError.failed)
		)
		mainVC.loadViewIfNeeded()
		mainVC.installTopLevelPreview(previewVC, file: try File(url: folderURL))

		mainVC.outlinePreview(previewVC, requestPreviewOf: fileNode)

		XCTAssertIdentical(mainVC.currentPreviewController, previewVC)
		XCTAssertNil(mainVC.nestedPreviewController)
		XCTAssertFalse(previewVC.view.isHidden)
		XCTAssertTrue(mainVC.backButton.isHidden)
		XCTAssertEqual(mainVC.statusLabel.stringValue, "Couldn’t preview file.bin")
	}

	private func node(
		named name: String,
		type: UTType,
		isDirectory: Bool = false,
		isPackage: Bool = false,
		isSymbolicLink: Bool = false
	) -> FileTreeNode {
		FileTreeNode(
			name: name,
			size: 1,
			isDirectory: isDirectory,
			dateModified: nil,
			fileURL: temporaryDirectory.appendingPathComponent(name),
			isPackage: isPackage,
			isSymbolicLink: isSymbolicLink,
			contentTypeIdentifier: type.identifier
		)
	}

	private func makeOutline(rootNodes: [FileTreeNode]) -> OutlinePreviewVC {
		OutlinePreviewVC(
			nibName: NSNib.Name("OutlinePreviewVC"),
			bundle: OutlinePreviewVC.resourceBundle,
			rootNodes: rootNodes,
			labelText: "\(rootNodes.count) items",
			expandAll: true,
			showsFileThumbnails: true,
			searchEnabled: true
		)
	}

	private func assertGlanceRoute(
		_ route: NestedPreviewRoute,
		expected: Preview.Type,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard case let .glance(actual) = route else {
			return XCTFail("Expected Glance route", file: file, line: line)
		}
		XCTAssertEqual(
			ObjectIdentifier(actual),
			ObjectIdentifier(expected),
			file: file,
			line: line
		)
	}

	private func assertNativeRoute(
		_ route: NestedPreviewRoute,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard case .native = route else {
			return XCTFail("Expected native route", file: file, line: line)
		}
	}

	private func row(named name: String, in outlineView: NSOutlineView) -> Int? {
		(0 ..< outlineView.numberOfRows).first { row in
			let treeNode = outlineView.item(atRow: row) as? NSTreeNode
			return (treeNode?.representedObject as? FileTreeNode)?.name == name
		}
	}

	private func firstSubview<View: NSView>(of _: View.Type, in view: NSView) -> View? {
		if let matchingView = view as? View {
			return matchingView
		}
		return view.subviews.lazy.compactMap { self.firstSubview(of: View.self, in: $0) }.first
	}

	private func makeDirectory(named name: String) throws -> URL {
		let directoryURL = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)
		return directoryURL
	}

	private func writeFile(named name: String, contents: String) throws -> URL {
		let fileURL = temporaryDirectory.appendingPathComponent(name)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try contents.write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}
}

@MainActor
private final class RecordingOutlineInteractionDelegate: OutlinePreviewInteractionDelegate {
	private(set) var selectedNode: FileTreeNode?
	private(set) var previewedNode: FileTreeNode?

	func outlinePreview(_: OutlinePreviewVC, didSelect node: FileTreeNode?) {
		selectedNode = node
	}

	func outlinePreview(_: OutlinePreviewVC, requestPreviewOf node: FileTreeNode) {
		previewedNode = node
	}
}

@MainActor
private final class StubNestedPreviewProvider: NestedPreviewProviding {
	let result: Result<PreviewVC, Error>

	init(result: Result<PreviewVC, Error>) {
		self.result = result
	}

	func makePreviewController(for _: FileTreeNode) throws -> PreviewVC {
		try result.get()
	}
}

private final class StubPreviewVC: NSViewController, PreviewVC {}

private enum TestNestedPreviewError: Error {
	case failed
}
