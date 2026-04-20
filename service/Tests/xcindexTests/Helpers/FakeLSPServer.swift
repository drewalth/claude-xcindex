import Foundation

/// Writes a scripted fake sourcekit-lsp to a temp path so `LSPClient`
/// tests can drive timeout, protocol-error, and termination branches
/// without depending on a real Swift toolchain. The script is a
/// minimal Python program that parses LSP Content-Length framing and
/// emits responses per the chosen mode — enough to satisfy
/// `LSPClient.launch` + `references` without modeling the whole LSP.
///
/// Each test owns its own `FakeLSPServer` instance; the temp file is
/// deleted on deinit so parallel tests don't collide.
final class FakeLSPServer {
    enum Mode: String {
        /// Respond to initialize, then hang on every other request.
        case initializeOnly = "initialize_only"
        /// Never respond to initialize — exercises .initializeTimeout.
        case initializeTimeout = "initialize_timeout"
        /// Respond to initialize; return ResponseError for references.
        case referencesProtocolError = "references_protocol_error"
        /// Respond to initialize; hang on references (.referencesTimeout).
        case referencesTimeout = "references_timeout"
        /// Respond to initialize; exit the process when references lands.
        case exitAfterInit = "exit_after_init"
    }

    let binaryURL: URL
    private let tempDir: URL

    init(mode: Mode) throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "xcindex-fake-lsp-\(UUID().uuidString)"
        )
        let dir = URL(fileURLWithPath: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir

        let script = Self.pythonScript(mode: mode)
        let scriptURL = dir.appendingPathComponent("fake-sourcekit-lsp")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )
        self.binaryURL = scriptURL
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func pythonScript(mode: Mode) -> String {
        """
        #!/usr/bin/env python3
        import json, sys, time

        MODE = \(String(reflecting: mode.rawValue))

        def read_message():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                line_str = line.decode('utf-8', errors='replace').rstrip('\\r\\n')
                if line_str == '':
                    break
                if ':' in line_str:
                    k, v = line_str.split(':', 1)
                    headers[k.strip().lower()] = v.strip()
            n = int(headers.get('content-length', '0'))
            if n <= 0:
                return None
            body = sys.stdin.buffer.read(n)
            try:
                return json.loads(body)
            except Exception:
                return None

        def send(obj):
            body = json.dumps(obj).encode('utf-8')
            sys.stdout.buffer.write(f'Content-Length: {len(body)}\\r\\n\\r\\n'.encode('ascii'))
            sys.stdout.buffer.write(body)
            sys.stdout.buffer.flush()

        while True:
            msg = read_message()
            if msg is None:
                break
            method = msg.get('method')
            mid = msg.get('id')
            if method == 'initialize':
                if MODE == 'initialize_timeout':
                    time.sleep(60)
                    continue
                send({'jsonrpc': '2.0', 'id': mid,
                      'result': {'capabilities': {}}})
            elif method == 'initialized':
                pass
            elif method == 'textDocument/didOpen':
                pass
            elif method == 'textDocument/references':
                if MODE == 'references_protocol_error':
                    send({'jsonrpc': '2.0', 'id': mid,
                          'error': {'code': -32603, 'message': 'fake protocol error'}})
                elif MODE == 'references_timeout':
                    time.sleep(60)
                elif MODE == 'exit_after_init':
                    sys.exit(0)
                else:
                    send({'jsonrpc': '2.0', 'id': mid, 'result': []})
            elif method == 'shutdown':
                send({'jsonrpc': '2.0', 'id': mid, 'result': None})
            elif method == 'exit':
                break
            else:
                if mid is not None:
                    send({'jsonrpc': '2.0', 'id': mid,
                          'error': {'code': -32601, 'message': f'method not found: {method}'}})
        """
    }
}
