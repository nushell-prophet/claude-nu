# claude-nu workflows: the Workflow tool runs a session launched, read from
# their state files.

use sessions.nu [piped-session-files drop-copied-records]
use discovery.nu [top-level-session-files top-level-session-file workflow-state-files read-workflow-state read-session-records project-dir-name project-display-name session-id-from-path]
use extract.nu [pick-first]

# The Workflow tool runs of Claude Code sessions, one row per run:
# {id, session, status, agent_count, duration, error, name, phases, started,
# summary, agents, state_file, project, project_name}. `agents` lists the run's
# agents as its progress recorded them — {agent_id, label, phase, state} — and
# `agent_id` joins to the `agent_id` column of `sessions --subagents`.
# Scoping works as in `messages`: no input reads every top-level session of the
# current project, piped session rows narrow it, a `projects` row stands for
# that project. A piped subagent transcript stands for the session that ran it.
# Why a command and not a `sessions` column: a run is a row of its own — one
# session launches several, and "which runs failed" is a filter over runs.
# Why the state file and not the agents' `journal.jsonl`: the journal holds only
# started/result pairs per agent, while the state file carries the status, the
# duration, the error and each agent's label and phase.
# Why `state_file` and not `path`: a `path` column makes a row a session
# selector, and piping a run on into `messages` would read the JSON state as a
# transcript; `session` already names the session to pipe on.
@category claude-nu
@example "runs of this project that did not complete" { claude-nu workflows | where status != completed | select id name status error }
@example "the longest runs across every project" { claude-nu projects | claude-nu workflows | sort-by duration --reverse | select id name duration agent_count project_name }
@example "the agents of the latest run, by phase" { claude-nu workflows | sort-by started | last | get agents | group-by phase }
export def main []: [nothing -> table record -> table table -> table list<string> -> table] {
    let input = $in
    let piped_files = piped-session-files $input

    let scoped_files = if $piped_files != null {
        $piped_files
    } else {
        top-level-session-files
        | if ($in | is-empty) { error make "No session files found for the current project" } else { }
    }

    # Why: a run belongs to a top-level session — the one that started it or
    # one that resumed it — and a session and its subagents piped together
    # must list each run once.
    let session_files = $scoped_files | each { top-level-session-file } | uniq

    # Why the top-level files too: a piped agent transcript is read through its
    # parent's, which may be gone while the agent's is still there.
    let missing = $scoped_files | append $session_files | uniq | where not ($it | path exists)

    if ($missing | is-not-empty) {
        error make $"Session file not found: ($missing | str join ', ')"
    }

    $session_files
    | each {|session_file|
        let state_files = $session_file | workflow-state-files

        if ($state_files | is-empty) { return [] }
        # Why only here: `project_name` needs the transcript's `cwd`, and most
        # sessions run no workflow, so only the few that did pay for the read.
        let project_name = $session_file
            | read-session-records --contains '"cwd"'
            | pick-first $.cwd
            | project-display-name

        $state_files
        | each {|state_file|
            let run = $state_file | read-workflow-state

            {
                id: $run.id
                session: ($session_file | launching-session $run.id)
                status: $run.status
                agent_count: $run.agent_count
                duration: $run.duration
                error: $run.error
                name: $run.name
                phases: $run.phases
                started: $run.started
                summary: $run.summary
                agents: $run.agents
                state_file: $state_file
                project: ($session_file | project-dir-name)
                project_name: $project_name
            }
        }
    }
    | flatten
    # Why: a resumed run is one run, and both the session that started it and
    # the one that resumed it list it. Both rows name the launching session,
    # so which one is kept does not change the row.
    | drop-copied-records id
}

# The session that launched run `run`, listed by `session_file`: the one whose
# tree holds the run's agents' directory. A resumed session holds only a link
# to it, so the link is followed — as `parent-session-of` does for an agent's
# transcript. With no agents' directory the listing session is the answer.
# Not the listing session because: both the launching and the resuming session
# list a resumed run, and the dedup keeps whichever row comes last in the
# input, so the run's `session` would follow the order sessions were piped in.
def launching-session [run: string]: path -> string {
    let session_file = $in
    let agents_dir = $session_file
        | str replace --regex '\.jsonl$' ''
        | path join subagents workflows $run

    if ($agents_dir | path exists) {
        $agents_dir | path expand | path dirname --num-levels 3 | path basename
    } else {
        $session_file | session-id-from-path
    }
}
