import Foundation

class TSVPreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let payload = try await PreviewExecutor.run {
			let data = try Data(contentsOf: fileURL)
			return try PreviewCoreBridge.parseTSV(data)
		}
		return TablePreviewVC(headers: payload.headers, cells: payload.rows)
	}
}
