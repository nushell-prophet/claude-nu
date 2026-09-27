# Chapter 3: what the agents did, and what came back.
# Past agents walked `message.content[]` for `tool_use` blocks in jq, then
# joined them to `tool_result` blocks by id in python to see what failed.
# `tool-calls` is the first half; `--results` is the join.
# Refresh the outputs: `dotnu embeds-update guide/03-tool-calls.nu`

use ../claude-nu
use fixture-home.nu
fixture-home

# Which tools the agents used in this project, most-called first.
claude-nu tool-calls
| get tool
| uniq --count
| sort-by count --reverse
| first 5
| print $in
# => ╭───┬────────────┬───────╮
# => │ # │   value    │ count │
# => ├───┼────────────┼───────┤
# => │ 0 │ Bash       │   193 │
# => │ 1 │ Edit       │    55 │
# => │ 2 │ Read       │    50 │
# => │ 3 │ TaskUpdate │    28 │
# => │ 4 │ TaskCreate │    14 │
# => ╰───┴────────────┴───────╯

# The regex matches the tool name, then the input rendered as NUON — so a
# string is found whichever field of whichever tool holds it.
claude-nu tool-calls 'AskUserQuestion' | length | print $in
# => 4

claude-nu tool-calls 'docker build'
| select tool input
| update input { to nuon | str substring 0..50 }
| print $in
# => ╭──────┬───────────────┬───────────────────────────────────────────────────────╮
# => │    # │     tool      │                         input                         │
# => ├──────┼───────────────┼───────────────────────────────────────────────────────┤
# => │    0 │ Bash          │ {command: "git add sandbox-toolkit/install/bootstra   │
# => │    1 │ TaskCreate    │ {subject: "Verify PR 2 (Dockerfile builds)", descri   │
# => │    2 │ Bash          │ {command: "command -v docker && (docker buildx buil   │
# => │    3 │ Bash          │ {command: "docker build -t cozy:v1 . 2>&1", descrip   │
# => │    4 │ Monitor       │ {description: "cozy:v1 docker build progress", comm   │
# => │    5 │ Bash          │ {command: "docker build -t cozy:v1 . 2>&1", descrip   │
# => │    6 │ Bash          │ {command: "tail -200 /tmp/claude-1000/-Users-user-g   │
# => │    7 │ Bash          │ {command: "docker buildx build --check /Users/user/   │
# => ╰──────┴───────────────┴───────────────────────────────────────────────────────╯

# `--tool` keeps the calls to one tool, or to any of a list, by exact name.
# The regex is no stand-in: it also finds every call whose input mentions the
# name. `--tool` has its own rg pre-filter over the raw `"name":"<tool>"`, so
# across every project it reads only the files that hold such a call, while a
# `where tool == ...` after the fact parses them all (56 s against 11 s on one
# machine).
claude-nu tool-calls 'Agent' | get tool | uniq --count | print $in
# => ╭───┬───────┬───────╮
# => │ # │ value │ count │
# => ├───┼───────┼───────┤
# => │ 0 │ Edit  │     4 │
# => │ 1 │ Agent │     5 │
# => │ 2 │ Write │     1 │
# => │ 3 │ Bash  │     1 │
# => ╰───┴───────┴───────╯

claude-nu tool-calls --tool Agent | length | print $in
# => 5

# The shell commands of a session, the "bash corpus" past agents rebuilt with jq.
# The nushell MCP tool keeps its command in `input.input`, not `input.command`.
claude-nu tool-calls --tool Bash
| get input.command
| first 3
| each { lines | first | str substring 0..60 }
| print $in
# => ╭─────────┬────────────────────────────────────────────────────────────────────╮
# => │       0 │ git log --oneline -20                                              │
# => │       1 │ ls /Users/user/git/ai-sandbox-dev-container/cozy/                  │
# => │       2 │ wc -l /Users/user/git/ai-sandbox-dev-container/cozy/Dockerfil      │
# => ╰─────────┴────────────────────────────────────────────────────────────────────╯

# What failed, and what it said. `--results` adds `result` and `is_error`,
# joined by the call's `id`; it parses the whole file, so it is off by default.
claude-nu tool-calls --results
| where is_error == true
| select tool result
| update result { lines | first | str substring 0..50 }
| first 3
| print $in
# => ╭────────┬───────────┬─────────────────────────────────────────────────────────╮
# => │      # │   tool    │                         result                          │
# => ├────────┼───────────┼─────────────────────────────────────────────────────────┤
# => │      0 │ Read      │ EISDIR: illegal operation on a directory, read '/Us     │
# => │      1 │ Read      │ File does not exist. Note: your current working dir     │
# => │      2 │ Read      │ File does not exist. Note: your current working dir     │
# => ╰────────┴───────────┴─────────────────────────────────────────────────────────╯

# With `--results` the regex searches the results too: "which session printed
# this", when the words never appeared in a message or a command.
claude-nu tool-calls --results 'No such file' | select tool session | update session { str substring 0..8 } | print $in
# => ╭───┬──────┬───────────╮
# => │ # │ tool │  session  │
# => ├───┼──────┼───────────┤
# => │ 0 │ Bash │ 99bf0e5b- │
# => │ 1 │ Bash │ ef27ae6d- │
# => │ 2 │ Bash │ ef27ae6d- │
# => ╰───┴──────┴───────────╯

# A call that never got a result (interrupted, or the session still running it)
# keeps its row, with null in both columns.
claude-nu tool-calls --results | where result == null | length | print $in
# => 0

# The files an agent edited, and how often.
claude-nu tool-calls --tool [Edit Write]
| get input.file_path
| path basename
| uniq --count | sort-by count --reverse
| first 3
| print $in
# => ╭───┬────────────────────────────────────┬───────╮
# => │ # │               value                │ count │
# => ├───┼────────────────────────────────────┼───────┤
# => │ 0 │ 20260509-180340-separate-script.md │    17 │
# => │ 1 │ bootstrap.nu                       │    13 │
# => │ 2 │ ots.nu                             │     6 │
# => ╰───┴────────────────────────────────────┴───────╯

# The prompts the parent gave its subagents.
claude-nu tool-calls --tool Agent | get input.description | print $in
# => ╭───┬──────────────────────────────────────────────╮
# => │ 0 │ Review feat/dockerfile-thin branch           │
# => │ 1 │ Dr. House review of plan                     │
# => │ 2 │ Verify plan vs user inputs                   │
# => │ 3 │ Research OTS upgrade workflow and provenance │
# => │ 4 │ Design ots promote command implementation    │
# => ╰───┴──────────────────────────────────────────────╯

# `messages` and `tool-calls` are one table per kind, so the order between
# them is lost. `timeline` is one row per content block, in file order: text,
# thinking, tool_use and tool_result, each with `role` and `kind`. `text` holds
# the words, a call's input as NUON, or a result's text; `tool` names the tool
# on both the call and its result.
claude-nu sessions --session '99bf0e5b'
| claude-nu timeline
| first 5
| select role kind tool text
| update text { lines | first | str substring 0..30 }
| print $in
# => ╭─────┬─────────────┬───────────────┬───────┬──────────────────────────────────╮
# => │   # │    role     │     kind      │ tool  │               text               │
# => ├─────┼─────────────┼───────────────┼───────┼──────────────────────────────────┤
# => │   0 │ user        │ text          │       │ I've upgraded the timestamp (ch  │
# => │   1 │ assistant   │ tool_use      │ Bash  │ {"command":"git status && ls","  │
# => │   2 │ user        │ tool_result   │ Bash  │ On branch main                   │
# => │   3 │ assistant   │ tool_use      │ Bash  │ {"command":"ls multiproofs/ mul  │
# => │   4 │ user        │ tool_result   │ Bash  │ multiproofs/:                    │
# => ╰─────┴─────────────┴───────────────┴───────┴──────────────────────────────────╯

# "What did the agent say right before each tool call": a pair of rows.
claude-nu sessions --session '99bf0e5b'
| claude-nu timeline
| window 2
| where $it.0.role == assistant and $it.0.kind == text and $it.1.kind == tool_use
| each {|w| {said: ($w.0.text | lines | first | str substring --grapheme-clusters 0..40) tool: $w.1.tool} }
| first 3
| print $in
# => ╭────────┬───────────────────────────────────────────────┬─────────────────────╮
# => │      # │                     said                      │        tool         │
# => ├────────┼───────────────────────────────────────────────┼─────────────────────┤
# => │      0 │ Short answer: **no documented reglament e     │ ToolSearch          │
# => │      1 │ I'll research the codebase to understand      │ Agent               │
# => │      2 │ Before I design, three scope questions —      │ AskUserQuestion     │
# => ╰────────┴───────────────────────────────────────────────┴─────────────────────╯

# What the user typed as slash commands, as `messages` is what they said.
# Built-ins (/clear, /model ...) are dropped unless `--all`.
claude-nu slash-commands --all
| get command
| uniq --count
| sort-by count --reverse
| print $in
# => ╭───┬─────────────────┬───────╮
# => │ # │      value      │ count │
# => ├───┼─────────────────┼───────┤
# => │ 0 │ /clear          │     2 │
# => │ 1 │ /branch         │     1 │
# => │ 2 │ /exit           │     1 │
# => │ 3 │ /plan           │     1 │
# => │ 4 │ /copy           │     1 │
# => │ 5 │ /remote-control │     1 │
# => ╰───┴─────────────────┴───────╯
