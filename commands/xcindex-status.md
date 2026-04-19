---
name: xcindex-status
description: Check Xcode index freshness for the current project.
allowed-tools:
  - mcp__xcindex__status
  - Bash
  - Glob
---

Call the `status` tool from the xcindex MCP server with the project path
inferred from the current working directory, or ask the user to provide it
if it can't be found.

If no `projectPath` or `indexStorePath` is available, scan `./` and `../` for
`.xcodeproj` or `.xcworkspace` files and use the first match.

Report, in this order:

1. **Index store path** — the resolved `Index.noindex/DataStore` directory.
2. **Last index update timestamp** — when Xcode last wrote the index.
3. **Stale files** — any Swift files the user has edited this session that
   are newer than the index. If the status response includes a
   `results may be stale` note on any path, surface it prominently.
4. **Recommendation** — one of:
   - **Up to date** — "Tools are ready. Ask about references, overrides, conformances, or blast radius."
   - **Stale** — show the exact rebuild command for the detected project:
     - For `.xcworkspace`:
       ```
       xcodebuild -workspace <name>.xcworkspace -scheme <scheme> -configuration Debug build
       ```
     - For `.xcodeproj`:
       ```
       xcodebuild -project <name>.xcodeproj -scheme <scheme> -configuration Debug build
       ```
     - If the user prefers the IDE: "Open in Xcode and press Cmd+B."
   - **No index found** — suggest `/xcindex-setup` to build from scratch,
     or running `./bin/xcindex-doctor` for a full environment check.

Be concise. Three or four short lines of prose for up-to-date; a single
commanded-line for stale; a one-sentence remediation for missing.
