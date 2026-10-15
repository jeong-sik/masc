# Isolated preparation harness

This opt-in harness authors one paired `upstream_inline` case. Select either a
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
- `case`: `"upstream_inline"`. Other cases are not implemented.
- `pairs`: an explicit positive integer.
- `runtime`: exactly `mode="synthetic_streaming"`, a nonblank `model_id`, and
  positive `max_context_tokens` / `max_output_tokens`. These are explicit
  synthetic capability declarations, with no implicit model or capability cap.
- `synthetic_outcome`: `"success"` or `"provider_refusal"`. The latter lets the
  actual Runtime reject the fixture response while keeping every planned sample
  in the denominator.

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
api-name = "gpt-4o-mini"
max-context = 128000
streaming = true
[preparation_http.sample]
```

For a real trial, explicitly select the provider endpoint, canonical model and
capabilities under investigation; no default model or provider is supplied by
the harness. The normal Runtime parser and adapter resolve this configuration.
Use a catalog-backed model or its supported explicit capability declaration.
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

Both arms restore the same private fixture into the **same canonical base**.
Restore keeps every original directory inode because backend preparations freeze
those identities. It checks the snapshot file hashes, removes only extra entries
inside the experiment-owned base, restores common bytes, and checks all original
file hashes and directory identities. The original job source/Task/trace/input,
Skill bytes/reference, and model settings are identical. The strategy instruction
is the intentional prompt difference. Board IDs, clocks and loopback ports are
physical trial metadata, so full provider prompts are not claimed byte-identical.
Where observed, the first offered tool-schema hash must also agree across a
successful pair. Configured HTTP runs currently leave that hash unobserved;
`summary.matching` records this limit instead of treating two nulls as proof of
matched tool inventory.

Each arm actually creates an addressed Board post, verifies one exact durable
queue selection, classifies lifecycle admission, and calls the explicit heartbeat
cycle through its real Owner. Prompt construction, Runtime selection, streaming
provider requests and all public tool calls run inside production code. The
synthetic provider loads held-back schemas using the actual `keeper_tool_search`
when necessary. It never executes a tool. Both arms use the SDK's normal scheduler
and actual descriptor execution modes; there is no forced serial control policy.
This one case has data dependencies and makes no concurrency-overlap claim.

Both arms first read the original selection artifact. The direct arm then reads
the selected original job result and its stdout. The Skill arm authors a transient
prepare/run whose explicit output template binds the child argument from another
actual selection read. That extra read and prepare/run cost remain inside its
clock. The child uses the exact published Inline Skill. Publication outside the
clock is the declared starting condition, not hidden authoring work.

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
`Completed` alone is insufficient. Exact Skill compliance joins the activation
to the original SDK parent reply, immutable prepared manifest, resolved child
argument and physical stdout execution. Model-generated tool-use IDs and child
aliases need not match the scripted peer. There are no latency percentiles or
speedup calculations in this harness yet.

Admission records canonical source ID, snapshot reference, revision and
`first_admitted_at`, plus separate enqueue entry/return observations. A synchronous
actual tool observation is joined to a unique committed physical execution row
for the first successful selection leaf, including SDK coordinates and schedule.
An absent/ambiguous join stays `unknown`. Its observer time follows the actual
result/log commit; it is not an execution-start timestamp. The cycle call entry
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
provider request count, total serialized input bytes, first offered inventory and
response-reported model are currently unobserved. Do not infer them from the last
request's wire metadata or substitute zero. The same failure/unfinished
denominator applies to configured HTTP trials, including noncompliant arms.

The explicit targeted CI entry is `test_keeper_preparation_trial`, declared as
`@runtest-test_keeper_preparation_trial`. Its Dune action declares the compiled
driver dependency and explicit synthetic model/capability inputs. It launches
this coordinator with one real matched pair, then checks every denominator,
physical first-leaf/Task/trace/ACK join, same common input/inventory, actual exact
Skill activation, resolved child argument, persisted final digest and backend0.
It also crosses an independently hosted loopback HTTP refusal through the
configured Runtime branch for both arms, checks the fixture environment
credential binding, and retains both refusals as explicit failures. That server
is synthetic and does not exercise a paid provider.
It is not a no-argument invocation of the parameterized driver. Authoring this
alias is not evidence that it has executed.
