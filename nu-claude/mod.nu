# nu-claude - Nushell utilities for Claude Code
#
# Usage:
#   use nu-claude
#   nu-claude messages           # Get user messages from current session
#   nu-claude messages --all     # Include system messages
#   nu-claude messages --raw     # Get raw message records

export use commands.nu [ messages ]
