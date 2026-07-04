# claude-nu rendering: session record content -> markdown text.
# Standalone — imports nothing from the other claude-nu submodules.

# Reverse the HTML entity escaping Claude Code applies to `!`-command output
# (the `<`/`>`/`&` inside <bash-stdout>/<bash-stderr> arrive as &lt;/&gt;/&amp;).
# &amp; is undone last so a literal "&amp;lt;" decodes to "&lt;", not "<".
export def unescape-html []: string -> string {
    str replace --all '&lt;' '<'
    | str replace --all '&gt;' '>'
    | str replace --all '&quot;' '"'
    | str replace --all '&#39;' "'"
    | str replace --all '&amp;' '&'
}

# Render a `!`-command user record's string content as readable markdown.
# `<bash-input>CMD</bash-input>` -> a `sh` code block; the paired
# `<bash-stdout>OUT</bash-stdout><bash-stderr>ERR</bash-stderr>` record -> the
# captured output as a plain code block (stderr flagged). Non-bash strings pass
# through untouched. Tags are split by literal string (not regex): real output
# has its own `<`/`>` HTML-escaped, so the wrapper tags are the only literal
# ones, and a missing closing tag (test fixtures) still degrades cleanly.
# Why: a `!` command is a real user action, but Claude Code stores it in these
# wrappers; without rendering, export-session/messages drop the user's command.
export def render-bash-wrapper []: string -> string {
    let s = $in
    if ($s | str starts-with "<bash-input>") {
        let cmd = $s
            | str replace "<bash-input>" "" | str replace "</bash-input>" ""
            | unescape-html | str trim
        $"```sh\n($cmd)\n```"
    } else if ($s | str starts-with "<bash-stdout>") {
        let parts = $s | split row "<bash-stderr>"
        let out = $parts.0
            | str replace "<bash-stdout>" "" | str replace "</bash-stdout>" ""
            | unescape-html | str trim
        let err = $parts.1? | default ""
            | str replace "</bash-stderr>" ""
            | unescape-html | str trim
        [
            (if ($out | is-not-empty) { $"```\n($out)\n```" })
            (if ($err | is-not-empty) { $"```\n[stderr]\n($err)\n```" })
        ] | compact | str join "\n\n"
    } else { $s }
}

# Content value as a list of blocks; [] when it isn't one (string/null content).
export def content-blocks []: any -> table {
    if ($in | describe) =~ '^(list|table)' { } else { [] }
}

# Shared dispatch on message content shape: string content passes through
# render-bash-wrapper (a no-op unless it's a `!`-command wrapper), content block
# lists go through $render, anything else yields "".
export def render-message-content [render: closure]: record -> string {
    let content = $in.message?.content?
    match ($content | describe) {
        "string" => { $content | render-bash-wrapper }
        $t if ($t =~ '^(list|table)') => { $content | do $render }
        _ => { "" }
    }
}

# Collapse whitespace (newlines, tabs, runs of spaces) to single spaces
# and truncate to a max length, appending an ellipsis on truncation.
export def to-one-line [max: int]: string -> string {
    str replace --all --regex '\s+' ' '
    | str trim
    | if ($in | str length) > $max {
        $"($in | str substring 0..<$max)..."
    } else { }
}

# One-line summary of a tool_use input record for placeholder rendering.
# Picks the most informative scalar field (command, file_path, query, etc.)
# and falls back to a compact NUON dump.
export def summarize-tool-input [input: any]: nothing -> string {
    if not (($input | describe) | str starts-with "record") { return "" }
    let cols = $input | columns
    let preferred = ["command" "file_path" "path" "pattern" "query" "url" "skill" "subagent_type" "description"]
    let key = $preferred | where {|k| $k in $cols } | get 0?
    if $key != null {
        let v = $input | get $key
        if ($v | describe) == "string" { $v } else { $v | to nuon }
    } else {
        $input | to nuon
    }
}

# Render a single content block as one line of markdown.
# text -> text as-is; with --thinking, thinking -> `[thinking]`-prefixed text;
# with --tools, tool_use/tool_result -> blockquote placeholder; else "".
export def render-block [--tools --thinking]: record -> string {
    let block = $in
    match $block.type? {
        "text" => ($block.text? | default "")
        "thinking" if $thinking => $"[thinking] ($block.thinking? | default '')"
        "tool_use" if $tools => {
            let summary = summarize-tool-input $block.input? | to-one-line 120
            $"> [($block.name? | default 'tool'): ($summary)]"
        }
        "tool_result" if $tools => {
            let raw = $block.content?
            let txt = if ($raw | describe) == "string" { $raw } else {
                $raw | content-blocks | where type? == "text" | get text --optional | str join " "
            }
            let n = $txt | str length
            let err = if $block.is_error? == true { " error" } else { "" }
            $"> [result($err): ($n) chars]"
        }
        _ => ""
    }
}

# Render a record's content blocks as markdown text, one block per paragraph.
# Flags pass through to render-block: --tools renders tool_use/tool_result as
# one-line blockquote placeholders, --thinking renders thinking blocks.
export def render-content [--tools --thinking]: record -> string {
    render-message-content {
        each { render-block --tools=$tools --thinking=$thinking }
        | where { $in | is-not-empty }
        | str join "\n\n"
    }
}
