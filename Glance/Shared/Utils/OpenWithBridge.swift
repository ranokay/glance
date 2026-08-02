import AppKit
import Foundation

enum OpenWithBridgeError: Error, LocalizedError {
	case bridgeUnavailable
	case incompatibleApplication
	case invalidRequest
	case requestTimedOut
	case securityScopeUnavailable

	var errorDescription: String? {
		switch self {
			case .bridgeUnavailable:
				"The Glance Open With bridge is unavailable."
			case .incompatibleApplication:
				"The selected application is not compatible with this file."
			case .invalidRequest:
				"The Glance Open With bridge received an invalid request."
			case .requestTimedOut:
				"The Glance Open With request timed out."
			case .securityScopeUnavailable:
				"Glance could not access the selected file."
		}
	}
}

struct OpenWithBridgeRemoteError: Error, LocalizedError {
	let domain: String
	let code: Int
	let message: String

	var errorDescription: String? {
		message
	}
}

@MainActor
protocol OpenWithBridgeSending {
	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	)
}

@MainActor
protocol OpenWithLaunching {
	func isApplication(_ applicationURL: URL, compatibleWith fileURL: URL) -> Bool
	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	)
}

@MainActor
protocol OpenWithSecurityScopeManaging {
	func resolveBookmark(_ bookmarkData: Data) throws -> URL
	func startAccessing(_ url: URL) -> Bool
	func stopAccessing(_ url: URL)
}

@MainActor
protocol OpenWithBridgeDispatching {
	func dispatch(
		requestURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	)
}

@MainActor
protocol OpenWithBridgeRequestStoring {
	func store(_ requestString: String) throws -> String
	func take(named name: String) throws -> String
	func remove(named name: String)
}

@MainActor
protocol OpenWithBridgeNotifying: AnyObject {
	func addObserver(
		forName name: Notification.Name,
		handler: @escaping @MainActor @Sendable (String) -> Void
	) -> NSObjectProtocol
	func removeObserver(_ observer: NSObjectProtocol)
	func post(name: Notification.Name, object: String)
}

@MainActor
final class SystemOpenWithBridgeNotificationCenter: OpenWithBridgeNotifying {
	private let center: DistributedNotificationCenter

	init(center: DistributedNotificationCenter = .default()) {
		self.center = center
	}

	func addObserver(
		forName name: Notification.Name,
		handler: @escaping @MainActor @Sendable (String) -> Void
	) -> NSObjectProtocol {
		center.addObserver(forName: name, object: nil, queue: .main) { notification in
			guard let object = notification.object as? String else {
				return
			}
			Task { @MainActor in
				handler(object)
			}
		}
	}

	func removeObserver(_ observer: NSObjectProtocol) {
		center.removeObserver(observer)
	}

	func post(name: Notification.Name, object: String) {
		center.postNotificationName(
			name,
			object: object,
			userInfo: nil,
			deliverImmediately: true
		)
	}
}

enum OpenWithBridgeConstants {
	static let requestScheme = "glance-open-with"
	static let requestHost = "request"
	static let handoffHost = "handoff"
	static let requestNotification = Notification.Name(
		"com.chamburr.Glance.OpenWithBridge.request"
	)
	static let responseNotification = Notification.Name(
		"com.chamburr.Glance.OpenWithBridge.response"
	)
	static let currentVersion = 1
	static let maximumPayloadSize = 128 * 1024
}

struct OpenWithBridgeRequest: Codable {
	let version: Int
	let requestID: UUID
	let fileBookmark: Data
	let applicationPath: String
}

struct OpenWithBridgeHandoff: Codable {
	let version: Int
	let requestID: UUID
	let requestStoreName: String
}

struct OpenWithBridgeResponse: Codable {
	let version: Int
	let requestID: UUID
	let errorDomain: String?
	let errorCode: Int?
	let errorMessage: String?

	static func success(requestID: UUID) -> Self {
		Self(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: requestID,
			errorDomain: nil,
			errorCode: nil,
			errorMessage: nil
		)
	}

	static func failure(requestID: UUID, error: Error) -> Self {
		let nsError = error as NSError
		return Self(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: requestID,
			errorDomain: nsError.domain,
			errorCode: nsError.code,
			errorMessage: sanitizedMessage(for: error)
		)
	}

	func validatedError() throws -> Error? {
		switch (errorDomain, errorCode, errorMessage) {
			case (nil, nil, nil):
				return nil
			case let (errorDomain?, errorCode?, errorMessage?) where !errorMessage.isEmpty:
				return OpenWithBridgeRemoteError(
					domain: errorDomain,
					code: errorCode,
					message: errorMessage
				)
			default:
				throw OpenWithBridgeError.invalidRequest
		}
	}

	private static func sanitizedMessage(for error: Error) -> String {
		if let bridgeError = error as? OpenWithBridgeError {
			return bridgeError.localizedDescription
		}
		return "The selected application could not open this file."
	}
}

enum OpenWithBridgeCodec {
	private static let payloadQueryName = "payload"

	static func requestURL(for request: OpenWithBridgeRequest) throws -> URL {
		var components = URLComponents()
		components.scheme = OpenWithBridgeConstants.requestScheme
		components.host = OpenWithBridgeConstants.requestHost
		components.queryItems = [
			URLQueryItem(
				name: payloadQueryName,
				value: try encodedString(for: request)
			),
		]
		guard let url = components.url,
		      url.absoluteString.utf8.count <= OpenWithBridgeConstants.maximumPayloadSize
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		return url
	}

	static func request(from url: URL) throws -> OpenWithBridgeRequest {
		guard url.scheme == OpenWithBridgeConstants.requestScheme,
		      url.host == OpenWithBridgeConstants.requestHost,
		      url.user == nil,
		      url.password == nil,
		      url.port == nil,
		      url.fragment == nil,
		      url.absoluteString.utf8.count <= OpenWithBridgeConstants.maximumPayloadSize,
		      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      let queryItems = components.queryItems,
		      queryItems.count == 1,
		      queryItems[0].name == payloadQueryName,
		      let payload = queryItems[0].value
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		return try decodedValue(OpenWithBridgeRequest.self, from: payload)
	}

	static func handoffURL(for handoff: OpenWithBridgeHandoff) throws -> URL {
		var components = URLComponents()
		components.scheme = OpenWithBridgeConstants.requestScheme
		components.host = OpenWithBridgeConstants.handoffHost
		components.queryItems = [
			URLQueryItem(
				name: payloadQueryName,
				value: try encodedString(for: handoff)
			),
		]
		guard let url = components.url,
		      url.absoluteString.utf8.count <= 2048
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		return url
	}

	static func handoff(from url: URL) throws -> OpenWithBridgeHandoff {
		guard url.scheme == OpenWithBridgeConstants.requestScheme,
		      url.host == OpenWithBridgeConstants.handoffHost,
		      url.user == nil,
		      url.password == nil,
		      url.port == nil,
		      url.fragment == nil,
		      url.absoluteString.utf8.count <= 2048,
		      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      let queryItems = components.queryItems,
		      queryItems.count == 1,
		      queryItems[0].name == payloadQueryName,
		      let payload = queryItems[0].value
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		return try decodedValue(OpenWithBridgeHandoff.self, from: payload)
	}

	static func responseString(for response: OpenWithBridgeResponse) throws -> String {
		try encodedString(for: response)
	}

	static func response(from string: String) throws -> OpenWithBridgeResponse {
		try decodedValue(OpenWithBridgeResponse.self, from: string)
	}

	private static func encodedString(for value: some Encodable) throws -> String {
		let data = try JSONEncoder().encode(value)
		guard data.count <= OpenWithBridgeConstants.maximumPayloadSize else {
			throw OpenWithBridgeError.invalidRequest
		}
		return data.base64EncodedString()
	}

	private static func decodedValue<T: Decodable>(_: T.Type, from string: String) throws -> T {
		guard string.utf8.count <= OpenWithBridgeConstants.maximumPayloadSize,
		      let data = Data(base64Encoded: string),
		      data.count <= OpenWithBridgeConstants.maximumPayloadSize
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		do {
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			throw OpenWithBridgeError.invalidRequest
		}
	}
}

@MainActor
final class SystemOpenWithSecurityScopeManager: OpenWithSecurityScopeManaging {
	func resolveBookmark(_ bookmarkData: Data) throws -> URL {
		var bookmarkDataIsStale = false
		let fileURL = try URL(
			resolvingBookmarkData: bookmarkData,
			options: [.withoutUI],
			relativeTo: nil,
			bookmarkDataIsStale: &bookmarkDataIsStale
		)
		guard fileURL.isFileURL, !bookmarkDataIsStale else {
			throw OpenWithBridgeError.invalidRequest
		}
		return fileURL.resolvingSymlinksInPath().standardizedFileURL
	}

	func startAccessing(_ url: URL) -> Bool {
		url.startAccessingSecurityScopedResource()
	}

	func stopAccessing(_ url: URL) {
		url.stopAccessingSecurityScopedResource()
	}
}

@MainActor
final class SystemOpenWithBridgeRequestStore: OpenWithBridgeRequestStoring {
	private static let namePrefix = "com.chamburr.Glance.OpenWithBridge."
	private static let pasteboardType = NSPasteboard.PasteboardType(
		"com.chamburr.Glance.open-with-request"
	)

	func store(_ requestString: String) throws -> String {
		guard requestString.utf8.count <= OpenWithBridgeConstants.maximumPayloadSize else {
			throw OpenWithBridgeError.invalidRequest
		}
		let name = Self.namePrefix + UUID().uuidString
		let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
		pasteboard.clearContents()
		guard pasteboard.setString(requestString, forType: Self.pasteboardType) else {
			throw OpenWithBridgeError.bridgeUnavailable
		}
		return name
	}

	func take(named name: String) throws -> String {
		guard Self.isValidName(name) else {
			throw OpenWithBridgeError.invalidRequest
		}
		let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
		defer {
			pasteboard.clearContents()
		}
		guard let requestString = pasteboard.string(forType: Self.pasteboardType),
		      requestString.utf8.count <= OpenWithBridgeConstants.maximumPayloadSize
		else {
			throw OpenWithBridgeError.invalidRequest
		}
		return requestString
	}

	func remove(named name: String) {
		guard Self.isValidName(name) else {
			return
		}
		NSPasteboard(name: NSPasteboard.Name(name)).clearContents()
	}

	private static func isValidName(_ name: String) -> Bool {
		guard name.hasPrefix(namePrefix),
		      name.utf8.count == namePrefix.utf8.count + 36
		else {
			return false
		}
		return UUID(uuidString: String(name.dropFirst(namePrefix.count))) != nil
	}
}

private struct UncheckedOpenWithBridgeValue<Value>: @unchecked Sendable {
	let value: Value
}

@MainActor
final class WorkspaceOpenWithLauncher: OpenWithLaunching {
	private static let excludedBundleIdentifiers: Set<String> = [
		"com.chamburr.Glance",
		"com.chamburr.Glance.QLPlugin",
	]

	private let workspace: NSWorkspace

	init(workspace: NSWorkspace = .shared) {
		self.workspace = workspace
	}

	func isApplication(_ applicationURL: URL, compatibleWith fileURL: URL) -> Bool {
		guard applicationURL.isFileURL,
		      applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
		      let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
		      !Self.excludedBundleIdentifiers.contains(bundleIdentifier)
		else {
			return false
		}
		let requestedApplicationKey = Self.applicationKey(applicationURL)
		return workspace.urlsForApplications(toOpen: fileURL).contains {
			Self.applicationKey($0) == requestedApplicationKey
		}
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		workspace.open(
			[fileURL],
			withApplicationAt: applicationURL,
			configuration: Self.makeOpenConfiguration()
		) { _, error in
			let sendableError = UncheckedOpenWithBridgeValue(value: error)
			Task { @MainActor in
				completion(sendableError.value)
			}
		}
	}

	static func makeOpenConfiguration() -> NSWorkspace.OpenConfiguration {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.promptsUserIfNeeded = false
		configuration.addsToRecentItems = false
		return configuration
	}

	private static func applicationKey(_ applicationURL: URL) -> String {
		applicationURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
	}
}

@MainActor
final class WorkspaceOpenWithRequestDispatcher: OpenWithBridgeDispatching {
	private let workspace: NSWorkspace
	private let notificationCenter: OpenWithBridgeNotifying
	private let containingApplicationURL: URL

	init(
		workspace: NSWorkspace = .shared,
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter(),
		containingApplicationURL: URL = WorkspaceOpenWithRequestDispatcher
			.defaultContainingApplicationURL
	) {
		self.workspace = workspace
		self.notificationCenter = notificationCenter
		self.containingApplicationURL = containingApplicationURL
	}

	func dispatch(
		requestURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		do {
			let handoff = try OpenWithBridgeCodec.handoff(from: requestURL)
			guard handoff.version == OpenWithBridgeConstants.currentVersion else {
				throw OpenWithBridgeError.invalidRequest
			}
		} catch {
			completion(error)
			return
		}

		if isContainingApplicationRunning {
			post(requestURL)
			completion(nil)
			return
		}

		workspace.openApplication(
			at: containingApplicationURL,
			configuration: Self.makeOpenConfiguration()
		) { [weak self] _, error in
			let sendableError = UncheckedOpenWithBridgeValue(value: error)
			Task { @MainActor in
				guard let self else {
					completion(OpenWithBridgeError.bridgeUnavailable)
					return
				}
				guard sendableError.value == nil else {
					completion(sendableError.value)
					return
				}
				self.post(requestURL)
				completion(nil)
			}
		}
	}

	private var isContainingApplicationRunning: Bool {
		guard let bundleIdentifier = Bundle(url: containingApplicationURL)?.bundleIdentifier else {
			return false
		}
		return !NSRunningApplication.runningApplications(
			withBundleIdentifier: bundleIdentifier
		).isEmpty
	}

	private func post(_ requestURL: URL) {
		notificationCenter.post(
			name: OpenWithBridgeConstants.requestNotification,
			object: requestURL.absoluteString
		)
	}

	static func makeOpenConfiguration() -> NSWorkspace.OpenConfiguration {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = false
		configuration.promptsUserIfNeeded = false
		configuration.addsToRecentItems = false
		configuration.createsNewApplicationInstance = false
		return configuration
	}

	private static var defaultContainingApplicationURL: URL {
		var candidate = Bundle.main.bundleURL.standardizedFileURL
		while candidate.pathComponents.count > 1 {
			guard candidate.pathExtension.caseInsensitiveCompare("app") != .orderedSame else {
				break
			}
			candidate.deleteLastPathComponent()
		}
		return candidate
	}
}

@MainActor
final class OpenWithBridgeServer {
	private let notificationCenter: OpenWithBridgeNotifying
	private let launcher: OpenWithLaunching
	private let securityScopeManager: OpenWithSecurityScopeManaging
	private let requestStore: OpenWithBridgeRequestStoring
	private var requestObserver: NSObjectProtocol?

	init(
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter(),
		launcher: OpenWithLaunching = WorkspaceOpenWithLauncher(),
		securityScopeManager: OpenWithSecurityScopeManaging = SystemOpenWithSecurityScopeManager(),
		requestStore: OpenWithBridgeRequestStoring = SystemOpenWithBridgeRequestStore()
	) {
		self.notificationCenter = notificationCenter
		self.launcher = launcher
		self.securityScopeManager = securityScopeManager
		self.requestStore = requestStore
	}

	isolated deinit {
		if let requestObserver {
			notificationCenter.removeObserver(requestObserver)
		}
	}

	func start() {
		guard requestObserver == nil else {
			return
		}
		requestObserver = notificationCenter.addObserver(
			forName: OpenWithBridgeConstants.requestNotification
		) { [weak self] requestString in
			guard let requestURL = URL(string: requestString),
			      requestURL.scheme == OpenWithBridgeConstants.requestScheme,
			      requestURL.host == OpenWithBridgeConstants.handoffHost
			else {
				return
			}
			self?.handle(requestURL)
		}
	}

	func canHandle(_ url: URL) -> Bool {
		url.scheme == OpenWithBridgeConstants.requestScheme
			&& (url.host == OpenWithBridgeConstants.requestHost
				|| url.host == OpenWithBridgeConstants.handoffHost)
	}

	func handle(_ requestURL: URL) {
		var responseRequestID: UUID?
		do {
			let request: OpenWithBridgeRequest
			if requestURL.host == OpenWithBridgeConstants.handoffHost {
				let handoff = try OpenWithBridgeCodec.handoff(from: requestURL)
				responseRequestID = handoff.requestID
				guard handoff.version == OpenWithBridgeConstants.currentVersion else {
					throw OpenWithBridgeError.invalidRequest
				}
				let storedRequest = try requestStore.take(named: handoff.requestStoreName)
				guard let storedRequestURL = URL(string: storedRequest) else {
					throw OpenWithBridgeError.invalidRequest
				}
				request = try OpenWithBridgeCodec.request(from: storedRequestURL)
				guard request.requestID == handoff.requestID else {
					throw OpenWithBridgeError.invalidRequest
				}
			} else {
				request = try OpenWithBridgeCodec.request(from: requestURL)
				responseRequestID = request.requestID
			}
			guard request.version == OpenWithBridgeConstants.currentVersion else {
				throw OpenWithBridgeError.invalidRequest
			}
			guard request.applicationPath.utf8.count <= 4096,
			      NSString(string: request.applicationPath).isAbsolutePath
			else {
				throw OpenWithBridgeError.invalidRequest
			}

			let fileURL = try securityScopeManager.resolveBookmark(request.fileBookmark)
			guard securityScopeManager.startAccessing(fileURL) else {
				throw OpenWithBridgeError.securityScopeUnavailable
			}

			let applicationURL = URL(fileURLWithPath: request.applicationPath)
				.resolvingSymlinksInPath()
				.standardizedFileURL
			guard launcher.isApplication(applicationURL, compatibleWith: fileURL) else {
				securityScopeManager.stopAccessing(fileURL)
				throw OpenWithBridgeError.incompatibleApplication
			}

			let securityScopeManager = securityScopeManager
			launcher.open(fileURL: fileURL, with: applicationURL) { [weak self] error in
				securityScopeManager.stopAccessing(fileURL)
				self?.sendResponse(requestID: request.requestID, error: error)
			}
		} catch {
			guard let responseRequestID else {
				Log.general.error(
					"Could not decode Open With bridge request: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)"
				)
				return
			}
			sendResponse(requestID: responseRequestID, error: error)
		}
	}

	private func sendResponse(requestID: UUID, error: Error?) {
		let response = error.map {
			OpenWithBridgeResponse.failure(requestID: requestID, error: $0)
		} ?? OpenWithBridgeResponse.success(requestID: requestID)
		do {
			notificationCenter.post(
				name: OpenWithBridgeConstants.responseNotification,
				object: try OpenWithBridgeCodec.responseString(for: response)
			)
		} catch {
			let nsError = error as NSError
			Log.general.error(
				"Could not send Open With bridge response: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
			)
		}
	}
}

@MainActor
final class OpenWithBridgeClient: OpenWithBridgeSending {
	private struct PendingRequest {
		let observer: NSObjectProtocol
		let timeoutTask: Task<Void, Never>
		let requestStoreName: String
		let completion: @MainActor (Error?) -> Void
	}

	private let notificationCenter: OpenWithBridgeNotifying
	private let dispatcher: OpenWithBridgeDispatching
	private let requestStore: OpenWithBridgeRequestStoring
	private let timeout: Duration
	private var pendingRequests = [UUID: PendingRequest]()

	init(
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter(),
		dispatcher: OpenWithBridgeDispatching = WorkspaceOpenWithRequestDispatcher(),
		requestStore: OpenWithBridgeRequestStoring = SystemOpenWithBridgeRequestStore(),
		timeout: Duration = .seconds(5)
	) {
		self.notificationCenter = notificationCenter
		self.dispatcher = dispatcher
		self.requestStore = requestStore
		self.timeout = timeout
	}

	isolated deinit {
		cancelAllPendingRequests(error: OpenWithBridgeError.bridgeUnavailable)
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		let requestID = UUID()
		let requestURL: URL
		let requestStoreName: String
		let handoffURL: URL
		var storedRequestName: String?
		do {
			let request = OpenWithBridgeRequest(
				version: OpenWithBridgeConstants.currentVersion,
				requestID: requestID,
				fileBookmark: try fileURL.bookmarkData(
					options: .minimalBookmark,
					includingResourceValuesForKeys: nil,
					relativeTo: nil
				),
				applicationPath: applicationURL.resolvingSymlinksInPath()
					.standardizedFileURL.path
			)
			requestURL = try OpenWithBridgeCodec.requestURL(for: request)
			requestStoreName = try requestStore.store(requestURL.absoluteString)
			storedRequestName = requestStoreName
			handoffURL = try OpenWithBridgeCodec.handoffURL(for: OpenWithBridgeHandoff(
				version: OpenWithBridgeConstants.currentVersion,
				requestID: requestID,
				requestStoreName: requestStoreName
			))
		} catch {
			if let storedRequestName {
				requestStore.remove(named: storedRequestName)
			}
			completion(error)
			return
		}

		let observer = notificationCenter.addObserver(
			forName: OpenWithBridgeConstants.responseNotification
		) { [weak self] responseString in
			guard let response = try? OpenWithBridgeCodec.response(from: responseString),
			      response.version == OpenWithBridgeConstants.currentVersion,
			      response.requestID == requestID
			else {
				return
			}
			let responseError: Error?
			do {
				responseError = try response.validatedError()
			} catch {
				return
			}
			self?.finish(requestID: requestID, error: responseError)
		}
		let requestTimeout = timeout
		let timeoutTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: requestTimeout)
			guard !Task.isCancelled else {
				return
			}
			self?.finish(requestID: requestID, error: OpenWithBridgeError.requestTimedOut)
		}
		pendingRequests[requestID] = PendingRequest(
			observer: observer,
			timeoutTask: timeoutTask,
			requestStoreName: requestStoreName,
			completion: completion
		)

		dispatcher.dispatch(requestURL: handoffURL) { [weak self] error in
			guard let error else {
				return
			}
			self?.finish(requestID: requestID, error: error)
		}
	}

	private func finish(requestID: UUID, error: Error?) {
		guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else {
			return
		}
		notificationCenter.removeObserver(pendingRequest.observer)
		pendingRequest.timeoutTask.cancel()
		requestStore.remove(named: pendingRequest.requestStoreName)
		pendingRequest.completion(error)
	}

	private func cancelAllPendingRequests(error: Error) {
		let requestIDs = Array(pendingRequests.keys)
		for requestID in requestIDs {
			finish(requestID: requestID, error: error)
		}
	}
}
