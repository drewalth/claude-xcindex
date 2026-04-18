#!/usr/bin/env node
// Bumps the version field across every manifest this repo ships.
// Invoked by semantic-release's @semantic-release/exec prepareCmd.
//
// Kept in sync:
//   - package.json            (+ package-lock.json via `npm version`)
//   - mcp/package.json        (+ mcp/package-lock.json via `npm version`)
//   - .claude-plugin/plugin.json   (hand-edited; not an npm package)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const version = process.argv[2];
if (!version) {
  console.error("Usage: bump-version.mjs <version>");
  process.exit(1);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const npmPackageDirs = [repoRoot, resolve(repoRoot, "mcp")];
for (const cwd of npmPackageDirs) {
  execFileSync(
    "npm",
    ["version", version, "--no-git-tag-version", "--allow-same-version"],
    { cwd, stdio: "inherit" },
  );
}

const pluginManifest = resolve(repoRoot, ".claude-plugin/plugin.json");
const manifest = JSON.parse(readFileSync(pluginManifest, "utf8"));
manifest.version = version;
writeFileSync(pluginManifest, JSON.stringify(manifest, null, 2) + "\n");
console.log(`Updated ${pluginManifest} -> ${version}`);
