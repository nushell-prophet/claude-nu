---
status: done
created: 20260510-2002
updated: 20260510
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

## Completed

- `--tools` flag for `export-session` (commit 4d9c7c8). Renders
  `tool_use` and `tool_result` blocks as one-line markdown blockquote
  placeholders interleaved with text:
  - `> [<ToolName>: <summary>]` for `tool_use`, where summary picks the
    most informative scalar field from input (`command`, `file_path`,
    `path`, `pattern`, `query`, `url`, `skill`, `subagent_type`,
    `description`) and falls back to compact NUON. Whitespace is
    collapsed to single spaces and the line is truncated to ~120 chars
    with an ellipsis.
  - `> [result: <n> chars]` (or `> [result error: <n> chars]`) for
    `tool_result`, summarising payload length without dumping it.
- `--include-thinking` flag for `messages` (commit 694ed3b). Surfaces
  thinking-only assistant turns that the visible-text filter would
  otherwise drop. Each thinking block is rendered with a `[thinking]`
  prefix so it stays distinguishable from regular text. Implemented via
  a parallel helper `extract-text-with-thinking`; the original
  `extract-text-content` contract is preserved for other callers
  (parse-session etc.).
- Defaults are UNCHANGED for both flags (additive only).
- `--include-system` expansion was DEFERRED per orchestrator
  instruction — it would couple to parser-format work covering the new
  top-level record types (`last-prompt`, `queue-operation`,
  `ai-title`).
