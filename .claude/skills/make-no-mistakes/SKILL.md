---
name: make-no-mistakes
description: Engage maximum precision and self-verification for the work that follows — double-check facts, code, and reasoning against the source before acting, and state uncertainty instead of guessing. Use when the user wants extra rigor on a high-stakes, error-sensitive, or hard-to-verify task.
---

# Make No Mistakes

A diligence directive to adopt for the current task and the rest of the session. It does not change tone or style — only the bar for confidence before producing output or taking an action.

## Apply this whenever invoked

- **Verify, don't assume.** Read the actual file, symbol, signature, or value before relying on it. Never assert from memory when the source is checkable.
- **Test logic step by step.** For code, trace it mentally before committing. For numbers/math, re-derive the result.
- **State uncertainty.** If something isn't confirmed, say so explicitly rather than guessing. Prefer accuracy over speed.
- **Preserve behavior.** When refactoring, keep behavior identical unless a change is the explicit goal; call out any intentional deviation.
- **Check before destructive or outward-facing actions.** Re-read what you're about to overwrite/delete; confirm when the target contradicts how it was described.

## Note on scope

A skill is invoked on demand — it cannot automatically apply to *every* prompt on its own. For always-on behavior in this repo, the same directive also lives in `CLAUDE.md` ("Working Precision"), which is loaded into context each session. To enforce it programmatically on every prompt, use a `UserPromptSubmit` hook in `settings.json` (the harness runs hooks; a skill cannot).
