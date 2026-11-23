import Foundation
import OSLog

public enum Log {
	/// Subsystems
	public static let subsystem = Bundle.main.bundleIdentifier ?? "com.chamburr.Glance"

	// Categories
	public static let general = Logger(subsystem: subsystem, category: "general")
	public static let parse = Logger(subsystem: subsystem, category: "parse")
	public static let render = Logger(subsystem: subsystem, category: "render")
}
