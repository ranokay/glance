import Cocoa
import XCTest

@MainActor
final class DirectoryPreviewTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlanceDirectoryTests-\(UUID().uuidString)", isDirectory: true)
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

	func testInitialPreviewLoadsOnlyDirectVisibleChildrenThenExpansionLoadsOneLevel() async throws {
		let rootURL = try makeDirectory(named: "root")
		let nestedURL = try makeDirectory(named: "root/nested")
		let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
		let visibleURL = try writeFile(named: "root/visible.txt", contents: "hello")
		_ = try writeFile(named: "root/nested/child.txt", contents: "child")
		_ = try writeFile(named: "root/.hidden.txt", contents: "hidden")
		_ = try makeDirectory(named: "root/.hidden-folder")
		try FileManager.default.setAttributes(
			[.modificationDate: modificationDate],
			ofItemAtPath: visibleURL.path
		)

		let previewVC = try await makePreview(for: rootURL)
		let visibleNode = try XCTUnwrap(itemNode(named: "visible.txt", in: previewVC.rootNodes))
		let nestedNode = try XCTUnwrap(itemNode(
			named: nestedURL.lastPathComponent,
			in: previewVC.rootNodes
		))

		XCTAssertEqual(visibleNode.size, 5)
		XCTAssertEqual(
			try XCTUnwrap(visibleNode.dateModified).timeIntervalSince1970,
			modificationDate.timeIntervalSince1970,
			accuracy: 1
		)
		XCTAssertTrue(nestedNode.childrenList.isEmpty)
		XCTAssertEqual(nestedNode.directoryChildrenState, .notLoaded)
		XCTAssertNil(itemNode(named: ".hidden.txt", in: previewVC.rootNodes))
		XCTAssertNil(itemNode(named: ".hidden-folder", in: previewVC.rootNodes))

		let outlineView = try loadOutlineView(for: previewVC)
		XCTAssertEqual(outlineView.numberOfRows, 2)
		try expand(nestedNode, in: outlineView)
		try await waitUntil { nestedNode.directoryChildrenState == .loaded(nextOffset: nil) }

		XCTAssertNotNil(itemNode(named: "child.txt", in: nestedNode.childrenList))
		XCTAssertEqual(outlineView.numberOfRows, 3)
	}

	func testLargeFirstSubfolderCannotHideRootSiblings() async throws {
		let rootURL = try makeDirectory(named: "siblings")
		_ = try makeDirectory(named: "siblings/a-large")
		_ = try makeDirectory(named: "siblings/b-visible")
		for index in 0 ..< 501 {
			_ = try writeFile(
				named: "siblings/a-large/item-\(index).txt",
				contents: "\(index)"
			)
		}

		let previewVC = try await makePreview(for: rootURL)

		XCTAssertNotNil(itemNode(named: "a-large", in: previewVC.rootNodes))
		XCTAssertNotNil(itemNode(named: "b-visible", in: previewVC.rootNodes))
		XCTAssertEqual(previewVC.previewStatusText, "2 items")
	}

	func testSingleRootFolderStartsCollapsed() async throws {
		let rootURL = try makeDirectory(named: "collapsed")
		_ = try makeDirectory(named: "collapsed/only-child")
		let previewVC = try await makePreview(for: rootURL)
		let outlineView = try loadOutlineView(for: previewVC)
		let childNode = try XCTUnwrap(itemNode(named: "only-child", in: previewVC.rootNodes))
		let childRow = try XCTUnwrap(row(for: childNode, in: outlineView))
		let childItem = try XCTUnwrap(outlineView.item(atRow: childRow))

		XCTAssertFalse(outlineView.isItemExpanded(childItem))
		XCTAssertEqual(outlineView.selectedRow, -1)
		XCTAssertEqual(childNode.directoryChildrenState, .notLoaded)
	}

	func testDirectoryPagesExposeEveryItemInDeterministicBatches() async throws {
		let rootURL = try makeDirectory(named: "paged")
		for index in 0 ..< 1001 {
			_ = try writeFile(
				named: "paged/item-\(String(format: "%04d", index)).txt",
				contents: "x"
			)
		}

		let previewVC = try await makePreview(for: rootURL, pageSize: 500)
		let outlineView = try loadOutlineView(for: previewVC)

		XCTAssertEqual(previewVC.rootNodes.count { $0.role == .item }, 500)
		XCTAssertEqual(previewVC.previewStatusText, "500+ items")
		try activateLoadMore(in: previewVC, outlineView: outlineView)
		try await waitUntil { previewVC.rootNodes.count { $0.role == .item } == 1000 }
		XCTAssertEqual(previewVC.previewStatusText, "1000+ items")

		try activateLoadMore(in: previewVC, outlineView: outlineView)
		try await waitUntil { previewVC.rootNodes.count { $0.role == .item } == 1001 }
		XCTAssertEqual(previewVC.previewStatusText, "1001 items")
		XCTAssertNil(previewVC.rootNodes
			.first { if case .loadMore = $0.role { true } else { false } })
	}

	func testNestedPageFailureShowsRetryAndCanRecover() async throws {
		let rootURL = try makeDirectory(named: "retry-root")
		let childURL = try makeDirectory(named: "retry-root/child")
		let loader = RetryingDirectoryLoader(rootURL: rootURL, childURL: childURL)
		let generatedPreview = try await DirectoryPreview(pageLoader: loader)
			.createPreviewVC(file: File(url: rootURL))
		let previewVC = try XCTUnwrap(generatedPreview as? OutlinePreviewVC)
		let childNode = try XCTUnwrap(itemNode(named: "child", in: previewVC.rootNodes))
		let outlineView = try loadOutlineView(for: previewVC)

		try expand(childNode, in: outlineView)
		try await waitUntil { childNode.directoryChildrenState == .failed }
		let retryNode = try XCTUnwrap(childNode.childrenList.first {
			if case .retry = $0.role { true } else { false }
		})
		let retryRow = try XCTUnwrap(row(for: retryNode, in: outlineView))
		outlineView.selectRowIndexes(IndexSet(integer: retryRow), byExtendingSelection: false)
		XCTAssertTrue(previewVC.activateOutlineSelection())
		try await waitUntil { childNode.directoryChildrenState == .loaded(nextOffset: nil) }

		XCTAssertNotNil(itemNode(named: "recovered.txt", in: childNode.childrenList))
	}

	func testDirectoryLoadingIsCancelledWhenPreviewIsTornDown() async throws {
		let rootURL = try makeDirectory(named: "cancel-root")
		let childURL = try makeDirectory(named: "cancel-root/child")
		let loader = CancellableDirectoryLoader(rootURL: rootURL, childURL: childURL)
		let generatedPreview = try await DirectoryPreview(pageLoader: loader)
			.createPreviewVC(file: File(url: rootURL))
		let previewVC = try XCTUnwrap(generatedPreview as? OutlinePreviewVC)
		let childNode = try XCTUnwrap(itemNode(named: "child", in: previewVC.rootNodes))
		let outlineView = try loadOutlineView(for: previewVC)

		let childRow = try XCTUnwrap(row(for: childNode, in: outlineView))
		let childItem = try XCTUnwrap(outlineView.item(atRow: childRow))
		XCTAssertTrue(previewVC.outlineView(outlineView, shouldExpandItem: childItem))
		try await waitUntil { await loader.childLoadStarted }
		previewVC.tearDown()
		try await waitUntil { await loader.childLoadWasCancelled }
	}

	func testPreviewDoesNotTraverseSymbolicLinksOrPackages() async throws {
		let rootURL = try makeDirectory(named: "boundaries")
		_ = try makeDirectory(named: "boundaries/Sample.app/Contents")
		_ = try writeFile(named: "boundaries/Sample.app/Contents/inside.txt", contents: "inside")
		let loopURL = rootURL.appendingPathComponent("loop", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: loopURL, withDestinationURL: rootURL)

		let previewVC = try await makePreview(for: rootURL)
		let packageNode = try XCTUnwrap(itemNode(named: "Sample.app", in: previewVC.rootNodes))
		let loopNode = try XCTUnwrap(itemNode(named: "loop", in: previewVC.rootNodes))

		XCTAssertTrue(packageNode.isLeaf)
		XCTAssertTrue(loopNode.isLeaf)
		XCTAssertTrue(packageNode.childrenList.isEmpty)
		XCTAssertTrue(loopNode.childrenList.isEmpty)
	}

	func testDefaultPreviewDeclinesTemporaryDirectories() async throws {
		let rootURL = try makeDirectory(named: "temporary")

		do {
			_ = try await DirectoryPreview().createPreviewVC(file: File(url: rootURL))
			XCTFail("Expected temporary directories to be declined")
		} catch {
			guard let directoryError = error as? DirectoryPreviewError else {
				return XCTFail("Unexpected error: \(error)")
			}
			guard case .temporaryDirectory = directoryError else {
				return XCTFail("Unexpected directory error: \(directoryError)")
			}
		}
	}

	private func makePreview(
		for directoryURL: URL,
		pageSize: Int = DirectoryPreview.defaultPageSize
	) async throws -> OutlinePreviewVC {
		let generatedPreview = try await DirectoryPreview(
			fileManager: .default,
			maxItemCount: pageSize,
			maxDepth: DirectoryPreview.defaultMaxDepth,
			excludedRootURLs: []
		).createPreviewVC(file: File(url: directoryURL))
		return try XCTUnwrap(generatedPreview as? OutlinePreviewVC)
	}

	private func activateLoadMore(
		in previewVC: OutlinePreviewVC,
		outlineView: NSOutlineView
	) throws {
		let loadMoreRow = try XCTUnwrap((0 ..< outlineView.numberOfRows).first { row in
			guard let node = representedNode(at: row, in: outlineView) else {
				return false
			}
			if case .loadMore = node.role {
				return true
			}
			return false
		})
		outlineView.selectRowIndexes(IndexSet(integer: loadMoreRow), byExtendingSelection: false)
		XCTAssertTrue(previewVC.activateOutlineSelection())
	}

	private func expand(_ node: FileTreeNode, in outlineView: NSOutlineView) throws {
		let nodeRow = try XCTUnwrap(row(for: node, in: outlineView))
		let item = try XCTUnwrap(outlineView.item(atRow: nodeRow))
		outlineView.expandItem(item)
	}

	private func row(for node: FileTreeNode, in outlineView: NSOutlineView) -> Int? {
		(0 ..< outlineView.numberOfRows).first {
			representedNode(at: $0, in: outlineView) === node
		}
	}

	private func representedNode(at row: Int, in outlineView: NSOutlineView) -> FileTreeNode? {
		(outlineView.item(atRow: row) as? NSTreeNode)?.representedObject as? FileTreeNode
	}

	private func loadOutlineView(for previewVC: OutlinePreviewVC) throws -> NSOutlineView {
		previewVC.loadViewIfNeeded()
		previewVC.view.layoutSubtreeIfNeeded()
		return try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))
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

	private func itemNode(named name: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
		for node in nodes where node.role == .item {
			if node.name == name {
				return node
			}
			if let childNode = itemNode(named: name, in: node.childrenList) {
				return childNode
			}
		}
		return nil
	}

	private func firstSubview<View: NSView>(of _: View.Type, in view: NSView) -> View? {
		if let matchingView = view as? View {
			return matchingView
		}
		return view.subviews.lazy.compactMap { self.firstSubview(of: View.self, in: $0) }.first
	}

	private func waitUntil(
		timeout: Duration = .seconds(3),
		condition: @escaping @MainActor () async -> Bool
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while await !condition() {
			guard clock.now < deadline else {
				throw DirectoryTestError.timedOut
			}
			try await Task.sleep(for: .milliseconds(5))
		}
	}
}

private actor RetryingDirectoryLoader: DirectoryPageLoading {
	let rootURL: URL
	let childURL: URL
	private var childAttempts = 0

	init(rootURL: URL, childURL: URL) {
		self.rootURL = rootURL
		self.childURL = childURL
	}

	func page(at directoryURL: URL, offset _: Int) async throws -> DirectoryPage {
		if directoryURL == rootURL {
			return DirectoryPage(
				entries: [.directory(named: "child", url: childURL)],
				nextOffset: nil,
				totalItemCount: 1
			)
		}
		childAttempts += 1
		guard childAttempts > 1 else {
			throw DirectoryTestError.expectedFailure
		}
		return DirectoryPage(
			entries: [
				.file(
					named: "recovered.txt",
					url: childURL.appendingPathComponent("recovered.txt")
				),
			],
			nextOffset: nil,
			totalItemCount: 1
		)
	}
}

private actor CancellableDirectoryLoader: DirectoryPageLoading {
	let rootURL: URL
	let childURL: URL
	private(set) var childLoadStarted = false
	private(set) var childLoadWasCancelled = false

	init(rootURL: URL, childURL: URL) {
		self.rootURL = rootURL
		self.childURL = childURL
	}

	func page(at directoryURL: URL, offset _: Int) async throws -> DirectoryPage {
		if directoryURL == rootURL {
			return DirectoryPage(
				entries: [.directory(named: "child", url: childURL)],
				nextOffset: nil,
				totalItemCount: 1
			)
		}
		childLoadStarted = true
		return try await withTaskCancellationHandler {
			try await Task.sleep(for: .seconds(30))
			return DirectoryPage(entries: [], nextOffset: nil, totalItemCount: 0)
		} onCancel: {
			Task {
				await self.recordCancellation()
			}
		}
	}

	private func recordCancellation() {
		childLoadWasCancelled = true
	}
}

extension DirectoryPreviewEntry {
	static func directory(named name: String, url: URL) -> DirectoryPreviewEntry {
		DirectoryPreviewEntry(
			name: name,
			isDirectory: true,
			size: 0,
			dateModified: nil,
			fileURL: url,
			isPackage: false,
			isSymbolicLink: false,
			contentTypeIdentifier: nil
		)
	}

	static func file(named name: String, url: URL) -> DirectoryPreviewEntry {
		DirectoryPreviewEntry(
			name: name,
			isDirectory: false,
			size: 1,
			dateModified: nil,
			fileURL: url,
			isPackage: false,
			isSymbolicLink: false,
			contentTypeIdentifier: nil
		)
	}
}

private enum DirectoryTestError: Error {
	case expectedFailure
	case timedOut
}
