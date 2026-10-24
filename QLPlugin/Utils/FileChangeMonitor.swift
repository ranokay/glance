import Darwin
import Foundation

/// Watches one file for external edits and reports a debounced refresh signal.
///
/// Editors that save atomically write a temporary file and rename it over the original, so a
/// watcher on the original file descriptor stops reporting after the first such save. This
/// monitor also watches the parent directory and re-arms the file descriptor against whatever
/// inode currently sits at the path.
@MainActor
final class FileChangeMonitor {
	/// Bursts of filesystem events from one save collapse into a single callback.
	static let debounceInterval: Duration = .milliseconds(250)

	private(set) var isWatching = false
	let fileURL: URL
	private let onChange: @MainActor () -> Void
	private var fileWatcher: FileSystemWatcher?
	private var directoryWatcher: FileSystemWatcher?
	private var watchedInode: UInt64?
	private var debounceTask: Task<Void, Never>?

	init(fileURL: URL, onChange: @escaping @MainActor () -> Void) {
		self.fileURL = fileURL
		self.onChange = onChange
	}

	/// Starts watching the file. Returns `false` when the file itself cannot be opened;
	/// the parent-directory watcher is best-effort because the sandbox may deny it.
	func start() -> Bool {
		guard !isWatching else {
			return true
		}
		guard startFileWatcher() else {
			return false
		}
		isWatching = true
		directoryWatcher = FileSystemWatcher(
			path: fileURL.deletingLastPathComponent().path,
			eventMask: [.write, .delete, .rename],
		) { [weak self] in
			self?.directoryDidChange()
		}
		return true
	}

	func stop() {
		guard isWatching else {
			return
		}
		isWatching = false
		debounceTask?.cancel()
		debounceTask = nil
		fileWatcher = nil
		directoryWatcher = nil
		watchedInode = nil
	}

	private func startFileWatcher() -> Bool {
		guard let inode = Self.inode(of: fileURL) else {
			return false
		}
		let watcher = FileSystemWatcher(
			path: fileURL.path,
			eventMask: [.write, .extend, .delete, .rename, .attrib],
		) { [weak self] in
			self?.fileDidChange()
		}
		guard let watcher else {
			return false
		}
		fileWatcher = watcher
		watchedInode = inode
		return true
	}

	private func fileDidChange() {
		guard isWatching else {
			return
		}
		scheduleChange()
	}

	private func directoryDidChange() {
		guard isWatching, Self.inode(of: fileURL) != watchedInode else {
			return
		}
		scheduleChange()
	}

	private func scheduleChange() {
		guard isWatching else {
			return
		}
		debounceTask?.cancel()
		debounceTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.debounceInterval)
			guard !Task.isCancelled, let self, isWatching else {
				return
			}
			debounceTask = nil
			rearmFileWatcherIfNeeded()
			onChange()
		}
	}

	/// Atomic saves replace the inode, so the next event must be watched from the new file.
	private func rearmFileWatcherIfNeeded() {
		guard let inode = Self.inode(of: fileURL) else {
			// The file is gone. Drop the stale descriptor so unrelated directory
			// traffic cannot schedule another failing refresh; a recreated file
			// counts as a new inode and is picked up again.
			fileWatcher = nil
			watchedInode = nil
			return
		}
		guard inode != watchedInode else {
			return
		}
		fileWatcher = nil
		_ = startFileWatcher()
	}

	private static func inode(of url: URL) -> UInt64? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
		      let number = attributes[.systemFileNumber] as? NSNumber
		else {
			return nil
		}
		return number.uint64Value
	}
}

/// Owns one kqueue-backed descriptor and closes it when the watcher is cancelled or released.
private final class FileSystemWatcher {
	private var source: DispatchSourceFileSystemObject?

	init?(
		path: String,
		eventMask: DispatchSource.FileSystemEvent,
		onEvent: @escaping @MainActor () -> Void,
	) {
		let descriptor = open(path, O_EVTONLY)
		guard descriptor >= 0 else {
			return nil
		}
		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: eventMask,
			queue: .main,
		)
		source.setEventHandler {
			MainActor.assumeIsolated { onEvent() }
		}
		source.setCancelHandler {
			close(descriptor)
		}
		source.resume()
		self.source = source
	}

	deinit {
		source?.cancel()
	}
}
