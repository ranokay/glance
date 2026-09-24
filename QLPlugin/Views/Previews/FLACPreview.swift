import AVFoundation
import Cocoa

struct FLACPreview: Preview {
	init() {}

	func createPreviewVC(file: File) async throws -> PreviewVC {
		let showsWaveform = await PreviewSettingsClient.shared.flacWaveformEnabled()
		return AVPlayerPreviewVC(fileURL: file.url, showsWaveform: showsWaveform)
	}
}

enum FLACWaveformError: Error {
	case fileTooLarge
	case durationTooLong
	case unsupportedChannels
	case unsupportedSamples
	case fileChanged
}

/// Samples short windows across the track; AVAssetReader reports unsupported decoders as errors.
enum FLACWaveformAnalyzer {
	static let binCount = 64
	static let maximumFileSize: UInt64 = 512 * 1024 * 1024
	private static let windowSeconds = 0.04
	private static let maximumWindowBytes = 1024 * 1024
	private static let maximumDurationSeconds = 24 * 60 * 60

	static func envelope(
		for fileURL: URL,
		onWindowRead: (@Sendable (Int) throws -> Void)? = nil
	) async throws -> [Float] {
		try Task.checkCancellation()
		let initialState = try fileState(at: fileURL)
		guard initialState.size <= maximumFileSize else {
			throw FLACWaveformError.fileTooLarge
		}
		let asset = AVURLAsset(url: fileURL)
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		guard let track = tracks.first else {
			throw FLACWaveformError.unsupportedSamples
		}
		let formats = try await track.load(.formatDescriptions)
		guard let format = formats.first,
		      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)
		else {
			throw FLACWaveformError.unsupportedSamples
		}
		let channelCount = Int(stream.pointee.mChannelsPerFrame)
		guard (1 ... 8).contains(channelCount) else {
			throw FLACWaveformError.unsupportedChannels
		}
		let sampleRate = stream.pointee.mSampleRate
		guard sampleRate.isFinite, (1 ... 384_000).contains(sampleRate) else {
			throw FLACWaveformError.unsupportedSamples
		}
		let seconds = try await asset.load(.duration).seconds
		guard seconds.isFinite, seconds > 0, seconds <= Double(maximumDurationSeconds) else {
			throw FLACWaveformError.durationTooLong
		}
		var peaks = [Float]()
		peaks.reserveCapacity(binCount)

		for index in 0 ..< binCount {
			try Task.checkCancellation()
			let center = seconds * (Double(index) + 0.5) / Double(binCount)
			let start = max(0, center - windowSeconds / 2)
			let length = min(windowSeconds, seconds - start)
			peaks.append(try readPeak(in: asset, track: track, start: start, length: length))
			try onWindowRead?(index)
			guard try fileState(at: fileURL) == initialState else {
				throw FLACWaveformError.fileChanged
			}
		}

		try Task.checkCancellation()
		guard try fileState(at: fileURL) == initialState else {
			throw FLACWaveformError.fileChanged
		}
		let maximum = peaks.max() ?? 0
		return maximum > 0 ? peaks.map { $0 / maximum } : peaks
	}

	private static func readPeak(
		in asset: AVURLAsset,
		track: AVAssetTrack,
		start: Double,
		length: Double
	) throws -> Float {
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = CMTimeRange(
			start: CMTime(seconds: start, preferredTimescale: 1_000_000),
			duration: CMTime(seconds: length, preferredTimescale: 1_000_000)
		)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsNonInterleaved: false,
		])
		guard reader.canAdd(output) else {
			throw FLACWaveformError.unsupportedSamples
		}
		reader.add(output)
		guard reader.startReading() else {
			throw reader.error ?? FLACWaveformError.unsupportedSamples
		}
		defer { reader.cancelReading() }
		var peak: Float = 0
		var bytesRead = 0
		while let sampleBuffer = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
				throw FLACWaveformError.unsupportedSamples
			}
			let length = CMBlockBufferGetDataLength(block)
			guard length > 0,
			      length <= maximumWindowBytes - bytesRead,
			      length.isMultiple(of: MemoryLayout<Float>.size)
			else {
				throw FLACWaveformError.unsupportedSamples
			}
			bytesRead += length
			var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
			let status = samples.withUnsafeMutableBytes { bytes in
				CMBlockBufferCopyDataBytes(
					block,
					atOffset: 0,
					dataLength: length,
					destination: bytes.baseAddress!
				)
			}
			guard status == noErr else {
				throw FLACWaveformError.unsupportedSamples
			}
			for value in samples where value.isFinite {
				peak = max(peak, abs(value))
			}
		}
		guard reader.status == .completed else {
			throw reader.error ?? FLACWaveformError.unsupportedSamples
		}
		return min(1, peak)
	}

	private static func fileState(at fileURL: URL) throws -> FileState {
		let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
		guard attributes[.type] as? FileAttributeType == .typeRegular,
		      let size = (attributes[.size] as? NSNumber)?.uint64Value
		else {
			throw FLACWaveformError.unsupportedSamples
		}
		return FileState(
			size: size,
			modified: attributes[.modificationDate] as? Date,
			fileNumber: attributes[.systemFileNumber] as? UInt64
		)
	}

	private struct FileState: Equatable {
		let size: UInt64
		let modified: Date?
		let fileNumber: UInt64?
	}
}

final class FLACWaveformView: NSView {
	var amplitudes = [Float]() {
		didSet { needsDisplay = true }
	}

	var progress: Double = 0 {
		didSet {
			progress = min(max(progress.isFinite ? progress : 0, 0), 1)
			needsDisplay = true
		}
	}

	var isLoading = true {
		didSet { needsDisplay = true }
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setAccessibilityRole(.image)
		setAccessibilityLabel("FLAC waveform playback progress")
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)
		guard bounds.width > 0, bounds.height > 0 else {
			return
		}
		guard !amplitudes.isEmpty else {
			let label = isLoading ? "Analyzing waveform…" : "Waveform unavailable"
			NSString(string: label).draw(
				in: bounds.insetBy(dx: 8, dy: 8),
				withAttributes: [
					.font: NSFont.systemFont(ofSize: 12),
					.foregroundColor: NSColor.secondaryLabelColor,
				]
			)
			return
		}
		let step = bounds.width / CGFloat(amplitudes.count)
		let barWidth = max(1, step * 0.62)
		for (index, amplitude) in amplitudes.enumerated() {
			let barProgress = Double(index) / Double(amplitudes.count)
			let color = NSColor.controlAccentColor
				.withAlphaComponent(barProgress <= progress ? 1 : 0.3)
			color.setFill()
			let height = max(2, bounds.height * CGFloat(amplitude))
			let bar = NSRect(
				x: bounds.minX + CGFloat(index) * step + (step - barWidth) / 2,
				y: bounds.midY - height / 2,
				width: barWidth,
				height: height
			)
			NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
		}
		if progress > 0, progress < 1 {
			NSColor.controlAccentColor.setFill()
			NSRect(
				x: bounds.minX + bounds.width * CGFloat(progress),
				y: bounds.minY,
				width: 2,
				height: bounds.height
			).fill()
		}
	}
}
