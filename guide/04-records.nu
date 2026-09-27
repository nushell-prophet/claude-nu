# Chapter 4: raw records, and per-session numbers.
# When no command models what you need, `records` gives every line of the
# transcript, one row each, the whole line under `record`. Past agents reached
# for `jq -c 'select(.type == "system")'` here; it is `where type == system`.
# Refresh the outputs: `dotnu embeds-update guide/04-records.nu`

use ../claude-nu
use fixture-home.nu
fixture-home

# What the transcripts of this project hold.
claude-nu records
| get type
| uniq --count
| sort-by count --reverse
| print $in
# => ╭────┬───────────────────────┬───────╮
# => │  # │         value         │ count │
# => ├────┼───────────────────────┼───────┤
# => │  0 │ assistant             │   683 │
# => │  1 │ user                  │   476 │
# => │  2 │ attachment            │   104 │
# => │  3 │ ai-title              │    86 │
# => │  4 │ file-history-snapshot │    86 │
# => │  5 │ last-prompt           │    83 │
# => │  6 │ queue-operation       │    78 │
# => │  7 │ system                │    67 │
# => │  8 │ permission-mode       │    53 │
# => │  9 │ agent-name            │    16 │
# => │ 10 │ custom-title          │     7 │
# => ╰────┴───────────────────────┴───────╯

# The fields one record type carries, to learn a shape before querying it.
claude-nu records
| where type == permission-mode
| first
| get record
| columns
| print $in
# => ╭───┬────────────────╮
# => │ 0 │ type           │
# => │ 1 │ permissionMode │
# => │ 2 │ sessionId      │
# => ╰───┴────────────────╯

# The permission modes each session ran in.
claude-nu records
| where type == permission-mode
| group-by session
| items {|s rows| {session: ($s | str substring 0..8) modes: ($rows.record.permissionMode | uniq | str join ', ')} }
| print $in
# => ╭───┬───────────┬─────────────────────────╮
# => │ # │  session  │          modes          │
# => ├───┼───────────┼─────────────────────────┤
# => │ 0 │ b9ce8986- │ auto                    │
# => │ 1 │ ae3bbbf7- │ auto                    │
# => │ 2 │ b370af1e- │ auto                    │
# => │ 3 │ 99bf0e5b- │ bypassPermissions, plan │
# => ╰───┴───────────┴─────────────────────────╯

# The regex runs over the record as JSON, the text the rg pre-filter reads.
claude-nu records '"permissionMode":"plan"' | get type | uniq --count | print $in
# => ╭───┬─────────────────┬───────╮
# => │ # │      value      │ count │
# => ├───┼─────────────────┼───────┤
# => │ 0 │ permission-mode │     4 │
# => ╰───┴─────────────────┴───────╯

# Per-session numbers are `sessions --columns`. `tool_counts` names every tool
# that was called; `token_usage` counts each reply once, though Claude Code
# writes one record per content block with the usage repeated on each.
claude-nu sessions --session '99bf0e5b' --columns tool_counts | get 0.tool_counts | print $in
# => ╭─────────────────┬────╮
# => │ Bash            │ 29 │
# => │ Edit            │ 11 │
# => │ Read            │ 9  │
# => │ Agent           │ 2  │
# => │ ToolSearch      │ 2  │
# => │ ExitPlanMode    │ 1  │
# => │ Write           │ 1  │
# => │ AskUserQuestion │ 1  │
# => ╰─────────────────┴────╯

claude-nu sessions --session '99bf0e5b' --columns token_usage,assistant_msg_count | select assistant_msg_count token_usage.output_tokens | print $in
# => ╭───┬─────────────────────┬───────────────────────────╮
# => │ # │ assistant_msg_count │ token_usage.output_tokens │
# => ├───┼─────────────────────┼───────────────────────────┤
# => │ 0 │                  61 │                     46805 │
# => ╰───┴─────────────────────┴───────────────────────────╯

# How many columns `--all-columns` computes; `--columns` tab-completes their names.
claude-nu sessions --session '99bf0e5b' --all-columns | columns | length | print $in
# => 38

# A session as markdown, to read or to archive next to the code.
claude-nu sessions --session '99bf0e5b'
| claude-nu export-session
| lines
| first 8
| print $in
# => ╭───┬───────────────────────────────────────────────╮
# => │ 0 │ ---                                           │
# => │ 1 │ date: 2026-05-06                              │
# => │ 2 │ session: 99bf0e5b-212c-4891-abb2-6bc585af2ea0 │
# => │ 3 │ summary: automate-ots-promotion-workflow      │
# => │ 4 │ ---                                           │
# => │ 5 │                                               │
# => │ 6 │                                               │
# => │ 7 │ # Automate Ots Promotion Workflow             │
# => ╰───┴───────────────────────────────────────────────╯
