import Cocoa

struct SupportedFileSection: Equatable {
	let title: String
	let formats: [String]
	let summary: String
	let blurb: String
	let example: String
	let symbolName: String
	let formatNote: String?

	init(
		title: String,
		formats: [String],
		summary: String = "",
		blurb: String,
		example: String,
		symbolName: String,
		formatNote: String? = nil,
	) {
		self.title = title
		self.formats = formats
		self.summary = summary
		self.blurb = blurb
		self.example = example
		self.symbolName = symbolName
		self.formatNote = formatNote
	}

	var details: String {
		guard !formats.isEmpty else {
			return summary
		}
		var line = formats.joined(separator: ", ")
		if let formatNote {
			line += " \(formatNote)"
		}
		if !summary.isEmpty {
			line += " • \(summary)"
		}
		return line
	}
}

@MainActor
final class SupportedFilesWC: NSWindowController {
	static let shared = SupportedFilesWC()

	static let sections = [
		SupportedFileSection(
			title: "Audio",
			formats: [".flac"],
			summary: "Native playback with waveform overview",
			blurb: "Native playback with a waveform overview.",
			example: "field-recording.flac",
			symbolName: "waveform",
		),
		SupportedFileSection(
			title: "Source Code",
			formats: [
				".cpp", ".elrc", ".ini", ".js", ".jsonl", ".py",
				".swift", ".tmpl", ".toml", ".ts", ".ttml", ".yml",
			],
			blurb: "Syntax highlighting for these and many more.",
			example: "main.swift",
			symbolName: "chevron.left.forwardslash.chevron.right",
			formatNote: "and many more",
		),
		SupportedFileSection(
			title: "Markdown",
			formats: [".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".Rmd", ".qmd"],
			summary: "Mermaid diagrams",
			blurb: "Rendered locally, with Mermaid diagrams.",
			example: "notes.md",
			symbolName: "doc.text",
		),
		SupportedFileSection(
			title: "Diagrams",
			formats: [".drawio"],
			summary: "Uncompressed diagrams.net files",
			blurb: "Uncompressed diagrams.net files.",
			example: "architecture.drawio",
			symbolName: "flowchart",
		),
		SupportedFileSection(
			title: "Archive",
			formats: [".7z", ".ear", ".jar", ".rar", ".tar", ".tar.gz", ".tgz", ".war", ".zip"],
			blurb: "Browse entries without extracting the archive.",
			example: "release.zip",
			symbolName: "archivebox",
		),
		SupportedFileSection(
			title: "E-books",
			formats: [".epub"],
			summary: "DRM-free EPUB 2 and EPUB 3 books",
			blurb: "DRM-free EPUB 2 and EPUB 3 books.",
			example: "designing-data.epub",
			symbolName: "book",
		),
		SupportedFileSection(
			title: "Jupyter Notebook",
			formats: [".ipynb"],
			blurb: "Cells, outputs, and embedded images.",
			example: "analysis.ipynb",
			symbolName: "book.closed",
		),
		SupportedFileSection(
			title: "Tab-separated Values",
			formats: [".tab", ".tsv"],
			blurb: "Rows and columns, typed and aligned.",
			example: "measurements.tsv",
			symbolName: "tablecells",
		),
		SupportedFileSection(
			title: "Spreadsheet",
			formats: [".xlsx"],
			summary: "Values, dates, and every worksheet",
			blurb: "Values, dates, and every worksheet.",
			example: "budget.xlsx",
			symbolName: "tablecells.badge.ellipsis",
		),
		SupportedFileSection(
			title: "Database",
			formats: [".sqlite", ".sqlite3", ".db"],
			summary: "Read-only tables with typed columns",
			blurb: "Read-only tables with typed columns.",
			example: "library.sqlite",
			symbolName: "cylinder.split.1x2",
		),
		SupportedFileSection(
			title: "Structured Data",
			formats: [".json", ".plist", ".xml"],
			summary: "Collapsible trees, typed values, and truncation notices",
			blurb: "Collapsible trees, typed values, and truncation notices.",
			example: "settings.plist",
			symbolName: "curlybraces",
		),
		SupportedFileSection(
			title: "Folders",
			formats: [],
			summary: "Lazy trees with icons, thumbnails, 500-item pages, and Back navigation",
			blurb: "Lazy trees with icons, thumbnails, and pages of 500.",
			example: "Projects",
			symbolName: "folder",
		),
	]

	let categoryTableView = NSTableView(frame: .zero)
	let searchField = NSSearchField(frame: .zero)
	let detailTitleLabel = NSTextField(labelWithString: "")
	let detailSummaryLabel = NSTextField(wrappingLabelWithString: "")
	let formatsHeadingLabel = NSTextField(labelWithString: "Formats")
	let formatsValueLabel = NSTextField(wrappingLabelWithString: "")
	let exampleValueLabel = NSTextField(wrappingLabelWithString: "")
	let emptyStateLabel =
		NSTextField(wrappingLabelWithString: "No supported files match that search.")

	private let sidebarView = NSVisualEffectView()
	private let detailScrollView = NSScrollView()
	private let detailContentStack = NSStackView()
	private let symbolBadge = SymbolBadgeView()
	private let formatsSection = NSStackView()
	private var visibleSectionIndices = Array(SupportedFilesWC.sections.indices)
	private(set) var selectedSectionIndex: Int? = 0

	var isFormatsSectionVisible: Bool {
		!formatsSection.isHidden
	}

	var isDetailVisible: Bool {
		!detailScrollView.isHidden
	}

	init() {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false,
		)
		window.title = "Supported Files"
		window.titleVisibility = .hidden
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 560, height: 380)
		window.center()
		WindowAppearance.apply(to: window)
		WindowAppearance.hideMinimizeAndZoomButtons(on: window)
		WindowAppearance.track(window)

		super.init(window: window)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(windowWillClose),
			name: NSWindow.willCloseNotification,
			object: window,
		)
		setUpContent()
		categoryTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
		showSection(at: 0)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func showSupportedFilesWindow() {
		showWindow(nil)
		if let index = selectedSectionIndex,
		   let row = visibleSectionIndices.firstIndex(of: index)
		{
			categoryTableView.selectRowIndexes(
				IndexSet(integer: row),
				byExtendingSelection: false,
			)
			window?.makeFirstResponder(categoryTableView)
		}
		if let window {
			WindowAppearance.bringToFront(window)
		}
	}

	@objc
	private func windowWillClose(_: Notification) {
		DispatchQueue.main.async {
			WindowAppearance.refreshActivationPolicy()
		}
	}

	func selectSection(at index: Int) {
		guard Self.sections.indices.contains(index),
		      let row = visibleSectionIndices.firstIndex(of: index)
		else {
			return
		}
		categoryTableView.selectRowIndexes(
			IndexSet(integer: row),
			byExtendingSelection: false,
		)
		showSection(at: index)
	}

	// MARK: - Content Setup

	private func setUpContent() {
		guard let contentView = window?.contentView else {
			return
		}

		sidebarView.material = .sidebar
		sidebarView.blendingMode = .behindWindow
		sidebarView.state = .followsWindowActiveState
		sidebarView.translatesAutoresizingMaskIntoConstraints = false

		let divider = NSBox()
		divider.boxType = .custom
		divider.titlePosition = .noTitle
		divider.borderWidth = 0
		divider.cornerRadius = 0
		divider.fillColor = .separatorColor
		divider.translatesAutoresizingMaskIntoConstraints = false

		contentView.addSubview(sidebarView)
		contentView.addSubview(divider)
		contentView.addSubview(detailScrollView)
		contentView.addSubview(emptyStateLabel)

		NSLayoutConstraint.activate([
			sidebarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
			sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			sidebarView.widthAnchor.constraint(equalToConstant: 210),
			divider.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
			divider.topAnchor.constraint(equalTo: contentView.topAnchor),
			divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			divider.widthAnchor.constraint(equalToConstant: 1),
			detailScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
			detailScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			detailScrollView.topAnchor.constraint(
				equalTo: contentView.safeAreaLayoutGuide.topAnchor,
			),
			detailScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			emptyStateLabel.centerXAnchor.constraint(equalTo: detailScrollView.centerXAnchor),
			emptyStateLabel.centerYAnchor.constraint(equalTo: detailScrollView.centerYAnchor),
			emptyStateLabel.widthAnchor.constraint(
				lessThanOrEqualTo: detailScrollView.widthAnchor,
				constant: -60,
			),
		])

		setUpSidebar()
		setUpDetail()
	}

	private func setUpSidebar() {
		searchField.placeholderString = "Search"
		searchField.controlSize = .regular
		searchField.sendsSearchStringImmediately = true
		searchField.target = self
		searchField.action = #selector(searchChanged)
		searchField.setAccessibilityLabel("Search supported files")
		searchField.translatesAutoresizingMaskIntoConstraints = false

		categoryTableView.identifier = NSUserInterfaceItemIdentifier("SupportedFiles.Categories")
		categoryTableView.dataSource = self
		categoryTableView.delegate = self
		categoryTableView.headerView = nil
		categoryTableView.rowHeight = 30
		categoryTableView.intercellSpacing = NSSize(width: 0, height: 2)
		categoryTableView.backgroundColor = .clear
		categoryTableView.style = .plain
		categoryTableView.selectionHighlightStyle = .none
		categoryTableView.allowsEmptySelection = true
		categoryTableView.allowsMultipleSelection = false
		categoryTableView.focusRingType = .none
		categoryTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
		categoryTableView.addTableColumn(
			NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SupportedFiles.Category")),
		)
		categoryTableView.tableColumns[0].width = 190
		categoryTableView.setAccessibilityLabel("Supported file categories")
		categoryTableView.reloadData()

		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.documentView = categoryTableView
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		sidebarView.addSubview(searchField)
		sidebarView.addSubview(scrollView)

		NSLayoutConstraint.activate([
			searchField.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 10),
			searchField.trailingAnchor.constraint(
				equalTo: sidebarView.trailingAnchor,
				constant: -10,
			),
			searchField.topAnchor.constraint(
				equalTo: sidebarView.safeAreaLayoutGuide.topAnchor,
				constant: 10,
			),
			scrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 10),
			scrollView.trailingAnchor.constraint(
				equalTo: sidebarView.trailingAnchor,
				constant: -10,
			),
			scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
			scrollView.bottomAnchor.constraint(
				equalTo: sidebarView.safeAreaLayoutGuide.bottomAnchor,
				constant: -10,
			),
		])
	}

	private func setUpDetail() {
		detailScrollView.drawsBackground = false
		detailScrollView.hasVerticalScroller = true
		detailScrollView.autohidesScrollers = true
		detailScrollView.borderType = .noBorder
		detailScrollView.translatesAutoresizingMaskIntoConstraints = false

		detailTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
		detailTitleLabel.maximumNumberOfLines = 1
		detailSummaryLabel.font = .systemFont(ofSize: 12)
		detailSummaryLabel.textColor = .secondaryLabelColor
		detailSummaryLabel.maximumNumberOfLines = 0

		let titleStack = NSStackView(views: [detailTitleLabel, detailSummaryLabel])
		titleStack.orientation = .vertical
		titleStack.alignment = .leading
		titleStack.spacing = 3
		let header = NSStackView(views: [symbolBadge, titleStack])
		header.orientation = .horizontal
		header.alignment = .centerY
		header.spacing = 14
		detailSummaryLabel.widthAnchor.constraint(equalTo: titleStack.widthAnchor).isActive = true
		titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		formatsHeadingLabel.font = .systemFont(ofSize: 10, weight: .semibold)
		formatsHeadingLabel.textColor = .secondaryLabelColor
		formatsValueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		formatsValueLabel.textColor = .secondaryLabelColor
		formatsValueLabel.maximumNumberOfLines = 0
		let formatsWell = WellView(content: formatsValueLabel)
		let formatsContent = NSStackView(views: [formatsHeadingLabel, formatsWell])
		formatsContent.orientation = .vertical
		formatsContent.alignment = .leading
		formatsContent.spacing = 6
		formatsWell.widthAnchor.constraint(lessThanOrEqualTo: formatsContent.widthAnchor)
			.isActive = true
		formatsSection.addArrangedSubview(formatsContent)
		formatsSection.orientation = .vertical
		formatsSection.alignment = .leading
		formatsSection.spacing = 0
		formatsContent.widthAnchor.constraint(equalTo: formatsSection.widthAnchor).isActive = true

		exampleValueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		exampleValueLabel.textColor = .secondaryLabelColor
		exampleValueLabel.maximumNumberOfLines = 0
		let exampleWell = WellView(content: exampleValueLabel)

		let localLabel = NSTextField(
			labelWithString: "Previews are generated locally. Nothing is uploaded.",
		)
		localLabel.font = .systemFont(ofSize: 10)
		localLabel.textColor = .secondaryLabelColor

		detailContentStack.orientation = .vertical
		detailContentStack.alignment = .leading
		detailContentStack.spacing = 10
		for view in [header, formatsSection, exampleWell, localLabel] {
			detailContentStack.addArrangedSubview(view)
		}
		header.widthAnchor.constraint(equalTo: detailContentStack.widthAnchor).isActive = true
		formatsSection.widthAnchor.constraint(equalTo: detailContentStack.widthAnchor)
			.isActive = true
		exampleWell.widthAnchor.constraint(lessThanOrEqualTo: detailContentStack.widthAnchor)
			.isActive = true
		localLabel.widthAnchor.constraint(equalTo: detailContentStack.widthAnchor).isActive = true
		detailContentStack.setCustomSpacing(18, after: header)
		detailContentStack.setCustomSpacing(18, after: formatsSection)
		detailContentStack.setCustomSpacing(18, after: exampleWell)
		formatsSection.setContentHuggingPriority(.required, for: .vertical)

		let documentView = FlippedDocumentView()
		documentView.translatesAutoresizingMaskIntoConstraints = false
		detailContentStack.translatesAutoresizingMaskIntoConstraints = false
		documentView.addSubview(detailContentStack)
		detailScrollView.documentView = documentView

		NSLayoutConstraint.activate([
			documentView.leadingAnchor
				.constraint(equalTo: detailScrollView.contentView.leadingAnchor),
			documentView.trailingAnchor
				.constraint(equalTo: detailScrollView.contentView.trailingAnchor),
			documentView.topAnchor.constraint(equalTo: detailScrollView.contentView.topAnchor),
			documentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
			detailContentStack.leadingAnchor.constraint(
				equalTo: documentView.leadingAnchor,
				constant: 28,
			),
			detailContentStack.trailingAnchor.constraint(
				equalTo: documentView.trailingAnchor,
				constant: -28,
			),
			detailContentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
			detailContentStack.bottomAnchor.constraint(
				equalTo: documentView.bottomAnchor,
				constant: -26,
			),
		])

		emptyStateLabel.font = .systemFont(ofSize: 12)
		emptyStateLabel.textColor = .secondaryLabelColor
		emptyStateLabel.alignment = .center
		emptyStateLabel.maximumNumberOfLines = 0
		emptyStateLabel.isHidden = true
		emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
	}

	private func showSection(at index: Int) {
		guard Self.sections.indices.contains(index) else {
			showEmptyState()
			return
		}
		selectedSectionIndex = index
		let section = Self.sections[index]
		detailTitleLabel.stringValue = section.title
		detailTitleLabel.setAccessibilityLabel(section.title)
		detailSummaryLabel.stringValue = section.blurb
		detailSummaryLabel.setAccessibilityLabel(section.blurb)
		symbolBadge.update(
			symbolName: section.symbolName,
			accessibilityDescription: section.title,
		)
		formatsHeadingLabel.stringValue = section.formats.isEmpty ? "" : "Formats"
		formatsValueLabel.stringValue = section.formats.joined(separator: ", ")
		formatsValueLabel.setAccessibilityLabel(section.formats.joined(separator: ", "))
		formatsSection.isHidden = section.formats.isEmpty
		exampleValueLabel.stringValue = "Example · \(section.example)"
		exampleValueLabel.setAccessibilityLabel("Example \(section.example)")
		emptyStateLabel.isHidden = true
		detailScrollView.isHidden = false
		detailScrollView.contentView.scroll(to: .zero)
		detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
	}

	private func showEmptyState() {
		selectedSectionIndex = nil
		emptyStateLabel.isHidden = false
		detailScrollView.isHidden = true
	}

	@objc
	private func searchChanged(_ sender: NSSearchField) {
		let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
			.localizedLowercase
		if query.isEmpty {
			visibleSectionIndices = Array(Self.sections.indices)
		} else {
			visibleSectionIndices = Self.sections.indices.filter { index in
				let section = Self.sections[index]
				let haystack = [
					section.title,
					section.details,
					section.blurb,
					section.example,
					section.formats.joined(separator: " "),
				].joined(separator: " ").localizedLowercase
				return haystack.contains(query)
			}
		}
		categoryTableView.reloadData()

		let targetIndex: Int? = if
			let selectedSectionIndex,
			visibleSectionIndices.contains(selectedSectionIndex)
		{
			selectedSectionIndex
		} else {
			visibleSectionIndices.first
		}

		if let targetIndex, let row = visibleSectionIndices.firstIndex(of: targetIndex) {
			categoryTableView.selectRowIndexes(
				IndexSet(integer: row),
				byExtendingSelection: false,
			)
			showSection(at: targetIndex)
		} else {
			categoryTableView.deselectAll(nil)
			showEmptyState()
		}
	}
}

extension SupportedFilesWC: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		visibleSectionIndices.count
	}

	func tableView(
		_ tableView: NSTableView,
		viewFor _: NSTableColumn?,
		row: Int,
	) -> NSView? {
		let identifier = NSUserInterfaceItemIdentifier("SupportedFiles.Category.Cell")
		let cell = tableView.makeView(withIdentifier: identifier, owner: self)
			as? SupportedFilesSidebarCell ?? SupportedFilesSidebarCell()
		cell.identifier = identifier
		cell.configure(section: Self.sections[visibleSectionIndices[row]])
		return cell
	}

	func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
		SidebarSelectionRowView(frame: .zero)
	}

	func tableViewSelectionDidChange(_: Notification) {
		guard visibleSectionIndices.indices.contains(categoryTableView.selectedRow) else {
			return
		}
		showSection(at: visibleSectionIndices[categoryTableView.selectedRow])
	}
}

private final class SupportedFilesSidebarCell: NSTableCellView {
	private let iconView = NSImageView()
	private let titleLabel = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.imageScaling = .scaleProportionallyDown
		iconView.contentTintColor = .secondaryLabelColor
		titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(iconView)
		addSubview(titleLabel)
		imageView = iconView
		textField = titleLabel
		NSLayoutConstraint.activate([
			iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
			iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
			iconView.widthAnchor.constraint(equalToConstant: 15),
			iconView.heightAnchor.constraint(equalToConstant: 15),
			titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
			titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(section: SupportedFileSection) {
		titleLabel.stringValue = section.title
		iconView.image = NSImage(
			systemSymbolName: section.symbolName,
			accessibilityDescription: section.title,
		) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: section.title)
		setAccessibilityLabel(section.title)
	}

	override var backgroundStyle: NSView.BackgroundStyle {
		didSet {
			let isSelected = backgroundStyle == .emphasized
			titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
			iconView.contentTintColor = isSelected
				? .alternateSelectedControlTextColor
				: .secondaryLabelColor
		}
	}
}

private final class SymbolBadgeView: NSView {
	private let iconView = NSImageView()

	init() {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		widthAnchor.constraint(equalToConstant: 44).isActive = true
		heightAnchor.constraint(equalToConstant: 44).isActive = true
		iconView.imageScaling = .scaleProportionallyDown
		iconView.contentTintColor = .controlAccentColor
		iconView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(iconView)
		NSLayoutConstraint.activate([
			iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
			iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
			iconView.widthAnchor.constraint(equalToConstant: 22),
			iconView.heightAnchor.constraint(equalToConstant: 22),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func update(symbolName: String, accessibilityDescription: String) {
		iconView.image = NSImage(
			systemSymbolName: symbolName,
			accessibilityDescription: accessibilityDescription,
		) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: accessibilityDescription)
		setAccessibilityLabel(accessibilityDescription)
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func draw(_: NSRect) {
		let path = NSBezierPath(
			roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
			xRadius: 11,
			yRadius: 11,
		)
		NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
		path.fill()
		NSColor.controlAccentColor.withAlphaComponent(0.16).setStroke()
		path.lineWidth = 1
		path.stroke()
	}
}

private final class WellView: NSView {
	init(content: NSView) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func draw(_: NSRect) {
		let path = NSBezierPath(
			roundedRect: bounds,
			xRadius: 8,
			yRadius: 8,
		)
		NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
		path.fill()
	}
}

private final class FlippedDocumentView: NSView {
	override var isFlipped: Bool {
		true
	}
}
