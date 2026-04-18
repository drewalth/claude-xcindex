#!/usr/bin/env node
// Bumps the version field in .claude-plugin/plugin.json.
// Invoked by semantic-release's @semantic-release/exec prepareCmd.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const version = process.argv[2];
if (!version) {
  console.error("Usage: bump-version.mjs <version>");
  process.exit(1);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pluginManifest = resolve(repoRoot, ".claude-plugin/plugin.json");

const manifest = JSON.parse(readFileSync(pluginManifest, "utf8"));
manifest.version = version;
writeFileSync(pluginManifest, JSON.stringify(manifest, null, 2) + "\n");
console.log(`Updated ${pluginManifest} -> ${version}`);
