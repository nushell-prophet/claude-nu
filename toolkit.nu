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
@example "Run tests interactively" { nu toolkit.nu test }
@example "Run tests for CI" { nu toolkit.nu test --fail }
@example "Output JSON for tooling" { nu toolkit.nu test --json }
export def 'main test' [
    --json # output results as JSON for external consumption
    --fail # exit with non-zero code if any tests fail (for CI)
] {
    if not $json { print $"(ansi attr_dimmed)Unit tests(ansi reset)" }
    let results = main test-unit --json=$json

    # Parse JSON if needed
    let results_data = if $json { $results | from json } else { $results }

    # Print summary
    let passed = $results_data | where status == 'passed' | length
    let failed = $results_data | where status == 'failed' | length
    let total = $results_data | length

    if not $json {
        print ""
        print $"(ansi green_bold)($passed) passed(ansi reset), (ansi red_bold)($failed) failed(ansi reset) \(($total) total\)"
    }

    if $fail and $failed > 0 {
        if $json { print ($results_data | to json --raw) }
        exit 1
    }

    if $json { $results_data | to json --raw }
}

# Run unit tests using nutest
@example "Run unit tests" { nu toolkit.nu test-unit }
export def 'main test-unit' [
    --json # output results as JSON for external consumption
] {
    let nutest_path = find-nutest
    if $nutest_path == null {
        print $"(ansi red)✗(ansi reset) nutest not found in NU_LIB_DIRS or at ../nutest"
        print $"  Install: (ansi attr_dimmed)git clone https://github.com/vyadh/nutest ../nutest(ansi reset)"
        if $json { return '[]' } else { return [] }
    }

    let tests_path = 'tests' | path expand
    let result = do {
        ^nu -c $"use ($nutest_path); nutest run-tests --path ($tests_path) --returns table --display nothing | to json --raw"
    } | complete

    if $result.exit_code != 0 {
        print $"(ansi red)✗(ansi reset) nutest failed"
        if ($result.stderr | str trim | is-not-empty) { print $result.stderr }
        if $json { return '[]' } else { return [] }
    }

    let flat = $result.stdout
    | from json
    | each {|row|
        let status = if $row.result == 'PASS' { 'passed' } else { 'failed' }
        {type: 'unit' name: $row.test status: $status file: null}
    }

    if not $json {
        $flat | each {|r| print-test-result $r }
    }

    if $json { $flat | to json --raw } else { $flat }
}

# Print a single test result with status indicator
def print-test-result [result: record] {
    let icon = match $result.status {
        'passed' => $"(ansi green)✓(ansi reset)"
        'failed' => $"(ansi red)✗(ansi reset)"
        _ => "?"
    }
    let suffix = if $result.file != null { $" (ansi attr_dimmed)\(($result.file)\)(ansi reset)" } else { "" }
    print $"  ($icon) ($result.name)($suffix)"
}

# Download Claude Code documentation pages from the sitemap
@example "Fetch docs" { nu toolkit.nu fetch-claude-docs }
@example "Fetch and commit" { nu toolkit.nu fetch-claude-docs --commit }
export def 'main fetch-claude-docs' [
    --commit # Create a git commit after downloading
] {
    use claude-nu
    claude-nu fetch-claude-docs --commit=$commit
}

# Fetch Nushell documentation (book, cookbook, blog) via shallow sparse checkout
@example "Fetch/update Nushell docs" { nu toolkit.nu fetch-nushell-docs }
export def 'main fetch-nushell-docs' [] {
    use claude-nu
    claude-nu fetch-nushell-docs
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
    use claude-nu

    let sessions_dir = claude-nu get-sessions-dir
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
@example "Check a file" { nu toolkit.nu check commands.nu }
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
