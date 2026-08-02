import AppKit

@MainActor
enum WindowAppearance {
	private static let materialViewIdentifier = NSUserInterfaceItemIdentifier(
		"Glance.WindowMaterial"
	)

	@discardableResult
	static func apply(to window: NSWindow) -> NSVisualEffectView? {
		window.styleMask.insert(.fullSizeContentView)
		window.titlebarAppearsTransparent = true
		window.backgroundColor = .clear
		window.isOpaque = false

		guard let contentView = window.contentView else {
			return nil
		}
		if let existingMaterialView = contentView.subviews.first(where: {
			$0.identifier == materialViewIdentifier
		}) as? NSVisualEffectView {
			return existingMaterialView
		}

		let materialView = NSVisualEffectView()
		materialView.identifier = materialViewIdentifier
		materialView.material = .underWindowBackground
		materialView.blendingMode = .behindWindow
		materialView.state = .followsWindowActiveState
		materialView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(materialView, positioned: .below, relativeTo: nil)
		NSLayoutConstraint.activate([
			materialView.topAnchor.constraint(equalTo: contentView.topAnchor),
			materialView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			materialView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			materialView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
		])
		return materialView
	}
}
