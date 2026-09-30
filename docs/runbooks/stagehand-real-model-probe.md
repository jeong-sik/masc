# Stagehand real model probe

This manual probe measures the three recorded extension `llm.generate` requests
through `Browser_stagehand_model.create`. It does not open a browser, run a
Keeper, or prove that a browser action completed.

## Build artifact

Dispatch the existing **Manual probe artifacts** workflow on the reviewed
branch with target `stagehand-model-macos-arm64`:


Dispatch only for operator-requested verification or evidence required by a selected `ci:run` candidate. Reuse an existing run for the same purpose.

```sh
gh workflow run linux-x64-probe.yml -f run_requested=true --ref REVIEWED_PROBE_BRANCH \
  -f target=stagehand-model-macos-arm64
```

The workflow defaults to its existing Linux x64 artifact. Using the registered
workflow path permits dispatching the reviewed branch before it merges; a new
manual-only workflow would first need to exist on the default branch. CI builds
the macOS arm64 executable and runs offline validator and configuration-publication
controls. The latter uses a committed loopback config with a public synthetic
credential sentinel and exercises the same runtime initialization and registry
publication as the real probe, without invoking any model callback. It never calls a
provider and receives no provider credentials. The artifact includes its source
commit, fixture, native dependency inventory and SHA-256 checksums.
If an offline control fails, CI remains failed and still packages the built binary
with `offline-controls.json`: exit codes and fixed failure categories only. Each
control passes `--control-result`, and the probe writes its outcome there as one
JSON object; a setup category is kept only when `--list-setup-reasons` lists it. The
manifest repeats those results; a retained diagnostic artifact is not a passed
setup control. Raw process output is never uploaded. Native
Homebrew dependencies listed in `native-dependencies.txt` must exist on the host;
this is a probe for the operator's development host, not a relocatable release.

After download, restore execute permission if artifact extraction removed it,
then run `shasum -a 256 -c SHA256SUMS`. Permission changes do not change hashes.
Keep the artifact manifest beside the resulting evidence. Each execution also
records the source commit embedded by the existing build identity mechanism.
The packaged synthetic `runtime-publication.toml` reproduces the setup control:

```sh
./stagehand_model_probe.exe --config-publication-self-test \
  --config runtime-publication.toml
```

This command stops after publication and lane admission; it does not call
`Model.create` or count as real-provider evidence.

## Isolated configuration and host execution

Use a separate temporary base path and a reviewed runtime configuration. Keep
credentials in local environment variables referenced by that configuration.
Do not copy credentials into the artifact, command arguments, or evidence.
The production lane is loaded through `Runtime.init_default_strict_report`, then
published by the server's existing `configure_exact_output_registry` boot step. The probe requires the declared
`browser_stagehand_exact` lane to contain **exactly two admitted HTTP slots in
order, with no CLI slots**. It refuses missing or dropped candidates rather
than silently reducing the test. Use provider-qualified primary and fallback
bindings from the reviewed isolated config, with the provider's currently
served API model identity recorded for each. Admission checks the local catalog
and request capabilities; it does not establish account access or provider
availability. Model IDs in output come from the admitted target projection.

### Prerequisites after the failed provider measurement

The [typed diagnostic evidence](../evidence/stagehand-real-model-20260927/typed-diagnostic/README.md)
records 27 invocations on source `fedd7dbabfcbdd14eab3480531abe7323f0148d9`:
primary GLM returned 429 in 9/9, the old Ollama fallback returned 410 in 9/9,
and synthetic primary 503 advanced to that fallback, which returned 410 in
another 9/9. No response reached shape validation. Preserve that failed run;
do not repeat the same 27-call configuration as a readiness check.

Before another provider measurement:

1. Review the replacement binding and its provider identity. On 2026-09-28,
   [Ollama's old Flash page](https://ollama.com/library/deepseek-v4-flash)
   still records retirement on 2026-09-25; the
   [V4.1 Flash tags](https://ollama.com/library/deepseek-v4.1-flash/tags)
   list `deepseek-v4.1-flash:cloud`. Availability in a model list does not prove
   valid Extract/Progress/Act responses. The seed repair in
   [#39434](https://github.com/jeong-sik/masc/pull/39434) is a separate proposal;
   it uses the existing provider-qualified binding and leaves direct DeepSeek
   bindings separate. Do not infer an API model name from a runtime slug or
   change an operator's live configuration as part of this probe.
2. Establish that the selected primary account can serve requests again,
   using current provider/account evidence or a small isolated readiness
   measurement. A repeated 429 under unchanged prerequisites does not justify
   restarting the full measurement. The fallback replacement does not resolve
   the primary account's rate limit.
3. Record the reviewed source head, exact artifact manifest/checksums and
   isolated slot order. A previously built binary proves its embedded source,
   not a later branch merge. Run both offline controls before provider calls.
4. Once those prerequisites change, run the fixture matrix below and publish
   all nine summaries, per-trial typed outcomes and the process exit status.
   The [#39429 completion contract](https://github.com/jeong-sik/masc/issues/39429)
   requires real-model success evidence; a catalog edit or offline setup pass
   does not complete it.

The original [#38739 review condition](https://github.com/jeong-sik/masc/pull/38739#pullrequestreview-5326481402)
also requires this model evidence. The Keeper's
[post-merge audit](https://github.com/jeong-sik/masc/pull/38739#issuecomment-5851059180)
records that the condition was unmet at merge and that the API does not expose
which admission path allowed it. Its merged state and scripted-browser results
do not supply the missing provider measurement.

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
means setup failed, and stderr names the category; 3 means an exception the
probe does not handle, whose text stays on the private stderr. A partial JSONL
without all nine summaries is incomplete. `--list-setup-reasons` prints every
setup category as one JSON array.

The validator checks the recorded fixture contracts, not arbitrary JSON Schema:

- Extract: string heading and price, exactly `Order form` and `42 USD`.
- Progress: string progress and boolean completed; nonempty progress and true.
- Act: the recorded action object and argument types; click `0-18`, no arguments,
  nonempty description, and `twoStep = false`.
- Every answer must have matching structured JSON and text JSON in the expected
  Stagehand assistant envelope.

Share evidence only after matching embedded source identity, artifact hashes,
both declared target IDs, all nine summary rows and the process exit status.
