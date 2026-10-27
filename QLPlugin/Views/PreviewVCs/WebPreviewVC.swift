import Cocoa
import GlanceKit
import WebKit

/// A document body plus the assets that depend on its content.
struct WebPreviewContent {
	var html: String
	var stylesheets: [Stylesheet] = []
	var scripts: [Script] = []
}

/// Quick Look panels can open without key status. Accept the first click so the page
/// receives a disclosure click immediately instead of only focusing the panel.
private final class PreviewWebView: WKWebView {
	override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
		true
	}
}

class WebPreviewVC: NSViewController, PreviewVC, WKNavigationDelegate {
	private var content: WebPreviewContent
	private let appearanceStylesheet: Stylesheet
	private let contentLoader: (@MainActor () async throws -> WebPreviewContent)?
	private let previewNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
	private var pendingScrollOffset: CGFloat?
	private var webView: WKWebView?

	nonisolated static let resourceBundle: Bundle = {
		let embeddedPluginBundle = Bundle.main.builtInPlugInsURL
			.flatMap { Bundle(url: $0.appendingPathComponent("QLPlugin.appex")) }
		let candidates = [
			Bundle(for: WebPreviewVC.self),
			Bundle(identifier: "com.chamburr.Glance.QLPlugin"),
			embeddedPluginBundle,
			Bundle.main,
		].compactMap(\.self)

		return candidates.first {
			$0.url(forResource: "shared-main", withExtension: "css") != nil
		} ?? Bundle(for: WebPreviewVC.self)
	}()

	/// Stylesheet with CSS that applies to all file types
	private static var sharedStylesheetURL: URL? {
		resourceBundle.url(forResource: "shared-main", withExtension: "css")
	}

	required convenience init(
		html: String,
		stylesheets: [Stylesheet] = [],
		scripts: [Script] = [],
		appearancePreferences: PreviewAppearancePreferences = PreviewAppearancePreferences.default,
		availableFontFamilies: [String] = NSFontManager.shared.availableFontFamilies,
	) {
		self.init(
			nibName: nil,
			bundle: nil,
			html: html,
			stylesheets: stylesheets,
			scripts: scripts,
			appearancePreferences: appearancePreferences,
			availableFontFamilies: availableFontFamilies,
		)
	}

	/// Creates a preview whose document can be rebuilt with the same loader after the file changes.
	convenience init(
		content: WebPreviewContent,
		appearancePreferences: PreviewAppearancePreferences = PreviewAppearancePreferences.default,
		availableFontFamilies: [String] = NSFontManager.shared.availableFontFamilies,
		contentLoader: @escaping @MainActor () async throws -> WebPreviewContent,
	) {
		self.init(
			nibName: nil,
			bundle: nil,
			html: content.html,
			stylesheets: content.stylesheets,
			scripts: content.scripts,
			appearancePreferences: appearancePreferences,
			availableFontFamilies: availableFontFamilies,
			contentLoader: contentLoader,
		)
	}

	init(
		nibName nibNameOrNil: NSNib.Name?,
		bundle nibBundleOrNil: Bundle?,
		html: String,
		stylesheets: [Stylesheet] = [],
		scripts: [Script] = [],
		appearancePreferences: PreviewAppearancePreferences = PreviewAppearancePreferences.default,
		availableFontFamilies: [String] = NSFontManager.shared.availableFontFamilies,
		contentLoader: (@MainActor () async throws -> WebPreviewContent)? = nil,
	) {
		content = WebPreviewContent(
			html: html,
			stylesheets: stylesheets,
			scripts: scripts,
		)
		self.contentLoader = contentLoader
		appearanceStylesheet = Stylesheet(
			content: appearancePreferences.stylesheet(
				availableFontFamilies: availableFontFamilies,
			),
		)
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
	}

	private static func resolvedStylesheets(
		_ stylesheets: [Stylesheet],
		appearanceStylesheet: Stylesheet,
	) -> [Stylesheet] {
		var resolvedStylesheets = stylesheets
		if let sharedStylesheetURL {
			resolvedStylesheets.insert(Stylesheet(url: sharedStylesheetURL), at: 0)
		} else {
			Log.render.error("Could not find shared stylesheet")
		}
		resolvedStylesheets.append(appearanceStylesheet)
		return resolvedStylesheets
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	deinit {
		MainActor.assumeIsolated {
			webView?.navigationDelegate = nil
			webView?.stopLoading()
		}
	}

	override func loadView() {
		view = PreviewBackgroundView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		loadPreview()
	}

	/// Give the page keyboard focus before the first click so select-all and copy
	/// work, and the first disclosure click is not spent focusing the panel.
	override func viewDidAppear() {
		super.viewDidAppear()
		guard let webView else {
			return
		}
		view.window?.makeFirstResponder(webView)
	}

	private func loadPreview() {
		let webView: WKWebView
		if let existingWebView = self.webView {
			webView = existingWebView
		} else {
			webView = PreviewWebView(frame: view.bounds)
			webView.autoresizingMask = [.height, .width]
			webView.underPageBackgroundColor = .clear
			webView.alphaValue = 0
			webView.navigationDelegate = self
			self.webView = webView
			view.addSubview(webView)
		}

		webView.loadHTMLString(documentHTML(), baseURL: Self.resourceBundle.resourceURL)
	}

	private func documentHTML() -> String {
		let stylesheets = Self.resolvedStylesheets(
			content.stylesheets,
			appearanceStylesheet: appearanceStylesheet,
		)
		let linkTags = stylesheets
			.map { $0.getInlineHTML() }
			.joined(separator: "\n")
		let scriptTags = content.scripts
			.map { $0.getInlineHTML(nonce: previewNonce) }
			.joined(separator: "\n")
		let sanitizedHTML = Self.sanitizePreviewHTML(content.html)

		return """
		<!DOCTYPE html>
		<html>
			<head>
				<meta charset="utf-8" />
				<meta
					name="viewport"
					content="width=device-width, initial-scale=1, shrink-to-fit=no"
				/>
				<meta
					http-equiv="Content-Security-Policy"
					content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-\(
						previewNonce
					)'; img-src data: file: blob:; font-src data: file:; media-src data: file: blob:; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'"
				/>
				\(linkTags)
			</head>
			<body>
				\(sanitizedHTML)
				\(scriptTags)
			</body>
		</html>
		"""
	}

	private static func sanitizePreviewHTML(_ html: String) -> String {
		var sanitized = replaceMatches(
			in: html,
			pattern: #"<script\b[^>]*>.*?(</script\s*>|$)"#,
			options: [.caseInsensitive, .dotMatchesLineSeparators],
		)

		let unsafeAttributePatterns = [
			#"\s+on[a-zA-Z0-9_-]+\s*=\s*"[^"]*""#,
			#"\s+on[a-zA-Z0-9_-]+\s*=\s*'[^']*'"#,
			#"\s+on[a-zA-Z0-9_-]+\s*=\s*[^\s>]+"#,
			#"\s+(href|src)\s*=\s*"[^"]*javascript:[^"]*""#,
			#"\s+(href|src)\s*=\s*'[^']*javascript:[^']*'"#,
			#"\s+(href|src)\s*=\s*[^\s>]*javascript:[^\s>]+"#,
		]

		for pattern in unsafeAttributePatterns {
			sanitized = replaceMatches(in: sanitized, pattern: pattern, options: [.caseInsensitive])
		}

		return sanitized
	}

	private static func replaceMatches(
		in html: String,
		pattern: String,
		options: NSRegularExpression.Options,
	) -> String {
		guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
			return html
		}

		let range = NSRange(html.startIndex ..< html.endIndex, in: html)
		return expression.stringByReplacingMatches(
			in: html,
			options: [],
			range: range,
			withTemplate: "",
		)
	}

	// MARK: - WKNavigationDelegate

	/// Reveal the web view once loading finishes, restoring the reader's place after a refresh.
	func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
		if let scrollOffset = pendingScrollOffset {
			pendingScrollOffset = nil
			webView.evaluateJavaScript("window.scrollTo(0, \(scrollOffset));")
			webView.alphaValue = 1
			return
		}
		revealAfterFirstPaint(webView)
	}

	/// On navigation failure, show the web view anyway so the user sees something
	func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
		webView.alphaValue = 1
	}

	func webView(
		_ webView: WKWebView,
		didFailProvisionalNavigation _: WKNavigation!,
		withError _: Error,
	) {
		webView.alphaValue = 1
	}

	private func revealAfterFirstPaint(_ webView: WKWebView) {
		// requestAnimationFrame is suspended while a WebKit view is detached from a window.
		// Keep a fallback so offscreen navigation cannot leave the preview
		// invisible.
		Task { @MainActor [weak self, weak webView] in
			try? await Task.sleep(for: .milliseconds(250))
			guard
				!Task.isCancelled,
				let self,
				let webView,
				Self.isDetachedRevealFallbackEligible(webView)
			else {
				return
			}
			reveal(webView)
		}
		webView.callAsyncJavaScript(
			"await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
			arguments: [:],
			in: nil,
			in: .page,
		) { [weak self, weak webView] _ in
			guard let self, let webView else {
				return
			}
			reveal(webView)
		}
	}

	static func isDetachedRevealFallbackEligible(_ webView: WKWebView) -> Bool {
		webView.window == nil
	}

	private func reveal(_ webView: WKWebView) {
		guard webView.alphaValue < 1 else {
			return
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.08
			webView.animator().alphaValue = 1
		}
	}
}

extension WebPreviewVC: RefreshablePreview {
	var isRefreshable: Bool {
		contentLoader != nil
	}

	/// Rebuilds the document from disk and restores the reader's scroll position.
	func refreshFromDisk() async throws {
		guard let contentLoader else {
			throw PreviewRefreshError.unavailable
		}
		let loadedContent = try await contentLoader()
		try Task.checkCancellation()
		// A previous reload may still be in flight; its saved position is still valid.
		let scrollOffset: CGFloat? = if let pendingScrollOffset {
			pendingScrollOffset
		} else {
			await currentScrollOffset()
		}
		try Task.checkCancellation()
		content = loadedContent
		pendingScrollOffset = scrollOffset
		webView?.alphaValue = 0
		loadPreview()
	}

	private func currentScrollOffset() async -> CGFloat? {
		guard let webView else {
			return nil
		}
		let value = try? await webView.evaluateJavaScript("window.scrollY")
		return (value as? NSNumber).map { CGFloat($0.doubleValue) }
	}
}
