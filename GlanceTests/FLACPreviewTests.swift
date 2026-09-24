import AVKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class FLACPreviewTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlanceFLACTests-\(UUID().uuidString)", isDirectory: true)
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

	func testFLACUsesNativePlaybackAndFitsANarrowPreview() throws {
		let fileURL = try makeFLACFixture()
		let preview = AVPlayerPreviewVC(fileURL: fileURL, showsWaveform: true)
		preview.loadViewIfNeeded()
		preview.view.frame = NSRect(x: 0, y: 0, width: 260, height: 340)
		preview.view.layoutSubtreeIfNeeded()

		XCTAssertEqual(preview.playerView?.controlsStyle, .inline)
		XCTAssertNotNil(preview.player)
		let waveform = try XCTUnwrap(preview.waveformView)
		XCTAssertGreaterThan(waveform.frame.width, 200)
		XCTAssertLessThanOrEqual(waveform.frame.maxX, preview.view.bounds.maxX)

		preview.tearDown()
		XCTAssertNil(preview.player)
		XCTAssertNil(preview.playerView)
		XCTAssertNil(preview.waveformView)
	}

	func testTopLevelAndNestedFLACBothUseTheMediaController() async throws {
		let fileURL = try makeFLACFixture()
		let file = try File(url: fileURL)
		let mainVC = MainVC()
		mainVC.loadViewIfNeeded()
		try await mainVC.previewFile(file: file)
		let topLevel = try XCTUnwrap(mainVC.currentPreviewController as? AVPlayerPreviewVC)

		let node = FileTreeNode(
			name: fileURL.lastPathComponent,
			size: file.size,
			isDirectory: false,
			dateModified: nil,
			fileURL: fileURL,
			contentTypeIdentifier: UTType.data.identifier
		)
		let nested = try await DefaultNestedPreviewProvider().makePreviewController(for: node)
		let nestedMedia = try XCTUnwrap(nested as? AVPlayerPreviewVC)
		nestedMedia.loadViewIfNeeded()
		XCTAssertEqual(topLevel.waveformView != nil, nestedMedia.waveformView != nil)
		topLevel.tearDown()
		nestedMedia.tearDown()
	}

	func testFLACAutoplaysAndStopsWhenPreviewWindowIsHidden() throws {
		let preview = AVPlayerPreviewVC(fileURL: try makeFLACFixture())
		preview.loadViewIfNeeded()
		defer { preview.tearDown() }
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.level = .floating
		window.contentView = preview.view
		preview.viewDidAppear()
		let player = try XCTUnwrap(preview.player)
		XCTAssertNotEqual(player.timeControlStatus, .paused)

		preview.handlePreviewWindowChange(
			Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
		)
		XCTAssertEqual(player.timeControlStatus, .paused)
		XCTAssertEqual(player.rate, 0)
	}

	func testFinderSidebarDoesNotAutoplayFLAC() throws {
		let preview = AVPlayerPreviewVC(fileURL: try makeFLACFixture())
		preview.loadViewIfNeeded()
		defer { preview.tearDown() }
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 313, height: 406),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.level = .normal
		window.contentView = preview.view
		preview.viewDidAppear()
		XCTAssertFalse(AVPlayerPreviewVC.shouldAutoplay(in: window))
		XCTAssertEqual(preview.player?.timeControlStatus, .paused)
		XCTAssertEqual(preview.player?.rate, 0)
	}

	func testFLACStopsWhenPreviewDisappears() throws {
		let preview = AVPlayerPreviewVC(fileURL: try makeFLACFixture())
		preview.loadViewIfNeeded()
		defer { preview.tearDown() }
		let player = try XCTUnwrap(preview.player)
		player.play()

		preview.viewWillDisappear()

		XCTAssertEqual(player.timeControlStatus, .paused)
		XCTAssertEqual(player.rate, 0)
	}

	func testWaveformProgressTracksPlaybackAndClampsInvalidPositions() throws {
		let preview = AVPlayerPreviewVC(fileURL: try makeFLACFixture(), showsWaveform: true)
		preview.loadViewIfNeeded()
		defer { preview.tearDown() }
		let waveform = try XCTUnwrap(preview.waveformView)

		preview.updateWaveformProgress(elapsed: 2, duration: 8)
		XCTAssertEqual(waveform.progress, 0.25)
		preview.updateWaveformProgress(elapsed: 20, duration: 8)
		XCTAssertEqual(waveform.progress, 1)
		preview.updateWaveformProgress(elapsed: -2, duration: 8)
		XCTAssertEqual(waveform.progress, 0)
		preview.updateWaveformProgress(elapsed: 1, duration: .nan)
		XCTAssertEqual(waveform.progress, 0)
	}

	func testFLACPlaybackWorksWhenWaveformIsDisabled() throws {
		let preview = AVPlayerPreviewVC(fileURL: try makeFLACFixture(), showsWaveform: false)
		preview.loadViewIfNeeded()
		defer { preview.tearDown() }
		XCTAssertNil(preview.waveformView)
		XCTAssertEqual(preview.playerView?.controlsStyle, .inline)
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.level = .floating
		window.contentView = preview.view
		preview.viewDidAppear()
		XCTAssertNotEqual(preview.player?.timeControlStatus, .paused)
	}

	func testWaveformPreferenceCrossesThePreviewSettingsBridge() async throws {
		let suiteName = "GlanceTests.FLACSettings.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AppSettingsStore(defaults: defaults)
		let center = StubPreviewSettingsCenter()
		let server = PreviewSettingsServer(settingsStore: store, notificationCenter: center)
		server.start()
		let client = PreviewSettingsClient(notificationCenter: center, timeout: .seconds(1))

		store.flacWaveformEnabled = false
		let disabled = await client.flacWaveformEnabled()
		XCTAssertFalse(disabled)
		store.flacWaveformEnabled = true
		let enabled = await client.flacWaveformEnabled()
		XCTAssertTrue(enabled)
		XCTAssertEqual(center.observerCount, 1)
	}

	func testWaveformPreferenceDefaultsOnWhenTheBridgeIsUnavailable() async {
		let client = PreviewSettingsClient(
			notificationCenter: StubPreviewSettingsCenter(),
			timeout: .milliseconds(1)
		)
		let enabled = await client.flacWaveformEnabled()
		XCTAssertTrue(enabled)
	}

	func testWaveformSamplesARealFLACIntoABoundedEnvelopeOffMain() async throws {
		let fileURL = try makeFLACFixture()
		let amplitudes = try await Task.detached(priority: .utility) {
			XCTAssertFalse(Thread.isMainThread)
			return try await FLACWaveformAnalyzer.envelope(for: fileURL)
		}.value

		XCTAssertEqual(amplitudes.count, FLACWaveformAnalyzer.binCount)
		XCTAssertTrue(amplitudes.contains { $0 > 0.5 })
		XCTAssertTrue(amplitudes.allSatisfy { (0 ... 1).contains($0) })
	}

	func testMalformedFLACFailsWithoutAPlaybackBlocker() async throws {
		let fileURL = temporaryDirectory.appendingPathComponent("broken.flac")
		try Data("not FLAC".utf8).write(to: fileURL)
		do {
			_ = try await FLACWaveformAnalyzer.envelope(for: fileURL)
			XCTFail("Malformed FLAC should not produce a waveform")
		} catch {
			// Playback remains available even when waveform decoding fails.
		}

		let preview = AVPlayerPreviewVC(fileURL: fileURL)
		preview.loadViewIfNeeded()
		XCTAssertNotNil(preview.playerView)
		preview.tearDown()
	}

	func testUnsupportedFLACDecoderFailsWithoutCrashing() async throws {
		let fileURL = try makeFLACFixture(named: "sine.flac.b64")
		do {
			_ = try await FLACWaveformAnalyzer.envelope(for: fileURL)
			XCTFail("The unsupported sample rate should not produce a waveform")
		} catch {
			XCTAssertFalse(error is CancellationError)
		}
	}

	func testChangingFLACStopsAnalysis() async throws {
		let fileURL = try makeFLACFixture()
		do {
			_ = try await FLACWaveformAnalyzer.envelope(for: fileURL) { index in
				guard index == 0 else {
					return
				}
				let handle = try FileHandle(forWritingTo: fileURL)
				try handle.seekToEnd()
				try handle.write(contentsOf: Data([0]))
				try handle.close()
			}
			XCTFail("A changed file should not produce a waveform")
		} catch let error as FLACWaveformError {
			guard case .fileChanged = error else {
				return XCTFail("Expected fileChanged, got \(error)")
			}
		}
	}

	func testCancelledWaveformAnalysisStopsBeforeReading() async throws {
		let fileURL = try makeFLACFixture()
		let task = Task.detached { () async throws -> [Float] in
			withUnsafeCurrentTask { $0?.cancel() }
			return try await FLACWaveformAnalyzer.envelope(for: fileURL)
		}
		do {
			_ = try await task.value
			XCTFail("Cancelled analysis should not return a waveform")
		} catch is CancellationError {
			// Cancellation is checked before the file is opened.
		}
	}

	func testCancellationStopsBetweenSampleWindows() async throws {
		let fileURL = try makeFLACFixture()
		let task = Task.detached { () async throws -> [Float] in
			try await FLACWaveformAnalyzer.envelope(for: fileURL) { index in
				if index == 0 {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
		}
		do {
			_ = try await task.value
			XCTFail("Cancelled analysis should stop before the next window")
		} catch is CancellationError {
			// Each sample window checks cancellation before it starts.
		}
	}

	func testFLACBypassesTheTextFileSizeLimit() throws {
		let fileURL = temporaryDirectory.appendingPathComponent("large.flac")
		try Data().write(to: fileURL)
		let handle = try FileHandle(forWritingTo: fileURL)
		try handle.truncate(atOffset: UInt64(PreviewPolicy.maximumFileSize + 1))
		try handle.close()
		XCTAssertNoThrow(try PreviewPolicy.validateFileSize(File(url: fileURL)))
	}

	func testOversizedRecordingSkipsWaveformAnalysis() async throws {
		let fileURL = temporaryDirectory.appendingPathComponent("recording.flac")
		try Data().write(to: fileURL)
		let handle = try FileHandle(forWritingTo: fileURL)
		try handle.truncate(atOffset: FLACWaveformAnalyzer.maximumFileSize + 1)
		try handle.close()
		do {
			_ = try await FLACWaveformAnalyzer.envelope(for: fileURL)
			XCTFail("Oversized recording should skip waveform analysis")
		} catch let error as FLACWaveformError {
			guard case FLACWaveformError.fileTooLarge = error else {
				return XCTFail("Expected the waveform file-size limit, got \(error)")
			}
		} catch {
			XCTFail("Expected the waveform file-size limit, got \(error)")
		}
	}

	private func makeFLACFixture(named name: String = "sine44100.flac.b64") throws -> URL {
		let fixtureURL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles/audio/\(name)")
		let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
		let base64 = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
		let data = try XCTUnwrap(Data(base64Encoded: base64))
		let fileURL = temporaryDirectory.appendingPathComponent("sine.flac")
		try data.write(to: fileURL)
		return fileURL
	}
}

@MainActor
private final class StubPreviewSettingsCenter: OpenWithBridgeNotifying {
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
		for observer in Array(observers.values) where observer.name == name {
			observer.handler(object)
		}
	}
}
