---
name: git-intent-readback
description: Before acting on a block of answers the user just committed, restate each one in your own words, name what is ambiguous, unanswered, or contradictory, and stop. Use when the user says "readback", "check my answers", "проверь мои ответы", "не бросайся выполнять", "я ответил на вопросы", or has just committed answers to questions you asked.
argument-hint: [N commits, or scope]
allowed-tools: Bash(git *), Read, Edit, Grep, Glob
---

You asked, the user answered in the document and committed.
The default reflex is to start working at once — and that reflex is the failure.
An answer can skip a question, carry two readings where you silently picked one, or contradict something already decided.
Work built on a wrong reading is expensive to undo, and the user learns about it only after the code exists.

The fix is a **readback** (an aviation term: the pilot repeats the clearance back before flying it).
You write what you understood — in your own words — into the document; the user reads the diff and repairs a wrong reading with one edit.
Copying their words back proves nothing; only a paraphrase can expose a misread.
That is the point of this skill: it catches not the ambiguity you noticed, but the one you didn't.

## The pass

Every question you asked lands in exactly one bucket.
Nothing is dropped silently — a question you forgot you asked is the same failure as an answer you misread.

- **Clear** — one reading only.
  Write that reading back, plus the consequence: what you will *do* because of it.
  The consequence is where the misread usually shows, not the sentence.
- **Ambiguous** — two or more readings.
  Don't pick.
  Enumerate them (A / B), recommend one, and place a `???` at the spot.
  A closed question is far cheaper for the user to answer than an open one.
- **Unanswered** — the user answered four of six.
  Say which two, at the spot they belong.
- **Conflicting** — the answer collides with another answer, with the document, or with a decision already in git history or in the code.
  Name the collision; never reconcile it on your own.
  A decision in git history is named by its commit's short `Change-Id` (the first 8 characters) where it carries one, by sha only where the repo stamps none — the id survives the rebases the sha does not.

Completeness runs both ways.
An answer can open a decision nobody asked about yet, and your plan for the work can need a choice no answer covers.
Walk the work you are about to do and ask what is still undecided — those gaps go in as `???` too.

Judgment: doubt is cheap here and silence is not.
If you hesitate between *clear* and *ambiguous*, it is ambiguous.

## Procedure

1. **Tree check** — `git status --porcelain`.
   Uncommitted answers are a draft he is still writing: read them back if he pasted them as a `git diff`, and leave your readback uncommitted too; never write over his lines or sweep them into your commit.
   (Same rule as `/git-intent`; `/git-intent-distill` alone still requires a clean tree, because it rewrites the whole file.)
2. **Get the answers** — `git log -p -N -- <doc>` with `N = $ARGUMENTS` (default `1`); `$ARGUMENTS` may instead name a scope or file.
   `git show HEAD~N:<doc>` gives the pre-answer version — that is where your original questions still stand.
   A pasted `git diff` is the same input, uncommitted: the answers are in the paste, and the pre-answer version is `HEAD:<doc>`.
3. **Read the canvas in full** — a session launched by `gi open` was told its canvas path in its own instructions; if you were given no such path, ask which document.
4. **Sort and write.**
   Ambiguous, unanswered, and conflicting go in as `???` next to the relevant spot, per the Canvas protocol.
   At most three `???` per pass, the ones blocking the most work first; the rest wait for the next round (the Canvas cap).
   Clear ones go into one `## Readback` section — one line each — so the user reviews the whole set as a single diff instead of hunting through the file.
5. **Commit** the document alone.
   Subject names the pass; body stays thin — the diff is the content.
6. **Stop.
   Do not start the work.**
   Report one line to chat: `readback in <doc> — N clear, M ambiguous, K unanswered`.

Stop even when nothing is ambiguous.
Confirmation costs the user one word, and it is the only thing standing between a silent misread and a day of wrong work.

## After

The user edits, answers the `???`, commits — then `/git-intent` executes.
The `## Readback` section is spent process material once the work starts: `/git-intent-distill` cuts it into history.

## Related

- `/git-intent` — the execute loop this pass deliberately delays.
- `/git-intent-distill` — removes the spent readback section afterwards.
