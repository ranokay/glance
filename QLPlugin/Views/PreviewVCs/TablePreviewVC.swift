import Cocoa

class TablePreviewVC: NSViewController, PreviewVC {
	let headers: [String]
	let cells: [[String: String]]
	let truncated: Bool

	@IBOutlet private var tableView: NSTableView!

	required convenience init(headers: [String], cells: [[String: String]]) {
		self.init(nibName: nil, bundle: nil, headers: headers, cells: cells)
	}

	convenience init(
		headers: [String],
		cells: [[String: String]],
		truncated: Bool,
	) {
		self.init(
			nibName: nil,
			bundle: nil,
			headers: headers,
			cells: cells,
			truncated: truncated,
		)
	}

	init(
		nibName nibNameOrNil: NSNib.Name?,
		bundle nibBundleOrNil: Bundle?,
		headers: [String],
		cells: [[String: String]],
		truncated: Bool = false,
	) {
		self.headers = headers
		self.cells = cells
		self.truncated = truncated
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setUpView()
		deleteDefaultColumns()
		createColumns()
	}

	private func setUpView() {
		tableView.delegate = self
		tableView.dataSource = self
	}

	/// Deletes all columns created by default using Interface Builder.
	private func deleteDefaultColumns() {
		while !tableView.tableColumns.isEmpty {
			if let column = tableView.tableColumns.first {
				tableView.removeTableColumn(column)
			}
		}
	}

	/// Creates table columns for all headers.
	private func createColumns() {
		for header in headers {
			let columnID = NSUserInterfaceItemIdentifier(rawValue: header)
			let column = NSTableColumn(identifier: columnID)
			column.title = header
			column.minWidth = 50
			column.maxWidth = 500
			tableView.addTableColumn(column)
		}
	}
}

extension TablePreviewVC: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		cells.count + (truncated ? 1 : 0)
	}

	/// Fills the table with the `tableData`.
	func tableView(
		_: NSTableView,
		viewFor tableColumn: NSTableColumn?,
		row rowIndex: Int,
	) -> NSView? {
		guard let tableColumn else {
			return nil
		}

		let textField = NSTextField()
		textField.isEditable = false
		textField.isBordered = false
		textField.drawsBackground = false
		textField.lineBreakMode = .byTruncatingTail

		if truncated, rowIndex == cells.count {
			// Informational tail row (the DirectoryPreview loadMore-row
			// convention): the first column carries the notice, the rest stay
			// empty.
			if tableColumn.identifier.rawValue == headers.first {
				textField.stringValue = "Showing the first \(cells.count) rows."
			}
			textField.textColor = .secondaryLabelColor
			return textField
		}

		let row = cells[rowIndex]
		textField.stringValue = row[tableColumn.identifier.rawValue] ?? ""

		return textField
	}
}
