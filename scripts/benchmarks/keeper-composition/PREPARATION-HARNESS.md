# Isolated preparation harness

This opt-in harness authors one matched `upstream_inline` case. Its provider is
a scripted loopback streaming peer and its Docker CLI is the existing owned-job
protocol peer. It measures instrumented **synthetic explicit-cycle** work. It is
not a real model trial, Docker isolation proof, fleet scheduling measurement,
installed runtime/UI result, or speedup result. Source and parser checks do not
prove that this executable has built or that either arm has completed.

An explicitly built `test/keeper_preparation_trial_driver.exe` is a prerequisite.
The runner neither builds it nor obtains a CI artifact. Supply the source commit
identity separately; the manifest records that value as caller-supplied, and the
actual executable SHA separately. That pair is not an independently verified
build receipt.

The experiment JSON has exactly these fields:

- `schema_version`: `1`.
- `case`: `"upstream_inline"`. Other cases are not implemented.
- `pairs`: an explicit positive integer.
- `runtime`: exactly `mode="synthetic_streaming"`, a nonblank `model_id`, and
  positive `max_context_tokens` / `max_output_tokens`. These are explicit
  synthetic capability declarations, with no implicit model or capability cap.
- `synthetic_outcome`: `"success"` or `"provider_refusal"`. The latter lets the
  actual Runtime reject the fixture response while keeping every planned sample
  in the denominator. Real/paid providers and private Runtime TOML are refused.

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
separate receipt. The selection artifact contains the exact selected original
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
The first offered tool-schema hash must also agree across a successful pair.

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

Success requires the complete actually returned stdout digest, the actual
persisted Keeper final JSON, the original job source and output digests unchanged,
its exact stimulus ACK, matching Task/trace and physical execution membership in
the actual TurnRecord, and zero backend calls after complete outputs. Strategy
compliance is recorded separately; noncompliance stays in the assigned arm.
`Completed` alone is insufficient. There are no latency percentiles or speedup
calculations for these protocol samples.

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

The explicit targeted CI entry is `test_keeper_preparation_trial`, declared as
`@runtest-test_keeper_preparation_trial`. Its Dune action declares the compiled
driver dependency and explicit synthetic model/capability inputs. It launches
this coordinator with one real matched pair, then checks every denominator,
physical first-leaf/Task/trace/ACK join, same common input/inventory, actual exact
Skill activation, resolved child argument, persisted final digest and backend0.
It is not a no-argument invocation of the parameterized driver. Authoring this
alias is not evidence that it has executed.
