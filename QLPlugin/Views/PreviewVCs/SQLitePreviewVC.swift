import Cocoa
import GlanceKit

final class SQLitePreviewVC: NSViewController, PreviewVC, PreviewStatusProviding {
	let fileURL: URL
	private(set) var tables: [String]
	private(set) var tablesTruncated: Bool
	private(set) var tablePopUpButton = NSPopUpButton()
	private(set) var tableView = NSTableView()
	private(set) var previousButton = NSButton()
	private(set) var nextButton = NSButton()
	private(set) var pageLabel = NSTextField(labelWithString: "")
	private(set) var currentTable: SQLitePreviewTable?
	var previewStatusDidChange: (@MainActor (String) -> Void)?

	private let emptyLabel = NSTextField(labelWithString: "No tables in this database")
	private let noticeLabel = NSTextField(labelWithString: "")
	private var offsetHistory: [UInt64] = []
	private var loadGeneration = 0
	private var isLoading = false
	private var loadFailed = false

	private enum PageIntent {
		case selectTable
		case next(from: UInt64)
		case previous
	}

	var previewStatusText: String {
		guard let table = currentTable else {
			return "No tables"
		}
		var parts = [table.name]
		if table.rows.isEmpty {
			parts.append("empty")
		} else {
			parts.append("rows \(rowRangeText(for: table))\(table.hasMore ? "+" : "")")
		}
		if table.pageTruncated || table.columnsTruncated || table.valuesTruncated {
			parts.append("truncated")
		}
		if tablesTruncated {
			parts.append("table list truncated")
		}
		return parts.joined(separator: " — ")
	}

	init(fileURL: URL, payload: SQLitePreviewPayload) {
		self.fileURL = fileURL
		tables = payload.tables
		tablesTruncated = payload.tablesTruncated
		currentTable = payload.table
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = PreviewBackgroundView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setUpView()
		rebuildTablePicker()
		rebuildTable()
		updateControls()
	}

	private func setUpView() {
		let tableLabel = NSTextField(labelWithString: "Table")
		tableLabel.textColor = .secondaryLabelColor
		tableLabel.setAccessibilityLabel("Table")

		tablePopUpButton.target = self
		tablePopUpButton.action = #selector(selectedTableChanged(_:))
		tablePopUpButton.setAccessibilityLabel("Table")
		tablePopUpButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		previousButton = NSButton(
			title: "Previous",
			target: self,
			action: #selector(previousPage(_:)),
		)
		previousButton.bezelStyle = .rounded
		previousButton.setAccessibilityLabel("Previous rows")

		nextButton = NSButton(
			title: "Next",
			target: self,
			action: #selector(nextPage(_:)),
		)
		nextButton.bezelStyle = .rounded
		nextButton.setAccessibilityLabel("Next rows")

		pageLabel.textColor = .secondaryLabelColor
		pageLabel.alignment = .center
		pageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		noticeLabel.textColor = .secondaryLabelColor
		noticeLabel.maximumNumberOfLines = 0
		noticeLabel.lineBreakMode = .byWordWrapping
		noticeLabel.isHidden = true

		let header = NSStackView(
			views: [tableLabel, tablePopUpButton, previousButton, pageLabel, nextButton],
		)
		header.orientation = .horizontal
		header.alignment = .centerY
		header.spacing = 8
		header.translatesAutoresizingMaskIntoConstraints = false

		tableView.columnAutoresizingStyle = .noColumnAutoresizing
		tableView.usesAlternatingRowBackgroundColors = true
		tableView.gridStyleMask = .solidVerticalGridLineMask
		tableView.selectionHighlightStyle = .none
		tableView.headerView = NSTableHeaderView()
		tableView.dataSource = self
		tableView.delegate = self

		let scrollView = NSScrollView()
		scrollView.hasHorizontalScroller = true
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.drawsBackground = false
		scrollView.documentView = tableView
		scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
		scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

		let content = NSStackView(views: [header, noticeLabel, scrollView])
		content.orientation = .vertical
		content.alignment = .leading
		content.spacing = 8
		content.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(content)

		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(emptyLabel)

		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
			content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
			content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
			content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			header.widthAnchor.constraint(equalTo: content.widthAnchor),
			noticeLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
			scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
			scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
			tablePopUpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
			pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
			emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
			emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
		])
	}

	@objc
	private func selectedTableChanged(_ sender: NSPopUpButton) {
		guard tables.indices.contains(sender.indexOfSelectedItem) else {
			return
		}
		requestPage(
			table: tables[sender.indexOfSelectedItem],
			offset: 0,
			intent: .selectTable,
		)
	}

	@objc
	private func previousPage(_: NSButton) {
		guard let offset = offsetHistory.last else {
			return
		}
		requestPage(table: currentTable?.name, offset: offset, intent: .previous)
	}

	@objc
	private func nextPage(_: NSButton) {
		guard let table = currentTable, table.hasMore, !table.rows.isEmpty else {
			return
		}
		requestPage(
			table: table.name,
			offset: table.offset + UInt64(table.rows.count),
			intent: .next(from: table.offset),
		)
	}

	private func requestPage(table: String?, offset: UInt64, intent: PageIntent) {
		Task { @MainActor in
			guard await loadPage(table: table, offset: offset) else {
				return
			}
			switch intent {
				case .selectTable:
					offsetHistory.removeAll()
				case let .next(from):
					offsetHistory.append(from)
				case .previous:
					_ = offsetHistory.popLast()
			}
			updateControls()
		}
	}

	private func loadPage(table: String?, offset: UInt64) async -> Bool {
		loadGeneration += 1
		let generation = loadGeneration
		isLoading = true
		loadFailed = false
		updateControls()
		defer {
			if generation == loadGeneration {
				isLoading = false
				updateControls()
			}
		}

		let fileURL = fileURL
		do {
			let payload = try await PreviewExecutor.run {
				try PreviewCoreBridge.parseSQLite(at: fileURL, table: table, offset: offset)
			}
			try Task.checkCancellation()
			guard generation == loadGeneration else {
				return false
			}
			apply(payload)
			return true
		} catch is CancellationError {
			return false
		} catch {
			guard generation == loadGeneration else {
				return false
			}
			Log.general.error(
				"Could not read SQLite preview for \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)",
			)
			loadFailed = true
			if let name = currentTable?.name {
				selectTable(named: name)
			}
			return false
		}
	}

	private func apply(_ payload: SQLitePreviewPayload) {
		loadFailed = false
		if payload.tables != tables || payload.tablesTruncated != tablesTruncated {
			tables = payload.tables
			tablesTruncated = payload.tablesTruncated
			rebuildTablePicker()
		}
		currentTable = payload.table
		if let table = payload.table {
			selectTable(named: table.name)
		}
		rebuildTable()
		updateControls()
		previewStatusDidChange?(previewStatusText)
	}

	private func rebuildTablePicker() {
		tablePopUpButton.removeAllItems()
		tablePopUpButton.addItems(withTitles: tables)
		if tablesTruncated {
			tablePopUpButton.addItem(
				withTitle: "Showing the first \(tables.count) tables",
			)
			tablePopUpButton.item(at: tablePopUpButton.numberOfItems - 1)?.isEnabled = false
		}
		tablePopUpButton.isEnabled = tables.count > 1
		if let name = currentTable?.name {
			selectTable(named: name)
		}
	}

	private func selectTable(named name: String) {
		guard let index = tables.firstIndex(of: name) else {
			return
		}
		tablePopUpButton.selectItem(at: index)
	}

	private func rebuildTable() {
		tableView.tableColumns.forEach(tableView.removeTableColumn)
		guard let table = currentTable else {
			tableView.reloadData()
			return
		}
		for (index, column) in table.columns.enumerated() {
			let tableColumn = NSTableColumn(identifier: .init("column-\(index)"))
			tableColumn.title = columnTitle(for: column)
			tableColumn.headerToolTip = column.declaredType.map { "Declared type: \($0)" }
				?? "No declared type"
			tableColumn.width = contentWidth(for: index, column: column, rows: table.rows)
			tableColumn.minWidth = 60
			tableColumn.maxWidth = 320
			tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
			tableView.addTableColumn(tableColumn)
		}
		tableView.reloadData()
	}

	private func columnTitle(for column: SQLitePreviewColumn) -> String {
		column.declaredType.map { "\(column.name) (\($0))" } ?? column.name
	}

	private func contentWidth(
		for index: Int,
		column: SQLitePreviewColumn,
		rows: [[SQLitePreviewCell]],
	) -> CGFloat {
		var longest = columnTitle(for: column).count
		for row in rows.prefix(20) where row.indices.contains(index) {
			longest = max(longest, displayText(for: row[index]).count)
		}
		return min(max(CGFloat(longest) * 7 + 24, 70), 320)
	}

	private func displayText(for cell: SQLitePreviewCell) -> String {
		switch cell.kind {
			case .null:
				"NULL"
			case .blob:
				"BLOB (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: cell.byteCount ?? 0), countStyle: .file)))"
			case .integer, .real, .text:
				cell.text
		}
	}

	private func updateControls() {
		let hasTable = currentTable != nil
		tablePopUpButton.isEnabled = hasTable && tables.count > 1 && !isLoading
		previousButton.isEnabled = hasTable && !offsetHistory.isEmpty && !isLoading
		nextButton.isEnabled = hasTable && (currentTable?.hasMore ?? false) && !isLoading
		emptyLabel.isHidden = hasTable
		if isLoading {
			pageLabel.stringValue = "Loading…"
		} else if loadFailed {
			pageLabel.stringValue = "Couldn’t load page"
		} else if let table = currentTable {
			pageLabel.stringValue = table.rows.isEmpty
				? "No rows"
				: "Rows \(rowRangeText(for: table))"
		} else {
			pageLabel.stringValue = ""
		}
		updateFooterNotice()
	}

	private func rowRangeText(for table: SQLitePreviewTable) -> String {
		"\(table.offset + 1)–\(table.offset + UInt64(table.rows.count))"
	}

	private func updateFooterNotice() {
		guard let table = currentTable,
		      table.pageTruncated || table.columnsTruncated || table.valuesTruncated
		      || table.virtualColumnsOmitted
		else {
			noticeLabel.stringValue = ""
			noticeLabel.isHidden = true
			return
		}
		noticeLabel.stringValue = footerNotice(for: table)
		noticeLabel.isHidden = false
	}

	private func footerNotice(for table: SQLitePreviewTable) -> String {
		var sentences = [String]()
		if table.pageTruncated {
			sentences.append("Showing \(table.rows.count) rows on this page.")
		}
		if table.columnsTruncated {
			sentences.append("Showing the first \(table.columns.count) columns.")
		}
		if table.valuesTruncated {
			sentences.append("Long values are clipped.")
		}
		if table.virtualColumnsOmitted {
			sentences.append("Virtual generated columns are omitted.")
		}
		return sentences.joined(separator: " ")
	}
}

extension SQLitePreviewVC: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		currentTable?.rows.count ?? 0
	}

	func tableView(
		_: NSTableView,
		viewFor tableColumn: NSTableColumn?,
		row rowIndex: Int,
	) -> NSView? {
		guard let tableColumn, let table = currentTable else {
			return nil
		}
		let columnIndex = Int(tableColumn.identifier.rawValue.dropFirst("column-".count)) ?? 0
		guard table.rows.indices.contains(rowIndex),
		      table.rows[rowIndex].indices.contains(columnIndex)
		else {
			return NSTextField(labelWithString: "")
		}
		return cellView(for: table.rows[rowIndex][columnIndex])
	}

	private func cellView(for cell: SQLitePreviewCell) -> NSView {
		let textField = NSTextField(labelWithString: "")
		textField.lineBreakMode = .byTruncatingTail
		textField.maximumNumberOfLines = 1
		switch cell.kind {
			case .null:
				textField.attributedStringValue = NSAttributedString(
					string: "NULL",
					attributes: [
						.foregroundColor: NSColor.tertiaryLabelColor,
						.font: NSFontManager.shared.convert(
							NSFont.systemFont(ofSize: NSFont.systemFontSize),
							toHaveTrait: .italicFontMask,
						),
					],
				)
			case .blob:
				textField.stringValue = displayText(for: cell)
				textField.textColor = .secondaryLabelColor
			case .integer, .real, .text:
				textField.stringValue = cell.text
				textField.toolTip = cell.text.isEmpty ? nil : cell.text
		}
		return textField
	}
}
