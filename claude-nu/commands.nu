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
        $sessions_dir | path join $"($session).jsonl"
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
def extract-text-content []: record -> string {
    let content = $in.message?.content?
    let content_type = ($content | describe)
    if ($content_type | str starts-with "list") or ($content_type | str starts-with "table") {
        $content
        | where type? == "text"
        | each { $in.text? | default "" }
        | str join ""
    } else if $content_type == "string" {
        $content
    } else {
        ""
    }
}

# Helper to extract tool calls from assistant messages
def extract-tool-calls []: record -> table {
    let content = $in.message?.content?
    let content_type = ($content | describe)
    if ($content_type | str starts-with "list") or ($content_type | str starts-with "table") {
        $content | where type? == "tool_use"
    } else {
        []
    }
}

# Parse a single session file into structured info
def parse-session-file []: path -> record {
    let file_path = $in
    let lines = open --raw $file_path | lines

    # Handle empty files
    if ($lines | is-empty) {
        return {
            path: $file_path
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
        }
    }

    let records = $lines | each { from json }

    # Extract summary
    let summary_records = $records | where type? == "summary"
    let summary = if ($summary_records | is-empty) {
        ""
    } else {
        $summary_records | first | get summary? | default ""
    }

    # User messages
    let user_records = $records | where type? == "user"
    let user_timestamps = $user_records
    | each { $in.timestamp? }
    | compact
    | each { $in | into datetime }

    let first_ts = if ($user_timestamps | is-empty) { null } else { $user_timestamps | first }
    let last_ts = if ($user_timestamps | is-empty) { null } else { $user_timestamps | last }

    let user_texts = $user_records
    | each { $in | extract-text-content }
    | where { ($in | describe) == "string" }
    let user_msg_length = if ($user_texts | is-empty) { 0 } else {
        $user_texts | each { $in | str length } | math sum
    }

    # Mentioned files (@path patterns in user messages)
    let mentioned_files = $user_texts
    | each { $in | parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    # Assistant messages
    let assistant_records = $records | where type? == "assistant"
    let response_texts = $assistant_records
    | each { $in | extract-text-content }
    | where { ($in | describe) == "string" }
    let response_length = if ($response_texts | is-empty) { 0 } else {
        $response_texts | each { $in | str length } | math sum
    }

    # Tool calls
    let all_tool_calls = $assistant_records
    | each { $in | extract-tool-calls }
    | flatten

    # Agent usages (Task tool)
    let agent_calls = $all_tool_calls | where name? == "Task"
    let agents = $agent_calls
    | each {|call|
        {
            type: ($call.input?.subagent_type? | default "unknown")
            description: ($call.input?.description? | default "")
        }
    }

    # Read files
    let read_files = $all_tool_calls
    | where name? == "Read"
    | each { $in.input?.file_path? }
    | compact
    | uniq

    # Edited files (Edit + Write)
    let edited_files = $all_tool_calls
    | where {|call| ($call.name? == "Edit") or ($call.name? == "Write") }
    | each { $in.input?.file_path? }
    | compact
    | uniq

    {
        path: $file_path
        summary: $summary
        first_timestamp: $first_ts
        last_timestamp: $last_ts
        user_msg_count: ($user_records | length)
        user_msg_length: $user_msg_length
        response_length: $response_length
        agent_count: ($agent_calls | length)
        agents: $agents
        mentioned_files: $mentioned_files
        read_files: $read_files
        edited_files: $edited_files
    }
}

# Parse Claude Code sessions for structured information
export def sessions [
    ...paths: path # Session files or directories to parse (default: current project sessions)
]: nothing -> table {
    # Resolve paths - default to get-sessions-dir if none provided
    let target_paths = if ($paths | is-empty) {
        [( get-sessions-dir )]
    } else {
        $paths
    }

    # Collect all session files
    let session_files = $target_paths
    | each {|p|
        if not ($p | path exists) {
            error make {msg: $"Path not found: ($p)"}
        }
        if ($p | path type) == "dir" {
            glob ($p | path join "*.jsonl")
        } else {
            [$p]
        }
    }
    | flatten
    | where { $in =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' }

    if ($session_files | is-empty) {
        error make {msg: "No session files found"}
    }

    # Parse each session file
    $session_files | each { $in | parse-session-file }
}
