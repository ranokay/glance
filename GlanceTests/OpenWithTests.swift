import Cocoa
import XCTest

@MainActor
final class OpenWithTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlanceOpenWithTests-\(UUID().uuidString)", isDirectory: true)
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

	func testApplicationListPreservesRankingMarksDefaultDeduplicatesAndExcludesGlance() {
		let textEditURL = URL(fileURLWithPath: "/Applications/TextEdit.app")
		let codeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
		let glanceURL = URL(fileURLWithPath: "/Applications/Glance.app")
		let workspace = StubWorkspaceApplicationProvider(
			compatibleApplicationURLs: [textEditURL, codeURL, textEditURL, glanceURL],
			defaultApplicationURL: codeURL,
			bundleIdentifiers: [glanceURL: "com.chamburr.Glance"],
			displayNames: [textEditURL: "TextEdit", codeURL: "Visual Studio Code"]
		)
		let service = OpenWithService(workspace: workspace)

		let applications = service.applications(
			for: URL(fileURLWithPath: "/tmp/document.txt")
		)

		XCTAssertEqual(applications.map(\.applicationURL), [textEditURL, codeURL])
		XCTAssertEqual(applications.map(\.displayName), ["TextEdit", "Visual Studio Code"])
		XCTAssertEqual(applications.map(\.isDefault), [false, true])
	}

	func testTopLevelFileMenuUsesRankedAppsMarksDefaultAndHasNoOtherPicker() throws {
		let fileURL = try writeFile(named: "notes.txt")
		let firstAppURL = URL(fileURLWithPath: "/Applications/First.app")
		let defaultAppURL = URL(fileURLWithPath: "/Applications/Default.app")
		let workspace = StubWorkspaceApplicationProvider(
			compatibleApplicationURLs: [firstAppURL, defaultAppURL],
			defaultApplicationURL: defaultAppURL,
			displayNames: [firstAppURL: "First", defaultAppURL: "Default"]
		)
		let mainVC = makeMainVC(workspace: workspace)

		mainVC.installTopLevelPreview(OpenWithStubPreviewVC(), file: try File(url: fileURL))

		XCTAssertEqual(mainVC.openWithTargetURL, fileURL)
		XCTAssertTrue(mainVC.openWithButton.isEnabled)
		let applicationItems = mainVC.openWithButton.menu?.items.filter {
			$0.representedObject is URL
		} ?? []
		XCTAssertEqual(applicationItems.map(\.title), ["First", "Default"])
		XCTAssertEqual(applicationItems.map(\.state), [.off, .on])
		XCTAssertFalse(mainVC.openWithButton.itemTitles.contains("Other…"))
	}

	func testFolderTargetIsDisabledForDirectoriesAndSymlinksAndEnabledForFilesAndPackages() throws {
		let folderURL = try makeDirectory(named: "folder")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let workspace = StubWorkspaceApplicationProvider(
			compatibleApplicationURLs: [applicationURL],
			displayNames: [applicationURL: "Editor"]
		)
		let mainVC = makeMainVC(workspace: workspace)
		let outlineVC = OutlinePreviewVC(rootNodes: [], labelText: "0 items")
		mainVC.installTopLevelPreview(outlineVC, file: try File(url: folderURL))
		let directoryNode = fileNode(named: "Nested", isDirectory: true)
		let symlinkNode = fileNode(named: "link.txt", isSymbolicLink: true)
		let regularFileNode = fileNode(named: "file.txt")
		let packageNode = fileNode(
			named: "Project.screenstudio",
			isDirectory: true,
			isPackage: true
		)

		mainVC.outlinePreview(outlineVC, didSelect: directoryNode)
		XCTAssertNil(mainVC.openWithTargetURL)
		XCTAssertFalse(mainVC.openWithButton.isEnabled)

		mainVC.outlinePreview(outlineVC, didSelect: symlinkNode)
		XCTAssertNil(mainVC.openWithTargetURL)
		XCTAssertFalse(mainVC.openWithButton.isEnabled)

		mainVC.outlinePreview(outlineVC, didSelect: regularFileNode)
		XCTAssertEqual(mainVC.openWithTargetURL, regularFileNode.fileURL)
		XCTAssertTrue(mainVC.openWithButton.isEnabled)

		mainVC.outlinePreview(outlineVC, didSelect: packageNode)
		XCTAssertEqual(mainVC.openWithTargetURL, packageNode.fileURL)
		XCTAssertTrue(mainVC.openWithButton.isEnabled)
	}

	func testChosenApplicationOpensExactlyOnceWithoutChangingDefaults() throws {
		let fileURL = try writeFile(named: "once.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let workspace = StubWorkspaceApplicationProvider(
			compatibleApplicationURLs: [applicationURL],
			displayNames: [applicationURL: "Editor"]
		)
		let mainVC = makeMainVC(workspace: workspace)
		mainVC.installTopLevelPreview(OpenWithStubPreviewVC(), file: try File(url: fileURL))

		let applicationItem = try XCTUnwrap(
			mainVC.openWithButton.menu?.items.first { $0.representedObject is URL }
		)
		mainVC.openWithButton.select(applicationItem)
		let action = try XCTUnwrap(mainVC.openWithButton.action)
		XCTAssertTrue(
			NSApplication.shared.sendAction(
				action,
				to: mainVC.openWithButton.target,
				from: mainVC.openWithButton
			)
		)

		XCTAssertEqual(workspace.openCalls.count, 1)
		XCTAssertEqual(workspace.openCalls.first?.fileURL, fileURL)
		XCTAssertEqual(workspace.openCalls.first?.applicationURL, applicationURL)
		XCTAssertEqual(workspace.defaultApplicationRequestCount, 1)
	}

	func testApplicationLauncherConfigurationDoesNotRequestHostUIOrRecentItemDonation() {
		let configuration = WorkspaceOpenWithLauncher.makeOpenConfiguration()

		XCTAssertFalse(configuration.promptsUserIfNeeded)
		XCTAssertFalse(configuration.addsToRecentItems)
		XCTAssertTrue(configuration.activates)
		XCTAssertFalse(configuration.createsNewApplicationInstance)
	}

	func testBridgeDispatchConfigurationDoesNotActivateGlance() {
		let configuration = WorkspaceOpenWithRequestDispatcher.makeOpenConfiguration()

		XCTAssertFalse(configuration.activates)
		XCTAssertFalse(configuration.promptsUserIfNeeded)
		XCTAssertFalse(configuration.addsToRecentItems)
		XCTAssertFalse(configuration.createsNewApplicationInstance)
	}

	func testWorkspaceProviderRoutesOpeningThroughBridge() throws {
		let fileURL = try writeFile(named: "bridged.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let bridge = StubOpenWithBridge()
		let provider = WorkspaceApplicationProvider(bridge: bridge)
		var receivedError: Error?

		provider.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
		}

		XCTAssertNil(receivedError)
		XCTAssertEqual(bridge.openCalls.count, 1)
		XCTAssertEqual(bridge.openCalls.first?.fileURL, fileURL)
		XCTAssertEqual(bridge.openCalls.first?.applicationURL, applicationURL)
	}

	func testBridgeForwardsAuthorizedRequestToApplicationLauncher() throws {
		let fileURL = try writeFile(named: "authorized.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher()
		let securityScopeManager = StubOpenWithSecurityScopeManager(fileURL: fileURL)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		let dispatcher = StubOpenWithBridgeDispatcher { server.handle($0) }
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "bridge response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertNil(receivedError)
		XCTAssertEqual(launcher.compatibilityChecks.count, 1)
		XCTAssertEqual(launcher.openCalls.count, 1)
		XCTAssertEqual(
			launcher.openCalls.first?.fileURL.resolvingSymlinksInPath(),
			fileURL.resolvingSymlinksInPath()
		)
		XCTAssertEqual(launcher.openCalls.first?.applicationURL, applicationURL)
		XCTAssertEqual(securityScopeManager.resolveCount, 1)
		XCTAssertEqual(securityScopeManager.startCount, 1)
		XCTAssertEqual(securityScopeManager.stopCount, 1)
		XCTAssertEqual(requestStore.count, 0)
	}

	func testBridgeCodecRoundTripsRequestsAndRejectsMalformedURLs() throws {
		let request = OpenWithBridgeRequest(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			fileBookmark: Data([1, 2, 3]),
			applicationPath: "/Applications/Editor.app"
		)

		let requestURL = try OpenWithBridgeCodec.requestURL(for: request)
		let decodedRequest = try OpenWithBridgeCodec.request(from: requestURL)

		XCTAssertEqual(requestURL.scheme, OpenWithBridgeConstants.requestScheme)
		XCTAssertEqual(decodedRequest.version, request.version)
		XCTAssertEqual(decodedRequest.requestID, request.requestID)
		XCTAssertEqual(decodedRequest.fileBookmark, request.fileBookmark)
		XCTAssertEqual(decodedRequest.applicationPath, request.applicationPath)
		XCTAssertThrowsError(
			try OpenWithBridgeCodec.request(
				from: try XCTUnwrap(URL(string: "glance-open-with://request?payload=invalid"))
			)
		)
	}

	func testBridgeCodecRoundTripsCompactHandoffURL() throws {
		let handoff = OpenWithBridgeHandoff(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			requestStoreName: "com.chamburr.Glance.OpenWithBridge.\(UUID().uuidString)"
		)

		let handoffURL = try OpenWithBridgeCodec.handoffURL(for: handoff)
		let decodedHandoff = try OpenWithBridgeCodec.handoff(from: handoffURL)

		XCTAssertEqual(handoffURL.host, OpenWithBridgeConstants.handoffHost)
		XCTAssertLessThan(handoffURL.absoluteString.utf8.count, 2048)
		XCTAssertEqual(decodedHandoff.version, handoff.version)
		XCTAssertEqual(decodedHandoff.requestID, handoff.requestID)
		XCTAssertEqual(decodedHandoff.requestStoreName, handoff.requestStoreName)
		XCTAssertFalse(handoffURL.absoluteString.contains("Applications"))
	}

	func testBridgeServerReceivesCompactHandoffNotification() throws {
		let fileURL = try writeFile(named: "notification.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher()
		let securityScopeManager = StubOpenWithSecurityScopeManager(fileURL: fileURL)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		server.start()
		let dispatcher = StubOpenWithBridgeDispatcher { requestURL in
			notificationCenter.post(
				name: OpenWithBridgeConstants.requestNotification,
				object: requestURL.absoluteString
			)
		}
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "distributed handoff response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertNil(receivedError)
		XCTAssertEqual(launcher.openCalls.count, 1)
		XCTAssertEqual(requestStore.count, 0)
		XCTAssertEqual(notificationCenter.observerCount, 1)
	}

	func testBridgeServerIgnoresFullRequestsOnDistributedChannel() throws {
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher()
		let securityScopeManager = StubOpenWithSecurityScopeManager(
			fileURL: try writeFile(named: "ignored-full-request.txt")
		)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		server.start()
		let request = OpenWithBridgeRequest(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			fileBookmark: Data([1, 2, 3]),
			applicationPath: "/Applications/Editor.app"
		)

		notificationCenter.post(
			name: OpenWithBridgeConstants.requestNotification,
			object: try OpenWithBridgeCodec.requestURL(for: request).absoluteString
		)

		XCTAssertEqual(securityScopeManager.resolveCount, 0)
		XCTAssertTrue(launcher.compatibilityChecks.isEmpty)
		XCTAssertTrue(launcher.openCalls.isEmpty)
	}

	func testBridgeRevalidatesApplicationCompatibilityBeforeOpening() throws {
		let fileURL = try writeFile(named: "incompatible.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher(isCompatible: false)
		let securityScopeManager = StubOpenWithSecurityScopeManager(fileURL: fileURL)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		let dispatcher = StubOpenWithBridgeDispatcher { requestURL in
			server.handle(requestURL)
		}
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "incompatible response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertEqual(
			(receivedError as? OpenWithBridgeRemoteError)?.message,
			OpenWithBridgeError.incompatibleApplication.localizedDescription
		)
		XCTAssertEqual(launcher.compatibilityChecks.count, 1)
		XCTAssertTrue(launcher.openCalls.isEmpty)
		XCTAssertEqual(securityScopeManager.startCount, 1)
		XCTAssertEqual(securityScopeManager.stopCount, 1)
	}

	func testBridgeRejectsRequestWhenSecurityScopeCannotStart() throws {
		let fileURL = try writeFile(named: "scope-denied.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher()
		let securityScopeManager = StubOpenWithSecurityScopeManager(
			fileURL: fileURL,
			startSucceeds: false
		)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		let dispatcher = StubOpenWithBridgeDispatcher { server.handle($0) }
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "scope denied response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertEqual(
			(receivedError as? OpenWithBridgeRemoteError)?.message,
			OpenWithBridgeError.securityScopeUnavailable.localizedDescription
		)
		XCTAssertEqual(securityScopeManager.resolveCount, 1)
		XCTAssertEqual(securityScopeManager.startCount, 1)
		XCTAssertEqual(securityScopeManager.stopCount, 0)
		XCTAssertTrue(launcher.compatibilityChecks.isEmpty)
		XCTAssertTrue(launcher.openCalls.isEmpty)
	}

	func testBridgeRejectsStaleBookmarkBeforeStartingScope() throws {
		let fileURL = try writeFile(named: "stale.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher()
		let securityScopeManager = StubOpenWithSecurityScopeManager(
			fileURL: fileURL,
			resolveError: OpenWithBridgeError.invalidRequest
		)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		let dispatcher = StubOpenWithBridgeDispatcher { server.handle($0) }
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "stale bookmark response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertEqual(
			(receivedError as? OpenWithBridgeRemoteError)?.message,
			OpenWithBridgeError.invalidRequest.localizedDescription
		)
		XCTAssertEqual(securityScopeManager.resolveCount, 1)
		XCTAssertEqual(securityScopeManager.startCount, 0)
		XCTAssertEqual(securityScopeManager.stopCount, 0)
		XCTAssertTrue(launcher.openCalls.isEmpty)
	}

	func testBridgeBalancesScopeWhenTargetApplicationFails() throws {
		let fileURL = try writeFile(named: "launcher-failure.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let launcher = StubOpenWithLauncher(openError: TestOpenWithError.failed)
		let securityScopeManager = StubOpenWithSecurityScopeManager(fileURL: fileURL)
		let server = makeBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
		let dispatcher = StubOpenWithBridgeDispatcher { server.handle($0) }
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		let completion = expectation(description: "launcher failure response")
		var receivedError: Error?

		client.open(fileURL: fileURL, with: applicationURL) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		XCTAssertEqual(
			(receivedError as? OpenWithBridgeRemoteError)?.message,
			"The selected application could not open this file."
		)
		XCTAssertEqual(securityScopeManager.startCount, 1)
		XCTAssertEqual(securityScopeManager.stopCount, 1)
	}

	func testBridgeCodecRejectsOversizedAndAmbiguousPayloads() throws {
		let oversizedRequest = OpenWithBridgeRequest(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			fileBookmark: Data(
				repeating: 0,
				count: OpenWithBridgeConstants.maximumPayloadSize
			),
			applicationPath: "/Applications/Editor.app"
		)
		XCTAssertThrowsError(try OpenWithBridgeCodec.requestURL(for: oversizedRequest))

		let validRequest = OpenWithBridgeRequest(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			fileBookmark: Data([1]),
			applicationPath: "/Applications/Editor.app"
		)
		let validURL = try OpenWithBridgeCodec.requestURL(for: validRequest)
		let payload = try XCTUnwrap(
			URLComponents(url: validURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
		)
		let ambiguousURL = try XCTUnwrap(
			URL(string: "glance-open-with://request?payload=\(payload)&payload=\(payload)")
		)
		XCTAssertThrowsError(try OpenWithBridgeCodec.request(from: ambiguousURL))
	}

	func testBridgeResponseRejectsPartialErrorShape() {
		let response = OpenWithBridgeResponse(
			version: OpenWithBridgeConstants.currentVersion,
			requestID: UUID(),
			errorDomain: "Test",
			errorCode: nil,
			errorMessage: "Failure"
		)

		XCTAssertThrowsError(try response.validatedError())
	}

	func testBridgeCorrelatesAndCompletesExactlyOnceForDuplicateResponses() throws {
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let dispatcher = StubOpenWithBridgeDispatcher { requestURL in
			guard let handoff = try? OpenWithBridgeCodec.handoff(from: requestURL),
			      let storedRequest = try? requestStore.take(named: handoff.requestStoreName),
			      let storedRequestURL = URL(string: storedRequest),
			      let request = try? OpenWithBridgeCodec.request(from: storedRequestURL)
			else {
				return
			}
			let response = OpenWithBridgeResponse.success(requestID: request.requestID)
			guard let responseString = try? OpenWithBridgeCodec.responseString(for: response) else {
				return
			}
			let unrelatedResponse = OpenWithBridgeResponse.success(requestID: UUID())
			if let unrelatedResponseString = try? OpenWithBridgeCodec.responseString(
				for: unrelatedResponse
			) {
				notificationCenter.post(
					name: OpenWithBridgeConstants.responseNotification,
					object: unrelatedResponseString
				)
			}
			notificationCenter.post(
				name: OpenWithBridgeConstants.responseNotification,
				object: responseString
			)
			notificationCenter.post(
				name: OpenWithBridgeConstants.responseNotification,
				object: responseString
			)
		}
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore
		)
		var completionCount = 0

		client.open(
			fileURL: try writeFile(named: "duplicate-response.txt"),
			with: URL(fileURLWithPath: "/Applications/Editor.app")
		) { _ in
			completionCount += 1
		}

		XCTAssertEqual(completionCount, 1)
		XCTAssertEqual(notificationCenter.observerCount, 0)
		XCTAssertEqual(requestStore.count, 0)
	}

	func testBridgeTimesOutWhenApplicationIsNotRunning() throws {
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let dispatcher = StubOpenWithBridgeDispatcher()
		let client = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore,
			timeout: .milliseconds(100)
		)
		let completion = expectation(description: "bridge timeout")
		var receivedError: Error?

		client.open(
			fileURL: try writeFile(named: "timeout.txt"),
			with: URL(fileURLWithPath: "/Applications/Editor.app")
		) { error in
			receivedError = error
			completion.fulfill()
		}
		wait(for: [completion], timeout: 1)

		guard let bridgeError = receivedError as? OpenWithBridgeError else {
			return XCTFail("Expected an Open With bridge error")
		}
		guard case .requestTimedOut = bridgeError else {
			return XCTFail("Expected the bridge request to time out")
		}
		XCTAssertEqual(notificationCenter.observerCount, 0)
		XCTAssertEqual(requestStore.count, 0)
	}

	func testBridgeDeinitCancelsPendingRequestsAndRemovesObservers() throws {
		let notificationCenter = StubOpenWithBridgeNotificationCenter()
		let requestStore = StubOpenWithBridgeRequestStore()
		let dispatcher = StubOpenWithBridgeDispatcher()
		var client: OpenWithBridgeClient? = makeBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore,
			timeout: .seconds(10)
		)
		var completionCount = 0
		var receivedError: Error?

		client?.open(
			fileURL: try writeFile(named: "deinit.txt"),
			with: URL(fileURLWithPath: "/Applications/Editor.app")
		) { error in
			completionCount += 1
			receivedError = error
		}
		XCTAssertEqual(notificationCenter.observerCount, 1)

		client = nil

		XCTAssertEqual(notificationCenter.observerCount, 0)
		XCTAssertEqual(requestStore.count, 0)
		XCTAssertEqual(completionCount, 1)
		guard let bridgeError = receivedError as? OpenWithBridgeError else {
			return XCTFail("Expected an Open With bridge error")
		}
		guard case .bridgeUnavailable = bridgeError else {
			return XCTFail("Expected deinitialization to cancel the request")
		}
	}

	func testOpeningFailureShowsTransientNonmodalUtilityBarError() throws {
		let fileURL = try writeFile(named: "failure.txt")
		let applicationURL = URL(fileURLWithPath: "/Applications/Editor.app")
		let workspace = StubWorkspaceApplicationProvider(
			compatibleApplicationURLs: [applicationURL],
			displayNames: [applicationURL: "Editor"],
			openError: TestOpenWithError.failed
		)
		let mainVC = makeMainVC(workspace: workspace)
		mainVC.installTopLevelPreview(OpenWithStubPreviewVC(), file: try File(url: fileURL))

		mainVC.openWithApplication(at: applicationURL)

		XCTAssertEqual(workspace.openCalls.count, 1)
		XCTAssertEqual(mainVC.statusLabel.stringValue, "Couldn’t open with Editor")
	}

	private func makeMainVC(workspace: StubWorkspaceApplicationProvider) -> MainVC {
		let mainVC = MainVC()
		mainVC.openWithService = OpenWithService(workspace: workspace)
		mainVC.loadViewIfNeeded()
		return mainVC
	}

	private func makeBridgeServer(
		notificationCenter: OpenWithBridgeNotifying,
		launcher: OpenWithLaunching,
		securityScopeManager: OpenWithSecurityScopeManaging,
		requestStore: OpenWithBridgeRequestStoring
	) -> OpenWithBridgeServer {
		OpenWithBridgeServer(
			notificationCenter: notificationCenter,
			launcher: launcher,
			securityScopeManager: securityScopeManager,
			requestStore: requestStore
		)
	}

	private func makeBridgeClient(
		notificationCenter: OpenWithBridgeNotifying,
		dispatcher: OpenWithBridgeDispatching,
		requestStore: OpenWithBridgeRequestStoring,
		timeout: Duration = .seconds(1)
	) -> OpenWithBridgeClient {
		OpenWithBridgeClient(
			notificationCenter: notificationCenter,
			dispatcher: dispatcher,
			requestStore: requestStore,
			timeout: timeout
		)
	}

	private func fileNode(
		named name: String,
		isDirectory: Bool = false,
		isPackage: Bool = false,
		isSymbolicLink: Bool = false
	) -> FileTreeNode {
		FileTreeNode(
			name: name,
			size: 1,
			isDirectory: isDirectory,
			dateModified: nil,
			fileURL: temporaryDirectory.appendingPathComponent(name),
			isPackage: isPackage,
			isSymbolicLink: isSymbolicLink
		)
	}

	private func makeDirectory(named name: String) throws -> URL {
		let directoryURL = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)
		return directoryURL
	}

	private func writeFile(named name: String) throws -> URL {
		let fileURL = temporaryDirectory.appendingPathComponent(name)
		try Data().write(to: fileURL)
		return fileURL
	}
}

@MainActor
private final class StubWorkspaceApplicationProvider: WorkspaceApplicationProviding {
	struct OpenCall {
		let fileURL: URL
		let applicationURL: URL
	}

	let compatibleApplicationURLs: [URL]
	let configuredDefaultApplicationURL: URL?
	let bundleIdentifiers: [URL: String]
	let displayNames: [URL: String]
	let openError: Error?
	private(set) var openCalls = [OpenCall]()
	private(set) var defaultApplicationRequestCount = 0

	init(
		compatibleApplicationURLs: [URL],
		defaultApplicationURL: URL? = nil,
		bundleIdentifiers: [URL: String] = [:],
		displayNames: [URL: String] = [:],
		openError: Error? = nil
	) {
		self.compatibleApplicationURLs = compatibleApplicationURLs
		configuredDefaultApplicationURL = defaultApplicationURL
		self.bundleIdentifiers = bundleIdentifiers
		self.displayNames = displayNames
		self.openError = openError
	}

	func compatibleApplicationURLs(for _: URL) -> [URL] {
		compatibleApplicationURLs
	}

	func defaultApplicationURL(for _: URL) -> URL? {
		defaultApplicationRequestCount += 1
		return configuredDefaultApplicationURL
	}

	func bundleIdentifier(for applicationURL: URL) -> String? {
		bundleIdentifiers[applicationURL]
	}

	func displayName(for applicationURL: URL) -> String {
		displayNames[applicationURL] ?? applicationURL.deletingPathExtension().lastPathComponent
	}

	func icon(for _: URL) -> NSImage {
		NSImage(size: NSSize(width: 16, height: 16))
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		openCalls.append(OpenCall(fileURL: fileURL, applicationURL: applicationURL))
		completion(openError)
	}
}

@MainActor
private final class StubOpenWithBridge: OpenWithBridgeSending {
	struct OpenCall {
		let fileURL: URL
		let applicationURL: URL
	}

	private(set) var openCalls = [OpenCall]()

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		openCalls.append(OpenCall(fileURL: fileURL, applicationURL: applicationURL))
		completion(nil)
	}
}

@MainActor
private final class StubOpenWithLauncher: OpenWithLaunching {
	struct OpenCall {
		let fileURL: URL
		let applicationURL: URL
	}

	let isCompatible: Bool
	let openError: Error?
	private(set) var compatibilityChecks = [OpenCall]()
	private(set) var openCalls = [OpenCall]()

	init(isCompatible: Bool = true, openError: Error? = nil) {
		self.isCompatible = isCompatible
		self.openError = openError
	}

	func isApplication(_ applicationURL: URL, compatibleWith fileURL: URL) -> Bool {
		compatibilityChecks.append(OpenCall(fileURL: fileURL, applicationURL: applicationURL))
		return isCompatible
	}

	func open(
		fileURL: URL,
		with applicationURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		openCalls.append(OpenCall(fileURL: fileURL, applicationURL: applicationURL))
		completion(openError)
	}
}

@MainActor
private final class StubOpenWithSecurityScopeManager: OpenWithSecurityScopeManaging {
	let fileURL: URL
	let startSucceeds: Bool
	let resolveError: Error?
	private(set) var resolveCount = 0
	private(set) var startCount = 0
	private(set) var stopCount = 0

	init(
		fileURL: URL,
		startSucceeds: Bool = true,
		resolveError: Error? = nil
	) {
		self.fileURL = fileURL
		self.startSucceeds = startSucceeds
		self.resolveError = resolveError
	}

	func resolveBookmark(_: Data) throws -> URL {
		resolveCount += 1
		if let resolveError {
			throw resolveError
		}
		return fileURL
	}

	func startAccessing(_: URL) -> Bool {
		startCount += 1
		return startSucceeds
	}

	func stopAccessing(_: URL) {
		stopCount += 1
	}
}

@MainActor
private final class StubOpenWithBridgeRequestStore: OpenWithBridgeRequestStoring {
	private var requests = [String: String]()
	var count: Int {
		requests.count
	}

	func store(_ requestString: String) throws -> String {
		let name = UUID().uuidString
		requests[name] = requestString
		return name
	}

	func take(named name: String) throws -> String {
		guard let requestString = requests.removeValue(forKey: name) else {
			throw OpenWithBridgeError.invalidRequest
		}
		return requestString
	}

	func remove(named name: String) {
		requests[name] = nil
	}
}

@MainActor
private final class StubOpenWithBridgeDispatcher: OpenWithBridgeDispatching {
	private let handler: ((URL) -> Void)?
	private(set) var requestURLs = [URL]()

	init(handler: ((URL) -> Void)? = nil) {
		self.handler = handler
	}

	func dispatch(
		requestURL: URL,
		completion: @escaping @MainActor (Error?) -> Void
	) {
		requestURLs.append(requestURL)
		handler?(requestURL)
		completion(nil)
	}
}

@MainActor
private final class StubOpenWithBridgeNotificationCenter: OpenWithBridgeNotifying {
	private final class ObserverToken: NSObject {}

	private struct Observer {
		let name: Notification.Name
		let handler: @MainActor @Sendable (String) -> Void
	}

	private var observers = [ObjectIdentifier: Observer]()
	var observerCount: Int {
		observers.count
	}

	func addObserver(
		forName name: Notification.Name,
		handler: @escaping @MainActor @Sendable (String) -> Void
	) -> NSObjectProtocol {
		let token = ObserverToken()
		observers[ObjectIdentifier(token)] = Observer(name: name, handler: handler)
		return token
	}

	func removeObserver(_ observer: NSObjectProtocol) {
		observers[ObjectIdentifier(observer as AnyObject)] = nil
	}

	func post(name: Notification.Name, object: String) {
		for observer in observers.values where observer.name == name {
			observer.handler(object)
		}
	}
}

private final class OpenWithStubPreviewVC: NSViewController, PreviewVC {}

private enum TestOpenWithError: Error {
	case failed
}
