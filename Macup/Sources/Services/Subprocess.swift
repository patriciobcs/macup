import Foundation

struct SubprocessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum SubprocessError: LocalizedError {
    case timeout(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let what): "\(what) timed out"
        case .launchFailed(let why): "Could not start process: \(why)"
        }
    }
}

/// Thin async wrapper around Process with streaming output and a timeout.
enum Subprocess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                return
            }
            collector.append(d, toStdout: true)
            if let onOutput, let s = String(data: d, encoding: .utf8) { onOutput(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                return
            }
            collector.append(d, toStdout: false)
            if let onOutput, let s = String(data: d, encoding: .utf8) { onOutput(s) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let finished = FinishedFlag()
            process.terminationHandler = { p in
                guard finished.claim() else { return }
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                if finished.claim() { cont.resume(throwing: SubprocessError.launchFailed(error.localizedDescription)) }
                return
            }
            let name = ([executable] + arguments).joined(separator: " ")
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, finished.claim() else { return }
                process.terminate()
                cont.resume(throwing: SubprocessError.timeout(name))
            }
        }

        // Drain anything left in the pipes after termination.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
        collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: false)
        return SubprocessResult(
            status: status, stdout: collector.text(stdout: true), stderr: collector.text(stdout: false))
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func append(_ d: Data, toStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if toStdout { out.append(d) } else { err.append(d) }
    }
    func text(stdout: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdout ? out : err, encoding: .utf8) ?? ""
    }
}

private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
