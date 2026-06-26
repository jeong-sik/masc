# Memory OS Production Audit

Date: 2026-06-26 15:19 KST

Scope:
- repo: `jeong-sik/masc`
- audit worktree: `.worktrees/memory-os-audit-20260626`
- audited source head: `2b30bbc55691a9a9e82b317d47765fd84884093f`
- live runtime head from `/health?full=1`: `e882945c06d`
- live base path: `/Users/dancer/me`
- live MASC root: `/Users/dancer/me/.masc`

This is an adversarial production-readiness audit of the Memory OS path: structure,
logical flow, code progression order, operational data quality, deletion/forgetting,
path/env/SSOT risks, and comparison against current OCaml 5.4/Eio practice and
memory-agent research/tools.

## Verdict

Memory OS is real, not decorative. It has an active prompt-time recall path,
post-turn write path, typed fact schema, per-keeper private store, shared store,
bounded caps, recall injection ledger, dashboard health surface, and maintenance
fibers. It should improve keeper memory when the librarian extracts useful claims,
because bounded facts and recent episodes are injected back into future keeper
prompts.

It is not yet production-complete under the requested "no hardcoding, no
heuristics, no silent failure, no string-match workaround" bar. The deterministic
storage layer is mostly strong; the weak surface is still the LLM ingestion and
cleanup loop:

1. Current `main` still treats parse-exhaustion fallback episodes as successful
   writes for librarian cadence. PR #22365 has the right source fix, but it is
   still open, draft, and CI-red.
2. `Keeper_librarian.json_of_output` and LLM consolidation still use markdown /
   first-`{...}` substring recovery. That is a heuristic parser in the hottest
   quality boundary.
3. GC and per-keeper consolidation are default-off. The write path drops expired
   rows during caps, but live data still has 16 expired facts on disk.
4. The current config-backed keeper store is small and bounded, but adjacent
   legacy `.masc/keepers` is 1.8G and contains garbage residue. The current Memory
   OS code does not own or clean that legacy tree.
5. The recall-injection ledger is useful for outcome evaluation, but it is already
   54M and has no visible retention policy in the audited path.

Review-response state:
- #22328 is merged and fixed the prior silent recall-unavailable hole.
- #22337 is merged and fixed MASC-authored unstructured fallback `claim_id`
  semantics.
- #22365 is the right fix for the fallback-cadence leak, but it is not landed and
  Build/Test is red.
- #22352 remains a separate linked-risk PR; do not merge it as-is because optional
  no-clock bridges can remove timeout enforcement from live Eio callers.

## Evidence

[근거] Source head: `git rev-parse HEAD`, checked 2026-06-26 15:19 KST,
confidence High. Result: `2b30bbc55691a9a9e82b317d47765fd84884093f`.

[근거] Live runtime truth:
`curl -fsS 'http://127.0.0.1:8935/health?full=1'`, checked 2026-06-26 15:19
KST, confidence High. Result: status `ok`, version `0.19.48`, runtime commit
`e882945c06d`, `effective_base_path=/Users/dancer/me`,
`effective_masc_root=/Users/dancer/me/.masc`, `roots_diverge=true`,
`resolution_source=explicit_env`, config keepers path
`/Users/dancer/me/.masc/config/keepers`, retained logs 50000, recent errors 0.

[근거] Live Memory OS dashboard:
`curl -fsS 'http://127.0.0.1:8935/api/v1/dashboard/keeper-memory-health'`,
checked 2026-06-26 15:19 KST, confidence High. Result: 2568 facts, 3997507
event bytes, 16 TTL-expired facts on disk, 0 near-duplicates, 6 cadence counter
entries.

[근거] Live disk size:
`du -sh /Users/dancer/me/.masc/config/keepers /Users/dancer/me/.masc/keepers /Users/dancer/me/.masc/recall_injections /Users/dancer/me/.masc/logs`,
checked 2026-06-26 15:19 KST, confidence High. Result: `config/keepers` 15M,
legacy `keepers` 1.8G, `recall_injections` 54M, logs 224M.

[근거] Live row scan:
`wc -l /Users/dancer/me/.masc/config/keepers/*.facts.jsonl` and
`*.events.jsonl`, checked 2026-06-26 15:19 KST, confidence High. Result: 2570
fact rows including `_shared`, 2272 event rows.

[근거] Live category/schema scan:
`jq -r '.category'` and `jq -r '.schema_version'` over live fact files, checked
2026-06-26 15:19 KST, confidence High. Result: top categories are `fact` 877,
`constraint` 450, `validated_approach` 327, `lesson` 275; schema versions are
`rfc0259-v1` 1790 and `rfc0231-v2` 780. There are 18 `external_state` category
rows, which is producer/schema drift relative to the current closed category set.

[근거] Live garbage residue scan:
`find /Users/dancer/me/.masc/config/keepers -maxdepth 4 \( -name '.atomic_*.tmp' -o -name 'PYEOF' \) -print`
and the same narrow scan under `/Users/dancer/me/.masc/keepers`, checked
2026-06-26 15:19 KST, confidence High. Result: current config keepers tree has
no matches; legacy tree has `/Users/dancer/me/.masc/keepers/imseonghan/.atomic_80095f.tmp`
and `/Users/dancer/me/.masc/keepers/PYEOF`.

[근거] OCaml 5.4 concurrency baseline:
[OCaml 5.4 manual, Parallel programming](https://ocaml.org/manual/5.4/parallelism.html),
checked 2026-06-26 KST, confidence High. Used for the immutability/data-race
baseline: shared mutable state needs synchronization; immutable values are the
safe default.

[근거] Eio baseline:
[Eio package docs](https://ocaml.org/p/eio/latest/doc/eio/Eio/index.html),
checked 2026-06-26 KST, confidence High. Used for the structured concurrency,
switch/cancellation, mutex/semaphore, and fiber-friendly blocking baseline.

[근거] Typed error handling baseline:
[Real World OCaml, Error Handling](https://dev.realworldocaml.org/error-handling.html),
checked 2026-06-26 KST, confidence Medium. Used as a Jane Street ecosystem
reference for typed `Result`/`Or_error` style instead of string-only failure
contracts.

[근거] Memory-agent references checked 2026-06-26 KST, confidence Medium for
product comparison because these projects evolve quickly:
[MemGPT](https://arxiv.org/abs/2310.08560),
[Generative Agents](https://arxiv.org/abs/2304.03442),
[Reflexion](https://arxiv.org/abs/2303.11366),
[LangGraph memory docs](https://docs.langchain.com/oss/python/concepts/memory),
[Letta stateful agents docs](https://docs.letta.com/guides/core-concepts/stateful-agents),
[Mem0 docs](https://docs.mem0.ai/introduction), and
[Zep docs](https://help.getzep.com/overview).

## Structure And Logical Flow

1. Prompt-time recall runs before the keeper turn. Entry point:
   `Keeper_memory_os_recall.render_if_enabled` in
   `lib/keeper/keeper_memory_os_recall.ml:376`.
2. Recall locks the keeper-private fact store and `_shared` in deterministic path
   order, reads the whole bounded private store, filters expired rows, ranks by
   `reference_time`, dedups by `claim_identity`, and renders at most 8 private
   facts, 4 shared facts, and 2 episodes.
3. The rendered recall block is appended to the keeper prompt. If rendering fails,
   current code returns an explicit unavailable block and records
   `MemoryOsRecallUnavailable`; this is the #22328 fix.
4. The keeper produces its turn response.
5. `Keeper_agent_run_post_turn_memory.run` snapshots tool emissions before
   detaching memory work, then submits deterministic memory write, librarian
   extraction, draft-skill projection, and legacy memory-bank compaction to the
   per-keeper memory lane (`lib/keeper/keeper_agent_run_post_turn_memory.ml:24`,
   `:37`, `:93`, `:207`).
6. `Keeper_memory_lane` serializes memory work per keeper with an `Eio.Mutex`,
   bounds pending memory jobs, and drops excess instead of building an unbounded
   queue (`lib/keeper/keeper_memory_lane.ml:3`, `:24`, `:104`).
7. `Keeper_librarian_runtime` checks enablement, cadence, runtime, provider
   support, optional global provider slot, timeout, and then calls the provider in
   JSON mode (`lib/keeper/keeper_librarian_runtime.ml:92`, `:120`, `:243`,
   `:350`, `:582`).
8. `Keeper_librarian` parses the provider output into an episode. Claims are
   converted once into typed category/claim-kind fields and written with TTLs
   (`lib/keeper/keeper_librarian.ml:122`, `:202`).
9. `Keeper_memory_os_io.merge_and_cap_facts` upserts by `claim_identity`, drops
   expired rows, ranks only when over the cap, and atomically rewrites the fact
   file (`lib/keeper/keeper_memory_os_io.ml:620`).
10. Episode events and episode files are appended and capped. Facts/events/episode
    file caps use a 256 low-water / 384 high-water hysteresis band
    (`lib/keeper/keeper_memory_os_io.ml:483`, `:501`, `:705`, `:728`).
11. Shared consolidation runs every 300s and rebuilds `_shared.facts.jsonl` from
    promotable corroborated facts, without mutating keeper-private stores
    (`lib/server/server_bootstrap_maintenance.ml:175`).
12. Optional GC and per-keeper LLM consolidation run only if env gates are enabled
    (`lib/server/server_bootstrap_maintenance.ml:219`, `:269`).

## Code Progression Order

Read and modify Memory OS in this order:

1. `lib/keeper/keeper_memory_os_types.ml`: schema version, category taxonomy,
   claim kind, TTLs, `claim_identity`, JSON codec.
2. `lib/keeper/keeper_memory_os_policy.ml`: re-observation and retention rank.
3. `lib/keeper/keeper_memory_os_io.ml`: path resolution, locks, atomic writes,
   JSONL reads, merge/upsert, caps.
4. `lib/keeper/keeper_memory_os_recall.ml`: prompt injection, failure visibility,
   shared/private merge, recall ledger.
5. `lib/keeper/keeper_librarian.ml`: prompt input scrub, JSON parser, claim
   extraction.
6. `lib/keeper/keeper_librarian_runtime.ml`: cadence, provider/runtime selection,
   timeout, fallback behavior.
7. `lib/keeper/keeper_agent_run_post_turn_memory.ml`: turn-end orchestration.
8. `lib/keeper/keeper_memory_lane.ml`: per-keeper serialized lane.
9. `lib/keeper/keeper_memory_os_gc.ml`: deterministic TTL/dedup cleanup.
10. `lib/keeper/keeper_memory_os_consolidator*.ml`: shared store promotion.
11. `lib/keeper/keeper_memory_os_consolidation*.ml`: optional LLM-based
    per-keeper consolidation.
12. `lib/server/server_bootstrap_maintenance.ml`: production maintenance cadence
    and env gates.
13. `lib/config/env_config_keeper.ml`: all Memory OS env knobs.
14. `test/test_keeper_memory_os*.ml` and `test/test_keeper_librarian*.ml`:
    executable contracts.

## Ten Real-World Examples

1. User preference:
   "Final answers should be concise." This becomes `preference`, is recalled in
   the keeper-private slice, and should not need a live external verifier.
2. Workspace invariant:
   "Do not start feature work in `~/me`; use repo-local `.worktrees`." This is a
   `constraint` and can be promoted if corroborated across keepers.
3. Proven workflow:
   "Use `gh pr checks --json` instead of assuming `conclusion` exists." This is a
   `validated_approach`; it improves future PR triage.
4. Failure lesson:
   "Do not classify current PR state from prose mentioning `PR #123`." This is a
   `lesson`; current code correctly avoids external-ref inference from claim text.
5. Active external state:
   "PR #22365 is open and CI-red." This should be `external_state` only if the
   producer supplies an explicit current-state tag and future recall marks it stale
   enough to re-verify. Otherwise it can mislead future turns.
6. Self observation:
   "Keeper is looping on the same task without progress." With `claim_kind =
   self_observation`, it gets a one-hour TTL and is not promoted to `_shared`.
7. Ephemeral checkpoint:
   "Continuation checkpoint saved." It should be `ephemeral`, expire in one day,
   and disappear through cap/GC. Live data still has expired examples on disk.
8. Tool blocker:
   "Network access failed because approval is needed." Useful in the current turn,
   dangerous as durable truth; category/claim kind must keep it volatile.
9. Shared fleet lesson:
   "A keeper that cannot acquire its memory lane should drop best-effort memory
   work instead of blocking the whole fleet." This is a durable concurrency lesson.
10. Malformed librarian output:
    A provider returns prose plus JSON or `<think>` text. Current code may recover
    a substring or store an `unstructured_note` fallback. This preserves forensic
    evidence, but it also creates noisy rows; live data has 118 such rows.

## Strengths

- Path ownership is correct in Memory OS implementation. The writer reads
  `Config_dir_resolver.keepers_dir ()`; no implementation hit showed
  `"/Users/dancer/me"` or a local `default_base` inside the Memory OS modules.
- The schema is typed. Categories and claim kinds are closed OCaml variants, with
  unknown categories conservative for promotion.
- External refs are no longer inferred from claim prose. That avoids a major
  string-match status-classifier failure mode.
- Fact identity has an SSOT: `claim_identity`. Write-time upsert, recall-time
  dedup, and shared promotion all use that boundary instead of separate
  normalizers.
- Writes are bounded. Fact, event, and episode file stores all have caps with
  hysteresis; the live current store is 15M, not the 1.8G legacy tree.
- Expiration is structural. `valid_until` is generated at write time, recall
  filters expired rows, and cap/merge paths drop expired rows before retention
  ranking.
- Recall failure is visible after #22328. A read/prompt-render failure now
  produces an explicit unavailable block, metric, and ledger `failure_reason`
  instead of silently omitting memory.
- Per-keeper memory work uses `Eio.Mutex` for yielding sections and `Stdlib.Mutex`
  only for short non-yielding tables. That fits the OCaml 5/Eio baseline.
- Provider saturation has a fleet-wide semaphore and per-keeper lane. One keeper's
  memory work should not create an unbounded fleet backlog.
- Tool/image/thinking content is scrubbed or omitted before librarian extraction.

## Findings

### P0 / P1: Fallback Cadence Leak Still Exists On Main

Current `main` still returns an unstructured fallback as `Ok episode` after parse
retries are exhausted (`lib/keeper/keeper_librarian_runtime.ml:481`, `:493`).
`run_best_effort` resets cadence on every `Some (Ok episode)` at `:634-637`.

Real-world impact: if a provider repeatedly returns unparseable JSON, the keeper
stores an ephemeral fallback note and then waits for the normal cadence interval.
The next structured extraction is delayed even though no structured memory was
actually extracted.

Status: PR #22365 implements the correct typed source fix by classifying
`Structured_episode` vs `Unstructured_fallback`, and only structured extraction
records cadence success. However #22365 is still open/draft and CI-red, so this
must remain a current-main finding.

[근거] `gh pr view 22365 --repo jeong-sik/masc --json statusCheckRollup`,
checked 2026-06-26 15:19 KST, confidence High. Result: `Build and Test` and
`CI Gate` failed. Failed harness log shows `masc_goal_transition` validation
error `actor id must match authenticated caller`, not a Memory OS compile error.

### P1: LLM Output Parsing Still Uses Heuristic Recovery

`Keeper_librarian.json_of_output` attempts raw JSON, string-wrapped JSON,
markdown fence stripping, and then extracts the first substring between the first
`{` and last `}` (`lib/keeper/keeper_librarian.ml:122-195`).

This is the main "괴상한 휴리스틱" remaining. It is useful for salvaging messy
model output, but it violates the strict production bar: a prose-wrapped or
multi-object response can be accepted as if the provider obeyed the schema.

Required fix:
- Prefer provider-native JSON schema / structured-output enforcement where the
  active provider supports it.
- Remove first-`{...}` substring fallback from production.
- If fallback must remain, route it to a diagnostic artifact, not the normal typed
  episode parser.
- Add corpus tests for malformed JSON, prose before/after JSON, multiple JSON
  objects, nested braces in strings, and model thinking leaks.

### P1: Deletion Exists But Is Not Fully Operational

Facts/events/episodes are capped on write. Expired facts are dropped during
`cap_facts` and `merge_and_cap_facts` (`lib/keeper/keeper_memory_os_io.ml:539`,
`:620`). GC exists (`lib/server/server_bootstrap_maintenance.ml:219`) but is
default-off (`lib/config/env_config_keeper.ml:275-284`).

Live result: 16 TTL-expired facts remain on disk. Most are `ephemeral`, but one
is a `lesson` row with finite `valid_until`, which shows legacy/schema drift can
produce surprising cleanup semantics.

Required fix:
- Add dry-run GC report command first.
- Turn on GC after dry-run proves it only removes expected rows.
- Add dashboard alerting for `ttl_expired_on_disk > 0` above a small threshold.
- Treat non-ephemeral expired durable categories as migration findings, not just
  cleanup noise.

### P1: Legacy `.masc/keepers` Garbage Is Outside Current Cleanup

Current Memory OS files live under `/Users/dancer/me/.masc/config/keepers`. That
tree is 15M and had no `.atomic_*.tmp` or `PYEOF` residue in a maxdepth-4 scan.

Legacy `/Users/dancer/me/.masc/keepers` is 1.8G and contains:
- `/Users/dancer/me/.masc/keepers/imseonghan/.atomic_80095f.tmp`
- `/Users/dancer/me/.masc/keepers/PYEOF`

This is not a current Memory OS path-hardcoding bug, but it is an operations
problem. Users see `.masc` as one root. If legacy garbage is not migrated,
archived, or pruned, it undermines trust in the memory system.

Required fix:
- Add read-only inventory for legacy `.masc/keepers`.
- Classify files as live, migrated, orphaned, backup, or unknown.
- Produce a dry-run cleanup plan with byte counts.
- Do not delete automatically until an operator approves.

### P1: Recall Ledger Has No Retention Surface

The recall injection ledger records exactly what memory was shown to a keeper,
including failure reasons (`lib/keeper/keeper_recall_injection_ledger.ml:38-70`).
That is good: it is the join key for outcome evaluation. But the live ledger is
54M and the audited path has no retention or compaction policy.

Required fix:
- Add a dated retention policy or compaction job for `recall_injections`.
- Keep a summary index keyed by fact key / trace outcome so evaluation does not
  require indefinite raw JSONL growth.

### P1: Memory Quality Is Not Yet Proven By Outcome Evaluation

Memory OS has the hooks to prove usefulness: recall injects `injected_fact_keys`
and `injected_episode_keys` (`lib/keeper/keeper_memory_os_recall.ml:244-255`,
`:409-419`). But the audit did not find a production-quality eval that correlates
those injected keys to later task success, reduced loops, fewer user corrections,
or faster PR triage.

Required fix:
- Add an outcome evaluator joining recall ledger, execution receipts, terminal
  reasons, human feedback, and PR/check outcomes.
- Measure before/after: repeated mistakes, loop frequency, reviewer correction
  rate, time-to-clean-PR, and useful recall acceptance.
- Promote only facts/lessons that survive this eval loop.

### P2: Timeout Is Not Fail-Closed If Clock Is Missing

`with_timeout ?clock` returns `Some (f ())` when no Eio clock is available
(`lib/keeper/keeper_librarian_runtime.ml:350-356`). The normal server path passes
the Eio clock from context, but this fallback means a context bug can remove
timeout enforcement instead of failing closed.

Required fix:
- For production provider calls, make missing clock an explicit skip/error.
- Keep no-clock execution only in tests through a testing helper.

### P2: Unstructured Fallback Rows Are Useful But Noisy

Live data has 118 `unstructured_note` rows. These preserve forensic evidence
after malformed provider output, and #22337 fixed the dangerous `claim_id`
overload by leaving fallback rows `claim_id=None`. But they still flow through
the normal fact store and can appear as recall context until expiration.

Required fix:
- Keep fallback evidence in a diagnostic stream.
- If retaining in Memory OS, render it only in debug/operator recall, not normal
  keeper task recall.

### P2: Env Surface Is Broad But Centralized

Memory OS env knobs are all in `Env_config.KeeperMemoryOs`
(`lib/config/env_config_keeper.ml:189-304`). This is acceptable, not a scattered
env anti-pattern. The downside is operational complexity: recall, librarian,
cadence, max messages, timeout, runtime override, global provider slot, GC,
consolidation, and consolidation runtime are all separate levers.

Required fix:
- Keep the env surface but add a dashboard/config endpoint that renders effective
  values and whether each is default, env, or boot override.
- Avoid adding new Memory OS env knobs unless they are kill switches or validated
  operator policies.

### P2: Local Mutability Is Mostly Justified

Mutable refs/Hashtbls exist in bounded local contexts:
- provider slot state (`keeper_librarian_runtime.ml:42-56`)
- cadence counters (`:133-199`)
- merge tables (`keeper_memory_os_io.ml:584-610`)
- memory lane pending state (`keeper_memory_lane.ml:3-11`)

This is not a P0 because the yielding sections use Eio primitives and the
`Stdlib.Mutex` sections are short/non-yielding. Still, the code should keep
adding pure helpers around state transitions, as `cadence_step` and
`cadence_step_keyed` already do.

## Hardcoding, Path, Stub, And Library Reuse Checks

Hardcoded local path:
- Targeted search did not find `"/Users/dancer/me"` in Memory OS implementation
  modules. The path hits are tests, diagnostics, or generic server default-base
  surfaces, not Memory OS storage code.
- Memory OS storage path uses `Config_dir_resolver.keepers_dir ()`
  (`lib/keeper/keeper_memory_os_io.ml:26-50`).

Stubs / not implemented:
- Targeted search found no production `failwith`, `assert false`, `TODO`,
  `FIXME`, `not implemented`, or `stub` in the Memory OS/librarian/ledger/lane
  modules audited.

Existing modules / library reuse:
- Good reuse: `Fs_compat.save_file_atomic`, `Dated_jsonl`, `File_lock_eio`,
  `Eio.Mutex`, `Eio.Semaphore`, `Yojson.Safe`, prompt registry, config resolver.
- Weak reuse: JSON object recovery is hand-rolled. Production should lean on
  provider structured outputs, schema validation, or a single shared strict JSON
  boundary rather than module-local substring salvage.

String matching:
- Acceptable: parsing enum strings at the producer boundary into closed variants.
- Not acceptable long-term: using raw model text shape to recover JSON objects.

Silent failure:
- Fixed: recall omission is now explicit unavailable context after #22328.
- Remaining best-effort catches are intentional for post-turn memory, ledger,
  and maintenance so one memory failure does not stop keeper execution. The gap is
  not that they catch; the gap is that some failures do not yet have a user-facing
  enough health surface or cleanup workflow.

## OCaml 5.4 / Eio Review

The implementation mostly follows the OCaml 5.4/Eio direction:
- Immutable snapshots are passed into detached memory work.
- Per-keeper memory lane uses `Eio.Mutex` for work that can yield across provider
  calls.
- `Stdlib.Mutex` is reserved for short Hashtbl/ref critical sections that do not
  call Eio operations.
- `Eio.Cancel.Cancelled` is re-raised in broad catches.

The main Eio production risk is timeout/context enforcement. A provider call that
lacks an Eio clock should not silently run without a timeout. This is the same
class of issue as #22352's no-clock bridge risk, though smaller because the
normal server path does provide the clock.

Jane Street / typed error alignment:
- The code uses `Result` in several boundary APIs, but some parsing failures still
  collapse to `None` or string messages.
- For production, parse boundaries should return typed errors such as
  `Malformed_json | Schema_error of field | Unstructured_output | Provider_timeout`
  rather than just `None` or `"invalid episode JSON"`.

## Research And Competitor Comparison

MemGPT / Letta:
- Strong at explicit agent state, archival/recall memory, and treating the agent
  as stateful across context windows.
- MASC is stronger in local operational integration: typed OCaml schema, per-keeper
  files, Eio lanes, GitHub/CI/keeper runtime evidence.
- MASC is weaker in mature retrieval, semantic indexing, and memory-management UX.

Generative Agents:
- The paper's observation/reflection/planning loop maps well to MASC's episodes,
  lessons, and validated approaches.
- MASC has the observation store, but reflection quality still depends on
  heuristic LLM extraction and lacks a strong outcome eval loop.

Reflexion:
- Reflexion's verbal memory idea matches Memory OS `lesson` and
  `validated_approach` facts.
- MASC needs a stricter loop that says whether recalled lessons actually changed
  the next action or prevented the same failure.

LangGraph / LangMem-style memory:
- These systems expose memory as a first-class long-term store inside agent
  graphs.
- MASC has first-class local stores, but should add more explicit retrieval and
  mutation APIs rather than relying mainly on prompt-time bounded recency.

Mem0 / Zep:
- These are purpose-built memory layers with extraction, session/user memory, and
  managed retrieval.
- MASC is more auditable in repo-local operation and can tie memory to PR/CI/runtime
  evidence, but it lacks their productized memory lifecycle and semantic search.

Net comparison: MASC's unique advantage is operational grounding. It can remember
what actually happened in PRs, keepers, health checks, and CI. Its current
weakness is not storage mechanics; it is ingestion quality, cleanup UX, and proof
that recall improves outcomes.

## Production Plan

Immediate:
1. Land #22365 or equivalent after CI is green, so unstructured fallback does not
   reset librarian cadence.
2. Remove first-`{...}` JSON substring recovery from production parser paths.
3. Add strict typed parse errors and a corpus of malformed provider outputs.
4. Add GC dry-run command and dashboard alert for expired rows.
5. Add legacy `.masc/keepers` inventory and cleanup dry-run.
6. Add retention/compaction for `recall_injections`.
7. Make provider timeout fail-closed when no production Eio clock is available.
8. Keep unstructured fallback as diagnostic evidence, not normal recall content.

Next:
1. Add outcome evaluation joining recall ledger to task/PR/check/human-feedback
   outcomes.
2. Add a memory quality dashboard: useful recalls, stale recalls, noisy fallback
   recalls, repeated mistakes, loop reductions.
3. Promote facts to `_shared` only when corroborated and outcome-positive.
4. Add migration for legacy `rfc0231-v2` rows and unknown categories like
   `external_state`.
5. Add operator-visible effective config for Memory OS env knobs.

## Bottom Line

Memory OS has the right skeleton: typed schema, bounded stores, explicit path
resolution, per-keeper Eio lane, recall visibility, and operational evidence
hooks. It can make keepers more human-like by preserving preferences, constraints,
lessons, and validated approaches across turns.

The system will not earn production trust until it stops accepting heuristic JSON
shape recovery as normal, proves that recall improves outcomes, and gives
operators a safe cleanup loop for expired, legacy, fallback, and ledger data. The
current store is not exploding, but the wider `.masc` memory footprint shows that
forgetting and migration must be treated as first-class product behavior, not
maintenance afterthoughts.
