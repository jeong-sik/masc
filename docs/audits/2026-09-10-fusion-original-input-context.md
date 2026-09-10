# Original work context for Fusion deliberation

`masc_fusion` now accepts optional `task_id`, `goal_id` and `decision_context`.
The caller selects the work being discussed; the runtime reads actual Task
content and Goal criteria, rather than trusting a model-written description of
those records. A Task must be assigned to this Keeper. A selected Goal must
exist and, when a Task is also selected, must be linked to that Task. With a
Task alone, all its linked Goal criteria are included. Goal-only deliberation
does not create a Task. Omitting both IDs is explicit absence of work binding and reads or locks no Task/Goal store.

The immutable typed snapshot holds Keeper identity, the available originating
turn, Task title/description/status and its persisted completion contract/required evidence, Goal IDs and exact criterion revisions,
the original question, and separately labelled caller-written decision context.
The runtime's real turn callback supplies the turn; non-turn callers retain
null rather than a guessed trace/turn coordinate.

The question appears once in the actual computation request prompt, followed by the rendered context; the stored snapshot still retains the question for exact binding. It is
persisted in the existing accepted delivery obligation and checked against
that prompt and Keeper at decode/admission. Recovery projects the same frozen
snapshot, not current edited Task/Goal records. Older unattributed obligations
remain unattributed; absence does not manufacture context.

The final Board evidence exposes `source_context`, `model_prompt` and the
human-readable original `question`. Its typed origin carries the captured turn.
Existing Fusion detail/Board reads therefore preserve what the panel received;
Keeper adoption records from the parent PR remain a separate judgment.

Tests cover authoritative capture, foreign/unlinked scope refusal, Goal-only
absence, serialization and later-criterion independence, and the production
async tool computation boundary through durable obligation and Board projection.
They use a synthetic compute runner, not live panel providers. Syntax/TOML/diff
checks have run; compiled behavior awaits CI. No local build was performed.
This makes context attribution available; it does not prove that live Keepers
now choose Fusion appropriately or that panel judgments are correct.
