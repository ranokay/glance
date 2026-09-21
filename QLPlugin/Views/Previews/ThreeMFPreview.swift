import Foundation

final class ThreeMFPreview: Preview {
	private let dimensionFormatter = NumberFormatter()
	private let triangleFormatter = NumberFormatter()

	required init() {
		dimensionFormatter.numberStyle = .decimal
		dimensionFormatter.maximumFractionDigits = 1
		triangleFormatter.numberStyle = .decimal
	}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let url = file.url
		let payload = try await PreviewExecutor.run {
			try PreviewCoreBridge.parseThreeMF(at: url)
		}
		let model = try ThreeMFSceneBuilder.build(payload)
		return ModelPreviewVC(
			scene: model.scene,
			camera: model.camera,
			labelText: label(for: model)
		)
	}

	private func label(for model: ThreeMFScene) -> String {
		let dimensions = [model.dimensions.x, model.dimensions.y, model.dimensions.z]
			.map { dimensionFormatter.string(for: $0) ?? "--" }
			.joined(separator: " × ")
		let triangles = triangleFormatter.string(for: model.triangleCount) ?? "--"
		let noun = model.triangleCount == 1 ? "triangle" : "triangles"
		return "\(dimensions) mm — \(triangles) \(noun)"
	}
}
