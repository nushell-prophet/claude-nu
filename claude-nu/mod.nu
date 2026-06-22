# claude-nu - Nushell utilities for Claude Code
#
# Public commands (see README.md for details):
#   projects        # List Claude Code projects, most recent first
#   sessions        # Parse sessions into a structured table
#   messages        # Extract user messages from a session
#   export-session  # Render a session's dialogue to markdown
#   save-markdown   # Write exported markdown to files
#
# Usage:
#   use claude-nu
#   claude-nu sessions | where parent_session_id == null | claude-nu messages 'regex'

export use commands.nu [ projects messages sessions export-session save-markdown ]
