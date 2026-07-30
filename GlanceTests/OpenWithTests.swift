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

private final class OpenWithStubPreviewVC: NSViewController, PreviewVC {}

private enum TestOpenWithError: Error {
	case failed
}
