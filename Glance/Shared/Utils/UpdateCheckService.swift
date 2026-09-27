import Foundation

public final class UpdateCheckService: @unchecked Sendable {
	private let settings: AppSettingsStore
	private let currentVersion: String
	private let fetch: @Sendable (URL) async throws -> GitHubRelease
	private let now: @Sendable () -> Date
	private let notified: @Sendable (String, URL) async -> Void

	public init(
		settings: AppSettingsStore,
		currentVersion: String,
		fetch: @Sendable @escaping (URL) async throws -> GitHubRelease,
		now: @Sendable @escaping () -> Date = Date.init,
		notified: @Sendable @escaping (String, URL) async -> Void
	) {
		self.settings = settings
		self.currentVersion = currentVersion
		self.fetch = fetch
		self.now = now
		self.notified = notified
	}

	public func checkIfDue() async -> UpdateState? {
		guard settings.autoUpdateCheckEnabled else {
			return nil
		}
		if
			let last = settings.lastUpdateCheckDate,
			now().timeIntervalSince(last) < UpdateChecker.checkInterval
		{
			return nil
		}
		return await checkNow()
	}

	public func checkNow() async -> UpdateState {
		do {
			let release = try await fetch(UpdateChecker.latestReleaseURL)
			settings.lastUpdateCheckDate = now()
			let result = UpdateChecker.state(latest: release, currentVersion: currentVersion)
			if case let .available(version, url) = result, settings.lastNotifiedUpdateVersion != version {
				settings.lastNotifiedUpdateVersion = version
				await notified(version, url)
			}
			return result
		} catch {
			return .unknown(message: "Couldn’t check just now.")
		}
	}

	public static func liveFetcher() -> @Sendable (URL) async throws -> GitHubRelease {
		{ url in
			var request = URLRequest(url: url, timeoutInterval: 20)
			request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
			let (data, _) = try await URLSession.shared.data(for: request)
			return try JSONDecoder().decode(GitHubRelease.self, from: data)
		}
	}
}
