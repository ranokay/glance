import Cocoa
import Foundation
import SceneKit
import WebKit
import XCTest

@MainActor
final class PreviewSmokeTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlancePreviewTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: temporaryDirectory,
			withIntermediateDirectories: true
		)
	}

	override func tearDownWithError() throws {
		if let temporaryDirectory {
			try? FileManager.default.removeItem(at: temporaryDirectory)
		}
		try super.tearDownWithError()
	}

	func testCodePreviewHandlesEmptyAndUnicodeSource() async throws {
		let fileURL = try writeFile(named: "unicode.swift", contents: "let cafe = \"\u{2615}\"\n")

		let previewVC = try await CodePreview().createPreviewVC(file: File(url: fileURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
	}

	func testEPUBPreviewRendersOfflineContentAndSanitizesActiveMarkup() async throws {
		let fixtureText = try String(
			contentsOf: URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()
				.appendingPathComponent("TestFiles/epub/example.epub.b64"),
			encoding: .utf8
		)
		let fixtureData = try XCTUnwrap(
			Data(base64Encoded: fixtureText.trimmingCharacters(in: .whitespacesAndNewlines))
		)
		let fixtureURL = try writeDataFile(named: "example.epub", data: fixtureData)

		let html = try await PreviewExecutor.run {
			try PreviewCoreBridge.renderEPUB(at: fixtureURL)
		}
		XCTAssertTrue(html.contains("Glance EPUB Fixture"))
		XCTAssertTrue(html.contains("href=\"#glance-c2-finish\""))
		XCTAssertTrue(html.contains("data:image/png;base64,"))
		XCTAssertFalse(html.contains("<script"))
		XCTAssertFalse(html.contains("onclick"))
		XCTAssertFalse(html.contains("https://example.com"))

		let generated = try await EPUBPreview().createPreviewVC(file: File(url: fixtureURL))
		let previewVC = try XCTUnwrap(generated as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(
			previewVC.view.subviews.compactMap { $0 as? WKWebView }.first
		)
		try await waitForWebViewToFinishLoadingAsync(webView)
		let state = try await webView.evaluateJavaScript(
			"""
			[
				document.querySelector('.epub-book h1')?.textContent || '',
				document.querySelectorAll('.epub-chapter').length,
				document.querySelector('a[href="#glance-c2-finish"]') !== null,
				document.querySelector('img[src^="data:image/png;base64,"]') !== null,
				document.querySelector('script') === null,
				document.querySelector('[onclick]') === null
			].join('|')
			"""
		) as? String
		XCTAssertEqual(state, "Glance EPUB Fixture|2|true|true|true|true")

		let bundle = WebPreviewVC.resourceBundle
		XCTAssertNotNil(bundle.url(forResource: "epub-main", withExtension: "css"))
	}

	func testEPUBPreviewRejectsMalformedArchives() async throws {
		let fileURL = try writeFile(named: "malformed.epub", contents: "not a ZIP")
		await XCTAssertThrowsErrorAsync {
			_ = try await EPUBPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testThreeMFPreviewBuildsInteractiveSceneFromRustPayload() async throws {
		let fixtureURL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles/models/simple.3mf")
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.parseThreeMF(at: fixtureURL)
		}
		XCTAssertEqual(payload.triangleCount, 1)
		XCTAssertEqual(payload.boundsMin, [2, 3, 4])
		XCTAssertEqual(payload.boundsMax, [12, 23, 4])

		let generated = try await ThreeMFPreview().createPreviewVC(file: File(url: fixtureURL))
		let previewVC = try XCTUnwrap(generated as? ModelPreviewVC)
		previewVC.loadViewIfNeeded()
		let sceneView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? SCNView }.first)
		XCTAssertTrue(sceneView.allowsCameraControl)
		XCTAssertEqual(sceneView.scene?.rootNode.childNodes.isEmpty, false)
	}

	func testThreeMFPreviewRejectsMalformedContainerOffMain() async throws {
		let fileURL = try writeFile(named: "malformed.3mf", contents: "not a ZIP")
		await XCTAssertThrowsErrorAsync {
			_ = try await ThreeMFPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testThreeMFCameraFramesAfterZeroWidthLayout() {
		let camera = ModelCamera(
			target: SCNVector3Zero,
			corners: [SCNVector3(-1, -1, -1), SCNVector3(1, 1, 1)],
			radius: 2
		)
		let previewVC = ModelPreviewVC(scene: SCNScene(), camera: camera, labelText: "Model")
		previewVC.loadViewIfNeeded()
		let initialPosition = camera.node.position

		previewVC.view.frame = NSRect(x: 0, y: 0, width: 0, height: 400)
		previewVC.viewDidLayout()
		XCTAssertEqual(camera.node.position.x, initialPosition.x)
		XCTAssertEqual(camera.node.position.y, initialPosition.y)
		XCTAssertEqual(camera.node.position.z, initialPosition.z)

		previewVC.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		previewVC.viewDidLayout()
		XCTAssertNotEqual(camera.node.position.x, initialPosition.x)
	}

	func testDrawIOPreviewRendersUncompressedDiagramOffline() async throws {
		let fileURL = try writeFile(
			named: "diagram.drawio",
			contents: Self.drawIODocument(label: "Offline diagram")
		)
		let generated = try await DrawIOPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generated as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)

		try await waitForWebViewToFinishLoadingAsync(webView)
		try await waitForJavaScript(
			"document.querySelector('.mxgraph > svg') !== null",
			in: webView
		)
		let state = try await webView.evaluateJavaScript(
			"""
			[
				document.body.textContent.includes('Offline diagram'),
				document.querySelector('meta[http-equiv="Content-Security-Policy"]')
					.content.includes("connect-src 'none'"),
				document.querySelector('[data-drawio-payload]') === null,
				document.querySelector('svg rect').style.fill.includes('light-dark')
			].join('|')
			"""
		) as? String
		XCTAssertEqual(state, "true|true|true|true")
	}

	func testDrawIOPreviewEncodesUntrustedXMLWithoutExecutingIt() async throws {
		let payload = "</div><script>window.drawIOInjected = true</script><div>"
		let fileURL = try writeFile(
			named: "untrusted.drawio",
			contents: Self.drawIODocument(label: payload)
		)
		let generated = try await DrawIOPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generated as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)

		try await waitForWebViewToFinishLoadingAsync(webView)
		try await waitForJavaScript(
			"document.querySelector('.mxgraph > svg') !== null",
			in: webView
		)
		let state = try await webView.evaluateJavaScript(
			"""
			[
				window.drawIOInjected === undefined,
				document.querySelector('.mxgraph > svg') !== null,
				!Array.from(document.scripts).some(script =>
					script.textContent.includes('drawIOInjected')
				)
			].join('|')
			"""
		) as? String
		XCTAssertEqual(state, "true|true|true")
	}

	func testDrawIOPreviewRejectsMalformedCompressedAndOversizedDocuments() async throws {
		let malformedURL = try writeFile(named: "malformed.drawio", contents: "not xml")
		let invalidUTF8URL = try writeDataFile(
			named: "invalid-utf8.drawio",
			data: Data([0xFF])
		)
		let compressedURL = try writeFile(
			named: "compressed.drawio",
			contents: #"<mxfile><diagram>jZLBbsIwDIafJtfuACRE2HbsuO0Bq7Q1iZM4Re3t5yYtG0JC7Pz//2UnkJmKV/dG6vAGIxQupzvp2PFiKUPkuc6ZnBHiGCU5wkTOCOlV9vTKSdoKKS9if2iNN9C08Kk1p2EHElBBP8NQWH7ZrsCTMTnnlHnYys+eowfXJzIJN2RbSIYwmjuBcdSPCnwaZHNldH03nVZLYGl6bmzvpPKGAVed16J4LLr9Xm9Vz0+Gh1C05kuvB/X1HzKnssv5z2v9w0lwDLuzH7S19Ac="</diagram></mxfile>"#
		)
		let oversizedURL = temporaryDirectory.appendingPathComponent("oversized.drawio")
		FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
		let handle = try FileHandle(forWritingTo: oversizedURL)
		try handle.truncate(atOffset: UInt64(DrawIOPreview.maximumFileSize + 1))
		try handle.close()
		let externalEntityURL = try writeFile(
			named: "entity.drawio",
			contents: """
			<!DOCTYPE mxGraphModel [<!ENTITY file SYSTEM "file:///etc/passwd">]>
			<mxGraphModel><root><mxCell id="0" value="&file;"/></root></mxGraphModel>
			"""
		)

		let failures = [
			(malformedURL, "Could not preview Draw.io diagram"),
			(invalidUTF8URL, "Draw.io diagram is not valid UTF-8"),
			(compressedURL, "Compressed Draw.io diagrams are not supported"),
			(oversizedURL, "Draw.io diagram exceeds the 10 MB preview limit"),
			(externalEntityURL, "document type declarations are not allowed"),
		]

		for (fileURL, expectedMessage) in failures {
			do {
				_ = try await DrawIOPreview().createPreviewVC(file: File(url: fileURL))
				XCTFail("Expected \(fileURL.lastPathComponent) to be rejected")
			} catch {
				XCTAssertTrue(error.localizedDescription.contains(expectedMessage))
			}
		}
	}

	func testDrawIOPreviewAcceptsBareUncompressedGraphModel() async throws {
		let fileURL = try writeFile(
			named: "bare.drawio",
			contents: "<mxGraphModel><root><mxCell id=\"0\"/></root></mxGraphModel>"
		)

		let previewVC = try await DrawIOPreview().createPreviewVC(file: File(url: fileURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
	}

	func testDrawIOPreviewAdaptsWebViewToSidebarAndWindowSizes() async throws {
		let fileURL = try writeFile(
			named: "responsive.drawio",
			contents: Self.drawIODocument(label: "Responsive diagram")
		)
		let generated = try await DrawIOPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generated as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(
			previewVC.view.subviews.compactMap { $0 as? WKWebView }.first
		)

		for width in [CGFloat(320), CGFloat(1000)] {
			previewVC.view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
			previewVC.view.layoutSubtreeIfNeeded()
			XCTAssertEqual(webView.frame.width, width, accuracy: 1)
		}
	}

	func testDrawIORuntimeAndLicenseAreBundled() throws {
		let bundle = WebPreviewVC.resourceBundle
		let runtimeURL = try XCTUnwrap(
			bundle.url(forResource: "drawio-viewer-31.4.6.min", withExtension: "js")
		)
		let licenseURL = try XCTUnwrap(
			bundle.url(forResource: "DRAWIO_LICENSE", withExtension: "txt")
		)
		let stylesheetURL = try XCTUnwrap(
			bundle.url(forResource: "drawio-main", withExtension: "css")
		)

		XCTAssertGreaterThan(try Data(contentsOf: runtimeURL).count, 2_000_000)
		XCTAssertTrue(
			try String(contentsOf: licenseURL, encoding: .utf8).contains("Apache License")
		)
		let stylesheet = try String(contentsOf: stylesheetURL, encoding: .utf8)
		XCTAssertTrue(stylesheet.contains("color-scheme: light dark"))
		XCTAssertTrue(stylesheet.contains("width: 100%"))
	}

	func testHTMLRendererPreservesBinarySafeUnicodeAndEmptyInputs() throws {
		let html = try HTMLRenderer.renderCode("let cafe = \"\u{2615}\"\n", lexer: "swift")

		XCTAssertTrue(html.hasPrefix(#"<pre class="chroma"><code>"#))
		XCTAssertTrue(html.contains("\u{2615}"))
		XCTAssertEqual(try HTMLRenderer.renderMarkdown(""), "")
	}

	func testHTMLRendererProducesSafeGFMAndNotebookDOM() throws {
		let markdown = """
		---
		title: Fixture
		---

		| one | two |
		| --- | --- |
		| yes | no |

		- [x] done

		<script>alert("bad")</script>
		[bad](javascript:alert("bad"))
		"""
		let markdownHTML = try HTMLRenderer.renderMarkdown(markdown)
		let notebook = """
		{"cells":[{"cell_type":"code","execution_count":1,"metadata":{},"source":["print('ok')"],"outputs":[{"name":"stdout","output_type":"stream","text":["ok\\n"]}]}],"metadata":{"kernelspec":{"language":"python"}},"nbformat":4,"nbformat_minor":5}
		"""
		let notebookHTML = try HTMLRenderer.renderNotebook(notebook)

		XCTAssertTrue(markdownHTML.contains(#"<pre class="chroma">"#))
		XCTAssertTrue(markdownHTML.contains("<table>"))
		XCTAssertTrue(markdownHTML.contains(#"type="checkbox""#))
		XCTAssertFalse(markdownHTML.lowercased().contains("<script"))
		XCTAssertFalse(markdownHTML.lowercased().contains("javascript:"))
		XCTAssertTrue(notebookHTML.contains(#"class="cell cell-code""#))
		XCTAssertTrue(notebookHTML.contains(#"class="output output-stream""#))
		XCTAssertThrowsError(try HTMLRenderer.renderNotebook("not-json"))
	}

	func testCodePreviewAppliesSemanticSyntaxStyles() async throws {
		let fileURL = try writeFile(named: "styled.swift", contents: "let value = 42\n")
		let generatedPreview = try await CodePreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generatedPreview as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)

		try await waitForWebViewToFinishLoadingAsync(webView)
		let result = try await webView.evaluateJavaScript(
			"""
			[
				document.querySelector('pre.chroma') !== null,
				document.querySelector('.chroma .storage') !== null,
				getComputedStyle(document.querySelector('.chroma .storage')).color
			].join('|')
			"""
		)
		let state = result as? String
		XCTAssertEqual(state?.hasPrefix("true|true|"), true)
		XCTAssertTrue(
			state?.hasSuffix("rgb(155, 35, 147)") == true
				|| state?.hasSuffix("rgb(252, 95, 163)") == true
		)
	}

	func testMarkdownPreviewHandlesFrontMatterAndRawHTML() async throws {
		let markdown = """
		---
		title: Fixture
		---

		# Heading

		<script>alert("bad")</script>
		"""
		let fileURL = try writeFile(named: "README.md", contents: markdown)

		let previewVC = try await MarkdownPreview().createPreviewVC(file: File(url: fileURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
	}

	func testMarkdownPreviewLoadsBundledMermaidOnlyForTrustedFences() async throws {
		let mermaidURL = try writeFile(
			named: "diagram.md",
			contents: "```mermaid\nflowchart LR\n    A --> B\n```\n"
		)
		let plainURL = try writeFile(
			named: "plain.md",
			contents: """
			<!--glance-renderer-mermaid-v1-->
			<pre data-glance-mermaid="1">forged</pre>

			```swift
			let value = 42
			```
			"""
		)

		let generatedMermaidPreview = try await MarkdownPreview().createPreviewVC(
			file: File(url: mermaidURL)
		)
		let mermaidPreview = try XCTUnwrap(generatedMermaidPreview as? WebPreviewVC)
		mermaidPreview.loadViewIfNeeded()
		let mermaidWebView = try XCTUnwrap(
			mermaidPreview.view.subviews.compactMap { $0 as? WKWebView }.first
		)
		try await waitForWebViewToFinishLoadingAsync(mermaidWebView)
		try await waitForJavaScript(
			"document.querySelector('.mermaid-diagram svg') !== null",
			in: mermaidWebView
		)
		let mermaidState = try await mermaidWebView.evaluateJavaScript(
			"""
			[
				typeof window.mermaid,
				document.querySelector('.mermaid-diagram svg') !== null,
				document.querySelector('meta[http-equiv="Content-Security-Policy"]')
					.content.includes("connect-src 'none'")
			].join('|')
			"""
		) as? String
		XCTAssertEqual(mermaidState, "object|true|true")

		let generatedPlainPreview = try await MarkdownPreview().createPreviewVC(
			file: File(url: plainURL)
		)
		let plainPreview = try XCTUnwrap(generatedPlainPreview as? WebPreviewVC)
		plainPreview.loadViewIfNeeded()
		let plainWebView = try XCTUnwrap(
			plainPreview.view.subviews.compactMap { $0 as? WKWebView }.first
		)
		try await waitForWebViewToFinishLoadingAsync(plainWebView)
		let plainState = try await plainWebView.evaluateJavaScript(
			"""
			[
				typeof window.mermaid,
				document.querySelectorAll('script').length,
				document.querySelector('pre.chroma') !== null
			].join('|')
			"""
		) as? String
		XCTAssertEqual(plainState, "undefined|0|true")
	}

	func testMarkdownPreviewKeepsMalformedMermaidReadable() async throws {
		let source = "this is not a diagram"
		let fileURL = try writeFile(
			named: "malformed-mermaid.md",
			contents: "```mermaid\n\(source)\n```\n"
		)
		let generatedPreview = try await MarkdownPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generatedPreview as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)

		try await waitForWebViewToFinishLoadingAsync(webView)
		try await waitForJavaScript(
			"document.querySelector('[data-glance-mermaid-state=" +
				"\"failed\"]') !== null",
			in: webView
		)
		let state = try await webView.evaluateJavaScript(
			"""
			const source = document.querySelector('pre[data-glance-mermaid="1"]');
			[source !== null, source.textContent.trim(), source.dataset.glanceMermaidState].join('|')
			"""
		) as? String
		XCTAssertEqual(state, "true|\(source)|failed")
	}

	func testMarkdownPreviewRendersMermaidInLightAndDarkAppearances() async throws {
		for (appearanceName, expectedTheme) in [
			(NSAppearance.Name.aqua, "default"),
			(.darkAqua, "dark"),
		] {
			let fileURL = try writeFile(
				named: "diagram-\(expectedTheme).md",
				contents: "```mermaid\nsequenceDiagram\n    Alice->>Bob: Hello\n```\n"
			)
			let generatedPreview = try await MarkdownPreview().createPreviewVC(
				file: File(url: fileURL)
			)
			let previewVC = try XCTUnwrap(generatedPreview as? WebPreviewVC)
			previewVC.loadViewIfNeeded()
			previewVC.view.appearance = NSAppearance(named: appearanceName)
			let webView = try XCTUnwrap(
				previewVC.view.subviews.compactMap { $0 as? WKWebView }.first
			)

			try await waitForWebViewToFinishLoadingAsync(webView)
			try await waitForJavaScript(
				"document.querySelector('.mermaid-diagram svg') !== null",
				in: webView
			)
			let theme = try await webView.evaluateJavaScript(
				"document.querySelector('.mermaid-diagram').dataset.glanceMermaidTheme"
			) as? String
			XCTAssertEqual(theme, expectedTheme)
		}
	}

	func testMermaidRuntimeAndLicenseAreBundled() throws {
		let bundle = WebPreviewVC.resourceBundle
		let runtimeURL = try XCTUnwrap(
			bundle.url(forResource: "markdown-mermaid-11.17.2.min", withExtension: "js")
		)
		let licenseURL = try XCTUnwrap(
			bundle.url(forResource: "MERMAID_LICENSE", withExtension: "txt")
		)

		XCTAssertGreaterThan(try Data(contentsOf: runtimeURL).count, 3_000_000)
		XCTAssertTrue(
			try String(contentsOf: licenseURL, encoding: .utf8).contains("The MIT License")
		)
	}

	func testJupyterPreviewHandlesValidNotebookAndRejectsMalformedNotebook() async throws {
		let notebook = """
		{"cells":[{"cell_type":"markdown","metadata":{},"source":["# Heading"]}],"metadata":{},"nbformat":4,"nbformat_minor":4}
		"""
		let validURL = try writeFile(named: "notebook.ipynb", contents: notebook)
		let invalidURL = try writeFile(named: "invalid.ipynb", contents: "not-json")

		let previewVC = try await JupyterPreview().createPreviewVC(file: File(url: validURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
		await XCTAssertThrowsErrorAsync {
			_ = try await JupyterPreview().createPreviewVC(file: File(url: invalidURL))
		}
	}

	func testJupyterPreviewRendersLatexDisplayOutput() async throws {
		let notebook = #"""
		{"cells":[{"cell_type":"code","metadata":{},"source":[],"outputs":[{"output_type":"execute_result","execution_count":1,"data":{"text/latex":["$\\displaystyle x^2", "+ y^2$"]}}]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
		"""#
		let fileURL = try writeFile(named: "latex-output.ipynb", contents: notebook)
		let generatedPreview = try await JupyterPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generatedPreview as? WebPreviewVC)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)

		try await waitForWebViewToFinishLoadingAsync(webView)
		let result = try await webView.evaluateJavaScript(
			"""
			[
				document.querySelector('[data-glance-latex-output="1"]') !== null,
				document.querySelector('.latex-output .katex') !== null,
				!document.body.textContent.includes('LaTeX output')
			].join('|')
			"""
		)

		XCTAssertEqual(result as? String, "true|true|true")
	}

	func testJupyterKaTeXStylesheetReferencesOnlyBundledWOFF2Fonts() throws {
		let bundle = WebPreviewVC.resourceBundle
		let stylesheetURL = try XCTUnwrap(
			bundle.url(forResource: "jupyter-katex.min", withExtension: "css")
		)
		let stylesheet = try String(contentsOf: stylesheetURL, encoding: .utf8)
		let fontReferences = try katexFontReferences(in: stylesheet)

		XCTAssertFalse(fontReferences.isEmpty)
		for fontReference in fontReferences {
			XCTAssertEqual(fontReference.pathExtension, "woff2")
			XCTAssertNotNil(
				bundle.url(
					forResource: fontReference.deletingPathExtension().lastPathComponent,
					withExtension: fontReference.pathExtension
				),
				"Missing bundled KaTeX font: \(fontReference.lastPathComponent)"
			)
		}

		let resourceURL = try XCTUnwrap(bundle.resourceURL)
		let bundledFallbackFonts = try FileManager.default
			.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
			.filter {
				$0.lastPathComponent.hasPrefix("KaTeX_")
					&& ["ttf", "woff"].contains($0.pathExtension)
			}
		XCTAssertTrue(
			bundledFallbackFonts.isEmpty,
			"Unexpected KaTeX fallback fonts: \(bundledFallbackFonts.map(\.lastPathComponent))"
		)
	}

	func testWebPreviewViewBecomesVisibleAfterLoading() throws {
		let previewVC = WebPreviewVC(html: "<p>Visible content</p>")

		previewVC.loadViewIfNeeded()

		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)
		XCTAssertFalse(webView.isHidden)
		waitForWebViewToBecomeVisible(webView)
		XCTAssertEqual(webView.alphaValue, 1)
	}

	func testWebPreviewFallbackOnlyAppliesWhileDetached() throws {
		let previewVC = WebPreviewVC(html: "<p>Fallback eligibility</p>")
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)
		XCTAssertTrue(WebPreviewVC.isDetachedRevealFallbackEligible(webView))

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.contentViewController = previewVC

		XCTAssertFalse(WebPreviewVC.isDetachedRevealFallbackEligible(webView))
	}

	func testPreviewBackgroundMatchesWebContentBeforeFirstPaintInBothAppearances() throws {
		for (appearanceName, expectedComponent) in [
			(NSAppearance.Name.aqua, CGFloat(1)),
			(NSAppearance.Name.darkAqua, CGFloat(30) / 255),
		] {
			let previewVC = WebPreviewVC(html: "<p>Matched background</p>")
			previewVC.loadViewIfNeeded()
			previewVC.view.appearance = NSAppearance(named: appearanceName)
			let backgroundView = try XCTUnwrap(previewVC.view as? PreviewBackgroundView)
			XCTAssertTrue(backgroundView.wantsLayer)
			backgroundView.viewDidChangeEffectiveAppearance()
			backgroundView.displayIfNeeded()
			let color = try XCTUnwrap(
				NSColor(cgColor: try XCTUnwrap(backgroundView.layer?.backgroundColor))?
					.usingColorSpace(.sRGB)
			)

			XCTAssertEqual(color.redComponent, expectedComponent, accuracy: 0.01)
			XCTAssertEqual(color.greenComponent, expectedComponent, accuracy: 0.01)
			XCTAssertEqual(color.blueComponent, expectedComponent, accuracy: 0.01)
		}
	}

	func testArchiveStatusIsSingleLineAndUsesAccurateSavedAndOverheadLabels() {
		let saved = ArchiveStatusFormatter.status(compressed: 50, uncompressed: 100)
		let overhead = ArchiveStatusFormatter.status(compressed: 125, uncompressed: 100)
		let empty = ArchiveStatusFormatter.status(compressed: 0, uncompressed: 0)

		XCTAssertFalse(saved.contains("\n"))
		XCTAssertTrue(saved.contains(" • "))
		XCTAssertTrue(saved.contains("Saved 50.0%"))
		XCTAssertTrue(overhead.contains("Overhead 25.0%"))
		XCTAssertFalse(empty.contains("Saved"))
		XCTAssertFalse(empty.contains("Overhead"))
	}

	func testWebPreviewRendersInlineContentAndStyles() throws {
		let previewVC = WebPreviewVC(
			html: #"<script>document.body.dataset.bad = "script"</script><p onclick="document.body.dataset.bad = 'event'">Visible content</p>"#
		)
		previewVC.loadViewIfNeeded()

		let webView = try XCTUnwrap(previewVC.view.subviews.compactMap { $0 as? WKWebView }.first)
		let expectation = expectation(description: "web preview rendered")

		waitForWebViewToFinishLoading(webView)
		webView.evaluateJavaScript(
			"""
			[
				document.body.textContent.trim(),
				document.styleSheets.length,
				document.querySelector('script') === null,
				document.querySelector('p').getAttribute('onclick') === null,
				document.body.dataset.bad || ''
			].join('|')
			"""
		) { result, error in
			XCTAssertNil(error)
			let renderedState = result as? String
			let renderedStateParts = renderedState?.split(
				separator: "|",
				omittingEmptySubsequences: false
			) ?? []
			XCTAssertEqual(renderedStateParts.count, 5)
			XCTAssertEqual(renderedStateParts.first.map(String.init), "Visible content")
			let styleSheetCount = Int(renderedStateParts.dropFirst().first ?? "0") ?? 0
			XCTAssertGreaterThan(styleSheetCount, 0)
			XCTAssertEqual(renderedStateParts.dropFirst(2).first.map(String.init), "true")
			XCTAssertEqual(renderedStateParts.dropFirst(3).first.map(String.init), "true")
			XCTAssertEqual(renderedStateParts.dropFirst(4).first.map(String.init), "")
			expectation.fulfill()
		}

		wait(for: [expectation], timeout: 5)
	}

	func testWebPreviewAppliesAppearancePreferencesToEveryRenderedFormat() async throws {
		let preferences = PreviewAppearancePreferences(
			fontFamily: "Menlo",
			fontSize: 18,
			wrapsLines: true
		)
		let formatHTML = [
			#"<pre class="chroma"><code>code</code></pre>"#,
			#"<div class="markdown-body"><pre><code>markdown</code></pre></div>"#,
			#"<div class="cell cell-code"><pre><code>notebook</code></pre></div>"#,
		]

		for html in formatHTML {
			for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
				let previewVC = WebPreviewVC(
					html: html,
					appearancePreferences: preferences,
					availableFontFamilies: ["Menlo"]
				)
				previewVC.loadViewIfNeeded()
				previewVC.view.appearance = NSAppearance(named: appearanceName)
				let webView = try XCTUnwrap(
					previewVC.view.subviews.compactMap { $0 as? WKWebView }.first
				)

				try await waitForWebViewToFinishLoadingAsync(webView)
				let state = try await webView.evaluateJavaScript(
					"""
					const code = document.querySelector('pre code');
					[
						getComputedStyle(document.body).fontSize,
						getComputedStyle(document.body).fontFamily,
						getComputedStyle(code).whiteSpace,
						getComputedStyle(code).overflowWrap
					].join('|')
					"""
				) as? String

				XCTAssertEqual(state, #"18px|Menlo, sans-serif|pre-wrap|anywhere"#)
			}
		}
	}

	func testWebPreviewRejectsUnavailableAndUnsafeFontFamilies() async throws {
		let unsafeFamily = #"Menlo\";}</style><script>document.body.dataset.bad='1'</script>"#
		let fallbackStylesheet = PreviewAppearancePreferences(
			fontFamily: "Not Installed",
			fontSize: 14,
			wrapsLines: false
		).stylesheet(availableFontFamilies: ["Menlo"])
		XCTAssertFalse(fallbackStylesheet.contains("Not Installed"))

		let previewVC = WebPreviewVC(
			html: "<pre><code>Safe content</code></pre>",
			appearancePreferences: PreviewAppearancePreferences(
				fontFamily: unsafeFamily,
				fontSize: 14,
				wrapsLines: false
			),
			availableFontFamilies: [unsafeFamily]
		)
		previewVC.loadViewIfNeeded()
		let webView = try XCTUnwrap(
			previewVC.view.subviews.compactMap { $0 as? WKWebView }.first
		)

		try await waitForWebViewToFinishLoadingAsync(webView)
		let state = try await webView.evaluateJavaScript(
			"""
			[
				document.querySelector('script') === null,
				document.body.dataset.bad || '',
				getComputedStyle(document.querySelector('pre code')).whiteSpace,
				Array.from(document.querySelectorAll('style'))
					.some(style => style.textContent.includes('</style>'))
			].join('|')
			"""
		) as? String

		XCTAssertEqual(state, "true||pre|false")
	}

	func testPreviewExecutorRunsWorkOffMainThreadAndPropagatesCancellation() async throws {
		let ranOnMainThread = try await PreviewExecutor.run { Thread.isMainThread }
		XCTAssertFalse(ranOnMainThread)

		let task = Task {
			try await PreviewExecutor.run {
				while !Task.isCancelled {
					Thread.sleep(forTimeInterval: 0.001)
				}
			}
		}
		try await Task.sleep(for: .milliseconds(10))
		task.cancel()
		await XCTAssertThrowsErrorAsync {
			try await task.value
		} errorHandler: { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	func testMainVCAsyncPreparationCompletesExactlyOnce() async throws {
		let fileURL = try writeFile(named: "prepared.swift", contents: "let prepared = true\n")
		let mainVC = MainVC()
		mainVC.containingAppIsRunning = { true }
		mainVC.loadViewIfNeeded()
		let completion = expectation(description: "preview preparation completed")
		completion.assertForOverFulfill = true

		mainVC.preparePreviewOfFile(at: fileURL) { error in
			XCTAssertNil(error)
			completion.fulfill()
		}

		await fulfillment(of: [completion], timeout: 5)
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(5))
		while !(mainVC.currentPreviewController is WebPreviewVC), clock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		XCTAssertTrue(mainVC.currentPreviewController is WebPreviewVC)
	}

	func testMainVCDeclinesUnsupportedGzipForSystemFallback() async throws {
		let fileURL = try writeFile(named: "plain.gz", contents: "not a tarball")
		let mainVC = MainVC()
		mainVC.loadViewIfNeeded()

		await XCTAssertThrowsErrorAsync {
			try await mainVC.previewFile(file: File(url: fileURL))
		} errorHandler: { error in
			XCTAssertEqual((error as NSError).code, 2)
		}
		XCTAssertNil(mainVC.currentPreviewController)
	}

	func testMainVCSupersededPreparationCompletesWithoutReplacingLatestPreview() async throws {
		let firstURL = try writeFile(named: "first.swift", contents: "let first = true\n")
		let latestURL = try writeFile(named: "latest.swift", contents: "let latest = true\n")
		let mainVC = MainVC()
		mainVC.containingAppIsRunning = { true }
		mainVC.loadViewIfNeeded()
		let firstCompletion = expectation(description: "superseded preparation completed")
		let latestCompletion = expectation(description: "latest preparation completed")
		firstCompletion.assertForOverFulfill = true
		latestCompletion.assertForOverFulfill = true

		mainVC.preparePreviewOfFile(at: firstURL) { error in
			XCTAssertNil(error)
			firstCompletion.fulfill()
		}
		mainVC.preparePreviewOfFile(at: latestURL) { error in
			XCTAssertNil(error)
			latestCompletion.fulfill()
		}

		await fulfillment(of: [firstCompletion, latestCompletion], timeout: 5)
		XCTAssertEqual(mainVC.topLevelFile?.url, latestURL)
		XCTAssertTrue(mainVC.currentPreviewController is WebPreviewVC)
	}

	func testTSVPreviewHandlesQuotedTabsUnicodeAndBlankCells() async throws {
		let tsv = """
		name\tvalue
		cafe\t"one\ttwo"
		blank\t
		"""
		let fileURL = try writeFile(named: "table.tsv", contents: tsv)

		let generatedPreview = try await TSVPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generatedPreview as? TablePreviewVC)

		XCTAssertEqual(previewVC.headers, ["name", "value"])
		XCTAssertEqual(previewVC.cells[0]["name"], "cafe")
		XCTAssertEqual(previewVC.cells[0]["value"], "one\ttwo")
		XCTAssertEqual(previewVC.cells[1]["name"], "blank")
		XCTAssertEqual(previewVC.cells[1]["value"], "")
	}

	func testTSVPreviewRejectsMalformedRows() async throws {
		let fileURL = try writeFile(
			named: "malformed.tsv",
			contents: "name\tvalue\n\"unterminated\tvalue\n"
		)

		await XCTAssertThrowsErrorAsync {
			_ = try await TSVPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testTSVPreviewRejectsTooManyColumnsBeforeRendering() async throws {
		let headers = (0 ... 512).map { "column-\($0)" }.joined(separator: "\t")
		let values = (0 ... 512).map(String.init).joined(separator: "\t")
		let fileURL = try writeFile(named: "wide.tsv", contents: "\(headers)\n\(values)\n")

		await XCTAssertThrowsErrorAsync {
			_ = try await TSVPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testTSVPreviewLimitsRowsBeforeRendering() async throws {
		let rows = (0 ... 5000).map { "row-\($0)\t\($0)" }.joined(separator: "\n")
		let tsv = "name\tvalue\n\(rows)\n"
		let fileURL = try writeFile(named: "limited.tsv", contents: tsv)

		let generatedPreview = try await TSVPreview().createPreviewVC(file: File(url: fileURL))
		let previewVC = try XCTUnwrap(generatedPreview as? TablePreviewVC)

		XCTAssertEqual(previewVC.headers, ["name", "value"])
		XCTAssertEqual(previewVC.cells.count, 5000)
		XCTAssertEqual(previewVC.cells.last?["name"], "row-4999")
	}

	func testTSVPreviewRejectsFilesOverProductionSizeLimit() async throws {
		let fileURL = temporaryDirectory.appendingPathComponent("oversized.tsv")
		XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
		let fileHandle = try FileHandle(forWritingTo: fileURL)
		try fileHandle.truncate(atOffset: 25 * 1024 * 1024 + 1)
		try fileHandle.close()

		await XCTAssertThrowsErrorAsync {
			_ = try await TSVPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testZIPPreviewHandlesNestedEntriesAndIgnoresResourceForkFolder() async throws {
		let zipRoot = temporaryDirectory.appendingPathComponent("zip-root", isDirectory: true)
		try FileManager.default.createDirectory(at: zipRoot, withIntermediateDirectories: true)
		_ = try writeFile(named: "zip-root/folder/nested file.txt", contents: "nested")
		_ = try writeFile(named: "zip-root/__MACOSX/._nested file.txt", contents: "metadata")
		let zipURL = temporaryDirectory.appendingPathComponent("archive.zip")
		try runProcess(
			"/usr/bin/zip",
			arguments: ["-qry", zipURL.path, "folder", "__MACOSX"],
			in: zipRoot
		)

		let generatedPreview = try await ZIPPreview().createPreviewVC(file: File(url: zipURL))
		let previewVC = try XCTUnwrap(generatedPreview as? OutlinePreviewVC)

		XCTAssertNotNil(node(named: "folder", in: previewVC.rootNodes))
		XCTAssertNil(node(named: "__MACOSX", in: previewVC.rootNodes))
		XCTAssertFalse(previewVC.previewStatusText.contains("\n"))
		XCTAssertTrue(previewVC.previewStatusText.contains("Compressed "))
		XCTAssertTrue(previewVC.previewStatusText.contains("Uncompressed "))
	}

	func testZIPPreviewRejectsCorruptedArchive() async throws {
		let fileURL = try writeFile(named: "corrupted.zip", contents: "not-a-zip")

		await XCTAssertThrowsErrorAsync {
			_ = try await ZIPPreview().createPreviewVC(file: File(url: fileURL))
		}
	}

	func testTARPreviewHandlesTarAndGzippedTarArchives() async throws {
		let tarRoot = temporaryDirectory.appendingPathComponent("tar-root", isDirectory: true)
		try FileManager.default.createDirectory(at: tarRoot, withIntermediateDirectories: true)
		_ = try writeFile(named: "tar-root/folder/nested file.txt", contents: "nested")
		_ = try writeFile(named: "tar-root/folder/unicode-\u{00E9}.txt", contents: "unicode")
		let tarURL = temporaryDirectory.appendingPathComponent("archive.tar")
		let tgzURL = temporaryDirectory.appendingPathComponent("archive.tgz")
		try runProcess(
			"/usr/bin/tar",
			arguments: ["-cf", tarURL.path, "-C", tarRoot.path, "folder"]
		)
		try runProcess(
			"/usr/bin/tar",
			arguments: ["-czf", tgzURL.path, "-C", tarRoot.path, "folder"]
		)

		let generatedTARPreview = try await TARPreview().createPreviewVC(file: File(url: tarURL))
		let tarPreviewVC = try XCTUnwrap(generatedTARPreview as? OutlinePreviewVC)
		let generatedTGZPreview = try await TARPreview().createPreviewVC(file: File(url: tgzURL))
		let tgzPreviewVC = try XCTUnwrap(generatedTGZPreview as? OutlinePreviewVC)

		XCTAssertNotNil(node(named: "folder", in: tarPreviewVC.rootNodes))
		XCTAssertNotNil(node(named: "folder", in: tgzPreviewVC.rootNodes))
	}

	func testTARPreviewSkipsLargeFilePayloadsWhileBuildingTree() async throws {
		let tarRoot = temporaryDirectory.appendingPathComponent("large-tar-root", isDirectory: true)
		try FileManager.default.createDirectory(at: tarRoot, withIntermediateDirectories: true)
		let largeFileURL = tarRoot.appendingPathComponent("large.bin")
		XCTAssertTrue(FileManager.default.createFile(atPath: largeFileURL.path, contents: nil))
		let largeFileHandle = try FileHandle(forWritingTo: largeFileURL)
		let chunk = Data(repeating: 0, count: 1_000_000)
		for _ in 0 ..< 12 {
			try largeFileHandle.write(contentsOf: chunk)
		}
		try largeFileHandle.close()

		let tarURL = temporaryDirectory.appendingPathComponent("large.tar")
		try runProcess(
			"/usr/bin/tar",
			arguments: ["-cf", tarURL.path, "-C", tarRoot.path, "large.bin"]
		)

		let generatedPreview = try await TARPreview().createPreviewVC(file: File(url: tarURL))
		let previewVC = try XCTUnwrap(generatedPreview as? OutlinePreviewVC)

		let largeFileNode = try XCTUnwrap(node(named: "large.bin", in: previewVC.rootNodes))
		XCTAssertEqual(largeFileNode.size, 12_000_000)
	}

	func testTARPreviewRejectsOverflowingPayloadOffsetWithoutTrapping() async throws {
		let tarData = tarHeader(
			name: "huge.bin",
			sizeField: tarBase256Size(Int64.max - 511)
		)
		let tarURL = try writeDataFile(named: "overflow.tar", data: tarData)

		await XCTAssertThrowsErrorAsync {
			_ = try await TARPreview().createPreviewVC(file: File(url: tarURL))
		}
	}

	func testArchivePreviewsRejectCorruptedTarAndSevenZipFiles() async throws {
		let tarURL = try writeFile(named: "corrupted.tar", contents: "not-a-tar")
		let sevenZipURL = try writeFile(named: "corrupted.7z", contents: "not-a-sevenzip")

		await XCTAssertThrowsErrorAsync {
			_ = try await TARPreview().createPreviewVC(file: File(url: tarURL))
		}
		await XCTAssertThrowsErrorAsync {
			_ = try await SevenZipPreview().createPreviewVC(file: File(url: sevenZipURL))
		}
	}

	func testSevenZipPreviewHandlesEncodedHeaderFixture() async throws {
		let fixture = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles/archives/example.7z")
		let generatedPreview = try await SevenZipPreview().createPreviewVC(file: File(url: fixture))
		let previewVC = try XCTUnwrap(generatedPreview as? OutlinePreviewVC)

		XCTAssertNotNil(node(named: "hello.txt", in: previewVC.rootNodes))
		XCTAssertNotNil(node(named: "unicode-ș.txt", in: previewVC.rootNodes))
	}

	func testSevenZipPreviewRejectsFilesOverProductionSizeLimit() async throws {
		let sevenZipURL = temporaryDirectory.appendingPathComponent("oversized.7z")
		XCTAssertTrue(FileManager.default.createFile(atPath: sevenZipURL.path, contents: nil))
		let fileHandle = try FileHandle(forWritingTo: sevenZipURL)
		try fileHandle.truncate(atOffset: 200 * 1024 * 1024 + 1)
		try fileHandle.close()

		await XCTAssertThrowsErrorAsync {
			_ = try await SevenZipPreview().createPreviewVC(file: File(url: sevenZipURL))
		}
	}

	func testRARPreviewHandlesRAR4AndRAR5Fixtures() async throws {
		let fixtures = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles/archives", isDirectory: true)
		let rar4Preview = try await RARPreview().createPreviewVC(
			file: File(url: fixtures.appendingPathComponent("example-rar4.rar"))
		)
		let rar5Preview = try await RARPreview().createPreviewVC(
			file: File(url: fixtures.appendingPathComponent("example-rar5.rar"))
		)
		let rar4VC = try XCTUnwrap(rar4Preview as? OutlinePreviewVC)
		let rar5VC = try XCTUnwrap(rar5Preview as? OutlinePreviewVC)

		XCTAssertNotNil(node(named: "payload.txt", in: rar4VC.rootNodes))
		XCTAssertNotNil(node(named: "hello.txt", in: rar5VC.rootNodes))
		XCTAssertFalse(rar4VC.previewStatusText.contains("\n"))
		XCTAssertTrue(rar5VC.previewStatusText.contains("Compressed "))
	}

	func testRARPreviewRejectsMalformedEncryptedAndMultipartArchives() async throws {
		let fixtures = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles/archives", isDirectory: true)
		let malformed = try writeFile(named: "malformed.rar", contents: "not-a-rar")
		let rejectedURLs = [
			malformed,
			fixtures.appendingPathComponent("encrypted-rar5.rar"),
			fixtures.appendingPathComponent("multipart-rar5.rar"),
		]

		for rejectedURL in rejectedURLs {
			await XCTAssertThrowsErrorAsync {
				_ = try await RARPreview().createPreviewVC(file: File(url: rejectedURL))
			}
		}
	}

	func testParserPerformance() async throws {
		guard ProcessInfo.processInfo.environment["GLANCE_RUN_PARSER_BENCHMARKS"] == "1" else {
			throw XCTSkip("Set GLANCE_RUN_PARSER_BENCHMARKS=1 to collect parser baselines")
		}

		let fixtures = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles", isDirectory: true)
		try await benchmarkParser("tsv") {
			_ = try await TSVPreview().createPreviewVC(
				file: File(url: fixtures.appendingPathComponent("tsv/example.tsv"))
			)
		}
		try await benchmarkParser("zip") {
			_ = try await ZIPPreview().createPreviewVC(
				file: File(url: fixtures
					.appendingPathComponent("archives/example-root-directory.zip"))
			)
		}
		try await benchmarkParser("tar") {
			_ = try await TARPreview().createPreviewVC(
				file: File(url: fixtures
					.appendingPathComponent("archives/example-root-directory.tar"))
			)
		}
		try await benchmarkParser("tgz") {
			_ = try await TARPreview().createPreviewVC(
				file: File(url: fixtures.appendingPathComponent("archives/example.tar.gz"))
			)
		}
		try await benchmarkParser("7z") {
			_ = try await SevenZipPreview().createPreviewVC(
				file: File(url: fixtures.appendingPathComponent("archives/example.7z"))
			)
		}
		try await benchmarkParser("rar") {
			_ = try await RARPreview().createPreviewVC(
				file: File(url: fixtures.appendingPathComponent("archives/example-rar5.rar"))
			)
		}
	}

	private func writeFile(named name: String, contents: String) throws -> URL {
		let fileURL = temporaryDirectory.appendingPathComponent(name)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try contents.write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}

	private static func drawIODocument(label: String) -> String {
		let escapedLabel = label
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		return """
		<mxfile host="app.diagrams.net">
		  <diagram name="Page-1">
		    <mxGraphModel dx="800" dy="500" grid="1" gridSize="10" page="1" pageWidth="827" pageHeight="1169">
		      <root>
		        <mxCell id="0"/>
		        <mxCell id="1" parent="0"/>
		        <mxCell
		          id="2"
		          value="\(escapedLabel)"
		          style="rounded=1;whiteSpace=wrap;html=1;fillColor=light-dark(#ffffff,#1e1e1e);fontColor=light-dark(#000000,#f5f5f5);"
		          vertex="1"
		          parent="1"
		        >
		          <mxGeometry x="40" y="40" width="180" height="80" as="geometry"/>
		        </mxCell>
		      </root>
		    </mxGraphModel>
		  </diagram>
		</mxfile>
		"""
	}

	private func writeDataFile(named name: String, data: Data) throws -> URL {
		let fileURL = temporaryDirectory.appendingPathComponent(name)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try data.write(to: fileURL, options: .atomic)
		return fileURL
	}

	private func node(named name: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
		for node in nodes {
			if node.name == name {
				return node
			}
			if let childNode = self.node(named: name, in: node.childrenList) {
				return childNode
			}
		}
		return nil
	}

	private func waitForWebViewToFinishLoading(_ webView: WKWebView, timeout: TimeInterval = 5) {
		let deadline = Date().addingTimeInterval(timeout)
		while webView.isLoading, Date() < deadline {
			RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
		}
		XCTAssertFalse(
			webView.isLoading,
			"Web view did not finish loading within \(timeout) seconds"
		)
	}

	private func waitForWebViewToFinishLoadingAsync(
		_ webView: WKWebView,
		timeout: Duration = .seconds(5)
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while webView.isLoading, clock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		XCTAssertFalse(webView.isLoading, "Web view did not finish loading within \(timeout)")
	}

	private func waitForJavaScript(
		_ expression: String,
		in webView: WKWebView,
		timeout: Duration = .seconds(5)
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while clock.now < deadline {
			if try await webView.evaluateJavaScript(expression) as? Bool == true {
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		XCTFail("JavaScript condition did not become true: \(expression)")
	}

	private func waitForWebViewToBecomeVisible(_ webView: WKWebView, timeout: TimeInterval = 15) {
		let deadline = Date().addingTimeInterval(timeout)
		while webView.alphaValue != 1, Date() < deadline {
			RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
		}
		XCTAssertEqual(webView.alphaValue, 1)
	}

	private func runProcess(
		_ executable: String,
		arguments: [String],
		in directory: URL? = nil
	) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.currentDirectoryURL = directory

		let outputPipe = Pipe()
		process.standardOutput = outputPipe
		process.standardError = outputPipe

		try process.run()
		process.waitUntilExit()

		guard process.terminationStatus == 0 else {
			let output = String(
				data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8
			) ?? ""
			throw ProcessError(
				command: ([executable] + arguments).joined(separator: " "),
				output: output
			)
		}
	}

	private func benchmarkParser(
		_ name: String,
		iterations: Int = 31,
		operation: () async throws -> Void
	) async throws {
		try await operation()
		var durations = [UInt64]()
		durations.reserveCapacity(iterations)
		for _ in 0 ..< iterations {
			let start = DispatchTime.now().uptimeNanoseconds
			try await operation()
			durations.append(DispatchTime.now().uptimeNanoseconds - start)
		}
		durations.sort()
		let median = durations[durations.count / 2]
		let p95Index = (durations.count * 95 + 99) / 100 - 1
		let p95 = durations[p95Index]
		print(
			String(
				format: "PARSER %@ median=%.3fms p95=%.3fms",
				name,
				Double(median) / 1_000_000,
				Double(p95) / 1_000_000
			)
		)
	}

	private func XCTAssertThrowsErrorAsync(
		_ operation: () async throws -> Void,
		errorHandler: (Error) -> Void = { _ in },
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		do {
			try await operation()
			XCTFail("Expected operation to throw", file: file, line: line)
		} catch {
			errorHandler(error)
		}
	}

	private func katexFontReferences(in stylesheet: String) throws -> [URL] {
		let expression = try NSRegularExpression(pattern: #"url\(([^)]+)\)"#)
		let matches = expression.matches(
			in: stylesheet,
			range: NSRange(stylesheet.startIndex ..< stylesheet.endIndex, in: stylesheet)
		)

		return matches.compactMap { match -> URL? in
			guard let range = Range(match.range(at: 1), in: stylesheet) else {
				return nil
			}
			let rawReference = String(stylesheet[range])
				.trimmingCharacters(in: CharacterSet(charactersIn: #""' "#))
			guard rawReference.hasPrefix("KaTeX_") else {
				return nil
			}
			return URL(fileURLWithPath: rawReference)
		}
	}

	private func tarHeader(
		name: String,
		sizeField: [UInt8],
		typeFlag: UInt8 = UInt8(ascii: "0")
	) -> Data {
		var header = Data(repeating: 0, count: 512)
		write(Array(name.utf8), to: &header, at: 0, maxLength: 100)
		write(sizeField, to: &header, at: 124, maxLength: 12)
		header[156] = typeFlag

		for index in 148 ..< 156 {
			header[index] = UInt8(ascii: " ")
		}
		let checksum = header.reduce(0) { $0 + Int($1) }
		let checksumBytes = Array(String(format: "%06o", checksum).utf8) + [0, UInt8(ascii: " ")]
		write(checksumBytes, to: &header, at: 148, maxLength: 8)
		return header
	}

	private func tarBase256Size(_ value: Int64) -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: 12)
		var remaining = UInt64(bitPattern: value)
		for index in stride(from: 11, through: 0, by: -1) {
			bytes[index] = UInt8(remaining & 0xFF)
			remaining >>= 8
		}
		bytes[0] |= 0x80
		return bytes
	}

	private func write(_ bytes: [UInt8], to data: inout Data, at offset: Int, maxLength: Int) {
		for (index, byte) in bytes.prefix(maxLength).enumerated() {
			data[offset + index] = byte
		}
	}
}

private struct ProcessError: Error, CustomStringConvertible {
	let command: String
	let output: String

	var description: String {
		"Command failed: \(command)\n\(output)"
	}
}
