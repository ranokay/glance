import Cocoa

// Quarantined legacy builder (slice 8).
//
// `FileTree` is still the shared bounded archive-tree builder used by the RAR,
// SevenZip, TAR, and ZIP previews. Do not adopt it for new previews, and do not
// delete it until those four previews migrate off it.

/// Data structure for representing a tree of files and directories. This class stores the root node
/// and provides functionality to insert new nodes.
class FileTree {
	static let defaultMaxPathDepth = 128
	static let defaultMaxNodeCount = 50000

	var root = FileTreeNode(name: "Root", size: 0, isDirectory: true, dateModified: Date())
	private let maxPathDepth: Int
	private let maxNodeCount: Int
	private var nodeCount = 1

	init(
		maxPathDepth: Int = FileTree.defaultMaxPathDepth,
		maxNodeCount: Int = FileTree.defaultMaxNodeCount
	) {
		self.maxPathDepth = max(1, maxPathDepth)
		self.maxNodeCount = max(1, maxNodeCount)
	}

	/// Parses the provided file/directory's path and creates a new `FileTreeNode` at the correct
	/// position in the tree. If a file/directory's parent directory doesn't exist yet, it will
	/// be created (with `dateModified` set to `nil`).
	func addNode(
		path: String,
		isDirectory: Bool,
		size: Int,
		dateModified: Date?,
		fileURL: URL? = nil,
		isPackage: Bool = false,
		isSymbolicLink: Bool = false,
		contentTypeIdentifier: String? = nil
	) throws {
		let pathParts = path.split(separator: "/", omittingEmptySubsequences: true)
		guard !pathParts.isEmpty else {
			return
		}
		guard pathParts.count <= maxPathDepth else {
			throw FileTreeError.pathDepthLimitExceeded(path: path, maxDepth: maxPathDepth)
		}

		var parentNode = root
		for (pathPartIndex, pathPart) in pathParts.enumerated() {
			let isLastPathPart = pathPartIndex == pathParts.count - 1
			let name = String(pathPart)
			let currentNode = parentNode.children[name]

			if isLastPathPart {
				if let currentNode {
					// Node already exists (i.e. directory has been created implicitly in a previous
					// function call): Update the directory node with the missing `dateModified`
					// info
					currentNode.dateModified = dateModified
					currentNode.fileURL = fileURL
					currentNode.isPackage = isPackage
					currentNode.isSymbolicLink = isSymbolicLink
					currentNode.contentTypeIdentifier = contentTypeIdentifier
				} else {
					_ = try createNode(
						parentNode: parentNode,
						name: name,
						size: size,
						isDirectory: isDirectory,
						dateModified: dateModified,
						fileURL: fileURL,
						isPackage: isPackage,
						isSymbolicLink: isSymbolicLink,
						contentTypeIdentifier: contentTypeIdentifier
					)
				}
			} else {
				if let currentNode {
					guard currentNode.isDirectory else {
						throw FileTreeError.notADirectoryError(
							pathParts: pathParts,
							pathPartIndex: pathPartIndex
						)
					}
					parentNode = currentNode
				} else {
					parentNode = try createNode(
						parentNode: parentNode,
						name: name,
						size: 0,
						isDirectory: true,
						dateModified: nil,
						fileURL: nil,
						isPackage: false,
						isSymbolicLink: false,
						contentTypeIdentifier: nil
					)
				}
			}
		}
	}

	private func createNode(
		parentNode: FileTreeNode,
		name: String,
		size: Int,
		isDirectory: Bool,
		dateModified: Date?,
		fileURL: URL?,
		isPackage: Bool,
		isSymbolicLink: Bool,
		contentTypeIdentifier: String?
	) throws -> FileTreeNode {
		guard nodeCount < maxNodeCount else {
			throw FileTreeError.nodeCountLimitExceeded(maxNodeCount: maxNodeCount)
		}
		let node = FileTreeNode(
			name: name,
			size: size,
			isDirectory: isDirectory,
			dateModified: dateModified,
			fileURL: fileURL,
			isPackage: isPackage,
			isSymbolicLink: isSymbolicLink,
			contentTypeIdentifier: contentTypeIdentifier
		)
		parentNode.children[name] = node
		nodeCount += 1
		return node
	}
}
