import Cocoa
import QuickLookUI
import UniformTypeIdentifiers

enum NestedPreviewError: LocalizedError {
	case missingFileURL(name: String)
	case nativePreviewUnavailable(name: String)
	case nonNavigableItem(name: String)

	var errorDescription: String? {
		switch self {
			case let .missingFileURL(name):
				"No source URL is available for \(name)"
			case let .nativePreviewUnavailable(name):
				"The native preview for \(name) is unavailable"
			case let .nonNavigableItem(name):
				"\(name) cannot be previewed from this folder"
		}
	}
}

enum NestedPreviewRoute {
	case glance(Preview.Type)
	case native
}

@MainActor
protocol NestedPreviewProviding {
	func makePreviewController(for node: FileTreeNode) throws -> PreviewVC
}

@MainActor
struct DefaultNestedPreviewProvider: NestedPreviewProviding {
	func makePreviewController(for node: FileTreeNode) throws -> PreviewVC {
		guard let fileURL = node.fileURL else {
			throw NestedPreviewError.missingFileURL(name: node.name)
		}
		guard !node.isSymbolicLink, !node.isDirectory || node.isPackage else {
			throw NestedPreviewError.nonNavigableItem(name: node.name)
		}

		switch route(for: node) {
			case let .glance(previewType):
				return try previewType.init().createPreviewVC(file: File(url: fileURL))
			case .native:
				let previewVC = NativePreviewVC(fileURL: fileURL)
				previewVC.loadViewIfNeeded()
				guard previewVC.previewView != nil else {
					throw NestedPreviewError.nativePreviewUnavailable(name: node.name)
				}
				return previewVC
		}
	}

	func route(for node: FileTreeNode) -> NestedPreviewRoute {
		guard !node.isPackage, let fileURL = node.fileURL else {
			return .native
		}

		let contentType = node.contentTypeIdentifier.flatMap(UTType.init)
		let isNativeMedia = contentType?.conforms(to: .image) == true
			|| contentType?.conforms(to: .movie) == true
			|| contentType?.conforms(to: .audio) == true
			|| contentType?.conforms(to: .pdf) == true
		if isNativeMedia {
			return .native
		}

		guard let registryEntry = SupportedPreviewRegistry.entry(matching: fileURL),
		      let previewType = PreviewVCFactory.getPreviewInitializer(fileURL: fileURL)
		else {
			return .native
		}
		let isExplicitGlanceType = registryEntry.id != "code.other-source-text"
		let isTextType = contentType?.conforms(to: .text) == true
		return isExplicitGlanceType || isTextType ? .glance(previewType) : .native
	}
}

final class NativePreviewVC: NSViewController, PreviewVC {
	let fileURL: URL
	private(set) var previewView: QLPreviewView?

	init(fileURL: URL) {
		self.fileURL = fileURL
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		guard let previewView = QLPreviewView(frame: view.bounds, style: .normal) else {
			return
		}
		previewView.autoresizingMask = [.height, .width]
		previewView.previewItem = fileURL as NSURL
		view.addSubview(previewView)
		self.previewView = previewView
	}
}
