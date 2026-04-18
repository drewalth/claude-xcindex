/**
 * Stale-index detection utilities.
 *
 * Claude edits .swift files during a session; the Xcode index is only updated
 * on build. This module tracks which source files were edited since the index
 * was last built so MCP tool responses can annotate results with staleness
 * warnings.
 */
import { stat } from "node:fs/promises";
// ---------------------------------------------------------------------------
// Session-scoped edit tracker
// ---------------------------------------------------------------------------
/** Set of absolute paths of .swift files edited this session. */
const editedFiles = new Set();
/** Mark a file as edited this session. */
export function markEdited(filePath) {
    if (filePath.endsWith(".swift") || filePath.endsWith(".m") || filePath.endsWith(".mm")) {
        editedFiles.add(filePath);
    }
}
/** Return the set of files edited this session. */
export function getEditedFiles() {
    return editedFiles;
}
/**
 * Check whether the index at `storePath` is fresh relative to a list of
 * source files. Pass the project's source root — we'll glob for .swift files.
 */
export async function checkFreshness(storePath, sourceRoot) {
    // Get the mtime of the DataStore directory itself as a proxy for last index
    // write. A more precise check would walk the unit files, but directory mtime
    // is fast and good enough for a warning.
    let indexMtime = null;
    try {
        const s = await stat(storePath);
        indexMtime = s.mtime;
    }
    catch {
        return {
            indexMtime: null,
            staleFiles: [],
            summary: "Index store not found — build the project in Xcode first.",
        };
    }
    // Check session-edited files against index mtime
    const staleFiles = [];
    for (const f of editedFiles) {
        try {
            const s = await stat(f);
            if (s.mtime > indexMtime) {
                staleFiles.push(f);
            }
        }
        catch {
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
        summary: `${staleFiles.length} source file(s) edited this session after the index was built ` +
            `(${names}). Results for symbols in those files may be stale.`,
    };
}
/** Append a staleness note to a result string if relevant files were edited. */
export function staleNote(involvedPaths) {
    const edited = [...editedFiles];
    const stale = involvedPaths.filter((p) => edited.includes(p));
    if (stale.length === 0)
        return null;
    const names = stale.map((f) => f.split("/").pop() ?? f).join(", ");
    return `Note: ${names} ${stale.length === 1 ? "was" : "were"} edited this session after the index was built; results may be stale.`;
}
//# sourceMappingURL=freshness.js.map