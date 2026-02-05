# claude-nu - Nushell utilities for Claude Code

# UUID pattern for session files
const UUID_JSONL_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# System-generated message prefixes to filter out
const SYSTEM_PREFIXES = [
    "<command-name>"
    "<command-message>"
    "<local-command-caveat>"
    "<local-command-stdout>"
    "<bash-input>"
    "<bash-stdout>"
    "Caveat:"
]

# Template for session summary record
const EMPTY_SESSION_SUMMARY = {
    summary: ""
    first_timestamp: null
    last_timestamp: null
    user_msg_count: 0
    user_msg_length: 0
    response_length: 0
    agent_count: 0
    agents: []
    mentioned_files: []
    read_files: []
    edited_files: []
    path: null
}

# Helper to get project sessions directory
export def get-sessions-dir []: nothing -> path {
    let project_path = $env.PWD | str replace --all '/' '-'
    $env.HOME | path join ".claude" "projects" $project_path
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
        return ($dir | path join $"($session).jsonl")
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

# Completion for session UUIDs
export def "nu-complete claude sessions" []: nothing -> record {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        return {options: {sort: false} completions: []}
    }

    let completions = ls $sessions_dir
    | where name =~ $UUID_JSONL_PATTERN
    | each {|file|
        let uuid = $file.name | path basename | str replace '.jsonl' ''
        let size = $file.size | into string
        let lines = try {
            open --raw $file.name | lines | first 5 | each { from json }
        } catch { [] }
        let summary = $lines | get 0?.summary? | default "No summary"
        # Timestamps are on message records, not summary headers
        let timestamp = $lines
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
    --session (-s): string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --all-sessions (-a) # Search across all project sessions
    --include-system (-u) # Include system/meta messages (not just user-typed)
    --raw (-r) # Return raw message records instead of just content
    --with-responses (-w) # Include assistant responses (text only, interleaved)
]: nothing -> table {
    let session_files = if $all_sessions {
        if $session != null {
            error make {msg: "--all-sessions and --session are mutually exclusive"}
        }
        let dir = get-sessions-dir
        if not ($dir | path exists) {
            error make {msg: "No sessions directory found for current project"}
        }
        ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | sort-by modified --reverse
        | get name
    } else {
        [(resolve-session-file $session)]
    }

    $session_files
    | each {|session_file|
        if not ($session_file | path exists) {
            error make {msg: $"Session file not found: ($session_file)"}
        }

        let session_uuid = $session_file | path basename | str replace '.jsonl' ''

        # Parse and filter messages
        let messages = open --raw $session_file
        | lines
        | each { from json }
        | if $with_responses {
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
        # Drop assistant messages with no visible text
        | if $with_responses {
            where {|r|
                match $r.type? {
                    "assistant" => ($r | extract-text-content | str trim | is-not-empty)
                    _ => true
                }
            }
        } else { }

        let filtered = $messages
        | if $regex == null { } else {
            where {
                let msg = $in
                match $msg.type? {
                    "assistant" => ($msg | extract-text-content | $in =~ $regex)
                    _ => {
                        let content = $msg.message?.content?
                        if ($content | describe) =~ '^(list|table)' {
                            ($content | get content --optional | str join "\n") =~ $regex
                        } else {
                            $content =~ $regex
                        }
                    }
                }
            }
        }

        if $raw {
            $filtered | sort-by timestamp
        } else {
            $filtered | each {|msg|
                let message = match $msg.type? {
                    "assistant" => ($msg | extract-text-content)
                    _ => {
                        let content = $msg.message?.content?
                        if ($content | describe) =~ '^(list|table)' {
                            $content | get content --optional | str join "\n"
                        } else {
                            $content
                        }
                    }
                }
                if $with_responses {
                    {role: $msg.type message: $message timestamp: ($msg.timestamp? | into datetime)}
                } else {
                    {message: $message timestamp: ($msg.timestamp? | into datetime)}
                }
            }
            | sort-by timestamp
        }
        | if $all_sessions {
            each { insert session $session_uuid }
        } else { }
    }
    | flatten
}

# Helper to extract text content from a message
export def extract-text-content []: record -> string {
    let content = $in.message?.content?
    let content_type = $content | describe
    match $content_type {
        "string" => { $content }
        $t if ($t =~ '^(list|table)') => {
            $content
            | where type? == "text"
            | get text --optional
            | str join
        }
        _ => { "" }
    }
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

# Extract session metadata from first record
export def extract-session-metadata []: record -> record {
    select --optional sessionId slug version cwd gitBranch
    | default "" sessionId slug version cwd gitBranch
    | rename --column {sessionId: session_id gitBranch: git_branch}
}

# Extract thinking level from user records
export def extract-thinking-level []: table -> string {
    get thinkingMetadata.level --optional
    | compact
    | first
    | default ""
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
export def extract-agents []: table -> table {
    where name? == "Task"
    | each {
        {
            type: ($in.input?.subagent_type? | default "unknown")
            description: ($in.input?.description? | default "")
        }
    }
}

# Extract tool statistics from tool calls and results
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

# Parse a single session file into structured info
export def parse-session-file []: path -> record {
    let file_path = $in
    let lines = open --raw $file_path | lines

    if ($lines | is-empty) {
        return ($EMPTY_SESSION_SUMMARY | update path $file_path)
    }

    let records = $lines | each { from json }

    let summary = $records
    | where type? == "summary"
    | first
    | get summary?
    | default ""

    let user_records = $records | where type? == "user"
    let timestamps = $user_records | extract-timestamps

    let user_msg_length = $user_records
    | each { extract-text-content | str length }
    | if ($in | is-empty) { 0 } else { math sum }

    let mentioned_files = $user_records
    | each { extract-text-content | parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    let assistant_records = $records | where type? == "assistant"
    let response_length = $assistant_records
    | each { extract-text-content | str length }
    | if ($in | is-empty) { 0 } else { math sum }

    let all_tool_calls = $assistant_records | each { extract-tool-calls } | flatten
    let file_ops = $all_tool_calls | extract-file-operations
    let agents = $all_tool_calls | extract-agents

    $EMPTY_SESSION_SUMMARY | merge {
        summary: $summary
        first_timestamp: $timestamps.first
        last_timestamp: $timestamps.last
        user_msg_count: ($user_records | length)
        user_msg_length: $user_msg_length
        response_length: $response_length
        agent_count: ($agents | length)
        agents: $agents
        mentioned_files: $mentioned_files
        read_files: $file_ops.read_files
        edited_files: $file_ops.edited_files
        path: $file_path
    }
}

# Parse Claude Code sessions for structured information
export def sessions [
    ...paths: path # Session files or directories to parse (default: current project sessions)
]: nothing -> table {
    let target_paths = $paths
    | if ($in | is-empty) { [(get-sessions-dir)] } else { }

    let session_files = $target_paths
    | each {|p|
        if not ($p | path exists) {
            error make {msg: $"Path not found: ($p)"}
        }
        if ($p | path type) == "dir" {
            glob ($p | path join "*.jsonl")
        } else { [$p] }
    }
    | flatten
    | where $it =~ $UUID_JSONL_PATTERN

    if ($session_files | is-empty) {
        error make {msg: "No session files found"}
    }

    $session_files | each { parse-session-file }
}

# Parse session file into raw data with selectable columns
# A plumbing command for downstream pipelines
# Uses lazy evaluation: expensive extractions only run when their flags are requested
export def parse-session [
    session?: string@"nu-complete claude sessions" # Session UUID or path (default: most recent)
    # File operations
    --edited-files # Include edited_files column
    --read-files # Include read_files column
    # Session info
    --summary (-s) # Include summary column
    --agents (-g) # Include agents column
    --first-timestamp # Include first_timestamp column
    --last-timestamp # Include last_timestamp column
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
    # Derived metrics
    --turn-count # Include turn_count column (user→assistant turns)
    --assistant-msg-count # Include assistant_msg_count column
    --tool-call-count # Include tool_call_count column
    --all (-a) # Include all columns
]: nothing -> record {
    let session_file = resolve-session-file $session

    if not ($session_file | path exists) {
        error make {msg: $"Session file not found: ($session_file)"}
    }

    let records = open --raw $session_file | lines | each { from json }

    # Handle empty session files
    if ($records | is-empty) {
        return {
            path: $session_file
            user_messages: []
            mentioned_files: []
        }
    }

    # Extract base data
    let user_records = $records | where type? == "user"
    let assistant_records = $records | where type? == "assistant"
    let all_tool_calls = $assistant_records | each { extract-tool-calls } | flatten

    # Default columns
    let user_messages = $user_records | each { extract-text-content } | where $it != ""
    let mentioned_files = $user_records
    | each { extract-text-content | parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    let base = {
        path: $session_file
        user_messages: $user_messages
        mentioned_files: $mentioned_files
    }

    # Lazy extraction - only compute when flags require it
    let need_file_ops = $all or $edited_files or $read_files
    let need_meta = $all or $session_id or $slug or $version or $cwd or $git_branch
    let need_tool_stats = $all or $bash_commands or $bash_count or $skill_invocations or $tool_errors or $ask_user_count or $plan_mode_used
    let need_metrics = $all or $turn_count or $assistant_msg_count or $tool_call_count
    let need_timestamps = $all or $first_timestamp or $last_timestamp

    let file_ops = if $need_file_ops { $all_tool_calls | extract-file-operations } else { {} }
    let agent_list = if ($all or $agents) { $all_tool_calls | extract-agents } else { [] }
    let meta = if $need_meta { $records | first | extract-session-metadata } else { {} }
    let tool_stats = if $need_tool_stats {
        let tool_results = $user_records | extract-tool-results
        $all_tool_calls | extract-tool-stats $tool_results
    } else { {} }
    let metrics = if $need_metrics {
        $user_records | extract-derived-metrics $assistant_records $all_tool_calls
    } else { {} }

    let sum = if ($all or $summary) {
        $records | where type? == "summary"
        | first
        | get summary?
        | default ""
    } else { "" }

    let timestamps = if $need_timestamps { $user_records | extract-timestamps } else { {first: null last: null} }
    let thinking = if ($all or $thinking_level) { $user_records | extract-thinking-level } else { "" }

    # Build result record with optional columns (data-driven)
    [
        # File operations
        {include: $edited_files field: edited_files value: $file_ops.edited_files?}
        {include: $read_files field: read_files value: $file_ops.read_files?}
        # Session info
        {include: $summary field: summary value: $sum}
        {include: $agents field: agents value: $agent_list}
        {include: $first_timestamp field: first_timestamp value: $timestamps.first?}
        {include: $last_timestamp field: last_timestamp value: $timestamps.last?}
        # Session metadata
        {include: $session_id field: session_id value: $meta.session_id?}
        {include: $slug field: slug value: $meta.slug?}
        {include: $version field: version value: $meta.version?}
        {include: $cwd field: cwd value: $meta.cwd?}
        {include: $git_branch field: git_branch value: $meta.git_branch?}
        # Thinking
        {include: $thinking_level field: thinking_level value: $thinking}
        # Tool statistics
        {include: $bash_commands field: bash_commands value: $tool_stats.bash_commands?}
        {include: $bash_count field: bash_count value: $tool_stats.bash_count?}
        {include: $skill_invocations field: skill_invocations value: $tool_stats.skill_invocations?}
        {include: $tool_errors field: tool_errors value: $tool_stats.tool_errors?}
        {include: $ask_user_count field: ask_user_count value: $tool_stats.ask_user_count?}
        {include: $plan_mode_used field: plan_mode_used value: $tool_stats.plan_mode_used?}
        # Derived metrics
        {include: $turn_count field: turn_count value: $metrics.turn_count?}
        {include: $assistant_msg_count field: assistant_msg_count value: $metrics.assistant_msg_count?}
        {include: $tool_call_count field: tool_call_count value: $metrics.tool_call_count?}
    ]
    | where { $all or $in.include }
    | reduce --fold $base {|it acc| $acc | insert $it.field $it.value }
}

# Sanitize topic string for use in filename
export def sanitize-topic []: string -> string {
    str downcase
    | str replace --all --regex '[^a-z0-9]+' '-'
    | str trim --char '-'
    | str substring 0..<50
}

# Export session dialogue to markdown file
export def export-session [
    topic?: string # Topic for filename (default: session summary)
    --session (-s): string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --output-dir (-o): path # Output directory (default: docs/sessions)
    --echo (-e) # Print markdown to stdout instead of saving to file
]: nothing -> string {
    let session_file = resolve-session-file $session
    let out_dir = $output_dir | default "docs/sessions"

    if not ($session_file | path exists) {
        error make {msg: $"Session file not found: ($session_file)"}
    }

    let records = open --raw $session_file | lines | each { from json }

    if ($records | is-empty) {
        error make {msg: "Session file is empty"}
    }

    # Extract summary from summary record
    let summary = $records
    | where type? == "summary"
    | first
    | get summary?
    | default ""

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
    | insert text { extract-text-content }
    | where { $in.text | str trim | is-not-empty }
    # Keep assistant messages; filter user messages starting with system prefixes
    | where {|r| $r.type != "user" or ($SYSTEM_PREFIXES | all {|p| not ($r.text | str starts-with $p) }) }
    | select type text
    | rename role content

    # Format as markdown
    let header = [
        $"# ($resolved_topic | str replace --all '-' ' ' | str title-case)"
        ""
        $"**Date:** ($first_timestamp | into datetime | format date '%Y-%m-%d')"
        $"**Summary:** ($summary)"
        ""
        "---"
        ""
    ] | str join "\n"

    let body = $dialogue
    | each {|turn|
        let role = match $turn.role { "user" => "User" _ => "Assistant" }
        $"## ($role)\n\n($turn.content)"
    }
    | str join "\n\n---\n\n"

    let markdown = $header + $body

    if $echo {
        $markdown
    } else {
        # Ensure output directory exists
        mkdir $out_dir

        # Write file
        let filename = $"($date_str)-($resolved_topic).md"
        let filepath = $out_dir | path join $filename
        $markdown | save -f $filepath

        $filepath
    }
}

# Download Claude Code documentation from sitemap
export def download-documentation [
    --output-dir (-o): path = "claude-code-docs" # Output directory for downloaded docs
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
