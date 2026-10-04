import Foundation

/// Keeps the menu bar app and the command line from changing packages at the same time: an advisory
/// lock on a file beside the saved state. Everything in one process shares a single hold on it, so the
/// app updating two managers at once does not lock itself out.
@MainActor
final class UpdateLock {
    private let url: URL
    private var descriptor: Int32 = -1
    private var holders = 0

    init(url: URL) { self.url = url }

    /// Takes the lock without waiting. False only when another process holds it. A lock file that
    /// cannot be opened at all never stands in the way of an update.
    func tryAcquire() -> Bool {
        if holders > 0 {
            holders += 1
            return true
        }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        holders = 1
        return true
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
