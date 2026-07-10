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
            name: ($cwd | path split | last 2 | path join)
            path: $dir.name
            count: ($files | length)
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

    # Not discover-session-files because: the description needs `size`, which
    # its rows don't carry, and a Tab press shouldn't pay the subagents glob.
    let completions = ls $sessions_dir
        | where name =~ $UUID_JSONL_PATTERN
        | each {|file|
            let uuid = $file.name | session-id-from-path
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
        if not ($session_file | path exists) {
            error make {msg: $"Session file not found: ($session_file)"}
        }

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

        # Why: sorting the ISO-8601 timestamp strings sorts chronologically,
        # so one sort here serves both the --raw and rendered branches.
        let filtered = $dialogue
            | if $regex == null { } else { where text =~ $regex }
            | sort-by timestamp

        if $raw {
            $filtered | reject text
        } else {
            $filtered
            | each {|msg| {role: $msg.type message: $msg.text timestamp: ($msg.timestamp? | into datetime)} }
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

    # Why `select` (not where+reduce): it keeps $selected's order and fails fast
    # if SESSION_COLUMNS names a column this record doesn't compute — drift
    # between the two lists used to be silently dropped.
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
        slug: $meta.slug?
        version: $meta.version?
        cwd: $meta.cwd?
        git_branch: $meta.git_branch?
        thinking_level: $thinking
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
    }
    | select ...$selected
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
        $input | get session | compact | ansi strip | uniq | each {|s| resolve-session-file $s }
    } else {
        error make {msg: "Piped input must have 'path' or 'session' column"}
    }
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

# Expand paths (piped or positional) to session-file rows. A directory
# discovers its sessions; a file is taken as-is, whatever its name — UUID/agent
# pattern filtering lives in discover-session-files (directory scans only), and
# a caller naming a file explicitly skips the layout-based parent discovery.
def expand-session-paths []: list<path> -> table {
    each {|p|
        if not ($p | path exists) {
            error make {msg: $"Path not found: ($p)"}
        }
        if ($p | path type) == "dir" {
            discover-session-files $p
        } else {
            [{path: $p parent_session_id: null}]
        }
    }
    | flatten
}

# Parse Claude Code sessions for structured information.
# `--columns` selects what to compute (lazy — only requested extractions run);
# omit it for the default overview set, `--all-columns` for everything. Column
# names are listed in SESSION_COLUMNS (and tab-complete on --columns).
# By default only top-level (human-driven) sessions are listed; pass --subagents
# to also include subagent transcripts (those rows carry a non-null parent_session_id).
# Named `main` because a module can't export a command named the same as the
# module — importing this file yields the `sessions` command.
export def main [
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
        error make {msg: $"($active_scopes | str join ' and ') are mutually exclusive — pick one session scope"}
    }
    # Why: --last/--session resolve to a single top-level file, so there are no
    # subagents to include — flag it as a no-op rather than silently ignore.
    if $subagents and ($last or $session != null) {
        print --stderr "claude-nu sessions: --subagents has no effect with --last/--session — those select a single top-level session"
    }

    let session_rows = if $session != null or $last {
        # Why: parse-session defaulted to the most recent session; after the
        # merge (bare scope = whole project) --last keeps that workflow.
        [(resolve-session-file $session)] | expand-session-paths
    } else if $all_projects {
        let projects_dir = projects-root
        if not ($projects_dir | path exists) {
            error make {msg: "No projects directory found"}
        }
        ls $projects_dir | where type == dir | get name | expand-session-paths
    } else {
        # Why: piped rows and positional paths mean the same thing (`projects |
        # sessions` pipes project dirs), so they share one expansion.
        $piped_files
        | default $paths
        | if ($in | is-empty) { [($piped_path | default (get-sessions-dir))] } else { }
        | expand-session-paths
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
    # uniq because `select` (unlike the old where+reduce) rejects a repeated name.
    let requested = $columns
        | default ""
        | split row ','
        | str trim
        | where $it != ""
        | uniq

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
        $row.path | parse-session-columns $selected | insert parent_session_id $row.parent_session_id
    }
}

# Sanitize topic string for use in filename
export def sanitize-topic []: string -> string {
    str lowercase
    | str replace --all --regex '[^a-z0-9]+' '-'
    | str trim --char '-'
    | str substring 0..<50
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
            date: ($first_timestamp | format date "%Y%m%d")
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
        | group-by filename --to-table
        | where ($it.items | length) > 1
        | get filename

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
            $r.markdown | save --force $filepath
            {session: $r.session filepath: $filepath}
        }

    if $was_record {
        $results | first | get filepath
    } else {
        $results
    }
}
