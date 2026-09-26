# Stagehand real model probe

This manual probe measures the three recorded extension `llm.generate` requests
through `Browser_stagehand_model.create`. It does not open a browser, run a
Keeper, or prove that a browser action completed.

## Build artifact

Dispatch the existing **Manual probe artifacts** workflow on the reviewed
branch with target `stagehand-model-macos-arm64`:

```sh
gh workflow run linux-x64-probe.yml --ref REVIEWED_PROBE_BRANCH \
  -f target=stagehand-model-macos-arm64
```

The workflow defaults to its existing Linux x64 artifact. Using the registered
workflow path permits dispatching the reviewed branch before it merges; a new
manual-only workflow would first need to exist on the default branch. CI builds
the macOS arm64 executable and runs offline validator controls. It never calls a
provider and receives no provider credentials. The artifact includes its source
commit, fixture, native dependency inventory and SHA-256 checksums. Native
Homebrew dependencies listed in `native-dependencies.txt` must exist on the host;
this is a probe for the operator's development host, not a relocatable release.

After download, restore execute permission if artifact extraction removed it,
then run `shasum -a 256 -c SHA256SUMS`. Permission changes do not change hashes.
Keep the artifact manifest beside the resulting evidence. Each execution also
records the source commit embedded by the existing build identity mechanism.

## Isolated configuration and host execution

Use a separate temporary base path and a reviewed runtime configuration. Keep
credentials in local environment variables referenced by that configuration.
Do not copy credentials into the artifact, command arguments, or evidence.
The production lane is read through `Runtime.init_default_strict_report` and
the published exact-output registry. The probe requires the declared
`browser_stagehand_exact` lane to contain **exactly two admitted HTTP slots in
order, with no CLI slots**. It refuses missing or dropped candidates rather
than silently reducing the test. Use the intended primary and fallback targets
(for example `glm-coding.glm-5-3`, then `ollama_cloud.deepseek-v4-flash`) from the
reviewed config. Model IDs in output come from the admitted target projection.

```sh
./stagehand_model_probe.exe \
  --config "$PROBE_CONFIG" --base-path "$PROBE_BASE" \
  --fixtures ./llm-generate-params.json \
  --repetitions 3 --injection-timeout-s 30 \
  --output ./results.jsonl 2>./private-provider-stderr.log
```

The repetitions and local injection deadline are explicit test parameters.
Real provider deadlines remain the configuration's own values. The output must
be a new file and is created mode 0600. Only `results.jsonl` is designed for
sharing. Provider stderr and the isolated config stay private: ordinary library
diagnostics can include endpoint details or provider error text.

## Routes and verdicts

Each fixture runs on primary only, fallback only, and a **synthetic primary
HTTP 503 followed by the real fallback**. The last route replaces the first
admitted target only inside the probe with a credential-free loopback refusal
target; it retains the original slot ID for ordering. It is never evidence of a
real primary provider failure. It executes the same model/fallback code, and
requires an observed loopback request plus a valid final fallback answer.

The probe records invocation counts, shape-valid counts, semantic-valid counts,
elapsed time, fixed failure categories, numeric RPC error codes and synthetic
request counts. Invocation counts are **not** provider dispatch counts. It
never prints model responses, prompts, error payloads, config paths or secrets
in JSONL. `model_rpc_refused` intentionally does not infer a provider cause from
error prose. Exit 0 requires every trial to pass; 1 means an invalid trial; 2
means setup failed. A partial JSONL without all nine summaries is incomplete.

The validator checks the recorded fixture contracts, not arbitrary JSON Schema:

- Extract: string heading and price, exactly `Order form` and `42 USD`.
- Progress: string progress and boolean completed; nonempty progress and true.
- Act: the recorded action object and argument types; click `0-18`, no arguments,
  nonempty description, and `twoStep = false`.
- Every answer must have matching structured JSON and text JSON in the expected
  Stagehand assistant envelope.

Share evidence only after matching embedded source identity, artifact hashes,
both declared target IDs, all nine summary rows and the process exit status.
