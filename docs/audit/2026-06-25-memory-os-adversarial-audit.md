# Memory OS Adversarial Audit

Date: 2026-06-25 17:41 KST

Scope: code review branch rebased onto `origin/main` at `6072c5b874`,
dedicated worktree `codex/memory-os-audit-20260625`, and live runtime rooted at
`<base-path>/.masc` with runtime commit `469a29a919`.

## Verdict

Memory OS is not just decorative state. It has an active write path, read path,
retention path, shared-store projection, dashboard health surface, and outcome
ledger hooks. It should improve memory in real runs when the extracted facts are
valid because recall injects bounded, typed facts and recent episodes back into
keeper prompts.

The hard production caveat is quality control. The deterministic file layer is
mostly bounded and conservative, but the LLM ingestion layer still accepts
prose-wrapped JSON through substring recovery and stores parse failures as
ephemeral `unstructured_note` facts. Live data already shows that debt: 54
`unstructured_note:` facts, 181 typed expired facts on disk according to the
dashboard health endpoint, and legacy/schema-drift rows including
`category="external_state"` and `schema_version="rfc0231-v2"`.

This audit fixed two concrete code defects and one CI-radius defect:

1. `keeper_memory_os_reconcile_gh.ml` no longer has an `assert false` path for
   `Task` external references. Unsupported refs now return `Unverifiable`.
2. `keeper_memory_os_io.ml` no longer misclassifies arbitrary body
   `Failure` exceptions inside `with_facts_lock` as lock-acquisition timeouts.
   A regression test pins that behavior.
3. `.github/workflows/ci.yml` no longer points the focused operator-control
   gate at a non-existent aggregate executable, and the SSE e2e gate now sets
   `MASC_E2E_TESTS=true` so its existing Dune stanza is enabled.

## Evidence

[근거] Live runtime root:
`curl -fsS 'http://127.0.0.1:8935/health?full=1'`, checked
2026-06-25 17:31 KST, confidence High. Result: `effective_base_path` was
the configured `<base-path>`, `effective_masc_root` was `<base-path>/.masc`,
runtime commit was `469a29a919`, status was `ok`.

[근거] Live Memory OS sizes:
`du -sh <base-path>/.masc/config/keepers <base-path>/.masc/keepers <base-path>/.masc/recall_injections <base-path>/.masc/logs`,
checked 2026-06-25 17:31 KST, confidence High. Result:
`config/keepers=14M`, legacy `keepers=1.8G`, `recall_injections=47M`,
`logs=232M`.

[근거] Live Memory OS row counts:
`wc -l <base-path>/.masc/config/keepers/*.facts.jsonl`,
`wc -l <base-path>/.masc/config/keepers/*.events.jsonl`, and
`find .../episodes -name '*.json' | wc -l`, checked 2026-06-25 17:31 KST,
confidence High. Result: 2603 facts, 2207 events, 2207 episode files. Per-keeper
stores were under the 384-row/file cap.

[근거] Typed health surface:
`curl -fsS 'http://127.0.0.1:8935/api/v1/dashboard/keeper-memory-health'`,
checked 2026-06-25 17:31 KST, confidence High. Result: 2601 non-shared facts,
`facts_bytes=902597`, `events_bytes=3989307`, `ttl_expired_on_disk=181`,
`near_duplicate=0`.

[근거] Current OCaml 5.4 guidance:
[OCaml 5.4 manual, Parallel programming](https://ocaml.org/manual/5.4/parallelism.html),
checked 2026-06-25 17:41 KST, confidence High. The manual says immutable values
can be shared freely, mutable refs/arrays/fields need synchronization to avoid
data races, and data-race-free programs get sequentially consistent semantics.

[근거] Current Eio guidance:
[Eio 1.3 docs](https://ocaml.org/p/eio/latest/doc/eio/Eio/index.html), checked
2026-06-25 17:41 KST, confidence High. Eio is effect-based parallel IO for
OCaml with fibers, domains, switches, cancellation, mutexes, semaphores, pools,
and executor pools.

[근거] CI failure triage before the CI-radius patch:
`gh run view 28159412988 --repo jeong-sik/masc --job 83395999819 --log-failed`,
checked 2026-06-25 18:59 KST, confidence High. Result: the focused operator
control step called a non-existent `test_operator_control.exe`; SSE reconnect
and contract harness failures remained CI-owned readiness blockers.

[근거] Current memory-agent references:
[LangGraph memory docs](https://docs.langchain.com/oss/python/concepts/memory),
[Letta stateful agents docs](https://docs.letta.com/guides/core-concepts/stateful-agents),
[Mem0 docs](https://docs.mem0.ai/introduction),
[Zep docs](https://help.getzep.com/overview),
[MemGPT paper](https://arxiv.org/abs/2310.08560),
[Generative Agents paper](https://arxiv.org/abs/2304.03442), and
[Reflexion paper](https://arxiv.org/abs/2303.11366), checked
2026-06-25 17:41 KST, confidence High for source identity and Medium for
cross-system comparison because the products evolve.

## Execution Flow

1. Prompt-time recall reads current memory before a keeper turn. The entrypoint
   is `Keeper_memory_os_recall.render_if_enabled`, default-on through
   `MASC_KEEPER_MEMORY_OS_RECALL`.
2. Recall locks the private keeper facts file and `_shared.facts.jsonl` in
   deterministic path order, scans the whole bounded private store, ranks by
   structural recency/truth anchors, appends a small shared slice, and renders up
   to 8 facts plus 2 episodes.
3. The model runs with this advisory block plus other keeper context.
4. Post-turn memory work is detached onto the per-keeper memory lane in
   `Keeper_agent_run_post_turn_memory`.
5. `Keeper_librarian_runtime` gates extraction by env, cadence, bounded pending
   lane, and a global provider slot. Defaults are conservative: librarian
   enabled, cadence 3 turns, max messages 24, timeout 600s, global slot 1.
6. `Keeper_librarian` parses the model output into an episode plus claims.
   Claims are converted once into typed categories, claim kinds, external refs,
   and TTLs before hitting the JSONL store.
7. `Keeper_memory_os_io.merge_and_cap_facts` upserts by `claim_identity`, drops
   expired rows on the hot write path, and caps facts to 384. Events and episode
   files are also capped to 384.
8. Cross-keeper consolidation periodically reconstructs `_shared.facts.jsonl`
   from corroborated promotable facts. It does not mutate keeper-private stores.
9. Optional maintenance paths do deletion/cleanup: `MASC_KEEPER_MEMORY_OS_GC`
   hard-expires and dedups private stores, `MASC_KEEPER_MEMORY_OS_RECONCILE`
   verifies GitHub-backed volatile claims, and per-keeper LLM consolidation can
   merge/drop rows. GC/reconcile/consolidation are default-off except the shared
   consolidator.
10. Dashboard health and recall-injection ledgers expose size, TTL, and
   injection/outcome evidence.

## Code Progression Order

Read in this order when debugging or extending Memory OS:

1. `lib/keeper/keeper_memory_os_types.mli` and `.ml`: schema, taxonomy,
   `claim_identity`, `external_ref_of_claim`, TTL derivation, JSON codecs.
2. `lib/keeper/keeper_memory_os_policy.ml`: retention and re-observation rules.
3. `lib/keeper/keeper_memory_os_io.ml`: file paths, JSONL reads/writes, locks,
   caps, atomic rewrites.
4. `lib/keeper/keeper_memory_os_recall.ml`: prompt injection, ranking,
   shared-store merge, recall ledger.
5. `lib/keeper/keeper_librarian.ml`: LLM output parser and claim extraction.
6. `lib/keeper/keeper_librarian_runtime.ml`: cadence, provider-slot, and
   bounded-lane runtime behavior.
7. `lib/keeper/keeper_agent_run_post_turn_memory.ml`: post-turn orchestration.
8. `lib/keeper/keeper_memory_os_gc.ml`: deterministic deletion path.
9. `lib/keeper/keeper_memory_os_reconcile*.ml`: external-state verification.
10. `lib/keeper/keeper_memory_os_consolidator*.ml` and
    `keeper_memory_os_consolidation*.ml`: shared tier and optional per-keeper
    LLM consolidation.
11. `lib/server/server_bootstrap_maintenance.ml`: production scheduling and env
    gates.
12. `test/test_keeper_memory_os.ml`: executable contract.

## Ten Real-World Examples

1. User preference: "Keep final answers short." Category `preference`, durable,
   recalled as a private fact.
2. Active PR state: "PR #22231 is open." External ref `Pr`, finite TTL, eligible
   for GitHub reconciliation. If closed/merged later, reconcile demotes or
   refreshes it rather than treating it as timeless truth.
3. Task-board state: "No unclaimed tasks exist." This should be volatile. If it
   enters as durable prose, it can mislead future turns. Current safeguards rely
   on claim kind/category and external-ref extraction, so producer quality
   matters.
4. Repeated tool lesson: "Use `rg` before slower grep." Category `lesson` or
   `validated_approach`, promotable when corroborated across keepers.
5. Sandbox blocker: "Network fetch failed because approval is needed." Category
   `blocker` or `constraint`, useful within a local horizon but dangerous if
   kept after env changes.
6. Proven fix pattern: "Reconcile verifier must classify off-lock and commit
   under CAS." Category `validated_approach`, durable and shareable after
   corroboration.
7. Ephemeral checkpoint: "Status dashboard was refreshed at 17:00." Category
   `ephemeral`, should expire and be dropped by write-time cap or GC.
8. Self observation: "Keeper is idle/stuck." Claim kind `self_observation`,
   gets a one-hour horizon and is not promoted to `_shared`.
9. Cross-keeper invariant: "Do not mutate `<workspace-root>` root checkout for
   feature work." Category `constraint`; if multiple keepers learn it, shared
   tier can surface it to others.
10. Malformed librarian output: prose around a JSON object can currently be
    recovered or converted into `unstructured_note`. This preserves signal, but
    also creates noisy debt; live data already contains 54 such facts.

## Hardcoding, Env, And SSOT

No hardcoded local absolute workspace path was found in the Memory OS
implementation code. This statement is scoped to implementation files, while the
audit evidence above uses `<base-path>` placeholders for live-machine paths.
Path ownership goes through `Config_dir_resolver`, `Env_config_core`, and the
active runtime root. This respects the MASC local-persistence boundary: MASC owns
file-backed keeper memory under `.masc`; OAS/model-provider code is not the
owner.

The env surface is broad but named and centralized enough to audit:

- `MASC_KEEPER_MEMORY_OS_RECALL`: default true.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN`: default true.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS`: default 3.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES`: default 24.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC`: default 600.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID`: optional runtime override.
- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT`: default 1.
- `MASC_KEEPER_MEMORY_OS_GC`: default false.
- `MASC_KEEPER_MEMORY_OS_RECONCILE`: default false.
- `MASC_KEEPER_MEMORY_OS_RECONCILE_APPLY`: default false.
- `MASC_KEEPER_MEMORY_OS_CONSOLIDATION`: default false.
- `MASC_KEEPER_MEMORY_OS_CONSOLIDATION_RUNTIME_ID`: optional runtime override.

The fixed-size constants are hardcoded operational policy, not hidden path
state: recall 8 facts and 2 episodes, shared facts 4, episode tail scan 32,
store caps 384. They are acceptable as code-owned safety defaults for this
hardening PR, but should become explicit product policy if operators need to
tune them without a code review. SSOT cleanup is tracked as
[#22294](https://github.com/jeong-sik/masc/issues/22294).

## Heuristics And String Matching

Good boundary string parsing:

- `category_of_string` parses LLM text once into a closed category variant.
- `external_ref_of_claim` recognizes limited PR/issue/task patterns and then
  stores typed refs.

Risky heuristic parsing:

- `Keeper_librarian.json_of_output` tries raw JSON, string-wrapped JSON,
  fenced JSON, then the first `{...}` substring.
- `Keeper_memory_os_consolidation.json_of_output` uses the same substring
  recovery style for optional per-keeper consolidation.
- Unknown categories are stored as `Unknown s`; they are conservative for
  promotion, but live `external_state` category rows show producer/schema drift.

This is the main "weird heuristic" finding. The deterministic layer is stricter
than the LLM parser. If the standard is "no heuristic," the parser needs a
structured-output contract or a reject-and-record path, not substring recovery.

## Failure Modes

Fixed:

- `keeper_memory_os_reconcile_gh.ml` used `assert false` for `Task` refs inside
  GraphQL query construction. The current patch returns `Unverifiable`.
- `keeper_memory_os_io.ml` caught broad `Failure` and labeled it a lock timeout.
  The current patch catches only `File_lock_eio.Flock_timeout`.
- `.github/workflows/ci.yml` drifted from current Dune targets:
  `test_operator_control.exe` no longer exists, and `test_sse_storm_e2e` is
  disabled unless `MASC_E2E_TESTS=true`. The current patch points CI at the
  existing focused operator-control aliases and enables the SSE stanza.

Residual:

- Recall catches non-cancel exceptions, logs a warning, and returns an empty
  block. That is safe for turn progress, but the model does not see that recall
  failed. Tracked as [#22293](https://github.com/jeong-sik/masc/issues/22293).
- Librarian runtime is best-effort. Provider saturation, cadence, parse failure,
  or lane saturation can skip extraction. It logs metrics, but skipped turns are
  not equivalent to guaranteed memory preservation.
- Strict destructive readers preserve corrupt stores, but normal recall readers
  are lenient and can ignore malformed rows.
- File IO is mostly blocking stdlib IO inside Eio fibers. Current stores are
  small and capped, but large legacy dirs or future cap increases would increase
  scheduler risk.

## Grows Or Deletes

It does both, but deletion is not always active.

Growth controls active by default:

- Facts are capped to 384 per keeper.
- Events and episode files are capped to 384.
- Expired facts are dropped during merge/cap writes.
- `_shared` is reconstructed by the shared consolidator.

Deletion controls default-off:

- `MASC_KEEPER_MEMORY_OS_GC=false` means dormant keepers can retain expired rows.
- `MASC_KEEPER_MEMORY_OS_RECONCILE=false` and `..._APPLY=false` mean volatile
  external-state truth can age out by TTL/cap but is not proactively grounded.
- Per-keeper LLM consolidation is default-off.

Live result: the bounded Memory OS store is healthy in size, but expired rows are
real. The live dashboard reports 181 expired facts on disk, concentrated mostly
in `mad-improver`.

## Live Trash Data

Memory OS current store:

- `config/keepers`: 14M.
- 2603 facts, 2207 events, 2207 episode files.
- Largest per-keeper fact count observed: 348, under the 384 cap.
- No `.atomic_*.tmp` files were found under `config/keepers` at depth 3.

Adjacent `.masc` trash outside current Memory OS:

- Legacy `<base-path>/.masc/keepers`: 1.8G.
- `<base-path>/.masc/logs`: 232M.
- `<base-path>/.masc/recall_injections`: 47M.
- A targeted scan saw an atomic temp file under legacy `.masc/keepers` and a
  stray `PYEOF` path. Those are cleanup/backlog issues, not current Memory OS
  fact-store growth.

Remediation should be dry-run first. Do not delete legacy keeper data or logs
without an ownership decision.

## OCaml/Eio Review

The core immutable record-heavy design aligns with OCaml 5.4 guidance:
facts/events/episodes are immutable values; shared mutable state is mostly
limited to locks, test overrides, cadence tables, and provider slots.

The remaining concurrency concerns are:

- `keepers_dir_override` and runtime cadence tables are mutable globals. They
  are guarded or test-scoped, but they are still global state.
- `Stdlib.Mutex` around cadence/global tables is acceptable because the critical
  sections are tiny and do not perform Eio-yielding IO.
- Normal file reads/writes use blocking stdlib IO. Eio gives fibers, switches,
  cancellation, and executor/domain tools; long blocking IO should not grow
  inside a cooperative domain. Current caps mitigate this.

## Comparison To Other Memory Systems

- Generative Agents uses natural-language observations, reflection, and dynamic
  retrieval to plan behavior. MASC has observations/episodes and recall, but
  reflection is weaker unless optional consolidation is enabled and evaluated.
- Reflexion stores verbal feedback in episodic memory to improve later trials.
  MASC `lesson` and `validated_approach` facts are similar, but MASC still needs
  stronger outcome-linked evaluation before claiming causal improvement.
- MemGPT/Letta emphasize stateful agents and context/memory management across
  context eviction. MASC is more local-file and ops-oriented; it is less of a
  generic virtual context manager.
- LangGraph distinguishes short-term thread memory and long-term namespaced
  stores. MASC matches this shape with per-keeper stores plus `_shared`, but it
  does not provide a general semantic-search store in this path.
- Mem0 and Zep sell managed production memory layers. MASC has better local
  traceability and deterministic retention, but weaker semantic extraction,
  graph retrieval, and managed cleanup.

## Does It Really Improve Memory?

Qualified yes.

It improves memory when:

- extracted claims are true and well-categorized,
- recall is enabled and not failing,
- facts survive ranking/cap,
- stale facts get TTL, reconciliation, or GC,
- the keeper actually uses the recalled block.

It does not yet prove end-to-end memory quality on its own. The recall-injection
ledger and dashboard health are the right direction, but the system still needs
evaluation that joins "fact was injected" to "future turn behaved better" and
separates extraction quality from retrieval quality.

## Residual Issue Records

Issue: permissive LLM JSON recovery stores noisy memory.
Symptom: 54 live `unstructured_note:` facts and parser fallback from first
`{...}` substring.
Repro: inspect `Keeper_librarian.json_of_output` and live facts category/counts.
Likely cause: resilience was favored over strict structured output.
Tried: documented and isolated; not fixed in this patch because it changes
ingestion policy.

Issue: expired rows remain on disk when GC is disabled.
Symptom: dashboard reports `ttl_expired_on_disk=181`.
Repro: dashboard health endpoint above.
Likely cause: GC default-off and expired rows for dormant keepers are only
removed on future writes/caps or explicit GC.
Tried: verified store caps and existing GC path; did not enable GC by default.

Issue: recall failure is not visible to the model.
Symptom: `render_context` logs and returns `""` on non-cancel exceptions.
Repro: inspect `Keeper_memory_os_recall.render_context`.
Likely cause: turn-progress safety.
Tried: documented as residual; not fixed because changing prompt error surface
requires product decision.

Issue: legacy `.masc/keepers` and logs dominate disk usage.
Symptom: live legacy `.masc/keepers=1.8G`, logs=232M, current
`config/keepers=14M`.
Repro: `du -sh` command above.
Likely cause: historical keeper/runtime data outside current Memory OS caps.
Tried: no deletion; requires dry-run cleanup tool and ownership review.

## PR Radius

Recent merged Memory OS-related commits:

- `4e412212a2` / #22231: per-keeper Memory OS consolidation and Hebbian view.
- `094fee3cb5` / #22213: dashboard real-data Memory OS panel.
- `74e846429e` / #22150: self-observation claim kind and finite horizon.
- `6a96a5ef38` / #21899: bounded episode log.
- `d1904ba0d2` / #21895: cap honors `valid_until`.
- `5d8c789573` / #21865: producer `claim_id` idempotency and volatile anchor
  inheritance.

Live open PR list checked 2026-06-25 17:41 KST. No open PR title/head branch was
Memory OS-specific before this audit branch.

## Validation

Local:

- `ocamlformat --check lib/keeper/keeper_memory_os_reconcile_gh.ml lib/keeper/keeper_memory_os_io.ml test/test_keeper_memory_os.ml`
  passed.
- `rg -n "assert false|failwith|Failure msg -> on_timeout" lib/keeper/keeper_memory_os_reconcile_gh.ml lib/keeper/keeper_memory_os_io.ml`
  returned no matches.

Not run locally by design:

- Dune build/test. This audit branch leaves OCaml build validation to GitHub CI,
  matching the requested build boundary.
