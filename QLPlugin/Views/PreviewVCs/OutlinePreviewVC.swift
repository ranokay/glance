import Cocoa

@MainActor
protocol OutlinePreviewInteractionDelegate: AnyObject {
	func outlinePreview(_ preview: OutlinePreviewVC, didSelect node: FileTreeNode?)
	func outlinePreview(_ preview: OutlinePreviewVC, requestPreviewOf node: FileTreeNode)
	func outlinePreview(_ preview: OutlinePreviewVC, requestNavigationInto node: FileTreeNode)
}

class OutlinePreviewVC: NSViewController, PreviewVC {
	@objc dynamic var rootNodes: [FileTreeNode]
	var previewStatusText: String
	var previewStatusDidChange: (@MainActor (String) -> Void)?
	private(set) var selectedNode: FileTreeNode?
	weak var interactionDelegate: OutlinePreviewInteractionDelegate? {
		didSet {
			if isViewLoaded {
				setUpInteraction()
			}
		}
	}

	private let expandAll: Bool
	private let showsFileThumbnails: Bool
	private(set) var directoryURL: URL?
	var isDirectoryBrowser: Bool {
		directoryURL != nil
	}

	let directoryPageLoader: (any DirectoryPageLoading)?
	let directoryPaginationSession: DirectoryPaginationSession
	var thumbnailLoader: DirectoryThumbnailLoader?
	var directoryLoadTasks = [ObjectIdentifier: Task<Void, Never>]()
	var rootPageLoadTask: Task<Void, Never>?
	private var pendingSortSnapshot: OutlineStateSnapshot?
	var isRestoringSortState: Bool {
		pendingSortSnapshot != nil
	}

	@objc dynamic var customSortDescriptors = [
		NSSortDescriptor(key: "auxiliarySortRank", ascending: true),
		NSSortDescriptor(
			key: "name",
			ascending: true,
			selector: #selector(NSString.localizedStandardCompare(_:))
		),
	] {
		willSet {
			guard isViewLoaded, pendingSortSnapshot == nil else {
				return
			}
			pendingSortSnapshot = captureOutlineState()
		}
		didSet {
			if customSortDescriptors.first?.key != "auxiliarySortRank" {
				customSortDescriptors = [
					NSSortDescriptor(key: "auxiliarySortRank", ascending: true),
				] + customSortDescriptors.filter { $0.key != "auxiliarySortRank" }
			}
			guard let pendingSortSnapshot else {
				return
			}
			Task { @MainActor [weak self] in
				await Task.yield()
				guard let self, self.pendingSortSnapshot != nil else {
					return
				}
				self.pendingSortSnapshot = nil
				reloadTree(restoring: pendingSortSnapshot)
			}
		}
	}

	@IBOutlet private var treeController: NSTreeController!
	@IBOutlet private var outlineView: NSOutlineView!

	nonisolated static let resourceBundle: Bundle = {
		let embeddedPluginBundle = Bundle.main.builtInPlugInsURL
			.flatMap { Bundle(url: $0.appendingPathComponent("QLPlugin.appex")) }
		let candidates = [
			Bundle(for: OutlinePreviewVC.self),
			Bundle(identifier: "com.chamburr.Glance.QLPlugin"),
			embeddedPluginBundle,
			Bundle.main,
		].compactMap(\.self)

		return candidates.first {
			$0.url(forResource: "OutlinePreviewVC", withExtension: "nib") != nil
		} ?? Bundle(for: OutlinePreviewVC.self)
	}()

	private static let registerValueTransformersOnce: Void = {
		ValueTransformer.setValueTransformer(DateTransformer(), forName: .dateTransformerName)
		ValueTransformer.setValueTransformer(IconTransformer(), forName: .iconTransformerName)
		ValueTransformer.setValueTransformer(SizeTransformer(), forName: .sizeTransformerName)
	}()

	required convenience init(
		rootNodes: [FileTreeNode],
		labelText: String?,
		expandAll: Bool = false,
		showsFileThumbnails: Bool = false,
		directoryURL: URL? = nil,
		directoryPageLoader: (any DirectoryPageLoading)? = nil,
		directoryPaginationSession: DirectoryPaginationSession = DirectoryPaginationSession()
	) {
		self.init(
			nibName: NSNib.Name("OutlinePreviewVC"),
			bundle: Self.resourceBundle,
			rootNodes: rootNodes,
			labelText: labelText,
			expandAll: expandAll,
			showsFileThumbnails: showsFileThumbnails,
			directoryURL: directoryURL,
			directoryPageLoader: directoryPageLoader,
			directoryPaginationSession: directoryPaginationSession
		)
	}

	init(
		nibName nibNameOrNil: NSNib.Name?,
		bundle nibBundleOrNil: Bundle?,
		rootNodes: [FileTreeNode],
		labelText: String?,
		expandAll: Bool = false,
		showsFileThumbnails: Bool = false,
		thumbnailLoader: DirectoryThumbnailLoader? = nil,
		directoryURL: URL? = nil,
		directoryPageLoader: (any DirectoryPageLoading)? = nil,
		directoryPaginationSession: DirectoryPaginationSession = DirectoryPaginationSession()
	) {
		self.rootNodes = rootNodes
		previewStatusText = labelText ?? ""
		self.expandAll = expandAll
		self.showsFileThumbnails = showsFileThumbnails
		self.directoryURL = directoryURL
		self.directoryPageLoader = directoryPageLoader
		self.directoryPaginationSession = directoryPaginationSession
		self.thumbnailLoader = showsFileThumbnails
			? thumbnailLoader ?? DirectoryThumbnailLoader()
			: nil
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
		_ = Self.registerValueTransformersOnce
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setUpInteraction()
		setUpView()
		if expandAll {
			expandAllItems()
		} else if !isDirectoryBrowser {
			expandSingleRootItem()
		}
		setUpThumbnailLoading()
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		configureVisibleFolderCells()
		requestVisibleThumbnails()
	}

	override func viewWillDisappear() {
		super.viewWillDisappear()
		thumbnailLoader?.cancelAll()
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	func tearDown() {
		rootPageLoadTask?.cancel()
		rootPageLoadTask = nil
		for task in directoryLoadTasks.values {
			task.cancel()
		}
		directoryLoadTasks.removeAll()
		thumbnailLoader?.cancelAll()
	}

	private func setUpView() {
		outlineView.enclosingScrollView?.drawsBackground = false
		outlineView.enclosingScrollView?.contentView.drawsBackground = false
		outlineView.backgroundColor = .clear
		if isDirectoryBrowser {
			outlineView.allowsEmptySelection = true
		}
		display(rootNodes: rootNodes)
		if isDirectoryBrowser {
			outlineView.deselectAll(nil)
		}
	}

	func activateOutlineSelection() -> Bool {
		guard outlineView.selectedRow >= 0,
		      let node = treeNode(at: outlineView.selectedRow),
		      !node.isSymbolicLink
		else {
			return false
		}

		switch node.role {
			case let .loadMore(offset):
				loadNextPage(from: node.parentNode, offset: offset)
				return true
			case let .retry(offset):
				if let parent = node.parentNode, offset == 0 {
					loadFirstPage(for: parent)
				} else {
					loadNextPage(from: node.parentNode, offset: offset)
				}
				return true
			case .loading:
				return false
			case .item:
				break
		}

		if node.isDirectory, !node.isPackage {
			guard let item = outlineView.item(atRow: outlineView.selectedRow) else {
				return false
			}
			if outlineView.isItemExpanded(item) {
				outlineView.collapseItem(item)
			} else {
				outlineView.expandItem(item)
			}
			return true
		}

		interactionDelegate?.outlinePreview(self, requestPreviewOf: node)
		return true
	}

	private func setUpInteraction() {
		outlineView.delegate = self
		outlineView.selectionHighlightStyle = interactionDelegate == nil ? .none : .regular
		outlineView.allowsEmptySelection = true
		outlineView.target = self
		outlineView.doubleAction = #selector(outlineSelectionWasDoubleClicked)
	}

	@objc
	private func outlineSelectionWasDoubleClicked() {
		guard outlineView.clickedRow >= 0,
		      let node = treeNode(at: outlineView.clickedRow),
		      !node.isSymbolicLink
		else {
			return
		}
		switch node.role {
			case .item where node.isDirectory && !node.isPackage:
				interactionDelegate?.outlinePreview(self, requestNavigationInto: node)
			default:
				_ = activateOutlineSelection()
		}
	}

	private func display(rootNodes: [FileTreeNode]) {
		treeController.content = rootNodes
		treeController.rearrangeObjects()
	}

	/// If the root contains a single item, this function expands its children.
	private func expandSingleRootItem() {
		let root = treeController.arrangedObjects
		if root.children?.count == 1, let firstChild = root.children?.first {
			outlineView.expandItem(firstChild)
		}
	}

	private func expandAllItems() {
		outlineView.expandItem(nil, expandChildren: true)
	}

	private func setUpThumbnailLoading() {
		guard showsFileThumbnails,
		      let clipView = outlineView.enclosingScrollView?.contentView
		else {
			return
		}
		outlineView.rowHeight = 28
		clipView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(outlineViewportDidChange),
			name: NSView.boundsDidChangeNotification,
			object: clipView
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(outlineViewportDidChange),
			name: NSOutlineView.itemDidExpandNotification,
			object: outlineView
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(outlineViewportDidChange),
			name: NSOutlineView.itemDidCollapseNotification,
			object: outlineView
		)
		requestVisibleThumbnails()
	}

	@objc
	private func outlineViewportDidChange() {
		configureVisibleFolderCells()
		requestVisibleThumbnails()
	}

	private func configureVisibleFolderCells() {
		guard showsFileThumbnails else {
			return
		}
		for row in visibleRowIndexes() {
			guard let cellView = outlineView.view(
				atColumn: 0,
				row: row,
				makeIfNecessary: false
			) as? NSTableCellView else {
				continue
			}
			configureFolderCell(cellView)
		}
	}

	private func configureFolderCell(_ cellView: NSTableCellView) {
		guard let imageView = cellView.imageView,
		      let textField = cellView.textField,
		      !imageView.constraints.contains(where: { $0.identifier == "Glance.FolderIconWidth" })
		else {
			return
		}
		imageView.translatesAutoresizingMaskIntoConstraints = false
		textField.translatesAutoresizingMaskIntoConstraints = false
		let width = imageView.widthAnchor.constraint(equalToConstant: 24)
		width.identifier = "Glance.FolderIconWidth"
		NSLayoutConstraint.activate([
			width,
			imageView.heightAnchor.constraint(equalToConstant: 24),
			imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 3),
			imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
			// NSTextField's alignment rect extends two points beyond its visible frame.
			textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
			textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
			textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
		])
	}

	private func requestVisibleThumbnails() {
		guard let thumbnailLoader else {
			return
		}
		let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
		for row in visibleRowIndexes() {
			guard let treeNode = treeNode(at: row) else {
				continue
			}
			thumbnailLoader.requestThumbnail(for: treeNode, scale: scale) { [weak self] node in
				self?.reloadIcon(for: node)
			}
		}
	}

	private func visibleRowIndexes() -> Range<Int> {
		let visibleRows = outlineView.rows(in: outlineView.visibleRect)
		guard visibleRows.location != NSNotFound else {
			return 0 ..< 0
		}
		return visibleRows.location ..< NSMaxRange(visibleRows)
	}

	private func treeNode(at row: Int) -> FileTreeNode? {
		(outlineView.item(atRow: row) as? NSTreeNode)?.representedObject as? FileTreeNode
	}

	private func reloadIcon(for node: FileTreeNode) {
		for row in visibleRowIndexes() where treeNode(at: row) === node {
			outlineView.reloadData(
				forRowIndexes: IndexSet(integer: row),
				columnIndexes: IndexSet(integer: 0)
			)
			return
		}
	}

	func makeDirectoryPreview(for node: FileTreeNode) async throws -> OutlinePreviewVC {
		guard let directoryPageLoader,
		      let fileURL = node.fileURL,
		      node.isDirectory,
		      !node.isPackage,
		      !node.isSymbolicLink
		else {
			throw NestedPreviewError.nonNavigableItem(name: node.name)
		}
		return try await DirectoryPreview.makeOutlinePreview(
			for: fileURL,
			pageLoader: directoryPageLoader
		)
	}

	private func captureOutlineState() -> OutlineStateSnapshot {
		let expandedNodes = Set((0 ..< outlineView.numberOfRows)
			.compactMap { row -> ObjectIdentifier? in
				guard let item = outlineView.item(atRow: row),
				      outlineView.isItemExpanded(item),
				      let treeNode = treeNode(at: row)
				else {
					return nil
				}
				return ObjectIdentifier(treeNode)
			})
		return OutlineStateSnapshot(
			expandedNodes: expandedNodes,
			selectedNode: selectedNode,
			scrollOrigin: outlineView.enclosingScrollView?.contentView.bounds.origin
		)
	}

	func reloadTree(
		expanding node: FileTreeNode? = nil,
		restoring state: OutlineStateSnapshot? = nil
	) {
		var expandedNodes = state?.expandedNodes ?? captureOutlineState().expandedNodes
		if let node {
			expandedNodes.insert(ObjectIdentifier(node))
		}
		let selectedIdentifier: ObjectIdentifier? = if let state {
			state.selectedNode.map(ObjectIdentifier.init)
		} else {
			selectedNode.map(ObjectIdentifier.init)
		}
		let scrollOrigin = state?.scrollOrigin
			?? outlineView.enclosingScrollView?.contentView.bounds.origin

		display(rootNodes: rootNodes)
		outlineView.reloadData()
		var row = 0
		while row < outlineView.numberOfRows {
			let treeNode = treeNode(at: row)
			let nodeIdentifier = treeNode.map(ObjectIdentifier.init)
			let isExpanded = nodeIdentifier.map(expandedNodes.contains) ?? false
			if isExpanded, let item = outlineView.item(atRow: row) {
				outlineView.expandItem(item)
			}
			row += 1
		}
		let selectedRow = selectedIdentifier.flatMap { identifier in
			(0 ..< outlineView.numberOfRows).first { row in
				treeNode(at: row).map(ObjectIdentifier.init) == identifier
			}
		}
		if let selectedRow {
			outlineView.selectRowIndexes(
				IndexSet(integer: selectedRow),
				byExtendingSelection: false
			)
		} else {
			outlineView.deselectAll(nil)
		}
		if let scrollOrigin, let clipView = outlineView.enclosingScrollView?.contentView {
			clipView.scroll(to: scrollOrigin)
			outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
		}
		configureVisibleFolderCells()
		requestVisibleThumbnails()
	}
}

struct OutlineStateSnapshot {
	let expandedNodes: Set<ObjectIdentifier>
	let selectedNode: FileTreeNode?
	let scrollOrigin: NSPoint?
}

extension OutlinePreviewVC: PreviewStatusProviding {}

extension OutlinePreviewVC: NSOutlineViewDelegate {
	func outlineView(_: NSOutlineView, shouldExpandItem item: Any) -> Bool {
		guard let treeNode = (item as? NSTreeNode)?.representedObject as? FileTreeNode else {
			return false
		}
		switch treeNode.directoryChildrenState {
			case .notLoaded:
				loadFirstPage(for: treeNode)
			case .loading, .loaded, .failed:
				break
		}
		return true
	}

	func outlineViewSelectionDidChange(_: Notification) {
		selectedNode = treeNode(at: outlineView.selectedRow)
		let selectableNode = selectedNode?.role == .item ? selectedNode : nil
		interactionDelegate?.outlinePreview(self, didSelect: selectableNode)
	}

	func outlineView(_: NSOutlineView, didAdd _: NSTableRowView, forRow row: Int) {
		guard
			showsFileThumbnails,
			let cellView = outlineView.view(
				atColumn: 0,
				row: row,
				makeIfNecessary: false
			) as? NSTableCellView
		else {
			return
		}
		configureFolderCell(cellView)
	}
}
