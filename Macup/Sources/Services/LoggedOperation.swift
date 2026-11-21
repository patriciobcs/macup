import Foundation

@MainActor
enum LoggedOperation {
    static func run(
        _ body: (@escaping @Sendable (String) -> Void) async throws -> SubprocessResult,
        onOutput: @escaping (String) -> Void
    ) async -> Result<SubprocessResult, Error> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task {
            for await chunk in stream { onOutput(chunk) }
        }
        let outcome: Result<SubprocessResult, Error>
        do { outcome = .success(try await body { continuation.yield($0) }) } catch { outcome = .failure(error) }
        continuation.finish()
        await consumer.value
        return outcome
    }
}
