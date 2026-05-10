# Nushell custom completions for Claude Code CLI
# Requires Nushell 0.108+

use ../claude-nu/commands.nu [ "nu-complete claude sessions" ]

# ===== Static Completions =====

const output_formats = [
    {value: "text" description: "Plain text output (default)"}
    {value: "json" description: "Single JSON result"}
    {value: "stream-json" description: "Realtime streaming JSON"}
]

const input_formats = [
    {value: "text" description: "Plain text input (default)"}
    {value: "stream-json" description: "Realtime streaming input"}
]

const permission_modes = [
    {value: "acceptEdits" description: "Accept all edit operations"}
    {value: "auto" description: "Auto mode classifier decides"}
    {value: "bypassPermissions" description: "Bypass all permission checks"}
    {value: "default" description: "Default permission handling"}
    {value: "dontAsk" description: "Don't ask for permissions"}
    {value: "plan" description: "Plan mode"}
]

const effort_levels = [
    {value: "low" description: "Low effort"}
    {value: "medium" description: "Medium effort"}
    {value: "high" description: "High effort"}
    {value: "xhigh" description: "Extra-high effort"}
    {value: "max" description: "Maximum effort"}
]

const models = [
    {value: "opus" description: "Claude Opus (most capable)"}
    {value: "sonnet" description: "Claude Sonnet (balanced)"}
    {value: "haiku" description: "Claude Haiku (fastest)"}
    {value: "claude-opus-4-5-20251101" description: "Claude Opus 4.5 (specific version)"}
    {value: "claude-sonnet-4-5-20250929" description: "Claude Sonnet 4.5 (specific version)"}
]

const install_targets = [
    {value: "stable" description: "Stable release"}
    {value: "latest" description: "Latest release"}
]

const mcp_scopes = [
    {value: "local" description: "Local configuration (default)"}
    {value: "user" description: "User-wide configuration"}
    {value: "project" description: "Project-specific configuration"}
]

const mcp_transports = [
    {value: "stdio" description: "Standard I/O (default)"}
    {value: "sse" description: "Server-Sent Events"}
    {value: "http" description: "HTTP transport"}
]

const tools = [
    {value: "default" description: "Use all built-in tools"}
    {value: "Bash" description: "Execute bash commands"}
    {value: "Edit" description: "Edit files"}
    {value: "Read" description: "Read files"}
    {value: "Write" description: "Write files"}
    {value: "Glob" description: "File pattern matching"}
    {value: "Grep" description: "Search file contents"}
    {value: "Task" description: "Launch subagents"}
    {value: "WebFetch" description: "Fetch web content"}
    {value: "WebSearch" description: "Search the web"}
    {value: "TodoWrite" description: "Manage task lists"}
    {value: "NotebookEdit" description: "Edit Jupyter notebooks"}
]

# ===== Main Command =====

export extern main [
    prompt?: string # Your prompt
    --debug (-d): string # Enable debug mode with optional category filtering
    --debug-file: string # Write debug logs to a specific file path (implicitly enables debug mode)
    --verbose # Override verbose mode setting from config
    --print (-p) # Print response and exit (useful for pipes)
    --output-format: string@$output_formats # Output format (only with --print)
    --json-schema: string # JSON Schema for structured output validation
    --include-partial-messages # Include partial message chunks (with --print and stream-json)
    --include-hook-events # Include all hook lifecycle events (only with --output-format=stream-json)
    --input-format: string@$input_formats # Input format (only with --print)
    --mcp-debug # [DEPRECATED] Enable MCP debug mode
    --dangerously-skip-permissions # Bypass all permission checks
    --allow-dangerously-skip-permissions # Enable bypassing permissions as an option
    --max-budget-usd: number # Maximum dollar amount for API calls (with --print)
    --replay-user-messages # Re-emit user messages from stdin to stdout
    --allowed-tools: string@$tools # Comma/space-separated list of allowed tools
    --tools: string@$tools # Specify available tools from built-in set
    --disallowed-tools: string@$tools # Comma/space-separated list of denied tools
    --mcp-config: string # Load MCP servers from JSON files or strings
    --system-prompt: string # System prompt for the session
    --append-system-prompt: string # Append to default system prompt
    --permission-mode: string@$permission_modes # Permission mode for the session
    --continue (-c) # Continue the most recent conversation
    --resume (-r): string@"nu-complete claude sessions" # Resume conversation by session ID or open picker
    --fork-session # Create new session ID when resuming
    --from-pr: string # Resume a session linked to a PR by PR number/URL (optional value)
    --no-session-persistence # Disable session persistence (with --print)
    --model: string@$models # Model for the current session
    --agent: string # Agent for the current session
    --agents: string # JSON object defining custom agents
    --betas: string # Beta headers for API requests
    --fallback-model: string@$models # Fallback model when default is overloaded
    --settings: string # Path to settings JSON file or JSON string
    --add-dir: string # Additional directories to allow tool access to
    --ide # Auto-connect to IDE on startup
    --strict-mcp-config # Only use MCP servers from --mcp-config
    --session-id: string # Use specific session ID (must be valid UUID)
    --setting-sources: string # Comma-separated setting sources (user, project, local)
    --plugin-dir: string # Load plugins from directories
    --plugin-url: string # Fetch a plugin .zip from a URL for this session only (repeatable)
    --disable-slash-commands # Disable all slash commands
    --chrome # Enable Claude in Chrome integration
    --no-chrome # Disable Claude in Chrome integration
    --bare # Minimal mode: skip hooks, LSP, plugin sync, attribution, auto-memory, prefetches, keychain reads, CLAUDE.md auto-discovery
    --brief # Enable SendUserMessage tool for agent-to-user communication
    --exclude-dynamic-system-prompt-sections # Move per-machine sections out of the system prompt for cache reuse
    --effort: string@$effort_levels # Effort level for the current session (low, medium, high, xhigh, max)
    --file: string # File resources to download at startup (file_id:relative_path)
    --name (-n): string # Set a display name for this session
    --remote-control: string # Start an interactive session with Remote Control enabled (optionally named)
    --remote-control-session-name-prefix: string # Prefix for auto-generated Remote Control session names
    --tmux # Create a tmux session for the worktree (requires --worktree)
    --worktree (-w): string # Create a new git worktree for this session (optionally specify a name)
    --version (-v) # Output the version number
    --help (-h) # Display help for command
]

# ===== MCP Commands =====

export extern "claude mcp" [
    --help (-h) # Display help for command
]

export extern "claude mcp serve" [
    --debug (-d) # Enable debug mode
    --verbose # Override verbose mode setting from config
    --help (-h) # Display help for command
]

export extern "claude mcp add" [
    name: string # Server name
    commandOrUrl: string # Command or URL for the server
    ...args: string # Additional arguments
    --scope (-s): string@$mcp_scopes # Configuration scope (local, user, project)
    --transport (-t): string@$mcp_transports # Transport type (stdio, sse, http)
    --env (-e): string # Set environment variables (KEY=value)
    --header (-H): string # Set WebSocket headers
    --help (-h) # Display help for command
]

export extern "claude mcp remove" [
    name: string # Server name to remove
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude mcp list" [
    --help (-h) # Display help for command
]

export extern "claude mcp get" [
    name: string # Server name
    --help (-h) # Display help for command
]

export extern "claude mcp add-json" [
    name: string # Server name
    json: string # JSON configuration string
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude mcp add-from-claude-desktop" [
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude mcp reset-project-choices" [
    --help (-h) # Display help for command
]

# ===== Plugin Commands =====

export extern "claude plugin" [
    --help (-h) # Display help for command
]

export extern "claude plugin validate" [
    path: string # Path to plugin or manifest
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace" [
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace add" [
    source: string # URL, path, or GitHub repo
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace list" [
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace remove" [
    name: string # Marketplace name to remove
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace update" [
    name?: string # Marketplace name (all if not specified)
    --help (-h) # Display help for command
]

export extern "claude plugin install" [
    plugin: string # Plugin name (use plugin@marketplace for specific)
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin uninstall" [
    plugin: string # Plugin name to uninstall
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin enable" [
    plugin: string # Plugin name to enable
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin disable" [
    plugin: string # Plugin name to disable
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin update" [
    plugin: string # Plugin name to update
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

# ===== Other Commands =====

export extern "claude setup-token" [
    --help (-h) # Display help for command
]

export extern "claude doctor" [
    --help (-h) # Display help for command
]

export extern "claude update" [
    --help (-h) # Display help for command
]

export extern "claude install" [
    target?: string@$install_targets # Version to install (stable, latest, or specific)
    --force # Force installation even if already installed
    --help (-h) # Display help for command
]
