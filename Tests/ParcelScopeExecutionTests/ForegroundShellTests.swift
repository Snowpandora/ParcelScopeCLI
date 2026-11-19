import Foundation
import XCTest

final class ForegroundShellTests: XCTestCase {
    func testProductionPrimitiveKeepsBothPromptsInForegroundAndPreservesExitStatus() throws {
        let root = URL(fileURLWithPath: "/private/tmp/parcelscope-pty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let harnessSource = root.appendingPathComponent("main.swift")
        let harness = root.appendingPathComponent("foreground-harness")
        try #"""
        import Foundation
        import Darwin
        if CommandLine.arguments[1] == "--probe" {
            let shell = pid_t(CommandLine.arguments[2])!
            print("PROMPT2 pid=\(shell) pgid=\(getpgid(shell)) tgp=\(tcgetpgrp(STDIN_FILENO))")
            exit(0)
        }
        print("PROMPT1 pid=\(getpid()) pgid=\(getpgrp()) tgp=\(tcgetpgrp(STDIN_FILENO))")
        fflush(nil)
        guard readLine() == "REVIEWED" else { print("CANCELLED-FIRST"); exit(9) }
        do {
            let result = try ForegroundShell.run(scriptPath: CommandLine.arguments[1])
            print("POSTFLIGHT status=\(result) pgid=\(getpgrp()) tgp=\(tcgetpgrp(STDIN_FILENO))")
            exit(result)
        } catch { print("SPAWN-FAILED \(error)"); exit(71) }
        """#.write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = Process(), compilerOutput = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-swift-version", "6", repository.appendingPathComponent("Sources/ParcelScopeExecution/ForegroundShell.swift").path, harnessSource.path, "-o", harness.path]
        compile.standardOutput = compilerOutput; compile.standardError = compilerOutput
        try compile.run()
        let compilerData = compilerOutput.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, String(decoding: compilerData, as: UTF8.self))
        guard compile.terminationStatus == 0 else { return }
        let shell = root.appendingPathComponent("reviewed.sh")
        let audit = root.appendingPathComponent("audit")
        let body = """
        #!/bin/bash
        set -eu
        [[ -z ${BASH_ENV-} && -z ${ENV-} && -z ${PARCELSCOPE_UNTRUSTED-} ]] || exit 88
        [[ $PATH == /usr/bin:/bin:/usr/sbin:/sbin ]] || exit 89
        '\(harness.path)' --probe "$$"
        printf '%s\\n' WAIT-REMOVE
        IFS= read -r response
        [[ $response == REMOVE ]] || exit 10
        printf '%s\\n' payload-removed >> '\(audit.path)'
        case "${PARCELSCOPE_SCENARIO:-success}" in
          partial) exit 7 ;;
          signaled) kill -TERM "$$" ;;
        esac
        printf '%s\\n' receipt-forgotten >> '\(audit.path)'
        exit 0
        """
        // Test scenario is embedded in the trusted script; production removes inherited environment.
        let driver = root.appendingPathComponent("driver.py")
        try Self.driver.write(to: driver, atomically: true, encoding: .utf8)
        for (scenario, expectedStatus, expectedAudit) in [
            ("success", 0, "payload-removed\nreceipt-forgotten\n"),
            ("cancel-first", 9, ""), ("cancel-second", 10, ""),
            ("partial", 7, "payload-removed\n"), ("signaled", 143, "payload-removed\n")
        ] {
            try? FileManager.default.removeItem(at: audit)
            try body.replacingOccurrences(of: "${PARCELSCOPE_SCENARIO:-success}", with: scenario).write(to: shell, atomically: true, encoding: .utf8)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [driver.path, harness.path, shell.path, scenario]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let log = String(decoding: data, as: UTF8.self)
            print("Foreground PTY " + scenario + ": " + log)
            XCTAssertEqual(process.terminationStatus, 0, scenario + ": " + log)
            guard process.terminationStatus == 0 else { continue }
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["status"] as? Int, expectedStatus, log)
            XCTAssertEqual(object["foreground"] as? Bool, true, log)
            if scenario != "cancel-first" { XCTAssertTrue((object["output"] as? String)?.contains("POSTFLIGHT status=\(expectedStatus)") == true, log) }
            let actual = FileManager.default.fileExists(atPath: audit.path) ? try String(contentsOf: audit, encoding: .utf8) : ""
            XCTAssertEqual(actual, expectedAudit, scenario)
        }
    }

    private static let driver = #"""
    import errno, fcntl, json, os, pty, re, select, signal, sys, termios, time
    harness, script, scenario = sys.argv[1:]
    master, slave = pty.openpty()
    child = os.fork()
    if child == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2): os.dup2(slave, fd)
        if slave > 2: os.close(slave)
        os.environ['BASH_ENV'] = '/nonexistent/parcelscope-unsafe-env'
        os.environ['ENV'] = '/nonexistent/parcelscope-unsafe-env'
        os.environ['PARCELSCOPE_UNTRUSTED'] = 'must-not-reach-reviewed-shell'
        os.execv(harness, [harness, script])
    os.close(slave)
    data = b''
    first = second = False
    completed = False
    shell_pid = None
    deadline = time.monotonic() + 8
    status = None
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try: chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO: raise
                chunk = b''
            if chunk: data += chunk
        text = data.decode(errors='replace')
        match = re.search(r'PROMPT2 pid=(\d+) pgid=(\d+) tgp=(\d+)', text)
        if match: shell_pid = int(match.group(1))
        if 'PROMPT1 ' in text and not first:
            os.write(master, b'CANCEL\n' if scenario == 'cancel-first' else b'REVIEWED\n')
            first = True
        if 'WAIT-REMOVE' in text and not second:
            os.write(master, b'CANCEL\n' if scenario == 'cancel-second' else b'REMOVE\n')
            second = True
        result, value = os.waitpid(child, os.WNOHANG)
        if result:
            completed = True
            status = os.waitstatus_to_exitcode(value)
            break
    if not completed:
        if shell_pid:
            try: os.kill(shell_pid, signal.SIGKILL)
            except ProcessLookupError: pass
        try: os.killpg(child, signal.SIGKILL)
        except ProcessLookupError: pass
        os.waitpid(child, 0)
    os.close(master)
    text = data.decode(errors='replace')
    observations = re.findall(r'(?:PROMPT[12]|POSTFLIGHT status=\d+) (?:pid=\d+ )?pgid=(\d+) tgp=(\d+)', text)
    foreground = bool(observations) and all(a == b and int(a) > 0 for a,b in observations)
    print(json.dumps({'status': status, 'foreground': foreground, 'output': text, 'completed': completed}))
    sys.exit(0 if completed and foreground else 70)
    """#
}
