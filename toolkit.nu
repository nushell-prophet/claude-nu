const captures_dir = 'dotnu-captures'
const fixtures_sessions_dir = 'tests/fixtures/sessions'
const uuid_jsonl_pattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# Check if a path has uncommitted changes in its git repository
def has-uncommitted-changes [path: path]: nothing -> bool {
    if not ($path | path exists) { return false }

    let dir = if ($path | path type) == 'dir' { $path } else { $path | path dirname }

    let git_check = do { cd $dir; ^git rev-parse --git-dir } | complete
    if $git_check.exit_code != 0 { return false }

    let status = do { cd $dir; ^git status --porcelain -- $path } | complete
    ($status.stdout | str trim | is-not-empty)
}

# Find nutest module path, or null if not available
def find-nutest [] {
    for dir in ($env.NU_LIB_DIRS? | default []) {
        let candidate = $dir | path join 'nutest'
        if ($candidate | path exists) {
            return ($candidate | path expand)
        }
    }

    let sibling = '../nutest/nutest' | path expand
    if ($sibling | path exists) { return $sibling }

    null
}

export def main [] { }

# Run all tests
#
# Output mode is auto-detected: when stdout is a terminal you get the human view
# (failures + a summary line); when it is piped or redirected you get machine-readable
# JSON. Force either with --json / --pretty.
@example "Run tests interactively" { nu toolkit.nu test }
@example "Run tests for CI" { nu toolkit.nu test --fail }
@example "Output JSON for tooling" { nu toolkit.nu test --json }
export def 'main test' [
    --json # force machine-readable JSON output even on a terminal
    --pretty # force the human view even when output is piped
    --all # human view: also list passing tests (default shows only failures)
    --fail # exit with non-zero code if any tests fail (for CI)
] {
    let results = collect-unit-results

    if (machine-mode --json=$json --pretty=$pretty) {
        print ($results | to json --raw)
    } else {
        print-human $results --all=$all
    }

    if $fail and ($results | where status == 'failed' | is-not-empty) {
        exit 1
    }
}

# Run unit tests using nutest
#
# Machine (JSON / piped) rows use the flat schema:
#   {type: 'unit', name, status: 'passed'|'failed', file: null, message}
# Note: status is 'passed'|'failed', NOT nutest's 'PASS'|'FAIL' 'result' column.
# message holds the assertion text on failure, null otherwise.
@example "Run unit tests" { nu toolkit.nu test-unit }
export def 'main test-unit' [
    --json # force machine-readable JSON output even on a terminal
    --pretty # force the human view even when output is piped
    --all # human view: also list passing tests (default shows only failures)
] {
    let flat = collect-unit-results
    if (machine-mode --json=$json --pretty=$pretty) {
        $flat | to json --raw
    } else {
        print-human $flat --all=$all
    }
}

# Decide whether to emit machine-readable data instead of the human view.
# Why: agents capture stdout through a pipe, humans read it in a terminal.
# Not $nu.is-interactive because: it reports REPL-ness, not human-ness — it is false for
# any `nu toolkit.nu ...` script run (human or agent) and true for an agent driving the
# nushell MCP, so it detects the opposite of what we need. is-terminal --stdout is the tty test.
def machine-mode [--json --pretty]: nothing -> bool {
    if $pretty { return false } # Not-piped override wins over everything
    if $json { return true }
    not (is-terminal --stdout)
}

# Collect unit test results as flat rows. nutest runs in a child nu so its module
# state can't leak into ours; errors go to stderr so they never corrupt the JSON on stdout.
def collect-unit-results []: nothing -> table {
    let nutest_path = find-nutest
    if $nutest_path == null {
        print -e $"(ansi red)✗(ansi reset) nutest not found in NU_LIB_DIRS or at ../nutest"
        print -e $"  Install: (ansi attr_dimmed)git clone https://github.com/vyadh/nutest ../nutest(ansi reset)"
        return []
    }

    let tests_path = 'tests' | path expand
    let result = do {
        ^nu -c $"use ($nutest_path); nutest run-tests --path ($tests_path) --returns table --display nothing | to json --raw"
    } | complete

    if $result.exit_code != 0 {
        print -e $"(ansi red)✗(ansi reset) nutest failed"
        if ($result.stderr | str trim | is-not-empty) { print -e $result.stderr }
        return []
    }

    $result.stdout
    | from json
    | each {|row|
        let status = if $row.result == 'PASS' { 'passed' } else { 'failed' }
        let message = if $status == 'failed' {
            let msgs = $row.output? | default [] | each {|o| $o.msg? } | compact
            if ($msgs | is-empty) { null } else { $msgs | str join '; ' }
        } else { null }
        {type: 'unit' name: $row.test status: $status file: null message: $message}
    }
}

# Print the human view: non-passing tests (or all with --all), then a summary line.
# Returns nothing so no wide table auto-renders and truncates the verdict column.
def print-human [flat: table --all] {
    let to_show = if $all { $flat } else { $flat | where status != 'passed' }
    $to_show | each {|r| print-test-result $r }
    print-summary $flat
}

# Print the N passed, M failed headline
def print-summary [flat: table] {
    let passed = $flat | where status == 'passed' | length
    let failed = $flat | where status == 'failed' | length
    let total = $flat | length
    print $"(ansi green_bold)($passed) passed(ansi reset), (ansi red_bold)($failed) failed(ansi reset) \(($total) total\)"
}

# Print a single test result with status indicator (and the assertion on failure)
def print-test-result [result: record] {
    let icon = match $result.status {
        'passed' => $"(ansi green)✓(ansi reset)"
        'failed' => $"(ansi red)✗(ansi reset)"
        _ => "?"
    }
    let suffix = if $result.file != null { $" (ansi attr_dimmed)\(($result.file)\)(ansi reset)" } else { "" }
    print $"  ($icon) ($result.name)($suffix)"
    if $result.status == 'failed' and ($result.message? | is-not-empty) {
        print $"      (ansi red)($result.message)(ansi reset)"
    }
}

# Download Claude Code documentation pages from the sitemap
@example "Fetch docs" { nu toolkit.nu fetch-claude-docs }
@example "Fetch and commit" { nu toolkit.nu fetch-claude-docs --commit }
export def 'main fetch-claude-docs' [
    --commit # Create a git commit after downloading
] {
    use claude-nu/docs.nu
    docs fetch-claude-docs --commit=$commit
}

# Fetch Nushell documentation (book, cookbook, blog) via shallow sparse checkout
@example "Fetch/update Nushell docs" { nu toolkit.nu fetch-nushell-docs }
export def 'main fetch-nushell-docs' [] {
    use claude-nu/docs.nu
    docs fetch-nushell-docs
}

# Vendor real session files as test fixtures (with obfuscated session IDs)
@example "Vendor 3 most recent sessions" { nu toolkit.nu vendor-sessions }
@example "Vendor 5 sessions" { nu toolkit.nu vendor-sessions --count 5 }
@example "Vendor and commit" { nu toolkit.nu vendor-sessions --commit }
export def 'main vendor-sessions' [
    ...sessions: string # Session UUIDs to vendor (default: most recent)
    --count (-n): int = 3 # Number of most recent sessions when no UUIDs given
    --commit # Also create a git commit after copying
] {
    use claude-nu/sessions.nu get-sessions-dir

    let sessions_dir = get-sessions-dir
    if not ($sessions_dir | path exists) {
        print $"(ansi red)✗(ansi reset) No sessions directory at ($sessions_dir)"
        return
    }

    let source_files = if ($sessions | is-empty) {
        let available = ls $sessions_dir
            | where name =~ $uuid_jsonl_pattern
            | sort-by modified --reverse

        let to_take = [($available | length) $count] | math min
        $available | first $to_take | get name
    } else {
        $sessions | each {|s|
            if ($s | str ends-with '.jsonl') { $s } else {
                $sessions_dir | path join $"($s).jsonl"
            }
        }
    }

    mkdir $fixtures_sessions_dir

    $source_files | each {|file|
        if not ($file | path exists) {
            print $"(ansi yellow)⚠(ansi reset) Not found: ($file | path basename)"
            return null
        }

        let raw = open --raw $file
        let old_uuid = $file | path basename | str replace '.jsonl' ''
        let new_uuid = random uuid

        # Replace filename UUID throughout the file
        let obfuscated = $raw | str replace --all $old_uuid $new_uuid

        # Also replace sessionId if it differs from the filename UUID
        let session_id = $raw | lines | first | from json | get sessionId? | default ""
        let obfuscated = if ($session_id != "" and $session_id != $old_uuid) {
            let new_session_id = random uuid
            $obfuscated | str replace --all $session_id $new_session_id
        } else { $obfuscated }

        let dest = $fixtures_sessions_dir | path join $"($new_uuid).jsonl"
        $obfuscated | save --force $dest

        let size = ls $dest | get size.0
        print $"(ansi green)✓(ansi reset) ($old_uuid | str substring 0..8)… → ($new_uuid | str substring 0..8)… (($size))"
    }

    if $commit {
        let status = git status --porcelain $fixtures_sessions_dir | str trim
        if $status != "" {
            git add $fixtures_sessions_dir
            git commit -m "test: vendor session fixtures"
            print $"(ansi green)Committed session fixtures(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}

# Check .nu file for static errors, showing line content for each diagnostic
@example "Check a file" { nu toolkit.nu check claude-nu/sessions.nu }
export def 'main check' [file: path] {
    let content = open --raw $file
    let source_lines = $content | lines

    nu --ide-check 10 $file
    | lines
    | each { from json }
    | where type == "diagnostic"
    | each {|d|
        let before = $content | str substring 0..<$d.span.start
        let line_num = $before | split row "\n" | length
        {
            line: $line_num
            severity: $d.severity
            message: $d.message
            source: ($source_lines | get ($line_num - 1) | str trim)
            span: ($content | str substring $d.span.start..<$d.span.end)
        }
    }
    | uniq
}

# Update dotnu capture files (requires dotnu module in scope)
@example "Update all captures" { nu toolkit.nu update-captures }
export def 'main update-captures' [] {
    if not (scope modules | where name == dotnu | is-not-empty) {
        print $"(ansi red)✗(ansi reset) dotnu module not in scope"
        print "  Add `use dotnu/` or ensure dotnu is in NU_LIB_DIRS"
        return
    }

    let captures = glob $'($captures_dir)/*.nu'
    if ($captures | is-empty) {
        print $"(ansi attr_dimmed)No capture files in ($captures_dir)/(ansi reset)"
        return
    }

    for f in $captures {
        print $"(ansi attr_dimmed)Updating ($f | path basename)…(ansi reset)"
        dotnu embeds-update $f
        print $"(ansi green)✓(ansi reset) ($f | path basename)"
    }
}
