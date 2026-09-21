import Foundation
import SceneKit

extension SCNVector3 {
	func dot(_ other: SCNVector3) -> CGFloat {
		x * other.x + y * other.y + z * other.z
	}

	func cross(_ other: SCNVector3) -> SCNVector3 {
		SCNVector3(
			y * other.z - z * other.y,
			z * other.x - x * other.z,
			x * other.y - y * other.x
		)
	}

	func normalized() -> SCNVector3 {
		let length = sqrt(x * x + y * y + z * z)
		guard length > 0 else {
			return SCNVector3(0, 0, 1)
		}
		return SCNVector3(x / length, y / length, z / length)
	}
}
