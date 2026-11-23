import Foundation
import GlanceKit

class CodePreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css",
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
				"Could not generate code HTML: \(error.localizedDescription, privacy: .private)",
			)
			throw error
		}
	}

	@MainActor
	private func makeContent(fileURL: URL) async throws -> WebPreviewContent {
		let lexer = PreviewSupport.getCodeLexer(fileURL: fileURL)
		let html = try await PreviewExecutor.run {
			let source = try String(contentsOf: fileURL, encoding: .utf8)
			return try HTMLRenderer.renderCode(source, lexer: lexer)
		}
		return WebPreviewContent(html: html, stylesheets: getStylesheets())
	}
}
