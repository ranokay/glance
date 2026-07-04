import Cocoa

let feedbackURL = URL(string: "https://github.com/chamburr/glance/issues")!
let licenseURL = URL(string: "https://github.com/chamburr/glance/blob/main/LICENSE.md")!
let privacyPolicyURL = URL(string: "https://github.com/chamburr/glance/blob/main/PRIVACY.md")!
let websiteURL = URL(string: "https://github.com/chamburr/glance")!

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class SupportedFilesMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openSupportedFilesWindow)
	}

	@objc
	private func openSupportedFilesWindow() {
		SupportedFilesWC.shared.showSupportedFilesWindow()
	}
}

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class SettingsMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openSettingsWindow)
	}

	@objc
	private func openSettingsWindow() {
		SettingsWC.shared.showSettingsWindow()
	}
}

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class FeedbackMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openFeedback)
	}

	@objc
	private func openFeedback() {
		feedbackURL.open()
	}
}

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class LicenseMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openLicense)
	}

	@objc
	private func openLicense() {
		licenseURL.open()
	}
}

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class PrivacyPolicyMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openPrivacyPolicy)
	}

	@objc
	private func openPrivacyPolicy() {
		privacyPolicyURL.open()
	}
}

/// Used as a subclass for the menu item in Interface Builder
@MainActor
final class WebsiteMenuItem: NSMenuItem {
	required init(coder decoder: NSCoder) {
		super.init(coder: decoder)

		target = self
		action = #selector(openWebsite)
	}

	@objc
	private func openWebsite() {
		websiteURL.open()
	}
}
