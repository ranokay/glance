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

private struct UncheckedOpenWithValue<Value>: @unchecked Sendable {
	let value: Value
}

@MainActor
final class WorkspaceApplicationProvider: WorkspaceApplicationProviding {
	private let workspace: NSWorkspace

	init(workspace: NSWorkspace = .shared) {
		self.workspace = workspace
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
		workspace.open(
			[fileURL],
			withApplicationAt: applicationURL,
			configuration: NSWorkspace.OpenConfiguration()
		) { _, error in
			let sendableError = UncheckedOpenWithValue(value: error)
			Task { @MainActor in
				completion(sendableError.value)
			}
		}
	}
}

@MainActor
final class OpenWithService {
	private static let excludedBundleIdentifiers: Set<String> = [
		"com.chamburr.Glance",
		"com.chamburr.Glance.QLPlugin",
	]

	private let workspace: WorkspaceApplicationProviding

	init(workspace: WorkspaceApplicationProviding = WorkspaceApplicationProvider()) {
		self.workspace = workspace
	}

	func applications(for fileURL: URL) -> [OpenWithApplication] {
		let defaultApplicationKey = workspace.defaultApplicationURL(for: fileURL).map(Self.key)
		var seenApplicationKeys = Set<String>()
		return workspace.compatibleApplicationURLs(for: fileURL).compactMap { applicationURL in
			let applicationKey = Self.key(applicationURL)
			guard seenApplicationKeys.insert(applicationKey).inserted,
			      !Self.excludedBundleIdentifiers.contains(
			      	workspace.bundleIdentifier(for: applicationURL) ?? ""
			      )
			else {
				return nil
			}
			return OpenWithApplication(
				applicationURL: applicationURL,
				displayName: workspace.displayName(for: applicationURL),
				icon: workspace.icon(for: applicationURL),
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

	private static func key(_ applicationURL: URL) -> String {
		applicationURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
	}
}
