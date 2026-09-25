import GlanceKit
import XCTest

final class PlistCoverageTests: XCTestCase {
	func testQuickLookInfoPlistContainsRepresentativeSupportedContentTypes() throws {
		let supportedTypes = try quickLookSupportedContentTypes()
		let requiredTypes = [
			"public.folder",
			"dyn.ah62d4rv4ge80k6xbs7y08", // .drawio
			"dyn.ah62d4rv4ge8xg5pg", // .3mf
			"org.7-zip.7-zip-archive",
			"com.sun.java-archive",
			"com.sun.web-application-archive",
			"com.rarlab.rar-archive",
			"org.gnu.gnu-zip-archive",
			"org.gnu.gnu-zip-tar-archive",
			"public.tar-archive",
			"public.zip-archive",
			"org.idpf.epub-container",
			"org.xiph.flac",
			"org.jupyter.ipynb",
			"public.jupyter-notebook",
			"com.microsoft.ini",
			"public.mpeg-2-transport-stream", // .ts
			"dyn.ah62d4rv4ge81k5puru", // .tmpl
			"dyn.ah62d4rv4ge80y65tr30a",
			"public.markdown",
			"net.daringfireball.markdown",
			"public.tab-separated-values-text",
			"dyn.ah62d4rv4ge80n5dwqq",
			"public.source-code",
			"public.swift-source",
			"public.toml",
			"public.plain-text",
			"dyn.ah62d4rv4ge81g4psq2", // .sinf
			"dyn.ah62d4rv4ge81s3dq", // .wdl
			"dyn.ah62d4rv4ge81g7u", // .sv
			"dyn.ah62d4rv4ge81g7xk", // .svh
			"dyn.ah62d4rv4ge81g5dzsm0u", // .slurm
			"dyn.ah62d4rv4ge80c65d", // .asc
			"dyn.ah62d4rv4ge81u8k", // .xy
			"dyn.ah62d4rv4ge81u8pf", // .xye
			"dyn.ah62d4rv4ge8087py", // .out
			"dyn.ah62d4rv4ge80w5xu", // .inp
			"dyn.ah62d4rv4ge80g4pg", // .cif
			"dyn.ah62d4rv4ge81u8p4", // .xyz
			"dyn.ah62d4rv4ge80s8xrqf4a", // .gzmat
			"dyn.ah62d4rv4ge80n5x0", // .env
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

	func testUserFacingRepositoryLinksPointToMaintainedFork() throws {
		let repositoryURL = "https://github.com/ranokay/glance"
		let menuContents = try String(
			contentsOf: repositoryRoot()
				.appendingPathComponent("Glance", isDirectory: true)
				.appendingPathComponent("Utils", isDirectory: true)
				.appendingPathComponent("Menu.swift"),
			encoding: .utf8
		)

		XCTAssertTrue(menuContents.contains("\(repositoryURL)/issues"))
		XCTAssertTrue(menuContents.contains("\(repositoryURL)/blob/main/LICENSE.md"))
		XCTAssertTrue(menuContents.contains("\(repositoryURL)/blob/main/PRIVACY.md"))
		XCTAssertTrue(menuContents.contains("\(repositoryURL)\""))
		XCTAssertFalse(menuContents.contains("github.com/chamburr/glance"))
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
