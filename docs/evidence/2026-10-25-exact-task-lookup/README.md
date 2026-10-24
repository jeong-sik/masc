# Exact Task IDs remain readable after completion

Author base: `44c28d74fbfb22279a1e47877736fb102e51645c`. The reproducible probe uses byte-identical published baseline `0596143ca7393557f072662e11d7e8359d23743b`; see `probe-baseline-binding.json`.

The failed actual Qwen canary used candidate
`3badb88117794510dac576bf3fc34f0336e17d8a`. After the controlled linked-Task
approval, requests13–15 called `keeper_tasks_list` with `task_ids=[task-001]`
and `projection=full`, omitting lifecycle flags. The approved Task was Done,
so the active-only default returned `matching_count=0` and `snapshot=[]`.
Request16 ended with a public no_op claim that the Task still awaited
verification. No Goal measurement or remaining work followed. The Task-list
source at the repair base has the same behavior as that candidate.

That failed G3 result remains a failure. Qwen originally omitted the Goal link;
the parent applied a controlled public-MCP link before operator-proxy approval.
The setup is not autonomous G2 association. The read-only original observation
is `/tmp/masc-goal-qwen-postapproval/20261024T145602000518Z.json`, SHA256
`4b9c6946199d27f179f8da2f32eebccccade1887a88ee27b02f022e33a9dd4c4`.
No raw thinking is copied into this evidence.

## Behavior and authority

An explicit nonempty `task_ids` lookup now defaults to every lifecycle state
when both `status` and `include_done` are absent. Ordinary discovery still
defaults to active tasks. An explicit status selects that state; explicit
include_done=false remains active-only and true adds Done while excluding
Cancelled. An explicit null status retains the prior active default. A supplied
nonboolean include_done is rejected, matching the published Boolean schema.

One closed `lifecycle_filter` represents the resolved scope. Runtime matching,
the cursor filter and the revision hash consume it. The former parallel
status/include_done fields are removed from the cursor. Old opaque cursor
shapes fail decoding; they are not reinterpreted or migrated. A cursor from a
different lifecycle cannot cross into another scope, and if_revision cannot
hide a lifecycle change even when the first page's visible bytes match.

The canonical tool TOML describes the actual defaults. No Task/Goal state,
ownership, approval policy, association or runtime gate changes here.

## Verification

`probe_lookup.py` executes the exact baseline runtime visibility predicate and
the repaired actual Query/Cursor/Snapshot modules, together with the exact
production revision statements. It uses the actual Task status/tag source and
a minimal typed task-record port for unrelated fields. The 27 checks pass,
covering baseline loss, all six states, discovery, explicit/null/invalid
arguments, cursor identity and production revision behavior. Changed pure
modules are compiled with their actual interfaces, with warnings4/32/69 as
errors. `source-check.json` records source hashes, commands' exits and output.
This is not full native Task-tool or Keeper execution.

The existing native `test_keeper_task_outcomes` consumer fixture is extended
through the real Task tool to cover all six persisted states, explicit filters,
page traversal through Done/Cancelled, cursor refusal and revision identity.
The parent integration executed both `test_keeper_task_outcomes` and `test_taskboard_tool_toml_parity` successfully at54e8b9b7cafab6122b8eccc9e15d8ec549e03ad8 in run40105703498. This is a targeted native consumer result, not a real model G3 verdict. Parsing and TOML validation are recorded in
`parse-check.json`. No local Dune, CI watch, old-canary mutation or new model
experiment was performed. New-candidate G3 success requires actual runtime
evidence after integration; these source checks do not establish it.
