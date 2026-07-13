# Claude-authorship of a git repo, two ways.
#
# Two different questions, two different mechanics:
#   commits           -> FLOW: per-commit table; --by-month rolls up Claude's share of commits each month (by count).
#   code-authorship   -> STOCK: what share of the lines that survive TODAY were last touched by Claude.
#
# Caveats the numbers carry:
#   - Classification floor: commits with no Claude marker at all read as human. Early history undercounts.
#   - code-authorship uses `git blame` = LAST commit to touch a line, not who first wrote it.
#     One human character-edit on a Claude line flips that line to human. It is an approximation.

# One classification rule, shared by both metrics.
# Why union of two signals: a repo can mark Claude two ways across its history —
# author email claude@anthropic.com OR a Co-Authored-By trailer (noreply@anthropic.com)
# on commits authored under a human's name. Email alone or trailer alone each miss a
# large slice. Binary: shared (co-authored) commits count as Claude.
def is-claude [email: string, body: string]: nothing -> bool {
    $email == 'claude@anthropic.com' or ($body | str contains 'noreply@anthropic.com')
}

# FLOW metric. Default: one row per commit with an is_claude flag — every other cut
# is a pipeline on top. --by-month: Claude's share of commits per author-date month.
# Why --no-merges: a merge authors no content of its own; counting it double-counts its parents.
export def commits [
    --by-month # Roll up to { month, total, claude, pct } instead of the per-commit table
]: nothing -> table {
    let base = (
        ^git log --no-merges $"--format=%H%x1f%aI%x1f%aE%x1f%b%x1e"
        | split row (char record_sep)
        | where ($it | str trim | is-not-empty)
        | each { |raw|
            let f = $raw | str trim | split row (char unit_sep)
            {
                sha: $f.0
                date: ($f.1 | into datetime)
                email: $f.2
                is_claude: (is-claude $f.2 ($f.3? | default ''))
            }
        }
    )
    if not $by_month { return $base }

    $base
    | insert month { $in.date | format date '%Y-%m' }
    | group-by month
    | items { |month, rows|
        { month: $month, total: ($rows | length), claude: ($rows | where is_claude | length) }
    }
    | insert pct { (($in.claude * 100 / $in.total) | math round) }
    | sort-by month
}

# sha -> is_claude for ALL commits (merges included: blame can point at any commit).
def commit-class []: nothing -> record {
    ^git log $"--format=%H%x1f%aE%x1f%b%x1e"
    | split row (char record_sep)
    | where ($it | str trim | is-not-empty)
    | reduce --fold {} { |raw, acc|
        let f = $raw | str trim | split row (char unit_sep)
        $acc | insert $f.0 (is-claude $f.1 ($f.2? | default ''))
    }
}

# STOCK metric: of the lines living in the tree now, what share trace to a Claude commit.
# Binary files contribute nothing: their blame output has no 40-hex line headers to match, so they drop out.
export def code-authorship []: nothing -> record {
    let class = commit-class
    let shas = ^git ls-files
        | lines
        | par-each { |file|
            ^git blame --line-porcelain -- $file
            | lines
            | where $it =~ '^[0-9a-f]{40} '
            | each { split row ' ' | first }
        }
        | flatten
    let total = $shas | length
    # Why guard: an empty/committed-nothing repo yields 0 lines; the pct divide would fail on it.
    if $total == 0 { error make { msg: "no tracked lines to attribute (empty repo or run from a repo root)" } }
    let claude = $shas | where {|s| $class | get -o $s | default false } | length
    { total_lines: $total, claude_lines: $claude, pct: (($claude * 100 / $total) | math round) }
}
