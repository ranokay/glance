import Foundation
import GlanceKit

class StructuredPreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css",
	)
	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "structured-main",
		withExtension: "css",
	)

	required init() {}

	private func getStylesheets() -> [Stylesheet] {
		var stylesheets = [Stylesheet]()

		if let mainStylesheetURL {
			stylesheets.append(Stylesheet(url: mainStylesheetURL))
		} else {
			Log.render.error("Could not find main structured preview stylesheet")
		}

		// Also styles the highlighted-text fallback for malformed input.
		if let chromaStylesheetURL {
			stylesheets.append(Stylesheet(url: chromaStylesheetURL))
		} else {
			Log.render.error("Could not find syntax-highlighting stylesheet")
		}

		return stylesheets
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		do {
			let content = try await makeContent(fileURL: fileURL)
			return await WebPreviewVC(
				content: content,
				appearancePreferences: PreviewSettingsClient.shared.appearancePreferences(),
				contentLoader: { try await self.makeContent(fileURL: fileURL) },
			)
		} catch let error as CancellationError {
			throw error
		} catch {
			Log.render.error(
				"Could not generate structured preview HTML: \(error.localizedDescription, privacy: .private)",
			)
			throw error
		}
	}

	@MainActor
	private func makeContent(fileURL: URL) async throws -> WebPreviewContent {
		let format = structuredFormat(for: fileURL)
		let data = try await PreviewExecutor.run {
			try Data(contentsOf: fileURL)
		}

		let html: String
		do {
			html = try await PreviewExecutor.run {
				try HTMLRenderer.renderStructured(data, format: format)
			}
		} catch let error as CancellationError {
			throw error
		} catch {
			// Malformed input must stay readable, so degrade to the highlighted text preview.
			let lexer = PreviewSupport.getCodeLexer(fileURL: fileURL)
			html = try await PreviewExecutor.run {
				// Binary property lists do not decode as UTF-8; the lossy fallback keeps the
				// malformed-input page readable instead of failing it.
				// swiftlint:disable:next optional_data_string_conversion
				let source = String(decoding: data, as: UTF8.self)
				return try HTMLRenderer.renderCode(source, lexer: lexer)
			}
		}

		return WebPreviewContent(html: html, stylesheets: getStylesheets())
	}

	/// The registry only routes `.json`, `.plist`, and `.xml` files to this preview.
	private func structuredFormat(for fileURL: URL) -> StructuredPreviewFormat {
		switch fileURL.pathExtension.lowercased() {
			case "json":
				.json
			case "plist":
				.plist
			default:
				.xml
		}
	}
}
