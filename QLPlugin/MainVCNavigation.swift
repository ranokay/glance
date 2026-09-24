import Cocoa

extension MainVC {
	func installTopLevelPreview(_ previewVC: PreviewVC, file: File) {
		clearPreviewControllers()
		topLevelFile = file
		topLevelPreviewController = previewVC
		currentPreviewController = previewVC
		previewNavigationStack = [previewVC]
		if file.isDirectory, let outlinePreview = previewVC as? OutlinePreviewVC {
			folderPreviewController = outlinePreview
			outlinePreview.interactionDelegate = self
		}
		nestedOpenWithTargetURL = nil
		bindStatus(to: previewVC)
		show(previewVC)
		updateOpenWithTarget()
	}

	func pushPreview(_ previewVC: PreviewVC, openWithTargetURL: URL?) {
		if let outlinePreview = previewVC as? OutlinePreviewVC,
		   outlinePreview.isDirectoryBrowser
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
		currentPreviewController = previewVC
		nestedOpenWithTargetURL = openWithTargetURL
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
		currentPreviewController = previousController
		if let outlinePreview = previousController as? OutlinePreviewVC,
		   outlinePreview.isDirectoryBrowser
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
		currentPreviewController = nil
		topLevelPreviewController = nil
		folderPreviewController = nil
		nestedPreviewController = nil
		previewNavigationStack.removeAll()
		topLevelFile = nil
		selectedFolderNode = nil
		nestedOpenWithTargetURL = nil
		openWithTargetURL = nil
		refreshOpenWithMenu()
		setBaseStatus("")
		updateChrome()
	}
}
