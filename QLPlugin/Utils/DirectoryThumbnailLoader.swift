import Cocoa
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct DirectoryThumbnailToken: Hashable {
	let id = UUID()
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
	let value: Value
}

@MainActor
protocol DirectoryThumbnailGenerating: AnyObject {
	@discardableResult
	func generateThumbnail(
		for fileURL: URL,
		size: CGSize,
		scale: CGFloat,
		completion: @escaping @MainActor @Sendable (NSImage?) -> Void
	) -> DirectoryThumbnailToken

	func cancel(_ token: DirectoryThumbnailToken)
}

@MainActor
final class QuickLookDirectoryThumbnailGenerator: DirectoryThumbnailGenerating {
	private let generator: QLThumbnailGenerator
	private var requests = [DirectoryThumbnailToken: QLThumbnailGenerator.Request]()

	init(generator: QLThumbnailGenerator = .shared) {
		self.generator = generator
	}

	func generateThumbnail(
		for fileURL: URL,
		size: CGSize,
		scale: CGFloat,
		completion: @escaping @MainActor @Sendable (NSImage?) -> Void
	) -> DirectoryThumbnailToken {
		let request = QLThumbnailGenerator.Request(
			fileAt: fileURL,
			size: size,
			scale: scale,
			representationTypes: .thumbnail
		)
		let token = DirectoryThumbnailToken()
		requests[token] = request
		generator.generateBestRepresentation(for: request) { [weak self] representation, _ in
			let image = UncheckedSendable(value: representation?.nsImage)
			Task { @MainActor [weak self] in
				guard let self, requests.removeValue(forKey: token) != nil else {
					return
				}
				completion(image.value)
			}
		}
		return token
	}

	func cancel(_ token: DirectoryThumbnailToken) {
		guard let request = requests.removeValue(forKey: token) else {
			return
		}
		generator.cancel(request)
	}
}

@MainActor
final class DirectoryThumbnailLoader {
	static let thumbnailSize = CGSize(width: 32, height: 32)

	private struct PendingRequest {
		let node: FileTreeNode
		let fileURL: URL
		let scale: CGFloat
		let completion: (FileTreeNode) -> Void
	}

	private struct ActiveRequest {
		let token: DirectoryThumbnailToken
		let node: FileTreeNode
		let completion: (FileTreeNode) -> Void
	}

	private let generator: DirectoryThumbnailGenerating
	private let maxConcurrentRequests: Int
	private var pendingRequests = [PendingRequest]()
	private var activeRequests = [URL: ActiveRequest]()
	private var cachedImages = [URL: NSImage]()
	private var failedURLs = Set<URL>()

	init(
		generator: DirectoryThumbnailGenerating = QuickLookDirectoryThumbnailGenerator(),
		maxConcurrentRequests: Int = 4
	) {
		self.generator = generator
		self.maxConcurrentRequests = max(1, maxConcurrentRequests)
	}

	func requestThumbnail(
		for node: FileTreeNode,
		scale: CGFloat,
		completion: @escaping (FileTreeNode) -> Void
	) {
		guard Self.isEligible(node), let fileURL = node.fileURL else {
			return
		}
		if let cachedImage = cachedImages[fileURL] {
			node.icon = cachedImage
			completion(node)
			return
		}
		guard !failedURLs.contains(fileURL),
		      activeRequests[fileURL] == nil,
		      !pendingRequests.contains(where: { $0.fileURL == fileURL })
		else {
			return
		}

		pendingRequests.append(
			PendingRequest(
				node: node,
				fileURL: fileURL,
				scale: scale,
				completion: completion
			)
		)
		startPendingRequests()
	}

	func cancelAll() {
		for request in activeRequests.values {
			generator.cancel(request.token)
		}
		activeRequests.removeAll()
		pendingRequests.removeAll()
	}

	static func isEligible(_ node: FileTreeNode) -> Bool {
		guard let fileURL = node.fileURL,
		      !node.isDirectory,
		      !node.isPackage,
		      !node.isSymbolicLink,
		      let contentTypeIdentifier = node.contentTypeIdentifier,
		      let contentType = UTType(contentTypeIdentifier)
		else {
			return false
		}

		let isThumbnailType = contentType.conforms(to: .image)
			|| contentType.conforms(to: .movie)
			|| contentType.conforms(to: .pdf)
		guard isThumbnailType else {
			return false
		}

		guard let registryEntry = SupportedPreviewRegistry.entry(matching: fileURL)
		else {
			return true
		}
		return registryEntry.id == "code.other-source-text"
	}

	private func startPendingRequests() {
		while activeRequests.count < maxConcurrentRequests, !pendingRequests.isEmpty {
			let pendingRequest = pendingRequests.removeFirst()
			let fileURL = pendingRequest.fileURL
			let token = generator.generateThumbnail(
				for: fileURL,
				size: Self.thumbnailSize,
				scale: pendingRequest.scale
			) { [weak self] image in
				self?.finishRequest(for: fileURL, image: image)
			}
			activeRequests[fileURL] = ActiveRequest(
				token: token,
				node: pendingRequest.node,
				completion: pendingRequest.completion
			)
		}
	}

	private func finishRequest(for fileURL: URL, image: NSImage?) {
		guard let activeRequest = activeRequests.removeValue(forKey: fileURL) else {
			return
		}
		if let image {
			cachedImages[fileURL] = image
			activeRequest.node.icon = image
			activeRequest.completion(activeRequest.node)
		} else {
			failedURLs.insert(fileURL)
		}
		startPendingRequests()
	}
}
