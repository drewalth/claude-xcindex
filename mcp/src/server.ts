/**
 * claude-xcindex MCP server
 *
 * Exposes Xcode's pre-built symbol index (IndexStoreDB) as MCP tools so
 * Claude can do surgical, semantic symbol lookups instead of shotgun grep.
 *
 * Tool surface (step 3: one tool; step 4 adds the rest):
 *   xcindex_find_references  — all occurrence sites for a symbol by name
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { SwiftBridge } from "./swift-bridge.js";
import { staleNote } from "./freshness.js";

// ---------------------------------------------------------------------------
// Server setup
// ---------------------------------------------------------------------------

const server = new McpServer({
  name: "claude-xcindex",
  version: "0.1.0",
});

const bridge = new SwiftBridge();

// ---------------------------------------------------------------------------
// Tool: xcindex_find_references
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_find_references",
  "Find every occurrence of a Swift/ObjC symbol in Xcode's pre-built semantic index. " +
  "Returns exact file+line+column+role for each reference — no false positives from " +
  "comments, strings, or same-named symbols in other modules. " +
  "Call xcindex_find_symbol first if you need to disambiguate overloads. " +
  "Requires the project to have been built in Xcode at least once.",
  {
    symbolName: z.string().describe(
      "Exact name of the symbol to look up (e.g. 'UserService', 'fetchUser', 'AuthProtocol'). " +
      "Case-sensitive. Use the declaration name, not a qualified path."
    ),
    projectPath: z.string().optional().describe(
      "Absolute path to the .xcodeproj or .xcworkspace file. " +
      "Used to locate DerivedData automatically. " +
      "Omit if you supply indexStorePath directly."
    ),
    indexStorePath: z.string().optional().describe(
      "Absolute path to the IndexStore DataStore directory " +
      "(e.g. ~/Library/Developer/Xcode/DerivedData/MyApp-abc123/Index.noindex/DataStore). " +
      "Overrides projectPath. Use xcindex_status to find this path."
    ),
    maxResults: z.number().int().min(1).max(500).optional().default(100).describe(
      "Cap on the number of occurrences returned (default 100, max 500). " +
      "For very common symbols, increase only if you need the full picture."
    ),
  },
  async ({ symbolName, projectPath, indexStorePath, maxResults }) => {
    const response = await bridge.send({
      op: "findRefs",
      symbolName,
      projectPath,
      indexStorePath,
    });

    if (response.error) {
      return {
        content: [{ type: "text", text: `Error: ${response.error}` }],
        isError: true,
      };
    }

    const occurrences = response.occurrences ?? [];
    const capped = occurrences.slice(0, maxResults ?? 100);
    const truncated = occurrences.length > capped.length;

    // Build a compact, readable table
    const lines: string[] = [];
    if (capped.length === 0) {
      lines.push(`No references found for '${symbolName}'.`);
      lines.push("Check that the project has been built in Xcode and the symbol name is exact.");
    } else {
      lines.push(`Found ${occurrences.length} reference(s) for '${symbolName}'${truncated ? ` (showing first ${capped.length})` : ""}:\n`);
      for (const occ of capped) {
        lines.push(`  ${occ.path}:${occ.line}:${occ.column}  [${occ.roles.join(", ")}]`);
      }

      // Staleness annotation
      const involvedPaths = [...new Set(capped.map((o) => o.path))];
      const note = staleNote(involvedPaths);
      if (note) {
        lines.push(`\n⚠️  ${note}`);
      }

      if (truncated) {
        lines.push(`\nResults truncated. Increase maxResults to see all ${occurrences.length} occurrences.`);
      }
    }

    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);

process.on("SIGINT", () => {
  bridge.dispose();
  process.exit(0);
});

process.on("SIGTERM", () => {
  bridge.dispose();
  process.exit(0);
});
