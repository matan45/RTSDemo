---
name: engine-research
description: "Research the VertexForge game engine before planning: map architecture, trace call paths across the Editor->Services->Core/Graphics layers and subsystem DLLs, and combine codebase exploration with external Vulkan/rendering/game-engine-design research. Use when planning an engine change, investigating how a subsystem works, scoping a feature, or answering 'how does X work / where does Y live' in VertexForge — especially in plan mode. Trigger keywords: research, investigate, how does, where is, architecture, plan, VertexForge engine, subsystem, render pipeline, call trace, scope a feature."
license: MIT
metadata:
  version: "1.1.0"
  domain: specialized
  triggers: research, investigate, architecture, plan mode, VertexForge, subsystem, call trace, render pipeline, scope feature, how does, where is
  role: researcher
  scope: investigation
  output-format: structured
  related-skills: game-developer, vulkan-graphics-dev, improve-codebase-architecture
---

# Engine Research (VertexForge)

A **read-only** research skill. The goal is a high-confidence evidence base for a plan — an architecture map, exact `path:line` citations, and a call trace — not edits. It is safe to invoke inside **plan mode** (uses only read tools + web research; the only file it may write is the plan file).

> The deliverable is the **Output Template** below, populated with verified citations. Stop at findings — hand off to design/planning.

## Seed every investigation with

- **`CLAUDE.md`** — module dependency graph, subsystem-extraction table, file-location tables, naming conventions.
- **`C:\Users\matan\.claude\projects\C--matan-VertexForge\memory\MEMORY.md`** — topic-file index of prior subsystem work; open the linked file for an area before exploring it. Treat as *leads*, not truth — re-verify any named file/symbol still exists.
- **git history** — `git log --oneline -- <path>` for how an area evolved.
- **the graphify code graph** (`graphify-out/`) — a whole-engine symbol graph (~55k nodes / ~101k edges). Cheapest first move when the question names a symbol; it finds *where to look*, it does not replace reading the source. See [graphify.md](references/graphify.md).
  - `graphify explain "<Symbol>"` — source `path:line`, degree, community, and every edge. ~2s even against the 70MB `graph.json`.
  - `grep` (never wholesale-read) `graphify-out/GRAPH_REPORT.md` — `## God Nodes` is a blast-radius warning; also `## Import Cycles`, `## Communities`.
  - **Check freshness first**: the report header names its build commit — compare to `git rev-parse HEAD`. If stale, say so in *Open questions*; **do not** run `graphify update .` inside plan mode (it writes).
  - **Only `[EXTRACTED]` edges (94%) are trustworthy.** `[INFERRED]` edges are name-collision guesses — verify before citing.

## Core Workflow

1. **Frame** — restate the question in one line. Decompose into ≤3 **codebase areas** + the **external/theory questions** worth researching. Pick entry points from [investigation-playbook.md](references/investigation-playbook.md). If the question names a symbol, `graphify explain` it first — it costs ~2s and sharpens the entry points.
2. **Fan out (parallel)** — in a **single message**, launch up to **3 `Explore` agents**, each with a distinct, specific focus (e.g. existing implementation / related components / tests & patterns). Hand each agent the concrete `path:line` set the graph surfaced rather than a vague area. In parallel, run `WebSearch`/`WebFetch` for theory questions — see [external-research.md](references/external-research.md).
3. **Synthesize** — collapse results into the Output Template. Resolve any contradiction by `Read`-ing the cited file directly; never ship an unverified claim.
4. **Gap pass** — list unknowns and unverified claims. Run a focused second round **only** for gaps that block the plan (loop-until-confident, not exhaustive).

## Output Template

```
Question        — one line.
Architecture    — modules/layers involved + how they connect
                  (use CLAUDE.md vocabulary: provider/adapter/controller/handler/service).
Key files       — path:line list of the load-bearing files & symbols.
Call trace      — end-to-end flow (e.g. Editor event -> Service -> Adapter -> Controller -> Graphics).
External         — Vulkan/library/technique notes, each with a source URL.
Constraints     — ABI/DLL boundaries, ECSRegistry singleton rule, shader-copy gotcha, validation concerns.
Open questions  — what remains unverified, and why.
```

## Constraints

### MUST DO
- Cite every claim with `path:line`; verify against source per CLAUDE.md "Working Precision".
- Keep `Explore` prompts narrow and concrete (one area + what to return), not "explore the engine".
- Surface existing utilities/patterns to reuse — research is also reuse-discovery.
- Trace the **representative path** end-to-end rather than listing every file.

### MUST NOT DO
- Make edits, run builds, or any non-read action (the plan file is the only allowed write).
- Trust a memory/topic file without re-verifying the named files/symbols exist now.
- Cite a graphify `[INFERRED]` edge as fact, or trust a `graphify path` whose middle hop is a stdlib type (`vector`, `string`, `shared_mutex`) — both are artifacts, not call paths.
- Enumerate every file in a subsystem — name the load-bearing ones.
- State time-sensitive or version-specific facts without a source.

## Plan-mode integration

Findings feed straight into the plan: put the **Architecture map**, **Key files** (`path:line`), and **Constraints** into the plan file, then design against them. This skill produces the evidence; the plan decides the change.

See [investigation-playbook.md](references/investigation-playbook.md) for per-domain entry points and [external-research.md](references/external-research.md) for the web/theory half.
