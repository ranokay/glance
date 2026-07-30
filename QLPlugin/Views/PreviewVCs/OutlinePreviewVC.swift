import Cocoa

@MainActor
protocol OutlinePreviewCommandHandling: AnyObject {
	func focusFolderSearch() -> Bool
}

final class OutlinePreviewView: NSView {
	weak var commandHandler: OutlinePreviewCommandHandling?

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let isFindCommand = modifiers == .command
			&& event.charactersIgnoringModifiers?.lowercased() == "f"
		if isFindCommand, commandHandler?.focusFolderSearch() == true {
			return true
		}
		return super.performKeyEquivalent(with: event)
	}
}

class OutlinePreviewVC: NSViewController, PreviewVC, NSSearchFieldDelegate {
	@objc dynamic var rootNodes: [FileTreeNode]
	private let labelText: String?
	private let expandAll: Bool
	private let showsFileThumbnails: Bool
	private let searchEnabled: Bool
	private let searchItemLimitReached: Bool
	private var thumbnailLoader: DirectoryThumbnailLoader?
	private var searchField: NSSearchField?

	@objc dynamic var customSortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

	@IBOutlet private var treeController: NSTreeController!
	@IBOutlet private var outlineView: NSOutlineView!
	@IBOutlet private var label: NSTextField!
	@IBOutlet private var outlineTopConstraint: NSLayoutConstraint!

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
		searchEnabled: Bool = false,
		searchItemLimitReached: Bool = false
	) {
		self.init(
			nibName: NSNib.Name("OutlinePreviewVC"),
			bundle: Self.resourceBundle,
			rootNodes: rootNodes,
			labelText: labelText,
			expandAll: expandAll,
			showsFileThumbnails: showsFileThumbnails,
			searchEnabled: searchEnabled,
			searchItemLimitReached: searchItemLimitReached
		)
	}

	init(
		nibName nibNameOrNil: NSNib.Name?,
		bundle nibBundleOrNil: Bundle?,
		rootNodes: [FileTreeNode],
		labelText: String?,
		expandAll: Bool = false,
		showsFileThumbnails: Bool = false,
		searchEnabled: Bool = false,
		searchItemLimitReached: Bool = false,
		thumbnailLoader: DirectoryThumbnailLoader? = nil
	) {
		self.rootNodes = rootNodes
		self.labelText = labelText
		self.expandAll = expandAll
		self.showsFileThumbnails = showsFileThumbnails
		self.searchEnabled = searchEnabled
		self.searchItemLimitReached = searchItemLimitReached
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
		setUpView()
		setUpSearch()
		if expandAll {
			expandAllItems()
		} else {
			expandSingleRootItem()
		}
		setUpThumbnailLoading()
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		configureVisibleFolderRows()
		requestVisibleThumbnails()
	}

	override func viewWillDisappear() {
		super.viewWillDisappear()
		thumbnailLoader?.cancelAll()
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	private func setUpView() {
		display(rootNodes: rootNodes)

		// Add label
		label.stringValue = labelText ?? ""
	}

	private func setUpSearch() {
		guard searchEnabled,
		      let scrollView = outlineView.enclosingScrollView
		else {
			return
		}

		let searchField = NSSearchField()
		searchField.translatesAutoresizingMaskIntoConstraints = false
		searchField.placeholderString = "Search folder"
		searchField.delegate = self
		searchField.sendsSearchStringImmediately = true
		view.addSubview(searchField)
		outlineTopConstraint.isActive = false
		NSLayoutConstraint.activate([
			searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
			searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
			searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
			searchField.heightAnchor.constraint(equalToConstant: 24),
			scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
		])
		self.searchField = searchField
		(view as? OutlinePreviewView)?.commandHandler = self
	}

	func controlTextDidChange(_ notification: Notification) {
		guard let searchField = notification.object as? NSSearchField,
		      searchField === self.searchField
		else {
			return
		}
		applySearchQuery(searchField.stringValue)
	}

	func control(
		_ control: NSControl,
		textView _: NSTextView,
		doCommandBy commandSelector: Selector
	) -> Bool {
		guard control === searchField,
		      commandSelector == #selector(NSResponder.cancelOperation(_:))
		else {
			return false
		}
		searchField?.stringValue = ""
		applySearchQuery("")
		view.window?.makeFirstResponder(outlineView)
		return true
	}

	func applySearchQuery(_ query: String) {
		guard searchEnabled else {
			return
		}
		let result = FolderSearch.filter(rootNodes: rootNodes, query: query)
		display(rootNodes: result.rootNodes)
		if let matchCount = result.matchCount {
			label.stringValue = FolderSearch.statusText(
				matchCount: matchCount,
				isTruncated: searchItemLimitReached
			)
		} else {
			label.stringValue = labelText ?? ""
		}
		expandAllItems()
		requestVisibleThumbnails()
	}

	func focusFolderSearch() -> Bool {
		guard let searchField else {
			return false
		}
		view.window?.makeFirstResponder(searchField)
		searchField.currentEditor()?.selectAll(nil)
		return true
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
		requestVisibleThumbnails()
	}

	@objc
	private func outlineViewportDidChange() {
		configureVisibleFolderRows()
		requestVisibleThumbnails()
	}

	private func configureVisibleFolderRows() {
		guard showsFileThumbnails else {
			return
		}
		for row in visibleRowIndexes() {
			guard let cellView = outlineView.view(
				atColumn: 0,
				row: row,
				makeIfNecessary: true
			) as? NSTableCellView else {
				continue
			}
			cellView.imageView?.frame = NSRect(x: 3, y: 2, width: 24, height: 24)
			if let textField = cellView.textField {
				textField.frame.origin.x = 31
				textField.frame.size.width = max(0, cellView.bounds.width - 31)
			}
		}
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
}

extension OutlinePreviewVC: OutlinePreviewCommandHandling {}

/// `ValueTransformer` which formats the provided date.
class DateTransformer: ValueTransformer {
	let dateFormatter = DateFormatter()
	let fallbackValue = "--"

	override init() {
		// Use same date format as Finder
		dateFormatter.dateStyle = .medium
		dateFormatter.timeStyle = .short
		dateFormatter.doesRelativeDateFormatting = true
	}

	override class func transformedValueClass() -> AnyClass {
		NSString.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let date = value as? Date else {
			return nil
		}

		// Dates which are `nil` are passed to this function as epoch dates (default value). If
		// this is the case, return "--" instead (same behavior as Finder)
		return date.timeIntervalSince1970 == 0 ? fallbackValue : dateFormatter.string(from: date)
	}
}

protocol FileIconProviding {
	func icon(for fileURL: URL) -> NSImage
}

final class WorkspaceFileIconProvider: FileIconProviding {
	func icon(for fileURL: URL) -> NSImage {
		NSWorkspace.shared.icon(forFile: fileURL.path)
	}
}

/// `ValueTransformer` which returns a thumbnail, file-specific icon, or generic fallback icon.
class IconTransformer: ValueTransformer {
	private static let directoryIcon = NSImage(
		contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns"
	)
	private static let fileIcon = NSImage(
		contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"
	)
	private let fileIconProvider: FileIconProviding

	override convenience init() {
		self.init(fileIconProvider: WorkspaceFileIconProvider())
	}

	init(fileIconProvider: FileIconProviding) {
		self.fileIconProvider = fileIconProvider
		super.init()
	}

	override class func transformedValueClass() -> AnyClass {
		NSImage.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let node = value as? FileTreeNode else {
			return nil
		}
		if let icon = node.icon {
			return icon
		}
		if let fileURL = node.fileURL {
			return fileIconProvider.icon(for: fileURL)
		}
		return node.isDirectory ? Self.directoryIcon : Self.fileIcon
	}
}

/// `ValueTransformer` which formats the provided number of bytes as a human-readable string (e.g.
/// `12345` -> `"12.345 KB"` or `0` -> `"--"`).
class SizeTransformer: ValueTransformer {
	let byteCountFormatter = ByteCountFormatter()
	let fallbackValue = "--"

	override class func transformedValueClass() -> AnyClass {
		NSString.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let size = value as? NSNumber else {
			return nil
		}

		// Format number of bytes in human-readable way. If the size is 0 bytes, return "--" instead
		// (same behavior as Finder)
		return size == 0 ? fallbackValue : (byteCountFormatter.string(for: size) ?? fallbackValue)
	}
}

extension NSValueTransformerName {
	static let dateTransformerName = NSValueTransformerName(rawValue: "DateTransformer")
	static let iconTransformerName = NSValueTransformerName(rawValue: "IconTransformer")
	static let sizeTransformerName = NSValueTransformerName(rawValue: "SizeTransformer")
}
