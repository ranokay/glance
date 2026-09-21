import Foundation

enum DrawIOPreviewError: LocalizedError {
	case compressedDiagramUnsupported
	case invalidDocument(String)
	case invalidEncoding
	case oversizedFile(maximumBytes: Int)

	var errorDescription: String? {
		switch self {
			case .compressedDiagramUnsupported:
				"Compressed Draw.io diagrams are not supported"
			case let .invalidDocument(message):
				"Could not preview Draw.io diagram: \(message)"
			case .invalidEncoding:
				"Draw.io diagram is not valid UTF-8"
			case let .oversizedFile(maximumBytes):
				"Draw.io diagram exceeds the \(maximumBytes / 1_000_000) MB preview limit"
		}
	}
}

final class DrawIOPreview: Preview {
	static let maximumFileSize = PreviewPolicy.maximumFileSize

	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "drawio-main",
		withExtension: "css"
	)
	private let viewerScriptURL = WebPreviewVC.resourceBundle.url(
		forResource: "drawio-viewer-31.4.6.min",
		withExtension: "js"
	)

	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let fileSize = file.size
		let encodedPayload = try await PreviewExecutor.run {
			guard fileSize <= Self.maximumFileSize else {
				throw DrawIOPreviewError.oversizedFile(maximumBytes: Self.maximumFileSize)
			}

			let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
			guard data.count <= Self.maximumFileSize else {
				throw DrawIOPreviewError.oversizedFile(maximumBytes: Self.maximumFileSize)
			}
			guard let source = String(data: data, encoding: .utf8) else {
				throw DrawIOPreviewError.invalidEncoding
			}

			try DrawIOXMLValidator.validate(source)
			return data.base64EncodedString()
		}

		guard let viewerScriptURL else {
			throw DrawIOPreviewError.invalidDocument("bundled viewer is unavailable")
		}

		return WebPreviewVC(
			html: "<div id=\"drawio-preview\" data-drawio-payload=\"\(encodedPayload)\"></div>",
			stylesheets: getStylesheets(),
			scripts: [bootstrapScript(), Script(url: viewerScriptURL)]
		)
	}

	private func getStylesheets() -> [Stylesheet] {
		guard let mainStylesheetURL else {
			Log.render.error("Could not find Draw.io stylesheet")
			return []
		}
		return [Stylesheet(url: mainStylesheetURL)]
	}

	/// Decode the base64 payload in trusted code, then use JSON.stringify to construct the viewer's
	/// configuration. User XML is never interpolated into executable JavaScript or live HTML.
	private func bootstrapScript() -> Script {
		Script(content: """
		(function() {
			const host = document.getElementById('drawio-preview');
			if (!host) {
				return;
			}

			try {
				const encoded = host.dataset.drawioPayload || '';
				host.removeAttribute('data-drawio-payload');
				const binary = atob(encoded);
				const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
				const xml = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
				const graph = document.createElement('div');
				graph.className = 'mxgraph';
				graph.setAttribute('data-mxgraph', JSON.stringify({
					highlight: '#0000ff',
					nav: false,
					resize: true,
					toolbar: '',
					xml: xml
				}));
				host.replaceWith(graph);

				// Keep the official viewer on local data only. The page CSP independently blocks
				// every network connection.
				window.PROXY_URL = 'about:blank';
				window.STYLE_PATH = 'about:blank';
				window.SHAPES_PATH = 'about:blank';
				window.STENCIL_PATH = 'about:blank';
				window.DRAW_MATH_URL = 'about:blank';
				window.GRAPH_IMAGE_PATH = 'about:blank';
				window.mxImageBasePath = 'about:blank';
				window.mxBasePath = 'about:blank';
				window.mxLoadStylesheets = false;
			} catch (error) {
				host.dataset.drawioState = 'failed';
				host.textContent = 'Could not decode Draw.io diagram';
				console.error('Could not prepare Draw.io diagram:', error);
			}
		})();
		""")
	}
}

private final class DrawIOXMLValidator: NSObject, XMLParserDelegate {
	private var diagramHasGraphModel = [Bool]()
	private var elementStack = [String]()
	private var rootElement: String?
	private var validationError: DrawIOPreviewError?

	static func validate(_ source: String) throws {
		if source.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
			|| source.range(of: "<!ENTITY", options: .caseInsensitive) != nil
		{
			throw DrawIOPreviewError.invalidDocument("document type declarations are not allowed")
		}

		let validator = DrawIOXMLValidator()
		let parser = XMLParser(data: Data(source.utf8))
		parser.delegate = validator
		parser.shouldResolveExternalEntities = false
		guard parser.parse() else {
			if let validationError = validator.validationError {
				throw validationError
			}
			let message = parser.parserError?.localizedDescription ?? "malformed XML"
			throw DrawIOPreviewError.invalidDocument(message)
		}

		try validator.finishValidation()
	}

	func parser(
		_ parser: XMLParser,
		didStartElement elementName: String,
		namespaceURI _: String?,
		qualifiedName _: String?,
		attributes _: [String: String] = [:]
	) {
		if elementStack.isEmpty {
			rootElement = elementName
			guard elementName == "mxfile" || elementName == "mxGraphModel" else {
				fail(
					.invalidDocument("expected mxfile or mxGraphModel root element"),
					parser: parser
				)
				return
			}
		} else if rootElement == "mxfile" {
			if elementName == "diagram", elementStack == ["mxfile"] {
				diagramHasGraphModel.append(false)
			} else if elementName == "mxGraphModel",
			          elementStack.count == 2,
			          elementStack[0] == "mxfile",
			          elementStack[1] == "diagram",
			          !diagramHasGraphModel.isEmpty
			{
				diagramHasGraphModel[diagramHasGraphModel.count - 1] = true
			}
		}

		elementStack.append(elementName)
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard
			rootElement == "mxfile",
			elementStack.count == 2,
			elementStack[0] == "mxfile",
			elementStack[1] == "diagram",
			!diagramHasGraphModel.isEmpty,
			!diagramHasGraphModel[diagramHasGraphModel.count - 1],
			!string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return
		}

		fail(.compressedDiagramUnsupported, parser: parser)
	}

	func parser(
		_: XMLParser,
		didEndElement _: String,
		namespaceURI _: String?,
		qualifiedName _: String?
	) {
		if !elementStack.isEmpty {
			elementStack.removeLast()
		}
	}

	private func finishValidation() throws {
		if let validationError {
			throw validationError
		}
		guard let rootElement else {
			throw DrawIOPreviewError.invalidDocument("document is empty")
		}
		if rootElement == "mxfile" {
			guard !diagramHasGraphModel.isEmpty else {
				throw DrawIOPreviewError.invalidDocument("mxfile contains no diagrams")
			}
			guard diagramHasGraphModel.allSatisfy(\.self) else {
				throw DrawIOPreviewError.compressedDiagramUnsupported
			}
		}
	}

	private func fail(_ error: DrawIOPreviewError, parser: XMLParser) {
		validationError = error
		parser.abortParsing()
	}
}
