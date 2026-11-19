import Foundation

/// Represents a launchd background service (Daemon or Agent) associated with an installed package.
public struct LaunchdService: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let plistPath: String
    public let isDaemon: Bool
    public let isLoaded: Bool
    public let pid: pid_t?

    public init(
        label: String,
        plistPath: String,
        isDaemon: Bool,
        isLoaded: Bool,
        pid: pid_t? = nil
    ) {
        self.label = label
        self.plistPath = plistPath
        self.isDaemon = isDaemon
        self.isLoaded = isLoaded
        self.pid = pid
    }

    /// Indicates whether the launchd service is actively running with an allocated PID.
    public var isRunning: Bool {
        guard let pid else { return false }
        return pid > 0
    }

    /// Determines if a file path points to a LaunchDaemon or LaunchAgent configuration plist.
    public static func isLaunchdPlistPath(_ path: String) -> Bool {
        let isPlist = path.hasSuffix(".plist")
        let isDaemon = path.contains("/LaunchDaemons/") || path.hasPrefix("Library/LaunchDaemons/")
        let isAgent = path.contains("/LaunchAgents/") || path.hasPrefix("Library/LaunchAgents/")
        return isPlist && (isDaemon || isAgent)
    }

    /// Infers the daemon type from a plist path.
    public static func isDaemonPath(_ path: String) -> Bool {
        path.contains("/LaunchDaemons/") || path.hasPrefix("Library/LaunchDaemons/")
    }
}
