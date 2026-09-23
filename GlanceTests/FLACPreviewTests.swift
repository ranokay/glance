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

	func testFLACUsesNativePlaybackAndFitsANarrowPreview() async throws {
		let fileURL = try makeFLACFixture()
		let file = try File(url: fileURL)
		let generated = try await FLACPreview().createPreviewVC(file: file)
		let preview = try XCTUnwrap(generated as? AVPlayerPreviewVC)
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
		XCTAssertNotNil(topLevel.waveformView)

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
		XCTAssertNotNil(nestedMedia.waveformView)
		topLevel.tearDown()
		nestedMedia.tearDown()
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
