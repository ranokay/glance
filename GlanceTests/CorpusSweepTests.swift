import Cocoa
import GlanceKit
import XCTest

/// Corpus sweep: every renderable fixture must resolve through the production
/// factory and construct without crashing. Missing coverage and regressions
/// fail; only the encryption-gated archives may throw.
///
/// Note: qlmanage cannot load appex plugins (`-g` rejects them) and the
/// thumbnail daemon does not dispatch to unregistered extensions, so shelling
/// out to qlmanage is exploratory-only (see scripts/qlmanage-corpus.sh). This
/// test gates the same production path — factory plus preview construction —
/// deterministically on every run.
final class CorpusSweepTests: XCTestCase {
	func testPreviewCorpusResolvesAndRendersEveryFixture() async throws {
		let corpusRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("TestFiles", isDirectory: true)
		let expectedRejections: Set = [
			"encrypted-rar5.rar",
			"encrypted.7z",
			"multipart-rar5.rar",
		]
		var missing = [String]()
		var failed = [String]()
		var unexpectedlyRendered = [String]()
		var swept = 0

		let files = try allFixtureFiles(under: corpusRoot)
		XCTAssertFalse(files.isEmpty, "corpus sweep found no fixtures")
		for fileURL in files {
			swept += 1
			let name = fileURL.lastPathComponent
			guard let initializer = PreviewVCFactory.getPreviewInitializer(
				fileURL: fileURL,
				isDirectory: false
			) else {
				missing.append(name)
				continue
			}
			do {
				_ = try await initializer.init().createPreviewVC(file: File(url: fileURL))
				if expectedRejections.contains(name) {
					unexpectedlyRendered.append(name)
				}
			} catch {
				if !expectedRejections.contains(name) {
					failed.append("\(name): \(error)")
				}
			}
		}

		// The 3MF sample ships as a directory fixture; its parts are not standalone.
		let modelDir = corpusRoot.appendingPathComponent("models/simple", isDirectory: true)
		do {
			guard PreviewVCFactory
				.getPreviewInitializer(fileURL: modelDir, isDirectory: true) != nil
			else {
				missing.append("models/simple")
				throw SweepError.abort
			}
			_ = try await DirectoryPreview().createPreviewVC(file: File(url: modelDir))
		} catch SweepError.abort {
		} catch {
			failed.append("models/simple: \(error)")
		}

		XCTAssertTrue(
			missing.isEmpty,
			"fixtures with no registered preview: \(missing.sorted())"
		)
		XCTAssertTrue(
			failed.isEmpty,
			"fixtures that failed to render: \(failed.sorted())"
		)
		XCTAssertTrue(
			unexpectedlyRendered.isEmpty,
			"encryption-gated fixtures now render — drop them from the allowlist: \(unexpectedlyRendered.sorted())"
		)
		XCTAssertGreaterThan(swept, 20, "corpus sweep covered \(swept) fixtures")
	}

	private func allFixtureFiles(under root: URL) throws -> [URL] {
		let modelParts = "models/simple/"
		return try FileManager.default
			.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?
			.compactMap { $0 as? URL }
			.filter { url in
				guard !url.lastPathComponent.hasPrefix(".") else {
					return false
				}
				guard url.pathExtension != "b64" else {
					return false
				}
				guard !url.path.contains(modelParts) else {
					return false
				}
				return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
			}
			.sorted(by: { $0.path < $1.path }) ?? []
	}
}

private enum SweepError: Error {
	case abort
}
