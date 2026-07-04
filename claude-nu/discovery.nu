# claude-nu discovery: where session files live on disk — enumerating,
# resolving, and reading them. Standalone — imports nothing from the other
# claude-nu submodules.

# UUID pattern for session files
export const UUID_JSONL_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# Subagent JSONL pattern (Claude Code 2.1.138+ layout:
# `<project>/<session-uuid>/subagents/agent-<id>.jsonl`)
export const AGENT_JSONL_PATTERN = 'agent-[0-9a-f]+\.jsonl$'

# Root of Claude Code session storage: ~/.claude/projects
export def projects-root []: nothing -> path {
    $env.HOME | path join ".claude" "projects"
}

# Sessions directory for the current project: ~/.claude/projects/<encoded-pwd>
export def get-sessions-dir []: nothing -> path {
    projects-root | path join ($env.PWD | path expand | str replace --all '/' '-')
}

# Project directory name a session file belongs to — the first path segment
# under ~/.claude/projects. Why: `path dirname` is right for top-level files
# (<root>/<proj>/<uuid>.jsonl) but wrong for subagent transcripts
# (<root>/<proj>/<uuid>/subagents/agent-*.jsonl), where it yields "subagents" —
# that mislabels rows and falsely trips multi-project tagging inside one
# project. Files outside the root fall back to their parent directory name.
export def project-dir-name []: path -> string {
    let file = $in
    let rel = try { $file | path relative-to (projects-root) } catch { null }
    if $rel == null {
        $file | path dirname | path basename
    } else {
        $rel | path split | first
    }
}

# Resolve session file path from UUID, path, or default to most recent
export def resolve-session-file [
    session?: string # Session UUID or path (null = most recent)
    --sessions-dir: path # Override sessions directory
]: nothing -> path {
    let dir = $sessions_dir | default (get-sessions-dir)

    if $session != null {
        if ($session | str ends-with '.jsonl') {
            return $session
        }
        let candidate = $dir | path join $"($session).jsonl"
        if ($candidate | path exists) {
            return $candidate
        }
        # Why: UUIDs are globally unique, but piped rows (or --session) may
        # point at a session from another project — search all projects
        # before giving up.
        let found = glob (projects-root | path join $"*/($session).jsonl")
        if ($found | is-empty) {
            error make {msg: $"Session not found in any project: ($session)"}
        }
        return ($found | first)
    }

    if not ($dir | path exists) {
        error make {msg: "No sessions directory found for current project"}
    }

    # Why: one discoverer owns the listing and recency order, so "most recent
    # session" is the first top-level (non-subagent) row it yields.
    let files = discover-session-files $dir | where parent_session_id == null

    if ($files | is-empty) {
        error make {msg: "No session files found"}
    }

    $files | first | get path
}

# Session UUID from a session file path
export def session-id-from-path []: path -> string {
    path basename | str replace '.jsonl' ''
}

# Read a session JSONL file into a table of records, one record per line. The
# single decode point for a session's raw records: every full-file parser goes
# through here, so "a session is one JSON object per line" lives in one place
# (and any future empty/corrupt-line handling has a single home).
# Why (speed): `from json --objects` decodes the whole NDJSON stream in one call
# instead of `lines | each { from json }`, which restarts the parser per line —
# ~1.25x faster across every session parse. --contains pre-screens the raw lines
# by substring before decoding, so a caller wanting one record type (messages
# wants user turns — only ~30% of lines) never parses the rest; the caller still
# re-filters the decoded `type`, so a line merely quoting the marker can't slip in.
export def read-session-records [--contains: string]: path -> table {
    open --raw $in
    | if $contains == null { } else { lines | where ($it | str contains $contains) | str join "\n" }
    | from json --objects
}

# Discover session files in a directory, newest first. Returns rows
# {path, parent_session_id, modified}; parent_session_id is the parent session
# UUID for subagent files (`<uuid>/subagents/agent-*.jsonl`), null for top-level
# files. Single source of truth for the on-disk session layout — every command
# that lists sessions for parsing goes through here, so the name patterns, the
# subagent walk, and the recency order live in one place. (Two lightweight
# listers in sessions.nu — `projects` and the sessions completer — stay
# independent by choice: they only need top-level names/mtimes/sizes, and this
# walk would add a subagents glob per directory for nothing.) Callers wanting
# only human-driven sessions filter `where parent_session_id == null`.
export def discover-session-files [dir: path]: nothing -> table {
    # Why: top-level files sit directly in $dir, so one `ls` lists them with
    # their mtimes; an empty dir is just [], whereas `ls` on a no-match glob
    # errors — keeping the empty case graceful without a special branch.
    let top_level = ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | each {|f| {path: $f.name parent_session_id: null modified: $f.modified} }

    # Why: subagent transcripts are nested out of reach of a flat `ls`, so a glob
    # descends to them. The `**` is load-bearing: Workflow agents nest deeper, at
    # `<uuid>/subagents/workflows/wf_*/agent-*.jsonl`, so a single-level
    # `*/subagents/*.jsonl` silently misses them. The parent UUID is therefore the
    # first path segment under $dir (depth-independent), not "two levels up" —
    # two-up would yield `workflows` for the nested ones.
    # Why (speed): one `ls <glob>` stats every transcript in a single directory
    # walk; the old `glob | each { ls }` re-stated each file individually (~10x
    # slower on a project with many subagents). `ls` errors on a no-match glob, so
    # try/catch keeps the empty case graceful (matching `glob`'s old behavior).
    let subagent_files = try { ls (($dir | path join "*/subagents/**/*.jsonl") | into glob) } catch { [] }
        | where name =~ $AGENT_JSONL_PATTERN
        | each {|f|
            {path: $f.name parent_session_id: ($f.name | path relative-to $dir | path split | first) modified: $f.modified}
        }

    $top_level | append $subagent_files | sort-by modified --reverse
}

# Session files (current project, or every project with --all-projects) whose
# raw JSONL contains `pattern`, newest first. Uses ripgrep to skip files that
# cannot match before the costly JSON parse; without rg it returns every
# top-level session file and lets the caller's structured filter do the work.
# Subagent transcripts are excluded — they carry no human-typed messages.
# Why: rg scans the raw, escaped JSON, so it can't honor line anchors or match a
# JSON-escaped quote/backslash the way the structured regex on extracted text
# does. That only ever costs recall for such patterns; it never yields a wrong
# hit, because `claude-nu -f` re-applies the real regex to the parsed text. For
# ordinary word/phrase/regex searches rg and the structured filter agree (both
# use Rust's regex engine), and we open only the few files that can match
# instead of parsing every session in every project. --no-rg forces the full
# enumeration so the caller's regex runs against the extracted text with exact
# semantics — the escape hatch for a pattern rg's raw scan would under-match.
export def find-session-files [
    pattern: string # Regex (Rust syntax) matched against raw session JSONL
    --all-projects # Search every project under ~/.claude/projects, not just the current one
    --no-rg # Skip the ripgrep pre-filter; return every top-level file for the caller to filter
]: nothing -> list<path> {
    let rows = if $no_rg or (which rg | is-empty) {
        top-level-session-files --all-projects=$all_projects
    } else {
        rg-session-files $pattern --all-projects=$all_projects
    }
    if ($rows | is-empty) { return [] }
    $rows | sort-by modified --reverse | get path
}

# Top-level session files in scope as {path, modified} rows (no content filter).
# The rg-less fallback for find-session-files, and the single place the
# project-vs-all-projects enumeration lives.
export def top-level-session-files [--all-projects]: nothing -> table {
    let dirs = if $all_projects {
        let root = projects-root
        if not ($root | path exists) { return [] }
        ls $root | where type == dir | get name
    } else {
        let dir = get-sessions-dir
        if not ($dir | path exists) { return [] }
        [$dir]
    }
    $dirs
    | each {|d| discover-session-files $d | where parent_session_id == null | select path modified }
    | flatten
}

# Top-level session files whose raw JSONL matches `pattern`, as {path, modified}.
# Why: --no-ignore --hidden so a stray .gitignore or the dot in ~/.claude can't
# hide a session; the subagents glob keeps us to human dialogue; the UUID-name
# guard mirrors discover-session-files' definition of a session file. The pattern
# goes through --regexp (which allows a leading `-`), not as a bare arg. rg exit
# 1 means "no match" (empty); only a real failure (exit 2+) errors — fail fast on
# a broken pattern instead of silently returning nothing.
export def rg-session-files [pattern: string --all-projects]: nothing -> table {
    let root = if $all_projects { projects-root } else { get-sessions-dir }
    if not ($root | path exists) { return [] }
    let res = rg --no-ignore --hidden --files-with-matches --glob '*.jsonl' --glob '!**/subagents/**' --regexp $pattern -- $root | complete
    let files = match $res.exit_code {
        0 => ($res.stdout | lines)
        1 => []
        _ => (error make {msg: $"rg failed \(exit ($res.exit_code)): ($res.stderr | str trim)"})
    }
    $files
    | where ($it | path basename) =~ $UUID_JSONL_PATTERN
    | each {|p| {path: $p modified: (ls $p | get 0.modified) } }
}
