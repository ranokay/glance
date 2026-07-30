import Cocoa

struct FolderSearchResult {
	let rootNodes: [FileTreeNode]
	let matchCount: Int?

	var isFiltering: Bool {
		matchCount != nil
	}
}

enum FolderSearch {
	static func filter(rootNodes: [FileTreeNode], query: String) -> FolderSearchResult {
		let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedQuery.isEmpty else {
			return FolderSearchResult(rootNodes: rootNodes, matchCount: nil)
		}

		var matchCount = 0
		let filteredNodes = rootNodes.compactMap { node -> FileTreeNode? in
			let result = filteredNode(node, matching: trimmedQuery)
			matchCount += result.matchCount
			return result.node
		}
		return FolderSearchResult(rootNodes: filteredNodes, matchCount: matchCount)
	}

	static func statusText(matchCount: Int, isTruncated: Bool) -> String {
		guard matchCount > 0 else {
			return "No matches"
		}
		let noun = matchCount == 1 ? "match" : "matches"
		let truncationSuffix = isTruncated ? " in first 500 items" : ""
		return "\(matchCount) \(noun)\(truncationSuffix)"
	}

	private static func filteredNode(
		_ node: FileTreeNode,
		matching query: String
	) -> (node: FileTreeNode?, matchCount: Int) {
		let nodeMatches = node.name.range(
			of: query,
			options: [.caseInsensitive, .diacriticInsensitive],
			locale: .current
		) != nil
		var matchCount = nodeMatches ? 1 : 0
		let filteredChildren = node.childrenList.compactMap { child -> FileTreeNode? in
			let result = filteredNode(child, matching: query)
			matchCount += result.matchCount
			return result.node
		}

		guard nodeMatches || !filteredChildren.isEmpty else {
			return (nil, 0)
		}
		return (node.copying(children: filteredChildren), matchCount)
	}
}

extension FileTreeNode {
	func copying(children copiedChildren: [FileTreeNode]) -> FileTreeNode {
		let copy = FileTreeNode(
			name: name,
			size: size,
			isDirectory: isDirectory,
			dateModified: dateModified,
			fileURL: fileURL,
			isPackage: isPackage,
			isSymbolicLink: isSymbolicLink,
			contentTypeIdentifier: contentTypeIdentifier,
			icon: icon
		)
		copy.children = Dictionary(uniqueKeysWithValues: copiedChildren.map { ($0.name, $0) })
		return copy
	}
}
