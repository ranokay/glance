import Foundation

class SQLitePreview: Preview {
	required init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let fileURL = file.url
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.parseSQLite(at: fileURL, table: nil, offset: 0)
		}
		return SQLitePreviewVC(fileURL: fileURL, payload: payload)
	}
}
