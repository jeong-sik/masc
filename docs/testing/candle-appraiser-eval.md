# Candle appraiser semantic evaluation

The lifecycle and transport suites use injected answers. This opt-in probe calls
`Server_candle_appraiser.run` with real provider responses and preserves each
production exact-run receipt. It starts no server or payout worker and writes no
Goal, Task, Candle ledger, or `Paid` event.

## Prepare without calling a model

Run `scripts/candle-appraiser-eval.py prepare` with explicit arguments:

```sh
python3 scripts/candle-appraiser-eval.py prepare \
  --source-runtime /path/to/existing/runtime.toml \
  --runtime provider.model \
  --workspace /path/to/new-private-workspace \
  --source-commit <exact-CI-source-SHA> \
  --max-output-tokens 4096 \
  --exact-body-timeout-s 1200 \
  --trials 20
```

The workspace must not exist. Only the selected HTTP provider, model and binding
are copied. The provider must reference an available environment credential;
the value is never written. Its body deadline and the lane's output limit are
explicit evaluation conditions recorded in `plan.json`. The source configuration
is read only. The current probe covers one HTTP slot, with no fallback.

The fixed 12 cases exercise Grade title/metric injection and verbose wording,
related/unrelated Relation decisions and injection, and Weights injection,
candidate ordering, Keeper renaming, and equivalent Task splitting. Twenty
repetitions come from RFC-goal-candle-ledger §5. This is 240 stage calls.

## Obtain and run the CI executable

Dispatch `linux-x64-probe.yml` on the reviewed branch with
`candle_appraiser_eval=true`. The artifact includes `candle_appraiser_eval_cli.exe`
and its SHA-256 manifest. CI builds the executable and makes no model calls.
The executable refuses a build commit different from `plan.json`.

On a Linux host, run the artifact with `--base-path WORKSPACE` to validate the
prepared files without model calls. Add `--execute` to run the declared slot.
`--evidence-path` must name a new output directory; it defaults to
`WORKSPACE/evidence`. Existing evidence is never overwritten.

On macOS, an existing Docker daemon with amd64 emulation can run the same
artifact. Mount the artifact and prepared workspace read only, and a separate
private output parent writable. Pass only the credential environment name from
`plan.json`, using Docker's `--env NAME` form so the value is inherited without
appearing in arguments. Do not pass the host's entire environment or mount a
live workspace. For example, after verifying the image's amd64 support:

```sh
docker run --rm --platform linux/amd64 --read-only \
  --tmpfs /tmp:rw,nosuid,nodev \
  --env PROVIDER_CREDENTIAL_VARIABLE \
  --mount type=bind,src=/path/to/artifact,dst=/artifact,readonly \
  --mount type=bind,src=/path/to/prepared-workspace,dst=/fixture,readonly \
  --mount type=bind,src=/path/to/private-output-parent,dst=/output \
  --workdir /tmp ubuntu:22.04 \
  /artifact/candle_appraiser_eval_cli.exe --base-path /fixture \
  --evidence-path /output/run --execute
```

The runtime image must supply the binary's linked libraries and trusted CA
certificates. Validate that environment without credentials before execution;
an image starting successfully alone does not establish library availability.

## Read results without manufacturing a pass

```sh
python3 scripts/candle-appraiser-eval.py report \
  --workspace /path/to/prepared-workspace \
  --evidence-path /path/to/private-output-parent/run
```

`results.jsonl` retains every trial, decision or typed error, and full run
receipt. The receipt includes the rendered prompt, actual answering slot and
raw response evidence. `metadata.json` binds the plan to the running binary.
`report.json` keeps missing trials and rejection counts, modal answers including
ties, and measured weight shares. Duplicate trial rows are rejected.

There is no global PASS. The RFC's proposed acceptance thresholds need operator
adoption. Calibration remains `not_performed` until a separate set of 20
human-graded Goals is supplied. A high count on synthetic cases does not replace
that calibration or show that a different model/slot behaves the same way.
Copy reviewed non-secret results to `docs/evidence/<date>-candle-appraiser/`;
private runtime files and credential values do not belong in that bundle.
