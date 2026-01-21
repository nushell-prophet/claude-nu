const output_dir = 'claude-code-docs'

export def main [] { }

# Run all tests
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
export def 'main test-unit' [
    --json # output results as JSON for external consumption
] {
    use ../nutest/nutest

    # Get detailed table from nutest
    let results = nutest run-tests --path tests/ --returns table --display nothing

    # Convert to flat table format
    let flat = $results
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
export def fetch-claude-docs [
    --no-commit # Skip creating a git commit after downloading
] {
    use claude-nu

    let results = claude-nu download-documentation --output-dir $output_dir

    # Print results
    $results | each {|r|
        let icon = if $r.status == "ok" { $"(ansi green)✓(ansi reset)" } else { $"(ansi red)✗(ansi reset)" }
        print $"($icon) ($r.url)"
    }

    # Summary
    let ok = $results | where status == "ok" | length
    let failed = $results | where status == "failed" | length
    print $"\n(ansi green_bold)($ok) ok(ansi reset), (ansi red_bold)($failed) failed(ansi reset)"

    if not $no_commit {
        # Stage and commit if there are changes
        let status = git status --porcelain $output_dir | str trim
        if $status != "" {
            git add $output_dir
            let date = date now | format date "%Y-%m-%d"
            git commit -m $"docs: update claude-code-docs \(($date)\)"
            print $"(ansi green)Committed documentation updates(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}
