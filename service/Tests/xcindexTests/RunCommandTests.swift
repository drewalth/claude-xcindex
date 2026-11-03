import Foundation
import os
import Testing
@testable import xcindex

@Suite("runCommand")
struct RunCommandTests {
    /// Waiting for exit before draining the pipe deadlocks once the child
    /// fills the ~64 KB pipe buffer: the child blocks on write, the parent on
    /// exit. Same for an undrained stderr pipe.
    ///
    /// A deadlock never finishes, so the bound only has to outlast a loaded
    /// CI runner. A dedicated thread keeps the child off GCD's width-limited
    /// pool, which parallel fixture builds can saturate.
    @Test(arguments: ["", ">&2"])
    func largeOutputDoesNotDeadlock(redirect: String) {
        let size = 256 * 1024
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        Thread {
            let output = runCommand("/bin/sh", args: ["-c", "head -c \(size) /dev/zero | tr '\\0' x \(redirect)"])
            result.withLock { $0 = output }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + 60) == .success else {
            Issue.record("runCommand hung on \(size) bytes (redirect \(redirect))")
            return
        }
        let output = result.withLock { $0 }
        if redirect.isEmpty {
            #expect(output?.count == size)
        } else {
            #expect(output == "")
        }
    }
}
