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
		forResource: "markdown-pele-1.9.0.global",
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

	/// This exact comment is emitted only by PreviewCore's Mermaid fence renderer. Raw HTML is
	/// disabled, and escaped code cannot reproduce a live HTML comment, so it is safe to use as the
	/// conditional runtime-loading signal.
	static let mermaidSentinel = "<!--glance-renderer-mermaid-v1-->"

	required init() {}

	private func getStylesheets(html: String) -> [Stylesheet] {
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

		// KaTeX stylesheet
		if Self.containsTrustedMath(in: html) {
			if let katexStylesheetURL {
				stylesheets.append(Stylesheet(url: katexStylesheetURL))
			} else {
				Log.render.error("Could not find KaTeX stylesheet")
			}
		}

		return stylesheets
	}

	static func containsTrustedMermaid(in html: String) -> Bool {
		html.contains(mermaidSentinel)
	}

	/// PreviewCore wraps dollar math in `<span data-math-style="…">` with escaped TeX source.
	/// Raw HTML is disabled, so user text cannot produce that opening tag and this marker is
	/// trusted. See `render_markdown` in `PreviewCore/src/markdown.rs`.
	static func containsTrustedMath(in html: String) -> Bool {
		html.contains("<span data-math-style=")
	}

	private func getScripts(html: String) -> [Script] {
		var scripts = [Script]()

		if Self.containsTrustedMermaid(in: html) {
			scripts += mermaidScripts()
		}

		if Self.containsTrustedMath(in: html) {
			scripts += mathScripts()
		}

		return scripts
	}

	private func mermaidScripts() -> [Script] {
		guard let mermaidScriptURL else {
			Log.render.error("Could not find bundled Pele script")
			return []
		}

		let renderScript = """
		(function() {
			const sources = Array.from(
				document.querySelectorAll('pre[data-glance-mermaid="1"]')
			);
			const styles = getComputedStyle(document.body);
			const fontFamily = styles.getPropertyValue('--font-family-sans-serif').trim()
				|| styles.fontFamily;
			const fontFamilyMono = styles.getPropertyValue('--font-family-monospace').trim()
				|| 'monospace';
			const fontSize = parseFloat(styles.fontSize) || 14;

			sources.forEach(function(source, index) {
				try {
					const result = pele.render(source.textContent || '', {
						idPrefix: 'glance-mermaid-' + index,
						maxWidth: source.clientWidth || document.body.clientWidth || 800,
						links: false,
						images: false,
						fontFamily: fontFamily,
						fontFamilyMono: fontFamilyMono,
						fontSize: fontSize
					});
					const diagram = document.createElement('div');
					diagram.className = 'mermaid-diagram';
					diagram.dataset.glanceMermaidState = 'rendered';
					diagram.innerHTML = result.svg;
					source.replaceWith(diagram);
				} catch (error) {
					source.dataset.glanceMermaidState = 'failed';
					console.error('Could not render Mermaid diagram:', error);
				}
			});
		})();
		"""

		return [Script(url: mermaidScriptURL), Script(content: renderScript)]
	}

	/// Marks `<span data-math-style="…">` nodes from PreviewCore and renders their escaped TeX
	/// source with the bundled KaTeX. `throwOnError: false` turns invalid TeX into escaped
	/// literal text instead of failing the preview.
	private func mathScripts() -> [Script] {
		guard let katexScriptURL else {
			Log.render.error("Could not find KaTeX script")
			return []
		}

		let renderScript = """
		(function() {
			document.querySelectorAll('span[data-math-style]').forEach(function(element) {
				try {
					katex.render(element.textContent || '', element, {
						displayMode: element.dataset.mathStyle === 'display',
						throwOnError: false,
						trust: false,
						strict: 'warn'
					});
					element.dataset.glanceMathState = 'rendered';
				} catch (error) {
					element.dataset.glanceMathState = 'failed';
					console.error('Could not render math:', error);
				}
			});
		})();
		"""

		return [Script(url: katexScriptURL), Script(content: renderScript)]
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		do {
			let html = try await PreviewExecutor.run {
				let source = try String(contentsOf: fileURL, encoding: .utf8)
				return "<div class=\"markdown-body\">\(try HTMLRenderer.renderMarkdown(source))</div>"
			}
			return await WebPreviewVC(
				html: html,
				stylesheets: getStylesheets(html: html),
				scripts: getScripts(html: html),
				appearancePreferences: PreviewSettingsClient.shared.appearancePreferences()
			)
		} catch {
			Log.render.error(
				"Could not generate Markdown HTML: \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}
}
