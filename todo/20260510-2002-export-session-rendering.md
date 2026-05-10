---
status: draft
created: 20260510-2002
updated: 20260510-2002
---

# Initial request (only the user can edit this section)

Audit on 2026-05-10 found that `export-session` and `messages` silently
drop content blocks that users likely expect to see. Decide what to render
and fix.

# LLM agent updates section

## Findings

These are behavioral choices rather than crashes — confirm intent before
changing.

### `export-session` drops tool_use / tool_result blocks

`export-session` returns a record `{session, date, topic, markdown}` and
`save-markdown` writes the markdown body. The body contains only `text`
turns from user/assistant — every `tool_use` and `tool_result` block is
silently dropped. For a typical 2.3 MB session the markdown out is 32 KB
and contains no record of the model's actions.

If exports are intended as conversation transcripts, surfacing a one-line
placeholder per tool call (e.g. `> [Bash: cat foo.txt]` or
`> [Read: src/main.rs]`) would preserve the narrative without bloating the
file. Full tool input/output rendering is a separate, heavier option.

### `messages` drops thinking-only assistant turns

`extract-text-content` only matches `type == "text"`. Assistant messages
that contain only `thinking` blocks (with no text) silently disappear from
`messages` output — 18/109 assistant messages in one cozy sample. May be
intentional (thinking is internal), but currently invisible to the user.

### `--include-system` is narrow

`messages -u` only widens the `type ∈ {user, assistant}` filter; it never
lets you grep across the new `last-prompt` / `queue-operation` / `ai-title`
top-level records. Coordinates with the parser-format todo (which also
addresses these record types).

## Implementation plan

- [ ] Decide rendering policy for `export-session` tool blocks: drop /
      one-line placeholder / full input+output. Recommend one-line
      placeholder as default with a flag for full rendering.
- [ ] Decide whether `messages` should expose thinking-only turns (perhaps
      under a `--thinking` flag).
- [ ] If keeping `--include-system`, expand it to cover the new top-level
      record types — or rename / split flags.
- [ ] Add fixtures and tests pinning the chosen behaviors.

## Affected files

- `claude-nu/commands.nu` — `export-session`, `messages`,
  `extract-text-content`
- `tests/test_commands.nu`
