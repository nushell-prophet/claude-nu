# nu-claude - Nushell utilities for Claude Code

# Helper to get project sessions directory
export def get-sessions-dir [] {
    let project_path = ($env.PWD | str replace --all '/' '-')
    $env.HOME | path join ".claude" "projects" $project_path
}

# Completion for session UUIDs
export def "nu-complete claude sessions" [] {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        return { options: { sort: false }, completions: [] }
    }

    let completions = ls $sessions_dir
        | where name =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
        | sort-by modified --reverse
        | each {|file|
            let uuid = ($file.name | path basename | str replace '.jsonl' '')
            let summary = try {
                open $file.name | lines | first | from json | get summary? | default "No summary"
            } catch {
                "No summary"
            }
            { value: $uuid, description: $summary }
        }

    {
        options: { sort: false },
        completions: $completions
    }
}

# Extract user messages from Claude Code session files
#
# Returns a list of user-typed messages from session files, filtering out
# system-generated messages, tool results, and command outputs.
export def messages [
    --session (-s): string@"nu-complete claude sessions"  # Session UUID (uses most recent if not specified)
    --all (-a)                                            # Include all message types (not just user-typed)
    --raw (-r)                                            # Return raw message records instead of just content
] {
    let sessions_dir = get-sessions-dir

    if not ($sessions_dir | path exists) {
        error make { msg: "No sessions directory found for current project" }
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
            error make { msg: "No session files found" }
        }

        $files | first | get name
    }

    if not ($session_file | path exists) {
        error make { msg: $"Session file not found: ($session_file)" }
    }

    # Parse session file
    let messages = open $session_file
        | lines
        | each { from json }
        | where type == "user"
        | where { |msg|
            # Filter out meta messages unless --all is specified
            if not $all {
                $msg.isMeta? != true
            } else {
                true
            }
        }
        | where { |msg|
            # Filter out non-user-typed content unless --all is specified
            if not $all {
                let content = $msg.message?.content?
                let content_type = ($content | describe)
                if ($content_type | str starts-with "list") {
                    # Tool results are arrays - skip unless --all
                    false
                } else if ($content | is-empty) {
                    false
                } else if ($content_type != "string") {
                    # Non-string content (records, etc.) - skip
                    false
                } else {
                    # Filter out system-generated messages
                    not (
                        ($content | str starts-with "<command-name>") or
                        ($content | str starts-with "<command-message>") or
                        ($content | str starts-with "<local-command-stdout>") or
                        ($content | str starts-with "<bash-input>") or
                        ($content | str starts-with "<bash-stdout>") or
                        ($content | str starts-with "Caveat:")
                    )
                }
            } else {
                true
            }
        }

    if $raw {
        $messages
    } else {
        $messages | each { |msg|
            let content = $msg.message?.content?
            if ($content | describe | str starts-with "list") {
                # For tool results, extract the content
                $content | each { |c| $c.content? } | str join "\n"
            } else {
                $content
            }
        }
    }
}
