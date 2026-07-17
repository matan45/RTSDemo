# Graphify Code Graph (VertexForge)

A pre-built symbol graph of the whole engine at `C:\matan\VertexForge\graphify-out\`. Use it to answer **"what already touches this, and what will I break?"** in seconds, before any `Explore` fan-out.

It tells you **where to look**. It is not evidence — a `path:line` from the graph still gets `Read` before it enters the Output Template, per CLAUDE.md "Working Precision".

## What's in the folder

| File | Size | Use |
|---|---|---|
| `graph.json` | 70MB | The graph. **Never read directly** — query via the CLI. |
| `GRAPH_REPORT.md` | 370KB | Human-readable. **`grep` it, never wholesale-read.** |
| `manifest.json` | 560KB | Per-file mtime + AST hash. Which files the graph covers. |
| `.graphify_analysis.json` | 4.9MB | Raw community→node map. Rarely needed. |
| `cache/` | — | AST cache + `stat-index.json`. Ignore. |

## Commands (read-only — safe in plan mode)

```bash
graphify explain "AudioBusManager"        # ~2.3s: path:line, degree, community, all edges
graphify path "A" "B"                     # shortest path between two symbols
```

`explain` output gives node ID, source `path:line`, community, degree, and each edge tagged `[EXTRACTED]` or `[INFERRED]` with a direction (`-->` / `<--`) and kind (`defines` / `references` / `contains` / `calls` / `imports`).

**Writes — NOT allowed in plan mode:** `graphify update .` (re-extract, no LLM/API cost), `graphify cluster-only .` (re-cluster + regenerate report). If the graph is stale, note it in *Open questions* and hand the refresh to the user.

## Freshness

`GRAPH_REPORT.md` header carries `Built from commit:` — compare against `git rev-parse HEAD`. A stale graph still has correct topology for untouched subsystems; it just won't know about new symbols. Check what actually moved before discarding it:

```bash
git log --oneline <graph-commit>..HEAD
git diff --stat <graph-commit>..HEAD
```

## Report sections worth grepping

- **`## God Nodes`** — the blast-radius list. As of the `905f90ac` build: `ICommand` 557 edges, `GPUDrivenRenderer` 420, `RenderPassHandler` 385, `IQuery` 364, `AssetRef` 254, `OffScreenController` 191, `INotification` 181. A feature touching one of these is a wide change — say so in *Constraints*.
- **`## Import Cycles`** — empty on a healthy build; a new entry is a real finding.
- **`## Communities`** — 1,738 clusters. Named ones (`AudioBusManager`, `ShadowSystem`, `TerrainService`, `PhysicsWorld`) map to real subsystems and are a decent "what else lives here" probe.
- **`## Summary`** — node/edge counts and the EXTRACTED/INFERRED split.

## Traps (verified 2026-07-17, not assumed)

**`[INFERRED]` edges are name-collision guesses — never cite one as fact.** ~6% of edges (6,424) are INFERRED at avg confidence 0.8. The report's own `## Surprising Connections` showcase is mostly false positives:

- Claimed `BackgroundRemover::autoDetectBackground() --calls--> sample` in `MemoryDiagnosticsWindow.hpp`. Impossible — `BackgroundRemover.cpp` includes only `ImageWriter.hpp`, `<cmath>`, `<algorithm>`.
- Claimed `legLength() --calls--> pos` in `NavmeshTileCache.cpp`. Impossible — `RetargetContext.cpp` has no navigation include.

Both collide on common method names (`sample`, `pos`). **To confirm any INFERRED edge, read the includes of the source file.** If the target's header isn't reachable, the edge is fiction.

**Stdlib types are nodes, so `path` routes through them.** `vector`, `string`, `string_view`, `map`, `shared_mutex` are high-degree hubs. Real example:

```
AudioBusManager --references--> shared_mutex <--imports-- EventDispatcher.hpp --contains--> EventDispatcher
```

That is not a call path — it says both files include `<shared_mutex>`. **Discard any path whose middle hop is a stdlib type.**

**Noise communities.** Clusters named `vector` / `string` / `string_view` / `map` with cohesion ~0.01 are stdlib buckets, not subsystems. Cohesion is the tell.

**Ambiguous matches.** `path` may warn `target match was ambiguous (top score …, runner-up …)` — many symbols share names across the engine. Re-run with a more specific symbol, or `explain` both candidates to disambiguate.

## Where it fits the workflow

Step **1 (Frame)**: `explain` the symbol in the question to pick entry points and spot god-node blast radius.
Step **2 (Fan out)**: hand each `Explore` agent the concrete `path:line` set the graph surfaced, instead of "go find the audio code".
Step **3 (Synthesize)**: `Read` every cited file. The graph never ships a claim on its own.
