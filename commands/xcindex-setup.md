---
name: xcindex-setup
description: Bootstrap xcindex in the current project — verifies the Swift binary, locates the Xcode project, optionally builds it so the symbol index is populated, then smoke-tests the MCP tools.
allowed-tools:
  - Bash
  - Glob
  - Read
  - AskUserQuestion
  - mcp__xcindex__status
---

Run the xcindex setup sequence for the current working directory. Walk
through each step in order, reporting progress between steps. Stop and
ask the user before any xcodebuild invocation.

## 1. Verify the Swift binary

Check that `${CLAUDE_PLUGIN_ROOT}/bin/xcindex` exists and is executable.
If it doesn't, run `${CLAUDE_PLUGIN_ROOT}/bin/run </dev/null` once to let
the launcher download or symlink the binary (it exits cleanly after
spawning its subprocess with an immediate EOF on stdin). If download
fails and the repo contains `service/Package.swift`, offer to fall back
to `cd service && swift build -c release` and report the built path.

If no binary can be obtained, stop here and tell the user what's
missing (network, Swift toolchain, or a valid release for their
plugin version).

## 2. Diagnostic scan

Find the Xcode project in the current working directory. Prefer
`.xcworkspace` over `.xcodeproj`; look in the cwd and one level up;
skip `*/Pods/*` and `*/.git/*` paths. This mirrors the detection logic
in `hooks/session-start.sh`.

Resolve the DerivedData directory:
  - Default: `~/Library/Developer/Xcode/DerivedData/<ProjectName>-*`,
    most recently modified.
  - Check for a custom location: `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation`.

Report:
  - Project path found (or "none detected").
  - Index store path (or "index store not present").
  - Last-build timestamp, if the index exists.
  - Any source files with mtime newer than the index.

## 3. Decide whether to build

If no `.xcodeproj` / `.xcworkspace` was found, stop — there's nothing to
build. Confirm the binary works and exit.

If the index exists and is not stale, tell the user xcindex is ready and
offer to skip the build. Only proceed if they want to force a rebuild.

If the index is missing or stale, use AskUserQuestion to confirm before
invoking xcodebuild — building can take minutes and uses significant CPU.
Offer two options:
  - "Build all schemes now" (recommended if the user just cloned or hasn't
    built recently).
  - "Skip — I'll build in Xcode myself."

## 4. Build schemes

If the user confirms:

  - `xcodebuild -list -project <found>` (or `-workspace`). Parse the
    "Schemes:" block; one scheme per line, trim whitespace.
  - For each scheme, detect its primary platform:
    `xcodebuild -showBuildSettings -scheme <s> -project <found> 2>/dev/null | grep SUPPORTED_PLATFORMS`.
    Pick the first value. Choose a destination:
      - `macosx` → `-destination 'generic/platform=macOS'`
      - `iphoneos` / `iphonesimulator` → `-destination 'generic/platform=iOS Simulator'`
      - `watchos*` → `-destination 'generic/platform=watchOS Simulator'`
      - `appletvos*` → `-destination 'generic/platform=tvOS Simulator'`
      - otherwise skip with a note
  - Build each scheme: `xcodebuild build -scheme <s> [-project|-workspace] <path> -destination '<d>' -quiet`.
    Stream output. If a build fails, stop and report which scheme broke
    with the last ~20 lines of output.

Test schemes (suffix "Tests") are usually covered by the primary scheme
— skip any scheme whose name ends in "Tests" to avoid redundant builds,
unless the user explicitly asks for them.

## 5. Smoke test

Call the `status` tool from the xcindex MCP server (`mcp__xcindex__status`)
with the resolved project path. Confirm it returns a sensible
`indexStorePath` and a recent `indexMtime`.

If status succeeds, print a summary:

```
✅ xcindex ready for <ProjectName>
   Index: <path>
   Last built: <mtime>
   Tools available: mcp__xcindex__find_symbol, mcp__xcindex__find_references, etc.
```

If status fails, report the error and suggest next steps — most often
this means the build completed but the index hasn't been written to disk
yet; wait a few seconds and retry.
