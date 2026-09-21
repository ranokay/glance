import Cocoa
import SceneKit

final class ModelCamera {
	private static let fieldOfView: CGFloat = 40
	private static let direction = SCNVector3(0.55, 0.45, 1)
	private static let margin: CGFloat = 1.05

	let node: SCNNode
	private let target: SCNVector3
	private let corners: [SCNVector3]
	private let radius: CGFloat

	init(target: SCNVector3, corners: [SCNVector3], radius: CGFloat) {
		self.target = target
		self.corners = corners
		self.radius = radius
		let camera = SCNCamera()
		camera.fieldOfView = Self.fieldOfView
		camera.projectionDirection = .vertical
		camera.automaticallyAdjustsZRange = true
		node = SCNNode()
		node.camera = camera
		node.position = SCNVector3(target.x, target.y, target.z + max(radius * 3, 1))
		node.look(at: target)
	}

	func frame(aspectRatio: CGFloat) {
		guard radius > 0, aspectRatio > 0 else {
			return
		}
		let direction = Self.direction.normalized()
		let forward = SCNVector3(-direction.x, -direction.y, -direction.z)
		let right = forward.cross(SCNVector3(0, 1, 0)).normalized()
		let up = right.cross(forward).normalized()
		let verticalTangent = tan(Self.fieldOfView * .pi / 360)
		let horizontalTangent = verticalTangent * aspectRatio
		var distance: CGFloat = 0
		for corner in corners {
			let offset = SCNVector3(
				corner.x - target.x,
				corner.y - target.y,
				corner.z - target.z
			)
			let depth = offset.dot(forward)
			distance = max(
				distance,
				abs(offset.dot(right)) / horizontalTangent - depth,
				abs(offset.dot(up)) / verticalTangent - depth
			)
		}
		distance *= Self.margin
		node.position = SCNVector3(
			target.x + direction.x * distance,
			target.y + direction.y * distance,
			target.z + direction.z * distance
		)
		node.look(at: target)
	}
}
