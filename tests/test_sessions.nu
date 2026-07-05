use std/assert
use std/testing *

# Import all functions from sessions.nu (including internals not re-exported via mod.nu)
use ../claude-nu/sessions.nu *
# Import the module entry point too, so its `main` is callable as `claude-nu` (the
# `-f` search command lives there, not in sessions.nu — see mod.nu).
use ../claude-nu

# Vendored real-session fixtures covering Claude Code 2.1.x record shapes
# Each fixture's first record type and special properties are documented inline.
const FIXTURE_PERMMODE_AGENT = '99bf0e5b-212c-4891-abb2-6bc585af2ea0.jsonl' # first: permission-mode, has Agent, mode "plan"
const FIXTURE_FHS_TASKFAMILY = 'ae3bbbf7-0554-45f7-9653-6ca09689be50.jsonl' # first: file-history-snapshot, has TaskCreate/TaskUpdate/TaskStop
const FIXTURE_PERMMODE_AGENT2 = 'b370af1e-c96f-46a2-a3fe-66b16f38bc03.jsonl' # first: permission-mode, has Agent
const FIXTURE_FHS_AGENT = 'b9ce8986-5d19-4ff5-9285-e0ed06464b6c.jsonl' # first: file-history-snapshot, has Agent + TaskCreate/Update
const FIXTURE_USER_FIRST = 'ef27ae6d-c8d1-4ce8-b0ff-bcfff3954193.jsonl' # 2.1.129 format, first: user

const FIXTURES_SESSIONS_DIR = path self fixtures/sessions

# =============================================================================
# Tests for get-sessions-dir
# =============================================================================

@test
def "get-sessions-dir returns valid path for current directory" [] {
    # Test that get-sessions-dir returns a path under ~/.claude/projects
    let result = get-sessions-dir

    assert ($result | str starts-with ($env.HOME | path join ".claude" "projects"))
}

# =============================================================================
# Tests for system message filtering (via the real `messages` command)
# =============================================================================

@test
def "messages drops every system/command wrapper prefix" [] {
    # Why: the old shadow test kept its own copy of the prefix list, which had
    # already drifted from SYSTEM_PREFIXES. Drive one message per real prefix
    # through `messages` so renaming/removing any one is caught here. (The list
    # mirrors SYSTEM_PREFIXES; feeding a prefix that the source no longer filters
    # makes it survive and fails this test.)
    let temp_file = $nu.temp-dir | path join $"test-sysprefix-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"real human message"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<command-name>foo"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<command-message>bar"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<local-command-caveat>baz"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<local-command-stdout>out"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<local-command-stderr>err"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"Caveat: heads up"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = messages --session $temp_file | get message

    rm $temp_file

    assert equal $result ["real human message"]
}

@test
def "messages --include-system keeps the wrapper messages" [] {
    let temp_file = $nu.temp-dir | path join $"test-sysprefix-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"real human message"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<command-name>foo</command-name>"},"timestamp":"2024-01-15T10:00:01Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = messages --session $temp_file --include-system | get message

    rm $temp_file

    assert ("real human message" in $result)
    assert ("<command-name>foo</command-name>" in $result)
}

@test
def "messages renders ! bash commands as user turns" [] {
    # Why: a `!` command is a real user action; its <bash-input>/<bash-stdout>
    # wrappers must surface as readable markdown, not be dropped as system noise.
    let f = $nu.temp-dir | path join $"test-bash-(random uuid).jsonl"
    [
        '{"type":"user","message":{"content":"<bash-input>git diff</bash-input>"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<bash-stdout>+ added &lt;tag&gt;</bash-stdout><bash-stderr>warn: x</bash-stderr>"},"timestamp":"2024-01-15T10:00:01Z"}'
    ] | str join "\n" | save --force $f

    let result = messages --session $f | get message

    rm $f

    assert equal $result.0 "```sh\ngit diff\n```"
    # stdout HTML-unescaped into a plain block; stderr flagged in its own block
    assert ($result.1 | str contains "+ added <tag>")
    assert ($result.1 | str contains "[stderr]\nwarn: x")
}

@test
def "export-session merges a ! command and its output into one user turn" [] {
    let f = $nu.temp-dir | path join $"test-bash-export-(random uuid).jsonl"
    [
        '{"type":"user","message":{"content":"<bash-input>ls</bash-input>"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<bash-stdout>file.txt</bash-stdout><bash-stderr></bash-stderr>"},"timestamp":"2024-01-15T10:00:01Z"}'
    ] | str join "\n" | save --force $f

    let md = export-session --session $f | get markdown

    rm $f

    # Single User heading; command block and output block both under it
    assert equal ($md | parse --regex '## User' | length) 1
    assert ($md | str contains "```sh\nls\n```")
    assert ($md | str contains "file.txt")
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
    let record = {
        message: {
            content: [
                {type: "text" text: "First part"}
                {type: "thinking" thinking: "internal thought"}
                {type: "text" text: " second part"}
            ]
        }
    }
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
    let record = {
        message: {
            content: [
                {type: "text" text: "Let me read that file"}
                {type: "tool_use" name: "Read" input: {file_path: "/test.txt"}}
                {type: "tool_use" name: "Edit" input: {file_path: "/test.txt" old_string: "a" new_string: "b"}}
            ]
        }
    }
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
    let record = {
        message: {
            content: [
                {type: "text" text: "Hello"}
                {type: "thinking" thinking: "Hmm"}
            ]
        }
    }
    let result = $record | extract-tool-calls

    assert equal ($result | length) 0
}

# =============================================================================
# Tests for sessions command data extraction
# =============================================================================

@test
def "sessions mentioned_files extracts @path mentions with prefixes" [] {
    # Why: replaces a shadow test that ran a copy of the regex. Driving the
    # real `sessions` extraction keeps the pattern from drifting untested.
    let temp_file = $nu.temp-dir | path join $"test-mentioned-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"please look at @src/main.rs"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"check @README.md and @docs/guide.md"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"also @/absolute/path.rs and @./relative/file.nu and @~/home/config.toml"},"timestamp":"2024-01-15T10:00:02Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let mentioned = sessions $temp_file --columns mentioned_files | first | get mentioned_files

    rm $temp_file

    assert ("src/main.rs" in $mentioned)
    assert ("README.md" in $mentioned)
    assert ("docs/guide.md" in $mentioned)
    assert ("/absolute/path.rs" in $mentioned)
    assert ("./relative/file.nu" in $mentioned)
    assert ("~/home/config.toml" in $mentioned)
}

@test
def "sessions mentioned_files rejects false positives" [] {
    # Emails, jj revsets, nushell annotations, extension-less @words, and
    # trailing punctuation must not be picked up as file mentions.
    let temp_file = $nu.temp-dir | path join $"test-mentioned-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"mail me at claude@anthropic.com"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"see @- and @-- revsets"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"the @\"nu-complete sessions\" annotation"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"user","message":{"content":"use @example attribute, end with @) or @:"},"timestamp":"2024-01-15T10:00:03Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let mentioned = sessions $temp_file --columns mentioned_files | first | get mentioned_files

    rm $temp_file

    assert equal $mentioned []
}

@test
def "extract-summary takes latest ai-title" [] {
    # ai-title is rewritten as the session evolves; the last one is current
    let records = [
        {type: "ai-title" aiTitle: "Old title"}
        {type: "user" message: {content: "hi"}}
        {type: "ai-title" aiTitle: "Current title"}
    ]

    assert equal ($records | extract-summary) "Current title"
}

# =============================================================================
# Integration tests for sessions overview and column selection
# =============================================================================

@test
def "sessions extracts all overview fields from session file" [] {
    # Create temp file with realistic session data
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"summary","summary":"Test session about file parsing"}'
        '{"type":"user","message":{"content":"Please check @src/main.rs"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"I will read that file."},{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.rs"}}]},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"Now edit @src/lib.rs please"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Making the edit."},{"type":"tool_use","name":"Edit","input":{"file_path":"/src/lib.rs","old_string":"old","new_string":"new"}}]},"timestamp":"2024-01-15T10:00:03Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"Explore","description":"Find tests"}}]},"timestamp":"2024-01-15T10:00:04Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    # Request the asserted columns explicitly: this test pins extraction logic,
    # not the default set, so it must not depend on which columns default in.
    let result = sessions $temp_file --columns summary,user_msg_count,user_msg_length,response_length,agent_count,agents,mentioned_files,read_files,edited_files | first

    rm $temp_file

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
def "sessions user_msg_count and turn_count exclude tool-result user records" [] {
    # Why: Claude Code stores tool results as type:"user" records whose content
    # is tool_result blocks (no text). Counting them inflated both metrics wildly
    # (e.g. 175 records for 3 real messages). Both must count authored text only,
    # staying consistent with user_messages / user_msg_length.
    let temp_file = $nu.temp-dir | path join $"test-toolresult-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Real question"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":[{"type":"tool_result","content":"file contents"}]},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"user","message":{"content":"Follow-up"},"timestamp":"2024-01-15T10:00:03Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns user_msg_count,turn_count,user_messages | first

    rm $temp_file

    assert equal $result.user_msg_count 2
    assert equal $result.turn_count 2
    assert equal $result.user_messages ["Real question" "Follow-up"]
}

@test
def "sessions user message columns exclude command and caveat wrappers" [] {
    # Why: `messages` drops the command/caveat wrappers Claude Code synthesizes
    # (via is-user-text) and meta turns; the user_msg_* columns and turn_count
    # must agree, or `sessions` reports a /clear or a caveat block as a message.
    let temp_file = $nu.temp-dir | path join $"test-wrappers-(random uuid).jsonl"

    let lines = [
        '{"type":"user","isMeta":true,"message":{"content":"<command-name>/clear</command-name>"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<local-command-caveat>Caveat: ran a local command</local-command-caveat>"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"Real question"},"timestamp":"2024-01-15T10:00:02Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns user_msg_count,user_messages,turn_count | first

    rm $temp_file

    assert equal $result.user_msg_count 1
    assert equal $result.turn_count 1
    assert equal $result.user_messages ["Real question"]
}

@test
def "sessions handles empty file" [] {
    let temp_file = $nu.temp-dir | path join $"test-empty-(random uuid).jsonl"

    "" | save --force $temp_file

    let result = sessions $temp_file --columns summary,user_msg_count,first_timestamp,last_timestamp,agents,mentioned_files | first

    rm $temp_file

    assert equal $result.summary ""
    assert equal $result.user_msg_count 0
    assert equal $result.first_timestamp null
    assert equal $result.last_timestamp null
    assert equal ($result.agents | length) 0
    assert equal ($result.mentioned_files | length) 0
}

@test
def "sessions default columns are the overview set" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $temp_file

    let cols = sessions $temp_file | first | columns

    rm $temp_file

    # Golden assertion: a deliberate, hand-maintained copy of the default policy.
    # Not derived from SESSION_COLUMNS on purpose — that would be a tautology and
    # could never catch an accidental `default` flip. Changing the overview set
    # is meant to trip this test so the change stays intentional.
    assert equal $cols [summary last_timestamp user_messages path parent_session_id]
}

@test
def "sessions column flag narrows output to base plus requested" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","slug":"narrow-test","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $temp_file

    let result = sessions $temp_file --columns slug | first

    rm $temp_file

    assert equal ($result | columns) [slug path parent_session_id]
    assert equal $result.slug "narrow-test"
}

@test
def "session-columns completer offers exactly the selectable columns" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","message":{"content":"Hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $temp_file

    # The completer must offer exactly what --all-columns can produce (sans the
    # always-present path/parent_session_id), so the two never drift apart.
    let produced = sessions $temp_file --all-columns | first | columns | where $it not-in [path parent_session_id]
    # Empty token (cursor right after the flag) → the bare column names.
    let offered = nu-complete claude session-columns "sessions --columns "

    rm $temp_file

    assert equal ($offered | sort) ($produced | sort)
}

@test
def "session-columns completer accumulates comma-separated picks" [] {
    # After a pick + comma, the completer returns full comma-joined values and
    # drops the already-chosen column, so the menu keeps working for the next
    # element — the reason --columns is a comma string, not a list<string>.
    let offered = nu-complete claude session-columns "sessions --columns slug,"

    assert ("slug,version" in $offered)
    assert ("slug,cwd" in $offered)
    assert ("slug,slug" not-in $offered)
    assert ($offered | all {|c| $c | str starts-with "slug," })
}

@test
def "sessions --columns fails fast on unknown column name" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","message":{"content":"Hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $temp_file

    let msg = try {
        sessions $temp_file --columns not_a_column
        ""
    } catch {|e| $e.msg }

    rm $temp_file

    assert str contains $msg "Unknown session column"
    assert str contains $msg "not_a_column"
}

@test
def "sessions rejects --columns combined with --all-columns" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","message":{"content":"Hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $temp_file

    let failed = try {
        sessions $temp_file --columns slug --all-columns
        false
    } catch { true }

    rm $temp_file

    assert $failed
}

# =============================================================================
# Tests for --session flag and session-file resolution
# =============================================================================

@test
def "messages command accepts full path via --session" [] {
    # Create temp session file
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

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

@test
def "messages always includes session column" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    '{"type":"user","message":{"content":"Self-describing row"},"timestamp":"2024-01-15T10:00:00Z"}'
    | save --force $temp_file

    let result = messages --session $temp_file

    rm $temp_file

    assert ("session" in ($result | columns))
    assert equal ($result | first | get session) ($temp_file | path basename | str replace '.jsonl' '')
}

@test
def "piping top-level sessions into messages excludes subagents" [] {
    # Why: messages no longer enumerates sessions — the caller scopes via
    # `sessions | where parent_session_id == null`. Subagent transcripts hold
    # agent-driven turns, so dropping them is the caller's choice, not messages'.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let sessions_dir = $fake_home | path join ".claude" "projects" "-work-proj"
    let parent_uuid = "11111111-1111-1111-1111-111111111111"
    mkdir ($sessions_dir | path join $parent_uuid "subagents")

    '{"type":"user","message":{"content":"alpha top message"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join $"($parent_uuid).jsonl")
    '{"type":"user","message":{"content":"beta top message"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "22222222-2222-2222-2222-222222222222.jsonl")
    '{"type":"user","message":{"content":"gamma subagent message"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join $parent_uuid "subagents" "agent-abc123.jsonl")

    let msgs = sessions $sessions_dir | where parent_session_id == null | messages | get message

    rm -rf $fake_home

    assert ("alpha top message" in $msgs)
    assert ("beta top message" in $msgs)
    assert ("gamma subagent message" not-in $msgs)
}

@test
def "sessions --all-projects piped into messages covers every session" [] {
    # Why: replaces the old `messages --all-projects`, which silently read only
    # the newest session per project (todo/20260618-225035). Routing scope
    # through `sessions --all-projects` makes "all" actually mean all, and tags
    # rows with their project when the scope spans more than one.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let projects_dir = $fake_home | path join ".claude" "projects"
    let proj_a = $projects_dir | path join "-proj-a"
    let proj_b = $projects_dir | path join "-proj-b"
    mkdir $proj_a $proj_b

    let a_old = $proj_a | path join "11111111-1111-1111-1111-111111111111.jsonl"
    let a_new = $proj_a | path join "22222222-2222-2222-2222-222222222222.jsonl"
    '{"type":"user","message":{"content":"a-old"},"timestamp":"2024-01-15T10:00:00Z"}' | save --force $a_old
    '{"type":"user","message":{"content":"a-new"},"timestamp":"2024-01-15T10:00:00Z"}' | save --force $a_new
    '{"type":"user","message":{"content":"b-only"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($proj_b | path join "33333333-3333-3333-3333-333333333333.jsonl")

    let result = with-env {HOME: $fake_home} {
        sessions --all-projects | where parent_session_id == null | messages
    }

    rm -rf $fake_home

    let all = $result | get message
    assert ("a-old" in $all)
    assert ("a-new" in $all)
    assert ("b-only" in $all)
    assert ("project" in ($result | columns))
}

@test
def "claude-nu -f searches the current project user messages" [] {
    # A real proj dir + cd so get-sessions-dir resolves to the fixture dir.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let sessions_dir = $fake_home | path join ".claude" "projects" $encoded
    mkdir $sessions_dir

    '{"type":"user","message":{"content":"the needle is here"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"only hay in this one"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "22222222-2222-2222-2222-222222222222.jsonl")

    let result = with-env {HOME: $fake_home} {
        do { cd $proj_dir; claude-nu -f 'needle' }
    }

    rm -rf $fake_home $proj_dir

    # Only the matching message returns, tagged with its session — a selector
    # callers can pipe straight back into export-session/messages.
    assert equal ($result | length) 1
    assert ($result.0.message | str contains "needle")
    assert equal $result.0.session "11111111-1111-1111-1111-111111111111"
}

@test
def "claude-nu -f --all-projects searches every project" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let projects_dir = $fake_home | path join ".claude" "projects"
    let proj_a = $projects_dir | path join "-proj-a"
    let proj_b = $projects_dir | path join "-proj-b"
    mkdir $proj_a $proj_b

    '{"type":"user","message":{"content":"needle in A"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($proj_a | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"needle in B"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($proj_b | path join "22222222-2222-2222-2222-222222222222.jsonl")
    '{"type":"user","message":{"content":"no match here"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($proj_b | path join "33333333-3333-3333-3333-333333333333.jsonl")

    let result = with-env {HOME: $fake_home} {
        claude-nu -f 'needle' --all-projects
    }

    rm -rf $fake_home

    let msgs = $result | get message
    assert equal ($result | length) 2
    assert ("needle in A" in $msgs)
    assert ("needle in B" in $msgs)
    # Scope spans >1 project, so each row is tagged with its project.
    assert ("project" in ($result | columns))
}

@test
def "claude-nu -f skips subagent transcripts" [] {
    # Why: subagents carry no human-typed messages, so `-f` searches only
    # top-level sessions (parent_session_id == null).
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let sessions_dir = $fake_home | path join ".claude" "projects" $encoded
    let sub = $sessions_dir | path join "11111111-1111-1111-1111-111111111111" "subagents"
    mkdir $sub

    '{"type":"user","message":{"content":"needle in top level"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"needle in subagent"},"timestamp":"2024-01-15T10:00:01Z"}'
        | save --force ($sub | path join "agent-abc123.jsonl")

    let result = with-env {HOME: $fake_home} {
        do { cd $proj_dir; claude-nu -f 'needle' }
    }

    rm -rf $fake_home $proj_dir

    assert equal ($result | length) 1
    assert ($result.0.message | str contains "top level")
}

@test
def "claude-nu -f matches a regex, not just a literal" [] {
    # Why: rg pre-filters the files, then `messages` re-applies the regex to the
    # extracted text — both use Rust's regex engine, so an actual pattern
    # (alternation here) must survive the round-trip and a non-match must drop.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let sessions_dir = $fake_home | path join ".claude" "projects" $encoded
    mkdir $sessions_dir

    '{"type":"user","message":{"content":"deploy to staging now"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"deploy to prod later"},"timestamp":"2024-01-15T10:00:01Z"}'
        | save --force ($sessions_dir | path join "22222222-2222-2222-2222-222222222222.jsonl")
    '{"type":"user","message":{"content":"nothing relevant"},"timestamp":"2024-01-15T10:00:02Z"}'
        | save --force ($sessions_dir | path join "33333333-3333-3333-3333-333333333333.jsonl")

    let result = with-env {HOME: $fake_home} {
        do { cd $proj_dir; claude-nu -f 'staging|prod' }
    }

    rm -rf $fake_home $proj_dir

    let msgs = $result | get message
    assert equal ($result | length) 2
    assert ($msgs | any {|m| $m | str contains "staging" })
    assert ($msgs | any {|m| $m | str contains "prod" })
}

@test
def "claude-nu -f --no-rg matches an anchored pattern the rg pre-filter misses" [] {
    # Why: rg scans the raw JSONL, whose every record line starts with `{`, so
    # `^deploy` never matches there — the default path under-matches. --no-rg
    # parses in-engine and applies `^` to the extracted text, so it finds the
    # message that actually starts with "deploy".
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let sessions_dir = $fake_home | path join ".claude" "projects" $encoded
    mkdir $sessions_dir

    '{"type":"user","message":{"content":"deploy to staging"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($sessions_dir | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"please deploy now"},"timestamp":"2024-01-15T10:00:01Z"}'
        | save --force ($sessions_dir | path join "22222222-2222-2222-2222-222222222222.jsonl")

    let default = with-env {HOME: $fake_home} { do { cd $proj_dir; claude-nu -f '^deploy' } }
    let no_rg = with-env {HOME: $fake_home} { do { cd $proj_dir; claude-nu -f '^deploy' --no-rg } }

    rm -rf $fake_home $proj_dir

    # rg can't see the anchored match in the raw bytes; in-engine it finds the
    # one message that starts with "deploy" and excludes the mid-string one.
    assert equal ($default | length) 0
    assert equal ($no_rg | length) 1
    assert equal $no_rg.0.message "deploy to staging"
}

@test
def "claude-nu without a search term errors with guidance" [] {
    let result = try { claude-nu; "no error" } catch {|e| $e.msg }
    assert ($result | str contains "search term")
}

@test
def "messages keys subagent rows by real project, not the subagents folder" [] {
    # Why: subagent transcripts live at <proj>/<uuid>/subagents/agent-*.jsonl, so
    # `path dirname` labelled them "subagents" and falsely tripped multi-project
    # tagging inside one project. project-dir-name resolves both layouts to the
    # same project, so a single-project scope adds no project column.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj = $fake_home | path join ".claude" "projects" "-proj-a"
    let sub = $proj | path join "11111111-1111-1111-1111-111111111111" "subagents"
    mkdir $sub

    '{"type":"user","message":{"content":"top-level msg"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force ($proj | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"user","message":{"content":"subagent msg"},"timestamp":"2024-01-15T10:00:01Z"}'
        | save --force ($sub | path join "agent-abc123.jsonl")

    let result = with-env {HOME: $fake_home} {
        sessions $proj --subagents | messages
    }

    rm -rf $fake_home

    assert equal ("project" in ($result | columns)) false
    let all = $result | get message
    assert ("top-level msg" in $all)
    assert ("subagent msg" in $all)
}

@test
def "save-markdown fails fast on messages-shaped input" [] {
    let err = try {
        [{role: "user" message: "hi" timestamp: "2024-01-15T10:00:00Z" session: "abc"}] | save-markdown
        null
    } catch {|e| $e.msg }

    assert ($err != null)
    assert ($err =~ "missing columns: date, topic, markdown")
}

# =============================================================================
# Tests for sessions command - Session metadata extraction
# =============================================================================

@test
def "sessions extracts session_id from first record" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","sessionId":"abc-123-def","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns session_id | first

    rm $temp_file

    assert equal $result.session_id "abc-123-def"
}

@test
def "sessions extracts slug from first record" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","slug":"happy-coding-session","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns slug | first

    rm $temp_file

    assert equal $result.slug "happy-coding-session"
}

@test
def "sessions extracts version from first record" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","version":"2.1.11","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns version | first

    rm $temp_file

    assert equal $result.version "2.1.11"
}

@test
def "sessions extracts cwd from first record" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","cwd":"/Users/test/project","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns cwd | first

    rm $temp_file

    assert equal $result.cwd "/Users/test/project"
}

@test
def "sessions extracts git_branch from first record" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","gitBranch":"feature/new-feature","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns git_branch | first

    rm $temp_file

    assert equal $result.git_branch "feature/new-feature"
}

@test
def "sessions handles missing metadata with empty defaults" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns session_id,slug,version,cwd,git_branch | first

    rm $temp_file

    assert equal $result.session_id ""
    assert equal $result.slug ""
    assert equal $result.version ""
    assert equal $result.cwd ""
    assert equal $result.git_branch ""
}

# =============================================================================
# Tests for sessions command - Thinking level extraction
# =============================================================================

@test
def "sessions extracts thinking_level from user records" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","thinkingMetadata":{"level":"high","disabled":false},"message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns thinking_level | first

    rm $temp_file

    assert equal $result.thinking_level "high"
}

@test
def "sessions handles missing thinking metadata" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Hello"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns thinking_level | first

    rm $temp_file

    assert equal $result.thinking_level ""
}

# =============================================================================
# Tests for sessions command - Tool statistics
# =============================================================================

@test
def "sessions extracts bash_commands list" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Run tests"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm build"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns bash_commands | first

    rm $temp_file

    assert equal ($result.bash_commands | length) 2
    assert ("npm test" in $result.bash_commands)
    assert ("npm build" in $result.bash_commands)
}

@test
def "sessions counts bash commands correctly" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Run tests"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cmd1"}},{"type":"tool_use","name":"Bash","input":{"command":"cmd2"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cmd3"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns bash_count | first

    rm $temp_file

    assert equal $result.bash_count 3
}

@test
def "sessions extracts skill_invocations list" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Use skill"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"nushell-style"}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"jj-commit"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns skill_invocations | first

    rm $temp_file

    assert equal ($result.skill_invocations | length) 2
    assert ("nushell-style" in $result.skill_invocations)
    assert ("jj-commit" in $result.skill_invocations)
}

@test
def "sessions counts tool_errors from tool_result" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"123","is_error":false,"content":"success"}]}}'
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"456","is_error":true,"content":"error"}]}}'
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"789","is_error":true,"content":"another error"}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns tool_errors | first

    rm $temp_file

    assert equal $result.tool_errors 2
}

@test
def "sessions counts ask_user_count" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Help me"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[]}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[]}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/test"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns ask_user_count | first

    rm $temp_file

    assert equal $result.ask_user_count 2
}

@test
def "sessions detects plan_mode_used true" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Plan this"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"EnterPlanMode","input":{}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns plan_mode_used | first

    rm $temp_file

    assert equal $result.plan_mode_used true
}

@test
def "sessions detects plan_mode_used false" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Just do it"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns plan_mode_used | first

    rm $temp_file

    assert equal $result.plan_mode_used false
}

# =============================================================================
# Tests for sessions command - Derived metrics
# =============================================================================

@test
def "sessions counts turn_count excluding meta messages" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","isMeta":true,"message":{"content":"System info"}}'
        '{"type":"user","message":{"content":"Real message 1"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"Real message 2"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","isMeta":true,"message":{"content":"More system info"}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns turn_count | first

    rm $temp_file

    assert equal $result.turn_count 2
}

@test
def "sessions counts assistant_msg_count" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Q1"}}'
        '{"type":"assistant","message":{"content":"A1"}}'
        '{"type":"user","message":{"content":"Q2"}}'
        '{"type":"assistant","message":{"content":"A2"}}'
        '{"type":"assistant","message":{"content":"A3"}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns assistant_msg_count | first

    rm $temp_file

    assert equal $result.assistant_msg_count 3
}

@test
def "sessions counts tool_call_count" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","message":{"content":"Do stuff"}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}},{"type":"tool_use","name":"Edit","input":{}}]}}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns tool_call_count | first

    rm $temp_file

    assert equal $result.tool_call_count 3
}

@test
def "sessions handles empty session for derived metrics" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    # Single record to avoid empty file edge case
    let lines = [
        '{"type":"summary","summary":"Empty session"}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns turn_count,assistant_msg_count,tool_call_count | first

    rm $temp_file

    assert equal $result.turn_count 0
    assert equal $result.assistant_msg_count 0
    assert equal $result.tool_call_count 0
}

# =============================================================================
# Tests for sessions command - --all-columns flag
# =============================================================================

@test
def "sessions --all-columns includes all columns" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"

    let lines = [
        '{"type":"user","sessionId":"test-id","slug":"test-slug","version":"1.0","cwd":"/test","gitBranch":"main","thinkingMetadata":{"level":"high"},"message":{"content":"@file.txt"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo"}}]}}'
    ]

    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --all-columns | first
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
    assert ("token_usage" in $cols)
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
    let temp_dir = $nu.temp-dir | path join $"test-sessions-(random uuid)"
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
    let temp_dir = $nu.temp-dir | path join $"test-sessions-(random uuid)"
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
    let temp_dir = $nu.temp-dir | path join $"test-sessions-(random uuid)"
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

@test
def "sessions --all-projects iterates every project dir" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let projects_dir = $fake_home | path join ".claude" "projects"
    let proj_a = $projects_dir | path join "-fake-proj-a"
    let proj_b = $projects_dir | path join "-fake-proj-b"
    mkdir $proj_a $proj_b

    '{"type":"summary","summary":"From A"}'
        | save --force ($proj_a | path join "11111111-1111-1111-1111-111111111111.jsonl")
    '{"type":"summary","summary":"From B"}'
        | save --force ($proj_b | path join "22222222-2222-2222-2222-222222222222.jsonl")

    let result = with-env {HOME: $fake_home} { sessions --all-projects }

    rm -rf $fake_home

    assert equal ($result | length) 2
    let summaries = $result | get summary | sort
    assert equal $summaries ["From A" "From B"]
}

@test
def "sessions --all-projects rejects explicit paths" [] {
    let failed = try {
        sessions "/some/path" --all-projects
        false
    } catch { true }

    assert $failed
}

@test
def "sessions lists subagents only with --subagents" [] {
    # Why: subagent transcripts (2.1.138+: `<dir>/<uuid>/subagents/agent-*.jsonl`)
    # hold agent-driven turns, so they are opt-in — the default scope is top-level
    # human sessions only, and --subagents adds them back.
    let parent_uuid = "b370af1e-c96f-46a2-a3fe-66b16f38bc03"

    let default = null | sessions $FIXTURES_SESSIONS_DIR
    assert (($default | where parent_session_id == null | length) > 0)
    assert equal ($default | where parent_session_id == $parent_uuid | length) 0

    let opted_in = null | sessions $FIXTURES_SESSIONS_DIR --subagents
    assert (($opted_in | where parent_session_id == $parent_uuid | length) > 0)
    assert (($opted_in | where parent_session_id == null | length) > 0)
}

@test
def "sessions adds parent_session_id column to every row" [] {
    let result = null | sessions $FIXTURES_SESSIONS_DIR
    let cols = $result | columns
    assert ("parent_session_id" in $cols)
}

@test
def "discover-session-files yields null parent for top-level files" [] {
    let temp_dir = $nu.temp-dir | path join $"test-discover-(random uuid)"
    mkdir $temp_dir

    let top_file = $temp_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl"
    "" | save --force $top_file

    let result = discover-session-files $temp_dir

    rm -rf $temp_dir

    assert equal ($result | length) 1
    assert equal $result.0.parent_session_id null
    assert equal $result.0.path $top_file
}

@test
def "discover-session-files extracts parent UUID from subagent path" [] {
    let temp_dir = $nu.temp-dir | path join $"test-discover-(random uuid)"
    let parent_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let subagents_dir = $temp_dir | path join $parent_uuid "subagents"
    mkdir $subagents_dir

    let agent_file = $subagents_dir | path join "agent-deadbeef1234.jsonl"
    "" | save --force $agent_file

    let result = discover-session-files $temp_dir

    rm -rf $temp_dir

    let agent_rows = $result | where parent_session_id == $parent_uuid
    assert equal ($agent_rows | length) 1
    assert equal $agent_rows.0.path $agent_file
}

@test
def "discover-session-files finds workflow-nested subagents" [] {
    # Why: Workflow agents nest deeper at
    # `<uuid>/subagents/workflows/wf_*/agent-*.jsonl`; a single-level glob misses
    # them, and the parent UUID must still resolve to the session, not `workflows`.
    let temp_dir = $nu.temp-dir | path join $"test-discover-(random uuid)"
    let parent_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let nested = $temp_dir | path join $parent_uuid "subagents" "workflows" "wf_abc123"
    mkdir $nested

    let agent_file = $nested | path join "agent-deadbeef1234.jsonl"
    "" | save --force $agent_file

    let result = discover-session-files $temp_dir

    rm -rf $temp_dir

    let agent_rows = $result | where parent_session_id == $parent_uuid
    assert equal ($agent_rows | length) 1
    assert equal $agent_rows.0.path $agent_file
}

@test
def "discover-session-files orders rows newest first" [] {
    # Why: the recency callers (most-recent session, newest-of-each-project)
    # trust this order instead of re-sorting, so it is a contract.
    let temp_dir = $nu.temp-dir | path join $"test-discover-(random uuid)"
    mkdir $temp_dir

    let older = $temp_dir | path join "11111111-1111-1111-1111-111111111111.jsonl"
    let newer = $temp_dir | path join "22222222-2222-2222-2222-222222222222.jsonl"
    "" | save --force $older
    "" | save --force $newer
    touch -m -t ((date now) - 2hr) $older
    touch -m -t ((date now) - 1hr) $newer

    let result = discover-session-files $temp_dir

    rm -rf $temp_dir

    assert ("modified" in ($result | columns))
    assert equal ($result | get path) [$newer $older]
}

# =============================================================================
# nu-complete claude sessions tests
# =============================================================================

@test
def "nu-complete returns empty for non-existent sessions dir" [] {
    # Why: a fake HOME guarantees the sessions dir is absent — with the real
    # HOME the test breaks on machines that have Claude sessions for /tmp.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    mkdir $fake_home
    let result = with-env {HOME: $fake_home} {
        do {
            cd /tmp
            nu-complete claude sessions
        }
    }
    rm -rf $fake_home

    assert equal $result.completions []
    assert equal $result.options.sort false
}

@test
def "nu-complete claude sessions shows latest ai-title in description" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let sessions_dir = $fake_home | path join ".claude" "projects" $encoded
    mkdir $sessions_dir

    # ai-title sits beyond any fixed head window and is rewritten later
    let lines = [
        '{"type":"user","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":"hello"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","message":{"content":"more"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"assistant","message":{"content":"sure"},"timestamp":"2024-01-15T10:00:03Z"}'
        '{"type":"user","message":{"content":"go on"},"timestamp":"2024-01-15T10:00:04Z"}'
        '{"type":"ai-title","aiTitle":"Old title"}'
        '{"type":"ai-title","aiTitle":"Current title"}'
    ]
    $lines | str join "\n"
        | save --force ($sessions_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl")

    let result = with-env {HOME: $fake_home} {
        do {
            cd $proj_dir
            nu-complete claude sessions
        }
    }

    rm -rf $fake_home $proj_dir

    assert equal ($result.completions | length) 1
    assert ($result.completions.0.description | str contains "Current title")
}

@test
def "projects recovers name from session cwd and counts sessions" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let sessions_dir = $fake_home | path join ".claude" "projects" "-some-encoded-dir"
    mkdir $sessions_dir

    # Why: the encoded dir name is lossy — `name` must come from cwd,
    # not from decoding the dir name.
    let lines = [
        '{"type":"user","cwd":"/real/parent/proj","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    $lines | str join "\n"
        | save --force ($sessions_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl")
    $lines | str join "\n"
        | save --force ($sessions_dir | path join "12345678-1234-1234-1234-123456789abd.jsonl")

    let result = with-env {HOME: $fake_home} { projects }

    rm -rf $fake_home

    assert equal ($result | length) 1
    assert equal $result.0.name "parent/proj"
    assert equal $result.0.count 2
    assert equal $result.0.path $sessions_dir
}

@test
def "projects falls back to older sessions when newest lacks cwd" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let sessions_dir = $fake_home | path join ".claude" "projects" "-some-encoded-dir"
    mkdir $sessions_dir

    # Why: a summary-only file (a real Claude Code artifact) carries no cwd;
    # when it is the newest, the project must not vanish from the listing.
    let old_file = $sessions_dir | path join "12345678-1234-1234-1234-123456789abc.jsonl"
    '{"type":"user","cwd":"/real/parent/proj","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        | save --force $old_file
    touch -m -t ((date now) - 1hr) $old_file
    '{"type":"summary","summary":"Legacy sidechain summary"}'
        | save --force ($sessions_dir | path join "12345678-1234-1234-1234-123456789abd.jsonl")

    let result = with-env {HOME: $fake_home} { projects }

    rm -rf $fake_home

    assert equal ($result | length) 1
    assert equal $result.0.name "parent/proj"
    assert equal $result.0.count 2
}

@test
def "projects skips dirs without session files" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    mkdir ($fake_home | path join ".claude" "projects" "-empty-project")

    let result = with-env {HOME: $fake_home} { projects }

    rm -rf $fake_home

    assert equal $result []
}

@test
def "sessions expands piped project dirs like positional dirs" [] {
    # Why: `projects | sessions` pipes dirs through the path column —
    # they must discover subagent files exactly as positional dirs do.
    let piped = [{path: $FIXTURES_SESSIONS_DIR}] | sessions --subagents
    let positional = null | sessions $FIXTURES_SESSIONS_DIR --subagents

    assert equal ($piped | sort-by path) ($positional | sort-by path)
    assert (($piped | where parent_session_id != null | length) > 0)
}

# =============================================================================
# sanitize-topic tests
# =============================================================================

@test
def "sanitize-topic converts to lowercase" [] {
    let result = "Hello World" | sanitize-topic
    assert equal $result "hello-world"
}

@test
def "sanitize-topic replaces special chars with dashes" [] {
    let result = "feat: add new feature!" | sanitize-topic
    assert equal $result "feat-add-new-feature"
}

@test
def "sanitize-topic collapses multiple dashes" [] {
    let result = "a--b---c" | sanitize-topic
    assert equal $result "a-b-c"
}

@test
def "sanitize-topic trims leading and trailing dashes" [] {
    let result = "---hello---" | sanitize-topic
    assert equal $result "hello"
}

@test
def "sanitize-topic handles empty string" [] {
    let result = "" | sanitize-topic
    assert equal $result ""
}

@test
def "sanitize-topic truncates to 50 chars" [] {
    let long_input = "this-is-a-very-long-topic-name-that-exceeds-fifty-characters-limit"
    let result = $long_input | sanitize-topic
    assert (($result | str length) <= 50)
}

@test
def "sanitize-topic preserves numbers" [] {
    let result = "version-2.0.1-release" | sanitize-topic
    assert equal $result "version-2-0-1-release"
}

@test
def "sanitize-topic handles unicode" [] {
    let result = "café résumé" | sanitize-topic
    assert equal $result "caf-r-sum"
}

# =============================================================================
# Tests against vendored real-session fixtures (Claude Code 2.1.x)
# =============================================================================

@test
def "extract-agents recognizes Agent tool name in 2.1.x" [] {
    let tool_calls = [
        {name: "Agent" input: {subagent_type: "Explore" description: "Find files"}}
        {name: "Read" input: {file_path: "/test.txt"}}
        {name: "Agent" input: {subagent_type: "general-purpose" description: "Audit"}}
    ]
    let agents = $tool_calls | extract-agents

    assert equal ($agents | length) 2
    assert equal ($agents | first | get type) "Explore"
    assert equal ($agents | last | get type) "general-purpose"
}

@test
def "extract-agents still recognizes legacy Task tool name" [] {
    let tool_calls = [
        {name: "Task" input: {subagent_type: "Explore" description: "Old name"}}
        {name: "Agent" input: {subagent_type: "general-purpose" description: "New name"}}
    ]
    let agents = $tool_calls | extract-agents

    assert equal ($agents | length) 2
}

@test
def "sessions finds agents in Agent-tool fixture" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_PERMMODE_AGENT
    let result = sessions $p --columns agents | first
    assert (($result.agents | length) > 0)
}

@test
def "extract-session-metadata walks records to find each field" [] {
    # Why: in 2.1.x first record can be permission-mode (sessionId only) or
    # file-history-snapshot (no metadata). Each field comes from the first
    # record that actually carries it.
    let records = [
        {type: "permission-mode" sessionId: "sess-abc" permissionMode: "auto"}
        {type: "file-history-snapshot" snapshot: {}}
        {type: "user" sessionId: "sess-abc" cwd: "/project" version: "2.1.138" gitBranch: "main" slug: "my-slug" message: {content: "hi"}}
    ]
    let meta = $records | extract-session-metadata

    assert equal $meta.session_id "sess-abc"
    assert equal $meta.cwd "/project"
    assert equal $meta.version "2.1.138"
    assert equal $meta.git_branch "main"
    assert equal $meta.slug "my-slug"
}

@test
def "extract-session-metadata returns empty defaults when no records carry a field" [] {
    let records = [
        {type: "permission-mode" sessionId: "sess-x" permissionMode: "auto"}
    ]
    let meta = $records | extract-session-metadata

    assert equal $meta.session_id "sess-x"
    assert equal $meta.cwd ""
    assert equal $meta.version ""
    assert equal $meta.git_branch ""
    assert equal $meta.slug ""
}

@test
def "sessions metadata works for file-history-snapshot-first fixture" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_TASKFAMILY
    let result = sessions $p --columns session_id,cwd,version,git_branch | first
    assert (($result.session_id | str length) > 0)
    assert (($result.cwd | str length) > 0)
    assert (($result.version | str length) > 0)
}

@test
def "sessions metadata works for permission-mode-first fixture" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_PERMMODE_AGENT
    let result = sessions $p --columns session_id,cwd,version,git_branch | first
    assert (($result.session_id | str length) > 0)
    assert (($result.cwd | str length) > 0)
    assert (($result.version | str length) > 0)
}

@test
def "sessions metadata still works for older user-first fixture" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_USER_FIRST
    let result = sessions $p --columns session_id,cwd,version,git_branch | first
    assert (($result.session_id | str length) > 0)
    assert (($result.cwd | str length) > 0)
    assert equal $result.version "2.1.129"
}

@test
def "sessions falls back to ai-title aiTitle when no summary record" [] {
    # All vendored fixtures lack a summary record but have ai-title
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_PERMMODE_AGENT
    let result = sessions $p --columns summary | first
    assert (($result.summary | str length) > 0)
}

@test
def "sessions uses summary record when present in preference to ai-title" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"
    let lines = [
        '{"type":"summary","summary":"Real summary record"}'
        '{"type":"ai-title","aiTitle":"AI title fallback"}'
        '{"type":"user","sessionId":"x","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns summary | first
    rm $temp_file

    assert equal $result.summary "Real summary record"
}

@test
def "sessions falls back to ai-title aiTitle for summary" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"
    let lines = [
        '{"type":"ai-title","aiTitle":"My AI title"}'
        '{"type":"user","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file | first
    rm $temp_file

    assert equal $result.summary "My AI title"
}

@test
def "sessions derives plan_mode_used true from permission-mode record" [] {
    # Why: 2.1.x replaced EnterPlanMode tool calls with top-level
    # permission-mode records carrying permissionMode value
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_PERMMODE_AGENT
    let result = sessions $p --columns plan_mode_used | first
    assert equal $result.plan_mode_used true
}

@test
def "sessions plan_mode_used false when no plan in permission-mode" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_AGENT
    let result = sessions $p --columns plan_mode_used | first
    assert equal $result.plan_mode_used false
}

@test
def "sessions plan_mode_used still detects legacy EnterPlanMode tool" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"plan this"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"EnterPlanMode","input":{}}]}}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --columns plan_mode_used | first
    rm $temp_file

    assert equal $result.plan_mode_used true
}

@test
def "extract-tool-stats counts new task-family tool names" [] {
    let tool_calls = [
        {name: "TaskCreate" input: {subject: "X" description: "y" activeForm: "z"}}
        {name: "TaskCreate" input: {subject: "X" description: "y" activeForm: "z"}}
        {name: "TaskUpdate" input: {taskId: "1" status: "completed"}}
        {name: "TaskStop" input: {}}
        {name: "Monitor" input: {}}
        {name: "ToolSearch" input: {query: "x" max_results: 5}}
    ]
    let stats = $tool_calls | extract-tool-stats []

    assert equal $stats.tool_counts.TaskCreate 2
    assert equal $stats.tool_counts.TaskUpdate 1
    assert equal $stats.tool_counts.TaskStop 1
    assert equal $stats.tool_counts.Monitor 1
    assert equal $stats.tool_counts.ToolSearch 1
}

@test
def "extract-tool-stats keeps backward-compat columns" [] {
    let tool_calls = [
        {name: "Bash" input: {command: "ls"}}
        {name: "Skill" input: {skill: "x"}}
        {name: "AskUserQuestion" input: {questions: []}}
    ]
    let stats = $tool_calls | extract-tool-stats []

    assert equal $stats.bash_count 1
    assert equal ($stats.bash_commands | length) 1
    assert equal ($stats.skill_invocations | length) 1
    assert equal $stats.ask_user_count 1
}

@test
def "sessions counts new tool names from fixture" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_TASKFAMILY
    let result = sessions $p --columns tool_counts | first
    # ae3bbbf7 fixture has TaskCreate, TaskUpdate, TaskStop calls
    assert ($result.tool_counts.TaskCreate > 0)
    assert ($result.tool_counts.TaskUpdate > 0)
    assert ($result.tool_counts.TaskStop > 0)
}

@test
def "sessions --all-columns includes new tool-stat columns" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Monitor","input":{}}]}}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = sessions $temp_file --all-columns | first
    let cols = $result | columns
    rm $temp_file

    assert ("tool_counts" in $cols)
    let count_keys = $result.tool_counts | columns
    assert ("TaskCreate" in $count_keys)
    assert ("TaskUpdate" in $count_keys)
    assert ("TaskStop" in $count_keys)
    assert ("Monitor" in $count_keys)
    assert ("ToolSearch" in $count_keys)
}

@test
def "sessions token-usage sums usage across turns" [] {
    let temp_file = $nu.temp-dir | path join $"test-session-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"a"}],"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":1}}}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"b"}],"usage":{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":2}}}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let u = sessions $temp_file --columns token_usage | first | get token_usage
    rm $temp_file

    assert equal $u.input_tokens 13
    assert equal $u.output_tokens 27
    assert equal $u.cache_creation_input_tokens 5
    assert equal $u.cache_read_input_tokens 3
}

# Guards the math-sum-on-empty crash: assistant turns may carry no usage.
@test
def "extract-token-usage zeros when usage absent" [] {
    let u = [
        {type: "assistant" message: {role: "assistant" content: [{type: "text" text: "x"}]}}
    ] | extract-token-usage

    assert equal $u.input_tokens 0
    assert equal $u.output_tokens 0
    assert equal $u.cache_creation_input_tokens 0
    assert equal $u.cache_read_input_tokens 0
}

# =============================================================================
# Tests for export-session --tools flag (tool_use/tool_result rendering)
# =============================================================================

@test
def "export-session default omits tool blocks" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_AGENT
    let md = export-session --session $p | get markdown

    # No blockquote placeholders should leak when --tools is absent
    assert not ($md | str contains "> [")
    # Tool names from the fixture must not appear as headings or placeholders
    assert not ($md | str contains "> [Bash:")
    assert not ($md | str contains "> [Read:")
    assert not ($md | str contains "> [result")
}

@test
def "export-session --tools renders tool_use as one-line blockquote" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_AGENT
    let md = export-session --session $p --tools | get markdown

    # Real fixture has Bash and Read tool calls
    assert ($md | str contains "> [Bash:")
    assert ($md | str contains "> [Read:")
}

@test
def "export-session --tools renders tool_result placeholder with char count" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_FHS_AGENT
    let md = export-session --session $p --tools | get markdown

    assert ($md =~ '> \[result(?: error)?: \d+ chars\]')
}

@test
def "export-session --tools truncates long tool inputs to ~120 chars" [] {
    let temp_file = $nu.temp-dir | path join $"test-export-(random uuid).jsonl"
    let long_cmd = "echo " + (0..200 | each { "x" } | str join "")
    let lines = [
        ('{"type":"user","message":{"content":"do thing"},"timestamp":"2024-01-15T10:00:00Z"}')
        ('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"' + $long_cmd + '"}}]}}')
    ]
    $lines | str join "\n" | save --force $temp_file

    let md = export-session --session $temp_file --tools | get markdown
    rm $temp_file

    # The placeholder line shouldn't blow past ~130 chars including marker
    let placeholder = $md | lines | where { $in | str starts-with "> [Bash:" } | first
    assert (($placeholder | str length) < 140)
    assert ($placeholder | str ends-with "...]")
}

@test
def "export-session --tools renders tool_result error marker" [] {
    let temp_file = $nu.temp-dir | path join $"test-export-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"do thing"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"false"}}]}}'
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","is_error":true,"content":"command not found"}]}}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let md = export-session --session $temp_file --tools | get markdown
    rm $temp_file

    assert ($md =~ '> \[result error: \d+ chars\]')
}

@test
def "export-session --tools picks file_path for Read tool placeholder" [] {
    let temp_file = $nu.temp-dir | path join $"test-export-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"read it"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.rs"}}]}}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let md = export-session --session $temp_file --tools | get markdown
    rm $temp_file

    assert ($md | str contains "> [Read: /src/main.rs]")
}

# =============================================================================
# Tests for messages --include-thinking flag
# =============================================================================

@test
def "messages default drops thinking-only assistant turns" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_USER_FIRST
    let result = messages --session $p --include-responses

    # No [thinking] prefix should leak when --include-thinking is absent
    assert not ($result | get message | any { $in | str contains "[thinking]" })
}

@test
def "messages --include-thinking surfaces thinking-only assistant turns" [] {
    let p = $FIXTURES_SESSIONS_DIR | path join $FIXTURE_USER_FIRST
    let default = messages --session $p --include-responses | where role == "assistant" | length
    let with_thinking = messages --session $p --include-responses --include-thinking | where role == "assistant" | length

    # Fixture has 38 thinking-only turns; flag must surface at least some
    assert ($with_thinking > $default)
}

@test
def "messages --include-thinking prefixes thinking blocks" [] {
    let temp_file = $nu.temp-dir | path join $"test-thinking-(random uuid).jsonl"
    let lines = [
        '{"type":"user","message":{"content":"hi"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"pondering the question"},{"type":"text","text":"answer"}]},"timestamp":"2024-01-15T10:00:01Z"}'
    ]
    $lines | str join "\n" | save --force $temp_file

    let result = messages --session $temp_file --include-responses --include-thinking
    rm $temp_file

    let assistant_msg = $result | where role == "assistant" | first | get message
    assert ($assistant_msg | str contains "[thinking] pondering the question")
    assert ($assistant_msg | str contains "answer")
}

# =============================================================================
# Tests for resolve-session-file resolution branches
# =============================================================================

@test
def "resolve-session-file passes through a .jsonl path unchanged" [] {
    # Why: an explicit path is taken as-is (no existence check); UUID lookup is
    # the only branch that touches disk.
    assert equal (resolve-session-file "/made/up/path.jsonl") "/made/up/path.jsonl"
}

@test
def "resolve-session-file resolves a bare UUID against the sessions dir" [] {
    let dir = $nu.temp-dir | path join $"test-resolve-(random uuid)"
    mkdir $dir
    let uuid = "12345678-1234-1234-1234-123456789abc"
    "" | save --force ($dir | path join $"($uuid).jsonl")

    let result = resolve-session-file $uuid --sessions-dir $dir

    rm -rf $dir

    assert equal ($result | path basename) $"($uuid).jsonl"
}

@test
def "resolve-session-file finds a UUID in another project via glob" [] {
    # Why: UUIDs are globally unique, so a session from another project resolves
    # by scanning every project under ~/.claude when it is not in the local dir.
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj = $fake_home | path join ".claude" "projects" "-proj-x"
    mkdir $proj
    let uuid = "abcdabcd-1234-1234-1234-123456789abc"
    "" | save --force ($proj | path join $"($uuid).jsonl")
    let empty_dir = $nu.temp-dir | path join $"empty-(random uuid)"
    mkdir $empty_dir

    let result = with-env {HOME: $fake_home} {
        resolve-session-file $uuid --sessions-dir $empty_dir
    }

    rm -rf $fake_home $empty_dir

    assert equal ($result | path basename) $"($uuid).jsonl"
}

@test
def "resolve-session-file errors when a UUID exists nowhere" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    mkdir ($fake_home | path join ".claude" "projects")
    let empty_dir = $nu.temp-dir | path join $"empty-(random uuid)"
    mkdir $empty_dir

    let err = with-env {HOME: $fake_home} {
        try {
            resolve-session-file "ffffffff-0000-0000-0000-000000000000" --sessions-dir $empty_dir
            ""
        } catch {|e| $e.msg }
    }

    rm -rf $fake_home $empty_dir

    assert str contains $err "not found in any project"
}

# =============================================================================
# Tests for resolve-piped-sessions input routing
# =============================================================================

@test
def "resolve-piped-sessions returns null for nothing input" [] {
    assert equal (resolve-piped-sessions null) null
}

@test
def "resolve-piped-sessions reads the path column, deduped" [] {
    let result = resolve-piped-sessions [{path: "/a.jsonl"} {path: "/a.jsonl"} {path: "/b.jsonl"}]
    assert equal $result ["/a.jsonl" "/b.jsonl"]
}

@test
def "resolve-piped-sessions accepts a record as a 1-row table" [] {
    let result = resolve-piped-sessions {path: "/a.jsonl"}
    assert equal $result ["/a.jsonl"]
}

@test
def "resolve-piped-sessions resolves the session column via UUID lookup" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj = $fake_home | path join ".claude" "projects" "-proj-x"
    mkdir $proj
    let uuid = "abcdabcd-1234-1234-1234-123456789abc"
    "" | save --force ($proj | path join $"($uuid).jsonl")

    let result = with-env {HOME: $fake_home} { resolve-piped-sessions [{session: $uuid}] }

    rm -rf $fake_home

    assert equal ($result | each { path basename }) [$"($uuid).jsonl"]
}

@test
def "resolve-piped-sessions errors on input lacking path or session" [] {
    let err = try { resolve-piped-sessions [{foo: 1}]; "" } catch {|e| $e.msg }
    assert str contains $err "must have 'path' or 'session' column"
}

# =============================================================================
# Tests for messages --raw and regex filtering
# =============================================================================

@test
def "messages --raw returns raw records without the rendered text column" [] {
    let f = $nu.temp-dir | path join $"test-raw-(random uuid).jsonl"
    [
        '{"type":"user","message":{"content":"hello"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"<command-name>noise</command-name>"},"timestamp":"2024-01-15T10:00:01Z"}'
    ] | str join "\n" | save --force $f

    let raw = messages --session $f --raw

    rm $f

    # System wrapper still filtered; the raw row keeps the nested message record
    assert equal ($raw | length) 1
    assert ("text" not-in ($raw | columns))
    assert ("message" in ($raw | columns))
    assert equal ($raw | first | get message.content) "hello"
}

@test
def "messages regex argument filters by rendered text" [] {
    let f = $nu.temp-dir | path join $"test-regex-(random uuid).jsonl"
    [
        '{"type":"user","message":{"content":"deploy the service"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"write the tests"},"timestamp":"2024-01-15T10:00:01Z"}'
    ] | str join "\n" | save --force $f

    let result = messages --session $f "deploy" | get message

    rm $f

    assert equal $result ["deploy the service"]
}

# =============================================================================
# Tests for save-markdown file output and collisions
# =============================================================================

@test
def "save-markdown writes a file and returns its path for a record" [] {
    let out = $nu.temp-dir | path join $"md-out-(random uuid)"
    let row = {session: "11111111-1111-1111-1111-111111111111" date: "20240115" topic: "my-topic" markdown: "# Hello\n\nbody"}

    let filepath = $row | save-markdown --output-dir $out

    let written = open --raw $filepath
    let basename = $filepath | path basename
    rm -rf $out

    # Record input -> a single filepath string back
    assert equal ($filepath | describe) "string"
    assert equal $basename "20240115-my-topic.md"
    assert equal $written "# Hello\n\nbody"
}

@test
def "save-markdown disambiguates colliding filenames with the session id" [] {
    # Why: two sessions sharing a date+topic would clobber one file; the writer
    # appends a session-id prefix so both survive.
    let out = $nu.temp-dir | path join $"md-out-(random uuid)"
    let rows = [
        {session: "aaaa1111-1111-1111-1111-111111111111" date: "20240115" topic: "topic-x" markdown: "# A"}
        {session: "bbbb2222-2222-2222-2222-222222222222" date: "20240115" topic: "topic-x" markdown: "# B"}
    ]

    let result = $rows | save-markdown --output-dir $out
    let names = ls $out | get name | path basename | sort
    rm -rf $out

    assert equal ($result | length) 2
    assert equal $names ["20240115-topic-x-aaaa11.md" "20240115-topic-x-bbbb22.md"]
}

# =============================================================================
# Tests for export-session dialogue rendering
# =============================================================================

@test
def "export-session merges consecutive same-role turns" [] {
    # Why: two user turns with no assistant between them collapse into one
    # "## User" section joined by a blank line, not two headers.
    let f = $nu.temp-dir | path join $"test-merge-(random uuid).jsonl"
    [
        '{"type":"user","message":{"content":"first"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","message":{"content":"second"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"reply"}]},"timestamp":"2024-01-15T10:00:02Z"}'
    ] | str join "\n" | save --force $f

    let md = export-session --session $f | get markdown

    rm $f

    assert equal ($md | lines | where $it == "## User" | length) 1
    assert equal ($md | lines | where $it == "## Assistant" | length) 1
    assert ($md | str contains "first\n\nsecond")
}
