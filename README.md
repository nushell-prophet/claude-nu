# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

> Work in progress — features are added as needed.
> If you use Nushell with Claude Code, you might find something useful here.

## Highlights

- **Search past sessions** — Find what you asked Claude last week with `projects | messages 'pattern'`
- **Session analytics** — See what Claude actually did: files touched, tools called, agents spawned, errors hit
- **Search what the agent ran** — `tool-calls 'pattern'` searches the tool calls themselves, not only what was typed
- **Read a session in order** — `timeline` gives one row per text, thinking, tool call and result, in file order
- **Workflow runs** — `workflows` lists each Workflow tool run: status, duration, error, agents
- **Rank your slash commands** — `slash-commands` counts what you actually invoked, skills and custom commands, built-ins left out
- **Smart session picker** — `claude --resume <TAB>` shows age, size, and summary instead of raw UUIDs
- **Export to markdown** — Keep session history in git with YAML frontmatter
- **Move a project** — `project-move <old> <new>` retargets sessions, permissions and prompt history after you move a directory
- **Try a pipeline** — `claude-nu example <TAB>` picks one of the module's own `@example` pipelines and pastes it into your command line
- **Dynamic script completions** — `nu` completions that parse any .nu script's subcommands at tab-time
- **Claude Code skills** — Opinionated Nushell style guide and completions guide, distributed via [plugin marketplace](https://github.com/nushell-prophet/nushell-skills)

## Installation

### Requirements

- [Nushell](https://www.nushell.sh/)
- [Claude Code](https://claude.ai/code) CLI

### Setup

Add to your `config.nu`:

```nushell no-run
# From the repo directory (or use full paths like ~/git/claude-nu)
use claude-nu
```

## Commands

### `claude-nu messages` (search)

Extract user messages from Claude Code session files — and search them: with a regex, every match comes back with its `session` column, a pipeline-safe selector you can drill into.

```nushell no-run
claude-nu messages              # Every message of the current project
claude-nu messages 'pattern'    # ...matching a regex — the project-wide search
claude-nu projects | claude-nu messages 'pattern' # ...across every project: each project row stands for its top-level sessions
claude-nu sessions --last | claude-nu messages # Just the current session
claude-nu sessions --session <uuid|name> | claude-nu messages # A named one (tab-completable; name = what /rename or `claude --name` set)
claude-nu messages 'pattern' | claude-nu export-session # Drill matched sessions into markdown
claude-nu messages --since 1wk  # ...sent in the last week (see The time window)
claude-nu messages 'pattern' --context 2 # ...with the 2 rows before and after each hit
claude-nu messages | where kind == typed # Only what the user typed, without `!` commands or their output
claude-nu messages --include-system # Include system/meta messages
claude-nu messages --raw        # Get raw JSONL records
```

A command handed nothing returns everything at its own level of the current project: `projects` all projects, `sessions` the project's sessions, `messages` its messages.
Narrowing is a scope to the left of the pipe, and selection lives in `sessions` alone — so one session, a whole project, or every project is the same command with a different scope in front of it.

Given a regex, `messages` pre-scans the raw JSONL with ripgrep and only parses the sessions that can match; the real regex is then applied to the extracted text.
A pattern that leans on a line anchor or a JSON-escaped character can hide from that raw scan — `--no-rg` skips it and matches everything in-engine.
Use `find` for filtering a `sessions` table you already have on screen.

For every project, scope with `projects`, not `sessions --all-projects`: both name the same top-level sessions, but `sessions` parses every file for its own columns first — 40 s against 2.4 s for one search over this machine.

Rows come session by session — newest session first, chronological inside each — not as one merged timeline.
A resumed or forked session repeats its parent's records under the same `uuid`; `messages`, `tool-calls`, `slash-commands` and `records` keep one copy, the one in the session listed last — by default the least recently active, usually the parent where it was first written — so a resumed conversation is not counted twice.

**Output:**
- `message` — User message content
- `timestamp` — When message was sent
- `uuid` — The record's own id: its address inside the session
- `kind` — What the row is: `typed`, `bash-input` (a `!` command), `bash-output` (what it printed), `system` (only with `--include-system`) or `response` (only with `--include-responses`)
- `session` — Session UUID, the selector to pipe onward
- `project` — Project directory the session belongs to, encoded (`/` turned into `-`) — a display name, not a real path
- `project_name` — The same project, readable: its `cwd`'s last two path segments, same form as `projects.name`. `""` when the session carries no `cwd`

`--include-responses` adds `role`; `--context` adds `hit`; `--raw` replaces `message` with the raw record's `type` and fields.

**Why `kind`.**
The rendered text cannot tell a `!git log` from a `git log` output the user pasted: both become the same fenced block.
So the kind is read from the raw record — `isMeta`, `isCompactSummary` and the wrapper tags — and the user's own words are `where kind == typed`.
An editor selection stays `typed`, because most such messages also carry the user's own words.

**The turns around a hit.**
`--context N` needs a regex.
With each hit it returns the N rows before and after it in the same session, like `rg --context`, and `hit` is true on the rows the regex matched.
A row that two windows share comes back once.
The neighbours come from the same rows the other flags select, so with `--include-responses` the reply before a prompt is a neighbour.
`--since`/`--until` cut the rows first, so a returned row is always a hit or the neighbour of a returned hit.

### `claude-nu tool-calls`

What an agent *did*, as `messages` is what was said: one row per tool call.
Scoping and searching work exactly as in `messages` — no input reads every top-level session of the current project, piped session rows narrow it, the regex argument gets the same ripgrep pre-filter over the raw JSONL, and `--no-rg` turns that off.

```nushell no-run
claude-nu tool-calls                       # Every tool call of the current project
claude-nu tool-calls 'claude-nu sessions'  # ...whose input matches a regex
claude-nu projects | claude-nu tool-calls 'npm test' # ...across every project
claude-nu tool-calls --tool Bash --since 1day | get input.command # only the calls to one tool, by exact name
claude-nu tool-calls --tool [Read Edit Write] 'sessions\.nu' # ...or to any of a list, with a regex on top
claude-nu tool-calls --results | where is_error | select tool input result # what failed, and what it said
```

**Output:**
- `tool` — Tool name (`Bash`, `Edit`, `Agent`, an MCP tool's full name, ...)
- `input` — The call's arguments, as the raw record, so you drill in: `get input.command`
- `timestamp` — When the call was made
- `id` — The call's `tool_use` id, which its result names
- `uuid` — The id of the record that holds the call
- `result`, `is_error` — Only with `--results`: the text the tool returned and whether it was an error; `null` for a call with no result yet (interrupted, or still running). The regex then searches the result too
- `session` — Session UUID, the selector to pipe onward
- `project` — Project directory the session belongs to, encoded (`/` turned into `-`) — a display name, not a real path
- `project_name` — The same project, readable: its `cwd`'s last two path segments, same form as `projects.name`. `""` when the session carries no `cwd`

The regex is applied to the tool name and to the whole input as compact JSON, not to one field,
so `tool-calls AskUserQuestion` finds that tool's calls; `--tool` is the exact filter.
JSON, because that is how the raw line holds the input and what the rg pre-filter reads:
`'"command":"git'` matches with and without `--no-rg`,
while a NUON pattern (`command: "git`) matches neither.
Which field holds the interesting string depends on the tool — `command` for Bash, `prompt` for Agent, its own schema for an MCP tool — so a search that had to name the field could only answer "who ran this" for Bash.

**Why `--tool` and not `where tool == ...`.**
The regex cannot stand in for an exact name: `mcp__nushell` also matches every `mcp__nushell__*` tool, and any call whose input mentions the name.
A `where` after the command gets the name right, but only after every file is parsed.
The tool name sits in the raw line as the fixed string `"name":"<tool>"`, so `--tool` gets its own ripgrep pre-filter.
Measured over this machine's whole store for `mcp__nushell__evaluate`: 56 s with the `where`, 11 s with the flag, the same 3868 rows.
It takes one name or a list (`--tool [Bash Read]`); an empty list is an error, since it almost always means an upstream name query found nothing.
`--no-rg` skips this pre-filter too.

**Why this is not a `sessions` column.**
`bash_commands` was the only other window onto agent actions and it reads the Bash tool alone.
Mining this machine's whole session store for `claude-nu` invocations, 82 of the 588 an agent made came through the nushell MCP server and were invisible there.
It also aggregates per session, so a matched command has no timestamp and no row of its own, and the `--columns` path has no ripgrep pre-filter: the same all-projects sweep took 42s through `sessions --columns bash_commands` against 2.4s once ripgrep narrowed the files first.

### `claude-nu records`

Every raw record, one row per JSONL line, for the record types no other command models: system records, hooks, permission modes, attachments, a field that is new in this Claude Code version.
Scoping works as in `messages`; the regex matches the whole record as JSON, the text the ripgrep pre-filter reads: `'"type":"system"'`.
A record a resumed or forked session copied from its parent comes back once, as in `messages`;
a line with no `uuid` is always kept.

```nushell no-run
claude-nu records | get type | uniq --count | sort-by count --reverse  # what the current project's transcripts hold
claude-nu sessions --last | claude-nu records | where type == permission-mode | get record.permissionMode
claude-nu records '"permissionMode":"plan"' | get session | uniq       # regex over the record as JSON, rg pre-filter as in `messages`
```

**Output:**
- `type` — The record's `type` (`user`, `assistant`, `system`, `permission-mode`, ...)
- `uuid` — The record's id; `null` for the types that carry none
- `timestamp` — When it was written; `null` for the types that carry none
- `record` — The whole decoded line
- `session`, `project`, `project_name` — As in `messages`

### `claude-nu timeline`

One row per content block of a session, in file order: text, thinking, tool calls and tool results together.
`messages` and `tool-calls` are one table per kind, so the order between kinds is lost — "the text before a tool call" or "the calls between two prompts" cannot be asked there.
Scoping, the regex with its ripgrep pre-filter, `--no-rg`, `--since`/`--until` and `--include-system` work as in `messages`.

```nushell no-run
claude-nu sessions --last | claude-nu timeline                               # the last session, block by block
claude-nu sessions --last | claude-nu timeline | where is_error == true | select tool text # failed calls, with what they said
claude-nu sessions --last | claude-nu timeline | window 2 | where {|w| $w.0.role == assistant and $w.0.kind == text and $w.1.kind == tool_use } # what the agent said right before each call
```

**Output:**
- `role` — `user` or `assistant`
- `kind` — `text`, `thinking`, `tool_use` or `tool_result`
- `text` — The block's words; for a `tool_use` its input as compact JSON (`{"command":"ls"}`), the form the regex and the rg pre-filter both read; for a `tool_result` the result text
- `tool` — The tool name, on a `tool_use` and, joined by `id`, on its `tool_result`
- `id` — The call's `tool_use` id, on both halves of a call
- `is_error` — Set on a `tool_result` only
- `timestamp`, `uuid` — Of the record that holds the block
- `session`, `project`, `project_name` — As in `messages`

Rows keep file order and are not sorted by time: the blocks of one record share a timestamp, so a sort could only lose the order inside a turn.

### `claude-nu sessions`

Parse session files into structured data.
`--columns` selects what to compute — lazy evaluation, only requested extractions run; the column names tab-complete.

```nushell no-run
claude-nu sessions                                # All sessions in current project (overview columns)
claude-nu sessions ~/other/project                # Sessions from another path
claude-nu sessions --all-projects                 # Every project under ~/.claude/projects
claude-nu sessions --session <uuid|name>          # Single session, by UUID, a unique UUID prefix (`9787e004`), a subagent id (`agent-…`), or the name /rename gave it (tab-completable). An id is looked up in this project first, then in every project; one that names transcripts in two places is an error listing their paths, since only a path can pick one. A piped row with a `project` looks in that project first. A prefix or a subagent id no transcript has is tried as a name
claude-nu sessions --last --columns token_usage   # Most recent session, just the requested column
claude-nu sessions --columns version,cwd,git_branch  # Several columns, comma-separated
claude-nu sessions --all-columns                  # All available columns
claude-nu sessions --since 1wk                    # Active in the last week — see The time window
claude-nu sessions --active-since 2026-08-04 --active-until 2026-08-05 # Open at some point on that day, by record time
claude-nu sessions --all-projects --columns size,modified | sort-by size --reverse # The largest sessions, without reading one
claude-nu sessions --subagents --columns agent_id,agent_type,agent_label | where parent_session_id != null # Which agents ran
```

**Default (overview) columns:**
- `summary` — AI-generated session summary
- `first_timestamp` — Session start time
- `last_timestamp` — Last activity
- `user_msg_count` — Number of user messages
- `user_msg_length` — Total chars typed by user
- `response_length` — Total chars of assistant text
- `agent_count` — Subagents spawned
- `agents` — Subagent info
- `mentioned_files` — @-mentions in user messages
- `read_files` — Files read
- `edited_files` — Files modified by Edit/Write
- `path` — Session file path
- `parent_session_id` — Parent UUID for subagent transcripts

**Additional columns:** request via `--columns name1,name2` (or `--all-columns` for everything).
Any `--columns` selection narrows output to `path`/`parent_session_id` plus the requested columns.

- `user_messages` — List of user message texts
- `session_id` — UUID
- `version` — Claude Code version
- `cwd` — Working directory
- `git_branch` — Branch at session start
- `effort` — Reasoning effort the session ran at
- `models` — Models the session ran on, in first-appearance order; more than one means `/model` was used mid-session
- `bash_commands` — List of bash commands run
- `bash_count` — Number of bash commands
- `skill_invocations` — Skills used
- `tool_errors` — Failed tool calls
- `ask_user_count` — User questions asked
- `plan_mode_used` — Whether plan mode was used
- `tool_counts` — Calls per tool name, most-called first; a tool never called is absent
- `turn_count` — Authored user turns (excludes meta and tool replies)
- `assistant_msg_count` — Assistant messages
- `tool_call_count` — Total tool invocations
- `token_usage` — Token totals (input/output/cache)
- `size` — File size
- `modified` — File mtime: the clock `--since`/`--until` compare. It is not `last_timestamp` — a record without a timestamp written after the last turn moves it, in one project by 73 s to 16 h
- `agent_id` — A subagent transcript's file stem (`agent-<id>`); it joins to the `agents` of `workflows`
- `agent_type` — The subagent's type (`Explore`, `workflow-subagent`, ...), from the `agent-<id>.meta.json` beside it
- `workflow` — The `wf_*` run a workflow agent belongs to
- `agent_label` — The Agent tool's description, or the label a workflow gave its agent (`review:scope`)
- `phase` — The workflow phase the agent ran in

`size` and `modified` come from the file listing, so a selection of only these two opens no session file.
`projects` rows carry `size` too: the sum over the same top-level transcripts that `count` counts.

The five agent columns are null on top-level rows.
A subagent row needs them because its `session_id` is the parent's, and nothing in its records names the agent.
Older meta files carry only `agentType`; then the label and phase come from the run's state file, and an agent the state does not list (an attempt a resumed run replaced) keeps a null label.

### `claude-nu slash-commands`

What you *typed*, as `messages` is what you said and `tool-calls` is what the agent did: one row per slash-command invocation.
Scoping works exactly as in `messages` — no input reads every top-level session of the current project, piped session rows narrow it, `--since`/`--until` cut the window per invocation.

```nushell no-run
claude-nu slash-commands | histogram command   # the commands you use most, sorted, with the share of each
claude-nu projects | claude-nu slash-commands | histogram command # ...across every project
claude-nu slash-commands --all      # keep the built-ins Claude Code handles itself
claude-nu slash-commands | where command == '/land-branch' | select timestamp args
```

`histogram` is the ranking: it sorts by count, keeps the column name, and adds each command's share and a bar.

**Output:**
- `command` — The name as typed, leading slash included (`/land-branch`, `/skill-creator:skill-creator`)
- `args` — What followed the command, `""` when it took none
- `timestamp` — When it was invoked
- `uuid` — The record's own id
- `session` — Session UUID, the selector to pipe onward
- `project` — Project directory the session belongs to, encoded (`/` turned into `-`) — a display name, not a real path
- `project_name` — The same project, readable: its `cwd`'s last two path segments, same form as `projects.name`. `""` when the session carries no `cwd`

**What counts.**
Skills and custom commands.
The built-ins Claude Code handles itself — `/clear`, `/model`, `/exit`, `/usage` and their kin — are housekeeping, not work, and `--all` keeps them in.
Claude Code's own prompt-skills (`/init`, `/simplify`, `/code-review`, `/schedule`) stay counted: the model runs those like any other skill.
The list of built-ins is maintained by hand in `extract.nu`, because the two automatic rules both fail — resolving a name against the installed skills would drop every command since renamed or deleted, and the record's own layout (a built-in written name-first with `<command-args>`, a skill message-first without) tracks the Claude Code version rather than the kind of command.

A command counts under the name it was typed with, so a skill you deleted keeps its history instead of vanishing from it.

A `Skill` tool call is a different question — that is the agent choosing a skill on its own, and it is `tool-calls --tool Skill`.

**Why the transcripts and not `~/.claude/history.jsonl`.**
The history file holds every project at once and cannot be narrowed by a session row, so it could not scope like its siblings.
The one thing it uniquely holds is the built-in commands that never reach the model — which is what the default drops anyway.

### The time window

`--since` and `--until` are on `sessions`, `messages`, `tool-calls` and `slash-commands`.
Each takes a duration meaning *ago* (`--since 1wk`, `--until 3day`), a date (`2026-08-01`), or a `datetime` value — so "what did I do last week" is a flag, not a filter you write afterwards.

What the window is measured against is the row you are asking for.
In `messages`, `tool-calls` and `slash-commands` a row is one message, one call or one invocation, so the window is compared to its own timestamp.
In `sessions` a row is a whole session, timed by its file's mtime — its last activity, the same clock that already orders every listing here.
Deciding the window from a parsed `first_timestamp` instead would have to parse every session to find out which sessions to parse, which is the cost the window exists to avoid.

`--since` also makes the work smaller before any file is opened: a session file untouched since before the bound cannot hold a message after it, so it is skipped unparsed.
Over this repo's own project, `messages` took 1.12s and `messages --since 1day` 0.077s.
`--until` gets no such shortcut — a file written today may have started months ago — so it filters rows after parsing.

**Record time for sessions: `--active-since` and `--active-until`.**
The mtime answers "when was this file last written", not "what was I doing that day".
A session open across the window is missed, and a file touched later by a record with no timestamp counts as active when nothing was said.
So `sessions` has a second pair, on record time: a session is kept when its span, `first_timestamp` to `last_timestamp`, overlaps the window.
They take the same values as `--since`/`--until`.
The cost is a parse of every session in the window.
`--active-since` still skips a file whose mtime is before the bound, because a file's mtime is never earlier than its last record; `--active-until` gets no such shortcut.
The two pairs cannot be mixed: they ask one question on two clocks, and a mixed call answers a window nobody named.

### `claude-nu workflows`

The Workflow tool runs of the scoped sessions, one row per run, read from each session's `workflows/wf_*.json` state files.
Scoping works as in `messages`: no input reads the current project, piped session rows or a `projects` row narrow it, and a piped subagent transcript stands for the session that ran it.

```nushell no-run
claude-nu workflows | where status != completed | select id name status error # runs that did not complete
claude-nu projects | claude-nu workflows | sort-by duration --reverse          # the longest runs, every project
claude-nu workflows | sort-by started | last | get agents | group-by phase     # the agents of the latest run
```

**Output:**
- `id` — The run id (`wf_...`)
- `session` — The session that launched the run
- `status` — `completed`, `failed`, ...; a state with no `status` reads as `failed` when it has an `error`, else `completed` — the rule Claude Code's own reader applies
- `agent_count`, `duration`, `error`, `name`, `phases`, `started`, `summary` — From the state file
- `agents` — `{agent_id, label, phase, state}` per agent the run's progress lists; `agent_id` joins to the `agent_id` column of `sessions --subagents`
- `state_file` — The JSON file the row was read from
- `project`, `project_name` — As in `messages`

**Why the state file and not the agents' `journal.jsonl`.**
The journal holds only started/result pairs, while the state file has the status, the duration, the error and each agent's label and phase.

**Why `state_file` and not `path`.**
A `path` column makes a row a session selector, so piping a run on into `messages` would read the JSON state as a transcript.
`session` already names the session to pipe on.

### `claude-nu export-session`

Export session dialogue to markdown.

```nushell no-run
claude-nu export-session                    # Uses session summary as title
claude-nu export-session "Auth refactor"    # Custom title, used as given
claude-nu sessions --session <uuid|name> | claude-nu export-session # Specific session
claude-nu export-session | save session.md  # Saving is the shell's job
claude-nu export-session --tools            # ...keeping tool calls, each input rendered whole
```

The output is the markdown itself — one string per session, with the session id and date in the YAML frontmatter.
One piped row naming one session gives a bare string;
a table, or a `projects` row, gives a list
— even when the project holds a single session.
Saving is ordinary `save`, not a flag.

Filters out system-generated messages, keeping only user prompts and assistant responses.

**Tool calls.**
They are dropped by default.
`--tools` keeps them, and keeps them whole: each call arrives as a `> [Bash]` header followed by its entire input record in a fenced NUON block.

```nuon
{
  command: "wc -l claude-nu/render.nu && cat claude-nu/render.nu",
  description: "Read render.nu"
}
```

Nothing is cut and nothing is picked.
That is the point of the format: NUON is lossless and reads back with `from nuon`, so a rendered call is still data.
A shell command does arrive with its quotes escaped, and a `Write` of a long file becomes one very long line.

Tool *results* are the exception, and stay a char count: `> [result: 6151 chars]`.
A single `cat` in a working session runs to thousands of characters, so folding results in would bury the dialogue the export exists for.

### `claude-nu project-move`

Point Claude Code's stored state at a project's new location.
Claude keys everything by the absolute project path, so a directory you moved with `mv` leaves its sessions, its permissions and its prompt history stranded under the old name — `claude --resume` in the new place finds nothing.
Both arguments are real paths on disk, not encoded directory names.

```nushell no-run
claude-nu project-move ~/old/proj ~/new/proj --dry-run # report what would change, write nothing
claude-nu project-move ~/old/proj ~/new/proj           # do it
```

It rewrites the four places the path is written, and only those: the sessions directory name under `~/.claude/projects`, the `cwd` field in every session record (subagent transcripts included), every mention of the path as a whole quoted string in `~/.claude.json` — its `projects` key and its `githubRepoPaths` entry — and the `project` field in `~/.claude/history.jsonl`.
One row per artifact touched comes back, with the number of occurrences replaced; `--dry-run` returns the same rows.

It refuses to merge two projects into one: if Claude already has a sessions directory for the new path, or `~/.claude.json` carries the old path and the new one at once, the move stops.
The config check is not cosmetic — the swap is textual, so rewriting the old key when the new one is already there would leave `projects` holding the same key twice, JSON a parser still reads while one project's permissions quietly win.
Only the old path and the new one *together* mean a merge: the new path alone is what a run leaves behind when it dies after the config swap, and a rerun has to finish that move rather than call it a collision.

It also refuses to rename a sessions directory that two projects share.
The encoded name is lossy — `/work/demo` and `/work-demo` both become `-work-demo` — and the rename takes the whole directory, so the other project's transcripts would land under the new name while everything that points at them still says the old path.
When a transcript under the source directory records some other path, the move stops and names the file and the path it found.
A transcript recording the new path is a half-finished rerun, and one recording no path at all is a session that died before its first turn — neither is a second project, and neither stops the move.

**What it does not touch.**
The project directory itself — move that yourself, this command only fixes what Claude wrote about it.
And the old path where it appears inside message texts and tool arguments: those record what happened at the old location, and rewriting them would falsify the transcript.
Projects nested under the old path (git worktrees, for instance) are separate projects with their own state; move each one.

**Why a literal substring swap and not a JSON round trip.**
A session record is a line of JSON we did not author.
Parsing and re-emitting it rewrites every byte of every record — escaping, key order, how numbers are spelled — in order to change one field.
Swapping the exact fragment `"cwd":"<old>"` touches only the bytes that encode the path.
Measured on one real 62-line session: the path occurs 65 times, 45 of them as that fragment.

**Failure behaviour.**
Each file is written through a temp file beside it — seeded by copying the target, so a 0600 `~/.claude.json` does not come back 0644 through the umask — and the rename of the sessions directory comes last.
A run that dies partway therefore leaves the sessions under the old name with some `cwd`s already rewritten, and running the same command again finishes exactly what is left: a file already done reports no occurrences and drops out of the next plan.
That holds at every point of the run, including after the config swap — the last write before the rename — which is why a `~/.claude.json` carrying only the new path is read as unfinished work and not as a second project to merge.
Because `~/.claude.json` is rewritten whole by every running `claude`, its mtime is checked between read and write, turning a lost concurrent save into an error instead of silence.
A session file whose bytes are not valid UTF-8 stops the move before anything is written, rather than being skipped in silence.

### `claude-nu gi`

The gi protocol — where all "what/why" lives in git (the diff and commit body) and the chat carries almost nothing.
It comes in three verbs.
`new` **names a canvas** from a slug and opens it.
`import` **writes a canvas** from a session's dialogue.
`open` **launches** a session bound to one canvas, creating the canvas if it does not exist yet — that launch is the only thing that turns gi on.

Each verb is a real Nushell subcommand, so it carries its own flags and its own `help claude-nu gi <verb>`, and `claude-nu gi <TAB>` completes them.

```nushell no-run
claude-nu gi new plan          # gi-canvas/<date>-plan.md (todo/ when only that exists), the editor to write the task in, then a session bound to it
claude-nu gi new plan --folder notes # ...in another folder
claude-nu gi new plan --no-editor # ...written straight, no editor
claude-nu gi new plan --no-claude-launch # ...and nothing launched: the path comes back instead
claude-nu gi import            # a canvas from the dialogue of the session this runs inside (gi-canvas/<date>-session-<id>.md)
claude-nu gi import <TAB>      # ...or of any session: the picker shows age, size, summary
claude-nu gi import --to notes/x.md # ...at a chosen path
claude-nu gi import --tools    # ...keeping tool calls, each input rendered whole
claude-nu gi import --commit   # ...and commit it
claude-nu gi import --gitignore # ...or keep it out of git
claude-nu gi open              # new canvas (gi-canvas/<date>-canvas-<time>.md) + a session bound to it
claude-nu gi open gi-canvas/plan.md   # ...a named one: created from the template if new, resumed if it already holds a session
claude-nu gi open gi-canvas/plan.md --no-hook # style only, without the Stop-hook floor
claude-nu gi open gi-canvas/plan.md --new-session # start over on it: mint a fresh id, overwrite the recorded one
claude-nu gi open gi-canvas/plan.md --fork # ...or keep it as it is and open a copy (gi-canvas/plan_1.md) on a session of its own
claude-nu gi open gi-canvas/plan.md --dangerously-skip-permissions --model opus # ...any other flag goes straight to `claude`
claude-nu gi                   # { canvas, plugin, style, skills }
```

**The Stop hook** is the hard floor that comes with every bound session: the agent's final chat message must stay small — `done`, a status note, a pointer to where the answer landed — at most 3 line breaks and 480 characters; anything bigger blocks the turn with an instruction to move the answer into the canvas and commit it — the block message names the exact file.
Size is the whole rule: no path is required, because demanding one made a short honest status note ("waiting on the background agent") a violation, which taught the agent to invent a path rather than to write less.
It also blocks any turn ending on `main`/`master`: gi commits are internal working history; they reach a public branch only squash-merged, after finalization.
The character budget is tunable via `GI_HOOK_MAX_LEN`.

**`chat:` is the way out.**
Open your message with `chat:` and that one exchange is off the canvas: the hook lets the turn end with any answer, on any branch, and the style tells the agent to answer in chat and write nothing — no document, no commit.
It is for the questions you ask *about* the work rather than as part of it.
The marker is read from the transcript, from your last authored message, so only you can spend one: a marker the agent could write would be the agent lifting its own floor, which is what the hook exists to prevent.
It covers one turn — the next unmarked message is canvas work again.

**Why activation lives at launch.**
`gi open` hands the gi plugin — the Canvas style and the skills — to `claude --plugin-dir`, passes the style's name and the hook to `claude --settings` (which takes inline JSON, merges with the project's settings rather than replacing them), names the canvas to the agent with `--append-system-prompt`, and sets `$env.GI_CANVAS` in the launch environment, which the hook inherits as a child process.
The path goes to the agent as text and to the hook as an environment variable because an environment variable is not in the model's context: pointing the agent at `$env.GI_CANVAS` cost a shell call per session, and when the agent misremembered the variable's name it read an empty string and started listing directories to find a canvas.
So gi writes nothing at all — no settings file, and nothing inside the repo but the canvas — and there is nothing to switch off afterwards: a plain `claude` in any repo is a plain session, always.
The earlier design put `outputStyle`, the hook, and the canvas path into `.claude/settings.local.json` — repo-wide keys that loaded into *every* session opened there, so a canvas from last week kept shaping unrelated work until you remembered to disable it.
`$env.GI_CANVAS` is also the hook's on/off switch: with no canvas bound it has nothing to enforce and stands down.

A repo can hold as many canvases as you like — each `gi open` binds one session to one file, so parallel canvases never collide.

**One directory.**
gi runs where you are standing: a relative canvas path is read against your cwd, the session starts there, and the path gi prints, hands to the agent, and quotes in a hook message is relative to the same place — so what you read is what you can paste back.
`--root <dir>` moves the whole run there instead.
One thing stays repo-scoped, because it is a property of the repo and not of the canvas: the branch guard reads the repo's branch.
Anchoring the canvas at the git root as well would, inside a monorepo, silently write to the wrong file: run from `mono/sub`, `gi open todo/x.md` would make and bind `mono/todo/x.md` — a second file with the same name as the one you meant.
One consequence to know: a canvas opened from a subdirectory gets its own session store, so `claude-nu sessions` at the repo root needs `--all-projects` to list it.

**Your own `claude` flags.**
`gi open` is `--wrapped`: anything it does not define is forwarded to `claude` untouched, so `--dangerously-skip-permissions`, `--model`, `--append-system-prompt` and the rest work as usual.
Two rules keep the binding honest.
Flags gi sets itself — `--settings`, `--session-id`, `--resume`/`-r`, `--continue`/`-c`, `--fork-session`, `--name`, short forms included — are refused, because a second `--settings` wins over gi's and would carry off the style and the Stop hook, leaving gi silently half on.
And a flag typed where the canvas goes (`gi open --model opus`) is refused too: nushell hands an undeclared leading flag to the positional, so it would otherwise create a canvas named `--model`.
`--dangerously-skip-permissions` is in the signature for that reason — it is the flag most often typed with no canvas named, and being declared it parses in either position.

**One canvas, one session, for life.**
On a canvas with no `session:` in its frontmatter, `gi open` mints the session id itself (`claude --session-id`) and writes it in; on one that already has it, the same command resumes that session (`claude --resume`).
So the same file reopens into the same conversation days later — a canvas is a working document, not a one-sitting scratchpad — and there is no second verb to pick, because the file already says which case it is.
`--new-session` is the way out when that session is gone — deleted, expired, or simply not worth continuing: it mints a fresh id and overwrites the one the canvas records, naming the id it drops as it goes.
The launch also passes `--name <canvas>`, which puts the canvas in the prompt box, the `/resume` picker, and the terminal title, so a window says which canvas it belongs to.

**Forking a canvas.**
`--fork` is the other way out of "one canvas, one session", and the opposite of `--new-session`: instead of overwriting the id the canvas records, it copies the file to the next free name in its series — `plan.md` → `plan_1.md`, a fork of `plan_1.md` → `plan_2.md` — and opens the copy on a session of its own.
The source keeps its session and stays readable.
The use it exists for: plan a change in one conversation, then implement it in a fresh context that starts from the plan — with the conversation that produced the plan still there to consult, and its own canvas still bound to it.
The name carries the lineage, so nothing has to be recorded in the frontmatter.
Numbering is max+1 over the series, never the first free gap: the canvas folder is untracked by default, so a deleted `plan_1.md` may still be named in a commit body or a chat pointer, and must not be handed to a different canvas later.
`--fork` needs a canvas to fork from (the positional names the source, not the file being created), and cannot be combined with `--new-session` — both mint an id, but on different files.

**Starting a canvas from a slug.**
`gi new <slug>` is the naming half of `gi open`: the canvas is `<folder>/<date>-<slug>.md` (`--folder`; by default `gi-canvas/` when the directory has one, else `todo/` when it has that, else a new `gi-canvas/` — the same folder `gi open` and `gi import` pick when given no path), it starts with the todo frontmatter — `status` and `updated`, the creation date being in the file name already — and the same header a canvas gets from `gi open`, and the command ends in that launch.
On `main` or `master` with nothing staged, it first switches to a new branch named after the slug, so the canvas and its commits start off the trunk.
It then puts the file in front of you, in `$env.EDITOR`, to write the task in: inside zellij in a pane of its own, so the document stays in view while the session runs beside it; outside zellij in the terminal you are in, and the launch follows when the editor exits — with no `$env.EDITOR` set that is an error naming `--no-editor`, never a guess at which editor you have.
`--no-editor` skips that, `--no-claude-launch` skips the launch and hands back the path instead, and the flags `gi open` defines — `--root`, `--no-hook`, `--dangerously-skip-permissions`, anything else straight to `claude` — work here too.
`--fork` and `--new-session` are the two it does not take: both act on a canvas that exists and already records a session.
The same slug on the same day is an error naming the canvas already there, not a second file — a slug is typed on purpose, unlike zellij's `cmd+e` note, which is named after the day alone and numbers a repeat.

**Switching into gi mid-chat:** `gi import` starts the canvas from a session's dialogue instead of the empty template, so the discussion that led you to gi is the canvas's first content.
With no session named it takes the one it runs inside (`$env.CLAUDE_CODE_SESSION_ID` — not "the newest session file", which during a live session is as likely a subagent transcript); name one — with a completer showing age, size and summary — to import an older chat from the REPL, where there is no live session to fall back on.
It keeps user messages and Claude's visible replies, and drops tool calls and thinking behind a note pointing at the raw `.jsonl` (`--tools` keeps tool calls, each input rendered whole — useful when the session's value is in what was tried, not only what was said).
Importing the live session, the turn that runs the import is never in it: Claude Code writes the session log as the turn runs, so the last exchange is still missing.
The doc is named for the day and the session (`gi-canvas/<date>-session-<id>.md`, or `--to <path>`) and is never overwritten — delete it to re-import the same day.
It lands in the working tree untracked; `--commit` puts it in git, `--gitignore` keeps it out (they are mutually exclusive).
Neither is the default: a transcript carries raw paths and whatever the dialogue quoted, so tracking it is your call — but leaving it ignored means every later gi turn stays out of git too, which is the failure gi exists to prevent.

An imported canvas records the session it came from, so `gi open <doc>` reopens **that same session** (`claude --resume`, so the id keeps matching the frontmatter) with the canvas bound, and — when it was the live session — the agent still holds the turns the log could not contain yet and can append that missing tail itself.
The `40-gi-canvas` skill drives the whole flow from inside a chat session, so you don't type nushell into Bash: it runs the import and hands you the one line to run.

**The protocol rides a plugin, and the repo keeps nothing.**
`gi open` hands `claude --plugin-dir` the directory `claude-nu/gi-md-src/plugin/`, which holds the Canvas output style and the gi skills.
`--plugin-dir` loads a plugin for one session, reading it where it lies — nothing installed, nothing copied, no trace in `~/.claude.json` beyond a usage counter.
So a canvas launch writes exactly one thing into your repo: the canvas.
There is no `.claude/` from gi, no `.gitignore` block explaining it, and no `gi enable` verb — nothing is seeded, so nothing has to be refreshed.

Reading in place cannot go stale.
It also keeps the protocol opt-in: the plugin loads only for launches gi makes, so a plain `claude` anywhere else is untouched — which a machine-wide install into `~/.claude/skills/` would have given up.

**The parts are namespaced.**
Claude Code prefixes a plugin's components with the plugin's name, so the style is `gi:Canvas` and the skills are `/gi:git-intent`, `/gi:git-intent-readback`, `/gi:git-intent-distill`, `/gi:git-intent-squash-archive`.
The prefix is not cosmetic: a bare `Canvas` in `outputStyle` resolves to nothing and the session starts with no style **and no error**, which is gi silently half on.

**A repo seeded by the old gi needs cleaning out by hand.**
Nothing migrates it, on purpose: gi no longer reads those paths, so it cannot tell its own leftovers from files you put there.
Project skills and plugin skills coexist rather than override, so until you remove them a canvas session in such a repo loads each gi skill twice — once bare from the repo copy, which is frozen at whatever the module held when that repo was first seeded, and once as `gi:*` from the plugin.
Four things to delete: `.claude/output-styles/canvas.md`, `.claude/skills/git-intent*`, `.claude/skills/gi-canvas`, and the `# gi seeds` block in `.claude/.gitignore` (delete the file if that block is all it holds).

**One skill is not in the plugin.**
`40-gi-canvas` (the `40-` prefix is that repo's, so its skills group in the menu) turns the chat you are already in into a canvas, which means it has to be there in sessions gi did *not* launch — exactly where `--plugin-dir` never reaches.
It ships with the rest of your own skills instead, and is the one piece of gi that is installed rather than read from the module.

**Why `import` is its own verb.**
It was `gi enable --from-session`, which put a canvas-writing switch on the one command that makes no canvases, and dragged in a path plus three flags that meant nothing without it — enforced by run-time guards a signature states for free.
As a switch it could also only ever mean the live session, so an older chat could not be imported from the REPL at all, and there was nothing for a completer to complete.

Canvases come from `gi open`, which creates one from the template and binds a session to it in the same breath, or from `gi import`, which writes one from a dialogue — so no two verbs ever write the same file.

### `claude-nu example`

Pick a pipeline from the menu and it lands in your command line, ready to read, edit and run.
You run it — the command only writes the buffer, with `commandline edit --replace`.

```nushell no-run
claude-nu example                    # The examples as a table: slug, description, pipeline
claude-nu example <TAB>              # ...as a menu, each slug next to the pipeline it stands for
claude-nu example search-every-project # Paste that one into the command line
```

There is no second list to keep in sync: the rows are the `@example` attributes the module's own commands already carry, read at runtime from `scope commands`.
Examples that cross commands — most pipelines do — hang on the module's `main`, the one place that covers all of them.
`dotnu examples-update` runs those blocks and writes the real output back into `--result`, so a pipeline broken by a rename is caught at authoring time instead of being suggested here.

Slugs come from the description, so they read as labels rather than as indexes.
The menu is not sorted: it keeps the order the code declares — the module's own pipelines first, then each command's — because that order is authored, while alphabetical would follow whatever word a description happens to start with.
The menu is REPL-only where it pastes: `commandline edit` has no buffer to write to in a script, which is why the bare form returns the table instead.

## Guide

`guide/` holds five chapters of worked pipelines, each a `.nu` script with its output embedded under the command as `# =>` comments (dotnu embeds):
`01-scope.nu` (which sessions a command reads), `02-words.nu` (the user's words and the turns around a hit), `03-tool-calls.nu` (what agents did and what came back, and the timeline), `04-records.nu` (raw records and per-session numbers), `05-agents.nu` (which agent a transcript is, and the Workflow runs).
They run on the test fixtures in a throwaway HOME, so the outputs are the same on every machine; `dotnu embeds-update guide/01-scope.nu` refreshes one chapter, and `toolkit main update-captures` (from a session that has dotnu loaded) refreshes all.

## CLI Completions

Two completion files live here, for the two CLIs this repo is actually about.
Add either to your `config.nu`:

```nushell no-run
use completions/claude.nu *
use completions/nu.nu *
```

- `completions/claude.nu` — `claude`: 50+ flags, MCP/plugin subcommands, session picker for `--resume`
- `completions/nu.nu` — `nu`: Parses .nu scripts at tab-time to offer their subcommands and flags

Completions for unrelated tools (`zellij`, `fd`, `chafa`, `sandbox-exec`) are in the dotfiles repo, under `nushell/completions/`, which is where per-tool shell integration belongs.

**Session picker example:**
```
claude --resume <TAB>
# abc123… │ 2 hours ago │ 15KB │ Implement user auth…
# def456… │ yesterday   │ 42KB │ Fix database migration…
```

**Dynamic script completions:**
```
nu toolkit.nu <TAB>
# test │ test-unit │ check │ vendor-sessions │ …
```

### Claude Code Skills

Nushell-specific skills for Claude Code are distributed as a plugin marketplace:

```
/plugin marketplace add nushell-prophet/nushell-skills
/plugin install nushell-completions@nushell-skills
/plugin install nushell-style@nushell-skills
```

- `nushell-completions` — Teaches Claude Code to write Nushell completions: inline lists, custom completers, `extern` definitions, module naming rules.
  Point it at `--help` output and it produces a ready-to-use completion file.
- `nushell-style` — Opinionated Nushell style guide: pipeline patterns, command choices, formatting conventions, testing patterns.
  Activates automatically when editing `.nu` files.

All completions in this repo were built with the `nushell-completions` skill.

## How it works

Claude Code stores session data as JSONL files in `~/.claude/projects/<encoded-path>/`.
Each file contains:
- Session metadata (summary, timestamps, git branch)
- User messages and assistant responses
- Tool calls and results

This module parses these files to extract useful information for analysis, debugging, and workflow automation.

## Development

### Testing

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell no-run
nu toolkit.nu test          # Run all tests
nu toolkit.nu test --json   # JSON output for CI
nu toolkit.nu test --fail   # Non-zero exit on failures
```

### Toolkit

```nushell no-run
nu toolkit.nu check [file]             # Static syntax check with diagnostics (whole repo if no file)
nu toolkit.nu vendor-sessions          # Obfuscate real sessions into test fixtures
```

## License

MIT
