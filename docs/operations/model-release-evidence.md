# Model release evidence and refresh

`Model_release_evidence` separates an official model release date from the time
MASC discovers that model on a particular account. Release recency is a display
recommendation, never admission, entitlement, tool support or context capacity.
Lookup requires an exact publisher and complete model ID. A configured custom
route must not inherit another publisher's evidence from its model-name prefix.

The recency interval is inclusive: from three calendar months before the
observation date through that date. Month-end subtraction clamps to the last
valid day of the target month. Unknown and future dates remain separate states.
General availability, limited rollout and preview are also distinct.

## Seed evidence checked on 2026-09-10

- Claude Sonnet 5: 2026-06-30, [official announcement](https://www.anthropic.com/news/claude-sonnet-5), which names `claude-sonnet-5` and availability that day.
- Claude Opus 5: 2026-07-24, [official announcement](https://www.anthropic.com/news/claude-opus-5).
- GPT-5.6 Sol, Terra and Luna: general availability 2026-07-09, [official launch](https://openai.com/index/gpt-5-6/). This is distinct from the earlier limited preview.
- GPT-6 Astra: initial limited rollout 2026-09-03, [official release notes](https://openai.com/products/release-notes/). A release does not establish access for the current account.
- GLM-5.3: unknown in this seed. The official blog could not be read reliably during this check; third-party dates are not substituted for primary evidence.

Other identities without reviewed evidence return `unknown`, including aliases,
custom routed copies and unlisted local models. The JSON is embedded with the
existing config embedding mechanism; capability/pricing rows remain owned by
AGENT_CORE's separate `models.toml`.

## First refresh stage

`model-release-evidence.yml` runs daily and on dispatch. It validates the data,
fetches the referenced public sources without credentials or redirects, and
publishes an artifact with observed timestamps, source body hashes and failures.
A changed page does not silently change the reviewed release date or its
`checked_on` date. The original catalog is never rewritten by this job.

For explicit local account discovery, the same script accepts
`--discovery-request FILE` with this ABI:

```json
{"schema":"masc.model_discovery_request.v1","connections":[{
  "id":"my-local-server","publisher":"my-local-publisher",
  "choice":"openai_compatible","endpoint":"http://127.0.0.1:8000/v1",
  "api_key_env":"","command":""
}]}
```

Supported choices reuse `install-runtime-setup.py:discover_models`: Codex,
Ollama, llama.cpp, vLLM and OpenAI-compatible HTTP. This enumerates metadata;
it sends no model turn. HTTP authorization, when supplied, uses the existing
helper's environment-name boundary. Neither credential values nor endpoint or
credential paths are copied into the report. The report selects only model IDs
and separately joins reviewed release evidence. Provider `created`, model-list
insertion times and arbitrary `release_date` response fields are never admitted
as release evidence. Unsupported and empty/unavailable discovery remain explicit.
Account model names can themselves be private; do not publish local reports.

This first stage provides typed evidence and daily observation, not an automatic
new-model release curator or an account-wide background scheduler. Native inventory and the model picker consume this exact-identity evidence: existing
connections stay first, followed by general releases inside the three-calendar-month
window. Limited releases and previews are labeled separately; unknown dates do not
hide models. Context windows and account verification remain separate checks.
Reviewed metadata update PRs and an installed-client refresh cache remain subsequent stages. Bedrock, GCP and Vertex account discovery are excluded.
