import Cocoa

struct SupportedFileSection: Equatable {
	let title: String
	let details: String
}

@MainActor
final class SupportedFilesWC: NSWindowController {
	static let shared = SupportedFilesWC()

	static let sections = [
		SupportedFileSection(
			title: "Source Code",
			details: ".cpp, .elrc, .ini, .js, .json, .py, .swift, .toml, .ttml, .yml and many more"
		),
		SupportedFileSection(
			title: "Markdown",
			details: ".md, .markdown, .mdown, .mkdn, .mkd, .Rmd, .qmd"
		),
		SupportedFileSection(
			title: "Archive",
			details: ".7z, .ear, .jar, .tar, .tar.gz, .tgz, .war, .zip"
		),
		SupportedFileSection(title: "Jupyter Notebook", details: ".ipynb"),
		SupportedFileSection(title: "Tab-separated Values", details: ".tab, .tsv"),
		SupportedFileSection(
			title: "Folders",
			details: "Lazy trees with icons, thumbnails, 500-item pages, and Back navigation"
		),
	]

	let sectionsStackView = NSStackView()

	init() {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "Supported Files"
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 420, height: 300)
		window.center()
		WindowAppearance.apply(to: window)

		super.init(window: window)
		setUpContent()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func showSupportedFilesWindow() {
		NSApp.activate()
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
	}

	private func setUpContent() {
		guard let contentView = window?.contentView else {
			return
		}

		sectionsStackView.orientation = .vertical
		sectionsStackView.alignment = .centerX
		sectionsStackView.spacing = 22
		sectionsStackView.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
		sectionsStackView.translatesAutoresizingMaskIntoConstraints = false

		for section in Self.sections {
			let sectionView = makeSectionView(section)
			sectionsStackView.addArrangedSubview(sectionView)
			sectionView.widthAnchor.constraint(
				equalTo: sectionsStackView.widthAnchor,
				constant: -56
			).isActive = true
		}

		let scrollView = NSScrollView()
		scrollView.identifier = NSUserInterfaceItemIdentifier("SupportedFiles.ScrollView")
		scrollView.borderType = .noBorder
		scrollView.drawsBackground = false
		scrollView.hasHorizontalScroller = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = sectionsStackView
		contentView.addSubview(scrollView)

		let clipView = scrollView.contentView
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			sectionsStackView.topAnchor.constraint(equalTo: clipView.topAnchor),
			sectionsStackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
			sectionsStackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
			sectionsStackView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
		])
	}

	private func makeSectionView(_ section: SupportedFileSection) -> NSStackView {
		let titleLabel = NSTextField(labelWithString: section.title)
		titleLabel.identifier = NSUserInterfaceItemIdentifier(
			"SupportedFiles.\(section.title).Title"
		)
		titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
		titleLabel.alignment = .center
		titleLabel.setAccessibilityLabel(section.title)

		let detailsLabel = NSTextField(wrappingLabelWithString: section.details)
		detailsLabel.identifier = NSUserInterfaceItemIdentifier(
			"SupportedFiles.\(section.title).Details"
		)
		detailsLabel.alignment = .center
		detailsLabel.maximumNumberOfLines = 0
		detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		detailsLabel.setAccessibilityLabel(section.details)

		let sectionView = NSStackView(views: [titleLabel, detailsLabel])
		sectionView.orientation = .vertical
		sectionView.alignment = .centerX
		sectionView.spacing = 5
		sectionView.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			titleLabel.widthAnchor.constraint(lessThanOrEqualTo: sectionView.widthAnchor),
			detailsLabel.widthAnchor.constraint(lessThanOrEqualTo: sectionView.widthAnchor),
		])
		return sectionView
	}
}
