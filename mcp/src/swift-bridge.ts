/**
 * Spawns the xcindex Swift binary and communicates with it over stdio
 * using a simple newline-delimited JSON-RPC protocol.
 *
 * One persistent process is kept alive per MCP server instance (the binary
 * caches the IndexStoreDB handle internally). If the process dies it is
 * restarted on the next call.
 */

import { spawn, ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";

// ---------------------------------------------------------------------------
// Wire types (must match Models.swift in the Swift service)
// ---------------------------------------------------------------------------

export interface FindRefsRequest {
  op: "findRefs";
  projectPath?: string;
  indexStorePath?: string;
  symbolName: string;
}

// More ops will be added in step 4
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

// ---------------------------------------------------------------------------
// SwiftBridge
// ---------------------------------------------------------------------------

const PLUGIN_DIR = path.dirname(
  path.dirname(fileURLToPath(import.meta.url)) // mcp/dist → mcp
);
const SWIFT_BINARY = path.join(
  PLUGIN_DIR,
  "swift-service/.build/release/xcindex"
);
const SWIFT_BINARY_DEBUG = path.join(
  PLUGIN_DIR,
  "swift-service/.build/debug/xcindex"
);

export class SwiftBridge {
  private proc: ChildProcess | null = null;
  private pendingResolvers: Array<(response: SwiftResponse) => void> = [];
  private lineBuffer = "";

  /** Send a request and wait for the single-line JSON response. */
  async send(request: SwiftRequest): Promise<SwiftResponse> {
    const proc = await this.ensureProcess();

    return new Promise((resolve) => {
      this.pendingResolvers.push(resolve);
      const line = JSON.stringify(request) + "\n";
      proc.stdin!.write(line);
    });
  }

  private async ensureProcess(): Promise<ChildProcess> {
    if (this.proc && !this.proc.killed) {
      return this.proc;
    }

    // Prefer release build, fall back to debug
    const { existsSync } = await import("node:fs");
    const bin = existsSync(SWIFT_BINARY) ? SWIFT_BINARY : SWIFT_BINARY_DEBUG;

    const proc = spawn(bin, [], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    proc.stderr?.on("data", (chunk: Buffer) => {
      process.stderr.write(`[xcindex swift] ${chunk.toString()}`);
    });

    proc.on("exit", (code) => {
      if (code !== 0) {
        process.stderr.write(`[xcindex swift] process exited with code ${code}\n`);
      }
      // Reject any pending promises so callers don't hang
      const resolvers = this.pendingResolvers.splice(0);
      for (const resolve of resolvers) {
        resolve({ error: `Swift service exited unexpectedly (code ${code})` });
      }
      this.proc = null;
    });

    // Read stdout line by line
    const rl = createInterface({ input: proc.stdout! });
    rl.on("line", (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) return;

      let response: SwiftResponse;
      try {
        response = JSON.parse(trimmed) as SwiftResponse;
      } catch {
        response = { error: `Failed to parse Swift response: ${trimmed}` };
      }

      const resolve = this.pendingResolvers.shift();
      if (resolve) {
        resolve(response);
      } else {
        process.stderr.write(`[xcindex swift] unexpected response: ${trimmed}\n`);
      }
    });

    this.proc = proc;
    return proc;
  }

  /** Gracefully terminate the Swift subprocess. */
  dispose(): void {
    this.proc?.stdin?.end();
    this.proc = null;
  }
}
