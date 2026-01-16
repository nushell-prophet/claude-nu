use std assert
use std/testing *

# Import all functions from commands.nu (including internals not re-exported via mod.nu)
use ../claude-nu/commands.nu *

# =============================================================================
# Tests for get-sessions-dir path transformation logic
# =============================================================================

@test
def "path transformation replaces slashes with dashes" [] {
    # Test the core transformation logic used by get-sessions-dir
    let path = "/Users/test/project"
    let result = $path | str replace --all '/' '-'

    assert equal $result "-Users-test-project"
}

@test
def "path transformation handles root path" [] {
    let path = "/"
    let result = $path | str replace --all '/' '-'

    assert equal $result "-"
}

@test
def "path transformation handles nested path" [] {
    let path = "/home/user/code/my-project/src"
    let result = $path | str replace --all '/' '-'

    assert equal $result "-home-user-code-my-project-src"
}

@test
def "get-sessions-dir returns valid path for current directory" [] {
    # Test that get-sessions-dir returns a path under ~/.claude/projects
    let result = get-sessions-dir

    assert ($result | str starts-with ($env.HOME | path join ".claude" "projects"))
}

# =============================================================================
# Tests for system message filtering logic
# =============================================================================

@test
def "system prefixes filter command-name messages" [] {
    let system_prefixes = [
        "<command-name>"
        "<command-message>"
        "<local-command-stdout>"
        "<bash-input>"
        "<bash-stdout>"
        "Caveat:"
    ]

    let content = "<command-name>some command"
    let passes = $system_prefixes | all { $content !~ $'^($in)' }

    assert equal $passes false
}

@test
def "system prefixes filter bash-stdout messages" [] {
    let system_prefixes = [
        "<command-name>"
        "<command-message>"
        "<local-command-stdout>"
        "<bash-input>"
        "<bash-stdout>"
        "Caveat:"
    ]

    let content = "<bash-stdout>output here"
    let passes = $system_prefixes | all { $content !~ $'^($in)' }

    assert equal $passes false
}

@test
def "system prefixes filter caveat messages" [] {
    let system_prefixes = [
        "<command-name>"
        "<command-message>"
        "<local-command-stdout>"
        "<bash-input>"
        "<bash-stdout>"
        "Caveat:"
    ]

    let content = "Caveat: This is a warning"
    let passes = $system_prefixes | all { $content !~ $'^($in)' }

    assert equal $passes false
}

@test
def "system prefixes allow regular user messages" [] {
    let system_prefixes = [
        "<command-name>"
        "<command-message>"
        "<local-command-stdout>"
        "<bash-input>"
        "<bash-stdout>"
        "Caveat:"
    ]

    let content = "Hello Claude, please help me"
    let passes = $system_prefixes | all { $content !~ $'^($in)' }

    assert equal $passes true
}

@test
def "system prefixes filter multiple message types correctly" [] {
    let system_prefixes = [
        "<command-name>"
        "<command-message>"
        "<local-command-stdout>"
        "<bash-input>"
        "<bash-stdout>"
        "Caveat:"
    ]

    let test_messages = [
        "Hello Claude"                    # Should pass
        "<command-name>some command"      # Should be filtered
        "<bash-stdout>output"             # Should be filtered
        "Caveat: This is a warning"       # Should be filtered
        "Regular message"                 # Should pass
    ]

    let filtered = $test_messages | where {|content|
        $system_prefixes | all { $content !~ $'^($in)' }
    }

    assert equal ($filtered | length) 2
    assert equal ($filtered | first) "Hello Claude"
    assert equal ($filtered | last) "Regular message"
}

# =============================================================================
# Tests for regex filtering logic
# =============================================================================

@test
def "regex filtering matches content" [] {
    let messages = [
        {content: "fix the bug in login"}
        {content: "add new feature"}
        {content: "bugfix for authentication"}
        {content: "update readme"}
    ]

    let filtered = $messages | where { $in.content =~ "bug" }

    assert equal ($filtered | length) 2
    assert ($filtered.0.content | str contains "bug")
    assert ($filtered.1.content | str contains "bug")
}

@test
def "regex filtering handles case sensitivity" [] {
    let messages = [
        {content: "Fix the BUG"}
        {content: "found a bug"}
        {content: "no issues here"}
    ]

    # Case-insensitive regex
    let filtered = $messages | where { $in.content =~ "(?i)bug" }

    assert equal ($filtered | length) 2
}

# =============================================================================
# Tests for list content handling
# =============================================================================

@test
def "list content joins correctly" [] {
    let list_content = [
        {content: "First part"}
        {content: "Second part"}
    ]

    let joined = $list_content | each { $in.content } | str join "\n"

    assert equal $joined "First part\nSecond part"
}

@test
def "list content type detection works" [] {
    let string_content = "simple string"
    let list_content = [{content: "part1"} {content: "part2"}]

    assert equal ($string_content | describe) "string"
    # In Nushell, lists of records are described as "table<...>" or "list<...>"
    let list_type = $list_content | describe
    assert (($list_type | str starts-with "list") or ($list_type | str starts-with "table"))
}

# =============================================================================
# Tests for session file parsing
# =============================================================================

@test
def "session jsonl parsing extracts user messages" [] {
    # Simulate parsing a JSONL session line
    let line = '{"type": "user", "message": {"content": "Hello"}, "timestamp": "2024-01-15T10:00:00Z"}'
    let parsed = $line | from json

    assert equal $parsed.type "user"
    assert equal $parsed.message.content "Hello"
}

@test
def "session jsonl parsing handles assistant messages" [] {
    let line = '{"type": "assistant", "message": {"content": "Hi there!"}, "timestamp": "2024-01-15T10:00:01Z"}'
    let parsed = $line | from json

    assert equal $parsed.type "assistant"
}

@test
def "session filtering selects only user messages" [] {
    let messages = [
        {type: "user" message: {content: "Hello"}}
        {type: "assistant" message: {content: "Hi"}}
        {type: "user" message: {content: "Thanks"}}
        {type: "summary" summary: "Session summary"}
    ]

    let user_messages = $messages | where type == "user"

    assert equal ($user_messages | length) 2
}

@test
def "isMeta filtering excludes meta messages" [] {
    let messages = [
        {type: "user" message: {content: "Hello"} isMeta: false}
        {type: "user" message: {content: "System info"} isMeta: true}
        {type: "user" message: {content: "Thanks"}}
    ]

    let non_meta = $messages | where isMeta? != true

    assert equal ($non_meta | length) 2
}

# =============================================================================
# Tests for extract-text-content helper
# =============================================================================

@test
def "extract-text-content returns string content directly" [] {
    let record = {message: {content: "Hello world"}}
    let result = $record | extract-text-content

    assert equal $result "Hello world"
}

@test
def "extract-text-content extracts text from content array" [] {
    let record = {message: {content: [
        {type: "text" text: "First part"}
        {type: "thinking" thinking: "internal thought"}
        {type: "text" text: " second part"}
    ]}}
    let result = $record | extract-text-content

    assert equal $result "First part second part"
}

@test
def "extract-text-content returns empty string for missing content" [] {
    let record = {message: {}}
    let result = $record | extract-text-content

    assert equal $result ""
}

@test
def "extract-text-content handles null message" [] {
    let record = {}
    let result = $record | extract-text-content

    assert equal $result ""
}

# =============================================================================
# Tests for extract-tool-calls helper
# =============================================================================

@test
def "extract-tool-calls returns tool_use items" [] {
    let record = {message: {content: [
        {type: "text" text: "Let me read that file"}
        {type: "tool_use" name: "Read" input: {file_path: "/test.txt"}}
        {type: "tool_use" name: "Edit" input: {file_path: "/test.txt" old_string: "a" new_string: "b"}}
    ]}}
    let result = $record | extract-tool-calls

    assert equal ($result | length) 2
    assert equal ($result | first | get name) "Read"
    assert equal ($result | last | get name) "Edit"
}

@test
def "extract-tool-calls returns empty for string content" [] {
    let record = {message: {content: "Just text"}}
    let result = $record | extract-tool-calls

    assert equal ($result | length) 0
}

@test
def "extract-tool-calls returns empty for no tool_use" [] {
    let record = {message: {content: [
        {type: "text" text: "Hello"}
        {type: "thinking" thinking: "Hmm"}
    ]}}
    let result = $record | extract-tool-calls

    assert equal ($result | length) 0
}

# =============================================================================
# Tests for sessions command data extraction
# =============================================================================

@test
def "mentioned files regex extracts @path patterns" [] {
    let texts = [
        "Please look at @src/main.rs"
        "Check @README.md and @docs/guide.md"
        "No files here"
    ]

    let mentioned = $texts
    | each { parse --regex '@([^\s<>]+)' | get capture0? | default [] }
    | flatten
    | uniq

    assert equal ($mentioned | length) 3
    assert ("src/main.rs" in $mentioned)
    assert ("README.md" in $mentioned)
    assert ("docs/guide.md" in $mentioned)
}

@test
def "mentioned files regex stops at angle brackets" [] {
    # @patterns stop at < or > characters
    let text = "See @file.txt and @path/to<file"

    let mentioned = $text
    | parse --regex '@([^\s<>]+)'
    | get capture0?
    | default []

    assert equal ($mentioned | length) 2
    assert equal ($mentioned | first) "file.txt"
    assert equal ($mentioned | last) "path/to"  # stops at <
}

@test
def "agent extraction from Task tool calls" [] {
    let tool_calls = [
        {name: "Task" input: {subagent_type: "Explore" description: "Find files"}}
        {name: "Read" input: {file_path: "/test.txt"}}
        {name: "Task" input: {subagent_type: "commit-git" description: "Commit changes"}}
    ]

    let agents = $tool_calls
    | where name? == "Task"
    | each {{
        type: ($in.input?.subagent_type? | default "unknown")
        description: ($in.input?.description? | default "")
    }}

    assert equal ($agents | length) 2
    assert equal ($agents | first | get type) "Explore"
    assert equal ($agents | last | get type) "commit-git"
}

@test
def "read files extraction from tool calls" [] {
    let tool_calls = [
        {name: "Read" input: {file_path: "/a.txt"}}
        {name: "Edit" input: {file_path: "/b.txt"}}
        {name: "Read" input: {file_path: "/c.txt"}}
        {name: "Read" input: {file_path: "/a.txt"}}  # duplicate
    ]

    let read_files = $tool_calls
    | where name? == "Read"
    | each { $in.input?.file_path? }
    | compact
    | uniq

    assert equal ($read_files | length) 2
    assert ("/a.txt" in $read_files)
    assert ("/c.txt" in $read_files)
}

@test
def "edited files extraction includes Edit and Write" [] {
    let tool_calls = [
        {name: "Read" input: {file_path: "/a.txt"}}
        {name: "Edit" input: {file_path: "/b.txt"}}
        {name: "Write" input: {file_path: "/c.txt"}}
        {name: "Edit" input: {file_path: "/b.txt"}}  # duplicate
    ]

    let edited_files = $tool_calls
    | where { ($in.name? == "Edit") or ($in.name? == "Write") }
    | each { $in.input?.file_path? }
    | compact
    | uniq

    assert equal ($edited_files | length) 2
    assert ("/b.txt" in $edited_files)
    assert ("/c.txt" in $edited_files)
}

@test
def "session uuid regex matches valid patterns" [] {
    let files = [
        "b1dcaaf0-254c-4bd3-b6e6-82d8467dd46d.jsonl"
        "agent-a0b1b97.jsonl"
        "some-other-file.jsonl"
        "02a679ee-8be6-47ef-a226-a2b731af0b60.jsonl"
    ]

    let session_files = $files
    | where { $in =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' }

    assert equal ($session_files | length) 2
}

@test
def "summary extraction handles missing summary record" [] {
    let records = [
        {type: "user" message: {content: "Hello"}}
        {type: "assistant" message: {content: "Hi"}}
    ]

    let summary = $records
    | where type? == "summary"
    | if ($in | is-empty) { "" } else { first | get summary? | default "" }

    assert equal $summary ""
}

@test
def "summary extraction gets summary from record" [] {
    let records = [
        {type: "summary" summary: "Test session summary"}
        {type: "user" message: {content: "Hello"}}
    ]

    let summary = $records
    | where type? == "summary"
    | if ($in | is-empty) { "" } else { first | get summary? | default "" }

    assert equal $summary "Test session summary"
}

@test
def "timestamp extraction handles empty user records" [] {
    let user_records = []

    let timestamps = $user_records
    | each { $in.timestamp? }
    | compact

    let first_ts = $timestamps | if ($in | is-empty) { null } else { first }

    assert equal $first_ts null
}

@test
def "response length sums text content" [] {
    let response_texts = ["Hello" "World!" "Test"]

    let length = $response_texts
    | each { str length }
    | if ($in | is-empty) { 0 } else { math sum }

    assert equal $length 15  # 5 + 6 + 4
}
