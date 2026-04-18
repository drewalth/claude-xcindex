import Foundation

// MARK: - JSON-RPC stdio loop
//
// Reads newline-delimited JSON requests from stdin, dispatches to handlers,
// writes newline-delimited JSON responses to stdout.
//
// Request shape:
//   { "op": "findRefs", "projectPath": "/path/to/My.xcodeproj", "symbolName": "MyClass" }
//   { "op": "findRefs", "indexStorePath": "/path/to/DataStore", "symbolName": "MyClass" }
//
// Response shape:
//   { "occurrences": [...] }      on success
//   { "error": "message" }        on failure

let processor = RequestProcessor()

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }

    guard let inputData = trimmed.data(using: .utf8) else {
        writeResponse(Response(error: "Invalid UTF-8 input"))
        continue
    }

    do {
        let request = try JSONDecoder().decode(Request.self, from: inputData)
        let response = processor.handle(request)
        writeResponse(response)
    } catch {
        writeResponse(Response(error: "Parse error: \(error.localizedDescription)"))
    }
}

func writeResponse(_ response: Response) {
    do {
        let data = try JSONEncoder().encode(response)
        if let s = String(data: data, encoding: .utf8) {
            print(s)
            fflush(stdout)
        }
    } catch {
        print("{\"error\":\"Failed to encode response: \(error)\"}")
        fflush(stdout)
    }
}
