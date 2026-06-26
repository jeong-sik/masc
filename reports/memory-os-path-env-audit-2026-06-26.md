# Memory OS / Path / Env Audit - 2026-06-26

Scope:

- MASC source references: `audit/memory-os-path-env-20260626` at `9b79f1a5ce3`.
- Live runtime evidence: dashboard/health process at build commit `6f0097221f6`.
- OAS source references: `ecd509f4b`.
- No local build was run. This is an audit/evidence note; CI remains the build authority.

External references checked on 2026-06-26 Asia/Seoul:

- OCaml 5.4 manual, parallelism: https://ocaml.org/manual/5.4/parallelism.html
- OCaml 5.4 `Lazy` API: https://ocaml.org/manual/5.4/api/Lazy.html
- Eio package docs: https://ocaml.org/p/eio/latest/doc/

## Evidence

Live commands:

- `curl -fsS 'http://127.0.0.1:8935/health?full=1'`
  - Runtime paths: `effective_base_path=/Users/dancer/me`, `effective_masc_root=/Users/dancer/me/.masc`, `resolution_source=explicit_cli`.
  - `keeper_fleet_safety.status=ok`, `running_keeper_fiber_count=6`, `failing_keeper_fiber_count=0`.
- `curl -fsS 'http://127.0.0.1:8935/api/v1/dashboard/keeper-memory-health' | jq '.keepers[] | select(.keeper_id=="sangsu")'`
  - `facts=163`, `events=178`, `events_to_facts_ratio=4.2430085983804995`, `ttl_expired_on_disk=0`, `near_duplicate=0`.
- `jq -s '[.[] | select((.claim // "") | startswith("unstructured_note:"))] | length' /Users/dancer/me/.masc/config/keepers/sangsu.facts.jsonl`
  - `11`
- `jq -s '[.[] | select((.claim // "") | startswith("unstructured_note:")) | select((.valid_until == null) or (.valid_until > now))] | length' /Users/dancer/me/.masc/config/keepers/sangsu.facts.jsonl`
  - `11`
- `rg -c 'librarian_unstructured_fallback' /Users/dancer/me/.masc/config/keepers/sangsu.events.jsonl`
  - `108`

Key source references:

- `lib/keeper/keeper_librarian_runtime.ml`
  - Global librarian provider slot: lines 24-90.
  - Unstructured fallback fact/episode construction: lines 378-450.
  - Parse retry exhaustion preserving fallback: lines 452-510.
  - Best-effort post-turn write path and provider-slot-busy skip: lines 650-743.
- `lib/keeper/keeper_memory_os_types.ml`
  - Ephemeral TTL: lines 152-178.
- `lib/keeper/keeper_memory_os_recall.ml`
  - Recall filters only current facts: lines 237-242.
  - Prompt block reads persisted facts/episodes: lines 270-350.
- `lib/keeper/keeper_run_tools_hooks.ml`
  - Memory OS recall block is appended to keeper prompt context: lines 351-370.
- `lib/server/server_dashboard_http_keeper_api.ml`
  - Dashboard serializes stored fact rows: lines 81-107 and 169-230.
- `dashboard/src/components/memory-inspector.ts`
  - UI labels `active recall candidate`, category, and `untyped`: lines 177-222.
- `lib/server/server_bootstrap_maintenance.ml`
  - Per-keeper maintenance loops catch per-keeper errors: lines 37-96 and 219-299.
- `lib/config/env_config_keeper.ml`
  - Memory OS env/TOML precedence and defaults: lines 1-12 and 205-284.
- `lib/config/env_config_core.ml`
  - `MASC_BASE_PATH` is required by `base_path ()`: lines 375-382.
- `lib/server/server_mcp_transport_http_session.ml`
  - Server default base path delegates to workspace resolver: lines 35-42.
- `lib/workspace/workspace_utils_backend_setup.ml`
  - Explicit `MASC_BASE_PATH` wins; absent value fails loud outside tests: lines 161-203.
- OAS env/debug references:
  - `lib/llm_provider/complete_sync.ml` lines 103-130: `OAS_DEBUG_REQUEST_BODY=full` is disabled, not a live full-body dump.
  - `lib/base/util.ml` lines 100-164, `lib/defaults.ml` lines 15-57, `lib/llm_provider/cli_common_env.ml` lines 11-80, `lib/tool_result_store.ml` lines 25-47: multiple env parsing policies remain.

## Findings

### P1 - Parse-failure fallback is persisted as active recall memory

Confirmed current behavior:

- When the librarian provider returns invalid episode JSON after retries, MASC creates a fact whose claim starts with `unstructured_note: librarian parse fallback (...)`.
- The fallback fact is category `Ephemeral`, has no `claim_kind`, has no `claim_id`, and receives the normal ephemeral TTL.
- The dashboard displays that row as `active recall candidate - temporary - untyped`.
- The row is persisted in the keeper fact/event/episode stores, not in a separate temporary cache.
- The row is eligible for future recall injection while current. It is not used by the same turn that created it because the librarian write happens after the prompt context for that turn has already been built.

This is not silent data loss, and keeping a diagnostic artifact is useful. The problem is that a raw, truncated, invalid provider response is stored in the same semantic fact channel as keeper memory. The live `sangsu` store has 11 current unstructured fallback facts and 108 fallback event markers, so the screenshot is a real current-state symptom.

Production fix direction:

- Keep the diagnostic artifact, but separate it from recallable facts by default.
- Add a typed parse-failure/diagnostic record or claim kind that the dashboard can show and health can count.
- Exclude those diagnostic rows from `Keeper_memory_os_recall.render_context_exn` unless an explicit debugging flag asks for them.
- Preserve metrics/logs and cadence retry behavior so this does not become a silent drop.

Implementation in this branch:

- Added `Keeper_memory_os_types.Diagnostic`.
- Added `Keeper_memory_os_types.fact_prompt_recallable` as the typed recall-eligibility SSOT.
- Marked new librarian parse-failure fallback facts as `claim_kind="diagnostic"`.
- Excluded diagnostic facts and diagnostic-only episodes from prompt recall.
- Kept diagnostics visible in dashboard decoding/rendering via backend-projected `prompt_recallable=false`.
- Did not add a legacy prefix-based migration for already-written untyped fallback rows. Those rows retain their existing TTL behavior; reclassifying them needs a separate, explicit migration decision.

### P1/P2 - Fleet-wide librarian provider slot does not stop all keepers, but can drop extraction work under load

The current code is better than the older "one keeper blocks every other keeper" claim:

- The default global slot is 1.
- A keeper waits only 0.25s for the slot when a clock exists.
- On timeout it records `MemoryLaneProviderSlotBusy` and skips extraction.
- Per-keeper errors are caught and do not cancel the keeper fleet.

So this is not a confirmed P0 fleet-stop bug. The remaining risk is fairness/data loss: under provider pressure, some keepers can repeatedly miss post-turn extraction rather than enqueueing a bounded retry. That can amplify the fallback/no-memory behavior shown in the dashboard.

Production fix direction:

- Replace "try for 0.25s then skip" with a bounded fair queue or per-keeper lane scheduler.
- Surface dropped/deferred extraction counts in health, grouped by keeper.
- Keep the failure local to the keeper/lane; do not make one provider failure stop the whole fleet.

### P2 - Memory OS read paths still use blocking stdlib filesystem calls inside Eio runtime paths

`keeper_memory_os_io` uses `Sys.readdir`, `Sys.file_exists`, `open_in_bin`, `in_channel_length`, and `really_input_string` in fact/episode read paths. The files are bounded, and this is not an immediate P0, but recall is on the keeper prompt-building path and dashboard reads are operator-facing runtime paths.

Production fix direction:

- Keep pure parsers as they are.
- Move filesystem access to Eio-native path APIs or an explicit systhread boundary for potentially blocking directory/file reads.
- Preserve current atomic write semantics through `Fs_compat.save_file_atomic`.

### P2 - OAS env parsing policy is duplicated and inconsistent

No hardcoded `/Users/dancer/me` path was found in the scanned OAS production source. The current risk is policy drift:

- `Util.int_env_or` silently falls back on invalid input.
- `Defaults.int_env_or` logs invalid input.
- `Cli_common_env.int` logs invalid input and has its own non-negative policy.
- `Tool_result_store.int_of_env` accepts any parsed integer and otherwise silently returns `None`.

This is not a P0, but it is exactly the kind of env-surface drift that makes production behavior hard to reason about.

Production fix direction:

- Consolidate env parsing through one OAS helper with explicit invalid-value policy.
- Make every env-backed setting declare bounds and whether invalid input fails open, fails closed, or logs-and-defaults.
- Add focused tests for representative invalid/negative/empty values.

## Corrected Non-Findings

### No confirmed production hardcoded `/Users/dancer/me` base path in scanned MASC/OAS code

The live MASC process is running with an explicit base path, and source resolution requires `MASC_BASE_PATH` or a server resolver path. The broad `/Users/dancer/me` hits in MASC are mainly tests/fixtures or documentation. I did not find a current production `let default_base = "/Users/dancer/me"` pattern in the scanned runtime paths.

### Expired Memory OS facts are not recall-injected on current code

The older "GC default off means expired facts accumulate indefinitely into recall" framing is stale:

- write/cap paths drop expired rows,
- recall filters `fact_is_current`,
- `sangsu` currently reports `ttl_expired_on_disk=0`.

GC is still default-off for quiet-store disk cleanup, but that is not the same as expired rows being active recall facts.

### OAS full request-body dump is not current behavior

The old `OAS_DEBUG_REQUEST_BODY=full` risk has been removed in current OAS. The code now warns that full dumps are disabled and suggests summary/scrubbed logging instead.

## P0 Judgment

I do not have a confirmed current P0 from this pass.

The strongest issue is P1: unparseable librarian output was preserved as prompt-recallable memory. It becomes P0 only if a plausible path shows those raw diagnostic rows can inject harmful operational instructions into a keeper prompt and drive action without validation. This branch fixes the new-write channel boundary before adding prompt constraints or heuristics.
