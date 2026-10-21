---
name: canvas-format
description: Experimental. Work on the aesthetics and usability of a canvas — reformat it for reading without changing what it says — threads and indents, marker placement, semantic-feed line breaks, headings — in a few passes, one commit each, learned from the Canvas style and from the user's own formatting edits in the canvas history. Use when the user says "format the canvas", "canvas-format", "отформатируй канвас", "причеши форму", "make it readable", or asks for layout changes only. For cutting spent content, use `gi:canvas-tidy` instead.
argument-hint: [canvas path, lens or instructions]
allowed-tools: Bash(git *), Bash(rg *), Read, Edit, Write, Grep, Glob
context: fork
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

Do the whole run yourself.
He does not read the run, only the result:
every check below is for you,
and none of it goes into the report.

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

**The agent's lines are yours to reshape.**
`git blame` tells whose a line is.
An `AA:` entry, a marker or a legend that an agent wrote may be moved, joined with its point, or turned into another marker;
its claims stay.

## Procedure

1. **Find the canvas** — `$ARGUMENTS` when it names a path, else `$GI_CANVAS`.
   With neither, stop and report that the canvas is unknown.
2. **Clean-tree check** — `git status --porcelain`.
   If it is not empty, stop and report it:
   a pass that starts on a dirty tree mixes his edits into a commit he may revert.
3. **Read the rules** — the Canvas style (`output-styles/canvas.md` in the plugin directory of this skill) and the semantic-feed rule of the repo `CLAUDE.md`, when there is one.
4. **Read the history** — `git log -p --follow -- <canvas>`.
   Find the commits where the user changed only the layout:
   how he indents a thread, where he puts a marker, how he breaks a line.
   His own edits are the best signal of what reads well to him;
   where they disagree with the style, follow his edits and name the difference in the commit body.
   An agent's layout is not his signal, even when he asked for the marker kind:
   a request for CriticMarkup is not a request for where it stands.
5. **Look** — read the canvas from the top, as one screen of Helix shows it.
   Name to yourself the three things that slow the reader most.
   They decide the passes;
   the lenses below are where to look, not a list to tick.
6. **Run the passes** that remove those obstacles, one lens and one commit each:
   - threads: each answer under its point, `AA:` entries 4 spaces deeper, one blank line between voices;
   - markers: every `{>>` with no `{==…==}` or `{~~…~~}` right before it is a defect
     (`rg --line-number '\{>>' <canvas>` finds them):
     attach it to the words it is about, or turn it into a `???` under its point when it is about the whole point;
     a legend that names a marker no longer in use goes;
   - lines: semantic-feed breaks, the threshold of the Canvas style, on every line — his and the `AA:` entries alike, since he reads both;
     a CriticMarkup span never breaks across lines, and a comment too long for one line belongs in a `???`;
   - headings: one heading level per topic, the same level for sibling topics.
   Skip a lens only after its check found nothing;
   do not make a commit to make a pass.
   `$ARGUMENTS` picks or adds a lens.
7. **Commit each pass** — subject `canvas: format <lens>`,
   body one line on the rule applied, and the difference from the style when step 4 found one.
8. **Report** in two lines at most: the commits, and the revert command for the whole run, `git revert --no-edit <first>^..<last>`.

## Related

- `/gi:canvas-tidy` — cuts spent content; run it before this skill, so the format pass does not lay out text tidy then deletes.
