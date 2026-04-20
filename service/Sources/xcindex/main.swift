import Foundation
import MCP

let server = XcindexServer.makeServer()
let processor = RequestProcessor()
await XcindexServer.register(on: server, processor: processor)

// Signal handlers must ignore the default action first so DispatchSource
// can observe the signal instead of the kernel killing us mid-shutdown.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let signalQueue = DispatchQueue(label: "xcindex.signals")
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

let onSignal: @Sendable () -> Void = {
    Task {
        await processor.shutdownAll()
        exit(0)
    }
}
sigintSource.setEventHandler(handler: onSignal)
sigtermSource.setEventHandler(handler: onSignal)
sigintSource.resume()
sigtermSource.resume()

// Last-resort cleanup: if we exit through a path that skips the
// signal handlers (uncaught fatal, library atexit), SIGTERM any
// sourcekit-lsp still tracked. SIGKILL on us bypasses this, but
// orphaned children would also show up in `ps aux`.
atexit {
    xcindexTerminateTrackedChildren()
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()

// Normal EOF (Claude Code closed stdin): drain the LSP cache before
// returning so children exit cleanly rather than via atexit SIGTERM.
await processor.shutdownAll()
