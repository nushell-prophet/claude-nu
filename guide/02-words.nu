# Chapter 2: the user's own words.
# The most common reason past agents parsed transcripts: find what the user
# said, with an address back to where it was said, and read the turns around it.
# In python that was json.loads over every line, keep type == "user", drop the
# tool results and the wrappers Claude Code writes itself — every agent wrote
# its own copy of that filter. `messages` is that filter.
# Refresh the outputs: `dotnu embeds-update guide/02-words.nu`

use ../claude-nu
use fixture-home.nu
fixture-home

# Search by regex. Each row carries `uuid`, the record's own id: the address.
claude-nu messages 'rename'
| select message uuid
| update message { lines | first | str substring 0..40 }
| update uuid { str substring 0..8 }
| print $in
# => ╭───┬───────────────────────────────────────────┬───────────╮
# => │ # │                  message                  │   uuid    │
# => ├───┼───────────────────────────────────────────┼───────────┤
# => │ 0 │   Vendored: nu-multiproof/nu-multiproof   │ e81f8ee1- │
# => │ 1 │ I ran the command, but I dropped --rename │ 2534ae26- │
# => │ 2 │ just make rename with our defaults, but a │ 136029ba- │
# => │ 3 │ 1. fix wit git mv, 2. reimplement the com │ 96c45d2e- │
# => ╰───┴───────────────────────────────────────────┴───────────╯

# The turns around a hit: `--context N` adds the N rows before and after each
# hit in its session, like `rg --context`, and a `hit` column marks the match.
# With `--include-responses` the assistant reply is a neighbour too.
claude-nu messages 'dropped --rename' --context 1 --include-responses
| select hit kind message
| update message { lines | first | str substring 0..45 }
| print $in
# => ╭─────┬─────────┬────────────┬─────────────────────────────────────────────────╮
# => │   # │   hit   │    kind    │                     message                     │
# => ├─────┼─────────┼────────────┼─────────────────────────────────────────────────┤
# => │   0 │ false   │ response   │ Implementation done. All 32 tests pass.         │
# => │   1 │ true    │ typed      │ I ran the command, but I dropped --rename and   │
# => │   2 │ false   │ response   │ Honest answer: **you wouldn't**. The flag was   │
# => ╰─────┴─────────┴────────────┴─────────────────────────────────────────────────╯

# Every row carries `kind`: `typed` is what the user wrote; a `!` command is
# `bash-input` and what it printed `bash-output`. Past agents guessed these
# from the text, but a rendered `!git log` reads like a pasted one.
# `system` and `response` rows come only with the flags that keep them.
claude-nu messages --include-system --include-responses | get kind | uniq --count | print $in
# => ╭───┬─────────────┬───────╮
# => │ # │    value    │ count │
# => ├───┼─────────────┼───────┤
# => │ 0 │ system      │    34 │
# => │ 1 │ typed       │    66 │
# => │ 2 │ response    │   127 │
# => │ 3 │ bash-input  │     1 │
# => │ 4 │ bash-output │     1 │
# => ╰───┴─────────────┴───────╯

# So the user's own words are one `where`.
claude-nu messages | where kind == typed | length | print $in
# => 66

# A time window is per message, by its own timestamp.
# Rows come session by session, chronological inside each; `sort-by timestamp`
# gives one timeline.
claude-nu messages --since 2026-05-09T18:40:00Z --until 2026-05-09T19:00:00Z
| select timestamp message
| update timestamp { format date '%T' }
| update message { lines | first | str substring 0..40 }
| print $in
# => ╭───┬───────────┬───────────────────────────────────────────╮
# => │ # │ timestamp │                  message                  │
# => ├───┼───────────┼───────────────────────────────────────────┤
# => │ 0 │ 18:54:04  │ orchestrate agents to implement and check │
# => │ 1 │ 18:54:09  │ orchestrate agents to implement and check │
# => │ 2 │ 18:41:20  │ commit                                    │
# => │ 3 │ 18:42:46  │ ask @"general-purpose (agent)" to be the  │
# => │ 4 │ 18:44:56  │ rewrite the todo with House's plan        │
# => │ 5 │ 18:47:43  │ commit                                    │
# => │ 6 │ 18:49:50  │ ask @"general-purpose (agent)" to check t │
# => │ 7 │ 18:52:53  │ commit                                    │
# => ╰───┴───────────┴───────────────────────────────────────────╯

# How much the user said per session, the census past agents built with jq.
claude-nu messages
| group-by session
| items {|s rows| {session: ($s | str substring 0..8) messages: ($rows | length) chars: ($rows.message | str length | math sum)} }
| print $in
# => ╭───┬───────────┬──────────┬───────╮
# => │ # │  session  │ messages │ chars │
# => ├───┼───────────┼──────────┼───────┤
# => │ 0 │ b9ce8986- │       24 │ 10066 │
# => │ 1 │ ae3bbbf7- │       12 │ 11364 │
# => │ 2 │ b370af1e- │       15 │  4705 │
# => │ 3 │ 99bf0e5b- │        6 │   452 │
# => │ 4 │ ef27ae6d- │       11 │  1366 │
# => ╰───┴───────────┴──────────┴───────╯

# What `messages` leaves out, by default: tool results, the wrappers around
# slash commands and hooks, `[Request interrupted by user]`, and records a
# resumed session copied from its parent (they keep the parent's uuid, and
# come back once). `--include-system` keeps the wrappers.
claude-nu messages --include-system | length | print $in
# => 102

claude-nu messages | length | print $in
# => 68

# The assistant's words are `--include-responses`, rows with a `role`.
# "Where did Claude explain it" is a search over those.
claude-nu messages 'tree-hash' --include-responses | where role == assistant | length | print $in
# => 4
