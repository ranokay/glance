import Cocoa

extension MainVC {
	func installTopLevelPreview(_ previewVC: PreviewVC, file: File) {
		clearPreviewControllers()
		topLevelFile = file
		previewNavigationStack = [previewVC]
		if let outlinePreview = previewVC as? OutlinePreviewVC,
		   outlinePreview.isNestedPreviewBrowser
		{
			folderPreviewController = outlinePreview
			outlinePreview.interactionDelegate = self
		}
		nestedOpenWithTargetURL = nil
		removeAllTemporaryFiles()
		bindStatus(to: previewVC)
		show(previewVC)
		updateOpenWithTarget()
	}

	func pushPreview(
		_ previewVC: PreviewVC,
		openWithTargetURL: URL?,
		temporaryFileURL: URL? = nil
	) {
		if let outlinePreview = previewVC as? OutlinePreviewVC,
		   outlinePreview.isNestedPreviewBrowser
		{
			outlinePreview.interactionDelegate = self
			folderPreviewController = outlinePreview
			nestedPreviewController = nil
			selectedFolderNode = outlinePreview.selectedNode
		} else {
			nestedPreviewController = previewVC
			selectedFolderNode = nil
		}
		previewNavigationStack.append(previewVC)
		nestedOpenWithTargetURL = openWithTargetURL
		if let temporaryFileURL {
			temporaryFiles[ObjectIdentifier(previewVC)] = temporaryFileURL
		}
		bindStatus(to: previewVC)
		show(previewVC)
		updateOpenWithTarget()
	}

	@objc
	func showFolderPreview() {
		nestedPreviewTask?.cancel()
		nestedPreviewTask = nil
		guard previewNavigationStack.count > 1,
		      let removedController = previewNavigationStack.popLast(),
		      let previousController = previewNavigationStack.last
		else {
			return
		}
		removedController.tearDown()
		removedController.view.removeFromSuperview()
		removedController.removeFromParent()
		removeTemporaryFile(for: removedController)
		if let outlinePreview = previousController as? OutlinePreviewVC,
		   outlinePreview.isNestedPreviewBrowser
		{
			folderPreviewController = outlinePreview
			nestedPreviewController = nil
			selectedFolderNode = outlinePreview.selectedNode
		} else {
			folderPreviewController = nil
			nestedPreviewController = previousController
			selectedFolderNode = nil
		}
		nestedOpenWithTargetURL = nil
		bindStatus(to: previousController)
		show(previousController)
		updateOpenWithTarget()
	}

	func clearPreviewControllers() {
		nestedPreviewTask?.cancel()
		nestedPreviewTask = nil
		statusResetTask?.cancel()
		boundStatusProvider?.previewStatusDidChange = nil
		boundStatusProvider = nil
		for child in children {
			(child as? PreviewVC)?.tearDown()
			child.view.removeFromSuperview()
			child.removeFromParent()
		}
		folderPreviewController = nil
		nestedPreviewController = nil
		previewNavigationStack.removeAll()
		topLevelFile = nil
		selectedFolderNode = nil
		nestedOpenWithTargetURL = nil
		removeAllTemporaryFiles()
		openWithTargetURL = nil
		refreshOpenWithMenu()
		setBaseStatus("")
		updateChrome()
	}

	func removeTemporaryFile(for controller: PreviewVC) {
		guard let url = temporaryFiles.removeValue(forKey: ObjectIdentifier(controller)) else {
			return
		}
		ArchiveTemporaryFile.remove(containing: url)
	}

	func removeAllTemporaryFiles() {
		for url in temporaryFiles.values {
			ArchiveTemporaryFile.remove(containing: url)
		}
		temporaryFiles.removeAll()
	}
}
