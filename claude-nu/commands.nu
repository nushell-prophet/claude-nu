# claude-nu - Nushell utilities for Claude Code

# UUID pattern for session files
const UUID_JSONL_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# Subagent JSONL pattern (Claude Code 2.1.138+ layout:
# `<project>/<session-uuid>/subagents/agent-<id>.jsonl`)
const AGENT_JSONL_PATTERN = 'agent-[0-9a-f]+\.jsonl$'

# System-generated message prefixes to filter out.
# Why: `!`-command wrappers (<bash-input>/<bash-stdout>/<bash-stderr>) are NOT
# here — they're a real user action, rendered as readable markdown by
# render-bash-wrapper instead of dropped. Only Claude Code's synthesized
# slash-command and caveat wrappers are filtered.
const SYSTEM_PREFIXES = [
    "<command-name>"
    "<command-message>"
    "<local-command-caveat>"
    "<local-command-stdout>"
    "<local-command-stderr>"
    "Caveat:"
]

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
    [slug false]
    [version false]
    [cwd false]
    [git_branch false]
    [thinking_level false]
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
]

# Root of Claude Code session storage: ~/.claude/projects
def projects-root []: nothing -> path {
    $env.HOME | path join ".claude" "projects"
}

# Sessions directory for the current project: ~/.claude/projects/<encoded-pwd>
export def get-sessions-dir []: nothing -> path {
    projects-root | path join ($env.PWD | path expand | str replace --all '/' '-')
}

# Project directory name a session file belongs to — the first path segment
# under ~/.claude/projects. Why: `path dirname` is right for top-level files
# (<root>/<proj>/<uuid>.jsonl) but wrong for subagent transcripts
# (<root>/<proj>/<uuid>/subagents/agent-*.jsonl), where it yields "subagents" —
# that mislabels rows and falsely trips multi-project tagging inside one
# project. Files outside the root fall back to their parent directory name.
def project-dir-name []: path -> string {
    let file = $in
    let rel = try { $file | path relative-to (projects-root) } catch { null }
    if $rel == null {
        $file | path dirname | path basename
    } else {
        $rel | path split | first
    }
}

# List Claude Code projects under ~/.claude/projects, most recent first.
# `name` is the last two segments of the real project path; `path` is the
# sessions directory, so rows pipe straight into `sessions`.
export def projects []: nothing -> table {
    let projects_root = projects-root
    if not ($projects_root | path exists) { return [] }

    ls $projects_root
    | where type == dir
    | sort-by modified --reverse
    | each {|dir|
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
            name: ($cwd | path split | last 2 | path join)
            path: $dir.name
            count: ($files | length)
            modified: $dir.modified
        }
    }
    | compact
}

# Resolve session file path from UUID, path, or default to most recent
export def resolve-session-file [
    session?: string # Session UUID or path (null = most recent)
    --sessions-dir: path # Override sessions directory
]: nothing -> path {
    let dir = $sessions_dir | default (get-sessions-dir)

    if $session != null {
        if ($session | str ends-with '.jsonl') {
            return $session
        }
        let candidate = $dir | path join $"($session).jsonl"
        if ($candidate | path exists) {
            return $candidate
        }
        # Why: UUIDs are globally unique, but piped rows (or --session) may
        # point at a session from another project — search all projects
        # before giving up.
        let found = glob (projects-root | path join $"*/($session).jsonl")
        if ($found | is-empty) {
            error make {msg: $"Session not found in any project: ($session)"}
        }
        return ($found | first)
    }

    if not ($dir | path exists) {
        error make {msg: "No sessions directory found for current project"}
    }

    # Why: one discoverer owns the listing and recency order, so "most recent
    # session" is the first top-level (non-subagent) row it yields.
    let files = discover-session-files $dir | where parent_session_id == null

    if ($files | is-empty) {
        error make {msg: "No session files found"}
    }

    $files | first | get path
}

# Session UUID from a session file path
def session-id-from-path []: path -> string {
    path basename | str replace '.jsonl' ''
}

# Read a session JSONL file into a table of records, one record per line. The
# single decode point for a session's raw records: every full-file parser goes
# through here, so "a session is one JSON object per line" lives in one place
# (and any future empty/corrupt-line handling has a single home).
# Why (speed): `from json --objects` decodes the whole NDJSON stream in one call
# instead of `lines | each { from json }`, which restarts the parser per line —
# ~1.25x faster across every session parse. --contains pre-screens the raw lines
# by substring before decoding, so a caller wanting one record type (messages
# wants user turns — only ~30% of lines) never parses the rest; the caller still
# re-filters the decoded `type`, so a line merely quoting the marker can't slip in.
def read-session-records [--contains: string]: path -> table {
    open --raw $in
    | if $contains == null { } else { lines | where ($it | str contains $contains) | str join "\n" }
    | from json --objects
}

# Completion for session UUIDs
export def "nu-complete claude sessions" []: nothing -> record {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        return {options: {sort: false} completions: []}
    }

    let completions = ls $sessions_dir
        | where name =~ $UUID_JSONL_PATTERN
        | each {|file|
            let uuid = $file.name | session-id-from-path
            let size = $file.size | into string
            let raw_lines = try { open --raw $file.name | lines } catch { [] }
            # Why: the title lives in summary/ai-title records anywhere in the
            # file. String-match first so a Tab press never JSON-parses whole
            # session files; extract-summary then filters false-positive lines
            # (e.g. messages quoting the pattern) by record type.
            let summary = $raw_lines
                | where $it =~ '"type":"(summary|ai-title)"'
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
            {value: $uuid description: $"($age), ($size): ($summary)" timestamp: $timestamp}
        }
        | sort-by timestamp --reverse
        | select value description

    {
        options: {sort: false}
        completions: $completions
    }
}

# Extract user messages from Claude Code session files.
# Scope by piping session rows in — `sessions | messages` for one project,
# `sessions --all-projects | messages` for every project. `sessions` lists only
# top-level human sessions by default, so these carry no agent turns; add
# `sessions --subagents` if you deliberately want subagent transcripts too. With
# no input it reads the current project's most recent session.
# Why: selection lives in one place (`sessions`); messages just reads what it's
# handed. This also kills the old `--all-projects` take-1 footgun (see
# todo/20260618-225035) — "all" now means all, because the caller controls it.
export def messages [
    regex?: string # Filter messages by regex pattern
    --session: string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --include-system # Include system/meta messages (not just user-typed)
    --include-thinking # Include assistant thinking blocks (prefixed with [thinking])
    --raw # Return raw message records instead of just content
    --include-responses # Include assistant responses (text only, interleaved)
]: [nothing -> table record -> table table -> table] {
    let input = $in
    let piped_files = resolve-piped-sessions $input

    if $piped_files != null and $session != null {
        error make {msg: "Piped input conflicts with --session"}
    }

    let session_files = if $piped_files != null {
        $piped_files
    } else {
        [(resolve-session-file $session)]
    }

    # Why: when the piped sessions span more than one project, tag each row with
    # its project so cross-project search stays traceable; a single-project
    # scope keeps the lean output.
    let multi_project = ($session_files | each { project-dir-name } | uniq | length) > 1

    $session_files
    | each {|session_file|
        if not ($session_file | path exists) {
            error make {msg: $"Session file not found: ($session_file)"}
        }

        let session_uuid = $session_file | session-id-from-path

        # Why: --include-thinking surfaces thinking-only assistant turns
        # (otherwise dropped by the empty-text filter). User text always goes
        # through extract-text-content, keeping its contract for other callers.
        let extract_assistant = if $include_thinking {
            {|r| $r | extract-text-with-thinking }
        } else {
            {|r| $r | extract-text-content }
        }
        let extract_text = {|r|
            match $r.type? {
                "assistant" => (do $extract_assistant $r)
                _ => ($r | extract-text-content)
            }
        }

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

        let filtered = $dialogue
            | if $regex == null { } else { where text =~ $regex }

        if $raw {
            $filtered | reject text | sort-by timestamp
        } else {
            $filtered
            | each {|msg| {role: $msg.type message: $msg.text timestamp: ($msg.timestamp? | into datetime)} }
            | sort-by timestamp
            | if $include_responses { } else { reject role }
        }
        # Why: rows are self-describing — the session column makes messages
        # output a valid session selector for resolve-piped-sessions, so it
        # can pipe back into messages/export-session/sessions.
        | each { insert session $session_uuid }
        | if $multi_project {
            insert project ($session_file | project-dir-name)
        } else { }
    }
    | flatten
}

# Reverse the HTML entity escaping Claude Code applies to `!`-command output
# (the `<`/`>`/`&` inside <bash-stdout>/<bash-stderr> arrive as &lt;/&gt;/&amp;).
# &amp; is undone last so a literal "&amp;lt;" decodes to "&lt;", not "<".
def unescape-html []: string -> string {
    str replace --all '&lt;' '<'
    | str replace --all '&gt;' '>'
    | str replace --all '&quot;' '"'
    | str replace --all '&#39;' "'"
    | str replace --all '&amp;' '&'
}

# Render a `!`-command user record's string content as readable markdown.
# `<bash-input>CMD</bash-input>` -> a `sh` code block; the paired
# `<bash-stdout>OUT</bash-stdout><bash-stderr>ERR</bash-stderr>` record -> the
# captured output as a plain code block (stderr flagged). Non-bash strings pass
# through untouched. Tags are split by literal string (not regex): real output
# has its own `<`/`>` HTML-escaped, so the wrapper tags are the only literal
# ones, and a missing closing tag (test fixtures) still degrades cleanly.
# Why: a `!` command is a real user action, but Claude Code stores it in these
# wrappers; without rendering, export-session/messages drop the user's command.
def render-bash-wrapper []: string -> string {
    let s = $in
    if ($s | str starts-with "<bash-input>") {
        let cmd = $s
            | str replace "<bash-input>" "" | str replace "</bash-input>" ""
            | unescape-html | str trim
        $"```sh\n($cmd)\n```"
    } else if ($s | str starts-with "<bash-stdout>") {
        let parts = $s | split row "<bash-stderr>"
        let out = $parts.0
            | str replace "<bash-stdout>" "" | str replace "</bash-stdout>" ""
            | unescape-html | str trim
        let err = $parts.1? | default ""
            | str replace "</bash-stderr>" ""
            | unescape-html | str trim
        [
            (if ($out | is-not-empty) { $"```\n($out)\n```" })
            (if ($err | is-not-empty) { $"```\n[stderr]\n($err)\n```" })
        ] | compact | str join "\n\n"
    } else { $s }
}

# Shared dispatch on message content shape: string content passes through
# render-bash-wrapper (a no-op unless it's a `!`-command wrapper), content block
# lists go through $render, anything else yields "".
def render-message-content [render: closure]: record -> string {
    let content = $in.message?.content?
    match ($content | describe) {
        "string" => { $content | render-bash-wrapper }
        $t if ($t =~ '^(list|table)') => { $content | do $render }
        _ => { "" }
    }
}

# Helper to extract text content from a message
export def extract-text-content []: record -> string {
    # Why: text blocks join with no separator (unlike render-content's "\n\n")
    # — callers like user_msg_length count exact characters.
    render-message-content { where type? == "text" | get text --optional | str join }
}

# Like extract-text-content but also surfaces thinking blocks, prefixed with
# `[thinking]` so they're distinguishable from regular text. Blocks are
# rendered in source order and joined with blank lines.
# Why: messages --include-thinking exposes thinking-only assistant turns that
# the visible-text filter would otherwise drop.
export def extract-text-with-thinking []: record -> string {
    render-content --thinking
}

# False when text is one of the command/tool/caveat wrappers Claude Code
# synthesizes around a turn — i.e. not a human-typed message (see SYSTEM_PREFIXES).
def is-user-text []: string -> bool {
    let text = $in
    $SYSTEM_PREFIXES | all {|p| not ($text | str starts-with $p) }
}

# Build a dialogue table from raw session records: the user and assistant turns
# with their visible text. Drops meta turns, empty-text turns, and the user-side
# system/command wrappers Claude Code synthesizes. `extract` renders each record's
# text, so callers pick plain text, +thinking, or tool placeholders. Pass
# --keep-system to retain meta and system-wrapper turns (messages --include-system).
# Why: messages and export-session both built this same dialogue+filter pass; one
# source keeps the system-prefix rule from drifting between them.
def extract-dialogue [extract: closure --keep-system]: table -> table {
    where type? in ["user" "assistant"]
    | if $keep_system { } else { where isMeta? != true }
    | insert text {|r| do $extract $r }
    | where {|r| $r.text | str trim | is-not-empty }
    | if $keep_system { } else {
        where {|r| $r.type? != "user" or ($r.text | is-user-text) }
    }
}

# Authored user-message text from a record set — exactly the user messages
# `messages` returns: tool-result records (render to ""), meta turns, and the
# command/caveat wrappers Claude Code synthesizes are all dropped (via
# extract-dialogue / is-user-text).
# Why: the user_msg_* columns and turn_count must agree with `messages` on what
# a user message is. The old "any non-empty user record" rule counted /clear and
# <local-command-caveat> wrappers as messages, inflating every count and dumping
# that wrapper text into the default `user_messages` column.
def user-message-texts []: table -> list<string> {
    where type? == "user"
    | extract-dialogue {|r| $r | extract-text-content }
    | get text
}

# Helper to extract tool calls from assistant messages
export def extract-tool-calls []: record -> table {
    $in.message?.content?
    | if ($in | describe) =~ '^(list|table)' {
        where type? == "tool_use"
    } else { [] }
}

# Extract tool results from user records (responses to tool calls)
export def extract-tool-results []: table -> table {
    each {|r|
        let content = $r.message?.content?
        if ($content | describe) =~ '^(list|table)' {
            $content | where type? == "tool_result"
        } else { [] }
    }
    | flatten
}

# Extract a session summary string from records.
# Why: 2.1.x sessions rarely carry a `summary` record; the canonical short
# summary now lives in `ai-title.aiTitle`. Prefer the legacy `summary`
# record when present, fall back to `ai-title.aiTitle`.
export def extract-summary []: table -> string {
    let records = $in
    let from_summary = $records | where type? == "summary" | get 0?.summary?
    if ($from_summary | is-not-empty) {
        return $from_summary
    }
    # Why: Claude Code rewrites ai-title as the session evolves; the last
    # record carries the current title, matching what the app shows.
    $records | where type? == "ai-title" | reverse | get 0?.aiTitle? | default ""
}

# First non-null value of a field across records, "" when absent
def pick-first [field: cell-path]: table -> string {
    get $field --optional | compact | first | default ""
}

# Extract session metadata from records, walking each one to find each field.
# Why: in 2.1.x first record can be permission-mode (sessionId only) or
# file-history-snapshot (no metadata). A "first non-summary record" lookup
# returns mostly empty fields; instead pull each field from the first record
# that actually carries it.
export def extract-session-metadata []: table -> record {
    let records = $in
    {
        session_id: ($records | pick-first $.sessionId)
        slug: ($records | pick-first $.slug)
        version: ($records | pick-first $.version)
        cwd: ($records | pick-first $.cwd)
        git_branch: ($records | pick-first $.gitBranch)
    }
}

# Extract thinking level from user records
export def extract-thinking-level []: table -> string {
    pick-first $.thinkingMetadata.level
}

# Extract first/last timestamps from user records
export def extract-timestamps []: table -> record {
    let ts = get timestamp --optional
        | compact
        | each { into datetime }
    {
        first: ($ts | first)
        last: ($ts | last)
    }
}

# Extract file operations from tool calls
export def extract-file-operations []: table -> record {
    let tool_calls = $in
    {
        edited_files: ($tool_calls | where name? in ["Edit" "Write"] | get input.file_path --optional | uniq)
        read_files: ($tool_calls | where name? == "Read" | get input.file_path --optional | uniq)
    }
}

# Extract agent info from tool calls
# Why: 2.1.x renamed `Task` to `Agent`; both share input shape.
# TaskCreate/Update/Stop are TODO-list ops with different schema, not agents.
export def extract-agents []: table -> table {
    where name? in ["Task" "Agent"]
    | each {
        {
            type: ($in.input?.subagent_type? | default "unknown")
            description: ($in.input?.description? | default "")
        }
    }
}

# Extract tool statistics from tool calls and results
# Why: tool catalog grew in 2.1.x; count newly-added names so users can see
# whether/how often they appear in a session.
export def extract-tool-stats [
    tool_results: table
]: table -> record {
    let tool_calls = $in
    let bash_cmds = $tool_calls | where name? == "Bash" | get input.command --optional
    {
        bash_commands: $bash_cmds
        bash_count: ($bash_cmds | length)
        skill_invocations: ($tool_calls | where name? == "Skill" | get input.skill --optional)
        tool_errors: ($tool_results | where is_error? == true | length)
        ask_user_count: ($tool_calls | where name? == "AskUserQuestion" | length)
        plan_mode_used: ($tool_calls | where name? == "EnterPlanMode" | is-not-empty)
        tool_counts: {
            TaskCreate: ($tool_calls | where name? == "TaskCreate" | length)
            TaskUpdate: ($tool_calls | where name? == "TaskUpdate" | length)
            TaskStop: ($tool_calls | where name? == "TaskStop" | length)
            Monitor: ($tool_calls | where name? == "Monitor" | length)
            ToolSearch: ($tool_calls | where name? == "ToolSearch" | length)
        }
    }
}

# Extract derived metrics from session data
export def extract-derived-metrics [
    assistant_records: table
    tool_calls: table
]: table -> record {
    {
        # Why: a turn is one authored user message — same definition as the
        # user_msg_* columns and `messages` (tool-result, meta, and command/
        # caveat wrapper records all excluded), so the metrics can't disagree.
        turn_count: ($in | user-message-texts | length)
        assistant_msg_count: ($assistant_records | length)
        tool_call_count: ($tool_calls | length)
    }
}

# Why: math sum errors on empty input in nu 0.107; every column sum
# (token usage, user_msg_length, response_length) guards through this.
def sum-or-zero []: list -> int {
    if ($in | is-empty) { 0 } else { math sum }
}

# Aggregate token usage across assistant records.
# Why: costUSD is null for subscription users, so token counts are the only
# usable cost/effort signal. Usage lives at message.usage per assistant turn;
# the nested `iterations`/`cache_creation` breakdowns are ignored — the
# top-level fields already hold the per-message totals.
export def extract-token-usage []: table -> record {
    let usages = get message.usage --optional | compact
    let sum = {|field| $usages | get $field --optional | compact | sum-or-zero }
    {
        input_tokens: (do $sum "input_tokens")
        output_tokens: (do $sum "output_tokens")
        cache_creation_input_tokens: (do $sum "cache_creation_input_tokens")
        cache_read_input_tokens: (do $sum "cache_read_input_tokens")
    }
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
        $user_records | extract-timestamps
    } else { {first: null last: null} }

    let file_ops = if (do $need [read_files edited_files]) {
        $all_tool_calls | extract-file-operations
    } else { {} }

    let agent_list = if (do $need [agents agent_count]) {
        $all_tool_calls | extract-agents
    } else { [] }

    let meta = if (do $need [session_id slug version cwd git_branch]) {
        $records | extract-session-metadata
    } else { {} }

    let thinking = if ("thinking_level" in $selected) {
        $user_records | extract-thinking-level
    } else { "" }

    let tool_stats = if (do $need [
        bash_commands bash_count skill_invocations tool_errors ask_user_count
        plan_mode_used tool_counts
    ]) {
        let tool_results = $user_records | extract-tool-results
        let stats = $all_tool_calls | extract-tool-stats $tool_results
        # Why: 2.1.x replaced EnterPlanMode tool calls with top-level
        # permission-mode records. Treat either signal as plan-mode.
        let from_records = $records | where type? == "permission-mode" | get permissionMode? | any { $in == "plan" }
        $stats | upsert plan_mode_used ($stats.plan_mode_used or $from_records)
    } else { {} }

    let metrics = if (do $need [turn_count assistant_msg_count tool_call_count]) {
        $user_records | extract-derived-metrics $assistant_records $all_tool_calls
    } else { {} }

    let usage = if ("token_usage" in $selected) {
        $assistant_records | extract-token-usage
    } else { {} }

    [
        {name: summary value: $summary}
        {name: first_timestamp value: $timestamps.first}
        {name: last_timestamp value: $timestamps.last}
        {name: user_msg_count value: ($user_messages | length)}
        {name: user_msg_length value: $user_msg_length}
        {name: response_length value: $response_length}
        {name: agent_count value: ($agent_list | length)}
        {name: agents value: $agent_list}
        {name: mentioned_files value: $mentioned_files}
        {name: read_files value: $file_ops.read_files?}
        {name: edited_files value: $file_ops.edited_files?}
        {name: user_messages value: $user_messages}
        {name: session_id value: $meta.session_id?}
        {name: slug value: $meta.slug?}
        {name: version value: $meta.version?}
        {name: cwd value: $meta.cwd?}
        {name: git_branch value: $meta.git_branch?}
        {name: thinking_level value: $thinking}
        {name: bash_commands value: $tool_stats.bash_commands?}
        {name: bash_count value: $tool_stats.bash_count?}
        {name: skill_invocations value: $tool_stats.skill_invocations?}
        {name: tool_errors value: $tool_stats.tool_errors?}
        {name: ask_user_count value: $tool_stats.ask_user_count?}
        {name: plan_mode_used value: $tool_stats.plan_mode_used?}
        {name: tool_counts value: $tool_stats.tool_counts?}
        {name: turn_count value: $metrics.turn_count?}
        {name: assistant_msg_count value: $metrics.assistant_msg_count?}
        {name: tool_call_count value: $metrics.tool_call_count?}
        {name: token_usage value: $usage}
    ]
    | where name in $selected
    | reduce --fold {} {|it acc| $acc | insert $it.name $it.value }
    | insert path $file_path
}

# True when a value is a record (which is a 1-row table once piped). Strips the
# `<...>` type detail so `record<a: int>` and a bare `record` both match.
def is-record []: any -> bool {
    ($in | describe | str replace --regex '<.*' '') == "record"
}

# Extract session file paths from piped input
# Returns null when input is not a table
export def resolve-piped-sessions [input: any]: nothing -> any {
    if ($input | describe) == "nothing" { return null }
    # Why: a record is a 1-row table (e.g. `sessions | first`); widen it here so
    # every piped command accepts a single row without the caller re-wrapping it.
    let input = if ($input | is-record) { [$input] } else { $input }
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
        $input | get session | ansi strip | uniq | each {|s| resolve-session-file $s }
    } else {
        error make {msg: "Piped input must have 'path' or 'session' column"}
    }
}

# Discover session files in a directory, newest first. Returns rows
# {path, parent_session_id, modified}; parent_session_id is the parent session
# UUID for subagent files (`<uuid>/subagents/agent-*.jsonl`), null for top-level
# files. Single source of truth for the on-disk session layout — every command
# that lists or picks session files goes through here, so the name patterns, the
# subagent walk, and the recency order live in one place. Callers wanting only
# human-driven sessions filter `where parent_session_id == null`.
export def discover-session-files [dir: path]: nothing -> table {
    # Why: top-level files sit directly in $dir, so one `ls` lists them with
    # their mtimes; an empty dir is just [], whereas `ls` on a no-match glob
    # errors — keeping the empty case graceful without a special branch.
    let top_level = ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | each {|f| {path: $f.name parent_session_id: null modified: $f.modified} }

    # Why: subagent transcripts are nested out of reach of a flat `ls`, so a glob
    # descends to them. The `**` is load-bearing: Workflow agents nest deeper, at
    # `<uuid>/subagents/workflows/wf_*/agent-*.jsonl`, so a single-level
    # `*/subagents/*.jsonl` silently misses them. The parent UUID is therefore the
    # first path segment under $dir (depth-independent), not "two levels up" —
    # two-up would yield `workflows` for the nested ones.
    # Why (speed): one `ls <glob>` stats every transcript in a single directory
    # walk; the old `glob | each { ls }` re-stated each file individually (~10x
    # slower on a project with many subagents). `ls` errors on a no-match glob, so
    # try/catch keeps the empty case graceful (matching `glob`'s old behavior).
    let subagent_files = try { ls (($dir | path join "*/subagents/**/*.jsonl") | into glob) } catch { [] }
        | where name =~ $AGENT_JSONL_PATTERN
        | each {|f|
            {path: $f.name parent_session_id: ($f.name | path relative-to $dir | path split | first) modified: $f.modified}
        }

    $top_level | append $subagent_files | sort-by modified --reverse
}

# Session files (current project, or every project with --all-projects) whose
# raw JSONL contains `pattern`, newest first. Uses ripgrep to skip files that
# cannot match before the costly JSON parse; without rg it returns every
# top-level session file and lets the caller's structured filter do the work.
# Subagent transcripts are excluded — they carry no human-typed messages.
# Why: rg scans the raw, escaped JSON, so it can't honor line anchors or match a
# JSON-escaped quote/backslash the way the structured regex on extracted text
# does. That only ever costs recall for such patterns; it never yields a wrong
# hit, because `claude-nu -f` re-applies the real regex to the parsed text. For
# ordinary word/phrase/regex searches rg and the structured filter agree (both
# use Rust's regex engine), and we open only the few files that can match
# instead of parsing every session in every project. --no-rg forces the full
# enumeration so the caller's regex runs against the extracted text with exact
# semantics — the escape hatch for a pattern rg's raw scan would under-match.
export def find-session-files [
    pattern: string # Regex (Rust syntax) matched against raw session JSONL
    --all-projects # Search every project under ~/.claude/projects, not just the current one
    --no-rg # Skip the ripgrep pre-filter; return every top-level file for the caller to filter
]: nothing -> list<path> {
    let rows = if $no_rg or (which rg | is-empty) {
        top-level-session-files --all-projects=$all_projects
    } else {
        rg-session-files $pattern --all-projects=$all_projects
    }
    if ($rows | is-empty) { return [] }
    $rows | sort-by modified --reverse | get path
}

# Top-level session files in scope as {path, modified} rows (no content filter).
# The rg-less fallback for find-session-files, and the single place the
# project-vs-all-projects enumeration lives.
def top-level-session-files [--all-projects]: nothing -> table {
    let dirs = if $all_projects {
        let root = projects-root
        if not ($root | path exists) { return [] }
        ls $root | where type == dir | get name
    } else {
        let dir = get-sessions-dir
        if not ($dir | path exists) { return [] }
        [$dir]
    }
    $dirs
    | each {|d| discover-session-files $d | where parent_session_id == null | select path modified }
    | flatten
}

# Top-level session files whose raw JSONL matches `pattern`, as {path, modified}.
# Why: --no-ignore --hidden so a stray .gitignore or the dot in ~/.claude can't
# hide a session; the subagents glob keeps us to human dialogue; the UUID-name
# guard mirrors discover-session-files' definition of a session file. The pattern
# goes through --regexp (which allows a leading `-`), not as a bare arg. rg exit
# 1 means "no match" (empty); only a real failure (exit 2+) errors — fail fast on
# a broken pattern instead of silently returning nothing.
def rg-session-files [pattern: string --all-projects]: nothing -> table {
    let root = if $all_projects { projects-root } else { get-sessions-dir }
    if not ($root | path exists) { return [] }
    let res = rg --no-ignore --hidden --files-with-matches --glob '*.jsonl' --glob '!**/subagents/**' --regexp $pattern -- $root | complete
    let files = match $res.exit_code {
        0 => ($res.stdout | lines)
        1 => []
        _ => (error make {msg: $"rg failed \(exit ($res.exit_code)): ($res.stderr | str trim)"})
    }
    $files
    | where ($it | path basename) =~ $UUID_JSONL_PATTERN
    | each {|p| {path: $p modified: (ls $p | get 0.modified) } }
}

# Completer for --columns: comma-separated session column names. Returns full
# comma-joined values (e.g. `slug,version`) so the menu re-spawns after each
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
    | where $it not-in $chosen
    | each {|c| if ($prefix | is-empty) { $c } else { $"($prefix),($c)" } }
}

# Parse Claude Code sessions for structured information.
# `--columns` selects what to compute (lazy — only requested extractions run);
# omit it for the default overview set, `--all-columns` for everything. Column
# names are listed in SESSION_COLUMNS (and tab-complete on --columns).
# By default only top-level (human-driven) sessions are listed; pass --subagents
# to also include subagent transcripts (those rows carry a non-null parent_session_id).
export def sessions [
    ...paths: path # Session files or directories to parse (default: current project sessions)
    --session: string@"nu-complete claude sessions" # Single session UUID or path
    --last # Only the most recent session of the current project
    --all-projects # Enumerate sessions across every project under ~/.claude/projects
    --subagents # Also list subagent transcripts (<uuid>/subagents/agent-*.jsonl); off by default
    --columns (-c): string@"nu-complete claude session-columns" # Comma-separated columns to include (default: overview set)
    --all-columns # Include all columns
]: [nothing -> table string -> table record -> table table -> table] {
    let input = $in
    # Why: piped string is a target path (`"dir" | sessions`); piped table
    # carries path/session columns like the other commands accept.
    let piped_path = if ($input | describe) == "string" { $input } else { null }
    let piped_files = if $piped_path == null { resolve-piped-sessions $input } else { null }

    if $all_projects and ($paths | is-not-empty) {
        error make {msg: "--all-projects and explicit paths are mutually exclusive"}
    }
    if $session != null {
        if ($paths | is-not-empty) { error make {msg: "--session and explicit paths are mutually exclusive"} }
        if $all_projects { error make {msg: "--session and --all-projects are mutually exclusive"} }
        if $last { error make {msg: "--session and --last are mutually exclusive"} }
    }
    if $last and ($all_projects or ($paths | is-not-empty)) {
        error make {msg: "--last cannot be combined with --all-projects or explicit paths"}
    }
    if ($piped_files != null or $piped_path != null) and ($session != null or $last or $all_projects or ($paths | is-not-empty)) {
        error make {msg: "Piped input conflicts with --session/--last/--all-projects/paths"}
    }
    # Why: --last/--session resolve to a single top-level file, so there are no
    # subagents to include — flag it as a no-op rather than silently ignore.
    if $subagents and ($last or $session != null) {
        print -e "claude-nu sessions: --subagents has no effect with --last/--session — those select a single top-level session"
    }

    let session_rows = if $piped_files != null {
        # Why: a piped path may be a project dir (`projects | sessions`) —
        # expand it like a positional dir; files are parsed as-is.
        $piped_files
        | each {|p|
            if ($p | path type) == "dir" {
                discover-session-files $p
            } else {
                [{path: $p parent_session_id: null}]
            }
        }
        | flatten
    } else if $session != null or $last {
        # Why: parse-session defaulted to the most recent session; after the
        # merge (bare scope = whole project) --last keeps that workflow.
        [{path: (resolve-session-file $session) parent_session_id: null}]
    } else {
        let target_paths = if $all_projects {
            let projects_dir = projects-root
            if not ($projects_dir | path exists) {
                error make {msg: "No projects directory found"}
            }
            ls $projects_dir | where type == dir | get name
        } else {
            $paths
            | if ($in | is-empty) {
                [($piped_path | default (get-sessions-dir))]
            } else { }
        }

        # Why: UUID/agent pattern filtering lives in discover-session-files
        # (directory scans only) — a file named explicitly or piped is parsed
        # as-is, whatever its name.
        $target_paths
        | each {|p|
            if not ($p | path exists) {
                error make {msg: $"Path not found: ($p)"}
            }
            if ($p | path type) == "dir" {
                discover-session-files $p
            } else {
                # Why: explicit file paths skip the layout-based parent
                # discovery — caller already pointed us at the file.
                [{path: $p parent_session_id: null}]
            }
        }
        | flatten
    }

    # Why: subagent transcripts hold agent-driven turns, not human messages, so
    # they are opt-in — the default scope is top-level sessions only. Explicitly
    # named/piped files carry parent_session_id == null, so they always pass.
    let session_rows = $session_rows
        | if $subagents { } else { where parent_session_id == null }

    if ($session_rows | is-empty) {
        error make {msg: "No session files found"}
    }

    let all_names = $SESSION_COLUMNS | get name

    # Why: --columns is a comma-separated string (see the completer) — split,
    # trim, and drop empties so "slug, cwd" and a trailing comma are forgiving.
    let requested = $columns
        | default ""
        | split row ','
        | each { str trim }
        | where $it != ""

    if $all_columns and ($requested | is-not-empty) {
        error make {msg: "--columns and --all-columns are mutually exclusive"}
    }

    let selected = if $all_columns {
        $all_names
    } else if ($requested | is-empty) {
        $SESSION_COLUMNS | where default | get name
    } else {
        # Why: fail fast on a typo'd column name — parse-session-columns would
        # otherwise silently omit it, hiding the mistake.
        let unknown = $requested | where $it not-in $all_names
        if ($unknown | is-not-empty) {
            error make {
                msg: $"Unknown session column\(s): ($unknown | str join ', ')"
                help: $"valid columns: ($all_names | str join ', ')"
            }
        }
        $requested
    }

    $session_rows | each {|row|
        if not ($row.path | path exists) {
            error make {msg: $"Session file not found: ($row.path)"}
        }
        $row.path | parse-session-columns $selected | insert parent_session_id $row.parent_session_id
    }
}

# Sanitize topic string for use in filename
export def sanitize-topic []: string -> string {
    str downcase
    | str replace --all --regex '[^a-z0-9]+' '-'
    | str trim --char '-'
    | str substring 0..<50
}

# Collapse whitespace (newlines, tabs, runs of spaces) to single spaces
# and truncate to a max length, appending an ellipsis on truncation.
def to-one-line [max: int]: string -> string {
    str replace --all --regex '\s+' ' '
    | str trim
    | if ($in | str length) > $max {
        $in | str substring 0..<$max | $in + "..."
    } else { }
}

# One-line summary of a tool_use input record for placeholder rendering.
# Picks the most informative scalar field (command, file_path, query, etc.)
# and falls back to a compact NUON dump.
def summarize-tool-input [input: any]: nothing -> string {
    if not (($input | describe) | str starts-with "record") { return "" }
    let cols = $input | columns
    let preferred = ["command" "file_path" "path" "pattern" "query" "url" "skill" "subagent_type" "description"]
    let key = $preferred | where {|k| $k in $cols } | get 0?
    if $key != null {
        let v = $input | get $key
        if ($v | describe) == "string" { $v } else { $v | to nuon }
    } else {
        $input | to nuon
    }
}

# Render a single content block as one line of markdown.
# text -> text as-is; with --thinking, thinking -> `[thinking]`-prefixed text;
# with --tools, tool_use/tool_result -> blockquote placeholder; else "".
def render-block [--tools --thinking]: record -> string {
    let block = $in
    match $block.type? {
        "text" => ($block.text? | default "")
        "thinking" if $thinking => $"[thinking] ($block.thinking? | default '')"
        "tool_use" if $tools => {
            let summary = summarize-tool-input $block.input? | to-one-line 120
            $"> [($block.name? | default 'tool'): ($summary)]"
        }
        "tool_result" if $tools => {
            let raw = $block.content?
            let txt = match ($raw | describe) {
                "string" => $raw
                $t if ($t =~ '^(list|table)') => {
                    $raw | where type? == "text" | get text --optional | str join " "
                }
                _ => ""
            }
            let n = $txt | str length
            let err = if $block.is_error? == true { " error" } else { "" }
            $"> [result($err): ($n) chars]"
        }
        _ => ""
    }
}

# Render a record's content blocks as markdown text, one block per paragraph.
# Flags pass through to render-block: --tools renders tool_use/tool_result as
# one-line blockquote placeholders, --thinking renders thinking blocks.
def render-content [--tools --thinking]: record -> string {
    render-message-content {
        each { render-block --tools=$tools --thinking=$thinking }
        | where { $in | is-not-empty }
        | str join "\n\n"
    }
}

# Export session dialogue to structured data with markdown
export def export-session [
    topic?: string # Topic for filename (default: session summary)
    --session: string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --tools # Render tool_use/tool_result blocks as one-line blockquote placeholders (default: drop)
]: [nothing -> record record -> table table -> table] {
    let input = $in
    let piped_files = resolve-piped-sessions $input

    if $piped_files != null {
        if $session != null { error make {msg: "Piped input conflicts with --session"} }
        if $topic != null { error make {msg: "Piped input conflicts with topic argument"} }
    }

    let export_one = {|session_file|
        if not ($session_file | path exists) {
            error make --unspanned {msg: $"Session file not found: ($session_file)"}
        }

        let records = $session_file | read-session-records

        if ($records | is-empty) {
            error make {msg: "Session file is empty"}
        }

        let summary = $records | extract-summary

        # Determine topic: argument > summary > "session"
        let resolved_topic = $topic
            | default (if $summary != "" { $summary } else { "session" })
            | sanitize-topic

        # Get date from first user record or now
        let first_timestamp = $records
            | where type? == "user"
            | get timestamp --optional
            | compact
            | if ($in | is-empty) { [(date now | format date "%Y-%m-%dT%H:%M:%S")] } else { }
            | first
        let date_str = $first_timestamp | into datetime | format date "%Y%m%d"

        # Extract dialogue: user messages and assistant responses
        let dialogue = $records
            | extract-dialogue {|r| if $tools { $r | render-content --tools } else { $r | extract-text-content }}
            | select type text
            | rename role content
            # Merge consecutive same-role messages
            | reduce --fold [] {|turn acc|
                let prev = $acc | last
                if $prev != null and $prev.role == $turn.role {
                    $acc | upsert ($acc | length | $in - 1) {
                        role: $turn.role
                        content: $"($prev.content)\n\n($turn.content)"
                    }
                } else { $acc | append $turn }
            }

        # Format as markdown
        let session_id = $session_file | session-id-from-path
        let date_formatted = $first_timestamp | into datetime | format date '%Y-%m-%d'

        let frontmatter = {
            date: $date_formatted
            session: $session_id
        }
        | if $summary != "" {insert summary $summary} else {}
        | to yaml
        | $"---\n($in)---\n"


        let title = $"# ($resolved_topic | str replace --all '-' ' ' | str title-case)"

        let body = $dialogue
            | each {|turn|
                let role = match $turn.role { "user" => "User" _ => "Assistant" }
                $"## ($role)\n\n($turn.content)"
            }
            | str join "\n\n"

        let markdown = [$frontmatter "" $title "" $body] | str join "\n"

        {
            session: $session_id
            date: $date_str
            topic: $resolved_topic
            markdown: $markdown
        }
    }

    if $piped_files != null {
        $piped_files | each {|f| do $export_one $f }
    } else {
        do $export_one (resolve-session-file $session)
    }
}

# Save exported session markdown to files
export def save-markdown [
    --output-dir: path # Output directory (default: docs/sessions)
]: [record -> string table -> table] {
    let input = $in
    let out_dir = $output_dir | default "docs/sessions"
    let was_record = $input | is-record

    # Normalize to table
    let rows = if $was_record { [$input] } else { $input }

    let missing = [session date topic markdown] | where $it not-in ($rows | columns)
    if ($rows | is-not-empty) and ($missing | is-not-empty) {
        error make --unspanned {
            msg: $"input is missing columns: ($missing | str join ', ')"
            help: "save-markdown takes export-session output — pipe through it first: ... | claude-nu export-session | claude-nu save-markdown"
        }
    }

    let rows = $rows
        | insert filename {|r| $"($r.date)-($r.topic).md" }

    # Detect collisions: filenames shared by multiple sessions
    let collision_names = $rows
        | group-by filename
        | transpose key rows
        | where { $in.rows | length | $in > 1 }
        | get key

    let rows = $rows
        | update filename {|r|
            if $r.filename in $collision_names {
                $"($r.date)-($r.topic)-($r.session | str substring 0..5).md"
            } else { }
        }

    mkdir $out_dir

    let results = $rows
        | each {|r|
            let filepath = $out_dir | path join $r.filename
            $r.markdown | save -f $filepath
            {session: $r.session filepath: $filepath}
        }

    if $was_record {
        $results | first | get filepath
    } else {
        $results
    }
}

# =============================================================================
# gi-hook — a per-repo Stop hook that keeps the chat terse (gi protocol)
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. That rule rests on prose
# alone and fights the model's training — the agent drifts back to long chat
# answers. This installs a structural barrier instead of self-control: a
# Claude Code Stop hook that blocks the turn when the final chat message is
# more than `done`/`noted` or a short pointer, and tells the agent to move the
# answer into a document. Opt-in and per-repo, so the classic mode is untouched.
# =============================================================================

# Substring that identifies our Stop entry inside settings.local.json. Why: the
# command line is the only stable signature to match on for idempotent enable
# and surgical disable — see `gi-hook disable`.
const GI_HOOK_MARKER = "gi-hook check"

# The output-style name gi-hook installs. Why a const: enable writes it into
# settings.local.json (outputStyle) and disable removes it only if it still
# matches — so a user's own outputStyle is never clobbered. Matches the `name:`
# frontmatter in the seeded style file.
const GI_HOOK_STYLE = "Canvas"

# Absolute path to this module's directory, resolved at parse time. Why a const:
# `path self` only runs at parse time, and the hook needs an absolute `use`
# target — relative paths are not resolved when Claude Code runs the hook.
const GI_HOOK_MODULE_DIR = (path self | path dirname)

# Root of the current repo (git top-level), falling back to PWD outside a repo.
def gi-hook-repo-root []: nothing -> path {
    let top = do { ^git rev-parse --show-toplevel } | complete
    if $top.exit_code == 0 { $top.stdout | str trim } else { $env.PWD | path expand }
}

# Path to the per-repo, per-machine settings file the hook lives in. Why this
# file: it is already gitignored by Claude Code, so the hook stays local — it
# never reaches another checkout or the classic mode.
def gi-hook-settings-path [root: path]: nothing -> path {
    $root | path join ".claude" "settings.local.json"
}

# The shell command Claude Code runs for the Stop event. Single-quote the `-c`
# body so the outer shell does not expand `$in`; `--stdin` feeds the event JSON
# to nushell as `$in`. The absolute module path is required — relative paths are
# not resolved at hook time. `path self` anchors it to this file's directory.
def gi-hook-command []: nothing -> string {
    $"nu --stdin -c 'use \"($GI_HOOK_MODULE_DIR)\"; $in | claude-nu gi-hook check'"
}

# The Stop hook entry as stored under hooks.Stop[].
def gi-hook-entry [command: string]: nothing -> record {
    { hooks: [ { type: "command", command: $command } ] }
}

# The gi working-doc template that ships inside the module (so it vendors with
# it) and the place `enable` drops it in a target repo. Why a repo-local `gi/`:
# the gi protocol keeps the live working doc under version control, so it sits
# next to the code it drives, not in a dotfile.
def gi-hook-template-src []: nothing -> path {
    $GI_HOOK_MODULE_DIR | path join "gi" "canvas-header.md"
}

def gi-hook-template-dst [root: path]: nothing -> path {
    $root | path join "gi" "canvas-header.md"
}

# The output style gi-hook distributes: the template that ships inside the module
# and the project-level path it lands at. Why distribute a local copy: gi-hook is
# vendored on its own, so it must carry the style itself rather than depend on a
# Claude plugin being installed — `enable` drops it as a per-repo project style.
def gi-hook-style-src []: nothing -> path {
    $GI_HOOK_MODULE_DIR | path join "gi" "canvas-output-style.md"
}

def gi-hook-style-dst [root: path]: nothing -> path {
    $root | path join ".claude" "output-styles" "canvas.md"
}

# True if a Stop entry is one we installed (matches by command signature).
def gi-hook-is-ours []: record -> bool {
    $in.hooks?
    | default []
    | any {|h| ($h.command? | default "") | str contains $GI_HOOK_MARKER }
}

def gi-hook-open-settings [path: path]: nothing -> record {
    if ($path | path exists) { open $path } else { {} }
}

# The four gi-hook actions, surfaced as tab completions on the positional below.
def "nu-complete gi-hook-actions" []: nothing -> table {
    [
        [value description];
        [enable  "install the Stop hook in this repo"]
        [disable "remove it (leaves any other hooks intact)"]
        [status  "show whether it is installed"]
        [check   "hook body — reads the Stop event JSON on stdin"]
    ]
}

# gi-hook — install/remove a per-repo Stop hook that enforces terse chat (gi
# protocol). One command, one positional action (tab-completes); with no action
# it reports status. Why one command, not four subcommands: the four were just
# verbs on the same object — a positional with a completer is the same call
# surface (`gi-hook enable` still parses) with a single export to maintain.
export def "gi-hook" [
    action?: string@"nu-complete gi-hook-actions" # enable | disable | status | check (default: status)
    --root: path # Repo root (default: git top-level); ignored by check
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    match $action {
        null | "status" => (gi-hook-status --root $root)
        "enable" => (gi-hook-enable --root $root)
        "disable" => (gi-hook-disable --root $root)
        "check" => ($event | gi-hook-check)
        _ => {
            error make {
                msg: $"unknown gi-hook action: ($action)"
                label: { text: "expected enable, disable, status, or check", span: (metadata $action).span }
            }
        }
    }
}

# Install the Stop hook into this repo's .claude/settings.local.json.
# Idempotent: a second enable does not add a duplicate.
def gi-hook-enable [
    --root: path # Repo root to install into (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
    let command = gi-hook-command
    let settings = gi-hook-open-settings $path

    let stop = $settings.hooks?.Stop? | default []
    let already = $stop | any {|e| $e | gi-hook-is-ours }
    let stop = if $already { $stop } else { $stop | append (gi-hook-entry $command) }

    let hooks = $settings.hooks? | default {} | upsert Stop $stop
    mkdir ($path | path dirname)
    # Set outputStyle alongside the hook so the proactive style and the reactive
    # hook turn on together. Why both: the style shapes what gets written, the
    # hook is the hard floor — LLMs are non-deterministic, so the floor stays.
    $settings | upsert hooks $hooks | upsert outputStyle $GI_HOOK_STYLE | save --force $path

    # Seed the gi working-doc template. Why not clobber: once it exists it is
    # the user's live doc — refreshing it would destroy their edits.
    let template = gi-hook-template-dst $root
    if not ($template | path exists) {
        mkdir ($template | path dirname)
        cp (gi-hook-template-src) $template
    }
    # Distribute the output style as a per-repo project style. Same no-clobber
    # rule: the user may have edited their local copy.
    let style = gi-hook-style-dst $root
    if not ($style | path exists) {
        mkdir ($style | path dirname)
        cp (gi-hook-style-src) $style
    }
    # The style is read once at session start, so it won't apply until /clear or
    # a new session; the hook takes effect immediately.
    print "gi-hook enabled. Run /clear or start a new session for the Canvas output style to load."
    gi-hook-status --root $root
}

# Remove our Stop hook, leaving any other hooks intact. No-op if absent.
def gi-hook-disable [
    --root: path # Repo root to remove from (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
    if not ($path | path exists) { return (gi-hook-status --root $root) }

    let settings = gi-hook-open-settings $path
    let stop = $settings.hooks?.Stop? | default [] | where {|e| not ($e | gi-hook-is-ours) }
    # Prune emptied containers so disable leaves no orphan keys behind.
    let hooks = $settings.hooks? | default {}
    let hooks = if ($stop | is-empty) { $hooks | reject Stop? } else { $hooks | upsert Stop $stop }
    let settings = if ($hooks | is-empty) { $settings | reject hooks? } else { $settings | upsert hooks $hooks }
    # Drop outputStyle only if it is still ours — never clobber a value the user
    # set themselves. The seeded style and working doc are left in place (user files).
    let settings = if ($settings.outputStyle? == $GI_HOOK_STYLE) { $settings | reject outputStyle? } else { $settings }
    $settings | save --force $path
    gi-hook-status --root $root
}

# Report whether the hook is installed in this repo. Pipeline-friendly record.
def gi-hook-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
    let settings = gi-hook-open-settings $path
    let stop = $settings.hooks?.Stop? | default []
    let template = gi-hook-template-dst $root
    let style = gi-hook-style-dst $root
    {
        enabled: ($stop | any {|e| $e | gi-hook-is-ours })
        settings_path: $path
        command: (gi-hook-command)
        template_path: $template
        template_present: ($template | path exists)
        style_path: $style
        style_present: ($style | path exists)
        output_style_set: ($settings.outputStyle? == $GI_HOOK_STYLE)
    }
}

# Stop-hook body. Reads the event JSON on stdin and returns either nothing
# (allow the turn to end) or the block-decision JSON string. `nu -c` renders
# the return value to stdout, which is the Stop hook's control channel; the
# command always exits 0, per the contract. Returning (not printing) keeps it
# unit-testable.
def gi-hook-check []: string -> any {
    let payload = try { $in | default "" | from json } catch { {} }
    # Already continuing from a prior block — let it end to avoid a loop.
    if ($payload.stop_hook_active? | default false) { return }

    let message = $payload.last_assistant_message? | default ""
    if (gi-hook-allowed $message) { return }

    let reason = "Chat may carry only `done`/`noted` or a short pointer (one line with a path/link). Move the full answer into the working document and commit it; leave only a pointer in chat."
    { decision: "block", reason: $reason } | to json --raw
}

# The allow-rule: what may stand alone in chat. True (allowed) when, after trim:
# empty; or `done`/`noted` (trailing punctuation ok); or a short pointer — one
# line, within the length budget, carrying a link signal (backtick, `→`, or a
# filename). Everything else (prose, long unanchored lines) is blocked.
# Why a budget env-var: "short pointer" is fuzzy; GI_HOOK_MAX_LEN makes the
# threshold tunable without editing the hook. Default is strict — prose fails.
export def gi-hook-allowed [message: string]: nothing -> bool {
    let text = $message | str trim
    if ($text | is-empty) { return true }
    if (($text | str downcase | str replace -r '[.!…]+$' '') in ["done" "noted"]) { return true }

    let max = $env.GI_HOOK_MAX_LEN? | default 120 | into int
    let single_line = not ($text | str contains "\n")
    let within = ($text | str length) <= $max
    let has_signal = ($text =~ '`') or ($text =~ '→') or ($text =~ '[\w./-]+\.\w+')
    $single_line and $within and $has_signal
}
