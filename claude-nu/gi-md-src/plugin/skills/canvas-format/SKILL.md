---
name: canvas-format
description: Experimental. Work on the aesthetics and usability of a canvas — reformat it for reading without changing what it says — threads and indents, marker placement, semantic-feed line breaks, headings — in a few passes, one commit each, learned from the Canvas style and from the user's own formatting edits in the canvas history. Use when the user says "format the canvas", "canvas-format", "отформатируй канвас", "причеши форму", "make it readable", or asks for layout changes only. For cutting spent content, use `gi:canvas-tidy` instead.
argument-hint: [lens or instructions]
allowed-tools: Bash(git *), Read, Edit, Write, Grep, Glob
---

Format works on the aesthetics and the usability of the canvas:
how the page looks in Helix,
and how fast he finds a point, sees whose line it is, and reads it.
Judge every change by that,
not by whether a rule allows it:
a change that obeys the style and makes the page no easier to read is not worth a commit.
It changes the shape of the canvas, never its claims.
`gi:canvas-tidy` decides what text stays;
this skill decides how the text that stays is laid out.
The user asks for it on purpose,
so it may touch lines he did not change in this turn
— the minimal-diff rule of semantic feed does not hold here.
Each pass is one commit,
so he reverts the passes he does not like with `git revert`.

## Invariant

**No word of his changes.**
A pass moves line breaks, indents, blank lines, list markers, heading levels and the place of a marker;
it never adds, deletes or swaps a word of his.
Check it before each commit:
`git diff --word-diff=porcelain -- <canvas>` shows the changed words,
and every `-`/`+` word pair must be markup (`#`, `-`, `**`, a marker), never a word of his text.
When a pass sees that his text states something wrong,
it does not fix it:
it attaches `{~~his claim~>the correct claim~~}{>>why<<}`, as the Canvas style says.
Grammar is not this pass's job either:
the grammar fix of the Canvas style runs on its own, at the start of a turn.

## Procedure

1. **Clean-tree check** — `git status --porcelain`.
   If it is not empty, stop and ask the user to commit:
   a pass that starts on a dirty tree mixes his edits into a commit he may revert.
2. **Read the rules** — the Canvas style (`output-styles/canvas.md` beside this skill) and the semantic-feed rule of the repo `CLAUDE.md`, when there is one.
3. **Read the history** — `git log -p --follow -- <canvas>`.
   Find the commits where the user changed only the layout:
   how he indents a thread, where he puts a marker, how he breaks a line.
   His own edits are the best signal of what reads well to him;
   where they disagree with the style, follow his edits and name the difference in the commit body.
4. **Run 2–3 passes**, each through one lens, one commit each:
   - threads: each answer under its point, `AA:` entries 4 spaces deeper, one blank line between voices;
   - markers: a remark on specific words becomes CriticMarkup on those words, a remark on a whole point a `???` under it;
   - lines: semantic-feed breaks, the threshold of the Canvas style, on every line — his and the `AA:` entries alike, since he reads both;
   - headings: one heading level per topic, the same level for sibling topics.
   Skip a lens with nothing to do;
   do not make a commit to make a pass.
   `$ARGUMENTS` picks or adds a lens.
5. **Commit each pass** — subject `canvas: format <lens>`,
   body one line on the rule applied, and the difference from the style when step 3 found one.
6. **Report** in the chat: the commits, one line each, and the revert command for the whole run: `git revert --no-edit <first>^..<last>`.

## Related

- `/gi:canvas-tidy` — cuts spent content; run it before this skill, so the format pass does not lay out text tidy then deletes.
