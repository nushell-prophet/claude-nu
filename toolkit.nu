const output_dir = 'claude-code-docs'
const skills_global_dir = '~/.claude/skills'
const skills_local_dir = 'skills'
const managed_skills = ['nushell-style' 'nushell-completions']
const nushell_docs_dir = 'nushell-docs'
const nushell_docs_repo = 'https://github.com/nushell/nushell.github.io.git'
const nushell_docs_folders = ['blog' 'book' 'cookbook']
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
export def 'main fetch-claude-docs' [
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

        if ($dest | path exists) { rm -rf $dest }
        cp -r $source $dest
        let file_count = glob $"($dest)/**/*" | where ($it | path type) == 'file' | length
        print $"(ansi green)✓(ansi reset) ($skill) \(($file_count) files\)"
        $total_files = $total_files + $file_count
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
@example "Force overwrite uncommitted changes" { nu toolkit.nu install-skills-globally --force }
export def 'main install-skills-globally' [
    --force # Overwrite even if destination has uncommitted changes
] {
    let global_dir = $skills_global_dir | path expand
    let local_dir = $skills_local_dir

    if not $force {
        let dirty = $managed_skills
        | each { $"($global_dir)/($in)" }
        | where { has-uncommitted-changes $in }
        if ($dirty | is-not-empty) {
            print $"(ansi yellow)⚠(ansi reset) Uncommitted changes in destination:"
            $dirty | each { print $"  ($in)" }
            print $"\n  Use (ansi cyan)--force(ansi reset) to overwrite"
            return
        }
    }

    mut total_files = 0

    for skill in $managed_skills {
        let source = $"($local_dir)/($skill)"
        let dest = $"($global_dir)/($skill)"

        if not ($source | path exists) {
            print $"(ansi yellow)⚠(ansi reset) ($skill): not found at ($source)"
            continue
        }

        if ($dest | path exists) { rm -rf $dest }
        cp -r $source $dest
        let file_count = glob $"($dest)/**/*" | where ($it | path type) == 'file' | length
        print $"(ansi green)✓(ansi reset) ($skill) \(($file_count) files\)"
        $total_files = $total_files + $file_count
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
        git sparse-checkout set --no-cone ...($nushell_docs_folders | each { $'/($in)/*' })
        cd -
    }

    # Show what we have
    let sizes = $nushell_docs_folders
    | each {|f| {folder: $f size: (du $"($dest)/($f)" | get apparent | first)} }

    print ""
    print ($sizes | table)
    print $"\n(ansi green)✓(ansi reset) Nushell docs ready at (ansi cyan)($dest)/(ansi reset)"
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
