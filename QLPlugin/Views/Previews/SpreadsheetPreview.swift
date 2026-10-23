import Foundation

class SpreadsheetPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.parseXLSX(at: fileURL)
		}
		return SpreadsheetPreviewVC(sheets: payload.sheets)
	}
}
