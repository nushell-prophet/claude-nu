# Nushell custom completions for Claude Code CLI

# Completion for output format
def "nu-complete claude output-format" [] {
    [
        { value: "text", description: "Plain text output (default)" }
        { value: "json", description: "Single JSON result" }
        { value: "stream-json", description: "Realtime streaming JSON" }
    ]
}

# Completion for input format
def "nu-complete claude input-format" [] {
    [
        { value: "text", description: "Plain text input (default)" }
        { value: "stream-json", description: "Realtime streaming input" }
    ]
}

# Completion for permission mode
def "nu-complete claude permission-mode" [] {
    [
        { value: "acceptEdits", description: "Accept all edit operations" }
        { value: "bypassPermissions", description: "Bypass all permission checks" }
        { value: "default", description: "Default permission handling" }
        { value: "delegate", description: "Delegate permission decisions" }
        { value: "dontAsk", description: "Don't ask for permissions" }
        { value: "plan", description: "Plan mode" }
    ]
}

# Completion for model selection
def "nu-complete claude model" [] {
    [
        { value: "opus", description: "Claude Opus (most capable)" }
        { value: "sonnet", description: "Claude Sonnet (balanced)" }
        { value: "haiku", description: "Claude Haiku (fastest)" }
        { value: "claude-opus-4-5-20251101", description: "Claude Opus 4.5 (specific version)" }
        { value: "claude-sonnet-4-5-20250929", description: "Claude Sonnet 4.5 (specific version)" }
    ]
}

# Completion for install targets
def "nu-complete claude install-target" [] {
    [
        { value: "stable", description: "Stable release" }
        { value: "latest", description: "Latest release" }
    ]
}

# Completion for session UUIDs (for --resume)
# Reads sessions from ~/.claude/projects/<project-path>/ sorted by modification time (newest first)
def "nu-complete claude sessions" [] {
    let project_path = ($env.PWD | str replace --all '/' '-')
    let sessions_dir = ($env.HOME | path join ".claude" "projects" $project_path)

    if not ($sessions_dir | path exists) {
        return { options: { sort: false }, completions: [] }
    }

    # Get UUID session files (exclude agent-* files), sorted by modification time
    let completions = ls $sessions_dir
        | where name =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
        | sort-by modified --reverse
        | each {|file|
            let uuid = ($file.name | path basename | str replace '.jsonl' '')
            # Try to read summary from first line
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

# Completion for built-in tools
def "nu-complete claude tools" [] {
    [
        { value: "default", description: "Use all built-in tools" }
        { value: "Bash", description: "Execute bash commands" }
        { value: "Edit", description: "Edit files" }
        { value: "Read", description: "Read files" }
        { value: "Write", description: "Write files" }
        { value: "Glob", description: "File pattern matching" }
        { value: "Grep", description: "Search file contents" }
        { value: "Task", description: "Launch subagents" }
        { value: "WebFetch", description: "Fetch web content" }
        { value: "WebSearch", description: "Search the web" }
        { value: "TodoWrite", description: "Manage task lists" }
        { value: "NotebookEdit", description: "Edit Jupyter notebooks" }
    ]
}

# Main claude command
export extern main [
    prompt?: string                                     # Your prompt
    --debug(-d): string                                 # Enable debug mode with optional category filtering
    --verbose                                           # Override verbose mode setting from config
    --print(-p)                                         # Print response and exit (useful for pipes)
    --output-format: string@"nu-complete claude output-format" # Output format (only with --print)
    --json-schema: string                               # JSON Schema for structured output validation
    --include-partial-messages                          # Include partial message chunks (with --print and stream-json)
    --input-format: string@"nu-complete claude input-format" # Input format (only with --print)
    --mcp-debug                                         # [DEPRECATED] Enable MCP debug mode
    --dangerously-skip-permissions                      # Bypass all permission checks
    --allow-dangerously-skip-permissions                # Enable bypassing permissions as an option
    --max-budget-usd: number                            # Maximum dollar amount for API calls (with --print)
    --replay-user-messages                              # Re-emit user messages from stdin to stdout
    --allowed-tools: string@"nu-complete claude tools"  # Comma/space-separated list of allowed tools
    --tools: string@"nu-complete claude tools"          # Specify available tools from built-in set
    --disallowed-tools: string@"nu-complete claude tools" # Comma/space-separated list of denied tools
    --mcp-config: string                                # Load MCP servers from JSON files or strings
    --system-prompt: string                             # System prompt for the session
    --append-system-prompt: string                      # Append to default system prompt
    --permission-mode: string@"nu-complete claude permission-mode" # Permission mode for the session
    --continue(-c)                                      # Continue the most recent conversation
    --resume(-r): string@"nu-complete claude sessions"  # Resume conversation by session ID or open picker
    --fork-session                                      # Create new session ID when resuming
    --no-session-persistence                            # Disable session persistence (with --print)
    --model: string@"nu-complete claude model"          # Model for the current session
    --agent: string                                     # Agent for the current session
    --betas: string                                     # Beta headers for API requests
    --fallback-model: string@"nu-complete claude model" # Fallback model when default is overloaded
    --settings: string                                  # Path to settings JSON file or JSON string
    --add-dir: string                                   # Additional directories to allow tool access to
    --ide                                               # Auto-connect to IDE on startup
    --strict-mcp-config                                 # Only use MCP servers from --mcp-config
    --session-id: string                                # Use specific session ID (must be valid UUID)
    --agents: string                                    # JSON object defining custom agents
    --setting-sources: string                           # Comma-separated setting sources (user, project, local)
    --plugin-dir: string                                # Load plugins from directories
    --disable-slash-commands                            # Disable all slash commands
    --chrome                                            # Enable Claude in Chrome integration
    --no-chrome                                         # Disable Claude in Chrome integration
    --version(-v)                                       # Output the version number
    --help(-h)                                          # Display help for command
]

# MCP server management
export extern "claude mcp" [
    --help(-h)                                          # Display help for command
]

# Plugin management
export extern "claude plugin" [
    --help(-h)                                          # Display help for command
]

# Set up authentication token
export extern "claude setup-token" [
    --help(-h)                                          # Display help for command
]

# Check auto-updater health
export extern "claude doctor" [
    --help(-h)                                          # Display help for command
]

# Check for and install updates
export extern "claude update" [
    --help(-h)                                          # Display help for command
]

# Install Claude Code native build
export extern "claude install" [
    target?: string@"nu-complete claude install-target" # Version to install (stable, latest, or specific)
    --help(-h)                                          # Display help for command
]
