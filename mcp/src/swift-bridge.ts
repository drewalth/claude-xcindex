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

export interface FindSymbolRequest {
  op: "findSymbol";
  projectPath?: string;
  indexStorePath?: string;
  symbolName: string;
}

export interface FindDefinitionRequest {
  op: "findDefinition";
  projectPath?: string;
  indexStorePath?: string;
  usr: string;
}

export interface FindOverridesRequest {
  op: "findOverrides";
  projectPath?: string;
  indexStorePath?: string;
  usr: string;
}

export interface FindConformancesRequest {
  op: "findConformances";
  projectPath?: string;
  indexStorePath?: string;
  usr: string;
}

export interface BlastRadiusRequest {
  op: "blastRadius";
  projectPath?: string;
  indexStorePath?: string;
  filePath: string;
}

export interface StatusRequest {
  op: "status";
  projectPath?: string;
  indexStorePath?: string;
}

export type SwiftRequest =
  | FindRefsRequest
  | FindSymbolRequest
  | FindDefinitionRequest
  | FindOverridesRequest
  | FindConformancesRequest
  | BlastRadiusRequest
  | StatusRequest;

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
  language: string;
  definitionPath?: string;
  definitionLine?: number;
}

export interface StatusResult {
  indexStorePath: string;
  indexMtime: string | null;
  staleFileCount: number;
  staleFiles: string[];
  summary: string;
}

export interface BlastRadiusResult {
  affectedFiles: string[];
  coveringTests: string[];
  directDependents: string[];
}

export interface SwiftResponse {
  error?: string;
  occurrences?: OccurrenceResult[];
  symbols?: SymbolResult[];
  status?: StatusResult;
  blastRadius?: BlastRadiusResult;
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
  /**
   * Serialized request queue. Each request enqueues a {resolve} entry; the
   * stdin write and response wait happen strictly in FIFO order, so concurrent
   * callers never interleave their stdin payloads (which would desync the
   * line-oriented protocol on the Swift side).
   */
  private queue: Promise<void> = Promise.resolve();
  private pendingResolvers: Array<(response: SwiftResponse) => void> = [];

  /** Send a request and wait for the single-line JSON response. */
  async send(request: SwiftRequest): Promise<SwiftResponse> {
    // Chain onto the queue: every send waits for the previous one to
    // finish writing and receive its response before starting.
    const result = this.queue.then(() => this.sendOne(request));
    // Update queue to the next boundary, swallowing errors so one failure
    // doesn't poison subsequent requests.
    this.queue = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  private async sendOne(request: SwiftRequest): Promise<SwiftResponse> {
    const proc = await this.ensureProcess();
    return new Promise((resolve) => {
      this.pendingResolvers.push(resolve);
      const line = JSON.stringify(request) + "\n";
      proc.stdin!.write(line);
    });
  }

  private async ensureProcess(): Promise<ChildProcess> {
    if (this.proc && !this.proc.killed && this.proc.exitCode === null) {
      return this.proc;
    }

    // Prefer release build, fall back to debug
    const { existsSync } = await import("node:fs");
    const bin = existsSync(SWIFT_BINARY) ? SWIFT_BINARY : SWIFT_BINARY_DEBUG;

    if (!existsSync(bin)) {
      const msg = `xcindex Swift binary not found at ${bin}. Run './build.sh' from the plugin root.`;
      process.stderr.write(`[xcindex] ${msg}\n`);
      throw new Error(msg);
    }

    const proc = spawn(bin, [], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    proc.stderr?.on("data", (chunk: Buffer) => {
      process.stderr.write(`[xcindex swift] ${chunk.toString()}`);
    });

    // Handle spawn failures (binary missing, permission denied, etc.)
    // Without this, `send()` would hang forever.
    proc.on("error", (err) => {
      process.stderr.write(`[xcindex swift] spawn error: ${err.message}\n`);
      const resolvers = this.pendingResolvers.splice(0);
      for (const resolve of resolvers) {
        resolve({ error: `Swift service failed to start: ${err.message}` });
      }
      this.proc = null;
    });

    proc.on("exit", (code, signal) => {
      if (code !== 0 && code !== null) {
        process.stderr.write(`[xcindex swift] process exited with code ${code}\n`);
      }
      // Drain any pending promises so callers don't hang
      const resolvers = this.pendingResolvers.splice(0);
      for (const resolve of resolvers) {
        resolve({
          error: signal
            ? `Swift service terminated by signal ${signal}`
            : `Swift service exited unexpectedly (code ${code})`,
        });
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
    const proc = this.proc;
    this.proc = null;
    if (!proc) return;

    proc.stdin?.end();
    // If it doesn't exit promptly on its own, SIGTERM then SIGKILL.
    // The Swift binary's stdio loop exits when stdin closes, but we defend
    // against any handler that might block on IndexStoreDB cleanup.
    const term = setTimeout(() => {
      if (proc.exitCode === null && !proc.killed) proc.kill("SIGTERM");
    }, 500);
    const kill = setTimeout(() => {
      if (proc.exitCode === null && !proc.killed) proc.kill("SIGKILL");
    }, 2000);
    proc.on("exit", () => {
      clearTimeout(term);
      clearTimeout(kill);
    });
  }
}
