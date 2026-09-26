# claude-nu discovery: where session files live on disk — enumerating,
# resolving, and reading them. Standalone — imports nothing from the other
# claude-nu submodules.

# UUID pattern for session files
export const UUID_JSONL_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

# A bare session UUID, the whole string. Why the whole string: this decides
# whether a selector is an id or a name, and `claude --name` accepts anything.
export const UUID_PATTERN = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Subagent JSONL pattern (Claude Code 2.1.138+ layout:
# `<project>/<session-uuid>/subagents/agent-<id>.jsonl`). The id is usually
# hex, but some carry words from the task (`agent-afork-59b4cf88f115039f`),
# and a hex-only pattern left 16 such files on this machine unlisted.
export const AGENT_JSONL_PATTERN = 'agent-[0-9a-z-]+\.jsonl$'
# A subagent id as `messages` and `tool-calls` name it: the file stem.
export const AGENT_ID_PATTERN = '^agent-[0-9a-z-]+$'

# Root of Claude Code session storage: ~/.claude/projects
export def projects-root []: nothing -> path {
    $env.HOME | path join ".claude" "projects"
}

# The directory name Claude Code gives a project under ~/.claude/projects: its
# absolute path with every `/` turned into `-`. Lossy on purpose — a `-` already
# in the path is indistinguishable from a separator — so the name identifies a
# directory, never a project. Recovering the real path means reading a session's
# `cwd` (see `projects`).
export def encode-project-dir []: path -> string {
    str replace --all '/' '-'
}

# Sessions directory for the current project: ~/.claude/projects/<encoded-pwd>
export def get-sessions-dir []: nothing -> path {
    projects-root | path join ($env.PWD | path expand | encode-project-dir)
}

# Project directory name a session file belongs to — the first path segment
# under ~/.claude/projects. Why: `path dirname` is right for top-level files
# (<root>/<proj>/<uuid>.jsonl) but wrong for subagent transcripts
# (<root>/<proj>/<uuid>/subagents/agent-*.jsonl), where it yields "subagents" —
# that mislabels rows and falsely trips multi-project tagging inside one
# project. Files outside the root fall back to their parent directory name.
export def project-dir-name []: path -> string {
    let file = $in
    let rel = try { $file | path relative-to (projects-root) } catch { null }
    if $rel == null {
        $file | path dirname | path basename
    } else {
        $rel | path split | first
    }
}

# The readable counterpart to project-dir-name: a session's real `cwd`,
# shortened to its last two path segments — the same form `projects` shows as
# `name`. Single source of truth so `project-dir-name` (encoded, lossy) and
# this (real, legible) stay the only two ways a project is named; "" when
# there is no cwd to shorten, so a caller can join without a null check.
export def project-display-name []: string -> string {
    let cwd = $in
    if $cwd == "" { "" } else { $cwd | path split | last 2 | path join }
}

# Resolve session file path from UUID, name, path, or default to most recent.
# Why by shape: a `.jsonl` suffix is a path, a UUID is an id, anything else is
# the name `/rename` or `claude --name` gave a session — so a name never reaches
# the id lookup, and the id lookup never pays the name scan.
export def resolve-session-file [
    session?: string # Session UUID, name (as set by /rename or `claude --name`), or path (null = most recent)
    --sessions-dir: path # Override sessions directory
]: nothing -> path {
    let dir = $sessions_dir | default (get-sessions-dir)

    if $session != null {
        if ($session | str ends-with '.jsonl') {
            return $session
        }
        # Why: `messages` and `tool-calls` name a subagent transcript by its
        # file stem, so that name has to resolve back, or the row cannot be
        # piped onward. A name is tried when no transcript has the id, as
        # after a prefix: `/rename` can call a session `agent-refactor`.
        if $session =~ $AGENT_ID_PATTERN {
            let by_id = find-session-file $dir $"*/subagents/**/($session).jsonl" $session
            if $by_id != null { return $by_id }
            return (resolve-session-name $session --sessions-dir $dir)
        }
        if $session !~ $UUID_PATTERN {
            # Why a prefix before a name: notes and agents quote sessions by
            # their first eight characters (`9787e004`), and a name is only
            # tried when no id starts with the text.
            let by_prefix = if $session =~ '^[0-9a-f][0-9a-f-]{5,34}$' {
                find-session-file $dir $"($session)*.jsonl" $session
            }
            if $by_prefix != null { return $by_prefix }
            return (resolve-session-name $session --sessions-dir $dir)
        }
        let found = find-session-file $dir $"($session).jsonl" $session
        if $found == null {
            error make $"Session not found in any project: ($session)"
        }
        return $found
    }

    if not ($dir | path exists) {
        error make "No sessions directory found for current project"
    }

    # Why: one discoverer owns the listing and recency order, so "most recent
    # session" is the first top-level (non-subagent) row it yields.
    let files = discover-session-files $dir | where parent_session_id == null

    if ($files | is-empty) {
        error make "No session files found"
    }

    $files | first | get path
}

# The one session file `pattern` names below `dir`, else below every project;
# null when none does, an error naming the candidates when several do.
# Why this project first: an id is unique per project only — a subagent id
# exists as two different transcripts in two project stores (118 on one
# machine), and a session copied between stores keeps its UUID — so a row
# piped from a project, whose `project` becomes `dir`, has to come back from
# that project, and a pick among the others would be a guess.
# Why the links are dropped: a resumed session links the transcripts it
# inherits, and a link is the same transcript, not a second candidate.
def find-session-file [
    dir: path
    pattern: string # glob below a project directory
    selector: string # what was asked for, for the error
]: nothing -> any {
    let local = if ($dir | path exists) {
        glob ($dir | path join $pattern) | drop-linked-copies $dir
    } else { [] }
    let found = $local
        | if ($in | is-empty) { glob (projects-root | path join "*" $pattern) | drop-linked-copies (projects-root) } else { }
        | where ($it | path basename) =~ $'($UUID_JSONL_PATTERN)|^($AGENT_JSONL_PATTERN)'
    if ($found | length) < 2 { return ($found | get 0?) }
    let ids = $found | each { session-id-from-path } | uniq
    if ($ids | length) == 1 {
        let rows = $found | each {|file| $"  ($file)" } | str join "\n"
        error make $"($selector) names more than one transcript, pick one by its path:\n($rows)"
    }
    let rows = $found | each {|file| $"  ($file | session-id-from-path)  ($file | project-dir-name)" } | str join "\n"
    error make $"Session id prefix is ambiguous, give more characters: ($selector)\n($rows)"
}

# The parent session of a subagent transcript, read from its path: the
# directory right above its `subagents`. null for a top-level transcript.
# Why `path expand`: a resumed session links the first session's agent
# transcripts into its own `subagents/`, and the parent is the session where
# the file lives — the one discovery and `--session agent-<id>` report, after
# `drop-linked-copies` drops the link.
export def parent-session-of []: path -> any {
    let file = $in | path expand
    let top = $file | top-level-session-file
    if $top == $file { null } else { $top | session-id-from-path }
}

# The top-level transcript a session file belongs to: itself for a top-level
# file, `<project>/<uuid>.jsonl` for a subagent transcript under `<uuid>/subagents/`.
# Why the last `subagents`, not the first: the store itself can sit under a
# directory of that name (a HOME, a CLAUDE_CONFIG_DIR, a scratch copy), while
# nothing below `<uuid>/subagents/` is named so.
export def top-level-session-file []: path -> path {
    let file = $in
    if ($file | path basename) !~ $AGENT_JSONL_PATTERN { return $file }
    let parts = $file | path split
    let at = $parts | enumerate | where item == "subagents" | get index | last
    if $at == null or $at == 0 { return $file }
    $"($parts | first $at | path join).jsonl"
}

# Workflow run state files of a top-level session, one per run it took part
# in, by run id. [] when it took part in none.
# A run counts when the session holds its state file (`<uuid>/workflows/wf_*.json`)
# or its agents' directory (`<uuid>/subagents/workflows/wf_*`, a symlink in a
# resumed session); each state file is then found the way an agent finds it,
# through `workflow-state-file`; a run with no state file anywhere has nothing
# to read and is left out.
# Why both places: a run resumed from another session writes its state there,
# while its agents stay under the session that started it — so the state file
# alone left the starting session with no run, and an agent's row piped here
# (which stands for that session) with none either.
# Why `ls` on the directories and a name filter, not a glob: the directory is a
# variable, and a `[` in a project path would turn a glob into a pattern.
export def workflow-state-files []: path -> list<path> {
    let session_file = $in
    let session_dir = $session_file | str replace --regex '\.jsonl$' ''
    let state_dir = $session_dir | path join "workflows"
    let agents_dir = $session_dir | path join "subagents" "workflows"
    let from_state = if ($state_dir | path exists) {
        ls $state_dir
        | where type == file and ($it.name | path basename) =~ '^wf_.*\.json$'
        | get name
        | path parse
        | get stem
    } else { [] }
    let from_agents = if ($agents_dir | path exists) {
        ls $agents_dir
        | where type in [dir symlink] and ($it.name | path basename) =~ '^wf_'
        | get name
        | path basename
    } else { [] }
    $from_state
    | append $from_agents
    | uniq
    | each {|run| $session_file | workflow-state-file $run }
    | compact
    | sort-by { path basename }
}

# One workflow run state file, read into the fields that say which run it was,
# whether it finished, how long it took and what failed. `agents` holds one row
# per agent the run's progress lists: {agent_id, label, phase, state}, with
# `agent_id` spelled as the transcript's file stem, so it joins to `sessions`.
# Why the status fallback: Claude Code's own reader of this file does the same —
# a file with no `status` is `failed` when it carries an `error`, else `completed`.
export def read-workflow-state []: path -> record {
    let state = open --raw $in | from json
    let progress = $state.workflowProgress? | default []
    {
        id: $state.runId?
        name: $state.workflowName?
        status: ($state.status? | default (if $state.error? != null { "failed" } else { "completed" }))
        agent_count: ($state.agentCount? | default 0)
        duration: ($state.durationMs? | if $in == null { } else { $in * 1ms })
        error: $state.error?
        started: ($state.startTime? | if $in == null { } else { $in * 1_000_000 | into datetime })
        phases: ($state.phases? | default [] | get --optional title)
        summary: $state.summary?
        agents: (
            $progress
            | where type? == "workflow_agent"
            | each {|a| {agent_id: $"agent-($a.agentId?)" label: $a.label? phase: $a.phaseTitle? state: $a.state?} }
        )
    }
}

# Who a subagent transcript is: {agent_id, agent_type, workflow, agent_label,
# phase}, all null for a top-level transcript. `agent_type` and the label come
# from the sibling `agent-<id>.meta.json` (`agentType`, `description` — the
# Agent tool's description, or the label a workflow gave its agent), `phase`
# from its `workflowPhase`; `workflow` is the `wf_*` directory a workflow agent
# sits in.
# Why the state-file fallback: meta files written before Claude Code recorded
# the label and phase in them carry only `agentType`, and the run's own state
# file still lists every agent with both. An agent the state does not list — one
# a resumed run started again under a new id — keeps a null label.
export def subagent-identity []: path -> record {
    let file = $in
    let none = {agent_id: null agent_type: null workflow: null agent_label: null phase: null}
    if ($file | path basename) !~ $AGENT_JSONL_PATTERN { return $none }

    let agent_id = $file | session-id-from-path
    let meta_file = $file | str replace --regex '\.jsonl$' '.meta.json'
    let meta = if ($meta_file | path exists) { open --raw $meta_file | from json } else { {} }
    let dir = $file | path dirname
    let workflow = if ($dir | path basename) =~ '^wf_' and ($dir | path dirname | path basename) == "workflows" {
        $dir | path basename
    }

    let listed = if $workflow != null and ($meta.description? == null or $meta.workflowPhase? == null) {
        $file
        | workflow-state-file $workflow
        | if $in == null { } else { read-workflow-state | get agents | where agent_id == $agent_id | get 0? }
    }

    {
        agent_id: $agent_id
        agent_type: $meta.agentType?
        workflow: $workflow
        agent_label: ($meta.description? | default $listed.label?)
        phase: ($meta.workflowPhase? | default $listed.phase?)
    }
}

# The state file of run `workflow`, looked up from a top-level transcript or one
# of its agents': the session's own `workflows/<id>.json` first, then any
# session of the same project. null when none exists.
# Why the project-wide step: a run resumed from another session writes its state
# there, while its agents' transcripts stay under the session that started them
# (seen on this machine: `wf_7b4c85a1-a5c`).
def workflow-state-file [workflow: string]: path -> any {
    let session_dir = $in | top-level-session-file | str replace --regex '\.jsonl$' ''
    let own = $session_dir | path join "workflows" $"($workflow).json"
    if ($own | path exists) { return $own }
    let pattern = $session_dir | path dirname | path join "*" "workflows" $"($workflow).json"
    try { ls ($pattern | into glob) | get name.0? } catch { null }
}

# The session file carrying `name` as its current name — the same two tiers as
# a UUID: this project's sessions first, then every project. Unlike a UUID a
# name is not unique (Claude only keeps it unique among live sessions, and only
# since 2.1.232), so two matches in a tier are an error naming both, which is
# what `/resume <name>` does with an ambiguous name — not a silent pick.
def resolve-session-name [
    name: string
    --sessions-dir: path
]: nothing -> path {
    let local = if ($sessions_dir | path exists) {
        discover-session-files $sessions_dir | where parent_session_id == null | get path
    } else { [] }
    let found = $local
        | sessions-named $name
        | if ($in | is-empty) {
            glob (projects-root | path join "*/*.jsonl")
            | where $it =~ $UUID_JSONL_PATTERN
            | sessions-named $name
        } else { }
    match ($found | length) {
        0 => (error make $"Session not found in any project: ($name)")
        1 => ($found | first)
        _ => {
            let rows = $found
                | each {|file|
                    let age = ls $file | get 0.modified | date humanize
                    $"  ($file | session-id-from-path)  ($age)  ($file | project-dir-name)"
                }
                | str join "\n"
            error make $"Session name is ambiguous, pick a UUID: ($name)\n($rows)"
        }
    }
}

# The files among the input whose current name is `name`. Current = the last
# `custom-title` record: a rename appends one, so an earlier record still holds
# the old name and a substring hit on it is not a match. The rg pre-filter looks
# for the JSON-encoded pair, fixed string, so a `(` or `.` in a name is data.
def sessions-named [name: string]: list<path> -> list<path> {
    let files = $in
    let marker = $'"customTitle":($name | to json --raw)'
    $files
    | rg-filter-session-files $marker --fixed-strings
    | where {
        read-session-records --contains '"custom-title"'
        | where type? == "custom-title"
        | get --optional customTitle
        | compact
        | last
        | default ""
        | $in == $name
    }
}

# Session UUID from a session file path
export def session-id-from-path []: path -> string {
    path basename | str replace '.jsonl' ''
}

# Read a session JSONL file into a table of records, one record per line. The
# single decode point for a session's raw records: every full-file parser goes
# through here, so "a session is one JSON object per line" lives in one place
# (and any future empty/corrupt-line handling has a single home).
# Why (speed): `from json --objects` decodes the whole NDJSON stream in one call
# instead of `lines | each { from json }`, which restarts the parser per line —
# ~1.25x faster across every session parse. --contains pre-screens the raw lines
# by substring before decoding, so a caller wanting one record type (messages
# wants user turns — only ~30% of lines) never parses the rest; the caller still
# re-filters the decoded `type`, so a line merely quoting the marker can't slip in.
export def read-session-records [--contains: string]: path -> table {
    let file = $in
    # Why the NUL trim: an unclean shutdown can leave a transcript extended by a
    # run of NUL bytes that were never written. A raw NUL is never valid JSON,
    # so the trim drops no record — while one such file on the machine stopped
    # every `--all-projects` read. Only a trailing run: a NUL anywhere else is a
    # shape nobody has seen, and it still fails below.
    let raw = open --raw $file
        | str trim --right --char (char nul)
        | if $contains == null { } else { lines | where ($it | str contains $contains) | str join "\n" }
    # Why: `from json --objects` is lazy, so its error surfaces wherever the
    # caller consumes the table — pointing at some pipeline in discovery.nu and
    # naming no file (a transcript padded with NUL bytes cost a scan of every
    # session on the machine to find). Collect inside the try so the failure
    # lands here, and rethrow it with the path and serde's own line. Only the
    # parse is inside: a missing or unreadable file keeps its own error.
    try {
        $raw | from json --objects | collect
    } catch {|e|
        let detail = $e.details.inner? | get --optional 0.labels.0.text | default $e.msg
        error make --unspanned {
            msg: $"Session file is not valid JSONL: ($file)\n($detail)"
            help: "one JSON record per line"
        }
    }
}

# Discover session files in a directory, newest first. Returns rows
# {path, parent_session_id, modified, size}; parent_session_id is the parent session
# UUID for subagent files (`<uuid>/subagents/agent-*.jsonl`), null for top-level
# files. `modified` and `size` are the `sessions` columns of the same names:
# the `ls` here already stats each file, so they cost no parse and no second stat.
# Single source of truth for the on-disk session layout — every command
# that lists sessions for parsing goes through here, so the name patterns, the
# subagent walk, and the recency order live in one place. (Two lightweight
# listers in sessions.nu — `projects` and the sessions completer — stay
# independent by choice: they only need top-level names/mtimes/sizes, and this
# walk would add a subagents glob per directory for nothing.) Callers wanting
# only human-driven sessions filter `where parent_session_id == null`.
export def discover-session-files [dir: path]: nothing -> table {
    # Why: top-level files sit directly in $dir, so one `ls` lists them with
    # their mtimes; an empty dir is just [], whereas `ls` on a no-match glob
    # errors — keeping the empty case graceful without a special branch.
    let top_level = ls $dir
        | where name =~ $UUID_JSONL_PATTERN
        | follow-links
        | each {|f| {path: $f.name parent_session_id: null modified: $f.modified size: $f.size} }

    # Why: subagent transcripts are nested out of reach of a flat `ls`, so a glob
    # descends to them. The `**` is load-bearing: Workflow agents nest deeper, at
    # `<uuid>/subagents/workflows/wf_*/agent-*.jsonl`, so a single-level
    # `*/subagents/*.jsonl` silently misses them. The parent UUID is therefore the
    # first path segment under $dir (depth-independent), not "two levels up" —
    # two-up would yield `workflows` for the nested ones.
    # Why (speed): one `ls <glob>` stats every transcript in a single directory
    # walk; the old `glob | each { ls }` re-stated each file individually (~10x
    # slower on a project with many subagents). `ls` errors on a no-match glob, so
    # try/catch keeps the empty case graceful (matching `glob`'s old behavior).
    let listed = try { ls (($dir | path join "*/subagents/**/*.jsonl") | into glob) } catch { [] }
        | where name =~ $AGENT_JSONL_PATTERN
    let real = $listed | get name | drop-linked-copies $dir
    let subagent_files = $listed
        | where name in $real
        | follow-links
        | each {|f|
            {path: $f.name parent_session_id: ($f.name | path relative-to $dir | path split | first) modified: $f.modified size: $f.size}
        }

    $top_level | append $subagent_files | sort-by modified --reverse
}

# `ls` rows with each symlink's `modified` and `size` taken from its target,
# under the link's own name.
# Why: `ls` describes the link, and Claude Code writes the subagent transcripts
# a resumed session inherits as symlinks to the parent's files. The link's
# mtime is when the session was resumed, not its last record, so the rule every
# mtime cut stands on — a file is written when its last record is — did not hold.
export def follow-links []: table -> table {
    each {|f|
        if $f.type != "symlink" { return $f }
        ls ($f.name | path expand) | first | update name $f.name
    }
}

# One path per real file among `files`, in their order: a path reached through a
# symlink below `root` — the file itself or a directory on the way — is dropped
# when the file's own spelling is among them too.
# Why the real file and not the link: when a session is resumed, Claude Code
# makes the new session's `subagents/` entries — a single transcript, or a
# whole `workflows/wf_*` directory — symlinks into the first session's
# directory, and keeps writing there: `wf_7b4c85a1-a5c` was made by a7aaed2c
# (21:42), linked from a7e17f17 on resume (21:44), and 5 of its 9 agents were
# then written into a7aaed2c's directory with a7e17f17's `sessionId`. So the
# file lives in the first session's tree, and the parent is read from where it
# lives — as for any path, and as `drop-copied-records` keeps the copy where a
# record was first written. The cost: an agent the resumed session started
# names the first one as its parent; only its records' `sessionId` can tell,
# and a listing parses no file. A link whose target is not among `files`
# stays: it is then the only way to that transcript.
export def drop-linked-copies [root: path]: list<path> -> list<path> {
    let files = $in
    let root_real = $root | path expand
    let rows = $files
        | each {|f|
            let real = $f | path expand
            {path: $f real: $real linked: ($real != ($root_real | path join ($f | path relative-to $root)))}
        }
    let direct = $rows | where not linked | get real
    $rows
    | where {|r| not $r.linked or $r.real not-in $direct }
    | uniq-by real
    | get path
}

# Top-level (human) session files of the current project, newest first — the
# default scope of a command handed no input. Subagent transcripts are excluded:
# they carry no human-typed messages, and asking for them is `sessions --subagents`.
export def top-level-session-files []: nothing -> list<path> {
    let dir = get-sessions-dir
    if not ($dir | path exists) { return [] }
    discover-session-files $dir | where parent_session_id == null | get path
}

# Path bytes one rg call may carry. Deliberately far under the smallest cap in
# play (macOS 1 MB, Linux 2 MB): argv shares that budget with the environment,
# and a session path is as long as the encoded project path it sits in — a deeply
# nested workspace makes every path longer at once, which is exactly the case a
# fixed file count cannot see.
const RG_ARGV_BUDGET = 262144

# Split paths into batches whose argv bytes stay under `budget`, keeping order.
# A path longer than the budget on its own still gets a call: one path per batch
# is the floor, because skipping it would silently lose a session.
def batch-by-argv-bytes [budget: int]: list<path> -> list<list<path>> {
    reduce --fold {batches: [] used: 0} {|file acc|
        # +1: argv charges each entry its bytes plus the terminating NUL
        let cost = ($file | str length) + 1
        if ($acc.batches | is-empty) or ($acc.used + $cost) > $budget {
            {batches: ($acc.batches | append [[$file]]) used: $cost}
        } else {
            {batches: ($acc.batches | update (($acc.batches | length) - 1) { append $file }) used: ($acc.used + $cost)}
        }
    }
    | get batches
}

# Narrow session files to those whose raw JSONL can match `pattern`, keeping the
# given order. A pre-filter, not the filter: the caller re-applies the real regex
# to the extracted text, so this only has to avoid parsing files that cannot
# match. Missing rg is not an error — every file passes and the caller's regex
# does all the work, just slower.
# Why: rg scans the raw, escaped JSON, so it can't honor line anchors or match a
# JSON-escaped quote/backslash the way the structured regex on extracted text
# does. That only ever costs recall for such patterns; it never yields a wrong
# hit. For ordinary word/phrase/regex searches rg and the structured filter agree
# (both use Rust's regex engine), and we open only the few files that can match
# instead of parsing every session in the scope.
# Why --no-ignore --hidden: a stray .gitignore or the dot in ~/.claude must not
# hide a session. The pattern goes through --regexp (which allows a leading `-`),
# not as a bare arg. rg exit 1 means "no match" (empty); only a real failure
# (exit 2+) errors — fail fast on a broken pattern instead of silently returning
# nothing.
export def rg-filter-session-files [
    pattern: string
    --fixed-strings # Match `pattern` as a literal substring, not a regex
]: list<path> -> list<path> {
    let files = $in
    if ($files | is-empty) or (which rg | is-empty) { return $files }
    let mode = if $fixed_strings { ["--fixed-strings"] } else { [] }
    # Why chunked: the paths travel through argv, so one call over a large enough
    # corpus dies with a bare "I/O error" — a limit the old directory-scoped call
    # never had. The limit is bytes, not files: measured here, 3012 paths are
    # 383 KB of argv (~127 B each), so the "~12k files fit, 20k do not" boundary
    # was really 1.5 MB vs 2.5 MB — Linux ARG_MAX (2 MB) exactly.
    # Why RIPGREP_CONFIG_PATH is cleared: a user's rc file (--fixed-strings,
    # --type, --max-filesize) would silently change what the pre-filter can see,
    # and a file it then skips reads back as "you never said that".
    let matched = $files
        | batch-by-argv-bytes $RG_ARGV_BUDGET
        | each {|chunk|
            let res = with-env {RIPGREP_CONFIG_PATH: null} {
                rg --no-ignore --hidden --files-with-matches ...$mode --regexp $pattern -- ...$chunk | complete
            }
            match $res.exit_code {
                0 => ($res.stdout | lines)
                1 => []
                _ => (error make $"rg failed \(exit ($res.exit_code)): ($res.stderr | str trim)")
            }
        }
        | flatten
    # Why match against the input list (not rg's output): it keeps the caller's
    # order and its own spelling of each path, whatever rg echoes back.
    $files | where $it in $matched
}

# A time bound as the caller typed it, turned into a datetime. A duration means
# "ago" (`--since 1wk`), a datetime is taken as given, and a string is read as
# either — so one flag accepts `1wk`, `2026-08-01`, and a `$start` variable.
# Why one converter: --since/--until live on three commands, and each deciding
# for itself what `1wk` means is how the same flag ends up meaning "a week ago"
# in one place and "a week long" in another.
export def resolve-time-bound [flag: string]: any -> datetime {
    peek | metadata access {|md|
        let value = $in
        match $md.peek.type {
            "datetime" => $value
            "duration" => ((date now) - $value)
            # Why duration first: `into datetime` rejects "1wk" and `into duration`
            # rejects "2026-08-01", so the two parses never both succeed.
            "string" => (
                try {
                    (date now) - ($value | into duration)
                } catch {
                    try { $value | into datetime } catch {
                        error make {
                            msg: $"($flag): cannot read '($value)' as a duration or a date"
                            help: "try a duration meaning ago \(1wk, 3day\) or a date \(2026-08-01\)"
                        }
                    }
                }
            )
            $other => (error make {msg: $"($flag): expected a duration, a datetime, or a date string — got ($other)"})
        }
    }
}

# Narrow session files to those last written at or after `since`, keeping the
# given order. Sound, not exact — the same deal as the rg pre-filter: a file is
# written when its last record is appended, so one untouched since before the
# bound cannot hold a message after it, while one written today may well have
# started months ago. That asymmetry is why there is no `until` twin: no cheap
# fact about a file rules out its *first* record being early. The caller still
# filters rows by their own timestamps; this only avoids opening files that
# cannot contribute one.
export def mtime-filter-session-files [since: datetime]: list<path> -> list<path> {
    let files = $in
    # Why the guard: `ls` with no arguments lists the working directory, so an
    # empty scope would come back as whatever happens to sit in it.
    if ($files | is-empty) { return $files }
    # Why one `ls ...$files`: it stats the whole scope in a single call, and a
    # string variable in a glob position is taken literally, so a `[` in a
    # project path cannot turn into a pattern.
    let kept = ls ...$files | follow-links | where modified >= $since | get name
    # Why match against the input list: it keeps the caller's order and its own
    # spelling of each path (same reason as in rg-filter-session-files).
    $files | where $it in $kept
}
