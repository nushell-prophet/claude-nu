use std/assert
use std/testing *

# `main` of timeline.nu imports under the file stem — this is `timeline`.
use ../claude-nu/timeline.nu
use ../claude-nu/sessions.nu [tool-calls]

const FIXTURE_FHS_TASKFAMILY = 'ae3bbbf7-0554-45f7-9653-6ca09689be50.jsonl' # has Bash, Read, TaskCreate/TaskUpdate/TaskStop
const FIXTURES_SESSIONS_DIR = path self fixtures/sessions
const CLAUDE_NU_MODULE = path self ../claude-nu

# A temp session file holding the given JSONL lines; the caller removes it.
def session-file [lines: list<string>]: nothing -> path {
    let file = $nu.temp-dir | path join $"test-timeline-(random uuid).jsonl"
    $lines | str join "\n" | save --force $file
    $file
}

const TURN = [
    '{"type":"user","uuid":"u-1","cwd":"/tmp/proj","message":{"content":"list the files"},"timestamp":"2024-01-15T10:00:00Z"}'
    '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"thinking","thinking":"ls will do"},{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"timestamp":"2024-01-15T10:00:01Z"}'
    '{"type":"user","uuid":"u-2","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt"}]},"timestamp":"2024-01-15T10:00:02Z"}'
    '{"type":"assistant","uuid":"a-2","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/nope"}}]},"timestamp":"2024-01-15T10:00:03Z"}'
    '{"type":"user","uuid":"u-3","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"File does not exist."}]}]},"timestamp":"2024-01-15T10:00:04Z"}'
    '{"type":"assistant","uuid":"a-3","message":{"content":[{"type":"text","text":"Only a.txt."}]},"timestamp":"2024-01-15T10:00:05Z"}'
]

@test
def "timeline yields one row per block in file order" [] {
    let file = session-file $TURN
    let rows = {path: $file} | timeline
    rm $file

    assert equal ($rows | select role kind text tool id is_error) [
        {role: user kind: text text: "list the files" tool: null id: null is_error: null}
        {role: assistant kind: thinking text: "ls will do" tool: null id: null is_error: null}
        {role: assistant kind: text text: "Let me look." tool: null id: null is_error: null}
        {role: assistant kind: tool_use text: '{"command":"ls"}' tool: Bash id: toolu_1 is_error: null}
        {role: user kind: tool_result text: "a.txt" tool: Bash id: toolu_1 is_error: false}
        {role: assistant kind: tool_use text: '{"file_path":"/nope"}' tool: Read id: toolu_2 is_error: null}
        {role: user kind: tool_result text: "File does not exist." tool: Read id: toolu_2 is_error: true}
        {role: assistant kind: text text: "Only a.txt." tool: null id: null is_error: null}
    ]
    assert equal ($rows | columns) [role kind text tool id is_error timestamp uuid session project project_name]
    assert equal ($rows.0.timestamp | describe) "datetime"
    assert equal ($rows | get project_name | uniq) ["tmp/proj"]
}

@test
def "timeline drops system wrappers and meta turns unless asked" [] {
    let file = session-file [
        '{"type":"user","uuid":"u-1","message":{"content":"real prompt"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","uuid":"u-2","message":{"content":"<command-name>/clear"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","uuid":"u-3","isMeta":true,"message":{"content":"skill body"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"timestamp":"2024-01-15T10:00:03Z"}'
        '{"type":"user","uuid":"u-4","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt"},{"type":"text","text":"<system-reminder>injected"}]},"timestamp":"2024-01-15T10:00:04Z"}'
    ]
    let plain = {path: $file} | timeline | get text
    let all = {path: $file} | timeline --include-system | get text
    rm $file

    # Why the tool_result survives on the wrapped record: the check is per block,
    # so a reminder riding on a result drops alone.
    assert equal $plain ["real prompt" '{"command":"ls"}' "a.txt"]
    assert equal $all ["real prompt" "<command-name>/clear" "skill body" '{"command":"ls"}' "a.txt" "<system-reminder>injected"]
}

@test
def "timeline drops redacted thinking and other block kinds" [] {
    let file = session-file [
        '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"server_tool_use","id":"srv_1","name":"advisor","input":{}},{"type":"text","text":"done"}]},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    let rows = {path: $file} | timeline
    rm $file

    assert equal ($rows | select kind text) [{kind: text text: done}]
}

@test
def "timeline regex matches text and tool name, with and without rg" [] {
    let file = session-file $TURN
    # Why every pattern runs twice: the rg pre-filter reads the raw JSON line,
    # the in-engine regex reads the rows — the two must agree.
    # Why the input pattern is JSON: that is how `text` renders a tool_use and
    # how the raw line holds it.
    let found = ['does not exist' 'Read' '"file_path":"/nope"']
        | each {|p| {
            rg: ({path: $file} | timeline $p | select kind id)
            no_rg: ({path: $file} | timeline $p --no-rg | select kind id)
        } }
    rm $file

    for f in $found { assert equal $f.rg $f.no_rg }
    assert equal $found.0.rg [{kind: tool_result id: toolu_2}]
    assert equal $found.1.rg [{kind: tool_use id: toolu_2} {kind: tool_result id: toolu_2}]
    assert equal $found.2.rg [{kind: tool_use id: toolu_2}]
}

@test
def "tool-calls regex over the input means the same with and without rg" [] {
    let file = session-file $TURN
    let rg = {path: $file} | tool-calls '"command":"ls"' | get id
    let no_rg = {path: $file} | tool-calls '"command":"ls"' --no-rg | get id
    rm $file

    assert equal $rg [toolu_1]
    assert equal $no_rg [toolu_1]
}

@test
def "timeline --since and --until cut the window per block" [] {
    let file = session-file $TURN
    let rows = {path: $file} | timeline --since 2024-01-15T10:00:02Z --until 2024-01-15T10:00:04Z
    rm $file

    # Why the result at 10:00:02 keeps its tool: the join runs over the whole
    # file, and the call it answers sits outside the window.
    assert equal ($rows | select kind tool) [
        {kind: tool_result tool: Bash}
        {kind: tool_use tool: Read}
        {kind: tool_result tool: Read}
    ]
}

@test
def "timeline on a session with no tool calls keeps its schema" [] {
    let file = session-file ['{"type":"user","uuid":"u-1","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}']
    let rows = {path: $file} | timeline
    rm $file

    assert equal ($rows | select kind text tool) [{kind: text text: hi tool: null}]
}

@test
def "a block copied into a resumed session comes back once, and its siblings stay" [] {
    # Why: a resumed session repeats its parent's records under the same uuid,
    # and one user record carries every result of a turn — deduping on the
    # record uuid alone would keep only one of them.
    let dir = $nu.temp-dir | path join $"test-timeline-resume-(random uuid)"
    mkdir $dir
    let calls = '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"pwd"}}]},"timestamp":"2024-01-15T10:00:00Z"}'
    let results = '{"type":"user","uuid":"u-1","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt"},{"type":"tool_result","tool_use_id":"toolu_2","content":"/tmp"}]},"timestamp":"2024-01-15T10:00:01Z"}'
    let older = $dir | path join 11111111-1111-1111-1111-111111111111.jsonl
    let newer = $dir | path join 22222222-2222-2222-2222-222222222222.jsonl
    [$calls $results] | str join "\n" | save $older
    [$calls $results '{"type":"user","uuid":"u-2","message":{"content":"after resuming"},"timestamp":"2024-01-16T10:00:00Z"}'] | str join "\n" | save $newer

    let rows = [{path: $newer} {path: $older}] | timeline
    rm --recursive $dir

    assert equal ($rows | select text session) [
        {text: "after resuming" session: "22222222-2222-2222-2222-222222222222"}
        {text: '{"command":"ls"}' session: "11111111-1111-1111-1111-111111111111"}
        {text: '{"command":"pwd"}' session: "11111111-1111-1111-1111-111111111111"}
        {text: "a.txt" session: "11111111-1111-1111-1111-111111111111"}
        {text: "/tmp" session: "11111111-1111-1111-1111-111111111111"}
    ]
}

@test
def "timeline agrees with tool-calls on a real fixture" [] {
    let file = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_TASKFAMILY
    let rows = {path: $file} | timeline
    let calls = {path: $file} | tool-calls

    assert ($calls | is-not-empty) "the fixture holds tool calls"
    assert equal ($rows | where kind == tool_use | get id) ($calls | get id)
    assert equal ($rows | where kind == tool_result and tool == null) []
}

@test
def "the example of what the agent said before a call keeps only the words of the agent" [] {
    # Why: a prompt answered with a tool call and no words is a user text row
    # right before a tool_use too, and it read as the agent speaking.
    let file = session-file [
        '{"type":"user","uuid":"u-1","message":{"content":"list the files"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","uuid":"u-2","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt"}]},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"assistant","uuid":"a-2","message":{"content":[{"type":"text","text":"Now read it."},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"a.txt"}}]},"timestamp":"2024-01-15T10:00:03Z"}'
    ]
    let example = scope commands
        | where name == timeline
        | get 0.examples
        | where description == "what the agent said right before each tool call"
        | get 0.example
    # Why a fresh `nu`: the example is source text, and it names the module
    # as users load it.
    let pipeline = $example | str replace 'claude-nu sessions --last' $"[($file | to nuon)]"
    let said = ^$nu.current-exe --commands $"use ($CLAUDE_NU_MODULE); ($pipeline) | to nuon" | from nuon
    rm $file

    assert equal $said [{said: "Now read it." tool: Read}]
}
