/**
 * Stale-index detection utilities.
 *
 * Claude edits .swift files during a session; the Xcode index is only updated
 * on build. Because the PostToolUse hook runs as a separate bash process, it
 * can't write to in-memory state in this Node server. We use a shared state
 * file instead: the hook appends edited paths to the file, and the MCP server
 * reads the file on each query. SessionStart truncates the file.
 *
 * State-file location: $TMPDIR/xcindex-edited-<cwd-hash>.txt
 * Format: one absolute file path per line
 */

import { statSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import path from "node:path";

// ---------------------------------------------------------------------------
// State file
// ---------------------------------------------------------------------------

/**
 * Resolve the path to the session state file for the current working directory.
 * Must match the path derivation used by `hooks/post-edit.sh` and
 * `hooks/session-start.sh`.
 */
export function stateFilePath(): string {
  const cwd = process.env.CLAUDE_PROJECT_DIR ?? process.cwd();
  const hash = createHash("sha1").update(cwd).digest("hex").slice(0, 12);
  return path.join(tmpdir(), `xcindex-edited-${hash}.txt`);
}

/** Read the current set of session-edited files from the state file. */
export function getEditedFiles(): Set<string> {
  const file = stateFilePath();
  if (!existsSync(file)) return new Set();
  try {
    const contents = readFileSync(file, "utf8");
    return new Set(
      contents
        .split("\n")
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
    );
  } catch {
    return new Set();
  }
}

// ---------------------------------------------------------------------------
// Stale-note helpers
// ---------------------------------------------------------------------------

/** Append a staleness note to a result string if relevant files were edited. */
export function staleNote(involvedPaths: string[]): string | null {
  const edited = getEditedFiles();
  const stale = involvedPaths.filter((p) => edited.has(p));
  if (stale.length === 0) return null;
  const names = stale.map((f) => f.split("/").pop() ?? f).join(", ");
  return `Note: ${names} ${stale.length === 1 ? "was" : "were"} edited this session after the index was built; results may be stale.`;
}

// ---------------------------------------------------------------------------
// Index freshness check (used by xcindex_status)
// ---------------------------------------------------------------------------

export interface FreshnessInfo {
  indexMtime: Date | null;
  staleFiles: string[];
  summary: string;
}

/**
 * Compare the session-edited file list against the index mtime.
 * Returns which edited files are newer than the last index write.
 */
export function checkFreshness(storePath: string): FreshnessInfo {
  let indexMtime: Date | null = null;
  try {
    indexMtime = statSync(storePath).mtime;
  } catch {
    return {
      indexMtime: null,
      staleFiles: [],
      summary: "Index store not found — build the project in Xcode first.",
    };
  }

  const edited = getEditedFiles();
  const staleFiles: string[] = [];
  for (const f of edited) {
    try {
      if (statSync(f).mtime > indexMtime) staleFiles.push(f);
    } catch {
      /* file deleted or inaccessible */
    }
  }

  if (staleFiles.length === 0) {
    return {
      indexMtime,
      staleFiles: [],
      summary: `Index is current (last updated ${indexMtime.toLocaleString()}).`,
    };
  }

  const names = staleFiles.map((f) => f.split("/").pop() ?? f).join(", ");
  return {
    indexMtime,
    staleFiles,
    summary:
      `${staleFiles.length} source file(s) edited this session after the index was built ` +
      `(${names}). Results for symbols in those files may be stale.`,
  };
}
