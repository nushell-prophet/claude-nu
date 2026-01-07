const sitemap_csv = 'urls-from-sitemap.csv'
const output_dir = 'claude-code-docs'

# Download Claude Code documentation pages from the sitemap
export def fetch-claude-docs [
    --skip-sitemap # Skip refreshing the sitemap before downloading
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
