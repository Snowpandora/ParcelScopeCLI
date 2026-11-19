import Foundation
import Darwin

/// Runs the reviewed shell in the CLI's existing foreground process group.
public enum ForegroundShell {
    public static func run(scriptPath: String) throws -> Int32 {
        guard scriptPath.hasPrefix("/"), !scriptPath.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let argumentValues: [String] = ["/bin/bash", scriptPath]
        var arguments = argumentValues.map { value in value.withCString { strdup($0) } }
        // In particular, do not inherit BASH_ENV, ENV, DYLD_* or user-controlled PATH.
        let environmentValues: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]
        var environment = environmentValues.map { value in value.withCString { strdup($0) } }
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        arguments.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        // Default spawn attributes deliberately omit POSIX_SPAWN_SETPGROUP. Foundation
        // Process starts a new group on macOS, which stops a child's second tty read.
        let launched = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/bin/bash", nil, nil, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard launched == 0 else { throw POSIXError(POSIXErrorCode(rawValue: launched) ?? .EIO) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        throw POSIXError(.ECHILD)
    }
}
