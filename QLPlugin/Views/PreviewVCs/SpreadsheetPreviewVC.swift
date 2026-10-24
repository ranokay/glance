import Cocoa

final class SpreadsheetPreviewVC: NSViewController, PreviewVC, PreviewStatusProviding {
	let sheets: [SpreadsheetPreviewSheet]
	private(set) var sheetPopUpButton = NSPopUpButton()
	private(set) var tableView = NSTableView()
	private(set) var selectedSheetIndex = 0
	var previewStatusDidChange: (@MainActor (String) -> Void)?

	var previewStatusText: String {
		guard let sheet = selectedSheet else {
			return "Empty workbook"
		}
		return sheet.rowsTruncated || sheet.columnsTruncated
			? "\(sheet.name) — truncated"
			: sheet.name
	}

	private var selectedSheet: SpreadsheetPreviewSheet? {
		guard sheets.indices.contains(selectedSheetIndex) else {
			return nil
		}
		return sheets[selectedSheetIndex]
	}

	init(sheets: [SpreadsheetPreviewSheet]) {
		self.sheets = sheets
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
		reloadSheet()
	}

	private func setUpView() {
		let sheetLabel = NSTextField(labelWithString: "Sheet")
		sheetLabel.textColor = .secondaryLabelColor
		sheetLabel.setAccessibilityLabel("Worksheet")

		sheetPopUpButton.addItems(withTitles: sheets.map(\.name))
		sheetPopUpButton.target = self
		sheetPopUpButton.action = #selector(selectedSheetChanged(_:))
		sheetPopUpButton.setAccessibilityLabel("Worksheet")
		sheetPopUpButton.isEnabled = sheets.count > 1

		let header = NSStackView(views: [sheetLabel, sheetPopUpButton])
		header.orientation = .horizontal
		header.alignment = .centerY
		header.spacing = 8
		header.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(header)

		tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(scrollView)

		NSLayoutConstraint.activate([
			header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
			header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
			header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
			scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			sheetPopUpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
		])
	}

	@objc
	private func selectedSheetChanged(_ sender: NSPopUpButton) {
		guard sheets.indices.contains(sender.indexOfSelectedItem) else {
			return
		}
		selectedSheetIndex = sender.indexOfSelectedItem
		reloadSheet()
		previewStatusDidChange?(previewStatusText)
	}

	private func reloadSheet() {
		tableView.tableColumns.forEach(tableView.removeTableColumn)

		let columnCount = max(
			1,
			selectedSheet?.rows.map(\.count).max() ?? 0,
		)
		for index in 0 ..< columnCount {
			let column = NSTableColumn(
				identifier: NSUserInterfaceItemIdentifier("column-\(index)"),
			)
			column.title = Self.columnName(for: index)
			column.width = contentWidth(for: index)
			column.minWidth = 40
			column.resizingMask = [.autoresizingMask, .userResizingMask]
			tableView.addTableColumn(column)
		}
		tableView.reloadData()
	}

	private func contentWidth(for columnIndex: Int) -> CGFloat {
		let rowLengths = selectedSheet?.rows.prefix(200).compactMap { row in
			row.indices.contains(columnIndex) ? row[columnIndex].count : 0
		} ?? []
		let longest = rowLengths.max() ?? 0
		return min(max(CGFloat(longest) * 7 + 24, 60), 400)
	}

	private static func columnName(for index: Int) -> String {
		var value = index
		var name = ""
		repeat {
			let scalar = UnicodeScalar(65 + value % 26) ?? UnicodeScalar(65)!
			name = String(scalar) + name
			value = value / 26 - 1
		} while value >= 0
		return name
	}
}

extension SpreadsheetPreviewVC: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		guard let sheet = selectedSheet else {
			return 0
		}
		return sheet.rows.count + (sheet.rowsTruncated || sheet.columnsTruncated ? 1 : 0)
	}

	func tableView(
		_: NSTableView,
		viewFor tableColumn: NSTableColumn?,
		row rowIndex: Int,
	) -> NSView? {
		guard let tableColumn, let sheet = selectedSheet else {
			return nil
		}
		let columnIndex = Int(tableColumn.identifier.rawValue.dropFirst("column-".count)) ?? 0
		if sheet.rowsTruncated || sheet.columnsTruncated, rowIndex == sheet.rows.count {
			guard columnIndex == 0 else {
				return NSTextField(labelWithString: "")
			}
			let notice = NSTextField(labelWithString: truncationNotice(for: sheet))
			notice.textColor = .secondaryLabelColor
			return notice
		}

		let row = sheet.rows[rowIndex]
		let value = row.indices.contains(columnIndex) ? row[columnIndex] : ""
		let textField = NSTextField(labelWithString: value)
		textField.lineBreakMode = .byTruncatingTail
		textField.maximumNumberOfLines = 1
		textField.toolTip = value.isEmpty ? nil : value
		return textField
	}

	private func truncationNotice(for sheet: SpreadsheetPreviewSheet) -> String {
		var parts = [String]()
		if sheet.rowsTruncated {
			parts.append("the first \(sheet.rows.count) rows")
		}
		if sheet.columnsTruncated {
			parts.append("the first \(sheet.rows.map(\.count).max() ?? 0) columns")
		}
		return "Showing \(parts.joined(separator: " and "))."
	}
}
