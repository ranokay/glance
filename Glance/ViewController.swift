import Cocoa

class ViewController: NSViewController {
	override func viewWillAppear() {
		super.viewWillAppear()
		if let window = view.window {
			WindowAppearance.apply(to: window)
		}
	}

	@IBAction private func openSupportedFilesWindow(_: NSButton) {
		SupportedFilesWC.shared.showSupportedFilesWindow()
	}

	@IBAction private func openGitHubRepository(_: NSButton) {
		AppLinks.website.open()
	}
}
