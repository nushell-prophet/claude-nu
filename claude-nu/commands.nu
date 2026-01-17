# claude-nu - Nushell utilities for Claude Code

# System-generated message prefixes to filter out
const SYSTEM_PREFIXES = [
    "<command-name>"
    "<command-message>"
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
    let project_path = ($env.PWD | str replace --all '/' '-')
    $env.HOME | path join ".claude" "projects" $project_path
}

# Completion for session UUIDs
export def "nu-complete claude sessions" []: nothing -> record {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        return {options: {sort: false} completions: []}
    }

    let completions = ls $sessions_dir
    | where name =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
    | sort-by modified --reverse
    | each {|file|
        let uuid = ($file.name | path basename | str replace '.jsonl' '')
        let age = $file.modified | date humanize
        let size = $file.size | into string
        let summary = try {
            open $file.name | lines | first | from json | get summary? | default "No summary"
        } catch {
            "No summary"
        }
        {value: $uuid description: $"($age), ($size): ($summary)"}
    }

    {
        options: {sort: false}
        completions: $completions
    }
}

# Extract user messages from Claude Code session files
export def messages [
    regex?: string # Filter messages by regex pattern
    --session (-s): string@"nu-complete claude sessions" # Session UUID (uses most recent if not specified)
    --all (-a) # Include all message types (not just user-typed)
    --raw (-r) # Return raw message records instead of just content
]: nothing -> table {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        error make {msg: "No sessions directory found for current project"}
    }

    # Get session file path
    let session_file = if $session != null {
        # Accept either UUID or full path (path has .jsonl extension)
        if ($session | str ends-with '.jsonl') {
            $session
        } else {
            $sessions_dir | path join $"($session).jsonl"
        }
    } else {
        # Use most recent session
        let files = ls $sessions_dir
        | where name =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
        | sort-by modified --reverse

        if ($files | is-empty) {
            error make {msg: "No session files found"}
        }

        $files | first | get name
    }

    if not ($session_file | path exists) {
        error make {msg: $"Session file not found: ($session_file)"}
    }

    # Parse session file
    let messages = open $session_file
    | lines
    | each { from json }
    | where type == "user"
    | if $all { } else {
        where isMeta? != true
        | where {
            let content = $in.message?.content?
            let content_type = ($content | describe)
            if ($content_type | str starts-with "list") {
                false
            } else if ($content | is-empty) {
                false
            } else if $content_type != "string" {
                false
            } else {
                $SYSTEM_PREFIXES | all { $content !~ $'^($in)' }
            }
        }
    }

    let filtered = $messages
    | if $regex == null { } else {
        where {
            let content = $in.message?.content?
            if ($content | describe | str starts-with "list") {
                ($content | each { $in.content? } | str join "\n") =~ $regex
            } else {
                $content =~ $regex
            }
        }
    }

    if $raw {
        $filtered
    } else {
        $filtered | each {|msg|
            let content = $msg.message?.content?
            let message = if ($content | describe | str starts-with "list") {
                $content | each { $in.content? } | str join "\n"
            } else {
                $content
            }
            {
                message: $message
                timestamp: ($msg.timestamp? | into datetime)
            }
        }
    }
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
    let content = $in.message?.content?
    let content_type = $content | describe
    if ($content_type =~ '^(list|table)') {
        $content | where type? == "tool_use"
    } else { [] }
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
    | if ($in | is-empty) { "" } else { first | get summary? | default "" }

    let user_records = $records | where type? == "user"
    let user_timestamps = $user_records
    | each { $in.timestamp? }
    | compact
    | each { into datetime }

    let first_ts = $user_timestamps | if ($in | is-empty) { null } else { first }
    let last_ts = $user_timestamps | if ($in | is-empty) { null } else { last }

    let user_msg_length = $user_records
    | each { extract-text-content | str length }
    | if ($in | is-empty) { 0 } else { math sum }

    let user_texts = $user_records | each { extract-text-content }

    let mentioned_files = $user_texts
    | each { parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    let assistant_records = $records | where type? == "assistant"
    let response_length = $assistant_records
    | each { extract-text-content | str length }
    | if ($in | is-empty) { 0 } else { math sum }

    let all_tool_calls = $assistant_records
    | each { extract-tool-calls }
    | flatten

    let agent_calls = $all_tool_calls | where name? == "Task"
    let agents = $agent_calls
    | each {
        {
            type: ($in.input?.subagent_type? | default "unknown")
            description: ($in.input?.description? | default "")
        }
    }

    let read_files = $all_tool_calls
    | where name? == "Read"
    | get input.file_path --optional
    | uniq

    let edited_files = $all_tool_calls
    | where name? in ["Edit" "Write"]
    | get input.file_path --optional
    | uniq

    $EMPTY_SESSION_SUMMARY
    | update summary $summary
    | update first_timestamp $first_ts
    | update last_timestamp $last_ts
    | update user_msg_count ($user_records | length)
    | update user_msg_length $user_msg_length
    | update response_length $response_length
    | update agent_count ($agent_calls | length)
    | update agents $agents
    | update mentioned_files $mentioned_files
    | update read_files $read_files
    | update edited_files $edited_files
    | update path $file_path
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
    | where { $in =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' }

    if ($session_files | is-empty) {
        error make {msg: "No session files found"}
    }

    $session_files | each { parse-session-file }
}

# Parse session file into raw data with selectable columns
# A plumbing command for downstream pipelines
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
    let sessions_dir = get-sessions-dir

    # Resolve session file path
    let session_file = if $session != null {
        if ($session | str ends-with '.jsonl') {
            $session
        } else {
            $sessions_dir | path join $"($session).jsonl"
        }
    } else {
        if not ($sessions_dir | path exists) {
            error make {msg: "No sessions directory found for current project"}
        }
        let files = ls $sessions_dir
        | where name =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
        | sort-by modified --reverse

        if ($files | is-empty) {
            error make {msg: "No session files found"}
        }
        $files | first | get name
    }

    if not ($session_file | path exists) {
        error make {msg: $"Session file not found: ($session_file)"}
    }

    let records = open --raw $session_file | lines | each { from json }

    # Extract raw data
    let user_records = $records | where type? == "user"
    let user_messages = $user_records | each { extract-text-content } | where { $in != "" }

    let user_texts = $user_records | each { extract-text-content }
    let mentioned_files = $user_texts
    | each { parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    # Build result with default columns
    let base = {
        path: $session_file
        user_messages: $user_messages
        mentioned_files: $mentioned_files
    }

    # Extract base data
    let assistant_records = $records | where type? == "assistant"
    let all_tool_calls = $assistant_records | each { extract-tool-calls } | flatten
    let first_record = $records | first

    let user_timestamps = $user_records
    | each { $in.timestamp? }
    | compact
    | each { into datetime }

    # Extract tool results from user records (responses to tool calls)
    let tool_results = $user_records
    | each {|r|
        let content = $r.message?.content?
        if ($content | describe) =~ '^(list|table)' {
            $content | where type? == "tool_result"
        } else { [] }
    }
    | flatten

    # Pre-compute optional fields
    let edited = $all_tool_calls
    | where name? in ["Edit" "Write"]
    | get input.file_path --optional
    | uniq

    let read = $all_tool_calls
    | where name? == "Read"
    | get input.file_path --optional
    | uniq

    let sum = $records
    | where type? == "summary"
    | if ($in | is-empty) { "" } else { first | get summary? | default "" }

    let agent_list = $all_tool_calls
    | where name? == "Task"
    | each {
        {
            type: ($in.input?.subagent_type? | default "unknown")
            description: ($in.input?.description? | default "")
        }
    }

    let first_ts = $user_timestamps | if ($in | is-empty) { null } else { first }
    let last_ts = $user_timestamps | if ($in | is-empty) { null } else { last }

    # Session metadata
    let meta_session_id = $first_record.sessionId? | default ""
    let meta_slug = $first_record.slug? | default ""
    let meta_version = $first_record.version? | default ""
    let meta_cwd = $first_record.cwd? | default ""
    let meta_git_branch = $first_record.gitBranch? | default ""

    # Thinking metadata
    let meta_thinking_level = $user_records
    | each { $in.thinkingMetadata?.level? }
    | compact
    | if ($in | is-empty) { "" } else { first }

    # Tool statistics
    let bash_cmds = $all_tool_calls
    | where name? == "Bash"
    | get input.command --optional

    let skill_list = $all_tool_calls
    | where name? == "Skill"
    | get input.skill --optional

    let error_count = $tool_results | where is_error? == true | length

    let ask_count = $all_tool_calls | where name? == "AskUserQuestion" | length

    let plan_used = ($all_tool_calls | where name? == "EnterPlanMode" | length) > 0

    # Derived metrics
    let turns = $user_records | where isMeta? != true | length
    let asst_count = $assistant_records | length
    let tool_count = $all_tool_calls | length

    # Build result record with optional columns
    $base
    | if ($all or $edited_files) { merge {edited_files: $edited} } else { $in }
    | if ($all or $read_files) { merge {read_files: $read} } else { $in }
    | if ($all or $summary) { merge {summary: $sum} } else { $in }
    | if ($all or $agents) { merge {agents: $agent_list} } else { $in }
    | if ($all or $first_timestamp) { merge {first_timestamp: $first_ts} } else { $in }
    | if ($all or $last_timestamp) { merge {last_timestamp: $last_ts} } else { $in }
    # Session metadata
    | if ($all or $session_id) { merge {session_id: $meta_session_id} } else { $in }
    | if ($all or $slug) { merge {slug: $meta_slug} } else { $in }
    | if ($all or $version) { merge {version: $meta_version} } else { $in }
    | if ($all or $cwd) { merge {cwd: $meta_cwd} } else { $in }
    | if ($all or $git_branch) { merge {git_branch: $meta_git_branch} } else { $in }
    # Thinking
    | if ($all or $thinking_level) { merge {thinking_level: $meta_thinking_level} } else { $in }
    # Tool statistics
    | if ($all or $bash_commands) { merge {bash_commands: $bash_cmds} } else { $in }
    | if ($all or $bash_count) { merge {bash_count: ($bash_cmds | length)} } else { $in }
    | if ($all or $skill_invocations) { merge {skill_invocations: $skill_list} } else { $in }
    | if ($all or $tool_errors) { merge {tool_errors: $error_count} } else { $in }
    | if ($all or $ask_user_count) { merge {ask_user_count: $ask_count} } else { $in }
    | if ($all or $plan_mode_used) { merge {plan_mode_used: $plan_used} } else { $in }
    # Derived metrics
    | if ($all or $turn_count) { merge {turn_count: $turns} } else { $in }
    | if ($all or $assistant_msg_count) { merge {assistant_msg_count: $asst_count} } else { $in }
    | if ($all or $tool_call_count) { merge {tool_call_count: $tool_count} } else { $in }
}
