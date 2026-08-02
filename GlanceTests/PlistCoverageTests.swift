import XCTest

final class PlistCoverageTests: XCTestCase {
	func testQuickLookInfoPlistContainsRepresentativeSupportedContentTypes() throws {
		let supportedTypes = try quickLookSupportedContentTypes()
		let requiredTypes = [
			"public.folder",
			"org.7-zip.7-zip-archive",
			"com.sun.java-archive",
			"com.sun.web-application-archive",
			"org.gnu.gnu-zip-tar-archive",
			"public.tar-archive",
			"public.zip-archive",
			"org.jupyter.ipynb",
			"public.jupyter-notebook",
			"com.microsoft.ini",
			"public.markdown",
			"net.daringfireball.markdown",
			"public.tab-separated-values-text",
			"dyn.ah62d4rv4ge80n5dwqq",
			"public.source-code",
			"public.swift-source",
			"public.toml",
			"public.plain-text",
		]

		for requiredType in requiredTypes {
			XCTAssertTrue(supportedTypes.contains(requiredType), requiredType)
		}
	}

	func testQuickLookSupportedContentTypesAreUnique() throws {
		let supportedTypes = try quickLookSupportedContentTypes()

		XCTAssertEqual(Set(supportedTypes).count, supportedTypes.count)
	}

	func testAppInfoPlistRegistersOpenWithBridgeURLScheme() throws {
		let plistURL = repositoryRoot()
			.appendingPathComponent("Glance", isDirectory: true)
			.appendingPathComponent("Info.plist")
		let data = try Data(contentsOf: plistURL)
		guard
			let plist = try PropertyListSerialization.propertyList(
				from: data,
				options: [],
				format: nil
			) as? [String: Any],
			let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]]
		else {
			throw PlistCoverageError.missingURLTypes(plistURL)
		}
		let urlSchemes = urlTypes.flatMap {
			$0["CFBundleURLSchemes"] as? [String] ?? []
		}

		XCTAssertTrue(urlSchemes.contains(OpenWithBridgeConstants.requestScheme))
	}

	func testProjectAndReleaseWorkflowRequireMacOS26() throws {
		let projectContents = try String(
			contentsOf: repositoryRoot()
				.appendingPathComponent("Glance.xcodeproj", isDirectory: true)
				.appendingPathComponent("project.pbxproj"),
			encoding: .utf8
		)
		let workflowContents = try String(
			contentsOf: repositoryRoot()
				.appendingPathComponent(".github", isDirectory: true)
				.appendingPathComponent("workflows", isDirectory: true)
				.appendingPathComponent("release.yml"),
			encoding: .utf8
		)

		XCTAssertTrue(projectContents.contains("MACOSX_DEPLOYMENT_TARGET = 26.0;"))
		XCTAssertTrue(projectContents.contains("MACOSX_DEPLOYMENT_TARGET:-26.0"))
		XCTAssertFalse(projectContents.contains("MACOSX_DEPLOYMENT_TARGET = 15.0;"))
		XCTAssertTrue(workflowContents.contains("runs-on: macos-26"))
		XCTAssertTrue(workflowContents.contains("Release builds require Xcode 26"))
	}

	func testMiseUsesDeterministicToolVersions() throws {
		let miseContents = try String(
			contentsOf: repositoryRoot().appendingPathComponent("mise.toml"),
			encoding: .utf8
		)

		XCTAssertTrue(miseContents.contains("go = \"1.26.5\""))
		XCTAssertTrue(miseContents.contains("swiftformat = \"0.61.1\""))
		XCTAssertTrue(miseContents.contains("swiftlint = \"0.63.3\""))
		XCTAssertFalse(miseContents.contains("= \"latest\""))
	}

	private func quickLookSupportedContentTypes() throws -> [String] {
		let plistURL = repositoryRoot()
			.appendingPathComponent("QLPlugin", isDirectory: true)
			.appendingPathComponent("Info.plist")
		let data = try Data(contentsOf: plistURL)
		guard
			let plist = try PropertyListSerialization.propertyList(
				from: data,
				options: [],
				format: nil
			) as? [String: Any],
			let extensionDictionary = plist["NSExtension"] as? [String: Any],
			let attributes = extensionDictionary["NSExtensionAttributes"] as? [String: Any],
			let supportedTypes = attributes["QLSupportedContentTypes"] as? [String]
		else {
			throw PlistCoverageError.missingSupportedContentTypes(plistURL)
		}

		return supportedTypes
	}

	private func repositoryRoot() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}
}

private enum PlistCoverageError: LocalizedError {
	case missingSupportedContentTypes(URL)
	case missingURLTypes(URL)

	var errorDescription: String? {
		switch self {
			case let .missingSupportedContentTypes(plistURL):
				"Could not read QLSupportedContentTypes from \(plistURL.path)"
			case let .missingURLTypes(plistURL):
				"Could not read CFBundleURLTypes from \(plistURL.path)"
		}
	}
}
