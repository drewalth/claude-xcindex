#!/usr/bin/env python3
"""Benchmark xcindex MCP queries vs textual grep on a real Xcode project.

Usage:
    scripts/benchmark.py /path/to/Project.xcodeproj

Emits a markdown report to stdout and writes scripts/benchmark-results.md.
Requires: a built xcindex binary (run ./build.sh first).

Methodology:
- Tool latency: cold = first query in a fresh subprocess (includes opening
  the LMDB index). Warm = subsequent query in the same process. The MCP
  server keeps the Swift subprocess alive across queries, so warm is what
  Claude experiences after the first call in a session.
- USR-only tools (findDefinition/findOverrides/findConformances) require
  a USR — we resolve one via findSymbol first, then time the USR call as
  warm-only (it's always preceded by a name resolution in real use).
- Precision: compares xcindex findRefs (semantic, USR-grounded) against
  `grep -rn '\\bSym\\b'` (best-case grep — word-boundary). Counts how
  many distinct files Claude would have to read with each approach.
"""
from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# (real_name, display_label, kind) — real_name is used for queries; label+kind appear in the report.
SYMBOLS = [
    ("Gauge",         "A", "common domain struct"),
    ("GaugeBot",      "B", "service protocol"),
    ("GaugeService",  "C", "service class"),
    ("GaugeDriver",   "D", "narrow protocol"),
    ("GaugeReading",  "E", "model type"),
]
RUNS = 5


def find_xcindex() -> Path:
    for variant in ("release", "debug"):
        p = REPO_ROOT / "mcp" / "swift-service" / ".build" / variant / "xcindex"
        if p.exists() and os.access(p, os.X_OK):
            return p
    sys.exit("xcindex binary not found. Run ./build.sh first.")


XCI = find_xcindex()


class XciSession:
    """A persistent xcindex subprocess. Mimics how the MCP server uses it."""

    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [str(XCI)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )

    def call(self, payload: dict) -> tuple[dict, int]:
        """Send a request, return (parsed response, elapsed ms)."""
        assert self.proc.stdin and self.proc.stdout
        line = json.dumps(payload) + "\n"
        t0 = time.monotonic()
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        out = self.proc.stdout.readline()
        elapsed = int((time.monotonic() - t0) * 1000)
        return json.loads(out), elapsed

    def close(self) -> None:
        if self.proc.stdin:
            self.proc.stdin.close()
        self.proc.wait(timeout=5)

    def __enter__(self): return self
    def __exit__(self, *_): self.close()


def median(xs: list[int]) -> int:
    return int(statistics.median(xs))


def time_grep(symbol: str, root: str) -> int:
    samples = []
    for _ in range(3):
        t0 = time.monotonic()
        subprocess.run(
            ["grep", "-rn", rf"\b{symbol}\b", "--include=*.swift", root],
            capture_output=True,
            check=False,
        )
        samples.append(int((time.monotonic() - t0) * 1000))
    return median(samples)


def grep_counts(symbol: str, root: str) -> tuple[int, int]:
    out = subprocess.run(
        ["grep", "-rn", rf"\b{symbol}\b", "--include=*.swift", root],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    lines = [ln for ln in out.splitlines() if ln]
    files = {ln.split(":", 1)[0] for ln in lines}
    return len(lines), len(files)


def resolve_usr(session: XciSession, project_path: str, name: str) -> str | None:
    resp, _ = session.call({"op": "findSymbol", "projectPath": project_path, "symbolName": name})
    syms = resp.get("symbols") or []
    return syms[0]["usr"] if syms else None


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} /path/to/Project.xcodeproj")
    project_path = sys.argv[1]
    project_root = str(Path(project_path).parent)

    # ---- environment / status ----
    with XciSession() as s:
        status_resp, _ = s.call({"op": "status", "projectPath": project_path})
    status = status_resp["status"]
    index_path = status["indexStorePath"]
    index_mtime = status["indexMtime"]
    index_size = subprocess.run(
        ["du", "-sh", index_path], capture_output=True, text=True, check=False
    ).stdout.split()[0]
    swift_files = subprocess.run(
        ["find", project_root, "-name", "*.swift",
         "-not", "-path", "*/.build/*", "-not", "-path", "*/DerivedData/*"],
        capture_output=True, text=True, check=False,
    ).stdout.splitlines()
    n_files = len(swift_files)
    loc = sum(1 for f in swift_files for _ in open(f, errors="ignore"))

    # ---- per-tool latency ----
    # Two categories:
    #   name-based: findSymbol, findRefs, blastRadius, status — pass symbolName/filePath directly
    #   USR-based:  findDefinition, findOverrides, findConformances — require a USR resolved via findSymbol
    name_tools = [
        ("find_symbol",     {"op": "findSymbol",     "projectPath": project_path, "symbolName": "GaugeService"}),
        ("find_references", {"op": "findRefs",       "projectPath": project_path, "symbolName": "GaugeService"}),
        ("blast_radius",    {"op": "blastRadius",    "projectPath": project_path,
                             "filePath": f"{project_root}/AppDatabase/Sources/AppDatabase/Schema/Gauge.swift"}),
        ("status",          {"op": "status",         "projectPath": project_path}),
    ]
    usr_tools = ["find_definition", "find_overrides", "find_conformances"]

    print("Benchmarking tool latency...", file=sys.stderr)
    tool_latency: dict[str, tuple[int | None, int]] = {}

    for label, payload in name_tools:
        cold_samples, warm_samples = [], []
        for _ in range(RUNS):
            with XciSession() as s:
                _, cold = s.call(payload)
                _, warm = s.call(payload)
            cold_samples.append(cold)
            warm_samples.append(warm)
        tool_latency[label] = (median(cold_samples), median(warm_samples))
        print(f"  {label}: cold={tool_latency[label][0]}ms warm={tool_latency[label][1]}ms", file=sys.stderr)

    # USR-based tools — resolve USR once, then time USR call as warm-only.
    # In real use the USR is always obtained via a prior findSymbol in the same session,
    # so the index is already open.
    with XciSession() as s:
        gauge_service_usr = resolve_usr(s, project_path, "GaugeService")
        gauge_driver_usr = resolve_usr(s, project_path, "GaugeDriver")
    if not gauge_service_usr or not gauge_driver_usr:
        sys.exit("Could not resolve USRs for benchmark symbols")

    usr_payloads = {
        "find_definition":   {"op": "findDefinition",   "projectPath": project_path, "usr": gauge_service_usr},
        "find_overrides":    {"op": "findOverrides",    "projectPath": project_path, "usr": gauge_service_usr},
        "find_conformances": {"op": "findConformances", "projectPath": project_path, "usr": gauge_driver_usr},
    }
    for label in usr_tools:
        payload = usr_payloads[label]
        warm_samples = []
        with XciSession() as s:
            # Open the index with one warm-up call.
            s.call({"op": "status", "projectPath": project_path})
            for _ in range(RUNS):
                _, ms = s.call(payload)
                warm_samples.append(ms)
        tool_latency[label] = (None, median(warm_samples))
        print(f"  {label}: warm={tool_latency[label][1]}ms (USR-only — preceded by findSymbol)", file=sys.stderr)

    # ---- precision: xcindex (warm, persistent process) vs grep ----
    print("Benchmarking precision (xcindex vs grep)...", file=sys.stderr)
    precision: dict[str, dict] = {}
    with XciSession() as s:
        # Warm up so the LMDB index is open.
        s.call({"op": "status", "projectPath": project_path})
        for real_name, label, kind in SYMBOLS:
            payload = {"op": "findRefs", "projectPath": project_path, "symbolName": real_name}
            resp, _ = s.call(payload)
            occ = resp.get("occurrences") or []
            xci_files = len({o["path"] for o in occ})
            xci_samples = []
            for _ in range(RUNS):
                _, ms = s.call(payload)
                xci_samples.append(ms)
            xci_ms = median(xci_samples)
            grep_hits, grep_files = grep_counts(real_name, project_root)
            grep_ms = time_grep(real_name, project_root)
            precision[label] = {
                "kind": kind,
                "grep_hits": grep_hits, "grep_files": grep_files, "grep_ms": grep_ms,
                "xci_refs": len(occ), "xci_files": xci_files, "xci_ms": xci_ms,
            }
            print(f"  {real_name} ({label}, {kind}): grep={grep_hits} hits / {grep_files} files / {grep_ms}ms"
                  f"  vs  xcindex={len(occ)} refs / {xci_files} files / {xci_ms}ms", file=sys.stderr)

    # ---- emit markdown ----
    hardware = subprocess.run(
        ["sysctl", "-n", "hw.model"], capture_output=True, text=True, check=False
    ).stdout.strip() or "unknown"
    arch = subprocess.run(["uname", "-m"], capture_output=True, text=True, check=False).stdout.strip()

    L = []
    L.append("# xcindex benchmark")
    L.append("")
    L.append(f"**Project:** a real-world Swift project  ")
    L.append(f"**Codebase:** {n_files} Swift files, {loc:,} LOC  ")
    L.append(f"**Index:** {index_size} on disk, last built {index_mtime}  ")
    L.append(f"**Hardware:** {arch}, {hardware}  ")
    L.append(f"**Method:** median of {RUNS} runs per measurement")
    L.append("")
    L.append("## Tool latency")
    L.append("")
    L.append("| Tool | Cold (ms) | Warm (ms) |")
    L.append("|---|---:|---:|")
    order = ["find_symbol", "find_references", "find_definition", "find_overrides",
             "find_conformances", "blast_radius", "status"]
    for label in order:
        cold, warm = tool_latency[label]
        cold_cell = f"{cold}" if cold is not None else "—"
        L.append(f"| `{label}` | {cold_cell} | {warm} |")
    L.append("")
    L.append("_Cold = first query in a fresh subprocess (includes opening the 222 MB LMDB index). "
             "Warm = subsequent query in the same process — what Claude experiences after the first "
             "call in a session, since the MCP server keeps the Swift subprocess alive. USR-based "
             "tools (`find_definition`/`find_overrides`/`find_conformances`) only run after a "
             "`find_symbol` resolves the USR, so cold timing is N/A._")
    L.append("")
    L.append("## Precision: xcindex vs `grep -rn '\\bSym\\b'`")
    L.append("")
    L.append("| Symbol | Kind | grep hits | grep files | xcindex refs | xcindex files | files saved | grep ms | xcindex warm ms |")
    L.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for _, label, _kind in SYMBOLS:
        p = precision[label]
        saved = p["grep_files"] - p["xci_files"]
        pct = (saved * 100 // p["grep_files"]) if p["grep_files"] else 0
        L.append(
            f"| `{label}` | {p['kind']} | {p['grep_hits']} | {p['grep_files']} | {p['xci_refs']} | {p['xci_files']} | "
            f"{saved} ({pct}%) | {p['grep_ms']} | {p['xci_ms']} |"
        )
    L.append("")
    L.append("_Symbol names redacted; counts and types are real. \"Files saved\" = files Claude would read "
             "with the grep approach minus files xcindex returned. xcindex returns precise (file, line, role) "
             "tuples that can be read line-anchored, so even when file counts are equal, xcindex eliminates "
             "the per-file scan-and-filter step._")
    L.append("")

    report = "\n".join(L)
    out_path = REPO_ROOT / "scripts" / "benchmark-results.md"
    out_path.write_text(report)
    print(report)
    print(f"\nWrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
