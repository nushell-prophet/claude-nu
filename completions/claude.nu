# Nushell custom completions for Claude Code CLI
# Requires Nushell 0.114+ (commandline complete)

use ../claude-nu/sessions.nu [ "nu-complete claude sessions" ]

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
    {value: "claude-opus-4-8" description: "Claude Opus 4.8 (specific version)"}
    {value: "claude-opus-4-8[1m]" description: "Claude Opus 4.8, 1M context"}
    {value: "claude-sonnet-4-6" description: "Claude Sonnet 4.6 (specific version)"}
]

const mcp_scopes = [
    {value: "local" description: "Local configuration (default)"}
    {value: "user" description: "User-wide configuration"}
    {value: "project" description: "Project-specific configuration"}
]

const plugin_update_scopes = [
    {value: "local" description: "Local configuration"}
    {value: "user" description: "User-wide configuration (default)"}
    {value: "project" description: "Project-specific configuration"}
    {value: "managed" description: "Managed installation scope"}
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

const setting_sources = [
    {value: "user" description: "Global user settings (~/.claude/settings.json)"}
    {value: "project" description: "Shared project settings (.claude/settings.json)"}
    {value: "local" description: "Local project settings (.claude/settings.local.json)"}
]

# ===== Completer Helpers =====

# Keep the menu in the list's semantic order (e.g. effort low -> max)
# instead of Nushell's default alphabetical re-sort.
def ordered []: table -> record {
    {options: {sort: false} completions: $in}
}

# Comma-separated multi-value completion: segments already typed stay as a
# prefix, remaining values are offered for the segment after the last comma.
def comma-list [context: string]: table -> table {
    let token = $context | split row ' ' | last
    let chosen = $token | split row ',' | drop 1
    let prefix = $chosen | str join ','
    $in
    | where value not-in $chosen
    | if ($prefix | is-empty) { } else { update value {|it| $"($prefix),($it.value)" } }
}

def "nu-complete claude output-formats" [] { $output_formats | ordered }
def "nu-complete claude input-formats" [] { $input_formats | ordered }
def "nu-complete claude effort" [] { $effort_levels | ordered }
def "nu-complete claude models" [] { $models | ordered }

def "nu-complete claude tools" [context: string] { $tools | comma-list $context }
def "nu-complete claude setting-sources" [context: string] { $setting_sources | comma-list $context }

# Free-text argument: suppress Nushell's file-path fallback
def "nu-complete claude freetext" []: nothing -> list<string> { [] }

# The prompt positional doubles as the value slot for optional-value flags.
# Why: Nushell can't express an optional-value flag (a typed flag always demands
# a value), so --resume is a bare switch and any session id given lands here as a
# positional. Offer the session picker only when --resume/-r is on the line;
# otherwise suppress file completion like plain freetext.
def "nu-complete claude prompt" [context: string]: nothing -> any {
    if ($context | split row ' ' | any {|w| $w in ['--resume' '-r']}) {
        nu-complete claude sessions
    } else { [] }
}

# Directory suggestions from Nushell's own completion engine
def "nu-complete claude dirs" [context: string]: nothing -> list<string> {
    $context | split row ' ' | last | commandline complete --type directory
}

# ===== Dynamic Completions =====

# MCP server names across scopes: user (~/.claude.json), project (.mcp.json),
# and local (per-project entry inside ~/.claude.json)
def "nu-complete claude mcp servers" []: nothing -> list<string> {
    let user_cfg = try { open ~/.claude.json } catch { {} }
    # Why: transpose + where instead of `get $env.PWD` because get parses
    # string keys as cell paths and would split a path containing dots
    let local = $user_cfg
        | get -o projects
        | default {}
        | transpose path cfg
        | where path == $env.PWD
        | get -o 0.cfg.mcpServers
        | default {}
    let project = try { open .mcp.json | get -o mcpServers | default {} } catch { {} }
    [($user_cfg | get -o mcpServers | default {}) $project $local]
    | each { columns }
    | flatten
    | uniq
}

# Installed plugins (name@marketplace), described by their install scopes
def "nu-complete claude installed-plugins" []: nothing -> table {
    try {
        open ~/.claude/plugins/installed_plugins.json
        | get plugins
        | transpose name installs
        | each {|p| {value: $p.name description: ($p.installs.scope | uniq | str join ", ")} }
    } catch { [] }
}

# Plugins offered by known marketplaces (for `plugin install`)
def "nu-complete claude marketplace-plugins" []: nothing -> table {
    try {
        open ~/.claude/plugins/known_marketplaces.json
        | transpose name cfg
        | each {|m|
            try {
                open ($m.cfg.installLocation | path join .claude-plugin marketplace.json)
                | get plugins
                | each {|p| {
                    value: $"($p.name)@($m.name)"
                    description: ($p | get -o description | default '' | str replace -r '(?s)(.{80}).+' '$1…')
                } }
            } catch { [] }
        }
        | flatten
    } catch { [] }
}

def "nu-complete claude marketplaces" []: nothing -> table {
    try {
        open ~/.claude/plugins/known_marketplaces.json
        | transpose name cfg
        | each {|m| {value: $m.name description: ($m.cfg | get -o source.repo | default '')} }
    } catch { [] }
}

# Agent names from project and user agent definitions
def "nu-complete claude agents" []: nothing -> list<string> {
    glob .claude/agents/*.md
    | append (glob ("~/.claude/agents/*.md" | path expand))
    | each { path parse | get stem }
    | uniq
}

# Project paths Claude Code has been run in (keys of ~/.claude.json projects)
def "nu-complete claude projects" []: nothing -> list<string> {
    try { open ~/.claude.json | get projects | columns } catch { [] }
}

# ===== Main Command =====

export extern main [
    prompt?: any@"nu-complete claude prompt" # Your prompt (also the value slot for --resume et al.; `any` so bool/int values like `--prompt-suggestions false` or `--worktree 5` pass through instead of failing a string type-check)
    --debug (-d) # Enable debug mode with optional category filtering (category passes through as a positional)
    --debug-file: path # Write debug logs to a specific file path (implicitly enables debug mode)
    --verbose # Override verbose mode setting from config
    --print (-p) # Print response and exit (useful for pipes)
    --output-format: string@"nu-complete claude output-formats" # Output format (only with --print)
    --json-schema: string@"nu-complete claude freetext" # JSON Schema for structured output validation
    --include-partial-messages # Include partial message chunks (with --print and stream-json)
    --include-hook-events # Include all hook lifecycle events (only with --output-format=stream-json)
    --input-format: string@"nu-complete claude input-formats" # Input format (only with --print)
    --mcp-debug # [DEPRECATED] Enable MCP debug mode
    --dangerously-skip-permissions # Bypass all permission checks
    --allow-dangerously-skip-permissions # Enable bypassing permissions as an option
    --max-budget-usd: number # Maximum dollar amount for API calls (with --print)
    --replay-user-messages # Re-emit user messages from stdin to stdout
    --prompt-suggestions # In print/SDK mode, emit a predicted next prompt after each turn (optional value; bare presets "true", an explicit true/false/on/off/... passes through as a positional)
    --allowed-tools: string@"nu-complete claude tools" # Comma/space-separated list of allowed tools
    --tools: string@"nu-complete claude tools" # Specify available tools from built-in set
    --disallowed-tools: string@"nu-complete claude tools" # Comma/space-separated list of denied tools
    --mcp-config: path # Load MCP servers from JSON files or strings
    --system-prompt: string@"nu-complete claude freetext" # System prompt for the session
    --append-system-prompt: string@"nu-complete claude freetext" # Append to default system prompt
    --permission-mode: string@$permission_modes # Permission mode for the session
    --continue (-c) # Continue the most recent conversation
    --resume (-r) # Resume conversation by session ID or open picker (optional value; id passes through as a positional, completed via "nu-complete claude prompt")
    --fork-session # Create new session ID when resuming
    --from-pr # Resume a session linked to a PR by PR number/URL (optional value; passes through as a positional)
    --no-session-persistence # Disable session persistence (with --print)
    --model: string@"nu-complete claude models" # Model for the current session
    --agent: string@"nu-complete claude agents" # Agent for the current session
    --agents: string@"nu-complete claude freetext" # JSON object defining custom agents
    --betas: string@"nu-complete claude freetext" # Beta headers for API requests
    --fallback-model: string@"nu-complete claude models" # Fallback model when default is overloaded
    --settings: path # Path to settings JSON file or JSON string
    --add-dir: string@"nu-complete claude dirs" # Additional directories to allow tool access to
    --ide # Auto-connect to IDE on startup
    --strict-mcp-config # Only use MCP servers from --mcp-config
    --session-id: string@"nu-complete claude sessions" # Use specific session ID (must be valid UUID)
    --setting-sources: string@"nu-complete claude setting-sources" # Comma-separated setting sources (user, project, local)
    --plugin-dir: string@"nu-complete claude dirs" # Load plugins from directories
    --plugin-url: string@"nu-complete claude freetext" # Fetch a plugin .zip from a URL for this session only (repeatable)
    --disable-slash-commands # Disable all slash commands
    --chrome # Enable Claude in Chrome integration
    --no-chrome # Disable Claude in Chrome integration
    --bare # Minimal mode: skip hooks, LSP, plugin sync, attribution, auto-memory, prefetches, keychain reads, CLAUDE.md auto-discovery
    --safe-mode # Start with all customizations disabled (CLAUDE.md, skills, plugins, hooks, MCP, custom commands/agents, ...); sets CLAUDE_CODE_SAFE_MODE=1
    --brief # Enable SendUserMessage tool for agent-to-user communication
    --exclude-dynamic-system-prompt-sections # Move per-machine sections out of the system prompt for cache reuse
    --effort: string@"nu-complete claude effort" # Effort level for the current session (low, medium, high, xhigh, max)
    --file: string@"nu-complete claude freetext" # File resources to download at startup (file_id:relative_path)
    --name (-n): string@"nu-complete claude freetext" # Set a display name for this session
    --remote-control # Start an interactive session with Remote Control enabled (optionally named; name passes through as a positional)
    --remote-control-session-name-prefix: string@"nu-complete claude freetext" # Prefix for auto-generated Remote Control session names
    --tmux # Create a tmux session for the worktree (requires --worktree)
    --worktree (-w) # Create a new git worktree for this session (optionally specify a name; name passes through as a positional)
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
    name: string@"nu-complete claude freetext" # Server name
    commandOrUrl: string # Command or URL for the server
    ...args: string # Additional arguments
    --scope (-s): string@$mcp_scopes # Configuration scope (local, user, project)
    --transport (-t): string@$mcp_transports # Transport type (stdio, sse, http)
    --env (-e): string@"nu-complete claude freetext" # Set environment variables (KEY=value)
    --header (-H): string@"nu-complete claude freetext" # Set WebSocket headers
    --callback-port: int # Fixed port for OAuth callback (for servers requiring pre-registered redirect URIs)
    --client-id: string@"nu-complete claude freetext" # OAuth client ID for HTTP/SSE servers
    --client-secret # Prompt for OAuth client secret (or set MCP_CLIENT_SECRET env var)
    --help (-h) # Display help for command
]

export extern "claude mcp remove" [
    name: string@"nu-complete claude mcp servers" # Server name to remove
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude mcp list" [
    --help (-h) # Display help for command
]

export extern "claude mcp get" [
    name: string@"nu-complete claude mcp servers" # Server name
    --help (-h) # Display help for command
]

export extern "claude mcp add-json" [
    name: string@"nu-complete claude freetext" # Server name
    json: string@"nu-complete claude freetext" # JSON configuration string
    --scope (-s): string@$mcp_scopes # Configuration scope
    --client-secret # Prompt for OAuth client secret (or set MCP_CLIENT_SECRET env var)
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
    path: path # Path to plugin or manifest
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace" [
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace add" [
    source: string # URL, path, or GitHub repo
    --scope: string@$mcp_scopes # Where to declare the marketplace (user default, project, local)
    --sparse: string@"nu-complete claude freetext" # Limit checkout to specific directories via git sparse-checkout (repeatable)
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace list" [
    --json # Output as JSON
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace remove" [
    name: string@"nu-complete claude marketplaces" # Marketplace name to remove
    --help (-h) # Display help for command
]

export extern "claude plugin marketplace update" [
    name?: string@"nu-complete claude marketplaces" # Marketplace name (all if not specified)
    --help (-h) # Display help for command
]

export extern "claude plugin install" [
    plugin: string@"nu-complete claude marketplace-plugins" # Plugin name (use plugin@marketplace for specific)
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin uninstall" [
    plugin: string@"nu-complete claude installed-plugins" # Plugin name to uninstall
    --scope (-s): string@$mcp_scopes # Configuration scope
    --keep-data # Preserve the plugin's persistent data directory (~/.claude/plugins/data/{id}/)
    --prune # Also remove auto-installed dependencies that are no longer needed
    --yes (-y) # Skip the --prune confirmation prompt (required when stdin is not a TTY)
    --help (-h) # Display help for command
]

export extern "claude plugin enable" [
    plugin: string@"nu-complete claude installed-plugins" # Plugin name to enable
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin disable" [
    plugin?: string@"nu-complete claude installed-plugins" # Plugin name to disable (omit with --all)
    --all (-a) # Disable all enabled plugins
    --scope (-s): string@$mcp_scopes # Configuration scope
    --help (-h) # Display help for command
]

export extern "claude plugin update" [
    plugin: string@"nu-complete claude installed-plugins" # Plugin name to update
    --scope (-s): string@$plugin_update_scopes # Installation scope: user, project, local, managed
    --help (-h) # Display help for command
]

export extern "claude plugin list" [
    --available # Include available plugins from marketplaces (requires --json)
    --json # Output as JSON
    --help (-h) # Display help for command
]

export extern "claude plugin prune" [
    --dry-run # List what would be removed without removing
    --scope (-s): string@$mcp_scopes # Prune at scope: user (default), project, or local
    --yes (-y) # Skip the confirmation prompt (required when stdin is not a TTY)
    --help (-h) # Display help for command
]

export extern "claude plugin tag" [
    path?: string@"nu-complete claude dirs" # Path to plugin directory
    --dry-run # Print what would be tagged without creating it
    --force (-f) # Skip the dirty-working-tree and tag-already-exists checks
    --message (-m): string@"nu-complete claude freetext" # Tag annotation message (use %s for the version)
    --push # Push the tag to --remote after creating it
    --remote: string@"nu-complete claude freetext" # Remote to push to with --push (default: "origin")
    --help (-h) # Display help for command
]

# ===== Auth Commands =====

export extern "claude auth" [
    --help (-h) # Display help for command
]

export extern "claude auth login" [
    --claudeai # Use Claude subscription (default)
    --console # Use Anthropic Console (API usage billing) instead of Claude subscription
    --email: string@"nu-complete claude freetext" # Pre-populate email address on the login page
    --sso # Force SSO login flow
    --help (-h) # Display help for command
]

export extern "claude auth logout" [
    --help (-h) # Display help for command
]

export extern "claude auth status" [
    --json # Output as JSON (default)
    --text # Output as human-readable text
    --help (-h) # Display help for command
]

# ===== Auto Mode Commands =====

export extern "claude auto-mode" [
    --help (-h) # Display help for command
]

export extern "claude auto-mode config" [
    --help (-h) # Display help for command
]

export extern "claude auto-mode critique" [
    --model: string@"nu-complete claude models" # Override which model is used
    --help (-h) # Display help for command
]

export extern "claude auto-mode defaults" [
    --help (-h) # Display help for command
]

# ===== Project Commands =====

export extern "claude project" [
    --help (-h) # Display help for command
]

export extern "claude project purge" [
    path?: string@"nu-complete claude projects" # Project path (omit with --all)
    --all # Purge state for every project (mutually exclusive with [path])
    --dry-run # List what would be deleted without deleting anything
    --interactive (-i) # Prompt for each item before deleting
    --yes (-y) # Skip confirmation prompt
    --help (-h) # Display help for command
]

# ===== Ultrareview =====

export extern "claude ultrareview" [
    target?: string # PR number, base branch, or empty for current branch
    --json # Print the raw bugs.json payload instead of formatted findings
    --timeout: int # Maximum minutes to wait for the review to finish (default 30)
    --help (-h) # Display help for command
]

# ===== Agents (background sessions) =====

export extern "claude agents" [
    --add-dir: string@"nu-complete claude dirs" # Additional directory to allow tool access to in dispatched sessions (repeatable)
    --agent: string@"nu-complete claude agents" # Default agent for dispatched sessions (overrides the 'agent' setting)
    --allow-dangerously-skip-permissions # Make bypass-permissions mode available to dispatched sessions without defaulting to it
    --cwd: path # Show only background sessions started under this path
    --dangerously-skip-permissions # Alias for --permission-mode bypassPermissions
    --effort: string@"nu-complete claude effort" # Default effort level for dispatched sessions
    --json # Print live sessions as a JSON array and exit (for scripting; no TTY required)
    --mcp-config: path # MCP server configuration to apply to dispatched sessions (repeatable)
    --model: string@"nu-complete claude models" # Default model for dispatched sessions
    --permission-mode: string@$permission_modes # Default permission mode for dispatched sessions
    --setting-sources: string@"nu-complete claude setting-sources" # Comma-separated setting sources (user, project, local)
    --settings: string # Settings file or JSON string to apply to the agent view and dispatched sessions
    --strict-mcp-config # Only use MCP servers from --mcp-config in dispatched sessions
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
    target?: string@[stable latest] # Version to install (stable, latest, or specific)
    --force # Force installation even if already installed
    --help (-h) # Display help for command
]
