# Isolated preparation harness

This opt-in harness supports paired `upstream_inline` and `named_inline` cases. Select either a
scripted loopback streaming peer or an explicitly configured HTTP Runtime. Both
use the existing synthetic owned-job CLI peer. Configured transport alone does
not establish real model identity, Docker isolation, fleet scheduling, installed
runtime/UI behavior, or preparation speedup. Source and parser checks do not
prove that this executable has built or that either arm has completed.

An explicitly built `test/keeper_preparation_trial_driver.exe` is a prerequisite.
The runner neither builds it nor obtains a CI artifact. Supply the source commit
identity separately; the manifest records that value as caller-supplied, and the
actual executable SHA separately. That pair is not an independently verified
build receipt.

The synthetic experiment JSON has exactly these fields:

- `schema_version`: `1`.
- `case`: `"upstream_inline"` for a newly authored task plan, or `"named_inline"`
  for direct reuse of an already published named Inline Skill.
- `pairs`: an explicit positive integer.
- `runtime`: exactly `mode="synthetic_streaming"`, a nonblank `model_id`, and
  positive `max_context_tokens` / `max_output_tokens`. These are explicit
  synthetic capability declarations, with no implicit model or capability cap.
- `synthetic_outcome`: `"success"`, `"provider_refusal"`, `"malformed_final"`
  or `"fixed_child"`.
  Refusal exercises the actual Runtime error boundary. A malformed final
  contains the correct JSON in prose after actual physical work, so objective
  validation must refuse it while retaining the failed attempt's measurements.
  `fixed_child` exercises an `upstream_inline` task completed with a tagged
  constant child argument. Its objective is correct, but the Skill arm must
  remain noncompliant with the assigned upstream strategy.

For an external HTTP Runtime, keep `schema_version`, `case` and `pairs`, omit
`synthetic_outcome`, and supply `runtime` with exactly `mode="configured_http"`
and `configuration`, a TOML string. Author a minimal public configuration using
the existing Runtime provider/model/binding format. For example, an isolated
OpenAI-compatible test server can use:

```toml
[runtime]
default = "preparation_http.sample"
[providers.preparation_http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:YOUR_TEST_PORT"
credentials = { type = "env", key = "OPENAI_API_KEY" }
[models.sample]
api-name = "preparation-http-refusal-fixture"
max-context = 128000
tools-support = true
streaming = true
[models.sample.capabilities]
max-output-tokens = 4096
[preparation_http.sample]
```

For a real trial, explicitly select the provider endpoint, canonical model and
capabilities under investigation; no default model or provider is supplied by
the harness. The normal Runtime parser and adapter resolve this configuration.
Use an exact provider/model catalog row or its supported explicit capability
declaration. A bare catalog model name alone does not resolve capabilities for
an arbitrary provider ID. The loopback example declares only its synthetic
endpoint contract; its values make no real-provider capability claim.
The named credential must already exist in the process environment. The
coordinator rejects inline credentials/headers before persisting the experiment;
the driver also rejects credential files, CLI providers, Keeper assignments and
failover lanes. Do not copy a live private `runtime.toml` into this experiment.
The driver adds only the fixture's Skill settings inside its owned base.

Given those explicit input files and a built driver, run:

```sh
python3 scripts/benchmarks/keeper-composition/preparation_trial.py \
  --driver "$BUILT_DRIVER" --source-head "$SOURCE_HEAD" \
  --experiment "$EXPERIMENT_JSON" --prompts "$FROZEN_PROMPT_SOURCE" \
  --output "$NEW_PRIVATE_OUTPUT_DIRECTORY"
```

The output directory must be new. The runner preallocates both unfinished arms
for every pair before fixture setup. It never silently retries or drops an arm.
A process killed before its final receipt remains unfinished; setup failure
leaves both expected attempts unfinished. The manifest is available even if a
later driver is unavailable. There is no coordinator timeout or runtime budget.

Setup uses the real public job start/status tools, durable complete stdout/stderr
artifacts, exact published Inline Skill, and a real claimed Task pinned to that
reference. Two distinct original outputs prevent a verifier from accepting an
arbitrary available stdout. Setup is outside the measured interval and has a
separate receipt. The fixture registers its original Keeper before reading its
queue. It delivers the completed setup jobs' notifications through the producer
maintenance API, verifies their exact original sources and complete output bytes,
and ACKs only those exact selections through the durable queue API. Its separate
setup ACK receipt does not claim a model turn or source reaction timestamp;
unknown setup stimuli are refused rather than discarded. The selection artifact contains the exact selected original
job ID as UTF-8 text. No answer or resolved child argument is put into the model's
initial context.

Both arms share a read-only instruction requiring exactly one JSON object,
without prose or Markdown, and excluding new program execution to recheck
completed output. Its SHA256 is recorded and compared across each pair. This
clarified instruction is a new measurement protocol: do not compare its results
against older instruction hashes as an effect of source changes.

Both arms restore the same private fixture into the **same canonical base**.
Restore keeps every original directory inode because backend preparations freeze
those identities. It checks the snapshot file hashes, removes only extra entries
inside the experiment-owned base, restores common bytes, and checks all original
file hashes and directory identities. The original job source/Task/trace/input,
Skill bytes/reference, and model settings are identical. The strategy instruction
is the intentional prompt difference. Board IDs, clocks and loopback ports are
physical trial metadata, so full provider prompts are not claimed byte-identical.
Where observed, the first offered tool-schema hash must also agree across a
successful pair. Both native configured HTTP and synthetic runs take this
metadata from the first actual dispatch. `summary.matching` includes a pair
only after all common receipt fields agree. Its
`first_offered_inventory_reported` flag distinguishes reported inventory from
two nulls; it does not independently verify that inventory or execution.

Read an existing capture without a driver, fixtures, network or writes:

```bash
python3 scripts/benchmarks/keeper-composition/preparation_trial.py \
  --report-from /absolute/path/to/existing-capture > /tmp/preparation-report.json
```

`--report-from` cannot be combined with run arguments. It reads the manifest,
hash-bound experiment and every declared attempt, including unavailable or
invalid receipts; it does not read a driver or recreate the fixture. The shell
redirection above writes a separate report outside the capture.

`outcomes` counts coordinator assessments. Each attempt separately retains
`reported_outcome`, `receipt_state`, its original bytes' hash when readable and
the declared pair/strategy/path. A cancelled/unsupported outcome, malformed
receipt or missing file remains in the denominator as an unfinished assessment;
the original reported value and available partial fields remain visible.
`pair_comparisons` distinguishes incomplete pairs from mismatched or matched
reported metadata. JSON booleans and numbers are different declarations.
Mismatch assessments never overwrite either original `attempt.json`.
Coordinator fixture/driver failures go to `process.json`, preserving any native
receipt. Normal run finalization uses the same reader to write `summary.json`.

Each attempt also has `process_observation`, associated through its declared
pair/strategy path. It retains that `process.json` path, read state
(`read`/`missing`/`invalid`), hash of readable bytes, decoded `reported_record`
where possible, interpreted `kind` and any admission reason. The same projection
is included in the pair's reported timing arm. `process_states` summarizes these
read states over the full declared cohort, separately from `receipt_states` and
native/coordinator outcomes.

Each pair also has a shared `setup_observation`, read once from its declared
`pair-NNNN/setup.json`, and `setup_states` counts these over declared pairs
rather than attempts. It preserves the decoded object without interpreting
`setup_complete`, `unfinished`, fixture contents or its clock as proof of setup
success, timing or invocation ownership. This supplies context when setup
failure leaves both process records absent. The regular-file/hash/read-state
boundary is shared with process observations, while process variant admission
remains specific to the process reader.

The reader recognizes the coordinator's two recorded variants: an integer
`returncode` with numeric wall-clock `observed_epoch` (`driver_returned`), or
null `returncode` plus `observation: fixture_or_driver_unavailable` and string
`detail`. JSON booleans are not return codes. Unknown/partial/malformed records
remain invalid with their available hash/decoded data; absent/nonregular records
do not abort other attempts or erase their timing. A known return code is saved
outside the invocation-error handler, so a persistence error cannot rewrite a
completed invocation as an unavailable one. Such a save failure reaches the CLI
error boundary; the preallocated denominator and native receipts remain.

These are recorded metadata, not current process probes. A zero return code
does not fabricate a missing successful native receipt; another code or an
unavailability record does not overwrite a received native result. Missing
records do not mean running or stopped, negative codes are not converted into
platform-specific signal diagnoses, and epochs are not used for elapsed-time
arithmetic. Both `current_liveness_verified` and `execution_verified` stay false.
No process ID lookup, retry, signal, launch or runtime verdict is derived here.

The manifest must bind the complete expected pair/strategy/path list and exact
experiment bytes. If that declaration is invalid, reporting refuses rather than
inventing a denominator. Descendant symlinks/nonregular files are not followed.
Reports are per-file reads, not an atomic snapshot of a running experiment.
Input agreement and artifact hashes are not source/build, independent physical
execution, model identity, Task progress or speedup proof. `speedup` and latency
percentiles remain null, and execution/source-build verdicts remain false.

Each new native driver invocation owns an opaque `clock_ref`. Its counter
observations use `clock_domain: driver_counter` and canonical unsigned 64-bit
decimal `monotonic_ns` strings. `epoch` remains wall-clock metadata. The reader
does not convert legacy floating-point or untagged observations into exact
counter samples; their raw receipts remain in the denominator.

Every admitted attempt has a `timing_report`, independently of its reported
success/failure/unfinished outcome. `intervals` covers source enqueue, cycle,
cycle-return to validation, and enqueue/cycle-entry to the native-reported useful
commit. Available intervals retain exact string endpoints and `duration_ns`;
unavailable intervals carry a reason instead of zero or a guessed timestamp.
Both endpoints must name the receipt's counter and must not regress. Wall-clock
intake/replay observations are retained without arithmetic. Absolute counter
endpoints from separate driver invocations are never subtracted from one another.

Useful-commit intervals additionally require recorded metadata agreement:
frozen fixture/hash and original Task/trace, canonical turn record, original
admission/intake marker and marker digest, and complete Tool-commit journal
hash/coverage with a unique full-identity join to the original selection read.
The nominated commit must fall within the reported cycle. Missing or mismatched
evidence withholds that useful interval while valid cycle spans remain visible.
`timing_report.identity` retains artifact hashes and its join outcome. These are
recorded metadata checks, not reexecution or independent verification of SDK
ownership, stdout content, first-successful-leaf semantics or physical execution.
No averages, percentiles, ratios or speedup verdicts are derived here. The
additional native observation encoding and offline file reads have unmeasured
overhead; matched actual cohorts and full protocol verification remain separate.

Every `pair_comparisons` entry also has `reported_timing`. It selects the arms
by declared strategy, even when physical execution order is reversed:
`baseline_strategy: direct`, `comparison_strategy: exact_skill`. Each interval
retains both original reported spans and either a signed exact integer string
`exact_skill_minus_direct_ns` or null plus `unavailable_arms`. Positive means
the reported `exact_skill` duration is longer; negative means shorter. Zero
durations require no division. These strategies do not label source versions
or the chronological first/second invocation.

Differences require admitted receipts, agreement on the existing common input
fields, the declared experiment case, reported nonblank fixture/inventory/common
instruction hashes and distinct reported counter owners. `blockers` identifies
an unmet pair prerequisite. Matching two null tool inventories does not supply
inventory coverage. Per-interval failures remain separate: an unavailable useful
commit or validation endpoint does not erase a valid cycle comparison. Each
duration is derived inside its own counter before comparing durations; no wall
or cross-owner absolute counter arithmetic is introduced.

All declared pairs remain, including failed/unfinished/cancelled/invalid/missing
arms. `reported_timing.arms` retains receipt state, original reported outcome,
receipt hash and reported owner. Available partial durations of failed attempts
can be compared without turning the functional pair into a success. Existing
`matching`, coordinator assessments and original evidence files retain their
meaning. Input agreement and differences of reported durations are still
unverified observations: pair execution/source verdicts remain false, and the
summary's speedup and latency percentiles remain null.

Each arm actually creates an addressed Board post, verifies one exact durable
queue selection, classifies lifecycle admission, and calls the explicit heartbeat
cycle through its real Owner. Prompt construction, Runtime selection, streaming
provider requests and all public tool calls run inside production code. The
synthetic provider loads held-back schemas using the actual `keeper_tool_search`
when necessary. It never executes a tool. Both arms use the SDK's normal scheduler
and actual descriptor execution modes; there is no forced serial control policy.
This one case has data dependencies and makes no concurrency-overlap claim.

Both arms physically read the original selection artifact. The direct arm uses
ordinary calls to read that selection, the selected original job result and its
stdout. The successful `upstream_inline` Skill arm submits one
`keeper_composition_run.recipe`. Its first producer reads the selection once;
the exact published Inline Skill consumes that actual output through its tagged
input template. Outer exports return the selected `job_id` and child `stdout`.
The scripted peer derives its answer from those actual model-visible exports;
fixture expectations and sealed audit manifests only validate the execution.
The current Task's selected schemas include the public run control, so this
path requires neither a preliminary read nor loader/prepare exchanges. Real
model adoption still requires a configured cohort. Publication outside the
clock is the declared starting condition, not hidden authoring work.

In `named_inline`, the Skill arm instead calls the existing named Tool with the
selected `job_id`. Its Tool name comes from the frozen executable Skill catalog;
no transient prepare/run or upstream child is required. The Skill document,
output contract and strict objective stay the same. A named invocation joins its
exact Task Skill activation, revision, turn, Runtime, original SDK call/input and
physical complete stdout leaf. A valid named call in an `upstream_inline`
experiment still fails that experiment's assigned strategy. Keep that original
outcome and run a separate named case; do not retroactively change compliance or
combine the two cases into a speed comparison.

Success requires an actual physical full stdout read in this original turn,
the independently checked complete stdout digest, the actual
persisted Keeper final JSON from the exact raw run owned by its TurnRecord,
the original job source and output digests unchanged,
its exact stimulus ACK, matching Task/trace/absolute turn, physical execution
ownership and zero backend calls after complete outputs. A direct read belongs
to the TurnRecord's SDK trajectory. A composition leaf joins its exact canonical
execution artifact and original SDK parent; its child execution ID is not an
outer SDK trajectory ID. The parent's full reply comes from the exact raw run,
not the potentially truncated call-log preview. Internal
final thoughts are deliberately excluded from replay checkpoints (RFC-0385),
so their last Assistant message is recorded separately and never substituted
for the exact-run final response. The fixture also checks the ordinary
autonomous inspector's exact turn/run projection; an unavailable run remains
unverified. Strategy
compliance is recorded separately; noncompliance stays in the assigned arm.
An outer plan with no selected exports is also valid. Its sealed canonical
reply retains full `actions`; a plan selecting exports instead retains the
complete node evidence through `execution_artifact`. Physical ownership and
resolved upstream arguments join the corresponding node facts in either
representation. Neither representation substitutes for the original SDK
reply, manifest hash, execution ID, Task/trace/turn or exact Skill activation.
`Completed` alone is insufficient. Upstream Skill compliance joins the activation
to the original SDK parent reply, immutable prepared manifest, resolved child
argument and physical stdout execution. Model-generated tool-use IDs and child
aliases need not match the scripted peer. There are no latency percentiles or
speedup calculations in this harness yet.

A tagged child template containing only constants is executable, but does not
prove an upstream dependency. The upstream measurement now follows the child
argument's typed `/content` output reference in the frozen canonical plan to
the exact original selection reader, then joins its actual complete successful
read to this same run/SDK parent/Task/turn. This stricter measurement supersedes
older compliance observations that checked only the serialized `upstream` kind
and resolved argument value. Keep those older receipts unchanged and annotate
the limitation when citing them.

Final validation records a closed outcome: verified JSON, missing/malformed
final, wrong object shape, wrong original job/digest, or scripted wire mismatch.
It never extracts a JSON fragment from prose. A returned cycle first persists
its admission/entry/return clocks; after evidence collection, the receipt also
retains physical stdout ownership, first useful observation, strategy compliance
and reported provider usage before any later boundary rejection. The final
`validation_finished` clock is present only when those checks return. Failed
attempts stay failed with their available metrics; absent observations stay
unknown. Backend call counts come from the actual synthetic peer's saved calls.

Admission records canonical source ID, snapshot reference, revision and
`first_admitted_at`, plus separate enqueue entry/return observations. The scoped
`durable_tool_call_commit` observer records original identities and a local clock
in `tool-commit-events.jsonl`, including native composition leaves. The receipt's
`tool_commit_observation` reports its mode, delivery failures, event count and
journal hash. Every observed occurrence must join one-to-one with its actual
physical ledger row; incomplete coverage leaves the useful clock `unknown`.
Owner handoffs capture this scope explicitly, including an absent observer.
The earliest successful original selection leaf retains its physical execution,
SDK coordinates and schedule. A native leaf also joins the exact SDK parent
reply and canonical execution artifact. No parent-return clock substitutes for
the leaf's own durable commit observation.

This opt-in scope requires synchronous appends and sidecar writes. Use the same
observer on both arms and report its I/O cost; ordinary product callers retain
their existing append mode. Earlier SDK-callback clocks are a different boundary
and cannot be combined with these timings. This observes durable completion
evidence, not execution start. The cycle call entry
and return are separate monotonic observations. Board signals currently do not
receive the source-bound reaction ledger `Turn_started` written for
Schedule/HITL/Ask. Generic runtime/SDK turn-start records are a different
coordinate and are not fabricated into that missing timestamp. All elapsed
observations are local to one driver process; setup and other arms are not
subtracted from them.

Only the synthetic loopback peer captures its actual safe request JSON bodies
and SSE response bytes. It captures no headers or credentials and never imports
private runtime config. `Request_wire_observer` remains hash/size metadata and is
not described as a full body recorder. Tool-call log outputs can be previews;
canonical markers, normalized references and durable manifests are decoded and
compared before verification. Request/response capture and durable receipt I/O
are measurement overhead included in these instrumented samples.

Configured HTTP receipts retain the exact TurnRecord's selected model and
provider-reported token usage with its original usage scope. Missing counts stay
null. The selected alias is not response-reported model identity. Complete
provider request count, first offered inventory and response-reported model are
not inferred from that last report. The separate `http_metrics` journal now
observes each actual native HTTP POST client entry, submitted body size/hash,
concrete dispatch entry, response headers and client return within the owned
cycle. It includes synchronous and streaming POST paths. The observation
context crosses the existing Owner handoff with an explicitly captured
closure; a binding on the submitting fiber alone cannot observe the already
running Owner. The same real-cycle peer comparison checks this boundary. Counts and total
serialized/submitted bytes remain null if observation delivery failed, the file
is unavailable or a call's phase sequence is incomplete/contradictory. A client
return is not provider/parser success, and submitted bytes are not a claim that
the peer acknowledged every network byte. There is no full-body capture or new
runtime gate. The serializer separately binds the final body's Tool inventory
to that exact body digest. `first_dispatched_tools` records absent/present/
unavailable metadata from the first dispatch; an unobserved producer stays
null. A present array records top-level wire entries and compact Yojson byte
count/SHA256 with object and array order preserved. Gemini's function wrapper
is one wire entry; this is not a universal function count or semantic JSON
canonicalization. No schema content is exposed. The receipt's first offered
hash comes from this native evidence, including configured HTTP refusals, and
never from the last input snapshot. Response-reported model remains unobserved.
Do not substitute zero for missing evidence. The same failure/unfinished
denominator applies to configured HTTP trials, including noncompliant arms.

The same `client_entered` rows now retain `request_components`, and the receipt
retains `first_dispatched_components` from the first actual dispatch. Observed
components list each top-level JSON field occurrence's encoded key/colon/value
bytes and value size/SHA256, plus the outer framing bytes. These sum to the exact
submitted body only when the serializer's compact re-encoding reproduces it
byte-for-byte. Unavailable metadata remains explicitly unavailable; an unobserved
producer stays null. No field value crosses this metadata channel.

Compare protocol fields in their own codec: `messages` may contain system text,
while `system` or `systemInstruction` can be separate fields in other codecs.
Compare first and subsequent calls under their actual call IDs, retain growing
conversation members, and report unchanged value digests separately from saved
bytes. Repeated Tool or system encoding is not evidence it can be removed from
the provider protocol. This unit changes observation only, so it establishes no
request reduction or preparation speedup.

The scripted peer additionally saves its original synthetic request in
`provider-request-<n>.body`, alongside the existing decoded JSON view. Verification
binds raw bytes to the peer's reported size/hash and independently measures JSON
value slices using Python's decoder. It does not re-encode pretty JSON and call
that the received wire body. Configured external Runtime calls keep metadata
only; this does not enable full-body capture for them.

The explicit targeted CI entry is `test_keeper_preparation_trial`, declared as
`@runtest-test_keeper_preparation_trial`. Its Dune action declares the compiled
driver dependency and explicit synthetic model/capability inputs. It launches
this coordinator with one real matched pair, then checks every denominator,
physical first-leaf/Task/trace/ACK join, same common input/inventory, actual exact
Skill activation, resolved child argument, persisted final digest and backend0.
It also runs a separate named-reuse pair through the actual named Skill Tool,
checking its activation and original physical leaf/SDK parent without prepare/run.
The fixed-child scenario additionally completes both objectives while retaining
the Skill arm's noncompliance, distinguishing a template from an actual dependency.
It also crosses an independently hosted loopback HTTP refusal through the
configured Runtime branch for both arms, checks the fixture environment
credential binding, and retains both refusals as explicit failures. That server
is synthetic and does not exercise a paid provider. Native HTTP size/hash and
dispatch/header counts and Tool metadata are compared with independently
received peer bytes and Tool arrays for
both normal and refused requests. A malformed-final pair
uses a valid no-outer-exports Skill run and verifies that already completed
physical work, source ACKs, clocks and usage
remain available when the final response violates the JSON contract; both
attempts remain explicit failures in the denominator.
That case submits the fresh recipe through `keeper_composition_run` without a
separate prepare. Its original SDK input is joined to the returned sealed draft,
run artifact, invocation turn and exact child mappings before accepting physical
stdout evidence. The malformed-final case keeps its preliminary selection read
and exercises repeated successful reads while retaining the earliest committed
occurrence. The normal pair exports the selection and stdout in one recipe call.
These different synthetic cases do not establish a latency comparison.
Both recipes pass the selection reader's fixed arguments through ordinary
`args`, while the child keeps its tagged upstream input. The same public
compiler normalizes the ordinary object and revalidates the frozen draft.
It is not a no-argument invocation of the parameterized driver. Authoring this
alias is not evidence that it has executed.
