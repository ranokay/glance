import Cocoa

enum FileTreeNodeRole: Equatable {
	case item
	case loading
	case loadMore(offset: Int)
	case retry(offset: Int)
}

enum DirectoryChildrenState: Equatable {
	case notLoaded
	case loading
	case loaded(nextOffset: Int?)
	case failed
}

enum FileTreeError {
	case notADirectoryError(pathParts: [String.SubSequence], pathPartIndex: Int)
	case pathDepthLimitExceeded(path: String, maxDepth: Int)
	case nodeCountLimitExceeded(maxNodeCount: Int)
}

extension FileTreeError: LocalizedError {
	var errorDescription: String? {
		switch self {
			case let .notADirectoryError(pathParts, pathPartIndex):
				NSLocalizedString(
					"Cannot create file tree node with path \"\(pathParts.joined())\": \"\(pathParts[pathPartIndex])\" is not a directory",
					comment: ""
				)
			case let .pathDepthLimitExceeded(path, maxDepth):
				NSLocalizedString(
					"Cannot create file tree node with path \"\(path)\": maximum path depth of \(maxDepth) exceeded",
					comment: ""
				)
			case let .nodeCountLimitExceeded(maxNodeCount):
				NSLocalizedString(
					"Cannot create file tree node: maximum node count of \(maxNodeCount) exceeded",
					comment: ""
				)
		}
	}
}

/// Data structure for representing a single file/directory in a tree. The class is designed to be
/// used in an `NSOutlineView`, which is why the `@objc` attributes are required.
class FileTreeNode: NSObject {
	/// Name of the file (without path information), e.g. `"myfile.txt"`
	@objc let name: String
	/// File size in bytes
	@objc let size: Int
	@objc let isDirectory: Bool
	@objc var dateModified: Date?
	@objc var fileURL: URL?
	@objc var isPackage: Bool
	@objc var isSymbolicLink: Bool
	@objc var contentTypeIdentifier: String?
	@objc dynamic var icon: NSImage?
	let role: FileTreeNodeRole
	var directoryChildrenState: DirectoryChildrenState
	weak var parentNode: FileTreeNode?
	/// Child nodes of a directory
	@objc var children = [String: FileTreeNode]()

	/// Number of child nodes (required for rendering the tree in an `NSOutlineView`)
	@objc var childrenCount: Int {
		children.values.count
	}

	/// List of child nodes (required for rendering the tree in an `NSOutlineView`).
	/// Display order only; page cursors resolve names in the scanner's ordering.
	@objc var childrenList: [FileTreeNode] {
		children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	/// Whether the node has any children (required for rendering the tree in an `NSOutlineView`)
	@objc var hasChildren: Bool {
		!children.isEmpty
	}

	/// Whether the node is a leaf (has no children) — used by `NSTreeController`'s `leafKeyPath`
	@objc var isLeaf: Bool {
		guard role == .item else {
			return true
		}
		guard isDirectory, !isPackage, !isSymbolicLink else {
			return !hasChildren
		}
		switch directoryChildrenState {
			case .notLoaded, .loading, .failed:
				return false
			case .loaded:
				return children.isEmpty
		}
	}

	/// Keeps loading, retry, and pagination actions after real entries for every sort direction.
	@objc var auxiliarySortRank: Int {
		role == .item ? 0 : 1
	}

	/// Whether the node is a loading, pagination, or retry row rather than a real entry.
	var isAuxiliary: Bool {
		role != .item
	}

	convenience init(name: String, size: Int, isDirectory: Bool) {
		self.init(name: name, size: size, isDirectory: isDirectory, dateModified: nil)
	}

	init(
		name: String,
		size: Int,
		isDirectory: Bool,
		dateModified: Date?,
		fileURL: URL? = nil,
		isPackage: Bool = false,
		isSymbolicLink: Bool = false,
		contentTypeIdentifier: String? = nil,
		icon: NSImage? = nil,
		role: FileTreeNodeRole = .item,
		directoryChildrenState: DirectoryChildrenState = .loaded(nextOffset: nil)
	) {
		self.name = name
		self.size = size
		self.isDirectory = isDirectory
		self.dateModified = dateModified
		self.fileURL = fileURL
		self.isPackage = isPackage
		self.isSymbolicLink = isSymbolicLink
		self.contentTypeIdentifier = contentTypeIdentifier
		self.icon = icon
		self.role = role
		self.directoryChildrenState = directoryChildrenState
	}

	static func loadingNode(parent: FileTreeNode? = nil) -> FileTreeNode {
		let node = FileTreeNode(
			name: "Loading…",
			size: 0,
			isDirectory: false,
			dateModified: nil,
			icon: NSImage(systemSymbolName: "progress.indicator", accessibilityDescription: nil),
			role: .loading
		)
		node.parentNode = parent
		return node
	}

	static func loadMoreNode(offset: Int, parent: FileTreeNode? = nil) -> FileTreeNode {
		let node = FileTreeNode(
			name: "Load More…",
			size: 0,
			isDirectory: false,
			dateModified: nil,
			icon: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil),
			role: .loadMore(offset: offset)
		)
		node.parentNode = parent
		return node
	}

	static func retryNode(offset: Int, parent: FileTreeNode? = nil) -> FileTreeNode {
		let node = FileTreeNode(
			name: "Couldn’t load this folder — Retry",
			size: 0,
			isDirectory: false,
			dateModified: nil,
			icon: NSImage(
				systemSymbolName: "arrow.clockwise.circle",
				accessibilityDescription: nil
			),
			role: .retry(offset: offset)
		)
		node.parentNode = parent
		return node
	}
}
