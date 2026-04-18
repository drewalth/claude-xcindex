/**
 * Spawns the xcindex Swift binary and communicates with it over stdio
 * using a simple newline-delimited JSON-RPC protocol.
 *
 * One persistent process is kept alive per MCP server instance (the binary
 * caches the IndexStoreDB handle internally). If the process dies it is
 * restarted on the next call.
 */
export interface FindRefsRequest {
    op: "findRefs";
    projectPath?: string;
    indexStorePath?: string;
    symbolName: string;
}
export type SwiftRequest = FindRefsRequest;
export interface OccurrenceResult {
    usr: string;
    symbolName: string;
    path: string;
    line: number;
    column: number;
    roles: string[];
}
export interface SymbolResult {
    usr: string;
    name: string;
    kind: string;
}
export interface SwiftResponse {
    error?: string;
    occurrences?: OccurrenceResult[];
    symbols?: SymbolResult[];
}
export declare class SwiftBridge {
    private proc;
    private pendingResolvers;
    private lineBuffer;
    /** Send a request and wait for the single-line JSON response. */
    send(request: SwiftRequest): Promise<SwiftResponse>;
    private ensureProcess;
    /** Gracefully terminate the Swift subprocess. */
    dispose(): void;
}
