use std/assert
use std/testing *

# Import all functions from sessions.nu (including internals not re-exported via mod.nu)
use ../claude-nu/sessions.nu *

# Tests for `tool-calls --tool`: the exact tool-name filter and its rg pre-filter.

# One session file with a Bash, a Read and an MCP call, each answered.
def write-mixed-session []: nothing -> path {
    let file = $nu.temp-dir | path join $"test-tool-flag-(random uuid).jsonl"
    [
        '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls sessions.nu"}}]},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","uuid":"u-1","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"sessions.nu"}]},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"assistant","uuid":"a-2","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/repo/sessions.nu"}}]},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"user","uuid":"u-2","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"export def tool-calls"}]},"timestamp":"2024-01-15T10:00:03Z"}'
        '{"type":"assistant","uuid":"a-3","message":{"content":[{"type":"tool_use","id":"toolu_3","name":"mcp__nushell__evaluate","input":{"input":"claude-nu sessions"}}]},"timestamp":"2024-01-15T10:00:04Z"}'
    ] | str join "\n" | save --force $file
    $file
}

@test
def "tool-calls --tool keeps only calls to that tool" [] {
    let file = write-mixed-session
    let result = {path: $file} | tool-calls --tool Bash
    rm $file

    assert equal ($result | get id) ["toolu_1"]
}

@test
def "tool-calls --tool takes a list of names" [] {
    let file = write-mixed-session
    let result = {path: $file} | tool-calls --tool [Read mcp__nushell__evaluate]
    rm $file

    assert equal ($result | get id) ["toolu_2" "toolu_3"]
}

@test
def "tool-calls --tool matches the name exactly, not as a regex" [] {
    # Why: `mcp__nushell` is a prefix of the MCP tool and `B.sh` a regex for
    # Bash; an exact filter must take neither.
    let file = write-mixed-session
    let prefix = {path: $file} | tool-calls --tool mcp__nushell
    let dotted = {path: $file} | tool-calls --tool 'B.sh' --no-rg
    rm $file

    assert equal $prefix []
    assert equal $dotted []
}

@test
def "tool-calls --tool composes with the regex" [] {
    let file = write-mixed-session
    let result = {path: $file} | tool-calls --tool [Bash Read] 'sessions\.nu'
    rm $file

    assert equal ($result | get id) ["toolu_1" "toolu_2"]
}

@test
def "tool-calls --tool composes with --results" [] {
    let file = write-mixed-session
    let result = {path: $file} | tool-calls --tool Read --results 'export def'
    rm $file

    assert equal ($result | select id result) [{id: "toolu_2" result: "export def tool-calls"}]
}

@test
def "tool-calls --tool pre-filters files by the raw name string" [] {
    # Why: the pre-filter reads `"name":"<tool>"` as Claude Code writes it,
    # compact. A line spelled with a space passes the in-engine filter but not
    # rg — so the file dropped here proves rg ran, and --no-rg brings it back.
    let dir = $nu.temp-dir | path join $"test-tool-flag-(random uuid)"
    mkdir $dir
    '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"tool_use","id":"toolu_1","name": "Bash","input":{"command":"ls"}}]},"timestamp":"2024-01-15T10:00:00Z"}'
    | save ($dir | path join 11111111-1111-1111-1111-111111111111.jsonl)

    let filtered = {path: $dir} | tool-calls --tool Bash
    let unfiltered = {path: $dir} | tool-calls --tool Bash --no-rg
    rm --recursive $dir

    assert equal $filtered []
    assert equal ($unfiltered | get id) ["toolu_1"]
}

@test
def "tool-calls --tool with an empty list is an error" [] {
    let file = write-mixed-session
    let result = try { {path: $file} | tool-calls --tool []; "no error" } catch {|e| $e.msg }
    rm $file

    assert str contains $result "non-empty list"
}

@test
def "tool-name-pattern escapes regex characters in a name" [] {
    assert equal (tool-name-pattern [Bash "a.b(c)"]) '"name":"(?:Bash|a\.b\(c\))"'
}
