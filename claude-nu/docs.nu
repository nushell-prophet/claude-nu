# claude-nu docs - download Claude Code and Nushell documentation
#
# Lives apart from the session-reading commands: it fetches reference docs
# rather than parsing sessions. Import it on its own: `use claude-nu/docs.nu *`.

# Default output directory for Claude Code documentation
const CLAUDE_DOCS_DIR = 'claude-code-docs'

# Nushell documentation settings
const NUSHELL_DOCS_DIR = 'nushell-docs'
const NUSHELL_DOCS_REPO = 'https://github.com/nushell/nushell.github.io.git'
const NUSHELL_DOCS_FOLDERS = ['blog' 'book' 'cookbook']

# Download Claude Code documentation from sitemap
export def download-claude-docs [
    --output-dir: path = $CLAUDE_DOCS_DIR # Output directory for downloaded docs
]: nothing -> table {
    # Fetch and parse sitemap
    let sitemap_xml = http get https://code.claude.com/docs/sitemap.xml

    let urls = $sitemap_xml
        | get content.content
        | each { get content.0.content.0 }
        | where $it =~ 'docs/en/'
        | each { $in + '.md' }

    # Ensure output directory exists
    mkdir $output_dir

    # Download files in parallel
    $urls
    | par-each --threads 4 {|url|
        let filename = $url | path split | skip 4 | str join '_'
        let dest_path = [$output_dir $filename] | path join

        try {
            http get $url | save -f $dest_path
            {url: $url status: "ok" dest: $dest_path error: null}
        } catch {|e|
            {url: $url status: "failed" dest: $dest_path error: ($e.msg? | default "unknown error")}
        }
    }
}

# Download Claude Code documentation pages from the sitemap, print results, and optionally commit
@example "Fetch docs" { fetch-claude-docs }
@example "Fetch and commit" { fetch-claude-docs --commit }
export def fetch-claude-docs [
    --commit # Create a git commit after downloading
]: nothing -> nothing {
    let results = download-claude-docs

    # Print results
    $results | each {|r|
        let icon = if $r.status == "ok" { $"(ansi green)✓(ansi reset)" } else { $"(ansi red)✗(ansi reset)" }
        print $"($icon) ($r.url)"
    }

    # Summary
    let ok = $results | where status == "ok" | length
    let failed = $results | where status == "failed" | length
    print $"\n(ansi green_bold)($ok) ok(ansi reset), (ansi red_bold)($failed) failed(ansi reset)"

    if $commit {
        # Stage and commit if there are changes
        let status = git status --porcelain $CLAUDE_DOCS_DIR | str trim
        if $status != "" {
            git add $CLAUDE_DOCS_DIR
            let date = date now | format date "%Y-%m-%d"
            git commit -m $"docs: update claude-code-docs \(($date)\)"
            print $"(ansi green)Committed documentation updates(ansi reset)"
        } else {
            print $"(ansi attr_dimmed)No changes to commit(ansi reset)"
        }
    }
}

# Fetch Nushell documentation (book, cookbook, blog) via shallow sparse checkout
@example "Fetch/update Nushell docs" { fetch-nushell-docs }
export def fetch-nushell-docs []: nothing -> nothing {
    let dest = $NUSHELL_DOCS_DIR

    if ($dest | path exists) {
        # Update existing checkout
        print $"(ansi attr_dimmed)Updating nushell-docs...(ansi reset)"
        cd $dest
        git pull
        cd -
    } else {
        # Fresh shallow sparse clone
        print $"(ansi attr_dimmed)Cloning nushell.github.io \(shallow sparse\)...(ansi reset)"
        git clone --depth 1 --filter=blob:none --sparse $NUSHELL_DOCS_REPO $dest
        cd $dest
        git sparse-checkout set --no-cone ...($NUSHELL_DOCS_FOLDERS | each { $'/($in)/*' })
        cd -
    }

    # Show what we have
    let sizes = $NUSHELL_DOCS_FOLDERS
        | each {|f| {folder: $f size: (du $"($dest)/($f)" | get apparent | first)} }

    print ""
    print ($sizes | table)
    print $"\n(ansi green)✓(ansi reset) Nushell docs ready at (ansi cyan)($dest)/(ansi reset)"
}
