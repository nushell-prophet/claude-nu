# claude-nu extraction: session records -> text, dialogue, and metrics.
use render.nu [render-message-content render-content content-blocks]

# System-generated message prefixes to filter out.
# Why: `!`-command wrappers (<bash-input>/<bash-stdout>/<bash-stderr>) are NOT
# here — they're a real user action, rendered as readable markdown by
# render-bash-wrapper instead of dropped. <selected-text> and <img> are absent
# for the same reason though nothing renders them — they pass through as the
# user's own text, an editor selection and a pasted image. Only what Claude
# Code synthesizes on its own is filtered — slash-command and caveat wrappers,
# the <task-notification> a finished background agent injects in its own voice
# under type: "user", and a <system-reminder> that opens the text.
# Why <system-reminder> is safe to list even though it usually rides along with
# a real message: the check is str starts-with, so it only drops a record whose
# text *begins* with the tag — a turn nobody typed. A reminder appended after
# the user's own words leaves those words first, and the message survives whole.
const SYSTEM_PREFIXES = [
    "<command-name>"
    "<command-message>"
    "<local-command-caveat>"
    "<local-command-stdout>"
    "<local-command-stderr>"
    "<task-notification>"
    "<system-reminder>"
    "Caveat:"
]

# Helper to extract text content from a message
export def extract-text-content []: record -> string {
    # Why: text blocks join with no separator (unlike render-content's "\n\n")
    # — callers like user_msg_length count exact characters.
    render-message-content { where type? == "text" | get text --optional | str join }
}

# Like extract-text-content but also surfaces thinking blocks, prefixed with
# `[thinking]` so they're distinguishable from regular text. Blocks are
# rendered in source order and joined with blank lines.
# Why: messages --include-thinking exposes thinking-only assistant turns that
# the visible-text filter would otherwise drop.
export def extract-text-with-thinking []: record -> string {
    render-content --thinking
}

# False when text is one of the command/tool/caveat wrappers Claude Code
# synthesizes around a turn — i.e. not a human-typed message (see SYSTEM_PREFIXES).
export def is-user-text []: string -> bool {
    let text = $in
    $SYSTEM_PREFIXES | all {|p| not ($text | str starts-with $p) }
}

# Build a dialogue table from raw session records: the user and assistant turns
# with their visible text. Drops meta turns, empty-text turns, and the user-side
# system/command wrappers Claude Code synthesizes. `extract` renders each record's
# text, so callers pick plain text, +thinking, or tool placeholders. Pass
# --keep-system to retain meta and system-wrapper turns (messages --include-system).
# Why: messages and export-session both built this same dialogue+filter pass; one
# source keeps the system-prefix rule from drifting between them.
export def extract-dialogue [extract: closure --keep-system]: table -> table {
    where type? in ["user" "assistant"]
    | if $keep_system { } else { where isMeta? != true }
    | insert text {|r| do $extract $r }
    | where {|r| $r.text | str trim | is-not-empty }
    | if $keep_system { } else {
        where {|r| $r.type? != "user" or ($r.text | is-user-text) }
    }
}

# Authored user-message text from a record set — exactly the user messages
# `messages` returns: tool-result records (render to ""), meta turns, and the
# command/caveat wrappers Claude Code synthesizes are all dropped (via
# extract-dialogue / is-user-text).
# Why: the user_msg_* columns and turn_count must agree with `messages` on what
# a user message is. The old "any non-empty user record" rule counted /clear and
# <local-command-caveat> wrappers as messages, inflating every count and dumping
# that wrapper text into the default `user_messages` column.
export def user-message-texts []: table -> list<string> {
    where type? == "user"
    | extract-dialogue {|r| $r | extract-text-content }
    | get text
}

# Helper to extract tool calls from assistant messages
export def extract-tool-calls []: record -> table {
    $in.message?.content? | content-blocks | where type? == "tool_use"
}

# Extract tool results from user records (responses to tool calls)
export def extract-tool-results []: table -> table {
    each { $in.message?.content? | content-blocks | where type? == "tool_result" }
    | flatten
}

# Extract a session summary string from records.
# Why this order: a name a human chose outranks one a model generated. A
# `custom-title` record is what `claude --name` writes, so it is the user's own
# label — and `gi open` sets it to the canvas path, which is the most useful
# thing a gi session could be called. Then the legacy `summary` record, which
# 2.1.x rarely writes any more, and last `ai-title.aiTitle`, the generated one.
export def extract-summary []: table -> string {
    let records = $in
    # Why the last record of each kind: Claude Code rewrites both titles as the
    # session evolves, so the final one is what the app shows.
    let from_custom = $records | where type? == "custom-title" | last-of $.customTitle
    if ($from_custom | is-not-empty) {
        return $from_custom
    }
    let from_summary = $records | where type? == "summary" | get 0?.summary?
    if ($from_summary | is-not-empty) {
        return $from_summary
    }
    $records | where type? == "ai-title" | last-of $.aiTitle
}

# Last non-null value of a field across records, "" when absent.
def last-of [field: cell-path]: table -> string {
    get $field --optional | compact | last | default ""
}

# First non-null value of a field across records, "" when absent
export def pick-first [field: cell-path]: table -> string {
    get $field --optional | compact | first | default ""
}

# Extract session metadata from records, walking each one to find each field.
# Why: in 2.1.x first record can be permission-mode (sessionId only) or
# file-history-snapshot (no metadata). A "first non-summary record" lookup
# returns mostly empty fields; instead pull each field from the first record
# that actually carries it.
export def extract-session-metadata []: table -> record {
    let records = $in
    {
        session_id: ($records | pick-first $.sessionId)
        version: ($records | pick-first $.version)
        cwd: ($records | pick-first $.cwd)
        git_branch: ($records | pick-first $.gitBranch)
    }
}

# Reasoning effort the session ran at, from assistant records.
# Why not thinkingMetadata.level any more: that field is gone — 3 of the newest
# 400 transcript files still carry it, and none of the newest 80 sessions do, so
# the column it fed was empty for every session. Claude Code now writes the same
# fact as a top-level `effort` on each assistant record, which is also why this
# reads assistant turns where the old one read user turns.
export def extract-effort []: table -> string {
    pick-first $.effort
}

# First/last timestamp across all records that carry one — the session's
# activity span.
# Why: not user records only — a session can have zero user turns (e.g. the
# user opened Claude, ran /usage, quit) yet still hold timestamped system
# records. User-only extraction gave those sessions a null last_timestamp,
# and sort-by places null after every datetime, so the natural
# `sessions | sort-by last_timestamp | last` idiom always picked a junk
# session instead of the real latest one.
export def extract-timestamps []: table -> record {
    let ts = get timestamp --optional
        | compact
        | each { into datetime }
    {
        first: ($ts | first)
        last: ($ts | last)
    }
}

# Extract file operations from tool calls
export def extract-file-operations []: table -> record {
    let tool_calls = $in
    {
        edited_files: ($tool_calls | where name? in ["Edit" "Write"] | get input.file_path --optional | uniq)
        read_files: ($tool_calls | where name? == "Read" | get input.file_path --optional | uniq)
    }
}

# Extract agent info from tool calls
# Why only `Agent`: 2.1.x renamed `Task` to `Agent`, and the old spelling is
# gone from every recent transcript (0 of the newest 80 sessions), so carrying
# it would be a branch nothing can reach. The drift check reports such a name as
# `dead` precisely so it gets deleted rather than kept "just in case".
# TaskCreate/Update/Stop are TODO-list ops with different schema, not agents.
export def extract-agents []: table -> table {
    where name? == "Agent"
    | each {
        {
            type: ($in.input?.subagent_type? | default "unknown")
            description: ($in.input?.description? | default "")
        }
    }
}

# Extract tool statistics from tool calls and results
# Why: tool catalog grew in 2.1.x; count newly-added names so users can see
# whether/how often they appear in a session.
export def extract-tool-stats [
    tool_results: table
]: table -> record {
    let tool_calls = $in
    let bash_cmds = $tool_calls | where name? == "Bash" | get input.command --optional
    {
        bash_commands: $bash_cmds
        bash_count: ($bash_cmds | length)
        skill_invocations: ($tool_calls | where name? == "Skill" | get input.skill --optional)
        tool_errors: ($tool_results | where is_error? == true | length)
        ask_user_count: ($tool_calls | where name? == "AskUserQuestion" | length)
        plan_mode_used: ($tool_calls | where name? == "EnterPlanMode" | is-not-empty)
        tool_counts: {
            TaskCreate: ($tool_calls | where name? == "TaskCreate" | length)
            TaskUpdate: ($tool_calls | where name? == "TaskUpdate" | length)
            TaskStop: ($tool_calls | where name? == "TaskStop" | length)
            Monitor: ($tool_calls | where name? == "Monitor" | length)
            ToolSearch: ($tool_calls | where name? == "ToolSearch" | length)
        }
    }
}

# Extract derived metrics from session data
export def extract-derived-metrics [
    assistant_records: table
    tool_calls: table
]: table -> record {
    {
        # Why: a turn is one authored user message — same definition as the
        # user_msg_* columns and `messages` (tool-result, meta, and command/
        # caveat wrapper records all excluded), so the metrics can't disagree.
        turn_count: ($in | user-message-texts | length)
        assistant_msg_count: ($assistant_records | length)
        tool_call_count: ($tool_calls | length)
    }
}

# Why: math sum errors on empty input in nu 0.107; every column sum
# (token usage, user_msg_length, response_length) guards through this.
export def sum-or-zero []: list -> int {
    if ($in | is-empty) { 0 } else { math sum }
}

# Aggregate token usage across assistant records.
# Why: costUSD is null for subscription users, so token counts are the only
# usable cost/effort signal. Usage lives at message.usage per assistant turn;
# the nested `iterations`/`cache_creation` breakdowns are ignored — the
# top-level fields already hold the per-message totals.
export def extract-token-usage []: table -> record {
    let usages = get message.usage --optional | compact
    let sum = {|field| $usages | get $field --optional | compact | sum-or-zero }
    {
        input_tokens: (do $sum "input_tokens")
        output_tokens: (do $sum "output_tokens")
        cache_creation_input_tokens: (do $sum "cache_creation_input_tokens")
        cache_read_input_tokens: (do $sum "cache_read_input_tokens")
    }
}
