import XCTest

@testable import Macup

final class SubprocessTests: XCTestCase {
    func testDeliversFinalChunkAndExitStatus() async throws {
        var chunks: [String] = []
        let lock = NSLock()
        let r = try await Subprocess.run(
            executable: "/bin/zsh", arguments: ["-c", "printf 'a\\n'; sleep 0.1; printf 'last line'; exit 3"],
            environment: nil, timeout: 10
        ) { s in
            lock.lock()
            chunks.append(s)
            lock.unlock()
        }
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stdout, "a\nlast line")
        XCTAssertEqual(chunks.joined(), "a\nlast line", "the last chunk before exit must be streamed too")
    }

    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let r = try await Subprocess.run(
            executable: "/bin/zsh",
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' x; head -c 300000 /dev/zero | tr '\\0' y >&2"],
            environment: nil, timeout: 30)
        XCTAssertEqual(r.stdout.count, 300_000)
        XCTAssertEqual(r.stderr.count, 300_000)
    }

    func testTimeoutKillsAndThrowsWithLabel() async {
        do {
            _ = try await Subprocess.run(
                executable: "/bin/zsh", arguments: ["-c", "sleep 30"], environment: nil, timeout: 0.5, label: "The test"
            )
            XCTFail("expected a timeout")
        } catch let e as SubprocessError {
            XCTAssertEqual(e.errorDescription, "The test took too long and was stopped")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testLineBufferHoldsBackAPartialLine() {
        // Scan output arrives in chunks: a report split across two reads must not be parsed twice or lost.
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.take("M\tbrew\to"), [], "an unfinished line waits for the rest")
        XCTAssertEqual(buffer.take("k\t\nM\tnpm"), ["M\tbrew\tok\t"])
        XCTAssertEqual(buffer.take("\tmissing\t\nM\tpip\tok\t\n"), ["M\tnpm\tmissing\t", "M\tpip\tok\t"])
        XCTAssertEqual(buffer.take(""), [])
    }

    func testUTF8SplitAcrossChunks() {
        var d = UTF8Chunker()
        let bytes = Array("🍺 ok".utf8)  // beer mug is 4 bytes
        XCTAssertEqual(d.decode(Data(bytes[0..<2])), "")  // incomplete: held back
        XCTAssertEqual(d.decode(Data(bytes[2...])), "🍺 ok")
        XCTAssertEqual(d.flush(), "")
    }
}
