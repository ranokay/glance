import Cocoa
import SceneKit

enum ThreeMFSceneError: LocalizedError {
	case invalidPayload

	var errorDescription: String? {
		"PreviewCore returned invalid 3MF scene data"
	}
}

struct ThreeMFScene {
	let scene: SCNScene
	let camera: ModelCamera
	let dimensions: SCNVector3
	let triangleCount: Int
}

@MainActor
enum ThreeMFSceneBuilder {
	static func build(_ payload: ThreeMFPreviewPayload) throws -> ThreeMFScene {
		guard payload.boundsMin.count == 3, payload.boundsMax.count == 3 else {
			throw ThreeMFSceneError.invalidPayload
		}
		let geometries = try payload.meshes.map(makeGeometry)
		let contentNode = SCNNode()
		for instance in payload.instances {
			guard geometries.indices.contains(instance.meshIndex),
			      instance.transform.count == 16
			else {
				throw ThreeMFSceneError.invalidPayload
			}
			let node = SCNNode(geometry: geometries[instance.meshIndex])
			node.transform = matrix(instance.transform)
			contentNode.addChildNode(node)
		}
		guard !contentNode.childNodes.isEmpty else { throw ThreeMFSceneError.invalidPayload }

		let rootNode = SCNNode()
		rootNode.transform = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)
		rootNode.addChildNode(contentNode)
		let scene = SCNScene()
		scene.rootNode.addChildNode(rootNode)

		let minimum = vector(payload.boundsMin)
		let maximum = vector(payload.boundsMax)
		let size = SCNVector3(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
		let center = SCNVector3(
			(minimum.x + maximum.x) / 2,
			(minimum.y + maximum.y) / 2,
			(minimum.z + maximum.z) / 2
		)
		let corners = [minimum.x, maximum.x].flatMap { x in
			[minimum.y, maximum.y].flatMap { y in
				[minimum.z, maximum.z].map { depth in SCNVector3(x, depth, -y) }
			}
		}
		let radius = sqrt(size.x * size.x + size.y * size.y + size.z * size.z) / 2
		let camera = ModelCamera(
			target: SCNVector3(center.x, center.z, -center.y),
			corners: corners,
			radius: radius
		)
		scene.rootNode.addChildNode(camera.node)

		let light = SCNLight()
		light.type = .ambient
		light.color = NSColor(calibratedWhite: 0.45, alpha: 1)
		let lightNode = SCNNode()
		lightNode.light = light
		scene.rootNode.addChildNode(lightNode)

		return ThreeMFScene(
			scene: scene,
			camera: camera,
			dimensions: SCNVector3(
				size.x * CGFloat(payload.unitMillimeters),
				size.y * CGFloat(payload.unitMillimeters),
				size.z * CGFloat(payload.unitMillimeters)
			),
			triangleCount: payload.triangleCount
		)
	}

	private static func makeGeometry(_ mesh: ThreeMFMeshPayload) throws -> SCNGeometry {
		guard mesh.color.count == 4 else { throw ThreeMFSceneError.invalidPayload }
		var positions = [Float]()
		var normals = [Float]()
		positions.reserveCapacity(mesh.triangles.count * 9)
		normals.reserveCapacity(mesh.triangles.count * 9)
		for triangle in mesh.triangles {
			guard triangle.count == 3 else { throw ThreeMFSceneError.invalidPayload }
			let indices = triangle.map(Int.init)
			guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else {
				throw ThreeMFSceneError.invalidPayload
			}
			let vertices = try indices.map { index -> SCNVector3 in
				let values = mesh.vertices[index]
				guard values.count == 3 else { throw ThreeMFSceneError.invalidPayload }
				return vector(values)
			}
			let firstEdge = SCNVector3(
				vertices[1].x - vertices[0].x,
				vertices[1].y - vertices[0].y,
				vertices[1].z - vertices[0].z
			)
			let secondEdge = SCNVector3(
				vertices[2].x - vertices[0].x,
				vertices[2].y - vertices[0].y,
				vertices[2].z - vertices[0].z
			)
			let normal = firstEdge.cross(secondEdge).normalized()
			for vertex in vertices {
				positions.append(contentsOf: [Float(vertex.x), Float(vertex.y), Float(vertex.z)])
				normals.append(contentsOf: [Float(normal.x), Float(normal.y), Float(normal.z)])
			}
		}
		guard !positions.isEmpty else { throw ThreeMFSceneError.invalidPayload }
		let vertexCount = positions.count / 3
		let geometry = SCNGeometry(
			sources: [
				source(positions, count: vertexCount, semantic: .vertex),
				source(normals, count: vertexCount, semantic: .normal),
			],
			elements: [
				SCNGeometryElement(
					indices: [Int32](0 ..< Int32(vertexCount)),
					primitiveType: .triangles
				),
			]
		)
		let material = SCNMaterial()
		material.lightingModel = .physicallyBased
		material.diffuse.contents = NSColor(
			calibratedRed: CGFloat(mesh.color[0]),
			green: CGFloat(mesh.color[1]),
			blue: CGFloat(mesh.color[2]),
			alpha: CGFloat(mesh.color[3])
		)
		material.metalness.contents = 0.0
		material.roughness.contents = 0.55
		material.isDoubleSided = true
		geometry.materials = [material]
		return geometry
	}

	private static func source(
		_ components: [Float],
		count: Int,
		semantic: SCNGeometrySource.Semantic
	) -> SCNGeometrySource {
		let data = components.withUnsafeBufferPointer { Data(buffer: $0) }
		return SCNGeometrySource(
			data: data,
			semantic: semantic,
			vectorCount: count,
			usesFloatComponents: true,
			componentsPerVector: 3,
			bytesPerComponent: MemoryLayout<Float>.size,
			dataOffset: 0,
			dataStride: MemoryLayout<Float>.size * 3
		)
	}

	private static func vector(_ values: [Float]) -> SCNVector3 {
		SCNVector3(CGFloat(values[0]), CGFloat(values[1]), CGFloat(values[2]))
	}

	private static func matrix(_ values: [Float]) -> SCNMatrix4 {
		SCNMatrix4(
			m11: CGFloat(values[0]),
			m12: CGFloat(values[1]),
			m13: CGFloat(values[2]),
			m14: CGFloat(values[3]),
			m21: CGFloat(values[4]),
			m22: CGFloat(values[5]),
			m23: CGFloat(values[6]),
			m24: CGFloat(values[7]),
			m31: CGFloat(values[8]),
			m32: CGFloat(values[9]),
			m33: CGFloat(values[10]),
			m34: CGFloat(values[11]),
			m41: CGFloat(values[12]),
			m42: CGFloat(values[13]),
			m43: CGFloat(values[14]),
			m44: CGFloat(values[15])
		)
	}
}
