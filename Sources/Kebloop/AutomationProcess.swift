import Foundation
import Darwin

struct AutomationOutput: Equatable {
    let stdout: String
    let stderr: String
}

enum AutomationFailure: LocalizedError, Equatable {
    case cancelled, timeout, outputLimit, missingExecutable, failed(Int32), invalid(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Execution cancelled."
        case .timeout: return "Execution exceeded its time limit. Increase the limit after reviewing the command."
        case .outputLimit: return "Execution exceeded the output limit. Reduce the command's output."
        case .missingExecutable: return "Executable or runtime is missing or not executable. Select a valid local executable."
        case .failed(let code): return "Execution exited with status \(code). Review the script or extension locally."
        case .invalid(let message): return message
        }
    }
}

// Dedicated process groups bound ordinary descendants too. This is not a sandbox: trusted code
// can deliberately detach itself. The minimal environment excludes inherited credentials.
final class AutomationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activePID: pid_t?
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let activePID { kill(-activePID, SIGKILL) }
    }
    func execute(executable: String, arguments: [String], input: Data? = nil, timeout: Double = 10, outputLimit: Int = 262_144) throws -> AutomationOutput {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw AutomationFailure.missingExecutable }
        guard timeout.isFinite, timeout > 0, timeout <= 300, outputLimit > 0, outputLimit <= 1_048_576 else { throw AutomationFailure.invalid("Invalid execution limits.") }
        let stdout = Pipe(), stderr = Pipe()
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("kebloop-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let inputData = input ?? Data()
        guard inputData.count <= 262_144 else { throw AutomationFailure.invalid("Input exceeds 256 KB. Reduce the query or preferences.") }
        guard FileManager.default.createFile(atPath: inputURL.path, contents: inputData, attributes: [.posixPermissions: 0o600]) else { throw AutomationFailure.invalid("Could not prepare private execution input.") }
        let stdin = try FileHandle(forReadingFrom: inputURL)
        defer { try? stdin.close(); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close() }
        for pipe in [stdout, stderr] { _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw AutomationFailure.invalid("Could not initialize subprocess isolation.") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdout.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, stderr.fileHandleForReading.fileDescriptor)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv = ([executable] + arguments).map { $0.withCString { strdup($0) } } + [nil]
        var environment = (["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"] as [String]).map { $0.withCString { strdup($0) } } + [nil]
        defer { for value in argv { free(value) }; for value in environment { free(value) } }
        var pid: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); throw AutomationFailure.cancelled }
        let launchError = posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment)
        if launchError != 0 { lock.unlock(); throw POSIXError(POSIXErrorCode(rawValue: launchError) ?? .EIO) }
        activePID = pid; lock.unlock()
        var reaped = false, status: Int32 = 0
        defer {
            // Stop remaining children even when the initial command exited successfully.
            lock.lock(); kill(-pid, SIGKILL); activePID = nil; lock.unlock()
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        var output = Data(), errors = Data(), total = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func drain(_ handle: FileHandle, into data: inout Data) throws {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                guard total + count <= outputLimit else { throw AutomationFailure.outputLimit }
                total += count; data.append(contentsOf: buffer.prefix(count))
            }
        }
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw AutomationFailure.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw AutomationFailure.timeout }
            try drain(stdout.fileHandleForReading, into: &output); try drain(stderr.fileHandleForReading, into: &errors)
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try drain(stdout.fileHandleForReading, into: &output); try drain(stderr.fileHandleForReading, into: &errors)
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw AutomationFailure.cancelled }
        let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        guard exitCode == 0 else { throw AutomationFailure.failed(exitCode) }
        return AutomationOutput(stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errors, as: UTF8.self))
    }
}
