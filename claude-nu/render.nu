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

# Render a tool_use block with its whole input, as a fenced NUON block under a
# blockquote header naming the tool.
# Not the one-line summary this replaced: that one collapsed the input to a
# single field cut at 120 chars, so an Edit showed file_path and dropped
# old_string/new_string, and a Write dropped content — with nothing in the
# output marking the loss, unlike the cut, which at least ended in an ellipsis.
# Why NUON: lossless, reads back with `from nuon`, and needs no per-tool case.
# Cost accepted: a Bash command arrives with its quotes escaped, where a fenced
# sh block would read better — one special case per tool is the higher price.
export def render-tool-input []: record -> string {
    let block = $in
    let header = $"> [($block.name? | default 'tool')]"
    $"($header)\n\n```nuon\n($block.input? | to nuon --pretty)\n```"
}

# Render a single content block as markdown.
# text -> text as-is; with --thinking, thinking -> `[thinking]`-prefixed text;
# with --tools, tool_use -> its whole input, tool_result -> a char count; else "".
# Why the result stays a count while the input is rendered whole: a single `cat`
# in a working session runs to thousands of characters, so folding results in
# would bury the dialogue the export exists for.
export def render-block [--tools --thinking]: record -> string {
    let block = $in
    match $block.type? {
        "text" => ($block.text? | default "")
        "thinking" if $thinking => $"[thinking] ($block.thinking? | default '')"
        "tool_use" if $tools => ($block | render-tool-input)
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
# Flags pass through to render-block: --tools renders tool_use inputs in full
# and tool_result as a char count, --thinking renders thinking blocks.
export def render-content [--tools --thinking]: record -> string {
    render-message-content {
        each { render-block --tools=$tools --thinking=$thinking }
        | where { $in | is-not-empty }
        | str join "\n\n"
    }
}

# Strip trailing spaces and tabs from every line of a markdown document.
# Why: transcripts carry them — the user dictates by voice, so a message often
# ends in a space, and 26 of the 60 newest sessions exported with such lines.
# They are invisible in the editor but real in a git diff, so a canvas or an
# exported doc kept picking up whitespace-only changes.
# Not per-turn, and not `str trim` on the text: a document-wide pass is the one
# point that also covers the frontmatter and the headings, and trimming a turn
# would eat the blank lines that separate its paragraphs.
export def trim-line-ends []: string -> string {
    str replace --all --regex '(?m)[ \t]+$' ''
}
