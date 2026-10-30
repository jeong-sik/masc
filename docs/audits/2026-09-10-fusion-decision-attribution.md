# Keeper adoption of Fusion advice

A Fusion result already has durable Board, chat and run-status evidence. That
is the panel/judge advice, not proof that the requesting Keeper adopted it.
This change adds `masc_fusion_decision`, a descriptor-backed Keeper model tool,
for the Keeper's separate `adopted`, `rejected` or `modified` choice and reason.

This first slice records decisions on an assigned Task. Linked Goal IDs are
read from the existing authoritative goal-task links. A goalless Task remains
valid; a goal-only decision without a Task is outside this slice. No Task is
created automatically and no general decision requires Fusion.

The source must be an existing durable Fusion Board post owned by this Keeper.
The event records its exact run/post IDs and an evidence digest. Actor and turn
come from the runtime, not tool arguments. Task ownership is held under the
backlog lock through the event write. The context is the adoption turn's Task
and Goals; this does not retroactively claim the panel saw that context.

The record is a `fusion_decision` event in the existing `.masc/events` task
history journal, not a new decision database. Its identity binds run, Task,
Keeper and turn. An exact same-turn retry returns the original event; a
conflicting rewrite is refused. A later turn can record a new judgment without
overwriting history. Appending uses the existing durable locked JSONL writer;
a committed append with cleanup failure returns the recorded event plus an
explicit warning. An unreadable journal cannot be treated as an empty history. Domain/ownership
refusals are typed `Rejected`; storage reads, malformed journal rows and append
failures are typed `Storage_failure`, projected as runtime failures. No error
message text selects the failure class.

Readback is available in `masc_task_history`, the existing dashboard Task
history (including choice/reason in notes), `masc_fusion_status` with a run ID,
and `keeper_decisions` on the dashboard Fusion run detail API. The latter read
projection distinguishes unavailable history from an empty list. Fusion's
judge recommendation remains separate and unchanged.

`test_fusion_decision` exercises the actual descriptor runtime dispatch,
filesystem event write, Task/Goal/turn binding, Task and Fusion readback,
idempotent retries, conflicting decision, foreign/missing source, absent turn
and corrupt history. At authoring only OCaml syntax parsing, TOML parsing and
diff checks have run. No local build or live model execution was performed;
targeted CI must establish compiled behavior. This is a usable recording path,
not evidence that Keepers now consult Fusion for important decisions in live
operation or that the chosen judgment is semantically correct.
