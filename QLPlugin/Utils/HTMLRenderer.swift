import Foundation
import GlancePreviewCore

enum HTMLRendererError {
	case rendererError(fileType: String, errorMessage: String)
}

extension HTMLRendererError: LocalizedError {
	var errorDescription: String? {
		switch self {
			case let .rendererError(fileType, errorMessage):
				NSLocalizedString(
					"Could not convert \(fileType) to HTML: \(errorMessage)",
					comment: ""
				)
		}
	}
}

enum HTMLRenderer {
	/// Converts a code string to HTML with support for syntax highlighting.
	static func renderCode(_ source: String, lexer: String) throws -> String {
		let result = withUTF8Buffer(source) { sourcePointer, sourceLength in
			withUTF8Buffer(lexer) { lexerPointer, lexerLength in
				glance_render_code(
					sourcePointer,
					sourceLength,
					lexerPointer,
					lexerLength
				)
			}
		}
		return try makeHTMLString(fileType: "code", result: result)
	}

	/// Converts a Markdown string to HTML.
	static func renderMarkdown(_ source: String) throws -> String {
		let result = withUTF8Buffer(source) { sourcePointer, sourceLength in
			glance_render_markdown(sourcePointer, sourceLength)
		}
		return try makeHTMLString(fileType: "Markdown", result: result)
	}

	/// Converts a Jupyter Notebook JSON file to HTML.
	static func renderNotebook(_ source: String) throws -> String {
		let result = withUTF8Buffer(source) { sourcePointer, sourceLength in
			glance_render_notebook(sourcePointer, sourceLength)
		}
		return try makeHTMLString(fileType: "Jupyter Notebook", result: result)
	}

	private static func makeHTMLString(
		fileType: String,
		result: GlanceRenderResult
	) throws -> String {
		defer { glance_render_buffer_free(result.data, result.length) }

		guard result.length == 0 || result.data != nil else {
			throw HTMLRendererError.rendererError(
				fileType: fileType,
				errorMessage: "renderer returned an invalid buffer"
			)
		}

		let data = result.data.map { Data(bytes: $0, count: result.length) } ?? Data()
		guard let output = String(data: data, encoding: .utf8) else {
			throw HTMLRendererError.rendererError(
				fileType: fileType,
				errorMessage: "renderer returned invalid UTF-8"
			)
		}

		guard result.status == 0 else {
			throw HTMLRendererError.rendererError(
				fileType: fileType,
				errorMessage: output.isEmpty ? "renderer failed without details" : output
			)
		}
		return output
	}

	private static func withUTF8Buffer<Result>(
		_ string: String,
		body: (UnsafePointer<UInt8>?, Int) -> Result
	) -> Result {
		let bytes = Array(string.utf8)
		return bytes.withUnsafeBufferPointer { buffer in
			body(buffer.baseAddress, buffer.count)
		}
	}
}
