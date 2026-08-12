import Foundation

/// Runs preview preparation outside the main actor and discards results after cancellation.
///
/// Cancellation does not interrupt a synchronous operation. The caller waits for it to finish,
/// then its result is discarded; bounded parser limits keep that wait finite.
enum PreviewExecutor {
	static func run<Output: Sendable>(
		_ operation: @escaping @Sendable () throws -> Output
	) async throws -> Output {
		let task = Task.detached(priority: .userInitiated) {
			try Task.checkCancellation()
			let output = try operation()
			try Task.checkCancellation()
			return output
		}
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}
}
