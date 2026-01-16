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
