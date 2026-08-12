import Foundation

class JupyterPreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css"
	)
	private let katexAutoRenderScriptURL = WebPreviewVC.resourceBundle.url(
		forResource: "jupyter-katex-auto-render.min",
		withExtension: "js"
	)
	private let katexScriptURL = WebPreviewVC.resourceBundle.url(
		forResource: "jupyter-katex.min",
		withExtension: "js"
	)
	private let katexStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "jupyter-katex.min",
		withExtension: "css"
	)
	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "jupyter-main",
		withExtension: "css"
	)

	required init() {}

	private func getStylesheets() -> [Stylesheet] {
		var stylesheets = [Stylesheet]()

		// Main Jupyter stylesheet
		if let mainStylesheetURL {
			stylesheets.append(Stylesheet(url: mainStylesheetURL))
		} else {
			Log.render.error("Could not find main Jupyter stylesheet")
		}

		// Semantic syntax-highlighting stylesheet
		if let chromaStylesheetURL {
			stylesheets.append(Stylesheet(url: chromaStylesheetURL))
		} else {
			Log.render.error("Could not find syntax-highlighting stylesheet")
		}

		// KaTeX stylesheet (for rendering LaTeX math)
		if let katexStylesheetURL {
			stylesheets.append(Stylesheet(url: katexStylesheetURL))
		} else {
			Log.render.error("Could not find KaTeX stylesheet")
		}

		return stylesheets
	}

	private func getScripts() -> [Script] {
		var scripts = [Script]()

		// KaTeX library (for rendering LaTeX math)
		if let katexScriptURL {
			scripts.append(Script(url: katexScriptURL))
		} else {
			Log.render.error("Could not find KaTeX script")
		}

		// KaTeX auto-renderer (finds LaTeX math ond the page and calls KaTeX on it)
		if let katexAutoRenderScriptURL {
			scripts.append(Script(url: katexAutoRenderScriptURL))
		} else {
			Log.render.error("Could not find KaTeX auto-render script")
		}

		// Main script (calls the KaTeX auto-renderer)
		scripts.append(Script(content: "renderMathInElement(document.body);"))

		return scripts
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		do {
			let html = try await PreviewExecutor.run {
				let source = try String(contentsOf: fileURL, encoding: .utf8)
				return try HTMLRenderer.renderNotebook(source)
			}
			return WebPreviewVC(
				html: html,
				stylesheets: getStylesheets(),
				scripts: getScripts()
			)
		} catch let error as CancellationError {
			throw error
		} catch {
			Log.render.error(
				"Could not generate Jupyter Notebook HTML: \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}
}
