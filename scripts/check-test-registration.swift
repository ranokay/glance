#!/usr/bin/env swift
import Foundation

struct RegistrationError: Error, CustomStringConvertible {
	let description: String
}

func checkTestRegistration(projectURL: URL, testsURL: URL) throws {
	var isDirectory: ObjCBool = false
	guard FileManager.default.fileExists(atPath: testsURL.path, isDirectory: &isDirectory),
	      isDirectory.boolValue
	else {
		throw RegistrationError(
			description: "Test source directory does not exist: \(testsURL.path)",
		)
	}
	let data = try Data(contentsOf: projectURL)
	guard let project = try PropertyListSerialization.propertyList(
	      	from: data,
	      	format: nil,
	      ) as? [String: Any],
	      let objects = project["objects"] as? [String: [String: Any]],
	      let rootID = project["rootObject"] as? String,
	      let mainGroup = objects[rootID]?["mainGroup"] as? String,
	      let targetIDs = objects[rootID]?["targets"] as? [String]
	else {
		throw RegistrationError(description: "Invalid Xcode project: \(projectURL.path)")
	}
	let targets = targetIDs.compactMap { objects[$0] }.filter {
		($0["isa"] as? String) == "PBXNativeTarget" && ($0["name"] as? String) == "GlanceTests"
	}
	guard targets.count == 1, let target = targets.first,
	      let phaseIDs = target["buildPhases"] as? [String]
	else {
		throw RegistrationError(description: "Expected exactly one GlanceTests target")
	}
	if let synchronizedGroups = target["fileSystemSynchronizedGroups"] as? [String],
	   !synchronizedGroups.isEmpty
	{
		throw RegistrationError(
			description: "GlanceTests uses synchronized groups; update the registration check",
		)
	}
	let sourceRoot = projectURL.deletingLastPathComponent().deletingLastPathComponent()
	var resolvedFiles = [String: Set<URL>]()
	func resolve(_ objectID: String, parentURL: URL, ancestors: Set<String>) throws {
		guard !ancestors.contains(objectID), let object = objects[objectID] else {
			throw RegistrationError(description: "Invalid or cyclic project group: \(objectID)")
		}
		let baseURL: URL
		switch object["sourceTree"] as? String ?? "<group>" {
			case "<group>":
				baseURL = parentURL
			case "SOURCE_ROOT":
				baseURL = sourceRoot
			case "<absolute>":
				baseURL = URL(fileURLWithPath: "/", isDirectory: true)
			default:
				return
		}
		let url = (object["path"] as? String).map {
			NSString(string: $0).isAbsolutePath ? URL(fileURLWithPath: $0) : baseURL
				.appendingPathComponent($0)
		} ?? baseURL
		if let children = object["children"] as? [String] {
			for child in children {
				try resolve(child, parentURL: url, ancestors: ancestors.union([objectID]))
			}
		} else if (object["isa"] as? String) == "PBXFileReference" {
			resolvedFiles[objectID, default: []]
				.insert(url.resolvingSymlinksInPath().standardizedFileURL)
		}
	}
	try resolve(mainGroup, parentURL: sourceRoot, ancestors: [])
	var registered = Set<URL>()
	for phaseID in phaseIDs {
		guard let phase = objects[phaseID] else {
			throw RegistrationError(description: "Missing build phase: \(phaseID)")
		}
		guard (phase["isa"] as? String) == "PBXSourcesBuildPhase" else { continue }
		for buildID in phase["files"] as? [String] ?? [] {
			guard let buildFile = objects[buildID], let fileID = buildFile["fileRef"] as? String,
			      let paths = resolvedFiles[fileID], paths.count == 1
			else {
				throw RegistrationError(
					description: "Cannot resolve GlanceTests source: \(buildID)",
				)
			}
			if let platforms = buildFile["platformFilters"] as? [String],
			   !platforms.contains("macos")
			{
				continue
			}
			if let platform = buildFile["platformFilter"] as? String, platform != "macos" {
				continue
			}
			registered.formUnion(paths)
		}
	}
	guard let files = FileManager.default.enumerator(
		at: testsURL,
		includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
		options: .skipsHiddenFiles,
	) else {
		throw RegistrationError(description: "Cannot enumerate test sources: \(testsURL.path)")
	}
	var sources = [URL]()
	for case let url as URL in files {
		if url.standardizedFileURL == testsURL.appendingPathComponent("TestFiles")
			.standardizedFileURL
		{
			files.skipDescendants()
			continue
		}
		if url.pathExtension == "swift",
		   try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
		{
			sources.append(url.resolvingSymlinksInPath().standardizedFileURL)
		}
	}
	let missing = sources.filter { !registered.contains($0) }.map(\.path).sorted()
	guard missing.isEmpty else {
		throw RegistrationError(description: "Swift test sources missing from GlanceTests Sources:\n" +
			missing.joined(separator: "\n"))
	}
	print("Test registration passed: \(sources.count) Swift sources in GlanceTests")
}

do {
	let arguments = CommandLine.arguments
	guard arguments.count == 1 || arguments.count == 3 else {
		throw RegistrationError(
			description: "Usage: check-test-registration.swift [project.pbxproj test-directory]",
		)
	}
	let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		.deletingLastPathComponent()
	let projectURL = arguments.count == 3 ? URL(fileURLWithPath: arguments[1])
		: root.appendingPathComponent("Glance.xcodeproj/project.pbxproj")
	let testsURL = arguments.count == 3 ? URL(fileURLWithPath: arguments[2], isDirectory: true)
		: root.appendingPathComponent("GlanceTests", isDirectory: true)
	try checkTestRegistration(projectURL: projectURL, testsURL: testsURL)
} catch {
	FileHandle.standardError.write(Data("\(error)\n".utf8))
	exit(1)
}
