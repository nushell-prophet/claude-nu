const output_dir = 'claude-code-docs'
const skills_global_dir = '~/.claude/skills'
const skills_local_dir = 'skills'
const managed_skills = ['nushell-style' 'nushell-completions']
const nushell_docs_dir = 'nushell-docs'
const nushell_docs_repo = 'https://github.com/nushell/nushell.github.io.git'
const nushell_docs_folders = ['blog' 'book' 'cookbook']

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
@example "Fetch and commit docs" { nu toolkit.nu fetch-claude-docs }
@example "Fetch without committing" { nu toolkit.nu fetch-claude-docs --no-commit }
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

# Vendor managed skills from ~/.claude/skills into this repo
@example "Vendor all skills with auto-commit" { nu toolkit.nu vendor-skills }
@example "Vendor skills without committing" { nu toolkit.nu vendor-skills --no-commit }
export def 'main vendor-skills' [
    --no-commit # Skip creating a git commit after copying
] {
    let global_dir = $skills_global_dir | path expand
    let local_dir = $skills_local_dir
    mut total_files = 0

    for skill in $managed_skills {
        let source = $"($global_dir)/($skill)"
        let dest = $"($local_dir)/($skill)"

        if not ($source | path exists) {
            print $"(ansi yellow)⚠(ansi reset) ($skill): not found at ($source)"
            continue
        }

        mkdir $dest
        let files = glob $"($source)/*.md"
        $files | each {|f|
            let name = $f | path basename
            cp $f $"($dest)/($name)"
            print $"(ansi green)✓(ansi reset) ($skill)/($name)"
        }
        $total_files = $total_files + ($files | length)
    }

    print $"\n(ansi attr_dimmed)Copied ($total_files) files to ($local_dir)(ansi reset)"

    if not $no_commit {
        let status = git status --porcelain $local_dir | str trim
        if $status != "" {
            git add $local_dir
            let date = date now | format date "%Y-%m-%d"
            git commit -m $"chore: vendor skills \(($date)\)"
            print $"(ansi green)Committed skill updates(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}

# Install managed skills to ~/.claude/skills (reverse of vendor-skills)
@example "Install all skills globally" { nu toolkit.nu install-skills-globally }
export def 'main install-skills-globally' [] {
    let global_dir = $skills_global_dir | path expand
    let local_dir = $skills_local_dir
    mut total_files = 0

    for skill in $managed_skills {
        let source = $"($local_dir)/($skill)"
        let dest = $"($global_dir)/($skill)"

        if not ($source | path exists) {
            print $"(ansi yellow)⚠(ansi reset) ($skill): not found at ($source)"
            continue
        }

        mkdir $dest
        let files = glob $"($source)/*.md"
        $files | each {|f|
            let name = $f | path basename
            cp $f $"($dest)/($name)"
            print $"(ansi green)✓(ansi reset) ($skill)/($name)"
        }
        $total_files = $total_files + ($files | length)
    }

    print $"\n(ansi attr_dimmed)Installed ($total_files) files to ($global_dir)(ansi reset)"
    print $"(ansi green)✓(ansi reset) Skills ready at (ansi cyan)($global_dir)(ansi reset)"
}

# Fetch Nushell documentation (book, cookbook, blog) via shallow sparse checkout
@example "Fetch/update Nushell docs" { nu toolkit.nu fetch-nushell-docs }
export def 'main fetch-nushell-docs' [] {
    let dest = $nushell_docs_dir

    if ($dest | path exists) {
        # Update existing checkout
        print $"(ansi attr_dimmed)Updating nushell-docs...(ansi reset)"
        cd $dest
        git pull
        cd -
    } else {
        # Fresh shallow sparse clone
        print $"(ansi attr_dimmed)Cloning nushell.github.io \(shallow sparse\)...(ansi reset)"
        git clone --depth 1 --filter=blob:none --sparse $nushell_docs_repo $dest
        cd $dest
        git sparse-checkout set ...$nushell_docs_folders
        cd -
    }

    # Show what we have
    let sizes = $nushell_docs_folders
    | each {|f| {folder: $f size: (du $"($dest)/($f)" | get apparent | first)} }

    print ""
    print ($sizes | table)
    print $"\n(ansi green)✓(ansi reset) Nushell docs ready at (ansi cyan)($dest)/(ansi reset)"
}
