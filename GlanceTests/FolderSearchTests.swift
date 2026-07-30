import Cocoa
import XCTest

@MainActor
final class FolderSearchTests: XCTestCase {
	func testSearchMatchesNestedNamesCaseAndDiacriticInsensitivelyAndRetainsAncestors() throws {
		let matchingURL = URL(fileURLWithPath: "/tmp/Documents/Résumé.PDF")
		let matchingNode = FileTreeNode(
			name: "Résumé.PDF",
			size: 42,
			isDirectory: false,
			dateModified: nil,
			fileURL: matchingURL,
			contentTypeIdentifier: "com.adobe.pdf"
		)
		let unrelatedNode = FileTreeNode(name: "notes.txt", size: 1, isDirectory: false)
		let parentNode = FileTreeNode(name: "Documents", size: 0, isDirectory: true)
		parentNode.children = [matchingNode.name: matchingNode, unrelatedNode.name: unrelatedNode]

		let result = FolderSearch.filter(rootNodes: [parentNode], query: "resume")
		let retainedParent = try XCTUnwrap(result.rootNodes.first)
		let retainedMatch = try XCTUnwrap(retainedParent.children[matchingNode.name])

		XCTAssertEqual(result.matchCount, 1)
		XCTAssertEqual(retainedParent.name, parentNode.name)
		XCTAssertEqual(retainedMatch.fileURL, matchingURL)
		XCTAssertEqual(retainedMatch.contentTypeIdentifier, "com.adobe.pdf")
		XCTAssertNil(retainedParent.children[unrelatedNode.name])
	}

	func testEmptySearchRestoresOriginalNodes() {
		let originalNode = FileTreeNode(name: "original.txt", size: 1, isDirectory: false)

		let result = FolderSearch.filter(rootNodes: [originalNode], query: "   ")

		XCTAssertNil(result.matchCount)
		XCTAssertIdentical(result.rootNodes.first, originalNode)
	}

	func testSearchReportsNoResultsAndTruncationWording() {
		let node = FileTreeNode(name: "notes.txt", size: 1, isDirectory: false)
		let result = FolderSearch.filter(rootNodes: [node], query: "image")

		XCTAssertTrue(result.rootNodes.isEmpty)
		XCTAssertEqual(result.matchCount, 0)
		XCTAssertEqual(FolderSearch.statusText(matchCount: 0, isTruncated: false), "No matches")
		XCTAssertEqual(
			FolderSearch.statusText(matchCount: 3, isTruncated: true),
			"3 matches in first 500 items"
		)
	}

	func testFolderSearchUpdatesRowsAndStatusAndClearsToOriginalTree() throws {
		let matchingNode = FileTreeNode(name: "Résumé.PDF", size: 1, isDirectory: false)
		let unrelatedNode = FileTreeNode(name: "notes.txt", size: 1, isDirectory: false)
		let parentNode = FileTreeNode(name: "Documents", size: 0, isDirectory: true)
		parentNode.children = [matchingNode.name: matchingNode, unrelatedNode.name: unrelatedNode]
		let previewVC = makePreview(
			rootNodes: [parentNode],
			labelText: "500+ items",
			searchEnabled: true,
			searchItemLimitReached: true
		)

		previewVC.loadViewIfNeeded()
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))
		XCTAssertEqual(allSubviews(of: NSSearchField.self, in: previewVC.view).count, 1)

		previewVC.applySearchQuery("resume")
		XCTAssertEqual(outlineView.numberOfRows, 2)
		XCTAssertEqual(previewVC.previewStatusText, "1 match in first 500 items")

		previewVC.applySearchQuery("missing")
		XCTAssertEqual(outlineView.numberOfRows, 0)
		XCTAssertEqual(previewVC.previewStatusText, "No matches")

		previewVC.applySearchQuery("")
		XCTAssertEqual(outlineView.numberOfRows, 3)
		XCTAssertEqual(previewVC.previewStatusText, "500+ items")
	}

	func testArchiveOutlineKeepsExistingLayoutWithoutSearch() throws {
		let archiveNode = FileTreeNode(name: "archive.txt", size: 1, isDirectory: false)
		let previewVC = makePreview(rootNodes: [archiveNode], labelText: "1 file")

		previewVC.loadViewIfNeeded()
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))

		XCTAssertTrue(allSubviews(of: NSSearchField.self, in: previewVC.view).isEmpty)
		XCTAssertNotEqual(outlineView.rowHeight, 28)
		XCTAssertEqual(previewVC.previewStatusText, "1 file")
	}

	func testSearchFocusSelectsFieldAndEscapeClearsItAndReturnsToOutline() throws {
		let node = FileTreeNode(name: "notes.txt", size: 1, isDirectory: false)
		let previewVC = makePreview(
			rootNodes: [node],
			labelText: "1 item",
			searchEnabled: true
		)
		let window = NSWindow(contentViewController: previewVC)
		previewVC.loadViewIfNeeded()
		let searchField = try XCTUnwrap(
			firstSubview(of: NSSearchField.self, in: previewVC.view)
		)
		let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: previewVC.view))

		XCTAssertTrue(previewVC.focusFolderSearch())
		XCTAssertIdentical(window.firstResponder, searchField.currentEditor())

		searchField.stringValue = "notes"
		previewVC.applySearchQuery(searchField.stringValue)
		let handledEscape = previewVC.control(
			searchField,
			textView: try XCTUnwrap(searchField.currentEditor() as? NSTextView),
			doCommandBy: #selector(NSResponder.cancelOperation(_:))
		)

		XCTAssertTrue(handledEscape)
		XCTAssertEqual(searchField.stringValue, "")
		XCTAssertIdentical(window.firstResponder, outlineView)
	}

	private func makePreview(
		rootNodes: [FileTreeNode],
		labelText: String,
		searchEnabled: Bool = false,
		searchItemLimitReached: Bool = false
	) -> OutlinePreviewVC {
		OutlinePreviewVC(
			nibName: NSNib.Name("OutlinePreviewVC"),
			bundle: OutlinePreviewVC.resourceBundle,
			rootNodes: rootNodes,
			labelText: labelText,
			expandAll: true,
			searchEnabled: searchEnabled,
			searchItemLimitReached: searchItemLimitReached
		)
	}

	private func firstSubview<View: NSView>(of _: View.Type, in view: NSView) -> View? {
		if let matchingView = view as? View {
			return matchingView
		}
		return view.subviews.lazy.compactMap { self.firstSubview(of: View.self, in: $0) }.first
	}

	private func allSubviews<View: NSView>(of _: View.Type, in view: NSView) -> [View] {
		let currentView = (view as? View).map { [$0] } ?? []
		return currentView + view.subviews.flatMap { self.allSubviews(of: View.self, in: $0) }
	}
}
