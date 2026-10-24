import Foundation
import XCTest

@MainActor
final class FileChangeMonitorTests: XCTestCase {
	// swiftlint:disable:next modifier_order
	private nonisolated(unsafe) var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GlanceFileChangeTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: temporaryDirectory,
			withIntermediateDirectories: true,
		)
	}

	override func tearDownWithError() throws {
		if let temporaryDirectory {
			try? FileManager.default.removeItem(at: temporaryDirectory)
		}
		try super.tearDownWithError()
	}

	func testMonitorReportsOneChangePerInPlaceAndAtomicSaveAndStopsOnTeardown() async throws {
		let fileURL = try writeFile(named: "watched.md", contents: "first")
		let changes = ChangeCounter()
		let inPlaceSave = expectation(description: "in-place save")
		let atomicSave = expectation(description: "atomic save")
		inPlaceSave.assertForOverFulfill = true
		atomicSave.assertForOverFulfill = true
		let monitor = FileChangeMonitor(fileURL: fileURL) {
			changes.count += 1
			switch changes.count {
				case 1:
					inPlaceSave.fulfill()
				case 2:
					atomicSave.fulfill()
				default:
					break
			}
		}

		XCTAssertTrue(monitor.start())
		XCTAssertTrue(monitor.isWatching)

		try "second".write(to: fileURL, atomically: false, encoding: .utf8)
		await fulfillment(of: [inPlaceSave], timeout: 5)

		try "third".write(to: fileURL, atomically: true, encoding: .utf8)
		await fulfillment(of: [atomicSave], timeout: 5)

		try await Task.sleep(for: .milliseconds(400))
		XCTAssertEqual(changes.count, 2)

		monitor.stop()
		XCTAssertFalse(monitor.isWatching)

		try "fourth".write(to: fileURL, atomically: true, encoding: .utf8)
		try await Task.sleep(for: .milliseconds(400))
		XCTAssertEqual(changes.count, 2)
	}

	func testMonitorIgnoresUnrelatedDirectoryTraffic() async throws {
		let fileURL = try writeFile(named: "watched.md", contents: "first")
		let changes = ChangeCounter()
		let monitor = FileChangeMonitor(fileURL: fileURL) {
			changes.count += 1
		}

		XCTAssertTrue(monitor.start())
		_ = try writeFile(named: "sibling.txt", contents: "unrelated")
		try await Task.sleep(for: .milliseconds(400))
		XCTAssertEqual(changes.count, 0)
		monitor.stop()
	}

	func testMonitorStopsReportingDirectoryTrafficAfterTheFileIsRemoved() async throws {
		let fileURL = try writeFile(named: "removed.md", contents: "first")
		let changes = ChangeCounter()
		let deletion = expectation(description: "file removed")
		let monitor = FileChangeMonitor(fileURL: fileURL) {
			changes.count += 1
			deletion.fulfill()
		}

		XCTAssertTrue(monitor.start())
		try FileManager.default.removeItem(at: fileURL)
		await fulfillment(of: [deletion], timeout: 5)

		_ = try writeFile(named: "sibling.txt", contents: "unrelated")
		try await Task.sleep(for: .milliseconds(400))
		XCTAssertEqual(changes.count, 1)
		monitor.stop()
	}

	func testMonitorCoalescesABurstOfSavesIntoOneCallback() async throws {
		let fileURL = try writeFile(named: "burst.md", contents: "zero")
		let changes = ChangeCounter()
		let burst = expectation(description: "save burst")
		let monitor = FileChangeMonitor(fileURL: fileURL) {
			changes.count += 1
			burst.fulfill()
		}

		XCTAssertTrue(monitor.start())
		for index in 1 ... 5 {
			try "value \(index)"
				.write(to: fileURL, atomically: index.isMultiple(of: 2), encoding: .utf8)
		}

		await fulfillment(of: [burst], timeout: 5)
		try await Task.sleep(for: .milliseconds(400))
		XCTAssertEqual(changes.count, 1)
		monitor.stop()
	}

	private func writeFile(named name: String, contents: String) throws -> URL {
		let fileURL = temporaryDirectory.appendingPathComponent(name)
		try contents.write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}
}

@MainActor
private final class ChangeCounter {
	var count = 0
}
