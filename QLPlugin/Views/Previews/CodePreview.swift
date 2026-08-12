import Foundation

class CodePreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css"
	)

	required init() {}

	private func getStylesheets() -> [Stylesheet] {
		var stylesheets = [Stylesheet]()

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
		let lexer = PreviewSupport.getCodeLexer(fileURL: fileURL)
		do {
			let html = try await PreviewExecutor.run {
				let source = try String(contentsOf: fileURL, encoding: .utf8)
				return try HTMLRenderer.renderCode(source, lexer: lexer)
			}
			return WebPreviewVC(html: html, stylesheets: getStylesheets())
		} catch let error as CancellationError {
			throw error
		} catch {
			Log.render.error(
				"Could not generate code HTML: \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}
}
