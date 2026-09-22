import Foundation

/// Returns a `PreviewVC` subclass that can be used to generate a preview of the provided file.
/// Returns `nil` if the file type is not supported.
class PreviewVCFactory {
	static func getPreviewInitializer(fileURL: URL, isDirectory: Bool = false) -> Preview.Type? {
		if isDirectory {
			return DirectoryPreview.self
		}

		guard let entry = SupportedPreviewRegistry.entry(matching: fileURL) else {
			return nil
		}

		switch entry.previewFileType {
			case .drawIO:
				return DrawIOPreview.self
			case .markdown:
				return MarkdownPreview.self
			case .jupyter:
				return JupyterPreview.self
			case .rar:
				return RARPreview.self
			case .tar:
				return TARPreview.self
			case .threeMF:
				return ThreeMFPreview.self
			case .tsv:
				return TSVPreview.self
			case .sevenZip:
				return SevenZipPreview.self
			case .zip:
				return ZIPPreview.self
			case .code:
				return CodePreview.self
			case .unsupported:
				return nil
		}
	}
}
