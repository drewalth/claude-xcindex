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

Report:
1. Index store path
2. Last index update timestamp
3. Whether the index is stale (any session-edited Swift files newer than the index)
4. Recommendation: build in Xcode if stale, or confirm tools are ready if current
