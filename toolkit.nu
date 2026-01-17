const sitemap_csv = 'urls-from-sitemap.csv'
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
    --skip-sitemap # Skip refreshing the sitemap before downloading
    --no-commit    # Skip creating a git commit after downloading
] {
    if not $skip_sitemap { fetch-sitemap }

    open $sitemap_csv
    | get url
    | par-each --threads 4 {|url|
        let filename = $url | path split | skip 4 | str join '_'
        let dest_path = [$output_dir $filename] | path join

        try {
            http get $url | save -f $dest_path
            print $"($url) ok"
        } catch {
            print $"($url) failed"
        }
    }

    if not $no_commit {
        # Stage and commit if there are changes
        let status = git status --porcelain $output_dir $sitemap_csv | str trim
        if $status != "" {
            git add $output_dir $sitemap_csv
            let date = date now | format date "%Y-%m-%d"
            git commit -m $"docs: update claude-code-docs \(($date)\)"
            print $"(ansi green)Committed documentation updates(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}

# Fetch and parse sitemap.xml, saving English docs URLs to CSV
def fetch-sitemap [] {
    let sitemap_xml = http get https://code.claude.com/docs/sitemap.xml

    $sitemap_xml
    | get content.content
    | each {
        get content
        | each { $in.content.0 }
    }
    | each {|entry|
        {url: $entry.0, ts: $entry.1?}
    }
    | where url =~ 'docs/en/'
    | update url { $in + '.md' }
    | save -f $sitemap_csv
}
