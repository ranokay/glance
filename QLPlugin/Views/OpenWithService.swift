import Cocoa

struct OpenWithApplication {
	let applicationURL: URL
	let displayName: String
	let icon: NSImage
	let isDefault: Bool
}

@MainActor
protocol WorkspaceApplicationProviding {
	func compatibleApplicationURLs(for fileURL: URL) -> [URL]
	func defaultApplicationURL(for fileURL: URL) -> URL?
	func bundleIdentifier(for applicationURL: URL) -> String?
	func displayName(for applicationURL: URL) -> String
	func icon(for applicationURL: URL) -> NSImage
	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	)
}

@MainActor
final class WorkspaceApplicationProvider: WorkspaceApplicationProviding {
	private let workspace: NSWorkspace
	private let bridge: OpenWithBridgeSending

	init(
		workspace: NSWorkspace = .shared,
		bridge: OpenWithBridgeSending = OpenWithBridgeClient()
	) {
		self.workspace = workspace
		self.bridge = bridge
	}

	func compatibleApplicationURLs(for fileURL: URL) -> [URL] {
		workspace.urlsForApplications(toOpen: fileURL)
	}

	func defaultApplicationURL(for fileURL: URL) -> URL? {
		workspace.urlForApplication(toOpen: fileURL)
	}

	func bundleIdentifier(for applicationURL: URL) -> String? {
		Bundle(url: applicationURL)?.bundleIdentifier
	}

	func displayName(for applicationURL: URL) -> String {
		let resourceValues = try? applicationURL.resourceValues(forKeys: [.localizedNameKey])
		return resourceValues?.localizedName
			?? applicationURL.deletingPathExtension().lastPathComponent
	}

	func icon(for applicationURL: URL) -> NSImage {
		workspace.icon(forFile: applicationURL.path)
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		bridge.open(fileURL: fileURL, with: applicationURL, completion: completion)
	}
}

@MainActor
final class OpenWithService {
	private struct CachedApplicationMetadata {
		let applicationURL: URL
		let bundleIdentifier: String?
		let displayName: String
		let icon: NSImage
	}

	private let workspace: WorkspaceApplicationProviding
	private var applicationMetadataCache = [String: CachedApplicationMetadata]()

	init(workspace: WorkspaceApplicationProviding = WorkspaceApplicationProvider()) {
		self.workspace = workspace
	}

	func applications(for fileURL: URL) -> [OpenWithApplication] {
		let defaultApplicationKey = workspace.defaultApplicationURL(for: fileURL).map {
			OpenWithApplicationIdentity.key(for: $0)
		}
		var seenApplicationKeys = Set<String>()
		return workspace.compatibleApplicationURLs(for: fileURL).compactMap { applicationURL in
			let applicationKey = OpenWithApplicationIdentity.key(for: applicationURL)
			guard seenApplicationKeys.insert(applicationKey).inserted else {
				return nil
			}
			let metadata = cachedMetadata(for: applicationURL, key: applicationKey)
			guard !OpenWithApplicationIdentity.excludedBundleIdentifiers.contains(
				metadata.bundleIdentifier ?? ""
			) else {
				return nil
			}
			return OpenWithApplication(
				applicationURL: metadata.applicationURL,
				displayName: metadata.displayName,
				icon: metadata.icon,
				isDefault: applicationKey == defaultApplicationKey
			)
		}
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		workspace.open(fileURL: fileURL, with: applicationURL, completion: completion)
	}

	private func cachedMetadata(
		for applicationURL: URL,
		key: String
	) -> CachedApplicationMetadata {
		if let cachedMetadata = applicationMetadataCache[key] {
			return cachedMetadata
		}
		let metadata = CachedApplicationMetadata(
			applicationURL: applicationURL,
			bundleIdentifier: workspace.bundleIdentifier(for: applicationURL),
			displayName: workspace.displayName(for: applicationURL),
			icon: workspace.icon(for: applicationURL)
		)
		applicationMetadataCache[key] = metadata
		return metadata
	}
}
