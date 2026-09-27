# claude-nu timeline - the interleaved record of a session, one row per
# content block.
use sessions.nu [
    piped-session-files drop-copied-records top-level-session-files
    resolve-time-bound mtime-filter-session-files rg-filter-session-files
    read-session-records session-id-from-path project-dir-name
    project-display-name pick-first content-blocks extract-text-content
    tool-result-text is-user-text
]

# The block kinds a timeline shows. Others — server tools and their results,
# documents, images — drop out: none of them is a turn of the dialogue or a
# call the session's own tools made.
const KINDS = ["text" "thinking" "tool_use" "tool_result"]

# The interleaved record of Claude Code session files: one row per content
# block, in file order — {role, kind, text, tool, id, is_error, timestamp, uuid,
# session, project, project_name}. `kind` is text, thinking, tool_use or
# tool_result; `text` is the block's text, a tool_use's input as compact JSON,
# or a tool_result's result text. `tool` names the tool on a tool_use and, joined
# by `id`, on its tool_result; `is_error` is set on a tool_result only.
# Scoping and searching work exactly as in `messages`: no input reads every
# top-level session of the current project, piped session rows narrow it, the
# regex argument (over `text` and `tool`) gets the same rg pre-filter, and
# `--no-rg` turns that off.
# Why a command of its own: `messages` and `tool-calls` are one table per kind,
# so the order between kinds is lost — "text followed by a tool call" and "the
# calls between two prompts" could not be asked, and past agents rebuilt this
# stream by hand from the raw records.
# Why file order and no sort by timestamp: blocks of one record share a
# timestamp, so a sort could only lose the order inside a turn.
@category claude-nu
@example "what the agent said right before each tool call" { claude-nu sessions --last | claude-nu timeline | window 2 | where {|w| $w.0.role == assistant and $w.0.kind == text and $w.1.kind == tool_use } | each {|w| {said: $w.0.text tool: $w.1.tool} } }
@example "the failed calls of the last session, with their results" { claude-nu sessions --last | claude-nu timeline | where is_error == true | select tool text }
export def main [
    regex?: string # Filter blocks by regex over `text` and `tool`
    --since: any # Only blocks at or after this point — a duration means ago (`1wk`), or a datetime/date string
    --until: any # Only blocks at or before this point
    --include-system # Keep system/meta turns and the wrappers Claude Code writes as the user
    --no-rg # Skip the ripgrep file pre-filter and match entirely in-engine (exact regex semantics, slower)
]: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    # Why up here: same as in `messages` — a bad bound fails before any parsing.
    let since_at = if $since == null { null } else { $since | resolve-time-bound "--since" }
    let until_at = if $until == null { null } else { $until | resolve-time-bound "--until" }

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    # Why here, before rg: same reason as in `messages` — rg's own "No such
    # file" would mask this and discard the matches it did find.
    let missing = $scoped_files | where not ($it | path exists)

    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    $scoped_files
    | if $since_at == null { } else { mtime-filter-session-files $since_at }
    | if $regex == null or $no_rg { } else { rg-filter-session-files $regex }
    | each {|session_file|
        let records = $session_file | read-session-records
        let blocks = $records
            | where type? in ["user" "assistant"]
            | if $include_system { } else { where isMeta? != true }
            | each { record-blocks }
            | flatten
            | if $include_system { } else {
                where role != "user" or kind != "text" or ($it.text | is-user-text)
            }
        # Why the join covers the whole file, before the time window: a result
        # inside the window names a call that may sit just outside it.
        # Why the null ids are dropped: `join` pairs a null key with a null key,
        # so every text block would take the name of a call that has no id.
        let names = $blocks
            | where kind == "tool_use" and id != null
            | select id tool
            | rename id call_tool
            | uniq-by id

        $blocks
        # Why the default: joined against no calls at all, `join` adds no
        # column, and the next line would fail on a session with no tools.
        | join --left $names id
        | default null call_tool
        | update tool {|b| default $b.call_tool }
        | reject call_tool
        | if $since_at == null { } else { where timestamp >= $since_at }
        | if $until_at == null { } else { where timestamp <= $until_at }
        | if $regex == null { } else {
            where text =~ $regex or ($it.tool | default "") =~ $regex
        }
        | insert session ($session_file | session-id-from-path)
        | insert project ($session_file | project-dir-name)
        | insert project_name ($records | pick-first $.cwd | project-display-name)
    }
    | flatten
    # Why a key per block and not the record uuid alone: a user record carries
    # every tool_result of a turn, so deduping on its uuid would keep one of them.
    | drop-copied-records _block_key
    | reject _block_key
}

# The timeline rows of one user or assistant record, one per content block of a
# kind in KINDS; empty text and thinking drop out.
# Why a string content counts as one text block: that is how a typed prompt is
# stored, and `extract-text-content` renders a `!`-command wrapper there the way
# `messages` shows it.
def record-blocks []: record -> table {
    let record = $in
    let content = $record.message?.content?
    let blocks = if ($content | describe) == "string" {
        [{type: "text" text: ($record | extract-text-content)}]
    } else {
        $content | content-blocks
    }
    # Why $record.timestamp and not `?`: every user and assistant record in the
    # store carries one (19873 of 19873 checked), so a missing one is a changed
    # record shape and must fail here, as in `tool-calls`.
    let timestamp = $record.timestamp | into datetime

    $blocks
    | enumerate
    | where item.type? in $KINDS
    | each {|b|
        let fields = $b.item | block-fields

        {
            role: $record.type
            kind: $fields.kind
            text: $fields.text
            tool: $fields.tool?
            id: $fields.id?
            is_error: $fields.is_error?
            timestamp: $timestamp
            uuid: $record.uuid?
            # Why the index is taken before any block is dropped: a copy in a
            # resumed session holds the same blocks, so the same index names
            # the same block in both files.
            _block_key: (if $record.uuid? == null { null } else { $"($record.uuid)/($b.index)" })
        }
    }
    | where kind in ["tool_use" "tool_result"] or ($it.text | str trim | is-not-empty)
}

# The kind-specific fields of one content block whose type is in KINDS.
def block-fields []: record -> record {
    let block = $in

    match $block.type? {
        "text" => {kind: "text" text: ($block.text? | default "")}
        "thinking" => {kind: "thinking" text: ($block.thinking? | default "")}
        # Why compact JSON: one rendering for every tool, the form the rg
        # pre-filter reads in the raw line, so the regex over `text` means the
        # same with and without --no-rg — as in `tool-calls` and `records`.
        # Not NUON on screen with JSON searched behind it because: a pattern
        # copied from `text` would then find nothing, the same trap reversed;
        # the noisier column is the accepted cost.
        "tool_use" => {kind: "tool_use" text: ($block.input? | default {} | to json --raw) tool: ($block.name? | default "") id: $block.id?}
        "tool_result" => {kind: "tool_result" text: ($block | tool-result-text) id: $block.tool_use_id? is_error: ($block.is_error? == true)}
    }
}
