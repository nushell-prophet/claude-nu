# claude-nu - Nushell utilities for Claude Code

# UUID pattern for session files
const UUID_JSONL_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# Subagent JSONL pattern (Claude Code 2.1.138+ layout:
# `<project>/<session-uuid>/subagents/agent-<id>.jsonl`)
const AGENT_JSONL_PATTERN = 'agent-[0-9a-f]+\.jsonl$'

# System-generated message prefixes to filter out
const SYSTEM_PREFIXES = [
    "<command-name>"
    "<command-message>"
    "<local-command-caveat>"
    "<local-command-stdout>"
    "<local-command-stderr>"
    "<bash-input>"
    "<bash-stdout>"
    "Caveat:"
]

# All selectable session columns, in output order
const SESSION_COLUMNS = [
    summary
    first_timestamp
    last_timestamp
    user_msg_count
    user_msg_length
    response_length
    agent_count
    agents
    mentioned_files
    read_files
    edited_files
    user_messages
    session_id
    slug
    version
    cwd
    git_branch
    thinking_level
    bash_commands
    bash_count
    skill_invocations
    tool_errors
    ask_user_count
    plan_mode_used
    tool_counts
    turn_count
    assistant_msg_count
    tool_call_count
    token_usage
]

# Overview returned when no column flags are given — the fixed set `sessions`
# always returned before columns became selectable
const DEFAULT_SESSION_COLUMNS = [
    summary
    first_timestamp
    last_timestamp
    user_msg_count
    user_msg_length
    response_length
    agent_count
    agents
    mentioned_files
    read_files
    edited_files
]

# Default output directory for Claude Code documentation
const CLAUDE_DOCS_DIR = 'claude-code-docs'

# Nushell documentation settings
const NUSHELL_DOCS_DIR = 'nushell-docs'
const NUSHELL_DOCS_REPO = 'https://github.com/nushell/nushell.github.io.git'
const NUSHELL_DOCS_FOLDERS = ['blog' 'book' 'cookbook']

# Root of Claude Code session storage: ~/.claude/projects
def projects-root []: nothing -> path {
    $env.HOME | path join ".claude" "projects"
}

# Helper to get project sessions directory
export def get-sessions-dir [
    project?: path # Project path, or `parent/name` shorthand (default: $env.PWD)
]: nothing -> path {
    let projects_root = projects-root
    let direct = ($project | default $env.PWD) | path expand | str replace --all '/' '-'
    let direct_dir = $projects_root | path join $direct

    # Why: the completer inserts a `parent/name` shorthand, which `path expand`
    # would wrongly anchor to $PWD. A real path always resolves directly, so
    # only fall back to shorthand matching when the expanded dir is absent.
    if $project == null or ($direct_dir | path exists) {
        return $direct_dir
    }

    # Why: only the completer's `parent/name` shape may suffix-match. A bare
    # or path-like value (e.g. `--project foo` meaning ./foo) must fail on
    # the missing dir, not silently resolve to another project whose encoded
    # name happens to end in the same suffix.
    if not ($project =~ '^[^/~.][^/]*/[^/]+$') {
        return $direct_dir
    }

    let encoded = $project | str replace --all '/' '-'
    let matches = ls $projects_root
        | where type == dir
        | where {|row| $row.name | path basename | str ends-with $"-($encoded)" }
    match ($matches | length) {
        0 => $direct_dir # let downstream report the missing dir
        1 => ($matches | get 0.name)
        _ => (error make {msg: $"Ambiguous project shorthand '($project)' matches: (($matches | get name | path basename | str join ', '))"})
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

# Completer for --project: existing projects by recency, shown as `parent/name`
export def "nu-complete claude projects" []: nothing -> record {
    {
        options: {sort: false}
        completions: (projects | each {|p| {value: $p.name description: ($p.modified | date humanize)} })
    }
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

    let files = ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | sort-by modified --reverse

    if ($files | is-empty) {
        error make {msg: "No session files found"}
    }

    $files | first | get name
}

# Session UUID from a session file path
def session-id-from-path []: path -> string {
    path basename | str replace '.jsonl' ''
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

# Extract user messages from Claude Code session files
export def messages [
    regex?: string # Filter messages by regex pattern
    --session: string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --all-sessions # Search across all project sessions
    --project: path@"nu-complete claude projects" # Project path to search in (default: current directory)
    --all-projects # Search across all projects
    --include-system # Include system/meta messages (not just user-typed)
    --include-thinking # Include assistant thinking blocks (prefixed with [thinking])
    --raw # Return raw message records instead of just content
    --include-responses # Include assistant responses (text only, interleaved)
]: [nothing -> table table -> table] {
    let input = $in
    let piped_files = resolve-piped-sessions $input

    if $piped_files != null {
        if $session != null { error make {msg: "Piped input conflicts with --session"} }
        if $all_sessions { error make {msg: "Piped input conflicts with --all-sessions"} }
        if $all_projects { error make {msg: "Piped input conflicts with --all-projects"} }
        if $project != null { error make {msg: "Piped input conflicts with --project"} }
    }

    let session_files = if $piped_files != null {
        $piped_files
    } else if $all_projects {
        if $session != null {
            error make {msg: "--all-projects and --session are mutually exclusive"}
        }
        if $project != null {
            error make {msg: "--all-projects and --project are mutually exclusive"}
        }
        let projects_dir = projects-root
        if not ($projects_dir | path exists) {
            error make {msg: "No projects directory found"}
        }
        ls $projects_dir
        | where type == dir
        | each {|dir|
            ls $dir.name
            | where name =~ $UUID_JSONL_PATTERN
            | sort-by modified --reverse
            | if $all_sessions { } else { take 1 }
            | get name
        }
        | flatten
    } else if $all_sessions {
        if $session != null {
            error make {msg: "--all-sessions and --session are mutually exclusive"}
        }
        let dir = get-sessions-dir $project
        if not ($dir | path exists) {
            error make {msg: $"Sessions directory not found: ($dir)"}
        }
        ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | sort-by modified --reverse
        | get name
    } else {
        let dir = get-sessions-dir $project
        [(resolve-session-file $session --sessions-dir $dir)]
    }

    $session_files
    | each {|session_file|
        if not ($session_file | path exists) {
            error make {msg: $"Session file not found: ($session_file)"}
        }

        let session_uuid = $session_file | session-id-from-path

        # Why: --include-thinking surfaces thinking-only assistant turns
        # (otherwise dropped by the visible-text filter below). Keep
        # extract-text-content's contract intact for other callers.
        let extract_assistant = if $include_thinking {
            {|r| $r | extract-text-with-thinking }
        } else {
            {|r| $r | extract-text-content }
        }

        # Parse and filter messages
        let messages = open --raw $session_file
            | lines
            | each { from json }
            | if $include_responses {
                where type in ["user" "assistant"]
            } else {
                where type == "user"
            }
            | if $include_system { } else {
                where {|r|
                    match $r.type? {
                        "assistant" => true
                        _ => {
                            if $r.isMeta? == true { false } else {
                                let content = $r.message?.content?
                                match ($content | describe) {
                                    "string" if ($content | is-not-empty) => {
                                        $SYSTEM_PREFIXES | all {|p| not ($content | str starts-with $p) }
                                    }
                                    _ => false
                                }
                            }
                        }
                    }
                }
            }
            # Extract visible text once; the regex filter and output read it
            | insert text {|r|
                match $r.type? {
                    "assistant" => (do $extract_assistant $r)
                    _ => {
                        let content = $r.message?.content?
                        if ($content | describe) =~ '^(list|table)' {
                            $content | get content --optional | str join "\n"
                        } else {
                            $content
                        }
                    }
                }
            }
            # Drop assistant messages with no visible text
            | where {|r| $r.type? != "assistant" or ($r.text | str trim | is-not-empty) }

        let filtered = $messages
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
        | if $all_projects {
            insert project ($session_file | path dirname | path basename)
        } else { }
    }
    | flatten
}

# Shared dispatch on message content shape: string content passes through
# as-is, content block lists go through $render, anything else yields "".
def render-message-content [render: closure]: record -> string {
    let content = $in.message?.content?
    match ($content | describe) {
        "string" => { $content }
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
        turn_count: ($in | where isMeta? != true | length)
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
    let records = open --raw $file_path | lines | each { from json }

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

    # Why: user_msg_length sums these texts, so both columns share one pass
    let user_messages = if (do $need [user_messages user_msg_length]) {
        $user_records | each { extract-text-content }
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
        {name: user_msg_count value: ($user_records | length)}
        {name: user_msg_length value: $user_msg_length}
        {name: response_length value: $response_length}
        {name: agent_count value: ($agent_list | length)}
        {name: agents value: $agent_list}
        {name: mentioned_files value: $mentioned_files}
        {name: read_files value: $file_ops.read_files?}
        {name: edited_files value: $file_ops.edited_files?}
        {name: user_messages value: ($user_messages | where $it != "")}
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

# Extract session file paths from piped input
# Returns null when input is not a table
export def resolve-piped-sessions [input: any]: nothing -> any {
    if ($input | describe) == "nothing" { return null }
    let cols = $input | columns
    if "path" in $cols {
        $input | get path | compact | uniq
    } else if "session" in $cols {
        $input | get session | uniq | each {|s| resolve-session-file $s }
    } else {
        error make {msg: "Piped input must have 'path' or 'session' column"}
    }
}

# Discover session files inside a single directory.
# Returns rows {path, parent_session_id} where parent_session_id is the
# parent session UUID for subagent files (basename of `<uuid>/subagents/`),
# null for top-level session files.
export def discover-session-files [dir: path]: nothing -> table {
    let top_level = glob ($dir | path join "*.jsonl")
        | where $it =~ $UUID_JSONL_PATTERN
        | each {|p| {path: $p parent_session_id: null} }

    let subagent_files = glob ($dir | path join "*/subagents/*.jsonl")
        | where $it =~ $AGENT_JSONL_PATTERN
        | each {|p|
            # Why: layout is `<dir>/<uuid>/subagents/agent-*.jsonl`,
            # so the parent UUID is two levels up from the file.
            {path: $p parent_session_id: ($p | path dirname | path dirname | path basename)}
        }

    $top_level | append $subagent_files
}

# Parse Claude Code sessions for structured information.
# Column flags select what to compute (lazy — only requested extractions run);
# no column flags returns the default overview set, --all-columns everything.
export def sessions [
    ...paths: path # Session files or directories to parse (default: current project sessions)
    --session: string@"nu-complete claude sessions" # Single session UUID or path
    --last # Only the most recent session of the current project
    --all-projects # Enumerate sessions across every project under ~/.claude/projects
    # Session info
    --summary # Include summary column
    --first-timestamp # Include first_timestamp column
    --last-timestamp # Include last_timestamp column
    --user-msg-count # Include user_msg_count column
    --user-msg-length # Include user_msg_length column (total chars typed by user)
    --response-length # Include response_length column (total chars of assistant text)
    --agent-count # Include agent_count column
    --agents # Include agents column
    # File operations
    --mentioned-files # Include mentioned_files column (@-mentions in user messages)
    --read-files # Include read_files column
    --edited-files # Include edited_files column
    --user-messages # Include user_messages column (list of user message texts)
    # Session metadata
    --session-id # Include session_id column
    --slug # Include slug column (human-readable session name)
    --version # Include version column (Claude Code version)
    --cwd # Include cwd column (working directory)
    --git-branch # Include git_branch column
    # Thinking
    --thinking-level # Include thinking_level column
    # Tool statistics
    --bash-commands # Include bash_commands column (list of commands)
    --bash-count # Include bash_count column
    --skill-invocations # Include skill_invocations column
    --tool-errors # Include tool_errors column (count of failed tool calls)
    --ask-user-count # Include ask_user_count column
    --plan-mode-used # Include plan_mode_used column (bool)
    --tool-counts # Include tool_counts column (record keyed by tool name: TaskCreate/Update/Stop, Monitor, ToolSearch)
    # Derived metrics
    --turn-count # Include turn_count column (user→assistant turns)
    --assistant-msg-count # Include assistant_msg_count column
    --tool-call-count # Include tool_call_count column
    # Token usage
    --token-usage # Include token_usage column (record: input/output/cache_creation/cache_read tokens)
    --all-columns # Include all columns
]: [nothing -> table string -> table table -> table] {
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

    if ($session_rows | is-empty) {
        error make {msg: "No session files found"}
    }

    let requested = [
        [include name];
        [$summary summary]
        [$first_timestamp first_timestamp]
        [$last_timestamp last_timestamp]
        [$user_msg_count user_msg_count]
        [$user_msg_length user_msg_length]
        [$response_length response_length]
        [$agent_count agent_count]
        [$agents agents]
        [$mentioned_files mentioned_files]
        [$read_files read_files]
        [$edited_files edited_files]
        [$user_messages user_messages]
        [$session_id session_id]
        [$slug slug]
        [$version version]
        [$cwd cwd]
        [$git_branch git_branch]
        [$thinking_level thinking_level]
        [$bash_commands bash_commands]
        [$bash_count bash_count]
        [$skill_invocations skill_invocations]
        [$tool_errors tool_errors]
        [$ask_user_count ask_user_count]
        [$plan_mode_used plan_mode_used]
        [$tool_counts tool_counts]
        [$turn_count turn_count]
        [$assistant_msg_count assistant_msg_count]
        [$tool_call_count tool_call_count]
        [$token_usage token_usage]
    ] | where include | get name

    let selected = if $all_columns {
        $SESSION_COLUMNS
    } else if ($requested | is-empty) {
        $DEFAULT_SESSION_COLUMNS
    } else { $requested }

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
]: [nothing -> record table -> table] {
    let input = $in
    let piped_files = resolve-piped-sessions $input

    if $piped_files != null {
        if $session != null { error make {msg: "Piped input conflicts with --session"} }
        if $topic != null { error make {msg: "Piped input conflicts with topic argument"} }
    }

    let export_one = {|session_file|
        if not ($session_file | path exists) {
            error make {msg: $"Session file not found: ($session_file)"}
        }

        let records = open --raw $session_file | lines | each { from json }

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
            | where type? in ["user" "assistant"]
            | where isMeta? != true
            | insert text { if $tools { render-content --tools } else { extract-text-content } }
            | where { $in.text | str trim | is-not-empty }
            # Keep assistant messages; filter user messages starting with system prefixes
            | where {|r| $r.type != "user" or ($SYSTEM_PREFIXES | all {|p| not ($r.text | str starts-with $p) }) }
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

        let frontmatter = [
            '---'
            $"date: ($date_formatted)"
            $"session: ($session_id)"
            ...(if $summary != "" { [$"summary: ($summary)"] } else { [] })
            '---'
        ] | str join "\n"

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
    let was_record = ($input | describe | str replace --regex '<.*' '') == "record"

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

# Download Claude Code documentation from sitemap
export def download-claude-docs [
    --output-dir: path = $CLAUDE_DOCS_DIR # Output directory for downloaded docs
]: nothing -> table {
    # Fetch and parse sitemap
    let sitemap_xml = http get https://code.claude.com/docs/sitemap.xml

    let urls = $sitemap_xml
        | get content.content
        | each { get content.0.content.0 }
        | where $it =~ 'docs/en/'
        | each { $in + '.md' }

    # Ensure output directory exists
    mkdir $output_dir

    # Download files in parallel
    $urls
    | par-each --threads 4 {|url|
        let filename = $url | path split | skip 4 | str join '_'
        let dest_path = [$output_dir $filename] | path join

        try {
            http get $url | save -f $dest_path
            {url: $url status: "ok" dest: $dest_path error: null}
        } catch {|e|
            {url: $url status: "failed" dest: $dest_path error: ($e.msg? | default "unknown error")}
        }
    }
}

# Download Claude Code documentation pages from the sitemap, print results, and optionally commit
@example "Fetch docs" { claude-nu fetch-claude-docs }
@example "Fetch and commit" { claude-nu fetch-claude-docs --commit }
export def fetch-claude-docs [
    --commit # Create a git commit after downloading
]: nothing -> nothing {
    let results = download-claude-docs

    # Print results
    $results | each {|r|
        let icon = if $r.status == "ok" { $"(ansi green)✓(ansi reset)" } else { $"(ansi red)✗(ansi reset)" }
        print $"($icon) ($r.url)"
    }

    # Summary
    let ok = $results | where status == "ok" | length
    let failed = $results | where status == "failed" | length
    print $"\n(ansi green_bold)($ok) ok(ansi reset), (ansi red_bold)($failed) failed(ansi reset)"

    if $commit {
        # Stage and commit if there are changes
        let status = git status --porcelain $CLAUDE_DOCS_DIR | str trim
        if $status != "" {
            git add $CLAUDE_DOCS_DIR
            let date = date now | format date "%Y-%m-%d"
            git commit -m $"docs: update claude-code-docs \(($date)\)"
            print $"(ansi green)Committed documentation updates(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}

# Fetch Nushell documentation (book, cookbook, blog) via shallow sparse checkout
@example "Fetch/update Nushell docs" { claude-nu fetch-nushell-docs }
export def fetch-nushell-docs []: nothing -> nothing {
    let dest = $NUSHELL_DOCS_DIR

    if ($dest | path exists) {
        # Update existing checkout
        print $"(ansi attr_dimmed)Updating nushell-docs...(ansi reset)"
        cd $dest
        git pull
        cd -
    } else {
        # Fresh shallow sparse clone
        print $"(ansi attr_dimmed)Cloning nushell.github.io \(shallow sparse\)...(ansi reset)"
        git clone --depth 1 --filter=blob:none --sparse $NUSHELL_DOCS_REPO $dest
        cd $dest
        git sparse-checkout set --no-cone ...($NUSHELL_DOCS_FOLDERS | each { $'/($in)/*' })
        cd -
    }

    # Show what we have
    let sizes = $NUSHELL_DOCS_FOLDERS
        | each {|f| {folder: $f size: (du $"($dest)/($f)" | get apparent | first)} }

    print ""
    print ($sizes | table)
    print $"\n(ansi green)✓(ansi reset) Nushell docs ready at (ansi cyan)($dest)/(ansi reset)"
}
