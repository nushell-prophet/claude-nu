# claude-nu - Nushell utilities for Claude Code
#
# Public commands (see README.md for details):
#   claude-nu -f    # Search this project's user messages (umbrella entry point)
#   projects        # List Claude Code projects, most recent first
#   sessions        # Parse sessions into a structured table
#   messages        # Extract user messages from a session
#   export-session  # Render a session's dialogue to markdown
#   save-markdown   # Write exported markdown to files
#   gi-hook         # Install/remove a per-repo Stop hook that keeps chat terse
#
# Usage:
#   use claude-nu
#   claude-nu -f 'regex'                # quick message search, current project
#   claude-nu sessions | where parent_session_id == null | claude-nu messages 'regex'

export use sessions.nu [
    projects messages main export-session save-markdown
]
export use gi-hook.nu main
use sessions.nu [ find-session-files ]

# Umbrella entry point: search user messages for a regex and return every match
# with its `session` column (a pipeline-safe selector — pipe it into
# export-session/messages/sessions). Searches the current project by default;
# --all-projects widens to every project. With no --find it points at the
# subcommands. Mirrors `help -f`, which greps commands the same way.
# Why: a shorthand for the documented `sessions | where parent_session_id == null
# | messages 'regex'` idiom, so message search is one verb. Lives in mod.nu
# because a directory module's `main` is only picked up when defined here, not
# when re-exported from a submodule. Not built on `find` because: `find` marks
# matches by injecting ansi codes into the cell values (which corrupt the
# path/session selectors) and only sees columns already computed; this reads the
# raw message text instead.
# Why (speed): find-session-files uses rg to narrow to the files whose raw JSONL
# can match before any JSON parsing, then `messages` parses and re-applies the
# real regex only to those — so a wide --all-projects search no longer parses
# every session in every project. It also skips `sessions` entirely: that pass
# computed summary/user_messages columns `messages` then threw away.
# Why (--no-rg): rg scans the raw, escaped JSON, so a pattern leaning on a line
# anchor (^/$) or a JSON-escaped quote/backslash/newline can match the extracted
# text yet not the raw bytes — rg would then skip a file it shouldn't. --no-rg
# parses every session in nushell and matches against the extracted text, so the
# regex behaves exactly; slower, but correct for those patterns.
export def main [
    --find (-f): string # Regex matched against user message text
    --all-projects # Search every project under ~/.claude/projects, not just the current one
    --no-rg # Skip the ripgrep pre-filter and match entirely in-engine (exact regex semantics, slower)
]: nothing -> table {
    if $find == null {
        error make {
            msg: "claude-nu needs a subcommand or a search term"
            help: "search messages:  claude-nu -f 'regex'  (--all-projects to widen)\nsubcommands:  projects, sessions, messages, export-session, save-markdown, gi-hook"
        }
    }
    let files = find-session-files $find --all-projects=$all_projects --no-rg=$no_rg
    if ($files | is-empty) { return [] }
    $files | wrap path | messages $find
}
