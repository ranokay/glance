import Foundation
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
			backgroundView.updateLayer()
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
