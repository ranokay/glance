import Foundation
import GlancePreviewCore

struct TSVPreviewPayload: Decodable {
	let headers: [String]
	let rows: [[String: String]]
}

struct ArchivePreviewPayload: Decodable {
	let entries: [ArchivePreviewEntry]
	let compressedSize: UInt64
	let uncompressedSize: UInt64
	let scannedUncompressedSize: UInt64?
	let truncated: Bool

	private enum CodingKeys: String, CodingKey {
		case entries
		case compressedSize = "compressed_size"
		case uncompressedSize = "uncompressed_size"
		case scannedUncompressedSize = "scanned_uncompressed_size"
		case truncated
	}
}

struct ArchivePreviewEntry: Decodable {
	let path: String
	let entryType: ArchivePreviewEntryType
	let size: UInt64
	let modifiedUnixSeconds: Double?

	private enum CodingKeys: String, CodingKey {
		case path
		case entryType = "entry_type"
		case size
		case modifiedUnixSeconds = "modified_unix_seconds"
	}
}

enum ArchivePreviewEntryType: String, Decodable {
	case file
	case directory
	case other
}

struct ThreeMFPreviewPayload: Decodable {
	let meshes: [ThreeMFMeshPayload]
	let instances: [ThreeMFInstancePayload]
	let unitMillimeters: Float
	let boundsMin: [Float]
	let boundsMax: [Float]
	let triangleCount: Int

	private enum CodingKeys: String, CodingKey {
		case meshes, instances
		case unitMillimeters = "unit_millimeters"
		case boundsMin = "bounds_min"
		case boundsMax = "bounds_max"
		case triangleCount = "triangle_count"
	}
}

struct ThreeMFMeshPayload: Decodable {
	let vertices: [[Float]]
	let triangles: [[UInt32]]
	let color: [Float]
}

struct ThreeMFInstancePayload: Decodable {
	let meshIndex: Int
	let transform: [Float]

	private enum CodingKeys: String, CodingKey {
		case meshIndex = "mesh_index"
		case transform
	}
}

enum PreviewCoreBridgeError: LocalizedError {
	case invalidBuffer
	case invalidUTF8
	case invalidPayload(String)
	case coreFailure(status: Int32, message: String)
	case invalidFileSystemPath

	var errorDescription: String? {
		switch self {
			case .invalidBuffer:
				"PreviewCore returned an invalid buffer"
			case .invalidUTF8:
				"PreviewCore returned invalid UTF-8"
			case let .invalidPayload(message):
				"PreviewCore returned an invalid payload: \(message)"
			case let .coreFailure(_, message):
				message.isEmpty ? "PreviewCore failed without details" : message
			case .invalidFileSystemPath:
				"The file path cannot be represented by the filesystem"
		}
	}
}

enum PreviewCoreBridge {
	static func renderEPUB(at url: URL) throws -> String {
		let data = try consume(pathResult(for: url, call: glance_render_epub))
		guard let html = String(data: data, encoding: .utf8) else {
			throw PreviewCoreBridgeError.invalidUTF8
		}
		return html
	}

	static func parseTSV(_ data: Data) throws -> TSVPreviewPayload {
		let result = data.withUnsafeBytes { buffer in
			glance_parse_tsv(
				buffer.bindMemory(to: UInt8.self).baseAddress,
				buffer.count
			)
		}
		return try decode(TSVPreviewPayload.self, result: result)
	}

	static func parseThreeMF(at url: URL) throws -> ThreeMFPreviewPayload {
		try decode(
			ThreeMFPreviewPayload.self,
			result: pathResult(for: url, call: glance_parse_three_mf)
		)
	}

	static func scanZIP(at url: URL) throws -> ArchivePreviewPayload {
		try decode(ArchivePreviewPayload.self, result: pathResult(for: url, call: glance_scan_zip))
	}

	static func scanTAR(at url: URL, isGzipped: Bool) throws -> ArchivePreviewPayload {
		let result = try url.withUnsafeFileSystemRepresentation { path in
			guard let path else {
				throw PreviewCoreBridgeError.invalidFileSystemPath
			}
			return glance_scan_tar(
				UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self),
				Int(strlen(path)),
				isGzipped
			)
		}
		return try decode(ArchivePreviewPayload.self, result: result)
	}

	static func scanSevenZip(at url: URL) throws -> ArchivePreviewPayload {
		try decode(
			ArchivePreviewPayload.self,
			result: pathResult(for: url, call: glance_scan_seven_zip)
		)
	}

	static func scanRAR(at url: URL) throws -> ArchivePreviewPayload {
		try decode(
			ArchivePreviewPayload.self,
			result: pathResult(for: url, call: glance_scan_rar)
		)
	}

	private static func pathResult(
		for url: URL,
		call: (UnsafePointer<UInt8>?, Int) -> GlanceRenderResult
	) throws -> GlanceRenderResult {
		try url.withUnsafeFileSystemRepresentation { path in
			guard let path else {
				throw PreviewCoreBridgeError.invalidFileSystemPath
			}
			return call(
				UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self),
				Int(strlen(path))
			)
		}
	}

	private static func decode<Payload: Decodable>(
		_ type: Payload.Type,
		result: GlanceRenderResult
	) throws -> Payload {
		let data = try consume(result)
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw PreviewCoreBridgeError.invalidPayload(String(describing: error))
		}
	}

	private static func consume(_ result: GlanceRenderResult) throws -> Data {
		defer { glance_render_buffer_free(result.data, result.length) }
		guard result.length == 0 || result.data != nil else {
			throw PreviewCoreBridgeError.invalidBuffer
		}
		let data = result.data.map { Data(bytes: $0, count: result.length) } ?? Data()
		guard result.status == GLANCE_STATUS_OK else {
			guard let message = String(data: data, encoding: .utf8) else {
				throw PreviewCoreBridgeError.invalidUTF8
			}
			throw PreviewCoreBridgeError.coreFailure(status: result.status, message: message)
		}
		return data
	}
}
