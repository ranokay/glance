import Foundation
import UniformTypeIdentifiers

struct DirectoryPageCandidate {
	let name: String
	let fileURL: URL
}

struct DirectorySnapshot {
	let candidates: [DirectoryPageCandidate]
	let modificationDate: Date?
}

struct DirectoryPageScanner: @unchecked Sendable {
	private static let sortLocale = Locale(identifier: "en_US_POSIX")
	private static let resourceKeys: Set<URLResourceKey> = [
		.contentModificationDateKey,
		.fileSizeKey,
		.isDirectoryKey,
		.isPackageKey,
		.isSymbolicLinkKey,
		.contentTypeKey,
	]

	let fileManager: FileManager
	let pageSize: Int

	func modificationDate(for directoryURL: URL) throws -> Date? {
		try directoryURL.resourceValues(forKeys: [.contentModificationDateKey])
			.contentModificationDate
	}

	func snapshot(directoryURL: URL) throws -> DirectorySnapshot {
		try Task.checkCancellation()
		var enumerationError: Error?
		guard let enumerator = fileManager.enumerator(
			at: directoryURL,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
			errorHandler: { _, error in
				enumerationError = error
				return false
			}
		) else {
			throw CocoaError(.fileReadUnknown)
		}

		var candidates = [DirectoryPageCandidate]()
		for case let itemURL as URL in enumerator {
			try Task.checkCancellation()
			candidates.append(DirectoryPageCandidate(
				name: itemURL.lastPathComponent,
				fileURL: itemURL
			))
		}
		if let enumerationError {
			throw enumerationError
		}
		candidates.sort(by: Self.isOrderedBefore)
		return DirectorySnapshot(
			candidates: candidates,
			modificationDate: try modificationDate(for: directoryURL)
		)
	}

	func page(
		from snapshot: DirectorySnapshot,
		offset: Int,
		afterName: String?
	) throws -> (page: DirectoryPage, continuationName: String?) {
		try Task.checkCancellation()
		let retainedLimit = pageSize.addingReportingOverflow(1)
		guard !retainedLimit.overflow else {
			throw CocoaError(.fileReadTooLarge)
		}
		let startIndex = afterName.map {
			Self.firstCandidate(after: $0, in: snapshot.candidates)
		} ?? snapshot.candidates.startIndex
		let endIndex = min(
			startIndex + retainedLimit.partialValue,
			snapshot.candidates.endIndex
		)
		var retainedCandidates = Array(snapshot.candidates[startIndex ..< endIndex])

		let hasMore = retainedCandidates.count > pageSize
		if hasMore {
			retainedCandidates.removeLast(retainedCandidates.count - pageSize)
		}

		var retainedEntries = [DirectoryPreviewEntry]()
		for candidate in retainedCandidates {
			try Task.checkCancellation()
			let values: URLResourceValues
			do {
				values = try candidate.fileURL.resourceValues(forKeys: Self.resourceKeys)
			} catch {
				Log.general.error(
					"Could not read item metadata \(candidate.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				continue
			}

			let isDirectory = values.isDirectory ?? false
			retainedEntries.append(DirectoryPreviewEntry(
				name: candidate.name,
				isDirectory: isDirectory,
				size: isDirectory ? 0 : values.fileSize ?? 0,
				dateModified: values.contentModificationDate,
				fileURL: candidate.fileURL,
				isPackage: values.isPackage ?? false,
				isSymbolicLink: values.isSymbolicLink ?? false,
				contentTypeIdentifier: values.contentType?.identifier
			))
		}

		let nextOffsetValue = offset.addingReportingOverflow(retainedCandidates.count)
		guard !nextOffsetValue.overflow else {
			throw CocoaError(.fileReadTooLarge)
		}
		let nextOffset = hasMore ? nextOffsetValue.partialValue : nil
		return (
			DirectoryPage(
				entries: retainedEntries,
				nextOffset: nextOffset,
				totalItemCount: snapshot.candidates.count
			),
			nextOffset == nil ? nil : retainedCandidates.last?.name
		)
	}

	private static func firstCandidate(
		after name: String,
		in candidates: [DirectoryPageCandidate]
	) -> Int {
		var lowerBound = 0
		var upperBound = candidates.count
		while lowerBound < upperBound {
			let index = lowerBound + (upperBound - lowerBound) / 2
			if isOrderedAfter(candidates[index].name, name) {
				upperBound = index
			} else {
				lowerBound = index + 1
			}
		}
		return lowerBound
	}

	private static func isOrderedBefore(
		_ lhs: DirectoryPageCandidate,
		_ rhs: DirectoryPageCandidate
	) -> Bool {
		compareNames(lhs.name, rhs.name) == .orderedAscending
	}

	private static func isOrderedAfter(_ name: String, _ cursorName: String) -> Bool {
		compareNames(name, cursorName) == .orderedDescending
	}

	private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
		let comparison = lhs.compare(
			rhs,
			options: [.caseInsensitive, .numeric],
			range: nil,
			locale: sortLocale
		)
		if comparison != .orderedSame {
			return comparison
		}
		if lhs == rhs {
			return .orderedSame
		}
		return lhs < rhs ? .orderedAscending : .orderedDescending
	}
}
