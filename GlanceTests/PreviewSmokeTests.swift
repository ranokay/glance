import Foundation
import WebKit
import XCTest

@MainActor
final class PreviewSmokeTests: XCTestCase {
	private var temporaryDirectoryURL: URL?

	func testCodePreviewHandlesEmptyAndUnicodeSource() throws {
		let fileURL = try writeFile(named: "unicode.swift", contents: "let cafe = \"\u{2615}\"\n")

		let previewVC = try CodePreview().createPreviewVC(file: File(url: fileURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
	}

	func testMarkdownPreviewHandlesFrontMatterAndRawHTML() throws {
		let markdown = """
		---
		title: Fixture
		---

		# Heading

		<script>alert("bad")</script>
		"""
		let fileURL = try writeFile(named: "README.md", contents: markdown)

		let previewVC = try MarkdownPreview().createPreviewVC(file: File(url: fileURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
	}

	func testJupyterPreviewHandlesValidNotebookAndRejectsMalformedNotebook() throws {
		let notebook = """
		{"cells":[{"cell_type":"markdown","metadata":{},"source":["# Heading"]}],"metadata":{},"nbformat":4,"nbformat_minor":4}
		"""
		let validURL = try writeFile(named: "notebook.ipynb", contents: notebook)
		let invalidURL = try writeFile(named: "invalid.ipynb", contents: "not-json")

		let previewVC = try JupyterPreview().createPreviewVC(file: File(url: validURL))

		XCTAssertTrue(previewVC is WebPreviewVC)
		XCTAssertThrowsError(try JupyterPreview().createPreviewVC(file: File(url: invalidURL)))
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

	func testTSVPreviewHandlesQuotedTabsUnicodeAndBlankCells() throws {
		let tsv = """
		name\tvalue
		cafe\t"one\ttwo"
		blank\t
		"""
		let fileURL = try writeFile(named: "table.tsv", contents: tsv)

		let previewVC = try XCTUnwrap(
			TSVPreview().createPreviewVC(file: File(url: fileURL)) as? TablePreviewVC
		)

		XCTAssertEqual(previewVC.headers, ["name", "value"])
		XCTAssertEqual(previewVC.cells[0]["name"], "cafe")
		XCTAssertEqual(previewVC.cells[0]["value"], "one\ttwo")
		XCTAssertEqual(previewVC.cells[1]["name"], "blank")
		XCTAssertEqual(previewVC.cells[1]["value"], "")
	}

	func testTSVPreviewToleratesMalformedQuotesAsCellText() throws {
		let fileURL = try writeFile(
			named: "malformed.tsv",
			contents: "name\tvalue\n\"unterminated\tvalue\n"
		)

		let previewVC = try XCTUnwrap(
			TSVPreview().createPreviewVC(file: File(url: fileURL)) as? TablePreviewVC
		)

		XCTAssertEqual(previewVC.headers, ["name", "value"])
		XCTAssertEqual(previewVC.cells.count, 1)
	}

	func testTSVPreviewRejectsTooManyColumnsBeforeRendering() throws {
		let fileURL = try writeFile(named: "wide.tsv", contents: "a\tb\tc\n1\t2\t3\n")

		XCTAssertThrowsError(
			try TSVPreview(maxRows: 10, maxColumns: 2)
				.createPreviewVC(file: File(url: fileURL))
		)
	}

	func testTSVPreviewLimitsRowsBeforeRendering() throws {
		let tsv = """
		name\tvalue
		one\t1
		two\t2
		three\t3
		"""
		let fileURL = try writeFile(named: "limited.tsv", contents: tsv)

		let previewVC = try XCTUnwrap(
			TSVPreview(maxRows: 2, maxColumns: 2)
				.createPreviewVC(file: File(url: fileURL)) as? TablePreviewVC
		)

		XCTAssertEqual(previewVC.headers, ["name", "value"])
		XCTAssertEqual(previewVC.cells.count, 2)
		XCTAssertEqual(previewVC.cells[1]["name"], "two")
	}

	func testTSVPreviewRejectsFilesOverConfiguredSizeBeforeParsing() throws {
		let fileURL = try writeFile(named: "oversized.tsv", contents: "name\nvalue\n")

		XCTAssertThrowsError(
			try TSVPreview(maxFileSize: 1, maxRows: 10, maxColumns: 1)
				.createPreviewVC(file: File(url: fileURL))
		)
	}

	func testZIPPreviewHandlesNestedEntriesAndIgnoresResourceForkFolder() throws {
		let temporaryDirectory = try temporaryDirectory()
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

		let previewVC = try XCTUnwrap(
			ZIPPreview().createPreviewVC(file: File(url: zipURL)) as? OutlinePreviewVC
		)

		XCTAssertNotNil(node(named: "folder", in: previewVC.rootNodes))
		XCTAssertNil(node(named: "__MACOSX", in: previewVC.rootNodes))
	}

	func testZIPPreviewRejectsCorruptedArchive() throws {
		let fileURL = try writeFile(named: "corrupted.zip", contents: "not-a-zip")

		XCTAssertThrowsError(try ZIPPreview().createPreviewVC(file: File(url: fileURL)))
	}

	func testZIPPreviewRejectsOversizedMetadataValuesBeforeConvertingToInt() throws {
		XCTAssertThrowsError(try ZIPPreview.checkedArchiveSize(UInt64(Int.max) + 1))
	}

	func testTARPreviewHandlesTarAndGzippedTarArchives() throws {
		let temporaryDirectory = try temporaryDirectory()
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

		let tarPreviewVC = try XCTUnwrap(
			TARPreview().createPreviewVC(file: File(url: tarURL)) as? OutlinePreviewVC
		)
		let tgzPreviewVC = try XCTUnwrap(
			TARPreview().createPreviewVC(file: File(url: tgzURL)) as? OutlinePreviewVC
		)

		XCTAssertNotNil(node(named: "folder", in: tarPreviewVC.rootNodes))
		XCTAssertNotNil(node(named: "folder", in: tgzPreviewVC.rootNodes))
	}

	func testTARPreviewSkipsLargeFilePayloadsWhileBuildingTree() throws {
		let temporaryDirectory = try temporaryDirectory()
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

		let previewVC = try XCTUnwrap(
			TARPreview().createPreviewVC(file: File(url: tarURL)) as? OutlinePreviewVC
		)

		let largeFileNode = try XCTUnwrap(node(named: "large.bin", in: previewVC.rootNodes))
		XCTAssertEqual(largeFileNode.size, 12_000_000)
	}

	func testTARPreviewRejectsOverflowingPayloadOffsetWithoutTrapping() throws {
		let tarData = tarHeader(
			name: "huge.bin",
			sizeField: tarBase256Size(Int64.max - 511)
		)
		let tarURL = try writeDataFile(named: "overflow.tar", data: tarData)

		XCTAssertThrowsError(try TARPreview().createPreviewVC(file: File(url: tarURL)))
	}

	func testArchivePreviewsRejectCorruptedTarAndSevenZipFiles() throws {
		let tarURL = try writeFile(named: "corrupted.tar", contents: "not-a-tar")
		let sevenZipURL = try writeFile(named: "corrupted.7z", contents: "not-a-sevenzip")

		XCTAssertThrowsError(try TARPreview().createPreviewVC(file: File(url: tarURL)))
		XCTAssertThrowsError(try SevenZipPreview().createPreviewVC(file: File(url: sevenZipURL)))
	}

	func testSevenZipPreviewRejectsFilesOverConfiguredSizeBeforeParsing() throws {
		let sevenZipURL = try writeDataFile(
			named: "oversized.7z",
			data: Data(repeating: 0, count: 2)
		)

		XCTAssertThrowsError(
			try SevenZipPreview(maxArchiveFileSize: 1, maxEntryCount: 10)
				.createPreviewVC(file: File(url: sevenZipURL))
		)
	}

	func testSevenZipPreviewRejectsUnencodedHeaderFileCountBeforeLibraryParsing() throws {
		let sevenZipURL = try writeDataFile(
			named: "too-many-files.7z",
			data: sevenZipUnencodedFileInfoHeader(numFiles: 2)
		)

		XCTAssertThrowsError(
			try SevenZipPreview(maxArchiveFileSize: 1024, maxEntryCount: 1)
				.createPreviewVC(file: File(url: sevenZipURL))
		)
	}

	func testSevenZipPreviewRejectsMalformedUnencodedHeaderDuringPreflight() throws {
		let sevenZipURL = try writeDataFile(
			named: "malformed-header.7z",
			data: sevenZipSignatureHeader(nextHeader: Data([0x01, 0x99]))
		)

		XCTAssertThrowsError(
			try SevenZipPreview(maxArchiveFileSize: 1024, maxEntryCount: 10)
				.createPreviewVC(file: File(url: sevenZipURL))
		) { error in
			XCTAssertEqual(String(describing: error), "malformedHeader")
		}
	}

	private func writeFile(named name: String, contents: String) throws -> URL {
		let fileURL = try temporaryDirectory().appendingPathComponent(name)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try contents.write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}

	private func writeDataFile(named name: String, data: Data) throws -> URL {
		let fileURL = try temporaryDirectory().appendingPathComponent(name)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try data.write(to: fileURL, options: .atomic)
		return fileURL
	}

	private func temporaryDirectory() throws -> URL {
		if let temporaryDirectoryURL {
			return temporaryDirectoryURL
		}

		let directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlancePreviewTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)
		temporaryDirectoryURL = directoryURL
		addTeardownBlock {
			try? FileManager.default.removeItem(at: directoryURL)
		}
		return directoryURL
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
		XCTAssertFalse(webView.isLoading)
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

	private func sevenZipUnencodedFileInfoHeader(numFiles: UInt8) -> Data {
		sevenZipSignatureHeader(nextHeader: Data([0x01, 0x05, numFiles]))
	}

	private func sevenZipSignatureHeader(nextHeader: Data) -> Data {
		var data = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04])
		data.append(Data(repeating: 0, count: 4))
		appendLittleEndianUInt64(0, to: &data)

		appendLittleEndianUInt64(UInt64(nextHeader.count), to: &data)
		data.append(Data(repeating: 0, count: 4))
		data.append(nextHeader)
		return data
	}

	private func appendLittleEndianUInt64(_ value: UInt64, to data: inout Data) {
		for index in 0 ..< 8 {
			data.append(UInt8((value >> (8 * index)) & 0xFF))
		}
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
