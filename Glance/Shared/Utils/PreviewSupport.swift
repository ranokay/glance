import Foundation

public enum PreviewFileType: Equatable, Sendable {
	case code
	case drawIO
	case epub
	case flac
	case jupyter
	case markdown
	case rar
	case sevenZip
	case tar
	case threeMF
	case tsv
	case unsupported
	case zip
}

public enum PreviewSupport {
	public static func getCodeLexer(fileURL: URL) -> String {
		// Recurse through .dist wrapper extensions
		if fileURL.pathExtension.lowercased() == "dist" {
			return getCodeLexer(fileURL: fileURL.deletingPathExtension())
		}

		// Use the registry's codeLexer when available
		if let entry = SupportedPreviewRegistry.entry(matching: fileURL),
		   let lexer = entry.codeLexer
		{
			return lexer
		}

		// Fall back to extension name or autodetect for unknown files
		return fileURL.pathExtension.isEmpty ? "autodetect" : fileURL.pathExtension
	}

	public static func getPreviewFileType(fileURL: URL) -> PreviewFileType {
		SupportedPreviewRegistry.entry(matching: fileURL)?.previewFileType ?? .unsupported
	}

	/// Whether the file is streamed audio exempt from the size limit and routed to media playback.
	public static func isStreamedAudio(fileURL: URL) -> Bool {
		getPreviewFileType(fileURL: fileURL) == .flac
	}
}
