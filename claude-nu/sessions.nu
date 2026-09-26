# claude-nu - Nushell utilities for Claude Code

# Why `export use`: the names stay in scope for the commands here AND stay
# reachable through sessions.nu (tests `use sessions.nu *`, toolkit imports
# get-sessions-dir, mod.nu picks its re-exports) — the split changes no caller.
export use discovery.nu *
export use render.nu *
export use extract.nu *

# All selectable session columns, paired with overview membership (the fixed
# set `sessions` returns when no columns are requested). Single source of truth:
# the --columns completer, --all-columns, and the default set all read from it;
# parse-session-columns computes each name. Adding a column means one row here
# plus its computation there — no flag list to keep in sync.
const SESSION_COLUMNS = [
    [name default];
    [summary true]
    [first_timestamp false]
    [last_timestamp true]
    [size false]
    [modified false]
    [user_msg_count false]
    [user_msg_length false]
    [response_length false]
    [agent_count false]
    [agents false]
    [mentioned_files false]
    [read_files false]
    [edited_files false]
    [user_messages true]
    [session_id false]
    [version false]
    [cwd false]
    [git_branch false]
    [effort false]
    [models false]
    [bash_commands false]
    [bash_count false]
    [skill_invocations false]
    [tool_errors false]
    [ask_user_count false]
    [plan_mode_used false]
    [tool_counts false]
    [turn_count false]
    [assistant_msg_count false]
    [tool_call_count false]
    [token_usage false]
    [agent_id false]
    [agent_type false]
    [workflow false]
    [agent_label false]
    [phase false]
]

# Columns every `sessions` row carries whatever --columns selects.
const ROW_COLUMNS = [path parent_session_id]

# Selectable columns read from the file listing, not from the records: a
# selection of only these opens no session file.
const LISTING_COLUMNS = [size modified]

# List Claude Code projects under ~/.claude/projects, most recent first.
# `name` is the last two segments of the real project path; `path` is the
# sessions directory, so rows pipe straight into `sessions`.
@category claude-nu
export def projects []: nothing -> table {
    let projects_root = projects-root
    if not ($projects_root | path exists) { return [] }

    ls $projects_root
    | where type == dir
    | sort-by modified --reverse
    | each {|dir|
        # Not discover-session-files because: only top-level names and mtimes
        # are needed here — its subagents glob per project dir buys nothing.
        let files = ls $dir.name | where name =~ $UUID_JSONL_PATTERN
        if ($files | is-empty) { return null }
        # Why: the dir name is lossy (`/` and `-` both encode to `-`), so
        # recover the real path from a session's `cwd` for true segments.
        # Scan newest-first until a file records one — summary-only files
        # (e.g. legacy sidechain summaries) carry no cwd and must not hide
        # the whole project.
        let cwd = $files
            | sort-by modified --reverse
            | reduce --fold null {|file found|
                if $found != null { return $found }
                try {
                    open --raw $file.name
                    | lines
                    | first 30
                    | where ($it | str contains '"cwd"')
                    | get 0?
                    | if $in != null { from json | get cwd? } else { null }
                } catch { null }
            }
        if $cwd == null { return null }
        {
            name: ($cwd | project-display-name)
            path: $dir.name
            count: ($files | length)
            # Why the same files as `count`: the top-level transcripts only —
            # no subagent transcripts, no `tool-results/` — so it is what
            # `projects | sessions` reads, not the disk the store takes (`du`).
            size: ($files | get size | math sum)
            modified: $dir.modified
        }
    }
    | compact
}

# Completion for session UUIDs
export def "nu-complete claude sessions" []: nothing -> record {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        return {options: {sort: false} completions: []}
    }

    # Not discover-session-files because: a Tab press shouldn't pay the
    # subagents glob.
    let completions = ls $sessions_dir
        | where name =~ $UUID_JSONL_PATTERN
        | each {|file|
            let uuid = $file.name | session-id-from-path
            let raw_lines = try { open --raw $file.name | lines } catch { [] }
            # Why: the title lives in custom-title/summary/ai-title records
            # anywhere in the file. String-match first so a Tab press never JSON-parses whole
            # session files; extract-summary then filters false-positive lines
            # (e.g. messages quoting the pattern) by record type.
            let summary = $raw_lines
                | where $it =~ '"type":"(custom-title|summary|ai-title)"'
                | each { try { from json } catch { {} } }
                | extract-summary
                | if ($in | is-empty) { "No summary" } else { }
            let head = try { $raw_lines | first 5 | each { from json } } catch { [] }
            # Timestamps are on message records, not summary headers
            let timestamp = $head
                | where timestamp? != null
                | get 0?.timestamp?
                | if ($in != null) { into datetime } else { $file.modified }

            let age = $timestamp | date humanize
            {value: $uuid description: $"($age), ($file.size): ($summary)" timestamp: $timestamp}
        }
        | sort-by timestamp --reverse
        | select value description

    {
        options: {sort: false}
        completions: $completions
    }
}

# Extract user messages from Claude Code session files.
# With no input it reads every top-level session of the current project; scope it
# by piping session rows in — `sessions --last | messages` for the most recent
# one, `sessions --session <uuid> | messages` for a named one, `projects |
# messages` for every project — the fast spelling, since `sessions
# --all-projects` parses every file for its own columns first. Both scopes are
# top-level human sessions, so they carry no agent turns; add `sessions
# --subagents` if you deliberately want subagent transcripts too.
# Rows come session by session — newest session first, chronological inside each
# — not as one merged timeline; `sort-by timestamp` if that is what you want.
# Why (no input = the whole project): a command handed nothing returns everything
# at its own level inside the current project — `projects` all projects,
# `sessions` the project's sessions, `messages` its messages. Reading the most
# recent session instead was a selection, and selection lives in one place
# (`sessions`); messages just reads what it's handed. That also kills the old
# `--all-projects` take-1 footgun (see todo/20260618-225035) — "all" now means
# all, because the caller controls it.
# Not a `--session` shortcut here because: the rule then held in three places at
# once, each with its own completer and its own "piped input conflicts with
# --session" guard, and a reader could not tell from the command shapes where
# selection actually lives.
# Why the regex is an argument, not a downstream `where`: given one, the raw
# JSONL pre-scan that already narrows lines to user turns can narrow whole files
# first (rg over the bytes), so a project- or all-projects-wide search parses
# only the sessions that can match. The real regex is re-applied to the extracted
# text either way, so the pre-scan can only cost recall, never add a wrong hit —
# and --no-rg turns it off for a pattern rg's raw scan would under-match (a line
# anchor, a JSON-escaped quote or backslash).
# Why the time window is per message here and per session in `sessions`: a row
# is what gets filtered, and here a row is one message with a timestamp of its
# own — so `messages --since 1wk` returns last week's messages, not every
# message of a session that happens to have been open last week.
# Every row carries a `kind`: `typed`, `bash-input`, `bash-output`, `system`
# (only with --include-system) or `response` (only with --include-responses).
# Why a column and not a flag per kind: the user's own words are
# `where kind == typed`, and the pasted output of a `!` command stays one
# `where` away instead of being guessed from the text.
# `--context N` returns, with each hit, the N rows before and after it in the
# same session — like `rg --context`. The rows come from the same dialogue the
# other flags select, so `--include-responses` makes the reply before a prompt
# a neighbour. Rows then carry `hit`, true for the rows the regex matched, and a
# row two windows share comes back once.
# Why the window runs over the rows left after --since/--until and after the
# copies a resumed session holds are dropped, not over the whole session: a
# returned row is then always a hit or a neighbour of one that is returned too,
# in the same session — never context for a hit the window or the copy rule
# already cut.
@category claude-nu
@example "only what the user typed, without `!` commands and their output" { claude-nu messages | where kind == typed }
@example "each prompt about a rebase with the reply before it and after it" { claude-nu messages 'rebase' --context 1 --include-responses }
export def messages [
    regex?: string # Filter messages by regex pattern
    --since: any # Only messages at or after this point — a duration means ago (`1wk`), or a datetime/date string
    --until: any # Only messages at or before this point
    --include-system # Include system/meta messages (not just user-typed), as rows of kind `system`
    --include-thinking # Include assistant thinking blocks (prefixed with [thinking])
    --raw # Return raw message records instead of just content
    --include-responses # Include assistant responses (text only, interleaved), as rows of kind `response`
    --no-rg # Skip the ripgrep file pre-filter and match entirely in-engine (exact regex semantics, slower)
    --context: int # With a regex: also the N rows before and after each hit in its session; adds a `hit` column
]: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    # Why up here: a misspelled bound must fail before any session is opened.
    let since_at = if $since == null { null } else { $since | resolve-time-bound "--since" }
    let until_at = if $until == null { null } else { $until | resolve-time-bound "--until" }

    if $context != null and $regex == null {
        error make {
            msg: "--context needs a regex"
            label: {text: "context around which hits?" span: (metadata $context).span}
            help: "pass the pattern to match: `messages 'pattern' --context 2`"
        }
    }
    if $context != null and $context < 0 {
        error make {
            msg: "--context cannot be negative"
            label: {text: "rows before and after each hit" span: (metadata $context).span}
        }
    }

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    # Why here, before the pre-filter and the read loop: rg touches these paths
    # first, and its own "No such file" (exit 2) would mask this error and throw
    # away the matches it did find. One check, at the one point they enter.
    let missing = $scoped_files | where not ($it | path exists)
    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    let session_files = $scoped_files
        | if $since_at == null { } else { mtime-filter-session-files $since_at }
        | if $regex == null or $no_rg { } else { rg-filter-session-files $regex }

    # Why: --include-thinking surfaces thinking-only assistant turns
    # (otherwise dropped by the empty-text filter). User text always goes
    # through extract-text-content, keeping its contract for other callers.
    let extract_text = {|r|
        if $r.type? == "assistant" and $include_thinking {
            $r | extract-text-with-thinking
        } else {
            $r | extract-text-content
        }
    }

    $session_files
    | each {|session_file|
        let session_uuid = $session_file | session-id-from-path

        # Why (speed): the default keeps only user turns, so pre-screen the raw
        # JSONL for the user-type marker before decoding — assistant turns, tool
        # results, and summaries (the ~70% bulk) never reach the JSON parser. The
        # `where type? == "user"` below still runs, so the prefilter only narrows.
        let records = if $include_responses {
            $session_file | read-session-records
        } else {
            $session_file | read-session-records --contains '"type":"user"'
        }
        let dialogue = $records
            | if $include_responses { } else { where type? == "user" }
            | extract-dialogue $extract_text --keep-system=$include_system
            | insert kind {|r| $r | message-kind }

        # Why: sorting the ISO-8601 timestamp strings sorts chronologically,
        # so one sort here serves both the --raw and rendered branches.
        let filtered = $dialogue
            | if $since_at == null { } else { where {|m| ($m.timestamp | into datetime) >= $since_at } }
            | if $until_at == null { } else { where {|m| ($m.timestamp | into datetime) <= $until_at } }
            | sort-by timestamp
            | if $regex == null { } else if $context == null { where text =~ $regex } else {
                insert hit {|m| $m.text =~ $regex }
            }

        if $raw {
            $filtered | reject text
        } else {
            $filtered
            | each {|msg|
                {role: $msg.type message: $msg.text timestamp: ($msg.timestamp? | into datetime) uuid: $msg.uuid? kind: $msg.kind}
                | if $context == null { } else { insert hit $msg.hit }
            }
            | if $include_responses { } else { reject role }
        }
        # Why: rows are self-describing — the session column makes messages
        # output a valid session selector for resolve-piped-sessions, so it
        # can pipe back into messages/export-session/sessions.
        # Not "project only when the scope spans several projects" because: the
        # output schema would then depend on the data, and a script with
        # `| get project` would work on a wide search and fail on a narrow one.
        | each { insert session $session_uuid }
        | insert project ($session_file | project-dir-name)
        | insert project_name ($records | pick-first $.cwd | project-display-name)
    }
    | flatten
    | drop-copied-records uuid
    # Why after the copies are dropped: a hit a resumed session copied can be
    # dropped from that session, and neighbours chosen before would stay behind
    # there as context for a hit it no longer returns.
    | if $context == null { } else {
        chunk-by {|m| $m.session } | each { keep-context $context } | flatten
    }
}

# Extract the tool calls of Claude Code session files — what an agent did, as
# `messages` is what was said. One row per tool_use block: {tool, input,
# timestamp, id, uuid, session, project, project_name}, with `input` kept as the raw
# record so a caller drills into it (`where tool == Bash | get input.command`).
# Scoping and searching work exactly as in `messages`: no input reads every
# top-level session of the current project, piped session rows narrow it, the
# regex argument gets the same rg pre-filter over the raw JSONL, and `--no-rg`
# turns that off.
# Why a command and not another `sessions` column: `bash_commands` was the only
# window onto agent actions, and it is Bash-only — mining this store for
# `claude-nu` invocations, 82 of the 588 an agent made came through
# `mcp__nushell__evaluate` and were invisible. It also aggregates per session,
# so a matched command carries no timestamp and no row of its own, and the
# columns path has no rg pre-filter: the same all-projects sweep costs 42s
# through `sessions --columns bash_commands` against 2.4s once rg narrows the
# files first.
# Why the regex matches the whole input, not just the tool name or one
# preferred field: the interesting string sits in a different field per tool
# (`command`, `prompt`, `skill`, an MCP tool's own schema), and a search that
# has to know the field per tool cannot answer "who ran this" across tools.
# Why the input as compact JSON and not NUON: the rg pre-filter reads the raw
# JSON line, so a NUON pattern spanning a key and its value (`command: "git`)
# passed no file and returned nothing, while --no-rg found the call.
# The regex also matches the tool name, so `tool-calls AskUserQuestion` finds
# the calls a reader means by it; the exact filter is `--tool`.
# Why `--tool` and not `where tool == ...` downstream: the flag gets its own rg
# pre-filter, because the tool name sits in the raw line as the fixed string
# `"name":"<tool>"` — a downstream `where` runs only after every file is parsed.
# Measured machine-wide for `mcp__nushell__evaluate`: 56 s with the `where`,
# 11 s with the flag — rg passed 328 of 3225 files, same 3868 rows.
@category claude-nu
@example "Only the nushell MCP calls, across every project" {
    claude-nu projects | claude-nu tool-calls --tool mcp__nushell__evaluate
}
@example "Every file read or edit that touched sessions.nu" {
    claude-nu tool-calls --tool [Read Edit Write] 'sessions\.nu'
}
export def tool-calls [
    regex?: string # Filter tool calls by regex over the tool name or the call's input as compact JSON (`'"command":"git'`)
    # Why list first: with `string` first the parser takes `[Bash Read]` as the
    # one string "[Bash Read]", and the filter silently matches nothing.
    --tool: oneof<list<string>, string> # Only calls to this tool, or to any of a list — exact name, with its own rg pre-filter
    --since: any # Only calls at or after this point — a duration means ago (`1wk`), or a datetime/date string
    --until: any # Only calls at or before this point
    --no-rg # Skip the ripgrep file pre-filters and match entirely in-engine (exact regex semantics, slower)
    --results # Add each call's `result` text and `is_error`; the regex then searches the result too
]: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    let tools = if $tool == null { null } else { [$tool] | flatten }
    # Why an error and not an empty result: an empty list is almost always a
    # name query upstream that found nothing, and it would read every file only
    # to return no rows.
    if $tools == [] {
        error make {
            msg: "--tool: expected a tool name or a non-empty list of them"
            label: {text: "empty list" span: (metadata $tool).span}
        }
    }

    # Why up here: same as in `messages` — a bad bound fails before any parsing.
    let since_at = if $since == null { null } else { $since | resolve-time-bound "--since" }
    let until_at = if $until == null { null } else { $until | resolve-time-bound "--until" }

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    # Why here, before rg: same reason as in `messages` — rg's own "No such
    # file" would mask this and discard the matches it did find.
    let missing = $scoped_files | where not ($it | path exists)
    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    let session_files = $scoped_files
        | if $since_at == null { } else { mtime-filter-session-files $since_at }
        | if $tools == null or $no_rg { } else { rg-filter-session-files (tool-name-pattern $tools) }
        | if $regex == null or $no_rg { } else { rg-filter-session-files $regex }

    $session_files
    | each {|session_file|
        # Why the pre-screen: tool calls live only on assistant records, which
        # are a minority of the lines — the rest never reach the JSON parser.
        # The `where type?` below still runs, so this only narrows.
        # Why --results reads the user records too: a result is a tool_result
        # block on the user record that follows the call, joined by the call's id.
        let records = $session_file
            | if $results { read-session-records } else { read-session-records --contains '"type":"assistant"' }
        let outcomes = if $results {
            $records
            | where type? == "user"
            | extract-tool-results
            | each {|r| {id: $r.tool_use_id? result: ($r | tool-result-text) is_error: ($r.is_error? == true)} }
            # Why: `join` pairs a null key with a null key, so a result naming
            # no call would attach to a call carrying no id.
            | where id != null
        } else { [] }

        $records
        | where type? == "assistant"
        | each {|record|
            $record
            | extract-tool-calls
            # Why $record.timestamp and not `?`: every assistant record in the
            # store carries one (26498 of 26498 checked), so a missing field is
            # a record shape that changed — it must fail here, not silently
            # yield a null column downstream.
            | each {|call|
                {
                    tool: ($call.name? | default "")
                    input: ($call.input? | default {})
                    timestamp: ($record.timestamp | into datetime)
                    id: $call.id?
                    uuid: $record.uuid?
                }
            }
        }
        | flatten
        | if $tools == null { } else { where tool in $tools }
        | if $since_at == null { } else { where timestamp >= $since_at }
        | if $until_at == null { } else { where timestamp <= $until_at }
        # Why a left join: a call with no result yet (interrupted, or the live
        # session still running it) keeps its row, with a null result.
        # Why the defaults: joined against no results at all (a session whose
        # calls are all still running), `join` adds no columns, and the schema
        # would depend on the data.
        | if $results { join --left $outcomes id | default null result | default null is_error } else { }
        | if $regex == null { } else {
            where {|call| $call.tool =~ $regex or ($call.input | to json --raw) =~ $regex or ($call.result? | default "") =~ $regex }
        }
        | insert session ($session_file | session-id-from-path)
        | insert project ($session_file | project-dir-name)
        | insert project_name ($records | pick-first $.cwd | project-display-name)
    }
    | flatten
    | drop-copied-records id
}

# The rg pattern for a file holding a call to any of `tools`: the tool_use
# block's `"name":"<tool>"` as Claude Code writes it, compact, no spaces.
# Why one escaped alternation and not one rg call per name: each call is a
# second pass over the files, and the result would be their intersection.
# Why escaped: a name is the caller's text, and a stray `.` or `(` would widen
# the pre-filter or make rg fail — the pattern must mean the name literally.
export def tool-name-pattern [tools: list<string>]: nothing -> string {
    let names = $tools | each { str replace --all --regex '[\\.^$|?*+()\[\]{}]' '\$0' } | str join '|'
    '"name":"(?:' + $names + ')"'
}

# Every raw record of Claude Code session files, one row per JSONL line:
# {type, uuid, timestamp, record, session, project, project_name}, with the
# whole decoded line under `record`. Scoping works as in `messages`; the regex
# matches the record as JSON (`'"type":"system"'`). A record a resumed or
# forked session copied from its parent comes back once, as in `messages`
# (`drop-copied-records`); a line with no `uuid` is always kept.
# Why JSON and not NUON: the rg pre-filter reads the raw
# JSON line, so a NUON pattern spanning a key and its value (`type: user`)
# passed no file and returned nothing — 0 rows against 476 with --no-rg.
# Why a command: the other commands model the record types they know, and past
# agents kept dropping to jq or to the private `read-session-records` for the
# rest — system records, hooks, permission modes, the shape of a new field.
# Why the record is nested, not spread into columns: record types share few
# fields, so a spread table is mostly nulls and its columns change with the
# scope; `record` keeps every row the same shape and the line lossless.
@category claude-nu
@example "record types of the current project, most common first" { claude-nu records | get type | uniq --count | sort-by count --reverse }
@example "the permission modes the last session ran in" { claude-nu sessions --last | claude-nu records | where type == permission-mode | get record.permissionMode }
export def records [
    regex?: string # Filter records by regex over the record as JSON (`'"type":"system"'`)
    --no-rg # Skip the ripgrep file pre-filter and match entirely in-engine (exact regex semantics, slower)
]: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    let missing = $scoped_files | where not ($it | path exists)
    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    $scoped_files
    | if $regex == null or $no_rg { } else { rg-filter-session-files $regex }
    | each {|session_file|
        let records = $session_file | read-session-records
        $records
        | each {|r| {type: ($r.type? | default "") uuid: $r.uuid? timestamp: ($r.timestamp? | if $in == null { } else { into datetime }) record: $r} }
        | if $regex == null { } else { where {|row| ($row.record | to json --raw) =~ $regex } }
        | insert session ($session_file | session-id-from-path)
        | insert project ($session_file | project-dir-name)
        | insert project_name ($records | pick-first $.cwd | project-display-name)
    }
    | flatten
    | drop-copied-records uuid
}

# Extract the slash commands invoked in Claude Code session files — what you
# typed, as `messages` is what you said and `tool-calls` is what the agent did.
# One row per invocation: {command, args, timestamp, uuid, session, project,
# project_name}. Scoping works exactly as in `messages`: no input reads every
# top-level session of the current project, piped session rows narrow it,
# `--since`/`--until` cut the window per invocation.
# Why a command and not a `sessions` column: the question it answers is "which
# commands do I actually use", which is a ranking over invocations — a per
# session list would have to be flattened before it could be counted, and a
# count aggregated per session cannot be re-aggregated across projects.
# Why it reads the transcripts and not ~/.claude/history.jsonl: the history file
# is every project at once and cannot be narrowed by a session row, so it could
# not scope like its siblings. What it uniquely holds — the built-in commands
# that never reach the model — is what `--all` covers here, and what the
# default drops anyway.
# Why no existence check against the installed skills: a command counts under
# the name it was typed with, so a skill since renamed or deleted keeps its
# history instead of vanishing from it.
# A `Skill` tool call is not a slash command — that is the agent choosing a
# skill on its own, and it is already `tool-calls | where tool == Skill`.
@category claude-nu
@example "the commands I use most" { claude-nu slash-commands | histogram command }
@example "...across every project" { claude-nu projects | claude-nu slash-commands | histogram command }
@example "including the built-ins Claude Code handles itself" { claude-nu slash-commands --all | histogram command | select command count }
@example "what I passed to a command" { claude-nu slash-commands | where command == '/land-branch' | select timestamp args }
export def slash-commands [
    --since: any # Only invocations at or after this point — a duration means ago (`1wk`), or a datetime/date string
    --until: any # Only invocations at or before this point
    --all # Keep the built-in commands Claude Code handles itself (/clear, /model, /exit ...)
]: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    # Why up here: same as in `messages` — a bad bound fails before any parsing.
    let since_at = if $since == null { null } else { $since | resolve-time-bound "--since" }
    let until_at = if $until == null { null } else { $until | resolve-time-bound "--until" }

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    let missing = $scoped_files | where not ($it | path exists)
    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    $scoped_files
    | if $since_at == null { } else { mtime-filter-session-files $since_at }
    | each {|session_file|
        # Why the pre-screen: an invocation is a handful of lines in a session,
        # and every one of them carries the tag — a file with no match never
        # reaches the JSON parser. `extract-slash-command` re-reads the tag, so
        # this only narrows.
        let records = $session_file | read-session-records --contains "<command-name>"

        $records
        | each {|record|
            let invocation = $record | extract-slash-command
            if $invocation == null { } else {
                $invocation | insert timestamp ($record.timestamp | into datetime) | insert uuid $record.uuid?
            }
        }
        | if $all { } else { where {|row| not ($row.command | is-builtin-slash-command) } }
        | if $since_at == null { } else { where timestamp >= $since_at }
        | if $until_at == null { } else { where timestamp <= $until_at }
        | insert session ($session_file | session-id-from-path)
        | insert project ($session_file | project-dir-name)
        | insert project_name ($records | pick-first $.cwd | project-display-name)
    }
    | flatten
    | drop-copied-records uuid
}

# The rows within `n` rows of a row whose `hit` is true, in their order, each
# once. The rows are one session's, sorted.
# Why a sliding window over the hit flags and not a distance to every hit per
# row: a broad regex makes most rows hits, and the per-row check is then
# quadratic in the session's length; the window costs 2n+1 per row.
def keep-context [n: int]: table -> table {
    let rows = $in
    if ($rows | is-empty) { return $rows }
    let pad = 0..<$n | each { false }
    let near = $pad
        | append ($rows | get hit)
        | append $pad
        | window ($n * 2 + 1)
        | each { any {|h| $h } }
    $rows
    | merge ($near | wrap _near)
    | where _near
    | reject _near
}

# Rows of records that a resumed or forked session copied from its parent,
# kept once. Claude Code writes the parent's history into the new file under
# the same record uuid (only `sessionId` changes), so a resumed conversation
# counted twice: 325 of 3,205 slash-command rows machine-wide were copies.
# The copy kept is the last in row order. The default order is by file mtime,
# the last activity, so that is usually the parent, where the record was first
# written — but a parent resumed after its fork sorts first, and then the fork's
# copy is kept. A row with no key is kept as it is.
export def drop-copied-records [key: string]: table -> table {
    let rows = $in
    if ($rows | is-empty) { return $rows }
    $rows
    | insert _copy_key {|r| $r | get --optional $key | default (random uuid) }
    | reverse
    | uniq-by _copy_key
    | reverse
    | reject _copy_key
}

# Parse one session file, computing only the selected columns.
# Lazy: each extraction group runs only when a selected column needs it.
# Why: no empty-file special case — every extractor yields its typed default
# ("", 0, []) on an empty record set, so empty JSONL files flow through.
def parse-session-columns [selected: list<string>]: path -> record {
    let file_path = $in
    let records = $file_path | read-session-records

    let user_records = $records | where type? == "user"
    let assistant_records = $records | where type? == "assistant"

    let need = {|cols| $cols | any {|c| $c in $selected } }

    let all_tool_calls = if (do $need [
        agents agent_count read_files edited_files bash_commands bash_count
        skill_invocations tool_errors ask_user_count plan_mode_used tool_counts
        turn_count assistant_msg_count tool_call_count
    ]) {
        $assistant_records | each { extract-tool-calls } | flatten
    } else { [] }

    # Why: user_msg_count/length/list all describe user-authored text, so one
    # pass feeds all three. user-message-texts is the single definition of "a
    # user message" shared with `messages` and turn_count — it drops tool-result
    # records (render to ""), meta turns, and command/caveat wrappers, so none of
    # the three count tool replies or a /clear invocation as a message.
    let user_messages = if (do $need [user_messages user_msg_length user_msg_count]) {
        $user_records | user-message-texts
    } else { [] }

    let user_msg_length = $user_messages
        | each { str length }
        | sum-or-zero

    let mentioned_files = if ("mentioned_files" in $selected) {
        $user_records
        | each { extract-text-content | parse --regex '(?<!\w)@((?:[/~]|\.{1,2}/)[\w./-]+|\w[\w./-]*\.\w{1,10})' | get capture0? | default [] }
        | flatten
        | uniq
    } else { [] }

    let response_length = if ("response_length" in $selected) {
        $assistant_records
        | each { extract-text-content | str length }
        | sum-or-zero
    } else { 0 }

    let summary = if ("summary" in $selected) { $records | extract-summary } else { "" }

    let timestamps = if (do $need [first_timestamp last_timestamp]) {
        $records | extract-timestamps
    } else { {first: null last: null} }

    let file_ops = if (do $need [read_files edited_files]) {
        $all_tool_calls | extract-file-operations
    } else { {} }

    let agent_list = if (do $need [agents agent_count]) {
        $all_tool_calls | extract-agents
    } else { [] }

    let meta = if (do $need [session_id version cwd git_branch]) {
        $records | extract-session-metadata
    } else { {} }

    let effort = if ("effort" in $selected) {
        $assistant_records | extract-effort
    } else { "" }

    let models = if ("models" in $selected) {
        $assistant_records | extract-models
    } else { [] }

    let tool_stats = if (do $need [
        bash_commands bash_count skill_invocations tool_errors ask_user_count
        plan_mode_used tool_counts
    ]) {
        let tool_results = $user_records | extract-tool-results
        let stats = $all_tool_calls | extract-tool-stats $tool_results
        # Why: 2.1.x replaced EnterPlanMode tool calls with top-level
        # permission-mode records, and older sessions carry the mode as a
        # `permissionMode` field on user records (Shift+Tab into plan mode).
        # Treat any of the three as plan-mode.
        let from_records = $records | get permissionMode --optional | any { $in == "plan" }
        $stats | upsert plan_mode_used ($stats.plan_mode_used or $from_records)
    } else { {} }

    let metrics = if (do $need [turn_count assistant_msg_count tool_call_count]) {
        $user_records | extract-derived-metrics $assistant_records $all_tool_calls
    } else { {} }

    let usage = if ("token_usage" in $selected) {
        $assistant_records | extract-token-usage
    } else { {} }

    # Why read beside the transcript and not from it: a subagent's records carry
    # the parent's `sessionId` and nothing naming the agent, so without these
    # a subagent row could not say which agent it is.
    let identity = if (do $need [agent_id agent_type workflow agent_label phase]) {
        $file_path | subagent-identity
    } else { {} }

    # Why `select` (not where+reduce): it keeps $selected's order and fails fast
    # if SESSION_COLUMNS names a column this record doesn't compute.
    {
        summary: $summary
        first_timestamp: $timestamps.first
        last_timestamp: $timestamps.last
        user_msg_count: ($user_messages | length)
        user_msg_length: $user_msg_length
        response_length: $response_length
        agent_count: ($agent_list | length)
        agents: $agent_list
        mentioned_files: $mentioned_files
        read_files: $file_ops.read_files?
        edited_files: $file_ops.edited_files?
        user_messages: $user_messages
        session_id: $meta.session_id?
        version: $meta.version?
        cwd: $meta.cwd?
        git_branch: $meta.git_branch?
        effort: $effort
        models: $models
        bash_commands: $tool_stats.bash_commands?
        bash_count: $tool_stats.bash_count?
        skill_invocations: $tool_stats.skill_invocations?
        tool_errors: $tool_stats.tool_errors?
        ask_user_count: $tool_stats.ask_user_count?
        plan_mode_used: $tool_stats.plan_mode_used?
        tool_counts: $tool_stats.tool_counts?
        turn_count: $metrics.turn_count?
        assistant_msg_count: $metrics.assistant_msg_count?
        tool_call_count: $metrics.tool_call_count?
        token_usage: $usage
        agent_id: $identity.agent_id?
        agent_type: $identity.agent_type?
        workflow: $identity.workflow?
        agent_label: $identity.agent_label?
        phase: $identity.phase?
    }
    | select ...$selected
    | insert path $file_path
}

# True when a value is a record (which is a 1-row table once piped). Strips the
# `<...>` type detail so `record<a: int>` and a bare `record` both match.
def is-record []: any -> bool {
    peek | metadata access {|md| $md.peek.type == "record" }
}

# Extract session file paths from piped input
# Returns null when input is not a table
export def resolve-piped-sessions [input: any]: nothing -> any {
    if ($input | describe) == "nothing" { return null }
    # Why: a record is a 1-row table (e.g. `sessions | first`); widen it here so
    # every piped command accepts a single row without the caller re-wrapping it.
    let input = if ($input | is-record) { [$input] } else { $input }
    # Why an empty table is an empty selection, not a broken contract: a search
    # that matched nothing must flow on (`messages 'nomatch' | export-session`
    # yields nothing) instead of erroring about columns the caller never chose.
    # Only a non-empty table can be missing them.
    if ($input | is-empty) { return [] }
    # Why: `glob ... | messages` and `[9787e004 agent-a1] | messages` are the
    # short spellings of a scope; each wanted `| wrap path` before. A string is
    # a path when one exists there, otherwise a selector as `--session` reads it.
    if ($input | describe) =~ '^list<(string|path)' {
        return ($input | ansi strip | each {|s| if ($s | path exists) { $s } else { resolve-session-file $s } } | uniq)
    }
    let cols = $input | columns
    # Why: `find` is handy for searching every column at once (it recurses into
    # nested cells like user_messages), but it marks matches by injecting ansi
    # codes into the string values themselves — which corrupts the path/session
    # selectors so `path exists`/`open` then fail. `find --no-highlight` (-n)
    # skips the injection, but stripping ansi here — the one chokepoint every
    # piped command shares — is more forgiving than asking callers to remember
    # the flag, so plain `find … | export-session` works too.
    if "path" in $cols {
        $input | get path | compact | ansi strip | uniq
    } else if "session" in $cols {
        # Why the row's `project`: an id names one transcript per project only,
        # so a row resolves in the store it was read from, not the first one found.
        $input
        | where session != null
        | each {|row| {session: ($row.session | ansi strip) project: ($row.project? | if $in == null { } else { ansi strip })} }
        | uniq
        | each {|row|
            let dir = if $row.project == null { null } else { projects-root | path join $row.project }
            resolve-session-file $row.session --sessions-dir $dir
        }
        | uniq
    } else {
        error make "Piped input must have 'path' or 'session' column"
    }
}

# The files a dialogue command reads from its piped input, or null when nothing
# was piped. A directory — the `path` of a `projects` row — stands for its
# top-level sessions, the same set a bare call reads for the current project.
# Why here and not in resolve-piped-sessions: `sessions` shares that one and
# expands a directory itself, subagent transcripts included for --subagents.
export def piped-session-files [input: any]: nothing -> any {
    let piped = resolve-piped-sessions $input
    if $piped == null { return null }
    $piped
    | each {|p|
        if ($p | path type) == "dir" {
            discover-session-files $p | where parent_session_id == null | get path
        } else {
            [$p]
        }
    }
    | flatten
    # Why: a directory and a file inside it can both be piped in, and the same
    # file must not be read twice.
    | uniq
}

# Completer for --columns: comma-separated session column names. Returns full
# comma-joined values (e.g. `version,cwd`) so the menu re-spawns after each
# comma and accumulates; names already chosen in the token are excluded.
# Why: --columns is a string, not list<string>, because Nushell completes a
# list-typed flag only outside its `[ ]` — where a bare value won't parse — and
# offers nothing inside the brackets. A string flag completes at the value
# position, where the inserted text is valid, so the menu actually works.
export def "nu-complete claude session-columns" [context: string]: nothing -> list<string> {
    let token = $context | split row ' ' | last
    let parts = $token | split row ','
    let chosen = $parts | drop 1
    let prefix = $chosen | str join ','
    $SESSION_COLUMNS
    | get name
    | difference $chosen
    | each {|c| if ($prefix | is-empty) { $c } else { $"($prefix),($c)" } }
}

# Expand paths (piped or positional) to session-file rows. A directory
# discovers its sessions, subagent transcripts only with --subagents; a file is
# taken as-is, whatever its name — UUID/agent pattern filtering lives in
# discover-session-files (directory scans only).
# Subagent transcripts hold agent-driven turns, not human messages, so they
# are opt-in.
# Why the cut is here, on directories only: a file named explicitly
# is always read, and its row still carries its parent — the id `messages`
# names it by has to round-trip, and a subagent row claiming no parent read as
# a top-level session of the parent's id.
def expand-session-paths [--subagents]: list<path> -> table {
    each {|p|
        if not ($p | path exists) {
            error make $"Path not found: ($p)"
        }
        if ($p | path type) == "dir" {
            discover-session-files $p
            | if $subagents { } else { where parent_session_id == null }
        } else {
            # Why the stat: discover-session-files already carries `modified`
            # and `size`, the --since/--until window filters on the first, and
            # both are columns — so a row made here has to carry them too, or a
            # named file would drop out of every window.
            let stat = ls $p | follow-links | get 0
            [{path: $p parent_session_id: ($p | parent-session-of) modified: $stat.modified size: $stat.size}]
        }
    }
    | flatten
}

# Parse Claude Code sessions for structured information.
# `--columns` selects what to compute (lazy — only requested extractions run);
# omit it for the default overview set, `--all-columns` for everything. Column
# names are listed in SESSION_COLUMNS (and tab-complete on --columns).
# By default only top-level (human-driven) sessions are listed; pass --subagents
# to also include subagent transcripts (those rows carry a non-null parent_session_id;
# the `agent_*`, `workflow` and `phase` columns say which agent each one is).
# `size` and `modified` come from the file listing, not the records: `modified`
# is the file mtime, the clock --since/--until compare, and it can run hours past
# `last_timestamp` — a record without a timestamp written after the last turn.
# --active-since/--active-until use record time instead: a session is kept when
# its span [first_timestamp, last_timestamp] overlaps the window, which costs a
# parse of every session the mtime cut on --active-since leaves in.
# Named `main` because a module can't export a command named the same as the
# module — importing this file yields the `sessions` command.
@category claude-nu
@example "sessions that touched a file" { claude-nu sessions --columns edited_files,session_id | where {|r| $r.edited_files | any {|f| $f =~ 'render.nu' } } }
@example "which skills got used, across every project" { claude-nu sessions --all-projects --columns skill_invocations | get skill_invocations | flatten | uniq --count | sort-by count --reverse }
@example "sessions by token spend" { claude-nu sessions --columns token_usage,session_id | insert total {|r| $r.token_usage.input_tokens + $r.token_usage.output_tokens } | sort-by total --reverse }
@example "the largest sessions of every project" { claude-nu sessions --all-projects --columns size,modified | sort-by size --reverse | first 5 }
@example "what I worked on last week" { claude-nu sessions --all-projects --since 1wk --columns summary,cwd }
@example "sessions open at some point on a given day" { claude-nu sessions --all-projects --active-since 2026-08-04 --active-until 2026-08-05 --columns summary,first_timestamp,last_timestamp }
@example "which agents this project spawned, workflow agents by run and phase" { claude-nu sessions --subagents --columns agent_id,agent_type,workflow,agent_label,phase | where parent_session_id != null }
export def main [
    ...paths: path # Session files or directories to parse (default: current project sessions)
    --session: string@"nu-complete claude sessions" # Single session: UUID, a unique UUID prefix (`9787e004`), a subagent id (`agent-…`), the name set by /rename or `claude --name`, or path
    --last # Only the most recent session of the current project
    --all-projects # Enumerate sessions across every project under ~/.claude/projects
    --subagents # Also list subagent transcripts (<uuid>/subagents/agent-*.jsonl); off by default
    --columns (-c): string@"nu-complete claude session-columns" # Comma-separated columns to include (default: overview set)
    --all-columns # Include all columns
    --since: any # Only sessions last active at or after this point — a duration means ago (`1wk`), or a datetime/date string
    --until: any # Only sessions last active at or before this point
    --active-since: any # Only sessions whose records reach this point: last_timestamp at or after it — same values as --since
    --active-until: any # Only sessions whose records start by this point: first_timestamp at or before it
]: [nothing -> table string -> table record -> table table -> table list<string> -> table] {
    let input = $in
    # Why up here: a misspelled bound must fail before any session is parsed.
    let since_at = if $since == null { null } else { $since | resolve-time-bound "--since" }
    let until_at = if $until == null { null } else { $until | resolve-time-bound "--until" }
    let active_since_at = if $active_since == null { null } else { $active_since | resolve-time-bound "--active-since" }
    let active_until_at = if $active_until == null { null } else { $active_until | resolve-time-bound "--active-until" }
    # Why exclusive: the two pairs ask one question on two clocks — file mtime
    # and record time — and a call mixing them answers a window nobody named.
    if ($since_at != null or $until_at != null) and ($active_since_at != null or $active_until_at != null) {
        error make {
            msg: "--since/--until and --active-since/--active-until are mutually exclusive"
            help: "--since/--until compare the file mtime, --active-* the record timestamps — pick one clock"
        }
    }
    let active_window = $active_since_at != null or $active_until_at != null
    # Why: piped string is a target path (`"dir" | sessions`); piped table
    # carries path/session columns like the other commands accept.
    let piped_path = if ($input | describe) == "string" { $input } else { null }
    let piped_files = if $piped_path == null { resolve-piped-sessions $input } else { null }

    # Why data-driven: every scope selector excludes every other, so one check
    # over the active set covers all pairs — the old pairwise ifs had to
    # hand-enumerate each combination and could miss one.
    let active_scopes = [
        [scope active];
        ["piped input" ($piped_files != null or $piped_path != null)]
        ["--session" ($session != null)]
        ["--last" $last]
        ["--all-projects" $all_projects]
        ["explicit paths" ($paths | is-not-empty)]
    ]
    | where active
    | get scope
    if ($active_scopes | length) > 1 {
        error make $"($active_scopes | str join ' and ') are mutually exclusive — pick one session scope"
    }
    # Why: --last/--session resolve to a single file — a subagent one when
    # --session names `agent-<id>` — so there is nothing to widen with
    # subagents; flag it as a no-op rather than silently ignore.
    if $subagents and ($last or $session != null) {
        print --stderr "claude-nu sessions: --subagents has no effect with --last/--session — those select a single session"
    }

    let session_rows = if $session != null or $last {
        # Why: parse-session defaulted to the most recent session; after the
        # merge (bare scope = whole project) --last keeps that workflow.
        [(resolve-session-file $session)] | expand-session-paths
    } else if $all_projects {
        let projects_dir = projects-root
        if not ($projects_dir | path exists) {
            error make "No projects directory found"
        }
        ls $projects_dir | where type == dir | get name | expand-session-paths --subagents=$subagents
    } else if $piped_files != null {
        # Why the early return: an empty piped selection is an empty answer, so
        # `sessions | where false | sessions` yields nothing — it must not fall
        # through to the default scope and silently widen back to the project.
        if ($piped_files | is-empty) { return [] }
        $piped_files | expand-session-paths --subagents=$subagents
    } else {
        # Why: piped rows and positional paths mean the same thing (`projects |
        # sessions` pipes project dirs), so they share one expansion.
        $paths
        | if ($in | is-empty) { [($piped_path | default (get-sessions-dir))] } else { }
        | expand-session-paths --subagents=$subagents
    }

    if ($session_rows | is-empty) {
        error make "No session files found"
    }

    # Why after that error and not before: "no sessions exist here" is a broken
    # scope, but a window that matches nothing is a legitimate empty answer.
    # Why the file mtime and not a parsed first/last timestamp: deciding which
    # sessions fall in the window would then have to parse every session — the
    # exact cost the window exists to avoid. mtime is the session's last
    # activity, the same clock that already orders every listing here.
    let session_rows = $session_rows
        | if $since_at == null { } else { where modified >= $since_at }
        | if $until_at == null { } else { where modified <= $until_at }
        # Why a first cut on mtime: a file is written when a record is appended,
        # so its mtime is never earlier than its last record — a file untouched
        # since before --active-since cannot reach into the window, and it is
        # skipped unparsed. --active-until has no such cut: a file written today
        # may have started months ago.
        | if $active_since_at == null { } else { where modified >= $active_since_at }

    let all_names = $SESSION_COLUMNS | get name

    # Why: --columns is a comma-separated string (see the completer) — split,
    # trim, and drop empties so "version, cwd" and a trailing comma are forgiving.
    # uniq because `select` rejects a repeated name.
    let requested = $columns
        | default ""
        | split row ','
        | str trim
        | where $it != ""
        | uniq

    if $all_columns and ($requested | is-not-empty) {
        error make {
            msg: "--columns and --all-columns are mutually exclusive"
            labels: [
                {text: "these columns" span: (metadata $columns).span}
                {text: "...and every column" span: (metadata $all_columns).span}
            ]
            help: "drop one — --all-columns already covers every name --columns could ask for"
        }
    }

    let selected = if $all_columns {
        $all_names
    } else if ($requested | is-empty) {
        $SESSION_COLUMNS | where default | get name
    } else {
        # Why: fail fast on a typo'd column name — parse-session-columns would
        # otherwise silently omit it, hiding the mistake.
        # Why the two row columns are accepted and dropped here: every row
        # carries them anyway, and the help names them, so asking for one is
        # not a typo — it was refused as an unknown column.
        let unknown = $requested | difference $all_names | difference $ROW_COLUMNS
        if ($unknown | is-not-empty) {
            error make {
                msg: $"Unknown session column\(s): ($unknown | str join ', ')"
                label: {text: "not a session column" span: (metadata $columns).span}
                help: $"valid columns: ($all_names | append $ROW_COLUMNS | str join ', ')"
            }
        }
        $requested | difference $ROW_COLUMNS
    }

    let listed = $selected | where $it in $LISTING_COLUMNS
    # Why the span is parsed with the selection: the overlap needs it, and a
    # separate pass would read every file in the window twice.
    let parsed = $selected
        | where $it not-in $LISTING_COLUMNS
        | if $active_window { append [first_timestamp last_timestamp] | uniq } else { }

    $session_rows | each {|row|
        # Why the listing columns bypass the parse: past agents mostly listed
        # sessions to sort them by size or mtime, and `--columns size,modified`
        # over every project should cost one `ls`, not a read of every file.
        let from_records = if ($parsed | is-empty) { {} } else { $row.path | parse-session-columns $parsed | reject path }
        # Why overlap and not containment: the question is "what was I doing
        # then", and a session open across the whole window was doing it.
        # A session with no timestamped record has no span, so it is never in one.
        let in_window = not $active_window or (
            $from_records.first_timestamp != null
            and ($active_since_at == null or $from_records.last_timestamp >= $active_since_at)
            and ($active_until_at == null or $from_records.first_timestamp <= $active_until_at)
        )
        if not $in_window { return null }
        let from_listing = if ($listed | is-empty) { {} } else { $row | select ...$listed }
        $from_records
        | merge $from_listing
        | select ...$selected
        | insert path $row.path
        | insert parent_session_id $row.parent_session_id
    }
}

# Export session dialogue to markdown.
# Scope by piping session rows in — `sessions --session <uuid> | export-session`
# for one, `sessions | export-session` for the whole project. With no input it
# reads the current project's most recent session.
# Why no `--session` here: selection lives in `sessions` alone (see the note on
# `messages`).
# Why markdown out, not a record: saving is the shell's job (`| save file.md`),
# and the record only repeated what the markdown already carries — session and
# date in the frontmatter, the title in the H1.
@category claude-nu
export def export-session [
    title?: string # Title for the exported doc, used as given (default: session summary)
    --tools # Keep tool calls: each tool_use input in full as a fenced NUON block, each result as a char count (default: drop)
]: [nothing -> string record -> any table -> list<string> list<string> -> list<string>] {
    let input = $in
    let piped_files = piped-session-files $input

    if $piped_files != null and $title != null {
        error make {
            msg: "Piped input conflicts with title argument"
            label: {
                text: "a title names one document, but the pipe may carry several sessions"
                span: (metadata $title).span
            }
            help: "drop the title, or pipe one session at a time"
        }
    }

    let export_one = {|session_file|
        if not ($session_file | path exists) {
            error make --unspanned $"Session file not found: ($session_file)"
        }

        let records = $session_file | read-session-records

        if ($records | is-empty) {
            error make "Session file is empty"
        }

        let summary = $records | extract-summary

        # Title: the argument as given; the summary fallback gets title-cased.
        # Why no slug pass anymore: lowercasing and hyphens served the filename,
        # which went away with --to.
        let doc_title = $title
            | default ((if $summary != "" { $summary } else { "session" }) | str title-case)

        # Date from the first user record, or now
        let first_timestamp = $records
            | where type? == "user"
            | get timestamp --optional
            | compact
            | if ($in | is-empty) { [(date now)] } else { }
            | first
            | into datetime

        # Extract dialogue: user messages and assistant responses
        let dialogue = $records
            | extract-dialogue {|r| if $tools { $r | render-content --tools } else { $r | extract-text-content }}
            # Why: a tool result rides on a user record, but nobody typed it —
            # it continues the assistant's turn. Left as `user`, --tools gave
            # every result its own `## User` header: 95 for 23 typed messages.
            # The same holds for the text Claude Code writes beside a result
            # ("Tool loaded."): only text the user wrote makes it a user turn.
            | update type {|r|
                let blocks = $r.message?.content? | content-blocks
                let typed = $blocks | where type? == "text" | any {|b| $b.text | is-user-text }
                if ($blocks | any {|b| $b.type? == "tool_result" }) and not $typed { "assistant" } else { $r.type }
            }
            | select type text
            | rename role content
            # Merge consecutive same-role messages
            | chunk-by {|r| $r.role }
            | each {|chunk| {role: $chunk.0.role content: ($chunk.content | str join "\n\n")} }

        # Format as markdown
        let session_id = $session_file | session-id-from-path

        let frontmatter = {
            date: ($first_timestamp | format date '%Y-%m-%d')
            session: $session_id
        }
        | if $summary != "" { insert summary $summary } else { }
        | to yaml
        | $"---\n($in)---\n"

        let heading = $"# ($doc_title)"

        let body = $dialogue
            | each {|turn|
                let role = match $turn.role { "user" => "User" _ => "Assistant" }
                $"## ($role)\n\n($turn.content)"
            }
            | str join "\n\n"

        # Why the trailing "": the doc ends with a newline, as text files do —
        # `save` writes the string as is, and `gi import` builds on it unchanged.
        [$frontmatter "" $heading "" $body ""] | str join "\n" | trim-line-ends
    }

    if $piped_files != null {
        $piped_files
        | each {|f| do $export_one $f }
        # A single piped row that names one session: hand back its markdown,
        # not a one-element list. A row that names a project directory stands
        # for all its sessions and keeps the list — `first` silently dropped
        # every session but the newest. The row decides, not the count: a
        # project holding one session is still a project.
        | if ($input | is-record) and ($piped_files | length) == 1 and ($input.path? | default "" | ansi strip | path type) != "dir" { first } else { }
    } else {
        do $export_one (resolve-session-file)
    }
}
