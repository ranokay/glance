import Foundation

final class EPUBPreview: Preview {
	private let mainStylesheetURL = WebPreviewVC.resourceBundle.url(
		forResource: "epub-main",
		withExtension: "css"
	)

	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let html = try await PreviewExecutor.run {
			try PreviewCoreBridge.renderEPUB(at: fileURL)
		}
		let stylesheets = mainStylesheetURL.map { [Stylesheet(url: $0)] } ?? []
		return WebPreviewVC(html: html, stylesheets: stylesheets)
	}
}
