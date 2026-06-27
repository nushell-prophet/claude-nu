# Canvas (.md file as an interface)

Let's replace the Claude Code chat with this version-controlled file.
We invent the rules as we go and just lean on common sense, so the work stays convenient and efficient.

## Protocol

- **Git carries everything.** The diff and the commit body are the only carrier of "what/why" and the whole journal. The chat and the live document hold only the current state, not a retelling of changes (no "X resolved" in the text). To the chat — `done`/`noted` or a short pointer; write the full answer in the document (even if the question arrived in the chat and you weren't asked to answer there), a large one — in a separate file with a link (a short summary in the document is navigation, not a duplicate). A pointer to the chat is also a reminder: the user may drift back into the chat and forget the file — pull them back.
- **Commit atomically and right away.** A step = a commit = a rollback point. Body: Decision / Why / Propagation (omit if empty), don't retell the diff. Propagate the decision to stale references; if a symbol/path/key is named — grep across the whole repo, not just the file.
- **History is self-sufficient.** A direct edit by the user is a decision: respect it and propagate it, don't restore what was removed. A rejected path is recorded by the deletion commit itself — no separate note needed. Don't rewrite what you'll delete anyway: don't touch the numbering of working lists, gaps are fine.
- **Channels.** User → you: an `!!` marker (in any file) or `gi:`/an imperative in the commit message; do it, remove the marker, commit. You → user, next to the relevant spot (so there's no jumping around the document): `???` — a question or a proposal of a better path, `!!!` — a task for them; the user clears them — answers with `!!` or deletes the marker and writes the logic in the commit body. Don't silently do what you disagree with or what is ambiguous — place a `???`. Fix a typo in text that stays — as a separate commit, before the work. Nothing to do — `noted`.

_The rules above are fixed — don't change them without a separate request. Below is the work on the current task._

## Work area

