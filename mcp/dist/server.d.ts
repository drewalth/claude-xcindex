/**
 * claude-xcindex MCP server
 *
 * Exposes Xcode's pre-built symbol index (IndexStoreDB) as MCP tools so
 * Claude can do surgical, semantic symbol lookups instead of shotgun grep.
 *
 * Tool surface (step 3: one tool; step 4 adds the rest):
 *   xcindex_find_references  — all occurrence sites for a symbol by name
 */
export {};
