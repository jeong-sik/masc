# Task creation and Goal measurement are present from the first request

The actual Keeper canary used embedded candidate
`7501aec032012869d8b979e0d14e1a9a9464ace7` and local Ollama `gemma4:e2b`.
`baseline.json` retains raw request/response SHA-256 and byte lengths, the
initial 31 tool names, the model's Task-create arguments, the matching wire
receipt, and the empty authoritative Task backlog snapshot. It retains no
provider Thinking text. The recorded health report identifies the embedded
candidate and executable SHA-256 independently of its checkout's later head.

The initial raw request `request-000003.request` contains the shared Goal ID,
current criterion revision and baseline measurement ID. It offers Task claim
and submit but does not offer Task creation or Goal measurement. The model
then emits `keeper_task_create` with the correct existing
`goal-canary-three-results` in `request-000006.response`; the corresponding
request still does not offer that schema. The captured backlog has no Tasks.
This establishes a reproduced Task-creation availability failure after Goal
context delivery. It does not establish a reproduced Goal-measurement failure:
no attempted measurement is claimed in this baseline.

Both canonical tool files declared `defer_loading = true`. The descriptor
reads that declaration using its internal name. The bundle partitions
Deferrable tools behind the existing loader, while Always_loaded tools join
the initial surface. The shared runtime prompt instructs Keepers to create
work Tasks, link relevant Goals, inspect actual results and record Goal metric
observations. Both handlers were already accessible through the loader.

This repair removes the two deferral declarations. In the canonical
`Tool_definition_toml.load` parser, an absent declaration means Always_loaded.
Task creation therefore becomes directly callable from the first eligible
request; Goal measurement becomes directly callable for the following result
measurement step. The latter is an intentional workflow improvement based on
the same delivery boundary, rather than a claimed measured failure. Existing
profile deny, capability and effect-authorization boundaries still apply.
No tool arguments, handler, Task/Goal state transition, gate or prompt changes.

Loading declarations come from `Tool_loading_declarations.table`, which reads
`Embedded_config` once per process. They do not come from managed runtime tool
copies. Editing a source or managed TOML next to the existing 7501 binary
cannot validate this repair. An exact rebuilt binary embedding these source
files is required for a fresh wire/canary comparison. The old canary and its
managed configuration were not mutated by this author.

Validation here is read-only actual baseline inspection, standard TOML
parsing of both changed declarations, source tracing of the canonical
parser/descriptor/bundle path, and `git diff --check`. See
`source-check.json`. No new unit test mirrors the loading declaration. No
local Dune build, native execution or post-fix Keeper success is claimed.
The parent session owns the exact build and live measurement of Task creation
and post-approval Goal measurement. Goal upsert/list/transition and the other
deferred tools are outside this change.
