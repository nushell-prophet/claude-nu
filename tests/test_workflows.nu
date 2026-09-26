use std/assert
use std/testing *

# Import all functions from sessions.nu (including internals not re-exported via mod.nu)
use ../claude-nu/sessions.nu *
# The module entry point, so `claude-nu workflows` is callable as users call it.
use ../claude-nu

# Invented fixture project: session ...0001 ran two workflows — one completed,
# one whose state carries only an `error` — and has a plain subagent and three
# workflow agents; session ...0002 ran none.
const FIXTURE_PROJECT = path self fixtures/workflows/-fixture-project
const FIXTURE_WF_SESSION = '5a5a5a5a-0000-4000-8000-000000000001'
const FIXTURE_PLAIN_SESSION = '5a5a5a5a-0000-4000-8000-000000000002'

def fixture-session [uuid: string]: nothing -> path {
    $FIXTURE_PROJECT | path join $"($uuid).jsonl"
}

# The fixture project under a fake home, with session ...0000 resumed from
# ...0001 the way Claude Code lays it out: its `subagents/` holds a symlink to
# the first session's plain agent transcript and one to its whole workflow
# directory.
const RESUMED_SESSION = '5a5a5a5a-0000-4000-8000-000000000000'

def resumed-store []: nothing -> record {
    let home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let project = $home | path join ".claude" "projects" "-fixture-project"
    mkdir ($project | path dirname)
    # Why the external cp: with this third in-process `cp --recursive` of the
    # fixture, parallel tests left another test's copy of a state file with its
    # bytes shifted (4 runs of 6); with `^cp` none did in 10.
    ^cp --recursive $FIXTURE_PROJECT $project
    cp ($project | path join $"($FIXTURE_PLAIN_SESSION).jsonl") ($project | path join $"($RESUMED_SESSION).jsonl")
    let real = $project | path join $FIXTURE_WF_SESSION subagents
    let linked = $project | path join $RESUMED_SESSION subagents
    mkdir ($linked | path join workflows)
    ^ln --symbolic ($real | path join agent-b1111111111111111.jsonl) ($linked | path join agent-b1111111111111111.jsonl)
    ^ln --symbolic ($real | path join workflows wf_aaaa1111-001) ($linked | path join workflows wf_aaaa1111-001)
    {home: $home project: $project}
}

# =============================================================================
# Tests for `claude-nu workflows`
# =============================================================================

@test
def "workflows lists one row per run of a piped session" [] {
    let rows = {path: (fixture-session $FIXTURE_WF_SESSION)} | claude-nu workflows
    assert equal ($rows | get id) [wf_aaaa1111-001 wf_bbbb2222-002]
    assert equal ($rows | get session | uniq) [$FIXTURE_WF_SESSION]
}

@test
def "workflows reads status, duration, agents and phases from the state file" [] {
    let run = {path: (fixture-session $FIXTURE_WF_SESSION)} | claude-nu workflows | where id == wf_aaaa1111-001 | first
    assert equal $run.status completed
    assert equal $run.agent_count 2
    assert equal $run.duration 5min
    assert equal $run.error null
    assert equal $run.name fixture-review
    assert equal $run.phases [Review Verify]
    assert equal $run.started ('2026-09-01T10:00:00Z' | into datetime)
    assert equal $run.project_name fixture/project
    assert equal ($run.agents | get agent_id) [agent-a1111111111111111 agent-a2222222222222222]
    assert equal ($run.agents | get label) ["review:scope" "verify:scope"]
    assert equal ($run.agents | get phase) [Review Verify]
}

@test
def "workflows reads a state with an error and no status as failed" [] {
    # Why: Claude Code's own reader of the state file makes the same call, so a
    # run that failed before a status was written must not read as completed.
    let run = {path: (fixture-session $FIXTURE_WF_SESSION)} | claude-nu workflows | where id == wf_bbbb2222-002 | first
    assert equal $run.status failed
    assert equal $run.error "agent budget exceeded"
    assert equal $run.phases []
    assert equal ($run.agents | get state) [error]
}

@test
def "workflows yields nothing for a session that ran none" [] {
    let rows = {path: (fixture-session $FIXTURE_PLAIN_SESSION)} | claude-nu workflows
    assert equal $rows []
}

@test
def "workflows reads every session of a piped project row" [] {
    let rows = {path: $FIXTURE_PROJECT} | claude-nu workflows
    assert equal ($rows | length) 2
}

@test
def "workflows maps a piped subagent transcript to its parent session once" [] {
    # Why: a run belongs to the session that launched it, so a session piped
    # together with its own subagents must not list each run twice.
    let agent = $FIXTURE_PROJECT | path join $FIXTURE_WF_SESSION subagents agent-b1111111111111111.jsonl
    let rows = [(fixture-session $FIXTURE_WF_SESSION) $agent] | claude-nu workflows
    assert equal ($rows | get id) [wf_aaaa1111-001 wf_bbbb2222-002]
}

# `resumed-store` with the state of run wf_aaaa1111-001 moved into the resumed
# session, where Claude Code writes it when the run finishes there.
def resumed-run-store []: nothing -> record {
    let store = resumed-store
    let state_dir = $store.project | path join $RESUMED_SESSION workflows
    mkdir $state_dir
    mv ($store.project | path join $FIXTURE_WF_SESSION workflows wf_aaaa1111-001.json) $state_dir
    $store
}

@test
def "workflows lists a resumed run under the session that started it" [] {
    let store = resumed-run-store

    let rows = {path: ($store.project | path join $"($FIXTURE_WF_SESSION).jsonl")} | claude-nu workflows

    rm --recursive --force $store.home

    assert equal ($rows | get id) [wf_aaaa1111-001 wf_bbbb2222-002]
    assert equal ($rows | get 0.state_file) ($store.project | path join $RESUMED_SESSION workflows wf_aaaa1111-001.json)
}

@test
def "workflows finds a resumed run from a piped agent transcript" [] {
    # Why: an agent row stands for its session, and the agent's own
    # `workflow` column already names the run through the same lookup.
    let store = resumed-run-store
    let agent = $store.project | path join $FIXTURE_WF_SESSION subagents workflows wf_aaaa1111-001 agent-a1111111111111111.jsonl

    let rows = [$agent] | claude-nu workflows

    rm --recursive --force $store.home

    assert ("wf_aaaa1111-001" in ($rows | get id))
}

@test
def "workflows lists a resumed run once across the project" [] {
    let store = resumed-run-store

    let rows = {path: $store.project} | claude-nu workflows

    rm --recursive --force $store.home

    assert equal ($rows | get id | sort) [wf_aaaa1111-001 wf_bbbb2222-002]
}

@test
def "workflows names the launching session of a resumed run in either input order" [] {
    # Why both orders: both sessions list the run, and the row kept once is
    # the last in input order — the launching session must not depend on it.
    let store = resumed-run-store
    let started = $store.project | path join $"($FIXTURE_WF_SESSION).jsonl"
    let resumed = $store.project | path join $"($RESUMED_SESSION).jsonl"

    let forward = [$started $resumed] | claude-nu workflows | where id == wf_aaaa1111-001 | get session
    let backward = [$resumed $started] | claude-nu workflows | where id == wf_aaaa1111-001 | get session

    rm --recursive --force $store.home

    assert equal $forward [$FIXTURE_WF_SESSION]
    assert equal $backward [$FIXTURE_WF_SESSION]
}

@test
def "workflows names the missing parent of a piped agent transcript" [] {
    # Why: the runs are read through the parent's transcript, so a parent that
    # is gone has to be named as such, not surface as an io error inside a reader.
    let project = $nu.temp-dir | path join $"wf-project-(random uuid)"
    cp --recursive $FIXTURE_PROJECT $project
    let parent = $project | path join $"($FIXTURE_WF_SESSION).jsonl"
    rm $parent
    let agent = $project | path join $FIXTURE_WF_SESSION subagents agent-b1111111111111111.jsonl

    let msg = try { [$agent] | claude-nu workflows; "no error" } catch {|e| $e.msg }

    rm --recursive --force $project

    assert equal $msg $"Session file not found: ($parent)"
}

@test
def "workflows rows carry no path column" [] {
    # Why: `path` makes a row a session selector, and a run piped on into
    # `messages` would then read its JSON state file as a transcript.
    let rows = {path: (fixture-session $FIXTURE_WF_SESSION)} | claude-nu workflows
    assert ("path" not-in ($rows | columns))
    assert ($rows | all {|r| $r.state_file | str ends-with $"($r.id).json" })
}

@test
def "workflows with no input reads the current project" [] {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $nu.temp-dir | path join $"fake-proj-(random uuid)"
    mkdir $proj_dir
    let encoded = $proj_dir | path expand | str replace --all '/' '-'
    let projects_dir = $fake_home | path join ".claude" "projects"
    mkdir $projects_dir
    cp --recursive $FIXTURE_PROJECT ($projects_dir | path join $encoded)

    let rows = with-env {HOME: $fake_home} { do { cd $proj_dir; claude-nu workflows } }

    rm --recursive --force $fake_home $proj_dir

    assert equal ($rows | get id) [wf_aaaa1111-001 wf_bbbb2222-002]
    assert equal ($rows | get project | uniq) [$encoded]
}

# =============================================================================
# Tests for the subagent identity columns of `sessions`
# =============================================================================

const IDENTITY_COLUMNS = 'agent_id,agent_type,workflow,agent_label,phase'

def identity-rows []: nothing -> table {
    null | sessions $FIXTURE_PROJECT --subagents --columns $IDENTITY_COLUMNS
}

@test
def "identity columns are not in the default set" [] {
    let cols = null | sessions $FIXTURE_PROJECT | columns
    for c in [agent_id agent_type workflow agent_label phase] {
        assert ($c not-in $cols)
    }
}

@test
def "identity columns are null on top-level rows" [] {
    let top = identity-rows | where parent_session_id == null
    assert equal ($top | length) 2
    for c in [agent_id agent_type workflow agent_label phase] {
        assert ($top | get $c | all { $in == null })
    }
}

@test
def "a plain subagent row names its id, type and label, and no workflow" [] {
    # Why: its session_id equals the parent's, so without these columns the row
    # cannot say which agent it is.
    let row = identity-rows | where agent_id == agent-b1111111111111111 | first
    assert equal $row.agent_type Explore
    assert equal $row.agent_label "Find stale references"
    assert equal $row.workflow null
    assert equal $row.phase null
}

@test
def "a workflow agent takes label and phase from its meta file" [] {
    # The state file says `verify:scope`; the meta file wins where it has one.
    let row = identity-rows | where agent_id == agent-a2222222222222222 | first
    assert equal $row.workflow wf_aaaa1111-001
    assert equal $row.agent_type workflow-subagent
    assert equal $row.agent_label "verify:scope-from-meta"
    assert equal $row.phase Verify
}

@test
def "a workflow agent with a bare meta file takes label and phase from the run state" [] {
    let row = identity-rows | where agent_id == agent-a1111111111111111 | first
    assert equal $row.workflow wf_aaaa1111-001
    assert equal $row.agent_label "review:scope"
    assert equal $row.phase Review
}

@test
def "a workflow agent the run state does not list keeps a null label" [] {
    let row = identity-rows | where agent_id == agent-a3333333333333333 | first
    assert equal $row.workflow wf_aaaa1111-001
    assert equal $row.agent_label null
    assert equal $row.phase null
}

@test
def "a workflow agent finds its run state in another session of the project" [] {
    # Why: a run resumed from another session writes its state there, while its
    # agents' transcripts stay under the session that started them.
    let project = $nu.temp-dir | path join $"wf-project-(random uuid)"
    cp --recursive $FIXTURE_PROJECT $project
    let other = $project | path join $FIXTURE_PLAIN_SESSION workflows
    mkdir $other
    mv ($project | path join $FIXTURE_WF_SESSION workflows wf_aaaa1111-001.json) $other

    let agent = $project | path join $FIXTURE_WF_SESSION subagents workflows wf_aaaa1111-001 agent-a1111111111111111.jsonl
    let row = null | sessions $agent --columns $IDENTITY_COLUMNS | first

    rm --recursive --force $project

    assert equal $row.agent_label "review:scope"
    assert equal $row.phase Review
}

@test
def "a store under a directory named subagents still maps an agent to its session" [] {
    # Why: the path is split at the last `subagents`, the one Claude Code made;
    # an ancestor of the store may carry the same name.
    let root = $nu.temp-dir | path join $"wf-(random uuid)" subagents
    mkdir $root
    ^cp --recursive $FIXTURE_PROJECT $root
    let agent = $root | path join ($FIXTURE_PROJECT | path basename) $FIXTURE_WF_SESSION subagents workflows wf_aaaa1111-001 agent-a1111111111111111.jsonl

    let row = null | sessions $agent --columns agent_label | first
    let runs = [$agent] | claude-nu workflows | get id

    rm --recursive --force ($root | path dirname)

    assert equal $row.parent_session_id $FIXTURE_WF_SESSION
    assert equal $row.agent_label "review:scope"
    assert equal $runs [wf_aaaa1111-001 wf_bbbb2222-002]
}

@test
def "a transcript reached through a symlink is listed once, under the session holding the file" [] {
    # Why: a resumed session links its `subagents/` entries into the first
    # session's directory, so the glob meets every such transcript twice.
    let store = resumed-store

    let rows = null | sessions $store.project --subagents --columns agent_id | where parent_session_id != null

    rm --recursive --force $store.home

    assert equal ($rows | get agent_id | sort) [agent-a1111111111111111 agent-a2222222222222222 agent-a3333333333333333 agent-b1111111111111111]
    assert equal ($rows | get parent_session_id | uniq) [$FIXTURE_WF_SESSION]
}

@test
def "a subagent transcript named through a link keeps the parent it lives under" [] {
    # Why: the parent is the session holding the file, whichever way it is
    # named, so a join on parent_session_id does not split one agent in two.
    let store = resumed-store
    let linked = $store.project | path join $RESUMED_SESSION subagents
    let paths = [
        ($linked | path join agent-b1111111111111111.jsonl)
        ($linked | path join workflows wf_aaaa1111-001 agent-a1111111111111111.jsonl)
    ]

    let parents = null | sessions ...$paths --columns agent_id | get parent_session_id

    rm --recursive --force $store.home

    assert equal $parents [$FIXTURE_WF_SESSION $FIXTURE_WF_SESSION]
}

@test
def "a subagent id resolves to the real transcript, not a link to it" [] {
    let store = resumed-store

    # Why the plain agent: `glob` does not walk a symlinked directory, but it
    # returns a symlinked file — in directory-walk order, so whether the link
    # or the file comes first depends on the filesystem. Either order fails
    # without `drop-linked-copies`: the link is then a second candidate, and
    # two candidates are an ambiguity error.
    let path = with-env {HOME: $store.home} { null | sessions --session agent-b1111111111111111 --columns agent_id | get 0.path }

    rm --recursive --force $store.home

    assert equal $path ($store.project | path join $FIXTURE_WF_SESSION subagents agent-b1111111111111111.jsonl)
}

@test
def "identity joins a subagent row to its run in workflows" [] {
    let runs = {path: (fixture-session $FIXTURE_WF_SESSION)} | claude-nu workflows
    let agents = $runs | where id == wf_aaaa1111-001 | first | get agents
    let rows = identity-rows | where workflow == wf_aaaa1111-001
    let joined = $agents | join $rows agent_id
    assert equal ($joined | get agent_id | sort) [agent-a1111111111111111 agent-a2222222222222222]
}
