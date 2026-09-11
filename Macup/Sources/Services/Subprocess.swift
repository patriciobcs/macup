import Foundation

struct SubprocessResult {
    var status: Int32
    var stdout: String
    var stderr: String
    /// Both streams in arrival order, as shown in the log.
    var combined: String
}

enum SubprocessError: LocalizedError {
    case timeout(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let what): "\(what) took too long and was stopped"
        case .launchFailed(let why): "Could not start process: \(why)"
        }
    }
}

/// Thin async wrapper around Process: streams output in order as it arrives, decodes UTF-8 across
/// chunk boundaries, finishes only when the process has exited *and* both pipes reached end of file
/// (bounded by a short grace period, so a stray grandchild holding the pipe cannot hang the caller),
/// and kills the process on timeout.
enum Subprocess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        label: String? = nil,
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

        let state = RunState(onOutput: onOutput)
        outPipe.fileHandleForReading.readabilityHandler = { h in state.read(h.availableData, .stdout, handle: h) }
        errPipe.fileHandleForReading.readabilityHandler = { h in state.read(h.availableData, .stderr, handle: h) }

        let name = label ?? executable
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            state.finish = { outcome in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                switch outcome {
                case .exited(let code): cont.resume(returning: code)
                case .timedOut: cont.resume(throwing: SubprocessError.timeout(name))
                case .launchFailed(let why): cont.resume(throwing: SubprocessError.launchFailed(why))
                }
            }
            process.terminationHandler = { p in state.exited(p.terminationStatus) }
            do {
                try process.run()
            } catch {
                state.complete(.launchFailed(error.localizedDescription))
                return
            }
            let killer = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
                state.complete(.timedOut)
            }
            state.timeoutItem = killer
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        }
        return state.result(status: status)
    }

    fileprivate enum Stream { case stdout, stderr }

    fileprivate enum Outcome {
        case exited(Int32)
        case timedOut
        case launchFailed(String)
    }

    /// All mutable state behind one lock; decides when the run is really over.
    fileprivate final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data(), combined = ""
        private var outDecoder = UTF8Chunker(), errDecoder = UTF8Chunker()
        private var outEOF = false, errEOF = false
        private var exitStatus: Int32?
        private var finished = false
        private let onOutput: (@Sendable (String) -> Void)?
        var finish: ((Outcome) -> Void)?
        var timeoutItem: DispatchWorkItem?
        /// After exit, how long to wait for the pipes to close before giving up on them.
        private let drainGrace: TimeInterval = 2

        init(onOutput: (@Sendable (String) -> Void)?) { self.onOutput = onOutput }

        func read(_ data: Data, _ stream: Stream, handle: FileHandle) {
            var text: String?
            lock.lock()
            if data.isEmpty {
                if stream == .stdout { outEOF = true } else { errEOF = true }
                handle.readabilityHandler = nil
                text = stream == .stdout ? outDecoder.flush() : errDecoder.flush()
            } else {
                if stream == .stdout {
                    out.append(data)
                    text = outDecoder.decode(data)
                } else {
                    err.append(data)
                    text = errDecoder.decode(data)
                }
            }
            if let text, !text.isEmpty { combined.append(text) }
            let done = exitStatus != nil && outEOF && errEOF
            let status = exitStatus
            lock.unlock()
            if let text, !text.isEmpty { onOutput?(text) }
            if done, let status { complete(.exited(status)) }
        }

        func exited(_ status: Int32) {
            lock.lock()
            exitStatus = status
            let done = outEOF && errEOF
            lock.unlock()
            if done {
                complete(.exited(status))
            } else {
                // Pipes still open: a grandchild may hold them. Wait briefly, then stop waiting.
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) { [weak self] in
                    self?.complete(.exited(status))
                }
            }
        }

        func complete(_ outcome: Outcome) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            timeoutItem?.cancel()
            let handler = finish
            lock.unlock()
            handler?(outcome)
        }

        func result(status: Int32) -> SubprocessResult {
            lock.lock()
            defer { lock.unlock() }
            return SubprocessResult(status: status, stdout: lossyUTF8(out), stderr: lossyUTF8(err), combined: combined)
        }
    }
}

/// Decodes UTF-8 arriving in arbitrary chunks, holding back an incomplete trailing sequence.
struct UTF8Chunker {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        // A multi-byte sequence can be cut at most 3 bytes before its end.
        for cut in 0...min(3, pending.count) {
            let head = pending.prefix(pending.count - cut)
            if let s = String(data: head, encoding: .utf8) {
                pending = Data(pending.suffix(cut))
                return s
            }
        }
        // Not valid UTF-8 at all: emit lossily and move on.
        let s = lossyUTF8(pending)
        pending.removeAll()
        return s
    }

    mutating func flush() -> String {
        defer { pending.removeAll() }
        return lossyUTF8(pending)
    }
}

// Command output is shown to a person, so invalid bytes become replacement characters rather than
// dropping the whole chunk.
// swiftlint:disable:next optional_data_string_conversion
private func lossyUTF8(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
