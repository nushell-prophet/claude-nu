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

# =============================================================================
# Integration test for parse-session-file
# =============================================================================

@test
def "parse-session-file extracts all fields from session file" [] {
    # Create temp file with realistic session data
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"summary","summary":"Test session about file parsing"}'
        '{"type":"user","message":{"content":"Please check @src/main.rs"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"I will read that file."},{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.rs"}}]},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"Now edit @src/lib.rs please"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Making the edit."},{"type":"tool_use","name":"Edit","input":{"file_path":"/src/lib.rs","old_string":"old","new_string":"new"}}]},"timestamp":"2024-01-15T10:00:03Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"Explore","description":"Find tests"}}]},"timestamp":"2024-01-15T10:00:04Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    # Run parse-session-file
    let result = $temp_file | parse-session-file

    # Cleanup
    rm $temp_file

    # Assertions
    assert equal $result.summary "Test session about file parsing"
    assert equal $result.user_msg_count 2
    assert ($result.user_msg_length > 0)
    assert ($result.response_length > 0)
    assert equal $result.agent_count 1
    assert equal ($result.agents | first | get type) "Explore"
    assert equal ($result.agents | first | get description) "Find tests"
    assert ("src/main.rs" in $result.mentioned_files)
    assert ("src/lib.rs" in $result.mentioned_files)
    assert ("/src/main.rs" in $result.read_files)
    assert ("/src/lib.rs" in $result.edited_files)
}

@test
def "parse-session-file handles empty file" [] {
    let temp_file = $nu.temp-path | path join $"test-empty-(random uuid).jsonl"

    "" | save --force $temp_file

    let result = $temp_file | parse-session-file

    rm $temp_file

    assert equal $result.summary ""
    assert equal $result.user_msg_count 0
    assert equal $result.first_timestamp null
    assert equal $result.last_timestamp null
    assert equal ($result.agents | length) 0
    assert equal ($result.mentioned_files | length) 0
}

# =============================================================================
# Tests for --session flag path detection
# =============================================================================

@test
def "session flag detects jsonl extension as path" [] {
    let input = "/Users/user/.claude/projects/-test/abc123.jsonl"
    let is_path = $input | str ends-with '.jsonl'

    assert equal $is_path true
}

@test
def "session flag detects uuid without extension" [] {
    let input = "b8890913-730d-4621-b108-9c565d5cea3a"
    let is_path = $input | str ends-with '.jsonl'

    assert equal $is_path false
}

@test
def "session flag works with windows-style paths" [] {
    let input = 'C:\Users\user\.claude\projects\-test\abc123.jsonl'
    let is_path = $input | str ends-with '.jsonl'

    assert equal $is_path true
}

@test
def "messages command accepts full path via --session" [] {
    # Create temp session file
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello from path test"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":"Hi there"},"timestamp":"2024-01-15T10:00:01Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    # Call messages with full path
    let result = messages --session $temp_file

    rm $temp_file

    assert equal ($result | length) 1
    assert equal ($result | first | get message) "Hello from path test"
}

# =============================================================================
# Tests for parse-session command - Session metadata extraction
# =============================================================================

@test
def "parse-session extracts session_id from first record" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","sessionId":"abc-123-def","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --session-id

    rm $temp_file

    assert equal $result.session_id "abc-123-def"
}

@test
def "parse-session extracts slug from first record" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","slug":"happy-coding-session","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --slug

    rm $temp_file

    assert equal $result.slug "happy-coding-session"
}

@test
def "parse-session extracts version from first record" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","version":"2.1.11","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --version

    rm $temp_file

    assert equal $result.version "2.1.11"
}

@test
def "parse-session extracts cwd from first record" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","cwd":"/Users/test/project","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --cwd

    rm $temp_file

    assert equal $result.cwd "/Users/test/project"
}

@test
def "parse-session extracts git_branch from first record" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","gitBranch":"feature/new-feature","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --git-branch

    rm $temp_file

    assert equal $result.git_branch "feature/new-feature"
}

@test
def "parse-session handles missing metadata with empty defaults" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --session-id --slug --version --cwd --git-branch

    rm $temp_file

    assert equal $result.session_id ""
    assert equal $result.slug ""
    assert equal $result.version ""
    assert equal $result.cwd ""
    assert equal $result.git_branch ""
}

# =============================================================================
# Tests for parse-session command - Thinking level extraction
# =============================================================================

@test
def "parse-session extracts thinking_level from user records" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","thinkingMetadata":{"level":"high","disabled":false},"message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --thinking-level

    rm $temp_file

    assert equal $result.thinking_level "high"
}

@test
def "parse-session handles missing thinking metadata" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --thinking-level

    rm $temp_file

    assert equal $result.thinking_level ""
}

# =============================================================================
# Tests for parse-session command - Tool statistics
# =============================================================================

@test
def "parse-session extracts bash_commands list" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Run tests"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm build"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --bash-commands

    rm $temp_file

    assert equal ($result.bash_commands | length) 2
    assert ("npm test" in $result.bash_commands)
    assert ("npm build" in $result.bash_commands)
}

@test
def "parse-session counts bash commands correctly" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Run tests"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cmd1"}},{"type":"tool_use","name":"Bash","input":{"command":"cmd2"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cmd3"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --bash-count

    rm $temp_file

    assert equal $result.bash_count 3
}

@test
def "parse-session extracts skill_invocations list" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Use skill"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"nushell-style"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"jj-commit"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --skill-invocations

    rm $temp_file

    assert equal ($result.skill_invocations | length) 2
    assert ("nushell-style" in $result.skill_invocations)
    assert ("jj-commit" in $result.skill_invocations)
}

@test
def "parse-session counts tool_errors from tool_result" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"123","is_error":false,"content":"success"}]}}'
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"456","is_error":true,"content":"error"}]}}'
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"789","is_error":true,"content":"another error"}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --tool-errors

    rm $temp_file

    assert equal $result.tool_errors 2
}

@test
def "parse-session counts ask_user_count" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Help me"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[]}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[]}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/test"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --ask-user-count

    rm $temp_file

    assert equal $result.ask_user_count 2
}

@test
def "parse-session detects plan_mode_used true" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Plan this"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"EnterPlanMode","input":{}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --plan-mode-used

    rm $temp_file

    assert equal $result.plan_mode_used true
}

@test
def "parse-session detects plan_mode_used false" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Just do it"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --plan-mode-used

    rm $temp_file

    assert equal $result.plan_mode_used false
}

# =============================================================================
# Tests for parse-session command - Derived metrics
# =============================================================================

@test
def "parse-session counts turn_count excluding meta messages" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","isMeta":true,"message":{"content":"System info"}}'
        '{"type":"user","message":{"content":"Real message 1"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"Real message 2"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","isMeta":true,"message":{"content":"More system info"}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --turn-count

    rm $temp_file

    assert equal $result.turn_count 2
}

@test
def "parse-session counts assistant_msg_count" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Q1"}}'
        '{"type":"assistant","message":{"content":"A1"}}'
        '{"type":"user","message":{"content":"Q2"}}'
        '{"type":"assistant","message":{"content":"A2"}}'
        '{"type":"assistant","message":{"content":"A3"}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --assistant-msg-count

    rm $temp_file

    assert equal $result.assistant_msg_count 3
}

@test
def "parse-session counts tool_call_count" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Do stuff"}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}},{"type":"tool_use","name":"Edit","input":{}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --tool-call-count

    rm $temp_file

    assert equal $result.tool_call_count 3
}

@test
def "parse-session handles empty session for derived metrics" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    # Single record to avoid empty file edge case
    let lines = [
        '{"type":"summary","summary":"Empty session"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --turn-count --assistant-msg-count --tool-call-count

    rm $temp_file

    assert equal $result.turn_count 0
    assert equal $result.assistant_msg_count 0
    assert equal $result.tool_call_count 0
}

# =============================================================================
# Tests for parse-session command - --all flag
# =============================================================================

@test
def "parse-session --all includes all columns" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","sessionId":"test-id","slug":"test-slug","version":"1.0","cwd":"/test","gitBranch":"main","thinkingMetadata":{"level":"high"},"message":{"content":"@file.txt"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file --all
    let cols = $result | columns

    rm $temp_file

    # Check all expected columns exist
    assert ("path" in $cols)
    assert ("user_messages" in $cols)
    assert ("mentioned_files" in $cols)
    assert ("edited_files" in $cols)
    assert ("read_files" in $cols)
    assert ("summary" in $cols)
    assert ("agents" in $cols)
    assert ("first_timestamp" in $cols)
    assert ("last_timestamp" in $cols)
    assert ("session_id" in $cols)
    assert ("slug" in $cols)
    assert ("version" in $cols)
    assert ("cwd" in $cols)
    assert ("git_branch" in $cols)
    assert ("thinking_level" in $cols)
    assert ("bash_commands" in $cols)
    assert ("bash_count" in $cols)
    assert ("skill_invocations" in $cols)
    assert ("tool_errors" in $cols)
    assert ("ask_user_count" in $cols)
    assert ("plan_mode_used" in $cols)
    assert ("turn_count" in $cols)
    assert ("assistant_msg_count" in $cols)
    assert ("tool_call_count" in $cols)
}

@test
def "parse-session default columns are minimal" [] {
    let temp_file = $nu.temp-path | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = parse-session $temp_file
    let cols = $result | columns

    rm $temp_file

    # Default should only have 3 columns
    assert equal ($cols | length) 3
    assert ("path" in $cols)
    assert ("user_messages" in $cols)
    assert ("mentioned_files" in $cols)
}

# =============================================================================
# extract-tool-results tests
# =============================================================================

@test
def "extract-tool-results extracts tool_result from user records" [] {
    let records = [
        {message: {content: [{type: "tool_result" tool_use_id: "123" content: "success"}]}}
        {message: {content: [{type: "tool_result" tool_use_id: "456" content: "done"}]}}
    ]

    let result = $records | extract-tool-results

    assert equal ($result | length) 2
    assert equal ($result.0.tool_use_id) "123"
    assert equal ($result.1.tool_use_id) "456"
}

@test
def "extract-tool-results returns empty for string content" [] {
    let records = [
        {message: {content: "just a string"}}
    ]

    let result = $records | extract-tool-results

    assert equal ($result | length) 0
}

@test
def "extract-tool-results flattens results from multiple records" [] {
    let records = [
        {message: {content: [{type: "tool_result" tool_use_id: "1" content: "a"} {type: "tool_result" tool_use_id: "2" content: "b"}]}}
        {message: {content: [{type: "tool_result" tool_use_id: "3" content: "c"}]}}
    ]

    let result = $records | extract-tool-results

    assert equal ($result | length) 3
}

@test
def "extract-tool-results filters non-tool_result items" [] {
    let records = [
        {message: {content: [{type: "tool_result" tool_use_id: "1" content: "result"} {type: "text" text: "some text"}]}}
    ]

    let result = $records | extract-tool-results

    assert equal ($result | length) 1
    assert equal ($result.0.type) "tool_result"
}

# =============================================================================
# sessions tests
# =============================================================================

@test
def "sessions parses single file" [] {
    let temp_dir = $nu.temp-path | path join $"test-sessions-(random uuid)"
    mkdir $temp_dir
    let temp_file = $temp_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl"

    let lines = [
        '{"type":"summary","summary":"Test session"}'
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file

    rm -rf $temp_dir

    assert equal ($result | length) 1
    assert equal ($result.0.summary) "Test session"
}

@test
def "sessions parses directory of files" [] {
    let temp_dir = $nu.temp-path | path join $"test-sessions-(random uuid)"
    mkdir $temp_dir

    let file1 = $temp_dir | path join "11111111-1111-1111-1111-111111111111.jsonl"
    let file2 = $temp_dir | path join "22222222-2222-2222-2222-222222222222.jsonl"

    '{"type":"summary","summary":"Session 1"}' | save --force $file1
    '{"type":"summary","summary":"Session 2"}' | save --force $file2

    let result = sessions $temp_dir

    rm -rf $temp_dir

    assert equal ($result | length) 2
}

@test
def "sessions ignores non-uuid files in directory" [] {
    let temp_dir = $nu.temp-path | path join $"test-sessions-(random uuid)"
    mkdir $temp_dir

    let valid_file = $temp_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl"
    let invalid_file = $temp_dir | path join "not-a-uuid.jsonl"

    '{"type":"summary","summary":"Valid"}' | save --force $valid_file
    '{"type":"summary","summary":"Invalid"}' | save --force $invalid_file

    let result = sessions $temp_dir

    rm -rf $temp_dir

    assert equal ($result | length) 1
    assert equal ($result.0.summary) "Valid"
}

@test
def "sessions errors on non-existent path" [] {
    let result = try {
        sessions "/nonexistent/path"
        false
    } catch {
        true
    }

    assert $result
}

# =============================================================================
# nu-complete claude sessions tests
# =============================================================================

@test
def "nu-complete returns empty for non-existent sessions dir" [] {
    # Use a path that definitely doesn't exist
    let result = do {
        cd /tmp
        nu-complete claude sessions
    }

    assert equal $result.completions []
    assert equal $result.options.sort false
}
