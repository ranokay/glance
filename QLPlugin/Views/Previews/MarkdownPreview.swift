import Foundation
import GlanceKit

class MarkdownPreview: Preview {
	private let chromaStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "shared-chroma",
		withExtension: "css"
	)
	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "markdown-main",
		withExtension: "css"
	)
	private let mermaidScriptURL = WebPreviewVC.resourceBundle.url(
		forResource: "markdown-mermaid-11.17.2.min",
		withExtension: "js"
	)

	/// This exact comment is emitted only by PreviewCore's Mermaid fence renderer. Raw HTML is
	/// disabled, and escaped code cannot reproduce a live HTML comment, so it is safe to use as the
	/// conditional runtime-loading signal.
	static let mermaidSentinel = "<!--glance-renderer-mermaid-v1-->"

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

	static func containsTrustedMermaid(in html: String) -> Bool {
		html.contains(mermaidSentinel)
	}

	private func getScripts(html: String) -> [Script] {
		guard Self.containsTrustedMermaid(in: html) else {
			return []
		}
		guard let mermaidScriptURL else {
			Log.render.error("Could not find bundled Mermaid script")
			return []
		}

		let renderScript = """
		(function() {
			const sources = Array.from(
				document.querySelectorAll('pre[data-glance-mermaid="1"]')
			);
			const isDark = window.matchMedia
				&& window.matchMedia('(prefers-color-scheme: dark)').matches;
			mermaid.initialize({
				startOnLoad: false,
				securityLevel: 'strict',
				suppressErrorRendering: true,
				theme: isDark ? 'dark' : 'default'
			});

			sources.forEach(async function(source, index) {
				try {
					const result = await mermaid.render(
						'glance-mermaid-' + index,
						source.textContent || ''
					);
					const diagram = document.createElement('div');
					diagram.className = 'mermaid-diagram';
					diagram.dataset.glanceMermaidState = 'rendered';
					diagram.dataset.glanceMermaidTheme = isDark ? 'dark' : 'default';
					diagram.innerHTML = result.svg;
					source.replaceWith(diagram);
					if (result.bindFunctions) {
						result.bindFunctions(diagram);
					}
				} catch (error) {
					source.dataset.glanceMermaidState = 'failed';
					console.error('Could not render Mermaid diagram:', error);
				}
			});
		})();
		"""

		return [Script(url: mermaidScriptURL), Script(content: renderScript)]
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		do {
			let html = try await PreviewExecutor.run {
				let source = try String(contentsOf: fileURL, encoding: .utf8)
				return "<div class=\"markdown-body\">\(try HTMLRenderer.renderMarkdown(source))</div>"
			}
			return WebPreviewVC(
				html: html,
				stylesheets: getStylesheets(),
				scripts: getScripts(html: html)
			)
		} catch {
			Log.render.error(
				"Could not generate Markdown HTML: \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}
}
