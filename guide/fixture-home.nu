# A throwaway HOME for the guide: the test fixtures laid out as one Claude Code
# project store, so every chapter runs on the same five sessions on any machine.
# Why not the real ~/.claude: the output would change on every run, and it
# would put private transcripts into a tracked file.
# The store sits under the name Claude Code gives the guide directory itself,
# so a bare call (no input = the current project) reads it.

const FIXTURES = path self ../tests/fixtures/sessions
# Why a second store: the shared fixtures hold one plain subagent and no
# Workflow run, so the agents chapter needs this small project instead. It
# takes the same place, so its calls stay bare like every other chapter's.
const WORKFLOW_FIXTURES = path self ../tests/fixtures/workflows/-fixture-project

export def --env main [
    --workflows # Lay out the Workflow-run fixture project instead of the five sessions
]: nothing -> nothing {
    let home = mktemp --directory --tmpdir claude-nu-guide-XXXXXX
    let store = $home | path join .claude projects ($env.PWD | str replace --all '/' '-')
    mkdir $store
    ls (if $workflows { $WORKFLOW_FIXTURES } else { $FIXTURES }) | get name | each {|p| cp --recursive $p $store } | ignore
    # Why: sessions list newest first by file mtime, and a copy (or a git
    # checkout) stamps every file with the same moment — so each file gets the
    # time of its own last record, and the order is the same on every run.
    glob ($store | path join **/*.jsonl) | each {|f|
        let last = open --raw $f | from json --objects | get timestamp --optional | compact | last
        # Why the skip: a workflow's `journal.jsonl` carries no timestamp.
        if $last != null { touch --modified --timestamp ($last | into datetime) $f }
    } | ignore
    $env.HOME = $home
}
