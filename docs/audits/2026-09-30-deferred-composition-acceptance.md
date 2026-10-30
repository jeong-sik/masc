# Defer + Composition: intended behavior and acceptance

## What each concept controls

- An Instruction Skill supplies a revision-bound document through `keeper_skill`.
  The model interprets it and chooses subsequent actions.
- A Composition Skill supplies a typed plan exposed as `keeper_compose_<name>`.
  The executor binds inputs, schedules dependencies and invokes node tools.
- `defer_loading = true` controls when a tool schema becomes callable. It does
  not schedule background execution. `execution = "async"` is a separate choice.
  A node returning `Tool_result.Deferred` is also a separate execution outcome.

## Intended flow

This flow describes Agent Core lanes that can extend the running tool set.
Official-client lanes receive the complete tools plus their declared loading
plan; client-specific transport behavior needs separate verification.

```text
Keeper task
  -> capability search returns exact identity and availability
  -> keeper_tool_search loads the selected deferred schema
  -> next request of the same Agent can call keeper_compose_<name>
  -> executor validates and binds node inputs
  -> independent nodes run according to their tool descriptors
  -> dependent nodes consume validated producer outputs
  -> result and node settlements retain the exact Skill revision
```

`keeper_capability_search` does not load or execute. It is optional: an Agent
can load an exact name directly from the advertised list through
`keeper_tool_search`. Loading does not execute. Declaring a tool
deferrable does not guarantee it is hidden on every turn: history and successful
outstanding load receipts can place its schema into a later turn.

A failed producer must prevent its dependents from running. Already-started
concurrent siblings settle. This does not imply rollback of completed effects or
a persistent cursor that resumes an arbitrary partially completed plan.

## Acceptance boundaries

| Boundary | Required evidence |
|---|---|
| Discovery | Search returns the composition identity while it remains absent from callable schemas |
| Loading | Actual `keeper_tool_search` changes the same Agent's callable set |
| Execution | That Agent calls the generated composition handler |
| Dataflow | The consumer input equals the producer output from that execution |
| Failure | A controlled producer failure yields zero dependent calls |
| Evidence | Durable node settlements retain the reference, input, output and failure |
| Model choice | A real model given a task, without a prescribed tool name, discovers and uses a suitable composition |
| Product result | The requested task outcome is independently checked |

The deterministic fixture joins the production bundle, loader, composition
handler, executor and evidence store. Its real read-only nodes first search the
capability inventory, then read the lane profile and search an isolated Board
using that profile. A malformed FTS query fails the first node and prevents both
dependent nodes from running. No leaf service stub is needed. These are the
fixture's assertions, now verified by the native run below. Such a fixture cannot prove autonomous model choice,
provider transport behavior, token savings or the quality of a real task result.

## Findings before the joined test

The inspected source at `0e3348dea76ddef7ee4779c43b9e66f0e068cb77` had separate
coverage for deferred loading, composition parsing, binding, failure stopping and
evidence persistence. No inspected test joined all of those boundaries through
one deferred composition in one Agent.

The runtime catalog inspected during this audit contained 23 Instruction Skills
and 8 Compositions. The eight composition declarations were inline and none
declared `defer_loading = true`. This is a deployment snapshot, not a product
restriction or proof that the combined feature runs in production.

The revision-specific `/api/v1/skills/evidence` request returned HTTP 401. Current
production node evidence could not be verified through that API. Catalog usage
counts must not substitute for successful execution or task outcome evidence.

The existing multi-Keeper acceptance harness explicitly names its composition
fixture in mission prompts. Its observations can establish instructed use, but
do not establish spontaneous discovery and selection.

## Verification status

- Component suite CI: [36598237622](https://github.com/jeong-sik/masc/actions/runs/36598237622),
  head `0e3348dea76ddef7ee4779c43b9e66f0e068cb77`; all six targeted component suites passed (91 tests).
  This baseline predates the joined fixture.
- Joined fixture: [36653388520](https://github.com/jeong-sik/masc/actions/runs/36653388520)
  succeeded at head `7be5ba4ed79146ea95310aad155c899eda5d4f5d`.
  The suite ran all 14 cases. Its joined case confirmed schema absence,
  exact discovery, discovery without loading, successful loading into the
  retained Agent, actual node execution and producer-to-consumer binding.
  It found the seeded Board post and matched returned settlements to durable
  evidence with the exact reference and parent invocation. An invalid FTS
  query produced durable failure with only the first node settled and both
  dependent dispatches prevented. The Board post count remained unchanged.
  The fixture uses real Keeper metadata ownership and the tool-call audit
  store. It accepts the loader's text response and reads large results through
  the official output codec and integrity-checked blob store. These boundaries
  are verified through production handlers in an isolated deterministic
  workspace. This targeted Test run is separate from required PR-check
  approval, main freshness and deployment evidence.
- Current production execution: not established by this audit.
- Unprompted model selection and independently checked task outcome: not measured.

## Real-model follow-up

Use an isolated workspace with a known Board post whose searchable term matches
the Keeper lane profile. Publish a read-only deferred composition that reads the
profile and searches for that term. Give the Keeper only the task: report its
current lane profile and one matching Board post, including the post ID. Do not
name the composition or prescribe a tool sequence.

Record the frozen catalog and revision, initial provider tool surface, discovery
and loading calls, subsequent provider surface, composition invocation and node
settlements. Independently compare the final profile and post ID with the fixture.
If the model completes the task using individual tools, record task success and
absence of composition selection separately. It is evidence about discoverability,
not an execution failure. A task unrelated to the composition supplies a negative
case: unnecessary loading or invocation should remain visible in the report.

Repeat the controlled task with a producer failure and verify the actual consumer
call count and reported failure. For a follow-up turn, inspect whether history or
load receipts carried the schema before asserting a fresh load was necessary.
Retain raw artifacts with the runtime, model, binary revision and exact Skill
reference. Run this campaign only once an isolated runtime and its authorized
admin API are available; the current production API rejection does not permit
substituting private-store reads.

## Source entry points

- `lib/keeper/keeper_identity_tool_search.mli`: loading and history/receipt carry.
- `config/tools/keeper_capability_search.toml`: discovery without invocation.
- `lib/keeper/keeper_tools_agent_core_bundle.ml`: production assembly.
- `lib/keeper/keeper_tool_composition_surface.ml`: generated handler and execution.
- `lib/keeper/keeper_tool_plan_executor.mli`: scheduling, binding and failure rules.
- `lib/keeper/keeper_skill_composition_evidence.mli`: durable settlements.
- `scripts/harness/workload/keeper_multi_collaboration_acceptance.py`: real-model campaign.
