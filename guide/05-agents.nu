# Chapter 5: which agent a transcript is, and the Workflow runs.
# Past agents opened `agent-<id>.meta.json` and `workflows/wf_*.json` in python
# to ask which agent this was, which run it belonged to, did the run finish,
# and what failed. `sessions` names the agent; `workflows` lists the runs.
# Refresh the outputs: `dotnu embeds-update guide/05-agents.nu`
# The store here is a small project of its own, with one plain subagent and a
# session that ran two Workflow runs (see fixture-home.nu).

use ../claude-nu
use fixture-home.nu
fixture-home --workflows

# A subagent row carries the parent's `session_id`, so it could not say which
# agent it was. The identity columns do, read from the meta file beside the
# transcript: a plain subagent has its type and the Agent tool's description;
# a workflow agent has its run, its label and its phase. They are null on
# top-level rows and outside the default set. An attempt a resumed run replaced
# is not in the run's state, so its label stays null.
claude-nu sessions --subagents --columns agent_id,agent_type,workflow,agent_label,phase
| where parent_session_id != null
| select agent_id agent_type agent_label
| update agent_id { str substring 0..8 }
| print $in
# => ╭───┬───────────┬───────────────────┬────────────────────────╮
# => │ # │ agent_id  │    agent_type     │      agent_label       │
# => ├───┼───────────┼───────────────────┼────────────────────────┤
# => │ 0 │ agent-a22 │ workflow-subagent │ verify:scope-from-meta │
# => │ 1 │ agent-b11 │ Explore           │ Find stale references  │
# => │ 2 │ agent-a33 │ workflow-subagent │                        │
# => │ 3 │ agent-a11 │ workflow-subagent │ review:scope           │
# => ╰───┴───────────┴───────────────────┴────────────────────────╯

# The workflow agents alone, by run and phase.
claude-nu sessions --subagents --columns agent_id,workflow,phase
| where workflow != null
| select agent_id workflow phase
| update agent_id { str substring 0..8 }
| print $in
# => ╭───┬───────────┬─────────────────┬────────╮
# => │ # │ agent_id  │    workflow     │ phase  │
# => ├───┼───────────┼─────────────────┼────────┤
# => │ 0 │ agent-a22 │ wf_aaaa1111-001 │ Verify │
# => │ 1 │ agent-a33 │ wf_aaaa1111-001 │        │
# => │ 2 │ agent-a11 │ wf_aaaa1111-001 │ Review │
# => ╰───┴───────────┴─────────────────┴────────╯

# One row per Workflow run, scoped like `messages`: no input is the current
# project, piped session rows or a project narrow it.
# A run with no `status` in its state file is `failed` when it has an `error`.
claude-nu workflows | select id name status agent_count duration | print $in
# => ╭────┬─────────────────┬────────────────┬───────────┬─────────────┬────────────╮
# => │  # │       id        │      name      │  status   │ agent_count │  duration  │
# => ├────┼─────────────────┼────────────────┼───────────┼─────────────┼────────────┤
# => │  0 │ wf_aaaa1111-001 │ fixture-review │ completed │           2 │       5min │
# => │  1 │ wf_bbbb2222-002 │ fixture-broken │ failed    │           1 │ 1sec 500ms │
# => ╰────┴─────────────────┴────────────────┴───────────┴─────────────┴────────────╯

# What did not complete, and why.
claude-nu workflows | where status != completed | select id error | print $in
# => ╭───┬─────────────────┬───────────────────────╮
# => │ # │       id        │         error         │
# => ├───┼─────────────────┼───────────────────────┤
# => │ 0 │ wf_bbbb2222-002 │ agent budget exceeded │
# => ╰───┴─────────────────┴───────────────────────╯

# The agents a run's progress lists, with their phase and state.
# `agent_id` joins to the `agent_id` column of `sessions --subagents`.
claude-nu workflows | where id == wf_aaaa1111-001 | get 0.agents | print $in
# => ╭───┬─────────────────────────┬──────────────┬────────┬───────╮
# => │ # │        agent_id         │    label     │ phase  │ state │
# => ├───┼─────────────────────────┼──────────────┼────────┼───────┤
# => │ 0 │ agent-a1111111111111111 │ review:scope │ Review │ done  │
# => │ 1 │ agent-a2222222222222222 │ verify:scope │ Verify │ done  │
# => ╰───┴─────────────────────────┴──────────────┴────────┴───────╯
