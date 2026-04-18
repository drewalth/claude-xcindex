# xcindex benchmark

**Project:** a real-world Swift project  
**Codebase:** 302 Swift files, 43,185 LOC  
**Index:** 229M on disk, last built 2026-04-12T23:44:26Z  
**Hardware:** arm64, Mac15,7  
**Method:** median of 5 runs per measurement

## Tool latency

| Tool | Cold (ms) | Warm (ms) |
|---|---:|---:|
| `find_symbol` | 5446 | 0 |
| `find_references` | 5496 | 1 |
| `find_definition` | — | 0 |
| `find_overrides` | — | 0 |
| `find_conformances` | — | 0 |
| `blast_radius` | 6377 | 876 |
| `status` | 5545 | 0 |

_Cold = first query in a fresh subprocess (includes opening the 222 MB LMDB index). Warm = subsequent query in the same process — what Claude experiences after the first call in a session, since the MCP server keeps the Swift subprocess alive. USR-based tools (`find_definition`/`find_overrides`/`find_conformances`) only run after a `find_symbol` resolves the USR, so cold timing is N/A._

## Precision: xcindex vs `grep -rn '\bSym\b'`

| Symbol | Kind | grep hits | grep files | xcindex refs | xcindex files | files saved | grep ms | xcindex warm ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `A` | common domain struct | 129 | 45 | 95 | 27 | 18 (40%) | 228 | 12 |
| `B` | service protocol | 90 | 27 | 18 | 8 | 19 (70%) | 230 | 0 |
| `C` | service class | 61 | 27 | 37 | 12 | 15 (55%) | 227 | 1 |
| `D` | narrow protocol | 14 | 6 | 7 | 6 | 0 (0%) | 230 | 0 |
| `E` | model type | 46 | 15 | 46 | 15 | 0 (0%) | 228 | 1 |

_Symbol names redacted; counts and types are real. "Files saved" = files Claude would read with the grep approach minus files xcindex returned. xcindex returns precise (file, line, role) tuples that can be read line-anchored, so even when file counts are equal, xcindex eliminates the per-file scan-and-filter step._
