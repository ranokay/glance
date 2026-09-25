import Cocoa
import GlanceKit

/// NUL cannot occur in a filesystem name, so these internal dictionary keys cannot replace a
/// real child. The node's display name remains the user-facing loading/action text.
private enum AuxiliaryChildKey {
	static let loading = "\0glance.loading"
	static let loadMore = "\0glance.load-more"
	static let retry = "\0glance.retry"
}

extension OutlinePreviewVC {
	func loadFirstPage(for node: FileTreeNode) {
		guard let directoryPageLoader, let fileURL = node.fileURL else {
			return
		}
		let taskID = ObjectIdentifier(node)
		guard directoryLoadTasks[taskID] == nil else {
			return
		}

		node.directoryChildrenState = .loading
		node.children = [AuxiliaryChildKey.loading: .loadingNode(parent: node)]
		reloadTree(expanding: node)
		let task = Task { @MainActor [weak self, weak node] in
			guard let self, let node else {
				return
			}
			defer { directoryLoadTasks[taskID] = nil }
			do {
				let page = try await directoryPageLoader.page(
					at: fileURL,
					offset: 0,
					session: directoryPaginationSession
				)
				try Task.checkCancellation()
				apply(page: page, to: node, replacingChildren: true)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not load folder \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				node.directoryChildrenState = .failed
				node.children = [AuxiliaryChildKey.retry: .retryNode(offset: 0, parent: node)]
				reloadTree(expanding: node)
			}
		}
		directoryLoadTasks[taskID] = task
	}

	func loadNextPage(from parent: FileTreeNode?, offset: Int) {
		guard let directoryPageLoader else {
			return
		}
		if let parent {
			loadNextChildPage(for: parent, offset: offset, loader: directoryPageLoader)
		} else {
			loadNextRootPage(offset: offset, loader: directoryPageLoader)
		}
	}

	func loadNextChildPage(
		for parent: FileTreeNode,
		offset: Int,
		loader: any DirectoryPageLoading
	) {
		guard let fileURL = parent.fileURL else {
			return
		}
		let taskID = ObjectIdentifier(parent)
		guard directoryLoadTasks[taskID] == nil else {
			return
		}
		removeAuxiliaryChildren(from: parent)
		parent.children[AuxiliaryChildKey.loading] = .loadingNode(parent: parent)
		parent.directoryChildrenState = .loading
		reloadTree(expanding: parent)
		let task = Task { @MainActor [weak self, weak parent] in
			guard let self, let parent else {
				return
			}
			defer { directoryLoadTasks[taskID] = nil }
			do {
				let page = try await loader.page(
					at: fileURL,
					offset: offset,
					session: directoryPaginationSession
				)
				try Task.checkCancellation()
				apply(page: page, to: parent, replacingChildren: false)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not load more items from \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				removeAuxiliaryChildren(from: parent)
				parent.children[AuxiliaryChildKey.retry] = .retryNode(
					offset: offset,
					parent: parent
				)
				parent.directoryChildrenState = .failed
				reloadTree(expanding: parent)
			}
		}
		directoryLoadTasks[taskID] = task
	}

	func loadNextRootPage(offset: Int, loader: any DirectoryPageLoading) {
		guard let directoryURL, rootPageLoadTask == nil else {
			return
		}
		rootNodes.removeAll { $0.role != .item }
		rootNodes.append(.loadingNode())
		reloadTree()
		rootPageLoadTask = Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			defer { rootPageLoadTask = nil }
			do {
				let page = try await loader.page(
					at: directoryURL,
					offset: offset,
					session: directoryPaginationSession
				)
				try Task.checkCancellation()
				rootNodes.removeAll { $0.role != .item }
				rootNodes.append(contentsOf: DirectoryPreview.makeNodes(from: page.entries))
				if let nextOffset = page.nextOffset {
					rootNodes.append(.loadMoreNode(offset: nextOffset))
				}
				updateDirectoryStatus()
				reloadTree()
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not load more items from \(directoryURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				rootNodes.removeAll { $0.role != .item }
				rootNodes.append(.retryNode(offset: offset))
				reloadTree()
			}
		}
	}

	func apply(page: DirectoryPage, to parent: FileTreeNode, replacingChildren: Bool) {
		if replacingChildren {
			parent.children.removeAll()
		} else {
			removeAuxiliaryChildren(from: parent)
		}
		for child in DirectoryPreview.makeNodes(from: page.entries) {
			child.parentNode = parent
			parent.children[child.name] = child
		}
		if let nextOffset = page.nextOffset {
			parent.children[AuxiliaryChildKey.loadMore] = .loadMoreNode(
				offset: nextOffset,
				parent: parent
			)
		}
		parent.directoryChildrenState = .loaded(nextOffset: page.nextOffset)
		reloadTree(expanding: parent)
	}

	func removeAuxiliaryChildren(from parent: FileTreeNode) {
		parent.children = parent.children.filter { $0.value.role == .item }
	}

	func updateDirectoryStatus() {
		guard directoryURL != nil else {
			return
		}
		let loadedCount = rootNodes.count { $0.role == .item }
		let hasMore = rootNodes.contains {
			if case .loadMore = $0.role {
				return true
			}
			return false
		}
		previewStatusText = DirectoryPreview.itemCountText(
			loadedCount: loadedCount,
			hasMore: hasMore
		)
		previewStatusDidChange?(previewStatusText)
	}
}
