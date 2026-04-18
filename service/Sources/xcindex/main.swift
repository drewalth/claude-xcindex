import Foundation
import MCP

let server = XcindexServer.makeServer()
let processor = RequestProcessor()
await XcindexServer.register(on: server, processor: processor)

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
