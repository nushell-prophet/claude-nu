#!/usr/bin/env nu
# Agent calls to claude-nu that failed.
#
# drift.nu asks whether claude-nu still reads what Claude Code writes. This
# asks the other half: whether agents manage to use it. Every Bash or nushell
# MCP call whose command runs a claude-nu subcommand and whose result carries a
# `nu::` error, one row per call, with a cause that points at the place to fix
# (the triage table in SKILL.md).
#
# Why a script and not a query in SKILL.md: the three studies before it each
# wrote this query again from zero, and each one guessed a column name first.

const REPO = path self ../../..

use ($REPO | path join claude-nu)
use ($REPO | path join claude-nu discovery.nu) [UUID_JSONL_PATTERN AGENT_JSONL_PATTERN]

const SUBCOMMANDS = 'claude-nu (projects|sessions|messages|tool-calls|timeline|records|workflows|slash-commands|export-session)'

# The cause decides where the fix goes; the order matters, the first match wins.
export def cause []: string -> string {
    let text = $in
    if $text =~ "neither a Nushell built-in|`claude-nu` .*not found|module_not_found|module_missing_mod_nu_file" {
        'not-loaded'
    } else if $text =~ 'column_not_found|Unknown session column' {
        'column-guess'
    } else if $text =~ 'Path not found|Session (file )?not found|File not found|ambiguous|names more than one transcript|No session files|No sessions directory' {
        'selector'
    } else if $text =~ 'mutually exclusive' {
        'scope-conflict'
    } else {
        'other'
    }
}

# Failed agent calls to claude-nu, subagents included, newest first.
def main [
    --since: string = '2wk' # How far back to look: a duration meaning ago, or a date
    --json # Machine-readable output, for agents
]: nothing -> any {
    # Why every transcript and not `claude-nu projects`: a project row stands
    # for its top-level sessions only, and much of the claude-nu use is by
    # subagents a study launched.
    let calls = ls (($env.HOME | path join .claude projects '**' '*.jsonl') | into glob)
        | where name =~ $UUID_JSONL_PATTERN or name =~ $AGENT_JSONL_PATTERN
        | get name
        | claude-nu tool-calls --results --since $since 'claude-nu '
        | where tool in [Bash mcp__nushell__evaluate]
        | insert command {|r| $r.input.command? | default $r.input.input? | default '' }
        | where command =~ $SUBCOMMANDS
        # Why: the session running this study has its own failed probes in it.
        | where session != $env.CLAUDE_CODE_SESSION_ID?

    let failed = $calls
        | insert code {|r| $r.result | default '' | parse --regex '(nu::[a-z_:]+)' | get capture0?.0? }
        | where code != null
        | insert cause {|r| $r.result | cause }
        | sort-by timestamp --reverse
        | select timestamp session cause code command result

    let report = {
        since: $since
        calls: ($calls | length)
        failed: ($failed | length)
        by_cause: ($failed | get cause | uniq --count | sort-by count --reverse | rename cause count)
        rows: $failed
    }

    if $json { return ($report | to json) }

    print $"($report.failed) of ($report.calls) agent calls to claude-nu failed since ($since)"
    print ($report.by_cause | to nuon --indent 1)
    print ($failed
        | update timestamp { format date '%F %T' }
        | update session { str substring 0..7 }
        | update command { str replace --all (char nl) ' ' | str substring 0..160 }
        | update result { lines | where $it =~ '^\s*(x|help:) ' | str join ' | ' | str substring 0..200 }
        | to nuon --indent 1)
}
