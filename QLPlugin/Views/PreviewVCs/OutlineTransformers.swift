import Cocoa

/// `ValueTransformer` which formats the provided date.
class DateTransformer: ValueTransformer {
	let dateFormatter = DateFormatter()
	let fallbackValue = "--"

	override init() {
		// Use same date format as Finder
		dateFormatter.dateStyle = .medium
		dateFormatter.timeStyle = .short
		dateFormatter.doesRelativeDateFormatting = true
	}

	override class func transformedValueClass() -> AnyClass {
		NSString.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let date = value as? Date else {
			return nil
		}

		// Dates which are `nil` are passed to this function as epoch dates (default value). If
		// this is the case, return "--" instead (same behavior as Finder)
		return date.timeIntervalSince1970 == 0 ? fallbackValue : dateFormatter.string(from: date)
	}
}

protocol FileIconProviding {
	func icon(for fileURL: URL) -> NSImage
}

final class WorkspaceFileIconProvider: FileIconProviding {
	func icon(for fileURL: URL) -> NSImage {
		NSWorkspace.shared.icon(forFile: fileURL.path)
	}
}

/// `ValueTransformer` which returns a thumbnail, file-specific icon, or generic fallback icon.
class IconTransformer: ValueTransformer {
	private static let directoryIcon = NSWorkspace.shared.icon(for: .folder)
	private static let fileIcon = NSWorkspace.shared.icon(for: .data)
	private let fileIconProvider: FileIconProviding

	override convenience init() {
		self.init(fileIconProvider: WorkspaceFileIconProvider())
	}

	init(fileIconProvider: FileIconProviding) {
		self.fileIconProvider = fileIconProvider
		super.init()
	}

	override class func transformedValueClass() -> AnyClass {
		NSImage.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let node = value as? FileTreeNode else {
			return nil
		}
		if let icon = node.icon {
			return icon
		}
		if let fileURL = node.fileURL {
			return fileIconProvider.icon(for: fileURL)
		}
		return node.isDirectory ? Self.directoryIcon : Self.fileIcon
	}
}

/// `ValueTransformer` which formats the provided number of bytes as a human-readable string (e.g.
/// `12345` -> `"12.345 KB"` or `0` -> `"--"`).
class SizeTransformer: ValueTransformer {
	let byteCountFormatter = ByteCountFormatter()
	let fallbackValue = "--"

	override class func transformedValueClass() -> AnyClass {
		NSString.self
	}

	override class func allowsReverseTransformation() -> Bool {
		false
	}

	override func transformedValue(_ value: Any?) -> Any? {
		guard let size = value as? NSNumber else {
			return nil
		}

		// Format number of bytes in human-readable way. If the size is 0 bytes, return "--" instead
		// (same behavior as Finder)
		return size == 0 ? fallbackValue : (byteCountFormatter.string(for: size) ?? fallbackValue)
	}
}

extension NSValueTransformerName {
	static let dateTransformerName = NSValueTransformerName(rawValue: "DateTransformer")
	static let iconTransformerName = NSValueTransformerName(rawValue: "IconTransformer")
	static let sizeTransformerName = NSValueTransformerName(rawValue: "SizeTransformer")
}
