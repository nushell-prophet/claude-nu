---
name: git-intent-distill
description: Reduce a canvas document to its current-state meaning, letting spent rejected paths and process scaffolding fall into git history (recoverable via `git log -p -- <doc>`). Use when the user says "distill", "git-intent-distill", or "reduce the canvas".
argument-hint: [scope or instructions]
allowed-tools: Bash(git *), Read, Edit, Write, Grep, Glob
---

Distill compresses the *document*, not the history. `git-intent` writes the loop; `git-intent-squash-archive` collapses the commit stream; neither decides what text the canvas should still carry. Over a session the canvas accumulates rejected-path sections, resolved markers, and superseded caveats — the human wants to read current state, not the whole working record. Distill removes that accumulation *into history*: the doc converges to its meaning, every cut stays recoverable.

This is a forward commit, not a rewrite — lighter than squash-archive: no tag, no reset. The pre-distill version is `git show HEAD^:<doc>`. Run it whenever the canvas has drifted from lean, not only at finalization.

## Invariant

**Remove only what history already holds.** Every cut must be recoverable from `git log -p -- <doc>`, so the precondition is a clean tree — all work committed — or the parent commit won't hold the full pre-distill version and the removed content is gone, not archived. Run `git status --porcelain`; if non-empty, stop and ask the user to commit first (same guard as the sibling skills). Scope of the guarantee: `git log -p -- <doc>` on the working branch; after `git-intent-squash-archive` the recovery path becomes the `archive/<branch>` tag.

## What to cut, what to keep — the judgment

This is the skill; the mechanics below are secondary. Distill is **not** "delete every rejected path." A rejected section can be *dead* (its reasoning is spent) or *protective* (it stands in the doc to stop a future agent re-proposing the bad idea). Cutting protective text to history only helps a reader who checks `git log` before proposing — real discipline, not a guarantee. So weigh each candidate rather than sweeping.

**Cut — dead process material:**

- Resolved `!!` / `???` / `!!!` markers and the scaffolding around them.
- Working-list numbering gaps and half-formed notes the final state superseded.
- Deliberation a later decision made moot — the settled outcome stays, the weighing goes.
- A rejected path whose only value was recording *that* it was rejected — the deletion commit body carries that.

**Keep — live constraints:**

- `## Open decisions` and anything still unresolved: live, not dead.
- Protective why-nots — a rejected path documented to prevent re-litigation — stay inline unless the user says otherwise.
- Current-state contracts and any caveat that still binds behavior.

When a cut is judgment-heavy, do less: leaving a live constraint in costs a few lines; distilling one into archaeology costs a re-litigated decision. When you genuinely can't tell dead from protective, keep it and place a `???` asking the user.

## User instructions

`$ARGUMENTS` steers the operation and overrides the default taxonomy. It may set scope ("only the transport section"), aggressiveness ("keep all why-nots", "cut hard"), or name specific content to keep or drop. `!!` markers in the doc do the same in place. With no instruction, apply the taxonomy above conservatively.

## Procedure

1. **Clean-tree check** — `git status --porcelain`. Non-empty → stop, ask the user to commit or stash.
2. **Read the canvas in full** — path is `$env.GI_HOOK_DOC`; if unset, ask which document.
3. **Classify** — mark each section cut/keep per the taxonomy and any `$ARGUMENTS` / `!!` instructions. Anything genuinely ambiguous between dead and protective: keep it, add a `???`.
4. **Edit** — remove the cut material; repair what the cuts leave dangling (broken sentences, stale cross-references, list numbering). Never leave the doc mid-broken.
5. **Commit** — the canvas change as its own commit. Body is thin: the diff *is* the archive, so name what was distilled in one line, not what each removed section said.

## Related

- `/git-intent` — the write-loop that produced the material being distilled.
- `/git-intent-squash-archive` — finalization: collapse the branch (distill commits included) into one clean commit for `main`, full history preserved in a tag.
