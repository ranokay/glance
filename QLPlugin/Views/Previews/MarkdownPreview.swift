import Foundation

class MarkdownPreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css"
	)
	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "markdown-main",
		withExtension: "css"
	)

	required init() {}

	private func getStylesheets() -> [Stylesheet] {
		var stylesheets = [Stylesheet]()

		// Main Markdown stylesheet
		if let mainStylesheetURL {
			stylesheets.append(Stylesheet(url: mainStylesheetURL))
		} else {
			Log.render.error("Could not find main Markdown stylesheet")
		}

		// Semantic syntax-highlighting stylesheet
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
			let html = try await PreviewExecutor.run {
				let source = try String(contentsOf: fileURL, encoding: .utf8)
				return "<div class=\"markdown-body\">\(try HTMLRenderer.renderMarkdown(source))</div>"
			}
			return WebPreviewVC(html: html, stylesheets: getStylesheets())
		} catch {
			Log.render.error(
				"Could not generate Markdown HTML: \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}
}
