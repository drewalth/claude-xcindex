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
// Shared parameter schemas
// ---------------------------------------------------------------------------

const projectParams = {
  projectPath: z.string().optional().describe(
    "Absolute path to the .xcodeproj or .xcworkspace file. " +
    "Used to locate DerivedData automatically. " +
    "Omit if you supply indexStorePath directly."
  ),
  indexStorePath: z.string().optional().describe(
    "Absolute path to the IndexStore DataStore directory. " +
    "Overrides projectPath. Use xcindex_status to find this path."
  ),
};

const usrParam = z.string().describe(
  "Unified Symbol Resolution identifier obtained from xcindex_find_symbol or " +
  "xcindex_find_references (the 'usr' field on any result)."
);

// ---------------------------------------------------------------------------
// Tool: xcindex_find_symbol
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_find_symbol",
  "Look up a symbol by name and return its kind, language, USR, and definition location. " +
  "Use this BEFORE xcindex_find_references or xcindex_find_definition to disambiguate " +
  "overloaded names (e.g. multiple types named 'Delegate' in different modules). " +
  "Returns one result per distinct symbol that exactly matches the name.",
  {
    symbolName: z.string().describe(
      "Exact symbol name to look up (case-sensitive). " +
      "E.g. 'URLSession', 'fetchUser', 'AuthDelegate'."
    ),
    ...projectParams,
  },
  async ({ symbolName, projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "findSymbol", symbolName, projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const symbols = response.symbols ?? [];
    if (symbols.length === 0) {
      return {
        content: [{ type: "text", text: `No symbols found for '${symbolName}'. Check the exact spelling and that the project has been built.` }],
      };
    }
    const lines = [`Found ${symbols.length} symbol(s) named '${symbolName}':\n`];
    for (const s of symbols) {
      lines.push(`  USR:  ${s.usr}`);
      lines.push(`  Kind: ${s.kind}  Language: ${s.language}`);
      if (s.definitionPath) lines.push(`  Defined at: ${s.definitionPath}:${s.definitionLine}`);
      lines.push("");
    }
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

// ---------------------------------------------------------------------------
// Tool: xcindex_find_definition
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_find_definition",
  "Return the canonical definition site (file + line) for a symbol identified by USR. " +
  "Use after xcindex_find_symbol to jump to the declaration. " +
  "More precise than text search because it uses the semantic USR, not the symbol name.",
  {
    usr: usrParam,
    ...projectParams,
  },
  async ({ usr, projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "findDefinition", usr, projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const occurrences = response.occurrences ?? [];
    if (occurrences.length === 0) {
      return { content: [{ type: "text", text: `No definition found for USR '${usr}'.` }] };
    }
    const occ = occurrences[0];
    const note = staleNote([occ.path]);
    const text = `${occ.symbolName} defined at:\n  ${occ.path}:${occ.line}:${occ.column}` +
      (note ? `\n\n⚠️  ${note}` : "");
    return { content: [{ type: "text", text }] };
  }
);

// ---------------------------------------------------------------------------
// Tool: xcindex_find_overrides
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_find_overrides",
  "Find all classes or structs that override a given method or property. " +
  "Essential before changing a method signature in a base class. " +
  "Pass the USR from xcindex_find_symbol for the base method.",
  {
    usr: usrParam,
    ...projectParams,
  },
  async ({ usr, projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "findOverrides", usr, projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const occurrences = response.occurrences ?? [];
    if (occurrences.length === 0) {
      return { content: [{ type: "text", text: `No overrides found for USR '${usr}'.` }] };
    }
    const lines = [`Found ${occurrences.length} override(s):\n`];
    for (const occ of occurrences) {
      lines.push(`  ${occ.path}:${occ.line}  (${occ.symbolName})`);
    }
    const note = staleNote([...new Set(occurrences.map(o => o.path))]);
    if (note) lines.push(`\n⚠️  ${note}`);
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

// ---------------------------------------------------------------------------
// Tool: xcindex_find_conformances
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_find_conformances",
  "Find all types that conform to a Swift protocol. " +
  "Pass the protocol's USR from xcindex_find_symbol. " +
  "More reliable than searching for ': ProtocolName' in source — handles type aliases and " +
  "retroactive conformances declared in other files.",
  {
    usr: usrParam,
    ...projectParams,
  },
  async ({ usr, projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "findConformances", usr, projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const occurrences = response.occurrences ?? [];
    if (occurrences.length === 0) {
      return { content: [{ type: "text", text: `No conformances found for USR '${usr}'.` }] };
    }
    const lines = [`Found ${occurrences.length} conformance(s):\n`];
    for (const occ of occurrences) {
      lines.push(`  ${occ.symbolName}  at ${occ.path}:${occ.line}`);
    }
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

// ---------------------------------------------------------------------------
// Tool: xcindex_blast_radius
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_blast_radius",
  "Given a source file path, return the minimal set of files you need to read before " +
  "editing it: direct dependents (files that call its symbols), one hop of transitive " +
  "callers, and the covering test files. " +
  "Call this BEFORE reading files when the user asks 'what does this file affect?' or " +
  "before making changes to a shared utility. " +
  "Avoids reading the entire codebase — just the relevant slice.",
  {
    filePath: z.string().describe(
      "Absolute path to the Swift/ObjC source file to analyse. " +
      "E.g. '/Users/me/MyApp/Sources/AuthService.swift'."
    ),
    ...projectParams,
  },
  async ({ filePath, projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "blastRadius", filePath, projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const br = response.blastRadius;
    if (!br) {
      return { content: [{ type: "text", text: "No blast radius data returned." }] };
    }

    const lines: string[] = [];
    const fileName = filePath.split("/").pop() ?? filePath;

    if (br.affectedFiles.length === 0) {
      lines.push(`No dependents found for '${fileName}' — safe to edit in isolation.`);
    } else {
      lines.push(`Blast radius for '${fileName}': ${br.affectedFiles.length} affected file(s)\n`);
      lines.push("Direct dependents:");
      for (const f of br.directDependents) lines.push(`  ${f}`);
      if (br.coveringTests.length > 0) {
        lines.push("\nCovering tests:");
        for (const f of br.coveringTests) lines.push(`  ${f}`);
      }
      const others = br.affectedFiles.filter(
        f => !br.directDependents.includes(f) && !br.coveringTests.includes(f)
      );
      if (others.length > 0) {
        lines.push(`\nTransitive dependents (${others.length}):`);
        for (const f of others.slice(0, 20)) lines.push(`  ${f}`);
        if (others.length > 20) lines.push(`  … and ${others.length - 20} more`);
      }
    }

    const note = staleNote([filePath]);
    if (note) lines.push(`\n⚠️  ${note}`);

    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

// ---------------------------------------------------------------------------
// Tool: xcindex_status
// ---------------------------------------------------------------------------

server.tool(
  "xcindex_status",
  "Check the freshness of the Xcode index for a project. " +
  "Returns the index store path, last-build timestamp, and whether any source files " +
  "edited this session are newer than the index. " +
  "Call this first if you suspect the index is stale, or at session start when working " +
  "on a large Swift project.",
  {
    ...projectParams,
  },
  async ({ projectPath, indexStorePath }) => {
    const response = await bridge.send({ op: "status", projectPath, indexStorePath });
    if (response.error) {
      return { content: [{ type: "text", text: `Error: ${response.error}` }], isError: true };
    }
    const status = response.status;
    if (!status) {
      return { content: [{ type: "text", text: "No status data returned." }] };
    }

    const { getEditedFiles } = await import("./freshness.js");
    const editedFiles = [...getEditedFiles()];

    const lines: string[] = [
      `Index store: ${status.indexStorePath}`,
      `Last updated: ${status.indexMtime ?? "unknown"}`,
    ];

    if (editedFiles.length > 0) {
      lines.push(`\nFiles edited this session: ${editedFiles.length}`);
      for (const f of editedFiles) lines.push(`  ${f}`);
      lines.push("\n⚠️  These files were edited after the index was built. Consider rebuilding in Xcode for accurate results.");
    } else {
      lines.push("\nNo source files edited this session — index should be current.");
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
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
