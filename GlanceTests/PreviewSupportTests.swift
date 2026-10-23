import GlanceKit
import XCTest

final class PreviewSupportTests: XCTestCase {
	func testSupportedPreviewRegistryIDsAreUnique() {
		let ids = SupportedPreviewRegistry.all.map(\.id)

		XCTAssertEqual(Set(ids).count, ids.count)
	}

	func testSupportedPreviewRegistryMatchesAliasesAndFallbacks() {
		let cases: [(path: String, expectedID: String?, expectedType: PreviewFileType)] = [
			("/tmp/diagram.drawio", "diagram.extension.drawio", .drawIO),
			("/tmp/book.epub", "ebook.extension.epub", .epub),
			("/tmp/track.flac", "audio.extension.flac", .flac),
			("/tmp/archive.tar.gz", "archive.extension.tar-gz", .tar),
			("/tmp/model.3mf", "archive.extension.3mf", .threeMF),
			("/tmp/ARCHIVE.TAR.GZ", "archive.extension.tar-gz", .tar),
			("/tmp/readme.md", "markdown.extension.md", .markdown),
			("/tmp/README.MD", "markdown.extension.md", .markdown),
			("/tmp/readme.markdown", "markdown.extension.markdown", .markdown),
			("/tmp/notebook.ipynb", "jupyter.extension.ipynb", .jupyter),
			("/tmp/table.tsv", "tsv.extension.tsv", .tsv),
			("/tmp/workbook.xlsx", "spreadsheet.extension.xlsx", .spreadsheet),
			("/tmp/archive.zip", "archive.extension.zip", .zip),
			("/tmp/archive.7z", "archive.extension.7z", .sevenZip),
			("/tmp/archive.rar", "archive.extension.rar", .rar),
			("/tmp/.elrc", "code.extension.elrc", .code),
			("/tmp/config.elrc", "code.extension.elrc", .code),
			("/tmp/config.ini", "code.extension.ini", .code),
			("/tmp/CONFIG.INI", "code.extension.ini", .code),
			("/tmp/component.ts", "code.extension.ts", .code),
			("/tmp/COMPONENT.TS", "code.extension.ts", .code),
			("/tmp/view.tmpl", "code.extension.tmpl", .code),
			("/tmp/events.jsonl", "code.extension.jsonl", .code),
			("/tmp/Makefile", "code.filename.makefile", .code),
			("/tmp/example.unknownext", "code.other-source-text", .code),
			("/tmp/plain.gz", nil, .unsupported),
		]

		for testCase in cases {
			let fileURL = URL(fileURLWithPath: testCase.path)
			XCTAssertEqual(
				SupportedPreviewRegistry.entry(matching: fileURL)?.id,
				testCase.expectedID,
				testCase.path
			)
			XCTAssertEqual(
				PreviewSupport.getPreviewFileType(fileURL: fileURL),
				testCase.expectedType,
				testCase.path
			)
		}
	}

	func testPreviewTypeUsesSpecializedPreviewForSupportedExtensionAliases() {
		let cases: [(path: String, expected: PreviewFileType)] = [
			("/tmp/book.epub", .epub),
			("/tmp/track.flac", .flac),
			("/tmp/readme.md", .markdown),
			("/tmp/readme.markdown", .markdown),
			("/tmp/readme.mdown", .markdown),
			("/tmp/readme.mkdn", .markdown),
			("/tmp/readme.mkd", .markdown),
			("/tmp/readme.rmd", .markdown),
			("/tmp/readme.qmd", .markdown),
			("/tmp/notebook.ipynb", .jupyter),
			("/tmp/archive.tar", .tar),
			("/tmp/archive.tgz", .tar),
			("/tmp/archive.tar.gz", .tar),
			("/tmp/model.3mf", .threeMF),
			("/tmp/table.tab", .tsv),
			("/tmp/table.tsv", .tsv),
			("/tmp/workbook.xlsx", .spreadsheet),
			("/tmp/archive.7z", .sevenZip),
			("/tmp/archive.rar", .rar),
			("/tmp/archive.ear", .zip),
			("/tmp/archive.jar", .zip),
			("/tmp/archive.war", .zip),
			("/tmp/archive.zip", .zip),
			("/tmp/archive.gz", .unsupported),
			("/tmp/.elrc", .code),
			("/tmp/config.elrc", .code),
			("/tmp/config.ini", .code),
			("/tmp/source.swift", .code),
			("/tmp/component.ts", .code),
			("/tmp/view.tmpl", .code),
		]

		for testCase in cases {
			let fileURL = URL(fileURLWithPath: testCase.path)
			XCTAssertEqual(
				PreviewSupport.getPreviewFileType(fileURL: fileURL),
				testCase.expected,
				testCase.path
			)
		}
	}

	func testPreviewTypeIsCaseInsensitive() {
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/README.MD")),
			.markdown
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/ARCHIVE.TAR.GZ")),
			.tar
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/ARCHIVE.ZIP")),
			.zip
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/ARCHIVE.RAR")),
			.rar
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/BOOK.EPUB")),
			.epub
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/TRACK.FLAC")),
			.flac
		)
	}

	func testCodeLexerUsesDotfileMappings() {
		let cases = [
			(".bashrc", ".bashrc"),
			(".elrc", "elisp"),
			(".vimrc", ".vimrc"),
			(".zprofile", "zsh"),
			(".zshrc", ".zshrc"),
			("Dockerfile", "Dockerfile"),
			("Gemfile", "Gemfile"),
			("GNUmakefile", "Makefile"),
			("Makefile", "Makefile"),
			("PKGBUILD", "PKGBUILD"),
			("Rakefile", "Rakefile"),
			(".dockerignore", "bash"),
			(".editorconfig", "ini"),
			(".gitattributes", "bash"),
			(".gitconfig", "ini"),
			(".gitignore", "bash"),
			(".npmignore", "bash"),
			(".zsh_history", "txt"),
		]

		for (fileName, lexer) in cases {
			let fileURL = URL(fileURLWithPath: "/tmp/\(fileName)")
			XCTAssertEqual(PreviewSupport.getCodeLexer(fileURL: fileURL), lexer, fileName)
		}
	}

	func testCodeLexerUsesExtensionMappings() {
		let cases = [
			("sinf", "txt"),
			("wdl", "txt"),
			("sv", "systemverilog"),
			("svh", "systemverilog"),
			("slurm", "bash"),
			("dat", "txt"),
			("asc", "txt"),
			("xy", "txt"),
			("xye", "txt"),
			("out", "txt"),
			("inp", "txt"),
			("cif", "txt"),
			("xyz", "txt"),
			("gzmat", "txt"),
			("alfredappearance", "json"),
			("mobileconfig", "xml"),
			("cjs", "js"),
			("cls", "tex"),
			("csproj", "xml"),
			("elrc", "elisp"),
			("entitlements", "xml"),
			("hbs", "handlebars"),
			("iml", "xml"),
			("ini", "ini"),
			("jsonl", "json"),
			("mjs", "js"),
			("plist", "xml"),
			("props", "xml"),
			("resolved", "json"),
			("scpt", "applescript"),
			("scptd", "applescript"),
			("spf", "xml"),
			("spTheme", "xml"),
			("storyboard", "xml"),
			("stringsdict", "xml"),
			("sty", "tex"),
			("targets", "xml"),
			("tmpl", "tmpl"),
			("ts", "ts"),
			("webmanifest", "json"),
			("xcscheme", "xml"),
			("xib", "xml"),
			("xmp", "xml"),
			("ass", "txt"),
			("liquid", "twig"),
			("lrc", "txt"),
			("modulemap", "hcl"),
			("nfo", "txt"),
			("njk", "twig"),
			("pbxproj", "txt"),
			("sln", "txt"),
			("srt", "txt"),
			("strings", "c"),
			("ttml", "xml"),
			("vtt", "txt"),
		]

		for (fileExtension, lexer) in cases {
			let fileURL = URL(fileURLWithPath: "/tmp/example.\(fileExtension)")
			XCTAssertEqual(
				PreviewSupport.getCodeLexer(fileURL: fileURL),
				lexer,
				fileExtension
			)
		}
	}

	func testDotenvVariantsUseDotenvHighlighting() {
		let fileNames = [
			".env",
			".env.preview",
			".env.development.local",
			".ENV.PRODUCTION",
		]

		for fileName in fileNames {
			let fileURL = URL(fileURLWithPath: "/tmp/\(fileName)")
			XCTAssertEqual(
				SupportedPreviewRegistry.entry(matching: fileURL)?.id,
				"code.filename.env",
				fileName
			)
			XCTAssertEqual(PreviewSupport.getCodeLexer(fileURL: fileURL), "dotenv", fileName)
		}
	}

	func testRequestedSourceAndDataFormatsUseCodePreview() {
		let fileExtensions = [
			"sinf", "wdl", "sv", "svh", "slurm",
			"dat", "asc", "xy", "xye", "out", "inp", "cif", "xyz", "gzmat",
		]

		for fileExtension in fileExtensions {
			let fileURL = URL(fileURLWithPath: "/tmp/example.\(fileExtension)")
			XCTAssertEqual(
				PreviewSupport.getPreviewFileType(fileURL: fileURL),
				.code,
				fileExtension
			)
			XCTAssertEqual(
				SupportedPreviewRegistry.entry(matching: fileURL)?.id,
				"code.extension.\(fileExtension)",
				fileExtension
			)
		}

		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/.env.local")),
			.code
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/.env.ipynb")),
			.jupyter
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/.env.tsv")),
			.tsv
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/.env.zip")),
			.zip
		)
		XCTAssertEqual(
			PreviewSupport.getPreviewFileType(fileURL: URL(fileURLWithPath: "/tmp/.env.md")),
			.markdown
		)
	}

	func testCodeLexerRecursesThroughDistExtension() {
		XCTAssertEqual(
			PreviewSupport.getCodeLexer(fileURL: URL(fileURLWithPath: "/tmp/example.swift.dist")),
			"swift"
		)
		XCTAssertEqual(
			PreviewSupport.getCodeLexer(fileURL: URL(fileURLWithPath: "/tmp/example.spTheme.dist")),
			"xml"
		)
	}

	func testCodeLexerFallsBackToExtensionOrAutodetect() {
		XCTAssertEqual(
			PreviewSupport.getCodeLexer(fileURL: URL(fileURLWithPath: "/tmp/example.unknownext")),
			"unknownext"
		)
		XCTAssertEqual(
			PreviewSupport.getCodeLexer(fileURL: URL(fileURLWithPath: "/tmp/unknown-dotless-file")),
			"autodetect"
		)
	}
}

@MainActor
final class PreviewSettingsBridgeTests: XCTestCase {
	private let center = StubPreviewSettingsBridgeCenter()

	func testBridgeResponseRoundTripsEveryField() {
		let snapshot = PreviewPreferenceSnapshot(
			waveformEnabled: false,
			appearance: PreviewAppearancePreferences(
				fontFamily: "SF Mono",
				fontSize: 21.5,
				wrapsLines: true
			)
		)
		let encoded = PreviewSettingsBridge.response(for: UUID(), snapshot: snapshot)

		guard let (_, decoded) = PreviewSettingsBridge.decode(encoded) else {
			XCTFail("Encoded snapshot \(encoded) failed to decode")
			return
		}
		XCTAssertEqual(decoded, snapshot)
	}

	func testBridgeResponseRepresentsMissingFamilyWithSentinel() {
		let snapshot = PreviewPreferenceSnapshot(
			waveformEnabled: true,
			appearance: .default
		)
		let encoded = PreviewSettingsBridge.response(for: UUID(), snapshot: snapshot)

		XCTAssertTrue(encoded.contains(PreviewSettingsBridge.familySentinel))
		guard let (_, decoded) = PreviewSettingsBridge.decode(encoded) else {
			XCTFail("Encoded snapshot \(encoded) failed to decode")
			return
		}
		XCTAssertNil(decoded.appearance.fontFamily)
		XCTAssertEqual(decoded, snapshot)
	}

	func testBridgeDecodeRejectsMalformedPayloads() {
		let id = UUID().uuidString
		let outOfRangeSize = "\(id)|1|-|320|0"
		let tooFewParts = "\(id)|1|-"
		let badWaveform = "\(id)|2|-|14|0"
		let badWrap = "\(id)|1|-|14|9"
		let undecodableFamily = "\(id)|1|%zz|14|0"

		XCTAssertNil(PreviewSettingsBridge.decode(outOfRangeSize))
		XCTAssertNil(PreviewSettingsBridge.decode(tooFewParts))
		XCTAssertNil(PreviewSettingsBridge.decode(badWaveform))
		XCTAssertNil(PreviewSettingsBridge.decode(badWrap))
		XCTAssertNil(PreviewSettingsBridge.decode(undecodableFamily))
	}

	func testClientFallsBackToDefaultsOnTimeout() async {
		let neverRespondingCenter = StubPreviewSettingsBridgeCenter()
		let client = PreviewSettingsClient(
			notificationCenter: neverRespondingCenter,
			timeout: .milliseconds(20)
		)

		let appearance = await client.appearancePreferences()

		XCTAssertEqual(appearance, PreviewAppearancePreferences.default)
	}

	func testClientReceivesServerSnapshotRoundTrip() async throws {
		let suiteName = UUID().uuidString
		let defaults = UserDefaults(suiteName: suiteName)
		try XCTUnwrap(defaults)
		defer {
			defaults?.removePersistentDomain(forName: suiteName)
		}
		defaults?.set(true, forKey: "flacWaveformEnabled")
		defaults?.set("SF Mono", forKey: "previewFontFamily")
		defaults?.set(21.5, forKey: "previewFontSize")
		defaults?.set(true, forKey: "previewLineWrapping")

		let store = AppSettingsStore(
			defaults: try XCTUnwrap(defaults)
		)
		let server = PreviewSettingsServer(settingsStore: store, notificationCenter: center)
		server.start()
		let client = PreviewSettingsClient(notificationCenter: center)

		let appearance = await client.appearancePreferences()
		let waveform = await client.flacWaveformEnabled()

		XCTAssertEqual(appearance.fontFamily, "SF Mono")
		XCTAssertEqual(appearance.fontSize, 21.5)
		XCTAssertTrue(appearance.wrapsLines)
		XCTAssertTrue(waveform)
	}
}

@MainActor
private final class StubPreviewSettingsBridgeCenter: OpenWithBridgeNotifying {
	private final class ObserverToken: NSObject {}

	private struct Observer {
		let name: Notification.Name
		let handler: @MainActor @Sendable (String) -> Void
	}

	private var observers = [ObjectIdentifier: Observer]()

	func addObserver(
		forName name: Notification.Name,
		handler: @escaping @MainActor @Sendable (String) -> Void
	) -> NSObjectProtocol {
		let token = ObserverToken()
		observers[ObjectIdentifier(token)] = Observer(name: name, handler: handler)
		return token
	}

	func removeObserver(_ observer: NSObjectProtocol) {
		observers.removeValue(forKey: ObjectIdentifier(observer as AnyObject))
	}

	func post(name: Notification.Name, object: String) {
		for observer in observers.values where observer.name == name {
			observer.handler(object)
		}
	}
}
