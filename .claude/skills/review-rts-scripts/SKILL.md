---
name: review-rts-scripts
description: "Reviews RTSDemo mType (.mt) gameplay scripts for language correctness, VertexForge engine API misuse, and project conventions. Use when reviewing, auditing, or PR-checking changes under scripts/game, or when the user asks to review mType / RTS / VertexForge code. Trigger keywords: review, code review, audit, PR, mType, .mt, RTSDemo, VertexForge, controller, gameplay script."
license: MIT
metadata:
  version: "1.0.0"
  domain: specialized
  triggers: code review, review mType, audit RTS scripts, PR check, VertexForge review, scripts/game
  role: reviewer
  scope: static-review
  output-format: review-report
---

# Review RTS Scripts (mType / VertexForge)

Static code review for RTSDemo gameplay scripts (`scripts/game/**/*.mt`). Checks three
layers at once — **mType language correctness**, **VertexForge engine API usage**, and
**RTSDemo project conventions** — and emits a severity-grouped report. Review-only: the
project builds from the VertexForge editor, so there is no compile/run step here.

## Workflow

1. **Determine scope.**
   - If the user named a file/dir, review exactly that.
   - Otherwise review changed scripts: `git diff --name-only main...HEAD` plus
     `git status --porcelain` (Bash tool), then keep paths matching `scripts/game/**/*.mt`.
   - If nothing matches, say so and offer to review a path or the whole `scripts/game` tree.
2. **Read each target file in full** (not just the diff hunks — context matters for
   lifecycle, caching, and null-guard checks).
3. **Run the master checklist** below against each file. Open the matching `references/*.md`
   for detail, exact rules, `MT-Exxxx` codes, and real example line references.
4. **Emit the review report** in the output format below.

## Master checklist

**mType correctness** → see [references/mtype-syntax.md](references/mtype-syntax.md)
- Explicit types everywhere (no `var`); nullable `T?` narrowed before use (`if (x == null)`).
- `parsePrimitive(...)` wraps numbers/bools in string concatenation.
- `::` for static / `.` for instance; wrapper types in generics (`ArrayList<Int>`, not `<int>`).
- `@Override` on overrides; interface implementations are complete; constructor named `constructor`.
- `value class` has no mutable state and a default constructor.

**Engine API** → see [references/engine-api.md](references/engine-api.md)
- Every `Entity::findByName` / `instantiate` / `getScript` result guarded on `< 0` / `null`.
- UI listener handlers (`onButtonClicked`, etc.) filter by `buttonEntityId`/`entityName` —
  these events are **broadcast to every** implementing script in the scene.
- UI calls guarded on `widgetId >= 0`; listener interfaces fully implemented.
- No `findByName` / `findAll` / allocations in `onUpdate` hot paths (cache them).

**RTS conventions** → see [references/rts-conventions.md](references/rts-conventions.md)
- `VK-####` file-header comment present and accurate.
- Imports are `import * from "../../lib/..."` (engine first, then local, then util).
- `Entity::self()` / `findByName` cached in `onStart`; cross-controller `getScript<T>`
  resolved lazily via a cached `T?` helper (script init order is not guaranteed).
- `InputEdge.step()` called exactly once per frame; input consumed by action/axis **name** only.
- Cross-file constants live in `util/Config.mt`; single-controller knobs stay as fields.
- Comments explain *why*; stub public APIs are preserved when filled in.

## Output format

Group findings by severity, most severe first:

- **Blocker** — would fail to compile, crash at runtime, or silently break behavior
  (unguarded `-1`/`null`, type error, incomplete interface, unfiltered broadcast handler).
- **Warning** — likely bug or perf issue (per-frame lookups/allocations, missing `@Override`,
  edge-detection skipped on some frames).
- **Nit** — convention/style (missing VK header, import ordering, comment density).

Each finding: `file:line — issue — why it matters — suggested fix`. Cite the relevant
`MT-Exxxx` code or reference-doc/engine path when it sharpens the point. Only flag real
issues — do not nag style the codebase itself does not follow. End with a one-line verdict
(e.g. "2 blockers, 3 warnings — not ready" or "clean").

## References

- [references/mtype-syntax.md](references/mtype-syntax.md) — mType language rules + `MT-Exxxx` catalog.
- [references/engine-api.md](references/engine-api.md) — VertexForge API correct-vs-misuse patterns.
- [references/rts-conventions.md](references/rts-conventions.md) — RTSDemo conventions + anti-patterns.
