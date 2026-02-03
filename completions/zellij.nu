# Nushell custom completions for Zellij terminal multiplexer

# ===== Dynamic Completers =====

# Complete session names from active sessions
def "nu-complete zellij sessions" [] {
    ^zellij list-sessions --no-formatting
    | lines
    | parse "{name} {rest}"
    | get name
}

# Complete layout names from layout directory
def "nu-complete zellij layouts" [] {
    let config_dir = ($env.ZELLIJ_CONFIG_DIR? | default "~/.config/zellij")
    let layout_dir = $"($config_dir)/layouts"
    if ($layout_dir | path exists) {
        ls $layout_dir | where name =~ '\.kdl$' | get name | path basename | str replace '.kdl' ''
    } else {
        []
    }
}

# ===== Static Completers =====

const directions = [left right up down]
const directions_horizontal = [left right]
const resize_actions = [increase decrease]
const input_modes = [locked pane tab resize move search session scroll enter-search rename-tab rename-pane]
const default_modes = [locked pane tab resize move search session]
const shells = [bash zsh fish elvish nu]
const bool_options = ["true" "false"]
const web_sharing_values = [on off disabled]
const clipboard_values = [system primary]
const force_close_values = [quit detach]

# ===== Main Command =====

export extern main [
    --config(-c): path              # Path to configuration file
    --config-dir: path              # Path to configuration directory
    --data-dir: path                # Path to plugin data directory
    --debug(-d)                     # Emit additional debug information
    --layout(-l): string@"nu-complete zellij layouts" # Layout to use
    --max-panes: int                # Maximum panes on screen
    --new-session-with-layout(-n): string@"nu-complete zellij layouts" # Start new session with layout
    --session(-s): string           # Session name
    --help(-h)                      # Print help information
    --version(-V)                   # Print version information
]

# ===== Action Subcommand =====

# Send actions to a specific session
export extern "action" [
    --help(-h)                      # Print help information
]

# Clear all buffers for focused pane
export extern "action clear" [
    --help(-h)                      # Print help information
]

# Close the focused pane
export extern "action close-pane" [
    --help(-h)                      # Print help information
]

# Close the current tab
export extern "action close-tab" [
    --help(-h)                      # Print help information
]

# Dump current layout to stdout
export extern "action dump-layout" [
    --help(-h)                      # Print help information
]

# Dump the focused pane to a file
export extern "action dump-screen" [
    path: path                      # Output file path
    --full(-f)                      # Dump with full scrollback
    --help(-h)                      # Print help information
]

# Open file in a new pane with default editor
export extern "action edit" [
    file: path                      # File to edit
    --cwd: path                     # Working directory for editor
    --direction(-d): string@$directions # Direction to open pane
    --floating(-f)                  # Open in floating mode
    --height: string                # Height (integer or percent)
    --in-place(-i)                  # Open in place of current pane
    --line-number(-l): int          # Open at line number
    --pinned: string@$bool_options   # Pin floating pane
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# Open pane scrollback in default editor
export extern "action edit-scrollback" [
    --help(-h)                      # Print help information
]

# Change focus to next pane
export extern "action focus-next-pane" [
    --help(-h)                      # Print help information
]

# Change focus to previous pane
export extern "action focus-previous-pane" [
    --help(-h)                      # Print help information
]

# Go to next tab
export extern "action go-to-next-tab" [
    --help(-h)                      # Print help information
]

# Go to previous tab
export extern "action go-to-previous-tab" [
    --help(-h)                      # Print help information
]

# Go to tab by index
export extern "action go-to-tab" [
    index: int                      # Tab index (1-based)
    --help(-h)                      # Print help information
]

# Go to tab by name
export extern "action go-to-tab-name" [
    name: string                    # Tab name
    --create(-c)                    # Create tab if it doesn't exist
    --help(-h)                      # Print help information
]

# Scroll down half page in focus pane
export extern "action half-page-scroll-down" [
    --help(-h)                      # Print help information
]

# Scroll up half page in focus pane
export extern "action half-page-scroll-up" [
    --help(-h)                      # Print help information
]

# Launch or focus a plugin
export extern "action launch-or-focus-plugin" [
    url: string                     # Plugin URL
    --configuration(-c): string     # Plugin configuration
    --floating(-f)                  # Open in floating mode
    --in-place(-i)                  # Open in place of current pane
    --move-to-focused-tab(-m)       # Move to focused tab
    --skip-plugin-cache(-s)         # Skip plugin cache
    --help(-h)                      # Print help information
]

# Launch a plugin
export extern "action launch-plugin" [
    url: string                     # Plugin URL
    --configuration(-c): string     # Plugin configuration
    --floating(-f)                  # Open in floating mode
    --in-place(-i)                  # Open in place of current pane
    --skip-plugin-cache(-s)         # Skip plugin cache
    --help(-h)                      # Print help information
]

# List connected clients
export extern "action list-clients" [
    --help(-h)                      # Print help information
]

# Move focus in specified direction
export extern "action move-focus" [
    direction: string@$directions # Direction to move focus
    --help(-h)                      # Print help information
]

# Move focus to pane or tab at screen edge
export extern "action move-focus-or-tab" [
    direction: string@$directions # Direction to move
    --help(-h)                      # Print help information
]

# Move pane in specified direction
export extern "action move-pane" [
    direction?: string@$directions # Direction to move pane
    --help(-h)                      # Print help information
]

# Rotate pane location backwards
export extern "action move-pane-backwards" [
    --help(-h)                      # Print help information
]

# Move tab in specified direction
export extern "action move-tab" [
    direction: string@$directions_horizontal # Direction to move tab
    --help(-h)                      # Print help information
]

# Open a new pane
export extern "action new-pane" [
    ...command: string              # Command to run
    --close-on-exit(-c)             # Close pane when command exits
    --configuration: string         # Plugin configuration
    --cwd: path                     # Working directory
    --direction(-d): string@$directions # Direction to open pane
    --floating(-f)                  # Open in floating mode
    --height: string                # Height (integer or percent)
    --in-place(-i)                  # Open in place of current pane
    --name(-n): string              # Pane name
    --plugin(-p): string            # Plugin URL
    --pinned: string@$bool_options   # Pin floating pane
    --start-suspended(-s)           # Start command suspended
    --skip-plugin-cache             # Skip plugin cache
    --stacked                       # Open in stacked mode
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# Create a new tab
export extern "action new-tab" [
    --cwd(-c): path                 # Working directory
    --layout(-l): string@"nu-complete zellij layouts" # Layout for new tab
    --layout-dir: path              # Layout directory
    --name(-n): string              # Tab name
    --help(-h)                      # Print help information
]

# Switch to next swap layout
export extern "action next-swap-layout" [
    --help(-h)                      # Print help information
]

# Scroll down one page in focus pane
export extern "action page-scroll-down" [
    --help(-h)                      # Print help information
]

# Scroll up one page in focus pane
export extern "action page-scroll-up" [
    --help(-h)                      # Print help information
]

# Send data to plugins via pipe
export extern "action pipe" [
    payload?: string                # Data to send (or stdin)
    --name(-n): string              # Pipe name
    --args(-a): string              # Pipe arguments
    --plugin(-p): string            # Plugin URL
    --plugin-configuration(-c): string # Plugin configuration
    --force-launch-plugin(-l)       # Launch new plugin even if running
    --skip-plugin-cache(-s)         # Skip plugin cache
    --floating-plugin(-f): string@$bool_options # Float plugin pane
    --in-place-plugin(-i): string@$bool_options # Launch plugin in-place
    --plugin-cwd(-w): path          # Plugin working directory
    --plugin-title(-t): string      # Plugin pane title
    --help(-h)                      # Print help information
]

# Switch to previous swap layout
export extern "action previous-swap-layout" [
    --help(-h)                      # Print help information
]

# Query all tab names
export extern "action query-tab-names" [
    --help(-h)                      # Print help information
]

# Rename the focused pane
export extern "action rename-pane" [
    name: string                    # New pane name
    --help(-h)                      # Print help information
]

# Rename the current session
export extern "action rename-session" [
    name: string                    # New session name
    --help(-h)                      # Print help information
]

# Rename the focused tab
export extern "action rename-tab" [
    name: string                    # New tab name
    --help(-h)                      # Print help information
]

# Resize focused pane
export extern "action resize" [
    resize: string@$resize_actions # Resize action
    direction?: string@$directions # Direction to resize
    --help(-h)                      # Print help information
]

# Scroll down in focus pane
export extern "action scroll-down" [
    --help(-h)                      # Print help information
]

# Scroll to bottom in focus pane
export extern "action scroll-to-bottom" [
    --help(-h)                      # Print help information
]

# Scroll to top in focus pane
export extern "action scroll-to-top" [
    --help(-h)                      # Print help information
]

# Scroll up in focus pane
export extern "action scroll-up" [
    --help(-h)                      # Print help information
]

# Stack panes by their IDs
export extern "action stack-panes" [
    ...pane_ids: string             # Pane IDs (terminal_1, plugin_2, or bare int)
    --help(-h)                      # Print help information
]

# Start or reload a plugin
export extern "action start-or-reload-plugin" [
    url: string                     # Plugin URL
    --configuration(-c): string     # Plugin configuration
    --help(-h)                      # Print help information
]

# Switch input mode
export extern "action switch-mode" [
    mode: string@$input_modes # Input mode
    --help(-h)                      # Print help information
]

# Toggle sync for all panes in tab
export extern "action toggle-active-sync-tab" [
    --help(-h)                      # Print help information
]

# Toggle floating panes visibility
export extern "action toggle-floating-panes" [
    --help(-h)                      # Print help information
]

# Toggle fullscreen for focused pane
export extern "action toggle-fullscreen" [
    --help(-h)                      # Print help information
]

# Toggle pane between embedded and floating
export extern "action toggle-pane-embed-or-floating" [
    --help(-h)                      # Print help information
]

# Toggle pane frames in UI
export extern "action toggle-pane-frames" [
    --help(-h)                      # Print help information
]

# Toggle pane pinned state
export extern "action toggle-pane-pinned" [
    --help(-h)                      # Print help information
]

# Remove pane name
export extern "action undo-rename-pane" [
    --help(-h)                      # Print help information
]

# Remove tab name
export extern "action undo-rename-tab" [
    --help(-h)                      # Print help information
]

# Write bytes to terminal
export extern "action write" [
    ...bytes: int                   # Bytes to write
    --help(-h)                      # Print help information
]

# Write characters to terminal
export extern "action write-chars" [
    chars: string                   # Characters to write
    --help(-h)                      # Print help information
]

# Change floating pane coordinates
export extern "action change-floating-pane-coordinates" [
    --pane-id(-p): string           # Pane ID (terminal_1, plugin_2, or int)
    --height: string                # Height (integer or percent)
    --pinned: string@$bool_options   # Pin floating pane
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# ===== Attach Subcommand =====

# Attach to a session
export extern "attach" [
    session_name?: string@"nu-complete zellij sessions" # Session to attach to
    --create(-c)                    # Create session if not exists
    --create-background(-b)         # Create detached session if not exists
    --force-run-commands(-f)        # Run commands on resurrect
    --index: int                    # Session index by creation date
    --help(-h)                      # Print help information
]

# Options for attach
export extern "attach options" [
    --help(-h)                      # Print help information
]

# ===== Convert Commands =====

# Convert configuration format
export extern "convert-config" [
    --help(-h)                      # Print help information
]

# Convert layout format
export extern "convert-layout" [
    --help(-h)                      # Print help information
]

# Convert theme format
export extern "convert-theme" [
    --help(-h)                      # Print help information
]

# ===== Session Management =====

# Delete all sessions
export extern "delete-all-sessions" [
    --force(-f)                     # Kill running sessions first
    --yes(-y)                       # Skip confirmation
    --help(-h)                      # Print help information
]

# Delete a specific session
export extern "delete-session" [
    target_session?: string@"nu-complete zellij sessions" # Session to delete
    --force(-f)                     # Kill running session first
    --help(-h)                      # Print help information
]

# Kill all sessions
export extern "kill-all-sessions" [
    --yes(-y)                       # Skip confirmation
    --help(-h)                      # Print help information
]

# Kill a specific session
export extern "kill-session" [
    target_session?: string@"nu-complete zellij sessions" # Session to kill
    --help(-h)                      # Print help information
]

# List active sessions
export extern "list-sessions" [
    --no-formatting(-n)             # No formatting (for scripts)
    --short(-s)                     # Short format
    --help(-h)                      # Print help information
]

# List existing plugin aliases
export extern "list-aliases" [
    --help(-h)                      # Print help information
]

# ===== Edit Subcommand =====

# Edit file with default editor
export extern "edit" [
    file: path                      # File to edit
    --cwd: path                     # Working directory
    --direction(-d): string@$directions # Direction to open pane
    --floating(-f)                  # Open in floating mode
    --height: string                # Height (integer or percent)
    --in-place(-i)                  # Open in place of current pane
    --line-number(-l): int          # Open at line number
    --pinned: string@$bool_options   # Pin floating pane
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# ===== Options Subcommand =====

# Change zellij behavior
export extern "options" [
    --advanced-mouse-actions: string@$bool_options # Mouse hover effects
    --attach-to-session: string@$bool_options # Attach to named session
    --auto-layout: string@$bool_options # Predefined layouts
    --copy-clipboard: string@$clipboard_values # OSC52 clipboard
    --copy-command: string          # Custom clipboard command
    --copy-on-select: string@$bool_options # Auto copy on select
    --default-cwd: path             # Default working directory
    --default-layout: string@"nu-complete zellij layouts" # Default layout
    --default-mode: string@$default_modes # Default mode
    --default-shell: path           # Default shell
    --disable-mouse-mode            # Disable mouse events
    --disable-session-metadata: string@$bool_options # Disable metadata
    --layout-dir: path              # Layout directory
    --mirror-session: string@$bool_options # Mirror multi-user session
    --mouse-mode: string@$bool_options # Handle mouse events
    --no-pane-frames                # Disable pane frames
    --on-force-close: string@$force_close_values # Force close behavior
    --pane-frames: string@$bool_options # Display pane frames
    --post-command-discovery-hook: string # Command discovery hook
    --scroll-buffer-size: int       # Scroll buffer size
    --scrollback-editor: path       # Scrollback editor path
    --scrollback-lines-to-serialize: int # Lines to serialize
    --serialization-interval: int   # Serialization interval (seconds)
    --serialize-pane-viewport: string@$bool_options # Serialize viewport
    --session-name: string          # Session name
    --session-serialization: string@$bool_options # Enable serialization
    --show-release-notes: string@$bool_options # Show release notes
    --show-startup-tips: string@$bool_options # Show startup tips
    --simplified-ui: string@$bool_options # Simplified UI for fonts
    --stacked-resize: string@$bool_options # Stack panes on resize
    --styled-underlines: string@$bool_options # ANSI styled underlines
    --support-kitty-keyboard-protocol: string@$bool_options # Kitty protocol
    --theme: string                 # Default theme
    --theme-dir: path               # Theme directory
    --web-server: string@$bool_options # Start web server
    --web-sharing: string@$web_sharing_values # Web sharing mode
    --help(-h)                      # Print help information
]

# ===== Pipe Subcommand =====

# Send data to plugins
export extern "pipe" [
    payload?: string                # Data to send (or stdin)
    --name(-n): string              # Pipe name
    --args(-a): string              # Pipe arguments
    --plugin(-p): string            # Plugin URL
    --plugin-configuration(-c): string # Plugin configuration
    --help(-h)                      # Print help information
]

# ===== Plugin Subcommand =====

# Load a plugin
export extern "plugin" [
    url: string                     # Plugin URL (http, file:, zellij:)
    --configuration(-c): string     # Plugin configuration
    --floating(-f)                  # Open in floating mode
    --height: string                # Height (integer or percent)
    --in-place(-i)                  # Open in place of current pane
    --pinned: string@$bool_options   # Pin floating pane
    --skip-plugin-cache(-s)         # Skip cache, recompile
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# ===== Run Subcommand =====

# Run command in new pane
export extern "run" [
    ...command: string              # Command to run
    --close-on-exit(-c)             # Close pane when command exits
    --cwd: path                     # Working directory
    --direction(-d): string@$directions # Direction to open pane
    --floating(-f)                  # Open in floating mode
    --height: string                # Height (integer or percent)
    --in-place(-i)                  # Open in place of current pane
    --name(-n): string              # Pane name
    --pinned: string@$bool_options   # Pin floating pane
    --start-suspended(-s)           # Start suspended
    --stacked                       # Open in stacked mode
    --width: string                 # Width (integer or percent)
    --x(-x): string                 # X coordinate (integer or percent)
    --y(-y): string                 # Y coordinate (integer or percent)
    --help(-h)                      # Print help information
]

# ===== Setup Subcommand =====

# Setup zellij and check configuration
export extern "setup" [
    --check                         # Check configuration
    --clean                         # Load default config
    --dump-config                   # Dump default config
    --dump-layout: string@"nu-complete zellij layouts" # Dump layout
    --dump-plugins: path            # Dump plugins to directory
    --dump-swap-layout: string      # Dump swap layout
    --generate-auto-start: string@$shells # Auto-start script
    --generate-completion: string@$shells # Shell completion
    --help(-h)                      # Print help information
]

# ===== Web Subcommand =====

# Run web server for terminal sessions
export extern "web" [
    --start                         # Start the server
    --stop                          # Stop the server
    --status                        # Get server status
    --daemonize(-d)                 # Run in background
    --create-token                  # Create login token
    --revoke-token: string          # Revoke token by name
    --revoke-all-tokens             # Revoke all tokens
    --list-tokens                   # List token names
    --ip: string                    # Listen IP (default 127.0.0.1)
    --port: int                     # Listen port (default 8082)
    --cert: path                    # SSL certificate path
    --key: path                     # SSL key path
    --help(-h)                      # Print help information
]

# ===== Help Subcommand =====

# Print help message
export extern "help" [
    subcommand?: string             # Subcommand to get help for
]
