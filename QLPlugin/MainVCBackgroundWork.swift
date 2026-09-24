import Cocoa

enum PreviewError: Error {
	case fileSizeError(path: String)
}

extension PreviewError: LocalizedError {
	var errorDescription: String? {
		switch self {
			case let .fileSizeError(path):
				NSLocalizedString("File \(path) is too large to preview", comment: "")
		}
	}
}

extension MainVC {
	func startPreviewPreparation(
		at fileURL: URL,
		completionHandler handler: @escaping @Sendable (Error?) -> Void
	) {
		previewPreparationTask?.cancel()
		let preparationID = UUID()
		previewPreparationID = preparationID
		let task = Task { @MainActor [weak self] in
			guard let self else {
				throw CancellationError()
			}
			try await preparePreview(at: fileURL)
		}
		previewPreparationTask = task
		Task { @MainActor [weak self] in
			do {
				try await task.value
				handler(nil)
			} catch is CancellationError {
				// Superseded requests still complete exactly once without asking Quick Look
				// to replace the newer preview with its fallback UI.
				handler(nil)
			} catch {
				handler(error)
			}
			if self?.previewPreparationID == preparationID {
				self?.previewPreparationTask = nil
				self?.previewPreparationID = nil
			}
		}
	}

	func preparePreview(at fileURL: URL) async throws {
		guard containingAppIsRunning() else {
			Log.general.info("Glance app is not running, declining preview")
			throw NSError(
				domain: "com.chamburr.Glance.QLPlugin",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Glance app is not running"]
			)
		}

		let file: File
		do {
			file = try File(url: fileURL)
		} catch {
			Log.general.error(
				"Could not obtain information about file \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
		do {
			try PreviewPolicy.validateFileSize(file)
		} catch {
			Log.general
				.error("Skipping file preview: \(error.localizedDescription, privacy: .private)")
			throw error
		}

		Log.general.info("Generating preview for file \(file.path, privacy: .private)")
		do {
			try await previewFile(file: file)
		} catch {
			Log.general.error(
				"Could not generate preview for file \(file.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}

	/// Generates a preview of the selected file and adds the corresponding child view controller.
	func previewFile(file: File) async throws {
		// Initialize `PreviewVC` for the file type
		if let previewInitializerType = PreviewVCFactory.getPreviewInitializer(
			fileURL: file.url,
			isDirectory: file.isDirectory
		) {
			// Generate file preview
			let previewInitializer = previewInitializerType.init()
			let previewVC = try await previewInitializer.createPreviewVC(file: file)
			try Task.checkCancellation()

			installTopLevelPreview(previewVC, file: file)

			// Update stats
			stats.increaseStatsCounts(fileExtension: file.url.pathExtension)
		} else {
			Log.general.info(
				"Skipping preview for file \(file.path, privacy: .private): File type not supported"
			)
			throw NSError(
				domain: "com.chamburr.Glance.QLPlugin",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "File type is not supported"]
			)
		}
	}

	func showTransientError(_ message: String) {
		statusResetTask?.cancel()
		setDisplayedStatus(message)
		statusResetTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else {
				return
			}
			guard let self else {
				return
			}
			setDisplayedStatus(baseStatusText)
		}
	}

	func openWithApplication(at applicationURL: URL) {
		guard let fileURL = openWithTargetURL else {
			return
		}
		openWithService.open(fileURL: fileURL, with: applicationURL) { [weak self] error in
			guard let error else {
				return
			}
			let nsError = error as NSError
			Log.general.error(
				"Could not open \(fileURL.path, privacy: .private) with \(applicationURL.path, privacy: .private): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription, privacy: .private)"
			)
			self?
				.showTransientError(
					"Couldn’t open with \(applicationURL.deletingPathExtension().lastPathComponent)"
				)
		}
	}

	func showNestedPreview(for node: FileTreeNode, from source: OutlinePreviewVC) {
		guard currentPreviewController === source else {
			return
		}
		nestedPreviewTask?.cancel()
		nestedPreviewTask = Task { @MainActor [weak self] in
			do {
				guard let self else {
					return
				}
				let previewVC = try await nestedPreviewProvider.makePreviewController(for: node)
				try Task.checkCancellation()
				guard currentPreviewController === source else {
					return
				}
				pushPreview(previewVC, openWithTargetURL: node.fileURL)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not generate nested preview for \(node.name, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				self?.showTransientError("Couldn’t preview \(node.name)")
			}
		}
	}

	func showDirectoryPreview(for node: FileTreeNode, from source: OutlinePreviewVC) {
		guard currentPreviewController === source else {
			return
		}
		nestedPreviewTask?.cancel()
		nestedPreviewTask = Task { @MainActor [weak self] in
			do {
				guard let self else {
					return
				}
				let previewVC = try await source.makeDirectoryPreview(for: node)
				try Task.checkCancellation()
				guard currentPreviewController === source else {
					return
				}
				pushPreview(previewVC, openWithTargetURL: nil)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not open folder \(node.name, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				self?.showTransientError("Couldn’t open \(node.name)")
			}
		}
	}
}
