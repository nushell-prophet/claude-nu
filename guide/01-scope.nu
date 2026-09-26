# Chapter 1: which sessions a command reads.
# Every claude-nu command reads the scope piped into it; with no input, the
# current project. So the first question of any search is what to pipe in.
# Refresh the outputs: `dotnu embeds-update guide/01-scope.nu`
# The store here is the test fixtures (see fixture-home.nu), five sessions of
# one project, so the numbers are small and the same on every run.

use ../claude-nu
use fixture-home.nu
fixture-home

# Every project in ~/.claude/projects, newest first. `count` is its top-level
# sessions; `path` is the store directory, so a row pipes straight on.
claude-nu projects | select name count | print $in
# => ╭───┬───────────────────────────────┬───────╮
# => │ # │             name              │ count │
# => ├───┼───────────────────────────────┼───────┤
# => │ 0 │ ai-sandbox-dev-container/cozy │     5 │
# => ╰───┴───────────────────────────────┴───────╯

# The whole machine: pipe `projects` in. Past agents globbed the store in
# python or bash; a project row stands for its top-level sessions.
# Not `sessions --all-projects | ...`: that parses every file for the session
# columns before the next command reads any of them (40 s against 2.4 s).
claude-nu projects | claude-nu messages 'docker' | length | print $in
# => 10

# The sessions of the current project, with the columns you ask for.
# A datetime renders as "4 months ago"; `format date` keeps these outputs stable.
claude-nu sessions --columns session_id,first_timestamp,turn_count | select session_id first_timestamp turn_count | update first_timestamp { format date '%F %R' } | print $in
# => ╭────┬───────────────────────────────────────┬───────────────────┬─────────────╮
# => │  # │              session_id               │  first_timestamp  │ turn_count  │
# => ├────┼───────────────────────────────────────┼───────────────────┼─────────────┤
# => │  0 │ b9ce8986-5d19-4ff5-9285-e0ed06464b6c  │ 2026-05-10 14:18  │          24 │
# => │  1 │ ae3bbbf7-0554-45f7-9653-6ca09689be50  │ 2026-05-09 18:53  │          12 │
# => │  2 │ b370af1e-c96f-46a2-a3fe-66b16f38bc03  │ 2026-05-09 18:14  │          15 │
# => │  3 │ 99bf0e5b-212c-4891-abb2-6bc585af2ea0  │ 2026-05-06 16:56  │           6 │
# => │  4 │ ef27ae6d-c8d1-4ce8-b0ff-bcfff3954193  │ 2026-05-06 01:09  │          11 │
# => ╰────┴───────────────────────────────────────┴───────────────────┴─────────────╯

# `size` and `modified` come from the file listing, so asking for only these
# opens no transcript. `modified` is the file mtime, the clock `--since` and
# `--until` compare; it can run hours past `last_timestamp`.
claude-nu sessions --columns size,modified | select size modified | update modified { format date '%F %R' } | print $in
# => ╭───┬──────────┬──────────────────╮
# => │ # │   size   │     modified     │
# => ├───┼──────────┼──────────────────┤
# => │ 0 │   1.3 MB │ 2026-05-10 20:14 │
# => │ 1 │ 936.6 kB │ 2026-05-09 19:48 │
# => │ 2 │ 651.8 kB │ 2026-05-09 18:53 │
# => │ 3 │ 584.7 kB │ 2026-05-06 22:18 │
# => │ 4 │ 552.9 kB │ 2026-05-06 01:31 │
# => ╰───┴──────────┴──────────────────╯

# `projects` rows carry `size` too: the top-level transcripts that `count` counts.
claude-nu projects | select name count size | print $in
# => ╭───┬───────────────────────────────┬───────┬────────╮
# => │ # │             name              │ count │  size  │
# => ├───┼───────────────────────────────┼───────┼────────┤
# => │ 0 │ ai-sandbox-dev-container/cozy │     5 │ 4.0 MB │
# => ╰───┴───────────────────────────────┴───────┴────────╯

# "What was I doing then" wants record time, not mtime. `--active-since` and
# `--active-until` keep a session whose span, first to last timestamp,
# overlaps the window. Here ae3bbbf7 started inside the window, but it was
# written to last at 19:48, so the mtime window drops it.
claude-nu sessions --active-since 2026-05-09T18:40:00Z --active-until 2026-05-09T19:00:00Z --columns session_id | get session_id | print $in
# => ╭───┬──────────────────────────────────────╮
# => │ 0 │ ae3bbbf7-0554-45f7-9653-6ca09689be50 │
# => │ 1 │ b370af1e-c96f-46a2-a3fe-66b16f38bc03 │
# => ╰───┴──────────────────────────────────────╯

claude-nu sessions --since 2026-05-09T18:40:00Z --until 2026-05-09T19:00:00Z --columns session_id | get session_id | print $in
# => ╭───┬──────────────────────────────────────╮
# => │ 0 │ b370af1e-c96f-46a2-a3fe-66b16f38bc03 │
# => ╰───┴──────────────────────────────────────╯

# One session, by the first characters of its id — the way notes quote it.
# Several matches are an error that lists them.
claude-nu sessions --session '99bf0e5b' --columns turn_count,git_branch | select turn_count git_branch | print $in
# => ╭───┬────────────┬────────────╮
# => │ # │ turn_count │ git_branch │
# => ├───┼────────────┼────────────┤
# => │ 0 │          6 │ main       │
# => ╰───┴────────────┴────────────╯

# Subagent transcripts are left out unless asked for. Each row names its parent.
claude-nu sessions --subagents --columns turn_count | where parent_session_id != null | select parent_session_id turn_count | print $in
# => ╭───┬──────────────────────────────────────┬────────────╮
# => │ # │          parent_session_id           │ turn_count │
# => ├───┼──────────────────────────────────────┼────────────┤
# => │ 0 │ b370af1e-c96f-46a2-a3fe-66b16f38bc03 │          1 │
# => ╰───┴──────────────────────────────────────┴────────────╯

# A subagent is named `agent-<id>` in `messages` and `tool-calls` rows, and
# that name is a selector too, so its rows pipe back in.
claude-nu sessions --session agent-c2f7cc67968140b5a --columns turn_count | get parent_session_id | print $in
# => ╭───┬──────────────────────────────────────╮
# => │ 0 │ b370af1e-c96f-46a2-a3fe-66b16f38bc03 │
# => ╰───┴──────────────────────────────────────╯

# A plain list is a scope as well: paths, directories, ids, id prefixes.
# Quote an id prefix: `99bf0e5b` alone parses as a file size.
['99bf0e5b' 'ef27ae6d'] | claude-nu messages | get session | uniq --count | print $in
# => ╭───┬──────────────────────────────────────┬───────╮
# => │ # │                value                 │ count │
# => ├───┼──────────────────────────────────────┼───────┤
# => │ 0 │ 99bf0e5b-212c-4891-abb2-6bc585af2ea0 │     6 │
# => │ 1 │ ef27ae6d-c8d1-4ce8-b0ff-bcfff3954193 │    11 │
# => ╰───┴──────────────────────────────────────┴───────╯

# Every row a command returns carries `session`, so any result is a scope for
# the next command: here, the tool calls of the sessions where "rename" was said.
claude-nu messages 'rename' | claude-nu tool-calls | length | print $in
# => 166
