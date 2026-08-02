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

	func testPreviewBuildsNestedTreeWithMetadataAndExpandsAllRows() throws {
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

		let previewVC = try makePreview(for: rootURL)
		let visibleNode = try XCTUnwrap(node(named: "visible.txt", in: previewVC.rootNodes))
		let nestedNode = try XCTUnwrap(
			node(named: nestedURL.lastPathComponent, in: previewVC.rootNodes)
		)

		XCTAssertEqual(visibleNode.size, 5)
		XCTAssertEqual(
			try XCTUnwrap(visibleNode.dateModified).timeIntervalSince1970,
			modificationDate.timeIntervalSince1970,
			accuracy: 1
		)
		XCTAssertNotNil(node(named: "child.txt", in: nestedNode.childrenList))
		XCTAssertNil(node(named: ".hidden.txt", in: previewVC.rootNodes))
		XCTAssertNil(node(named: ".hidden-folder", in: previewVC.rootNodes))

		previewVC.loadViewIfNeeded()
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))
		XCTAssertEqual(outlineView.numberOfRows, 3)
	}

	func testPreviewUsesDeterministicItemLimitAndTruncationLabel() throws {
		let rootURL = try makeDirectory(named: "limited")
		_ = try writeFile(named: "limited/c.txt", contents: "c")
		_ = try writeFile(named: "limited/a.txt", contents: "a")
		_ = try writeFile(named: "limited/b.txt", contents: "b")

		let previewVC = try makePreview(for: rootURL, maxItemCount: 2)

		XCTAssertEqual(Set(previewVC.rootNodes.map(\.name)), Set(["a.txt", "b.txt"]))
		previewVC.loadViewIfNeeded()
		XCTAssertEqual(previewVC.previewStatusText, "2+ items")
	}

	func testPreviewStopsAtConfiguredDepth() throws {
		let rootURL = try makeDirectory(named: "depth")
		_ = try makeDirectory(named: "depth/level-1/level-2")
		_ = try writeFile(named: "depth/level-1/level-2/level-3.txt", contents: "deep")

		let previewVC = try makePreview(for: rootURL, maxDepth: 2)

		XCTAssertNotNil(node(named: "level-1", in: previewVC.rootNodes))
		XCTAssertNotNil(node(named: "level-2", in: previewVC.rootNodes))
		XCTAssertNil(node(named: "level-3.txt", in: previewVC.rootNodes))
	}

	func testPreviewDoesNotRecurseIntoSymbolicLinksOrPackages() throws {
		let rootURL = try makeDirectory(named: "boundaries")
		let packageURL = try makeDirectory(named: "boundaries/Sample.app/Contents")
		_ = try writeFile(
			named: "boundaries/Sample.app/Contents/inside.txt",
			contents: "inside"
		)
		let loopURL = rootURL.appendingPathComponent("loop", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: loopURL, withDestinationURL: rootURL)

		let previewVC = try makePreview(for: rootURL)
		let packageNode = try XCTUnwrap(node(named: "Sample.app", in: previewVC.rootNodes))
		let loopNode = try XCTUnwrap(node(named: "loop", in: previewVC.rootNodes))

		XCTAssertEqual(packageURL.lastPathComponent, "Contents")
		XCTAssertTrue(packageNode.childrenList.isEmpty)
		XCTAssertTrue(loopNode.childrenList.isEmpty)
		XCTAssertNil(node(named: "inside.txt", in: previewVC.rootNodes))
	}

	func testDefaultPreviewDeclinesTemporaryDirectories() throws {
		let rootURL = try makeDirectory(named: "temporary")

		XCTAssertThrowsError(
			try DirectoryPreview().createPreviewVC(file: File(url: rootURL))
		) { error in
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
		maxItemCount: Int = DirectoryPreview.defaultMaxItemCount,
		maxDepth: Int = DirectoryPreview.defaultMaxDepth
	) throws -> OutlinePreviewVC {
		try XCTUnwrap(
			DirectoryPreview(
				fileManager: .default,
				maxItemCount: maxItemCount,
				maxDepth: maxDepth,
				excludedRootURLs: []
			).createPreviewVC(file: File(url: directoryURL)) as? OutlinePreviewVC
		)
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

	private func node(named name: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
		for node in nodes {
			if node.name == name {
				return node
			}
			if let childNode = self.node(named: name, in: node.childrenList) {
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
}
