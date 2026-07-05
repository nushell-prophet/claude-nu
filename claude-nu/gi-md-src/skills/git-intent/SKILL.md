---
name: git-intent
version: 0.4.0
description: Process commits as instructions — execute `!!` inline markers and `gi: <text>` commit-subject instructions, propagate user-committed choices through the codebase. Use when the user says "git-intent", "process", "apply intent", or pastes a `git log` containing `!!` markers or `gi:` subjects.
argument-hint: <N>
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

Git is the instruction interface between human and agent. The human delivers intent through commit messages and inline `!!` markers in any file type. The agent reads the diff, executes the instructions, and commits the results. Every change is reviewable in git history.

## Why

Chat is awkward for two things: instructions targeting many scattered points in a file (the user can't easily attach a comment at each), and reviewing large agent responses (no fast way to give feedback per section). Move both into a file and let git carry the loop — the user sees a diff, can revert individual hunks, and can leave `!!` markers right where a change should land. The agent should commit promptly so each step is a stable rollback point. If the agent's reply would be large, write it to `todo/` or `specs/`, not the chat.

It's a REPL cycle: user instructs, sees the diff, judges, instructs again. Git adds what a plain REPL lacks — per-step rollback and a history you can return to. That history is the workflow's main artifact: an auditable record of decisions, their motivations, and the paths that were considered and rejected. The iterative history is preserved on archival (see `/git-intent-squash-archive`) precisely so the rejected paths aren't lost.

## Instruction channels

Three channels carry user intent into a commit:

- **`!!` markers** in any file — pinpoint instructions next to the target.
- **Commit message** — explanation/context for the committed edit, optionally prefixed `gi:` (git intent). If the message reads as an imperative ("rename foo to bar", "expand this section"), treat it as actionable.
- **Direct edit** — the user's edit itself, with no marker and no commit-message text, is also an instruction. The edit *is* the decision; the agent's job is to honor and propagate it.

If `$ARGUMENTS` is empty or not a positive integer, default to `1`.

## Commit patterns

A commit message — with or without the `gi:` prefix — defaults to **explanation** of what the user already committed; the edit itself is the decision, and the agent honors and propagates it without re-executing the text. If the message reads as an **imperative**, treat it as actionable and apply it to the commit's files. When the role is unclear, ask. The pipeline is uniform: apply any `!!` markers, apply any imperative commit message, propagate the resulting decision to stale references elsewhere. Empty steps are no-ops.

The subject prefix is `gi:` (quiet — the commit *is* the unit, no surrounding noise to fight) while inline markers are `!!` (loud — they must stand out against surrounding code).

## Markers

- Native single-line comment of the file, prefixed with `!!`. Examples: `# !! ...` (Python/Nu/Shell/YAML), `// !! ...` (JS/Rust/Go/C), `-- !! ...` (SQL), `/* !! ... */` (CSS), `<!-- !! ... -->` (HTML/Markdown).
- Place on the line above or beside the target code
- Removed after processing — remove the whole comment including any closing delimiters (`*/`, `-->`), not just the `!!` token
- Comments without `!!` are persistent context — leave alone

## Reading user edits

- **User's committed edit > prior markers** — if the user edited code a marker targets, the edit *is* the decision; remove the marker without re-applying it
- **Clean up broken surroundings** — if the user's edit left a dangling sentence, stale list numbering, or broken syntax, fix it. Never re-add content the user removed
- **Surface contradictions** — when markers/edits conflict or scope is unclear, name the conflict in the commit body if you can resolve it, ask the user if you can't

## Procedure

1. **Clean-tree check** — run `git status --porcelain`. If non-empty, stop and ask the user to commit or stash.

2. **Get the diff** — run `git log -p -N --reverse` where `N = $ARGUMENTS`. If the patch is very large (>500 lines), prefer `git log -N --stat` plus targeted `git show` per file to avoid filling context.

3. **Read files in scope** in full. Skip files you've already read or edited in this session, and skip binary files.

4. **For each commit, run the pipeline:**
   - **Apply markers** — for each `!!` marker added in the diff, read the instruction text, apply it to the target code/text, remove the whole marker comment (including any closing delimiters like `*/` or `-->`).
   - **Apply imperative commit message** — if the message (with or without `gi:`) reads as a command, apply it to the commit's files. If it reads as explanation, skip — the edit itself is the decision.
   - **Propagate the decision** — scan each file in the commit scope for references that contradict the resulting state (stale branches, removed APIs, old behavior descriptions, obsolete rationale). If the decision names a symbol, path, API, or config key, also `grep` the broader repo. Clean up broken surroundings left by user edits, per *Reading user edits* above.

   Empty markers, empty global instruction, and no propagation needed are all valid no-ops — the pipeline runs unconditionally.

5. **Commit each logical change** — one commit per decision. When scope is unclear, name your interpretation in the commit body if you can resolve it; ask the user if you can't (per *Reading user edits*). Body is mandatory and follows this template:

   ```
   <subject>

   Decision: <one sentence>
   Why: <non-obvious reasoning, 1–2 sentences>
   Rejected: <alternative considered and dropped, with the reason — omit if none>
   Propagated: <other places touched — omit this line if none>
   ```

   - **Record rejected paths.** If the user considered an alternative and dropped it (in chat, via a `!!` marker that was later removed, or by reverting a prior hunk), capture it as `Rejected: <alt> — <why>`. The dead end is part of the decision graph and would otherwise be lost.
   - **Don't list conflicts you looked for and didn't find.** "Nothing else changed" is noise; absence is the default.
   - **Don't restate the diff.** If the body is longer than the diff, the body is wrong unless the reasoning is genuinely complex.
   - **Skip binary files** in the diff.
   - A decision visible in git history is binding — do not override without explicit instruction.

   If there is genuinely nothing to do (no markers, no propagation, no cleanup), report it and exit without creating an empty commit.

## Related

- `/git-intent-squash-archive` — when done iterating, squash the branch into one clean commit preserved as a git tag
