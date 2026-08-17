#!/usr/bin/env nu
# Format-drift detector for claude-nu.
#
# claude-nu parses Claude Code's transcript files. Claude Code ships several
# times a week and changes that format without notice, so the module's readers
# go stale silently: a renamed field leaves a column empty, a new content block
# renders as "", a new user-message wrapper gets counted as a human turn. None
# of that raises an error, and the unit tests still pass — they run on fixtures
# frozen at the version they were written for.
#
# So this driver checks the module against the newest sessions on disk instead
# of against fixtures. Three passes:
#
#   shapes  — every record type, content block, tool name, usage field and
#             user-message wrapper tag the newest sessions contain, compared
#             against known.nuon (the triaged baseline).
#   columns — `sessions --all-columns` over the same window, reporting each
#             column's blank rate. A column blank in every recent session is a
#             reader that has stopped reading.
#   smoke   — every read-only public command, run for real.
#
# Drift is reported in three directions, all actionable:
#   new   — the sessions hold something the baseline never saw. Triage it into
#           known.nuon.
#   dead  — the baseline says the code handles something no recent session
#           produces. Delete that reader. Backward compatibility is explicitly
#           not a goal: claude-nu reads the transcripts of the Claude Code you
#           are running, not of the ones you used to run.
#   todo  — triaged, understood, not yet fixed. Reported until it is.

const REPO = path self ../../..
const KNOWN_FILE = path self known.nuon

use ($REPO | path join claude-nu)
use ($REPO | path join claude-nu discovery.nu) [read-session-records]
use ($REPO | path join claude-nu render.nu) [content-blocks]
use ($REPO | path join claude-nu extract.nu) [extract-text-content is-user-text]

# Session files across every project, newest first. One `ls` glob does the whole
# walk — the corpus runs to thousands of files, and stat-ing them one at a time
# costs more than parsing the window afterwards.
export def latest-files [window: int]: nothing -> list<path> {
    ls (($env.HOME | path join .claude projects '**' '*.jsonl') | into glob)
    | sort-by modified --reverse
    | get name
    | if ($in | length) > $window { first $window } else { }
}

# Decode every record in the window. A file that fails to parse yields nothing
# rather than killing the run — a session being written to right now can end
# mid-line.
export def read-window [files: list<path>]: nothing -> table {
    $files | each {|f| try { $f | read-session-records } catch { [] } } | flatten
}

# True when a value carries no information: null, blank string, empty
# list/record, zero, false. Records recurse, so a token_usage of all zeros reads
# as blank — that is exactly the shape a stale reader leaves behind.
export def is-blank []: any -> bool {
    let v = $in
    match ($v | describe | split row '<' | first) {
        "nothing" => true
        "string" => ($v | str trim | is-empty)
        "list" | "table" => ($v | is-empty)
        "record" => ($v | values | all { is-blank })
        "int" | "float" => ($v == 0)
        "bool" => (not $v)
        _ => false
    }
}

# Count occurrences of each distinct value, most frequent first.
def tally []: list -> table {
    compact | uniq --count | sort-by count --reverse | rename value count
}

# Every format fact the window contains, as {category, value, count} rows.
# Read from the raw records, not through the module's extractors: the module is
# what is under test, so it cannot also be the instrument.
export def observe [records: table]: nothing -> table {
    let blocks = $records | each {|r| $r.message?.content? | content-blocks } | flatten

    # Why the module's renderer here, unlike everywhere else: a wrapper tag only
    # matters if it survives into the text `messages` hands back, and the
    # renderer is what decides that. Raw content would also count tags quoted
    # inside a message a human really typed.
    let user_tags = $records
        | where type? == "user"
        | each {|r| $r | extract-text-content }
        | where {|t| $t | str starts-with '<' }
        | parse --regex '^<(?<tag>[a-zA-Z][a-zA-Z0-9-]*)'
        | get tag

    [
        [category values];
        [record_types ($records | get type --optional)]
        [content_blocks ($blocks | get type --optional)]
        # Why MCP tools collapse to one class: their names are
        # `mcp__<server>__<tool>` and depend on which servers the user has
        # connected, so listing them individually would report a fresh batch of
        # `new` rows on every machine and never settle.
        [tool_names ($blocks
            | where type? == "tool_use"
            | get name --optional
            | each {|n| if ($n | str starts-with "mcp__") { "mcp__*" } else { $n } })]
        [usage_fields ($records | get message.usage --optional | compact | each { columns } | flatten)]
        [user_tags $user_tags]
    ]
    | each {|row| $row.values | tally | insert category $row.category }
    | flatten
    | move category --before value
}

# Compare the window against the triaged baseline, in all three directions.
# `rare` entries are exempt from the dead check: they are real but infrequent,
# and a small window is expected to miss them.
export def compare [observed: table, known: record]: nothing -> table {
    # Why the categories come from `observed`, not from `known`: known.nuon also
    # carries expected_blank_columns, which is a different kind of fact and has
    # no observations to compare against.
    $observed
    | get category
    | uniq
    | each {|cat|
        let baseline = $known | get $cat | transpose value meta
        let seen = $observed | where category == $cat
        let seen_values = $seen | get value
        let known_values = $baseline | get value
        let status = {|value| $baseline | where value == $value | get 0.meta.status }
        let note = {|value| $baseline | where value == $value | get 0.meta.note }

        let new = $seen
            | where value not-in $known_values
            | each {|r| {category: $cat value: $r.value count: $r.count drift: new note: "not in known.nuon — triage it"} }

        let dead = $baseline
            | where value not-in $seen_values and meta.status == "handled"
            | each {|r| {category: $cat value: $r.value count: 0 drift: dead note: $r.meta.note} }

        let todo = $seen
            | where value in $known_values
            | where {|r| (do $status $r.value) == "todo" }
            | each {|r| {category: $cat value: $r.value count: $r.count drift: todo note: (do $note $r.value)} }

        [$new $dead $todo] | flatten
    }
    | flatten
}

# Does the code still classify each wrapper tag the way the baseline records?
# The baseline's `drops` field says whether SYSTEM_PREFIXES should swallow the
# tag; is-user-text is the code's actual answer. They disagree when someone edits
# one without the other — which is how a wrapper starts counting as a human turn.
export def tag-check [observed: table, known: record]: nothing -> table {
    let seen = $observed | where category == user_tags | get value

    $known
    | get user_tags
    | transpose value meta
    | insert baseline_drops {|r| $r.meta.drops }
    | insert code_drops {|r| not ($"<($r.value)>" | is-user-text) }
    | where {|r| $r.baseline_drops != $r.code_drops }
    | insert in_window {|r| $r.value in $seen }
    | select value baseline_drops code_drops in_window
}

# Blank rate of every `sessions --all-columns` column over the window. A column
# at 100% is the silent failure this driver exists to catch: no error, no failing
# test, just a field that stopped arriving under the name the code reads.
export def column-health [files: list<path>]: nothing -> table {
    let rows = claude-nu sessions ...$files --all-columns
    let total = $rows | length
    $rows
    | columns
    | each {|col|
        let blank = $rows | get $col | where { is-blank } | length
        {
            column: $col
            rows: $total
            blank: $blank
            blank_pct: (if $total == 0 { 0 } else { $blank * 100 / $total | math round --precision 1 })
        }
    }
    | sort-by blank_pct --reverse
}

# Run every read-only public command for real. Not a substitute for the unit
# tests: those run on frozen fixtures, this runs on today's transcripts.
export def smoke [files: list<path>]: nothing -> table {
    let few = $files | first 3
    let checks = [
        [name closure];
        ["projects" {|| claude-nu projects | length }]
        ["sessions --all-columns" {|| claude-nu sessions ...$files --all-columns | length }]
        ["sessions | messages" {|| claude-nu sessions ...$files | claude-nu messages | length }]
        ["messages --include-responses" {|| claude-nu sessions ...$few | claude-nu messages --include-responses | length }]
        ["export-session" {|| claude-nu sessions ...$few | claude-nu export-session | str length }]
        ["commits --by-month" {|| cd $REPO; claude-nu commits --by-month | length }]
        ["code-authorship" {|| cd $REPO; claude-nu code-authorship | get pct }]
        ["gi" {|| cd $REPO; claude-nu gi | columns | length }]
    ]

    $checks | each {|c|
        let res = try {
            {ok: true result: (do $c.closure | into string)}
        } catch {|e|
            {ok: false result: ($e.msg | str trim)}
        }
        {command: $c.name ok: $res.ok result: $res.result}
    }
}

# Re-verify claude-nu against the newest Claude Code sessions on disk.
def main [
    --window: int = 40 # How many of the newest session files to read
    --json # Machine-readable output, for agents and CI
    --fail # Exit non-zero when anything needs attention
]: nothing -> any {
    let files = latest-files $window
    if ($files | is-empty) {
        error make --unspanned {msg: $"No session files under ($env.HOME | path join .claude projects)"}
    }

    let known = open $KNOWN_FILE
    let records = read-window $files
    let observed = observe $records
    let drift = compare $observed $known
    let tags = tag-check $observed $known
    let columns = column-health $files
    let checks = smoke $files

    # Why the exemption list: a column can be legitimately blank across a whole
    # window (no subagents ran, nobody used plan mode). Those are named in
    # known.nuon so the ones left over are all real.
    let expected_blank = $known.expected_blank_columns | columns
    let blank = $columns | where blank_pct == 100 and column not-in $expected_blank
    let broken = $checks | where ok == false
    let report = {
        window: {
            files: ($files | length)
            records: ($records | length)
            claude_version: (try { ^claude --version | split row ' ' | first } catch { "unknown" })
            session_versions: ($records | get version --optional | tally)
        }
        drift: $drift
        tag_mismatches: $tags
        blank_columns: $blank
        smoke_failures: $broken
        columns: $columns
        smoke: $checks
        observed: $observed
    }

    # Why serialized here rather than returned as a value: this driver is run as
    # a script from a shell, where a returned record renders as a display table
    # that no agent can parse back.
    if $json { return ($report | to json) }

    print $"claude ($report.window.claude_version) — newest ($report.window.files) session files, ($report.window.records) records"
    print $"session versions in window: ($report.window.session_versions | each {|r| $"($r.value) x($r.count)" } | str join ', ')"

    print "\n── drift ──"
    if ($drift | is-empty) { print "none" } else { print ($drift | table --expand) }

    print "\n── tag classification vs is-user-text ──"
    if ($tags | is-empty) { print "agrees" } else { print $tags }

    print "\n── columns blank in every session of the window ──"
    if ($blank | is-empty) { print "none" } else { print $blank }

    print "\n── smoke ──"
    if ($broken | is-empty) {
        print $"all ($checks | length) commands ran"
    } else {
        print $broken
    }

    if $fail and (($drift | is-not-empty) or ($tags | is-not-empty) or ($blank | is-not-empty) or ($broken | is-not-empty)) {
        exit 1
    }
}
