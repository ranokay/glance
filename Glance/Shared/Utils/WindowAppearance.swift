import AppKit

@MainActor
enum WindowAppearance {
	private static let materialViewIdentifier = NSUserInterfaceItemIdentifier(
		"Glance.WindowMaterial",
	)
	private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()

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

	static func track(_ window: NSWindow) {
		trackedWindows.add(window)
	}

	static func refreshActivationPolicy() {
		let hasOpenWindow = trackedWindows.allObjects.contains {
			$0.isVisible || $0.isMiniaturized
		}
		NSApp.setActivationPolicy(hasOpenWindow ? .regular : .accessory)
	}

	static func hideMinimizeAndZoomButtons(on window: NSWindow) {
		window.standardWindowButton(.miniaturizeButton)?.isHidden = true
		window.standardWindowButton(.zoomButton)?.isHidden = true
	}

	static func bringToFront(_ window: NSWindow) {
		trackedWindows.add(window)
		NSApp.setActivationPolicy(.regular)
		window.collectionBehavior.insert(.moveToActiveSpace)
		if window.isMiniaturized {
			window.deminiaturize(nil)
		}
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		window.orderFrontRegardless()
		window.makeKey()
		DispatchQueue.main.async {
			NSApp.activate(ignoringOtherApps: true)
			NSRunningApplication.current.activate(options: [.activateAllWindows])
			window.makeKeyAndOrderFront(nil)
			window.makeKey()
		}
	}
}

/// Source-list rows use the same inset capsule selection as modern AppKit
/// sidebars, including when the window becomes inactive.
final class SidebarSelectionRowView: NSTableRowView {
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		selectionHighlightStyle = .none
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var interiorBackgroundStyle: NSView.BackgroundStyle {
		isSelected && isEmphasized ? .emphasized : .normal
	}

	override var isSelected: Bool {
		didSet { updateSelectionAppearance() }
	}

	override var isEmphasized: Bool {
		didSet { updateSelectionAppearance() }
	}

	override func didAddSubview(_ subview: NSView) {
		super.didAddSubview(subview)
		updateSelectionAppearance()
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func drawBackground(in _: NSRect) {}

	override func drawSelection(in _: NSRect) {}

	override func draw(_: NSRect) {
		guard isSelected else {
			return
		}
		let path = NSBezierPath(
			roundedRect: bounds.insetBy(dx: 2, dy: 3),
			xRadius: 7,
			yRadius: 7,
		)
		if isEmphasized {
			NSColor.controlAccentColor.setFill()
		} else {
			NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
		}
		path.fill()
	}

	private func updateSelectionAppearance() {
		needsDisplay = true
		let style: NSView.BackgroundStyle =
			isSelected && isEmphasized ? .emphasized : .normal
		for case let cell as NSTableCellView in subviews {
			cell.backgroundStyle = style
		}
	}
}
