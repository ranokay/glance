import Cocoa
import SceneKit

final class ModelPreviewVC: NSViewController, PreviewVC {
	private let scene: SCNScene
	private let camera: ModelCamera
	private let labelText: String
	private var hasFramedCamera = false

	init(scene: SCNScene, camera: ModelCamera, labelText: String) {
		self.scene = scene
		self.camera = camera
		self.labelText = labelText
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = PreviewBackgroundView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		let sceneView = SCNView()
		sceneView.scene = scene
		sceneView.pointOfView = camera.node
		sceneView.allowsCameraControl = true
		sceneView.autoenablesDefaultLighting = true
		sceneView.antialiasingMode = .multisampling4X
		sceneView.backgroundColor = .clear
		sceneView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(sceneView)

		let label = NSTextField(labelWithString: labelText)
		label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		label.textColor = .secondaryLabelColor
		label.lineBreakMode = .byTruncatingTail
		label.toolTip = labelText
		label.setAccessibilityLabel(labelText)
		label.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(label)

		NSLayoutConstraint.activate([
			sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			sceneView.topAnchor.constraint(equalTo: view.topAnchor),
			sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
			label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
			label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
		])
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		guard !hasFramedCamera, view.bounds.width > 0, view.bounds.height > 0 else {
			return
		}
		camera.frame(aspectRatio: view.bounds.width / view.bounds.height)
		hasFramedCamera = true
	}
}
