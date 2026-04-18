/**
 * Stale-index detection utilities.
 *
 * Claude edits .swift files during a session; the Xcode index is only updated
 * on build. This module tracks which source files were edited since the index
 * was last built so MCP tool responses can annotate results with staleness
 * warnings.
 */
/** Mark a file as edited this session. */
export declare function markEdited(filePath: string): void;
/** Return the set of files edited this session. */
export declare function getEditedFiles(): ReadonlySet<string>;
export interface FreshnessInfo {
    /** mtime of the most-recently-written unit file in the store. */
    indexMtime: Date | null;
    /** Source files whose mtime is newer than the index. */
    staleFiles: string[];
    /** Human-readable summary for session-start context injection. */
    summary: string;
}
/**
 * Check whether the index at `storePath` is fresh relative to a list of
 * source files. Pass the project's source root — we'll glob for .swift files.
 */
export declare function checkFreshness(storePath: string, sourceRoot?: string): Promise<FreshnessInfo>;
/** Append a staleness note to a result string if relevant files were edited. */
export declare function staleNote(involvedPaths: string[]): string | null;
