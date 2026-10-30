# Claude native task input binding

This prerequisite connects private runtime task admission to its original host
input and materialized Keeper attempt. It does not publish task events or extend
the official client's receiver lifetime.

## Ownership boundary

`Keeper_claude_task_binding` accepts only private
`Runtime_claude_input_attribution.observation` and
`Runtime_claude_code.native_task_observation` values. The public
`Runtime_native_tasks.of_json` decoder cannot construct either an admitted native
owner or a bound task.

The adapter creates one binder immediately around each actual runtime invocation.
Prepared captures that invocation's ticket. A different generation, session or
client UUID conflicts; no newer ticket replaces it. The runtime reports exact
root Assistant attribution before it registers that envelope's native blocks.
The binder retains the evidence under the literal envelope UUID:

- `Explicit_group`: that frame's provider group contains the actual input UUID.
- `Response_inherited`: the input fold validated the response occurrence and
  its group contains that UUID.
- `Command_inherited`: the input fold supplied its private typed-command witness,
  retaining the actual stamp UUID and consumed group.

Prepared/Written/Consumed/Settled phase alone, a partial frame, model ID, result
stamp, text, current block, latest ticket or native call name is not this join.
The binder does not recreate the input fold's command or replay rules.

An admitted task owner's original session, assistant envelope, native ordinal
and call ID select its frozen binding. Missing/rejected first ownership is not
upgraded by a later stamp. Conflicting envelope evidence rejects subsequent
bindings without rewriting previously delivered facts. Native call completion,
task terminal observation and root result do not erase the binding. No task
observation changes root content, usage, effects, retry eligibility or phase.

The runtime's separate admission registry remains responsible for Native_full,
Root_response/Built_in Agent, provider root spawn depth, original call occurrence,
task/run identity and task terminal boundary. Binding must not reconstruct these
facts from public metadata or reopen a closed native content index.

## Callback and direct consumers

The adapter's `on_native_task_observation` now carries the private `bound` record.
The driver adds `attempt:Runtime_native_tasks.attempt`, captured from the actual
dispatch's routing run, runtime and lane index. A second actual invocation inside
the same candidate gets a new input generation from the runtime; the candidate
attempt itself remains the original materialized attempt.

`Keeper_agent_run` passes both values through
`Keeper_hooks_agent_core.Native_task_observed {attempt; bound}`. Direct and
autonomous collectors and the tool receipt projector explicitly leave task
metadata unprojected in this prerequisite. They do not stamp the current stream
scope, flush model text, manufacture tool receipts or emit an unsupported CUSTOM
event. The next journal unit can obtain the operation/autonomous source from its
own publisher and combine it with these frozen values.

## Authored behavioral coverage

The existing `test_keeper_claude_code_runtime` suite uses the actual SDK
handshake/user input and adapter/driver APIs. Its fixture stamps the UUID parsed
from the real written user envelope, rather than a guessed ticket:

- Two native Agent blocks in one attributed envelope retain separate ordinals;
  registration after one native call closes still binds correctly. Driver task
  callbacks match the actual admitted attempt before root response stop.
- Two actual driver invocations retain distinct input generations and routing
  runs even when their fixture provider envelope/call strings are reused. One
  binds an explicit complete envelope; the other inherits the exact attributed
  partial response into its complete native envelope.
- An unattributed old native owner cannot acquire a later command witness.
  A subsequent complete-only root Agent uses that witness's exact stamp; task
  replay and unknown task progress do not add callbacks.
- The existing closed-native-owner task fixture retains its Text and Thinking
  split-secret assertions, body preservation and unchanged content/phase events.

Native_full fixtures temporarily set the exact test Keeper's approval mode to
Yolo and restore its previous value with `Fun.protect`. Production admission is
unchanged. These tests are authored, not executed locally. Syntax parsing and
source review do not establish their runtime outcome.

## Remaining work

This unit was authored on `ef2be631b6fb122f9b267e157055ca6634deaced` and propagated
after freezing onto `bd2ab77b55f5eec85407a44f2a282f02495fb813`. That parent includes
the reused-model-ID command repair and signed elapsed/pause observations. The
input and task callback APIs are unchanged. This unit does not rewrite either
implementation, and requires its own review at this changed base.

Task journal/AG-UI/TUI/dashboard transport and visible task rendering remain
required. The current runtime still closes at its first root result. A later
persistent session receiver needs a task sink owned independently of the root
operation stream and an explicit multi-input registry; retaining this callback
does not provide that lifetime. Post-result task updates, new user input,
cancel/resume, and a real compiled-TUI screenshot remain separate unverified work.
