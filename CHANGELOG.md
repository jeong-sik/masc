# Changelog


## [0.10.0] - 2026-04-18

### Changed

- **Dashboard design-system migration.** Multi-wave sweep of raw Tailwind
  color utilities to semantic CSS var tokens (`var(--ok)`, `var(--warn)`,
  `var(--bad-light)`, `var(--accent)`) across ~50 files.
  - Severity hues (emerald/rose/amber/red) collapsed to `--ok`/`--bad-light`/`--warn`
    (#8271, #8273, #8278, #8279, #8283, #8286).
  - Working hues (sky/blue/violet/...) folded into `--accent` (#8284).
  - Orange/lime sweep (#8285). Neutral-gray (zinc/gray/neutral/stone)
    collapsed to `--text-muted`/`--white-*` (#8281).
  - Final high-shade/extreme variants cleanup (#8288).
  - Paper-theme bridges `--accent`/`--ok`/`--warn`/`--bad` (#8290).
  - Text size hygiene sweep `text-[9px]` → `text-[10px]` (97 instances /
    29 files, #8260).
  - Radius tokens absorb `rounded-[3px]`/`rounded-[18px]` drift (#8291).
  - Sharp corners sweep `rounded-{xl,2xl,3xl}` → `rounded` (#8292).
  - Flat shadows (`shadow-{md,lg,xl,2xl}` → `shadow-sm`) (#8299).

- **Keeper — critical-path + lifecycle fixes.**
  - Surface unified turn critical path failures (#8265).
  - Consume overflow event-bus signal (#8251).
  - Honour declared `max_checkpoint_messages` default on create (#8256).
  - Synchronous `is_registered` check after `start_keepalive` (#8247).
  - Tool-policy validator recognises admin-dispatched keeper tools (#8241).
  - `coord_gc` quarantines broken agent files instead of deleting (#8253).
  - `keeper_tool_affinity.configured_max_k`/`lookback_days` treat empty
    or whitespace-only env values as unset; optional `?getenv` injection
    seam for tests (#8190).

- **Cascade + verification.**
  - Hard-quota-aware immediate cooldown in cascade (#8249).
  - `/api/v1/cascade/health` exposes `hard_quota_cooldown_sec` (#8277).
  - Verification-protocol warns on missing-contract submit (#8276).
  - Verification-panel exposes `task_title` + pending-0 hint (#8259).
  - Dashboard surfaces live `pending_ruling` count instead of hardcoded 0 (#8268).

- **Dashboard runtime + auth.**
  - Auto-provision shared loopback dev token for `/mcp` (#8258).
  - Runtime-panel uses `CollapsibleSection` instead of raw `<details>` (#8275).
  - Ring buffer replaces `spread+slice` for hot-path signals (#8269).
  - Buffer sizes Vite-env overridable (#8270).

- **Sidecar + bridges.**
  - Sidecar honours configured runtime paths (#8267).
  - `oas_sse_bridge` surfaces `keeper_name` on envelope `agent_name` (#8261).

- **OAS pin bump → `v0.159.0`.** `agent_sdk` floor raised from `0.158.0`
  to `0.159.0` (dune-project + masc_mcp.opam + pin script SHA
  `28b3f14c1b0572dc4ce15255a6f0d097fe31275a`). Picks up env-driven CLI
  flags for the three non-interactive transports (`OAS_CLAUDE_STRICT_MCP`,
  `OAS_CLAUDE_MCP_CONFIG`, `OAS_CLAUDE_DISALLOWED_TOOLS`, `OAS_CODEX_CONFIG`,
  `OAS_CODEX_SANDBOX`, `OAS_CODEX_PROFILE`, `OAS_CODEX_SKIP_GIT`,
  `OAS_GEMINI_NO_MCP`, `OAS_GEMINI_ALLOWED_MCP`, `OAS_GEMINI_APPROVAL_MODE`,
  `OAS_GEMINI_EXTENSIONS`). Keeper operators can now lock down MCP /
  tighten approval surface per-deployment without an SDK change. See
  `docs/KEEPER-USER-MANUAL.md` §1.1.1 for the full table.

- **Tool-task schema.**
  - `handoff_context.summary` declared required; runtime error surfaces
    example payload (#8293).
  - Ignore underscore-prefixed internal markers in transition schema (#8289).

### Deprecated
- None.

## [0.9.13] - 2026-04-17

### Changed

- **Dashboard — form control whitelists + new semantic components.**
  - `Select` prop whitelist expanded (id/name/aria/required/blur/testId) + tests 0 → 14 (#8007).
  - `TimeAgo` renders as semantic `<time>` with `aria-label` + `mode` prop + tests 0 → 19 (#8011).
- **Dashboard — highlight-on-match helper wired into 2 panels** (#8012).
- **Keeper — team memory scope enforcement** [codex] (#8016). Keeper team-memory writes now fail closed when the keeper does not own the scope.
- **CI — lib_option_get baseline naturalized 0 → 3** after the lockfree cache refactor in #7953 exposed 3 legitimate call sites (#8022).
- **Docs/design — CDAL PHASE1A rename.** `cdal_eval` references renamed to `cdal_eval_v1`; successor modules clarified (#8020).

### Deprecated
- **Spec sync — board + testing dead refs retired (#8008).**
  - `docs/spec/11-board.md` Maps-to row: dropped `lib/tool_vote.ml` and
    `lib/tool_social.ml` (both folded into `lib/tool_board.ml` per that
    file's own `Replaces tool_social.ml for new installations` header);
    corrected sub-library path `lib/board/` → `lib/board_types/`.
  - `docs/spec/15-testing.md`: §5.3 Anti-Fake and §5.6 Keeper Contract
    collapsed into RETIRED paragraphs (`lib/anti_fake.ml`,
    `lib/keeper/keeper_contract.ml` purged — 0 grep hits each).
  - §5.5 Keeper Verifier rewritten to describe the 3-way successor
    split: `lib/verifier_core.ml` + `lib/verifier_oas.ml` +
    `lib/keeper/keeper_guards.ml` (`lib/keeper/keeper_verifier.ml`
    removed in #2589). Maps-to row adjusted accordingly.
  - Net: 47 lines of stale catalogs removed, 17 lines of retirement
    records + successor pointers added.

## [0.9.12] - 2026-04-17

### Changed

Dashboard prop-whitelist expansion batch + structural cleanup. Autocoder-
driven increments on top of the 0.9.11 release.

- **Dashboard — form control prop whitelists.**
  - `Checkbox` prop whitelist expanded (id/name/aria/value/testId) + tests 0 → 13 (#8000).
  - `NumberInput` prop whitelist expanded (id/name/aria/autocomplete/keyboard/blur/testId) + tests 0 → 15 (#8005).

- **Dashboard — copy affordance.**
  - `CopyIdButton` placed next to truncated `trace_id` displays (#8001).

- **Dashboard — connector/keeper views.**
  - K×M `ConnectorKeeperMatrix` added under all-connectors view (#8002).

- **Dashboard — cleanup / clarity.**
  - Retired `runtime-params` / `param-audit` state cluster purged (#8003).
  - `'runtime'` label overload disambiguated; card titles made KO-only (#8004).

### Deprecated

- None.

## [0.9.11] - 2026-04-17

### Changed

Post-0.9.10 bulk merge cycle (admin override). Corrects the four entries
(#7981, #7982, #7985, #7986) that landed *after* the v0.9.10 tag commit
(`9820decae`) and were incorrectly attributed to 0.9.10 in #7994 — they
belong to this release.

- **Dashboard UX.**
  - Cascade Profiles + Keeper Mapping merged into one Cascade Routing card (#7986).
  - Visible toast cap at 5 + test coverage 0 → 9 (#7985).
  - Text filter on harness-health compaction/handoff lists (#7981).
  - Text filter on agent-detail owned-tasks + histories (#7982).
  - `CopyIdButton` wired into keeper-detail prompt fingerprint displays (#7989).
  - `ActionButton` prop whitelist expanded (aria-busy/id/title/testId) + tests 0 → 16 (#7995).
  - `TextInput` / `TextArea` now forward `id` — fixes orphan `<label for>` a11y regression (#7987).

- **Keeper / cascade / server.**
  - Raw `cascade_name` preserved on keeper side; canonicalization pushed to point-of-use (#7978).
  - `Accept_rejected` split from success in cascade evaluator; added `evict_idle` + `rejected_in_window` metrics (#7996).

- **Performance.**
  - Autoresearch pagination: in-memory mtime cache removes O(N) file I/O bottleneck (#7988).

- **Dead code / cleanup.**
  - Dead `mission-cards` barrel removed (no importers, `SummaryStat` unreferenced) (#7991).

- **Spec / docs / tooling.**
  - RFC-0004: OCaml ↔ TS shared contract (SSE + gRPC-web) (#7999).
  - Spec §7/§8/§10 type sections retired (checkpoint / context_budget / message_schema purged) (#7997).
  - Capsule Execution Plan Slices A–C marked historical (team_session retired) (#7984).
  - OAS pin bumped to `0.155.1` + compat fixes (#7993).
  - CHANGELOG `[0.9.10]` TBD placeholders filled (#7994).
  - `.tmp/` scratch directory added to `.gitignore` (#7998).

### Deprecated

- **Capsule Execution Plan slices marked historical (#7984).**
  `docs/design/masc-capsule-execution-plan.md` Slices A–C targeted the retired
  `team_session` subsystem (9 dead `lib/team_session/*` and
  `lib/tool_team_session_*` module refs). Slices preserved as migration context
  for future `board_posts` + keeper-FSM coordination work. Product Thesis,
  Boundary Rules, Execution Order, Social Runtime Invariants, and Review Gate
  sections remain the current design stance.

## [0.9.10] - 2026-04-17

### Changed

Bulk merge cycle (2 `/loop` batches, admin override) covering dashboard UX, keeper observability, lock-free refactors, and spec/docs cleanup.

- **Dashboard UX.**
  - Connector overview strip gains an incident banner for sidecars dropped in the last 5 min (#7925) and an aggregate summary line (#7944).
  - Auto-restart toggle chains Save → stop → start on connector config (#7933).
  - Quick-bind form supports Enter-to-submit with per-connector channel ID hint (#7970).
  - Setup guide gains per-step completion checklist (#7974) and Vercel-style Start button on onboarding cards (#7963).
  - Copy affordance: new `CopyIdButton` on transport-health hot session ids (#7973) with inline "Copied" confirmation (#7980).
  - Live-ticking counter on startup-warning banner (#7967).
  - Text filters added to mission worker-runs evidence list (#7975) and runtime-monitor model-id/tool-name search (#7957).
  - Keyboard shortcuts for connector navigation (1–4, ?) (#7958).
  - Keeper modal KPIs regrouped into 4 question-led sections (#7946).
  - Live Judge promoted to page title; empty toolbar card purged (#7969).
  - AA accessibility pass on connector readiness rail (#7960).
  - Zod parse boundary for SSE events (#7955).
  - Outcomes rollup added to keeper JSON response (#7941).
  - Autoresearch loops API + list UI gain pagination (#7861).

- **Keeper / server / lib.**
  - Keeper behavioral regime deriver MVP (7th FSM axis: Crashing/Thrashing/Healthy) (#7968).
  - HTTP transport session/conn registries: global mutexes eliminated via lock-free atomic maps (#7979).
  - `a2a` global mutexes eliminated via lock-free atomic maps (#7857).
  - Dashboard cache global mutex eliminated via lock-free atomic map (#7953).
  - New `Lockfree_atomic` helper module extracted for reuse (#7952).
  - `bash exec` substrate semantics hardened (#7891).
  - Board flusher actor started with jsonl backend (#7915).
  - Autoresearch: exception-throwing serde helpers removed (#7942).
  - Dashboard: unexport internal-only helpers across 2 component files (#7977).
  - Dead cluster removal: `governance-panels/detail/strips` (follow-up #7927) (#7962), 3 orphan components (mission, connector-binding-summary, execution/shared) (#7938), orphan `keeper_handoff_delta` module (#7948).

- **Spec / docs / tooling.**
  - TLA+: `KeeperConditionsGovernPhase` liveness spec + clean/buggy cfg pair (#7965).
  - Spec §2 module table + §17 references synced with `lib/coord/` (room → coord rename) (#7954).
  - Comprehensive glossary sync: Chain/CP/agent_ecosystem/context_budget retired (#7964).
  - Keeper spec §05 synced with current keeper module layout (#7972).
  - Dead `code_refs` dropped (`sdk_version.ml`, `agent_ecosystem`, `message_schema`); §6 retired (#7945).
  - Retired CP/MDAL dropped from `DASHBOARD-INTEGRATION`; self-contradicting `BENCHMARK-RUNBOOK` note fixed (#7943).
  - Runtime gate for frontmatter `code_refs` existence (#7966).
  - OAS pin bumped to `cb4beb52` (PR-O2 pipeline → `Complete.complete`) (#7956).
  - `oas-pin` orphan SHA `6c79cf3f` replaced with ref-reachable `f2387e2a` (#7898).

### Deprecated

- None.

## [0.9.9] - 2026-04-17

### Changed

- **README facts aligned with code (PR #7730).**
  - OAS pin floor in badge + Tech Stack: `0.118.2` → `0.153.0` (matches `masc_mcp.opam` and `dune-project`).
  - Keeper lifecycle diagram corrected from "11-state" to the actual **12 states** in `lib/keeper/keeper_state_machine.mli` (`Overflowed` was missing).
  - WebRTC signaling endpoints made precise: `POST /webrtc/offer`, `POST /webrtc/answer`, gated by `Server_webrtc_transport.is_enabled`.
  - Personal-project disclaimer added (Korean + English) at the top.
  - "Production surface" framing replaced with surface-map vocabulary that doesn't imply external SLA.
- **Root scratch removed (PR #7744).**
  - `git rm` on 9 tracked one-off files: `pr-payload.json`, `pr6975.json`, `pr_body_tmp.txt`, `test-integration-{retry,verify}.txt`, `test_portal_lock_stress.ml` (no rg refs in `lib/bin/test/scripts`), `EIO_REFACTOR_ISSUES.md`, `AGENTS.md` (CLAUDE.md is the live SSOT), `session_tracker_qa_tests.md`.
  - `.gitignore` extended with `pr-*.json`, `pr_body_*.txt`, `test-integration-*.txt` so future drops are ignored automatically.
- **Audit tracker added (PR #7749).** `docs/_audit/2026-04-17-doc-classification.md` classifies all 145 markdown files in `docs/` into A·Live (81) / B·Historical (46) / C·Hype (7) / D·Duplicate (11), with grep evidence and disposition per file. Tracker only — actual delete / archive / merge / frontmatter PRs are sequenced separately.

No code changes. Bump captures the documentation/hygiene cycle as a tagged release boundary.

## [0.9.8] - 2026-04-17

### Changed
- **OAS pin bump to `v0.153.0`** — picks up OAS PR #975
  (`Budget_strategy.default_summarizer` exported in the `.mli`).
- **`keeper_summarizer.ml` simplified** — deletes the local
  `default_extractive_summary` re-implementation and delegates to
  `Agent_sdk.Budget_strategy.default_summarizer` directly. This was
  the follow-up promised in PR #7668 (Gen4 compaction-layer [STATE]
  scrub). Net diff: −36 lines; behavior unchanged (4 existing tests
  in `test_keeper_summarizer.ml` still pass).
- `scripts/oas-agent-sdk-pin.sh` BASE/SHA/MIN → `v0.153.0` /
  `485ac29af8c14942e29c99381a9946c7000a55c9` / `0.153.0`.

## [0.9.7] - 2026-04-17

### Changed
- **OAS pin bump to `v0.152.0`** — raises the `agent_sdk` floor in
  `dune-project` and updates the helper constants in
  `scripts/oas-agent-sdk-pin.sh` (BASE_VERSION, SHA, MIN_VERSION) to
  `d5d92f38f6490b924238b5a176a9feb6e79d17e3`.
  - Picks up OAS PR #973 (`Agent.options.summarizer` +
    `Builder.with_summarizer`): downstream consumers can now inject a
    custom summarizer callback into `Budget_strategy.reduce_for_budget`
    via the options record instead of falling through to
    `default_summarizer`.
  - Also picks up OAS PR #962 (Anthropic `cache_extended_ttl`), included
    transitively via the 0.151.0 release.
  - No runtime behavior change in masc-mcp itself: this is a pin-only
    bump. Registering a `[STATE]`-aware summarizer is the follow-up step
    and ships separately.

## [0.9.6] - 2026-04-16

### Fixed
- **Keeper continuity resonance loop** (PR #7612, #7615, #7618) — closes the
  save/read asymmetry that caused keepers to echo their own prior `[STATE]`
  narrative every turn.
  - `keeper_world_observation.ml:read_continuity_summary` now prefers the
    structured snapshot stored in `Checkpoint.working_context` over
    re-parsing `[STATE]` blocks from message bodies (PR #7612). Completes
    the RFC-MASC-001 Phase 1 read side; the save side already wrote
    structured JSON when enabled.
  - `scripts/retro-clean-keeper-continuity.sh` one-shot: dry-run default,
    `--apply` backs up and zeroes stale `continuity_summary` fields across
    `.masc/keepers/*.json`. Preserves all other fields (PR #7615).

### Changed
- **`MASC_STRUCTURED_STATE` default flipped to `true`** (PR #7618) —
  completes RFC-MASC-001 Phase 1 rollout. The structured
  `Checkpoint.working_context` save path is now active by default;
  combined with PR #7612 every keeper turn writes a typed snapshot and
  reads it back on the next turn instead of re-parsing `[STATE]` text.
  Accepted opt-out values: `false`, `0`, `no`. Legacy text `[STATE]`
  fallback is preserved for checkpoints without `working_context`.

## [0.9.5] - 2026-04-16

### Added
- **CDAL Verdict Gate** (PR #7531, env `MASC_CDAL_GATE_ENABLED`, default off) —
  `cdal_verdict_gate.ml` blocks task completion when CDAL verdict is Violated
  or Inconclusive with blocking gaps. Reads persisted verdicts with task_id
  filtering via typed `persisted_verdict` envelope.
- **Task verification FSM** (PR #7531, env `MASC_VERIFICATION_FSM_ENABLED`,
  default off) — new `AwaitingVerification` task_status + 3 actions
  (`submit_for_verification`, `approve`, `reject`). Cross-agent enforcement
  (worker ≠ verifier). Contract-driven deadline and required role.
- **Verification protocol** (`verification_protocol.ml`) — board post + SSE
  event emission on submit/approve/reject/timeout. Updates
  `Verification.ml` state machine on cross-agent verdicts.
- **Keeper-as-verifier** — `pending_verification_count` in
  `world_observation`; keepers can observe and act on verification requests
  via `masc_transition(action=approve|reject)`.
- **Typed evidence criterion** — `Types_core.evidence_criterion` ADT
  (Schema_match/Contains/Not_contains/Custom) replaces string list for
  `task_contract.verify_gate_evidence`. Backward compat reader.
- **Env-configurable knobs** —
  `MASC_CDAL_VERDICT_LOOKUP_LIMIT` (default 500),
  `MASC_VERIFICATION_TIMEOUT_CHECK_INTERVAL_SEC` (default 60.0).

### Changed
- verification_id now cryptographically random (128-bit CSPRNG via
  mirage-crypto). Previously used `Hashtbl.hash` + timestamp (weak).
- Dashboard shows `검증 대기` badge for `awaiting_verification` status
  (accent color, event icons).

### Deprecated
- Legacy `_task_id` string-prefix JSONL envelope still read but no longer
  written. Reader handles both formats.

## [Unreleased]

### Changed (specs)

- **`KeeperContextLifecycle.tla` completeness pass** — closes 3 of the
  gaps flagged by the 2026-04-16 compaction FSM/TLA+ audit
  (#7568 §1.4):
  - `CompactionFailed(k)` action added (documentation-only in the
    clean `Next` to avoid infinite retry without a bounded retry
    variable; exercised by `NextBuggy`). Models the
    `Compaction_failed` event at `keeper_state_machine.ml:383-389`
    that routes `compacting → overflow_retry` without clearing
    `context_overflow`.
  - `CompactionCompletesBuggy(k)` + `NextBuggy` + `SpecBuggy` —
    new Bug Model variant that reallocates `context_id` during
    compaction (models a broken Context.t identity path).
  - `CheckpointConsistency` strengthened: previously a duplicate of
    `TurnMonotonicity` (`ckpt_turn <= turn + 1`); now verifies that
    `ckpt_ctx_id` references an allocated context_id
    (`0 < ckpt_ctx_id < next_ctx_id`). Strengthens formally-verified
    surface without weakening the turn-monotonicity check.

### Added (specs)

- `KeeperContextLifecycle-buggy.cfg` — Bug Model cfg that runs the
  deliberate `CompactionCompletesBuggy` variant. TLC finds
  `Invariant ResumeIdentity is violated` at 377 states / depth 6 /
  1s. Completes the Bug Model pattern coverage that was missing.
- `KeeperContextLifecycle-ci.cfg` — smaller-constant cfg for quick
  invariant validation in every CI build. Reserves the default cfg
  (5.6M+ states) for nightly/release runs. Liveness
  (`PROPERTIES`) intentionally omitted — see file header comment.

### Follow-ups (out of scope)

- Add a bounded retry-budget variable to model the
  `compact_retry_exhausted` latch → `Paused` routing, then include
  `CompactionFailed(k)` in the clean `Next` and re-add liveness to
  `KeeperContextLifecycle-ci.cfg`.
- Upgrade `TurnSucceeds` fairness from WF to SF so small-model
  liveness holds without growing the state space (exposed by
  `KeeperContextLifecycle-ci.cfg` during this work).

## [0.9.5] - 2026-04-16

### Added

- **Keeper compaction audit** (`lib/keeper/keeper_compact_audit.{ml,mli}`).
  New Event_bus subscriber that observes `ContextCompactStarted` and
  `ContextCompacted` payloads emitted by OAS, synthesises a per-keeper
  `compaction_id` to correlate Start/Complete pairs, and appends
  structured JSONL rows to `.masc/data/harness-compact/YYYY-MM/DD.jsonl`.
  Rolling retention (default 14 days, override via
  `MASC_COMPACTION_AUDIT_RETENTION_DAYS`) prunes old day-files on every
  write — self-healing, no cron. No OAS changes required; subscriber
  runs alongside existing `oas_sse_bridge` each on its own bounded
  stream.
- **Audit CLI** (`bin/masc_compaction_audit.ml`, installed as
  `masc-compaction-audit`). Options: `--since`, `--until`,
  `--keeper NAME`, `--orphans-only`, `--prune`, `--retention-days`.
  Pairs Start/Complete by `compaction_id`, emits human-readable summary,
  flags orphan rows (compaction that never completed, or server crash).
- **Compaction FSM/TLA+ audit** (`docs/audits/compaction-fsm-tla-audit-2026-04-16.md`,
  #7568). Traceability matrix for `KeeperContextLifecycle.tla` and
  `MemoryCompaction.tla` against 12-phase OCaml FSM. Confirms
  `Compaction_completed`/`Compaction_failed` handlers align with spec
  intent; reclassifies the `manual_reconcile_required` drift from prior
  audit as abstraction mismatch (live behaviour correct via PR #6834's
  separate event dispatch). Flags gaps: missing
  `KeeperContextLifecycle-buggy.cfg`, no `CompactionFailed` action in
  context spec, 3-of-5 gate abstractions.

## [0.9.4] - 2026-04-16

### Added

- **Runtime TOML config** for all 4 Python sidecars (#7509, #7518). Each
  sidecar reads an optional `$MASC_BASE_PATH/.gate/runtime/<kind>/config.toml`.
  File absent = field defaults only (zero-config works). Secrets stay in
  env vars. Priority: env > TOML > field default.
- **Shared bindings-store helpers** (`gate_shared/bindings_store.py`,
  #7501). `load_bindings` + `save_bindings` free functions replace 3x38
  duplicated lines across Slack/iMessage/Telegram sidecars.
- **Env-var aliases** for Slack + Telegram timeout/path config fields
  (#7506).
- **Cascade `weighted_entry.supports_tool_choice`** (#7493). Per-entry
  capability override parsed from cascade.json; `sangsu` profile's
  Ollama entry declares `"supports_tool_choice": true`.

### Changed

- **OAS pin bumped to v0.150.0** (#7493). Removes
  `OAS_OLLAMA_SUPPORTS_TOOL_CHOICE` env var in favor of per-config
  `Provider_config.supports_tool_choice_override`.
- **Code quality pass** (#7516): trimmed 56 LOC of excessive comments +
  fixed 3 TOCTOU `Sys.file_exists` pre-checks in `read_json_file_opt`.

### Fixed

- Keeper: redirect `gh` to keeper_shell op=gh (#7474), demote
  semaphore_wait logs to INFO (#7472), add admin tools to Keeper_denied
  surface (#7455), hand off after overflow retry (#7435), accept both
  `pr_number` and `number` in keeper_pr_review (#7476).
- CI: pin `ocaml/setup-ocaml` to avoid upstream opam-binary regression
  (#7499).
- Dashboard: activity_graph events_shown vs events_store_total (#7502).
- Coord: before-state snapshots in error path logging (#7512), unified
  transition log_event JSON (#7504), correlation_id/run_id on task
  activity (#7511).

## [0.9.3] - 2026-04-16

### Changed

- **Gate wire vocabulary migrated** from `keeper_name` to `destination_id`
  across a 4-phase rolling deprecation. The Gate library is en route to a
  standalone `gate-mcp` repo (Track B4); `keeper_name` carried
  MASC-specific language that didn't belong in a generic gate contract.
  Phases:
  - Phase 1 (#7482): `inbound_of_json` accepts either key (prefers
    `destination_id`).
  - Phase 2 (#7484): `outbound_to_json` emits both keys.
  - Phase 2b (#7485): sidecar `GateResponse.from_json` parses either
    key on the consumer side (single shared helper covers all four
    Python sidecars).
  - Phase 3 (#7487): `outbound_to_json` drops `keeper_name`; only
    `destination_id` emitted now.
  - Phase 4 (future major release): rename internal OCaml record field
    and inbound-only `keeper_name` parse as well.

### Migration note

Out-of-tree consumers that still read only the `keeper_name` key from
gate reply JSON now see `null`. Upgrade to read `destination_id`. The
transition window was Phase 2 → Phase 3 (both keys emitted); consumers
had the full Phase 2 release to migrate.

## [0.9.2] - 2026-04-16

### Changed

- **B3c Python sidecar migration complete**. All four Python sidecars
  (`discord-bot`, `imessage-bot`, `slack-bot`, `telegram-bot`) now
  default to `.gate/runtime/<kind>/*` and share the same 1-tier legacy
  read-fallback pattern. Pre-v0.9.0 `bindings.json` auto-discovered on
  first startup; next save writes to the new default (#7477 iMessage,
  #7478 Slack, #7479 Telegram). Discord already migrated in v0.9.1.

### Fixed

- **OCaml bootstrap no longer depends on upstream latest-opam auto-pick**.
  On 2026-04-16 the latest stable `opam 2.5.1` release was published
  before Linux x86_64 binaries were attached, so `ocaml/setup-ocaml`
  failed early with `Failed to find opam binary for 'linux' and 'x86_64'`.
  The shared toolchain bootstrap now downloads the published `opam 2.5.0`
  Linux binary directly and `release.yml`, `webrtc-live-interop.yml`, and
  `deploy-railway.yml` reuse the same local bootstrap.
  Closes #7475.

## [0.9.1] - 2026-04-16

### Changed

- **Gate runtime path migration**: default storage paths move from
  `.masc/connectors/<kind>/*` to `.gate/runtime/<kind>/*` for Discord
  (OCaml + Python sidecar) and iMessage (OCaml). The pre-v0.9.0 layout is
  demoted to `legacy_*_path` so existing deployments see a transparent
  read-fallback — next write lands at the new default (#7467, #7468, #7470).
- iMessage's OCaml `configured_read_path` gained a required `~legacy`
  parameter, matching the Discord resolver in
  `Channel_gate_discord_names`. Read priority: env var > new default (if
  file exists) > legacy (if file exists) > new default (stable for later
  creation) (#7468).
- Discord sidecar cleanup: the `LEGACY_BASE_ROOT = Path("sidecars/discord-bot")`
  constant and `_resolve_legacy_storage_path` helper were removed. They
  served a 2026-Q1 cwd-relative layout (`sidecars/discord-bot/.gate/discord_*`)
  that is no longer auto-discovered; deployments still on it must set
  `DISCORD_*_PATH` env vars explicitly (#7470).

### Deferred to v0.9.2

- iMessage, Slack, Telegram sidecar migrations (Python). These sidecars
  currently have **no read-fallback loop** in their `bot.py` entry, unlike
  Discord. Each needs a 1-tier fallback wired in before the `DEFAULT_*` →
  `LEGACY_*` rotation can safely ship.

## [0.9.0] - 2026-04-16

### Added

- **Dashboard UX**: density toggle (comfortable/compact) (#7377); Compound Graph
  toggle bound to `g` (#7398); tab anomaly indicator on selected keeper (#7383);
  manual refresh button + `r` shortcut (#7378); Watson-pattern inferred reason
  on transition trail (#7397); time-windowed observatory telemetry (#7390).
- **Keeper features**: social transition reasons exposed + cross-turn state
  (#7399, #7395); magentic ledger social model + TLA+ spec (#7426, #7430);
  campaign FSM harness (#7385); `sangsu` cascade profile — local-first Ollama +
  GLM fallback (#7404); pipe support in `masc_code_shell` (#7393).

### Changed

- **Discord connector dashboard is now keeper-first** (#7388). Each configured
  keeper has its own section with inline channel-binding management; bindings
  that reference a keeper not in the directory are surfaced under `⚠` instead
  of being silently dropped. Replaces the prior binding-first grouping that
  users reported as opaque across 5 distinct confusion points.
- **Gate library extraction**: pure Gate modules (`gate_protocol`,
  `channel_gate_connector`, `channel_gate_discord_*`, `channel_gate_imessage_*`,
  `channel_gate_metrics`, `gate_time_util`) moved to `lib/gate/` as the
  `masc_gate` sub-library (#7407 B1a). `channel_gate` facade joined the same
  sub-library after Pulse extraction (#7457 B1c). Call sites unchanged thanks
  to `wrapped false`. Prerequisite for the planned standalone `gate-mcp` repo.
- **Pulse library extraction** (#7452 B1b): the beat engine moved to
  `lib/pulse/` as the `masc_pulse` sub-library. Unblocks Gate's dependency on
  Pulse without routing the arrow back through `masc_mcp`.
- **OAS pin → v0.148.0** (from v0.141.0) (#7394 + prior pins). Legacy cascade
  API removed from OAS across v0.142.0–v0.148.0 — `Judge.judge` and
  `Tool_selector.default_rerank_fn` now take a single `Provider_config.t`, and
  `Cascade_executor` was deleted (839 LOC). Cascade orchestration is now
  entirely a MASC concern; `keeper_agent_run` resolves the cascade locally,
  picks the first healthy provider, and passes a single provider to the
  single-provider SDK. Falls back to `core+prefilter+discovered` on
  no-healthy-provider (same as before).
- **`Room` module retired** (#7355): split into `room_state.ml` + renamed
  remainder to `Coord`.
- **Hashtbl → immutable StringMap/StringSet** across 14+ modules: `exec_memory`
  (#7414 #7416), `memory_bank` (#7429), `memory_recall` (#7421), `hooks_oas`
  (#7428), `tool_diversity` (#7425), `types_profile` (#7423), `rate_limit`
  (#7420), `cancellation` (#7419), `supervisor` (#7409 #7410), `context_core`
  (#7418), `exec_shared` (#7417), `tool_policy` (#7359), `agent_identity`
  (#7422), `streamable_http session storage` (#7427).
- Stringly-typed internal variants replaced with typed sums (#7347).
- `fail_fast_enabled` → `startup_abort_eligible` rename (#7415).

### Fixed

- Dashboard: 50-task hard cap removed (#7432); legacy composite payload
  normalized (#7412); duplicate cache timeout WARN in bg-revalidate (#7446);
  repeat shell cache timeout on rooms with many board posts (#7402).
- Keeper: deduplicated tool_use_failure + cycle-failure WARN/ERROR
  (#7454, #7451); `gh` timeout floor + org allowlist in `validate_gh_command`
  (#7433); status tails sorted + continuity fallback marker (#7363); real-cause
  pointer when `rg` exits 2 (#7408).
- Log: normal keeper/JSON flows no longer WARN (#7444).
- Board: `masc_board_post` accepts `body` alias + auto-fills author (#7445);
  duplicate 100-post pagination cap removed (#7396).
- Checkpoint: malformed checkpoint detection logging in `load_latest` (#7413).

### Removed

- `keeper_pr_submit` tool + hardened `gh`/dashboard flows (#7389).
- 18 dead permission entries (#7434); dead tool references
  (`masc_release`, `swarm_start` variants) (#7376).
- Dead `Blocked` variant from `turn_outcome` (#7346).
- Dead functions from `keeper_status_bridge` (#7403, #7406).

## [0.8.0] - 2026-04-15

### Changed
- **Tool registry pruning** (#7184): removed 65 dead tools with zero
  usage in April 2026 tool_usage logs. Deleted 5 entire subsystems
  (verify_*, auth_*, repair_loop_*, handover_*, heartbeat internals)
  as 19 source files + ~7,700 lines. Also pruned individual dead
  handlers, schemas, permission entries, and dispatch arms for 25+
  system-internal tools (agent eval, error tracking, lock/unlock,
  cancellation, subscription, progress, feature_flags, init,
  governance_set, set_room, etc.). keeper_denied surface reduced to
  `masc_reset`, `masc_spawn` only. masc_heartbeat dispatch relocated
  from deleted tool_heartbeat.ml to tool_room.ml.

### Added
- Operator-facing context overflow recovery tools (#7115). Two new MCP
  tools paired with the `Overflowed` phase introduced in #7083:
  - `masc_keeper_compact`: dispatches `Operator_compact_requested` to the
    keeper FSM and runs checkpoint compaction via OAS
    `recover_latest_checkpoint_for_overflow_retry`. Phase precondition is
    `Overflowed`/`Paused`/`Compacting`; `force=true` bypasses for
    `Running`/`Failing`.
  - `masc_keeper_clear`: last-resort context wipe. Loads the checkpoint,
    clears non-system messages (system prompt preserved by default), saves
    a new checkpoint, dispatches `Operator_clear_requested`. Requires an
    operator-provided `reason` for audit trail.
- Prometheus counters for the new operator tools:
  `masc_keeper_operator_compact_total{keeper,result}` (result ∈
  `ok|no_checkpoint|precondition`) and
  `masc_keeper_operator_clear_total{keeper,preserve_system}`.
- `checkpoint_found` field in the `masc_keeper_clear` response so
  operators can distinguish "no messages to clear" from "no checkpoint
  on disk".

### Fixed
- `masc_keeper_compact`/`masc_keeper_clear` now read/write checkpoints
  from `session_base_dir(config)` (`<masc_root>/.masc/traces`) instead
  of the incorrect `<base_path>/<keeper_name>`. Previous path would have
  made the tools always report missing checkpoints.
- When no valid checkpoint exists, `masc_keeper_compact` now dispatches
  `Compaction_failed` rather than `Compaction_completed { 0, 0 }`. The
  latter was a false-success signal that would clear `context_overflow`
  even though no compaction happened.

## [0.7.0] - 2026-04-14

### Added
- Prometheus metrics dashboard surface under monitoring tab (#6974). Fetches
  `/metrics`, parses Prometheus text format, renders 8 categorized tables
  (Server, Agent, Keeper, Transport, Inference, Tool, Delta, Provider).
- Clickable links from Prometheus labels: `keeper=` labels navigate to
  keeper detail, `tool_name=` labels navigate to tool-quality with
  highlight-and-scroll of the matching row (#7017).
- Agent + Transport metric categories — recategorize `masc_agent_*`,
  `masc_grpc_*`, `masc_ws_*` that previously fell into Other (#7017).
- RFC-0003 Keeper Composite Lifecycle docs + TLA+ spec with buggy variants
  (cascade, compaction, recovery) for regression-style verification (#7020).

### Fixed
- UTF-8 sanitization on outbound telemetry writers. `keeper_tool_call_log`
  and `oas_sse_bridge` now scrub invalid UTF-8 before persisting or
  broadcasting, eliminating ~12% JSONL row drop when tool output contains
  truncated multi-byte sequences (#6929).
- Prometheus histogram export format. `to_prometheus_text()` now emits
  histograms as `summary` type with `_sum`/`_count` pair rather than the
  invalid `histogram` bare type, so Prometheus servers parse the metrics
  correctly (#6936).
- `tool_usage_log` syntax error at line 105 (`let counts = fold_left ...`
  missing `in`) that broke Build/Test, Health, and Lint CI (#6975).
  Complexity comment updated from O(1) to O(log n) to match StringSet.mem.

### Changed
- Concurrency hardening: serialize `keeper_recurring` tasks Hashtbl +
  atomic id counter (#7022), `sse event_buffer` Queue with Eio.Mutex
  (#7016), `tool_shard` agent_shards read-modify-write (#6985).
- Pin `agent_sdk` to 0.134.0 (#7012).
- CI `ci_core=true` no longer forces TLA+, saving ~14 min per run (#7024).
- Dashboard: remove unused config binding in `ordered_room_ids` (#7021).

## [0.6.0] - 2026-04-14

### Added
- Dashboard OAS telemetry surface (#6978).
- `oas_sse_bridge` usage relay wiring (#6938).

### Changed
- Concurrency and observability fixes carried over from the 0.5.x line.

### Notes
- Version bumped in `dune-project` and `masc_mcp.opam` by #7009. This
  entry finalizes the release docs that were omitted in that bump, so
  `scripts/check-version-truth.sh` stops failing on every main-base PR.

## [0.5.11] - 2026-04-13

### Changed
- Replace all `Eio.traceln` in `lib/` with structured `Log` module
  calls (cascade_inference, autoresearch_codegen, dashboard judges,
  opentelemetry_client). Zero ad-hoc traceln calls remain.
- Add relay calibration drift metric: warn on correction_factor
  outside [0.5, 1.5], debug on shift > 0.1.

## [0.5.10] - 2026-04-13

### Added
- MASC-driven cascade FSM Phase 2: direct provider failover from MASC (#6776)
- Event_bus envelope API adoption: correlation_id + run_id metadata (#6777)
- Groq cascade fallback restored (#6566)
- OAS log bridge to masc-mcp structured logging (#6618)
- Keeper cascade provider allowlist env knob (#6478)
- Cross-model enforcement rate on dashboard (#6565)
- Keeper FSM dashboard exposure + TLA+ bug model (#6556)
- Prometheus llm_provider_http_status metrics (#6514)

### Fixed
- OAS pin v0.124.2: GLM auth passthrough (static_token) + intra-turn truncation (#6781, #6790)
- Cascade: add default_api_key_env for GLM providers (#6784)
- Admission queue: size to actual decode parallelism (#6768), passthrough mode (#6788)
- Keeper: context compaction in reducer (#6731), unified prompt CI alignment (#6700, #6783)
- Test: prevent integration tests from leaking real PRs to GitHub (#6756)
- Test: align admission queue default (#6785)
- Remove dead blocker_class_of_failure_reason (#6778)

### Refactored
- Spawn: add mcp_flag/prompt_flag types, replace match tables (#6767)
- Keeper: immutable string list for keeper_internal_set (#6761)

### Docs
- RFC-MASC-001 (checkpoint boundary migration), MASC-004 (memory bridge), MASC-005 (dashboard eval consumer) (#6787)

## [0.5.9] - 2026-04-12

### Added
- Harden OAS telemetry visibility and proactive monitoring (#6679)

### Fixed
- Keeper: add keeper_board_delete + cleanup to boundary-exempt list (#6698)
- Lazy: replace Stdlib.Lazy with Eio.Lazy in keeper modules (#6696)
- Dashboard: externalize agent status thresholds (#6683)
- Prompt: restore world prompt contract and sanitize unified prompt (#6675)
- Prompt: reinforce playground containment in keeper capabilities (#6678)
- Re-raise Eio.Cancel.Cancelled in 5 catch-all handlers (#6697)
- CI: unblock Build and Test (#6699)

### Hardened
- Store cache: mutex-protect Dated_jsonl store caches (#6690)
- Agent registry: serialise session cache mutations (#6682)

### Performance
- Memory OAS bridge: move episode JSONL load outside cache mutex (#6671)
- Prompt registry: move markdown disk reads outside registry mutex (#6663)

## [0.5.8] - 2026-04-12

### Fixed
- SSE: stop double-incrementing event_counter when ~id is passed (#6660)
- RNG: guard module-level Random.State with Eio.Mutex in 3 modules (#6652)
- Repair loop: gate working_dir on caller playground (#6651)
- Local runtime pool: drop dead select_runtime, re-check fingerprint after env load (#6650)
- Cascade: remove coding_first profile, cap max_tokens to 32768 (#6687)
- Cascade: clamp keeper_unified + coding_first max_tokens to 32768 (Groq limit) (#6686)
- Build identity: probe exe_dir before cwd for git commit (#6688)
- Keeper: masc_* boundary-exempt gap + cascade.json prune (#6681)
- Worker OAS: stop sending min_p=0.0 to cloud providers (#6672)
- Keeper checkpoint store: classify Eio.Io Fs Not_found as Not_found (#6655)

### Changed
- Bump OAS pin for GLM max_tokens clamp (#6689)
- Improve keeper timeout visibility (#6552)

### Performance
- Board: move Agent_economy.earn outside store.mutex (#6649)

## [0.5.7] - 2026-04-12

### Fixed
- CP unit: bound descendant_units_of_kind recursion (#6647)
- Prompt registry: merge validate+write into single mutex transaction (#6646)
- Room task schedule: reuse Room_task.update_local_agent_state on agent writes (#6642)

### Changed
- Bump OAS pin for min_p capability gate fix (#6653)
- Keeper: remove redundant UTF-8 sanitize calls on LLM input path (#6645)
- Docs: fix prompt-layer drift teaching server-root .worktrees/ (#6648)

## [0.5.6] - 2026-04-12

### Added
- Restore Groq cascade fallback, confirmed by OAS 0.121.0 (#6566)
- Bridge Agent_sdk.Log to masc-mcp structured log (#6618)

### Fixed
- CP unit: bound descendant_ids recursion with max_tree_depth guard (#6635)
- Room task: hold with_file_lock on agent state writes (#6634)
- Room/CP: hold with_file_lock around archive read-modify-write (#6632)
- Session: hold registry.lock on all hashtable reads, drop dead unregister_sync (#6628)
- Auth: gate cross-agent create_token and revoke on initial_admin (#6627)
- Channel gate: wire dedup_cleanup into orchestrator pulse (#6612)
- Keeper: fix retry timeout budget and local-only context (#6593)
- Config: prefer base-path config over repo-local env (#6626)

### Changed
- Bump OAS pin to v0.122.0 (#6631)

## [0.5.5] - 2026-04-12

### Added
- Harness: expose cross-model enforcement rate on dashboard (#6565)
- Dashboard: expose keeper FSM + root-fix hardcoded constants + TLA+ bug model (#6556)

### Fixed
- Keeper: cap Eio.Semaphore.acquire wait in with_keeper_turn_slot (#6608)
- Keeper: delete manual_reconcile file on clear to unblock legacy binaries (#6576)
- Tool worktree: reject cross-agent agent_name in masc_worktree_create (#6617)
- Tool code_write: scope writable paths and clone cwd per-agent (#6610)
- CI: narrow Keeper_tool_policy_config shortcut, revert signature tightening (#6607)
- CI: require tool_policy.toml in config_signature_exists (#6595)

### Changed
- Bump OAS pin to v0.121.0 for keep_alive=-1 fix (#6601)
- CI: wire specs/bug-models/ into tla-check.sh (#6582)

### Specifications
- TLA+ KeeperTaskInterlock: no Dead keeper holds a claimed task (#6574)

### Documentation
- Document post-turn-lifecycle implicit invariant (#6604)

## [0.5.4] - 2026-04-11

### Added
- `MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST` env knob for runtime cascade narrowing (#6478)
- `Config_dir_resolver.log_resolution` startup log with shadow hint (#6478)
- `test_cascade_config_validity` alcotest suite for cascade.json profiles (#6478)
- `scripts/sync-version-truth.sh` dry-run version sync helper (#6478)
- `scripts/opam-pin-external-deps.sh --install` flag (#6478)

### Changed
- Keeper: remove scope_kind gating (#6544)
- Cascade: drop unsupported groq labels (#6558)
- Dashboard: remove dead SSE route entries (#6557)

### Fixed
- Keeper: block write ops outside playground in keeper_bash (#6579)
- Keeper: address cross-model review follow-ups for #6543 (#6563)
- Keeper: log when open_pending overwrites a Cleared reconcile record (#6562)
- Keeper: use Eio.Lazy for decision_audit env caches (#6549)
- Keeper: tolerate text_response when provider ignores tool_choice (#6532)
- Keeper: distinguish Cancel from Timeout in LLM bridge (#6543)
- Keeper: enforce base path SSOT for playgrounds (#6548)
- Keeper: fix startup base path and cwd defaults (#6546)
- Keeper: fix channel gate ack leak (#6545)
- gRPC: guarantee cleanup on heartbeat fiber exit paths (#6524)
- gRPC: guarantee typed_stream close on subscribe fiber exit paths (#6529)
- Worktree: remove server-root fallback from worktree_create_r (#6542)
- Config: align config truth with runtime paths (#6503)
- CI: clean log noise and TLA workflow (#6505)
- Dashboard: type supervisor_diagnostics + ErrorState wave 3 (#6550)
- Test: clone into playground before masc_worktree_* (#6577)
- Docs: require keeper worktree under own playground clone (#6533)

## [0.5.3] - 2026-04-11

### Added
- Expose llm_provider_http_status via Prometheus counter (#6514)

### Changed
- Extract shared tool permission map from auth (#6501)
- Rename type result to tool_result across all tool modules (#6482)
- Bump OAS pin to v0.120.0 (#6510)
- Replace tautological assertions with observable post-conditions in keeper-registry tests (#6506)
- Prune retired front doors (#6520)
- Remove unused delete_posts_by_predicate (#6509)
- Remove 13 dead dashboard exports (#6493)

### Fixed
- Keeper: gate auto-clear of manual reconcile behind age threshold (#6497)
- Keeper: should_run_turn now consults manual_reconcile_pending (#6518)
- Keeper: SSOT playground paths, drop hardcoded masc-mcp and container root (#6468)
- Keeper: convert parse_keeper_identity from failwith to Result (#6479)
- Keeper FSM runtime integration (#6451)
- Goal-janitor: surface write_meta Error instead of ignoring (#6513)
- Board: log vote/vote_comment errors instead of silent drop (#6463)
- Backend: detect partial writes in atomic_increment and atomic_update (#6480)
- Transport: surface WS and WebRTC send failures in server bootstrap (#6517)
- Eio: wrap oas_sse_bridge + rate_limit cleanup fibers with exception loggers (#6519)
- Dashboard: restore control surface routing (#6490, #6523)
- Dashboard: standardize error display to CSS variable color scheme (#6494)
- Dashboard: standardize time display to relativeTime/TimeAgo (#6491)
- Dashboard: improve accessibility for buttons and form labels (#6496)
- Dashboard: preserve board scroll position on refresh (#6461)
- Dashboard: rename harness rail labels to match actual state (#6521)
- Dashboard: align navigation descriptions with actual UI (#6526)
- Worktree: use config base_path for worktree root (#6449)
- Playground: docker_playground_cwd double-slash escape (#6522)

### Security
- Remove tracked localhost TLS key from repository (#6487)

### Performance
- Memoize expensive derived state in fleet and agent-roster dashboard (#6492)

## [0.5.2] - 2026-04-11

### Changed
- Eliminate vendor hardcoding outside provider_adapter boundary (#6495)
- Root cause fixes for JSONL parsing, keeper_github repo, preset validation (#6457)

### Fixed
- Restore loopback cross-port relaxation in auth (#6504)
- Delegate context budget to OAS pipeline (#6488)

## [0.5.1] - 2026-04-11

### Changed
- FSM apply_event returns `Applied | Ignored` transition type — detect invalid events (#6481)
- Replace stringly-typed gate field with variant type (#6454)

### Fixed
- Restore keeper reset surface and typed tool expectations (#6477)
- Use glm-coding (Coding Plan) before glm (pay-per-use) in cascade (#6475)
- Align 4 tests with post-#6433 main state (#6460)

## [0.5.0] - 2026-04-11

### Added
- Typed_tool_masc + State_product + TLA+ orthogonal FSM verification (#6321)
- Trust Observatory dashboard — raw signals (Phase C0) (#6359)
- B-SIM Monte Carlo verification — 4 gates pass (#6352)
- Per-decision trifecta evaluation (Phase B3) (#6346)
- Guard → Thompson bridge (Phase B1) (#6307)
- TLA+ KeeperDecisionPipeline — Phase B0 gate (#6277)
- Shared gate client + Telegram/CLI connectors (#6367)
- iMessage channel connector (#6329)
- Docker playground for keeper_bash (#6338)
- Decision Pipeline FSM diagram in keeper detail dashboard (#6405)
- masc_keeper_reset command for stale runtime state (#6428)
- rate_limit.mli — hide bucket internals behind abstract type (#6431)
- coding_first cascade profile — glm-5.1 first for PR-capable keepers (#6430)
- Voice tools for sangsu (ElevenLabs Roger) (#6247)
- Keeper Failing → recovery minimum shards + .masc/ whitelist (Phase B2) (#6325)

### Changed
- Restructure keeper.world.md and keeper.capabilities.md (#6298)
- Substitute keeper_name into world/capabilities prompts (#6316)
- Expand decision log error_category: 5 → 7 categories (#6316)
- Wire OAS Tool_retry_policy + post_tool_use_failure hook (#6324)
- Per-keeper error prevention hints in TOML instructions (#6298)
- Broadcast PoC uses Tool_schema_gen combinators (#6427)
- Remove params_to_input_schema duplicate — use OAS shared utility (#6418)
- Draining invariant doc fix to match TLA+ (#6403)
- Rename team_session → execution_session (#6364)
- Remove remaining team session surfaces (#6363)
- OAS pin bumped to v0.119.1 (#6446)
- Allow localhost cross-port browser mutations for dev dashboard (#6459)

### Fixed
- Keeper turn timeout 300s → 1200s default (env var override removed) (#6371)
- Auto-recover reconcile-safe tools on server parse errors (#6370)
- Feature flag registry: MASC_KEEPER_DOCKER_PLAYGROUND (#6365)
- Voice config empty session endpoints (#6357)
- Keeper sidecar suffix check for dotted names (#6408)
- Worktree basepath config resolution (#6449)
- Keeper autonomous stall — raise turn budget, classify shell read-only (#6371)
- 50 additional bug fixes across keeper, dashboard, and infrastructure

## [0.3.0] - 2026-04-09

### Added
- Startup TOML cross-validation for tool registration (#6093)
- Keeper cascade config API + dashboard selector + TOML hot-reload (#6100)
- MASC store diagnosis cards in telemetry view (#6105)
- OAS runtime diagnosis surfaces (#6061)
- Prompt fingerprint telemetry (#6075)
- Keeper PR history tracking + active worktree listing in dashboard (#6083)
- Keeper playground state cache + dashboard panel (#6060)
- Dashboard OAS worker observability enrichment (#6071)
- Fleet telemetry panel improvements (#6104)
- Governance HITL approvals dashboard (#6098)
- Keeper TOML→JSON config SSOT resync — 20 fields (#6110)

### Changed
- **Breaking**: Renamed `keeper_shell_readonly` to `keeper_shell` across all configs, prompts, and registry (#6095)
- Centralized keeper entrypoint alias resolution (#6096)
- Simplified dashboard command surface (#6058)
- Simplified monitoring agents runtime view (#6103)
- Simplified playground status with stdlib `List.take` (#6097)
- Tool spec handler_binding required variant for type-safe dispatch (#6073)
- OAS pin bump to 120710a with Uncertain.t (#6114)
- Hardened OAS ownership boundaries (#6101)
- OAS pin SSOT and doctor checks relaxation (#6113)

### Fixed
- Discord keeper session isolation per room (#6094)
- Keeper post-commit timeout classification (#6102)
- Worker model_id hardcoded "turn-exhausted" in MaxTurnsExceeded response (#6087)
- Dashboard error prefix stripping before JSON categorization (#6057)
- Removed fake no-op Dashboard_cache.set_clock/set_sw (#6081, #6074)
- Dead OAS proof bridge panels removed from telemetry view (#6106)
- Sangsu keeper switched to local_only cascade (#6088)
- CI semantic version comparison in OAS pin check (#6111)

## [0.2.0] - 2026-04-09

### Changed
- Release SemVer restarts at `0.y.z` to reflect that `masc-mcp` is still pre-1.0.
- Release-train automation now compares tags within the active major series, so frozen legacy `v2.*` tags do not block the new `0.x` line.
- Front-door docs, release policy, and issue templates now point at `v0.2.0` as the active package version.
- The reset starts at `0.2.0` because historical `v0.1.0` and `v0.1.1` tags already exist in the repo.

### Deprecated
- New `v2.*` release tags. Historical `v2.87.0` through `v2.263.0` remain immutable legacy references.

## [2.263.0] - 2026-04-09

### Added
- OAS exit_condition plumbing — boring gate exits Agent.run early after 8+ idle turns (#5988)
- Configurable boring exit threshold via Runtime_params (#5997)
- Tool schemas for autonomy pipeline: keeper_pr_submit, keeper_preflight_check, keeper_pr_review_* (#5996)
- Keeper read-only tool classification with Tool_dispatch mirroring (#5983)
- Retry-safe tool metadata — board tools registered with Mod_inline + idempotent flags (#5973)
- Self-repo --base-path guard — rejects runtime state in source repo (#5992)

### Changed
- Adaptive OAS timeout — context-based (180s + 1.5s/1K tokens), max_turns 200→5 (#5987)
- GLM cascade simplified — removed redundant glm:glm-5-turbo, OAS glm:auto handles expansion (#5985)
- Time constants extracted to Masc_time_constants SSOT module (#5993)
- Network defaults centralized — SearXNG, OTel, allowed_origins (#5994)
- Output cap and min context constants deduplicated (#5995)

### Fixed
- Dashboard null-status crash — assoc_member wrapper tolerates null nested JSON (#5985)
- Keeper ambiguous-partial-commit reclassification for read-only tools (#5983, #5973)
- OAS cascade model timeout derived from keeper OAS budget (#5985)
- Cheolsu keeper set to ollama-only for slot queuing test (#5986)
- TLA+ spec: separated timeout from fairness, use Filename.concat (#5979)
- Version truth sync across ROADMAP, SPEC-INDEX, PRODUCT-OPERATING-PLAN (#5982)
- OAS pin updated to 0.117.0 (#5981)

## [2.262.0] - 2026-04-09

### Added
- Genuine HITL approval pipeline — Eio.Promise fiber suspension, MCP approval tools (#5907 Phase 1, #5955)
- Graduated boring-turn guard — 5-level tool_choice escalation to cut idle token waste (#5968)
- OAS pin drift doctor — local switch validation in Makefile build/test targets (#5958)
- Spawn stderr capture + cloexec pipes — child process observability and hang prevention (#5960)
- Approval audit log — persistent JSONL records for pending/resolved/expired events (#5969)
- Git clone sandboxing in keeper_shell (#5930)

### Fixed
- Ollama thinking mode disabled for keepers — unblocked all keeper timeouts (#5948)
- ToolResult.json field drift — aligned with OAS 0.116.1 (#5948)
- Hardcoded port 8085 removal — env-driven LLM endpoint discovery (#5962)
- Keeper name and MCP prefix boundary resolution (#5967)
- Dashboard null-agent patch guard (#5971)
- GLM-5-turbo cascade fallback for outage resilience (#5956)
- Read path validation with bounded suffix resolution and symlink escape prevention (#5930)
- Approval queue fiber cancellation cleanup — no orphan entries (#5955)

### Changed
- Named constants for model context thresholds (64k/200k) replacing magic numbers (#5969)
- Governance risk patterns documented in-code for mandatory review (#5969)

## [2.261.0] - 2026-04-08

### Added
- Per-keeper provider filter via `allowed_providers` config (#5831)
- Preset-aware task routing — keepers only claim tasks matching their preset (#5820)
- 11-state keeper phase diagram in dashboard (#5829)
- Excuse patterns editor UI with server-side validation (#5818)
- Output validation stats in tool-quality dashboard (#5832)
- Dashboard SSE `keeper_tool_skipped` event + centralized thresholds (#5824)
- Deterministic tool output validation (Samchon-style schema constraints) (#5821)
- Analyst persona (verification-driven) (#5850)

### Fixed
- Comprehensive Eio.Cancel.Cancelled guard sweep — 72 files, 129 patterns (#5842)
- Cancelled guard rollback for 3 cleanup sites (fd close before re-raise) (#5848)
- AllowList pruning WARN + agent JSON race condition (atomic write) (#5840)
- Defensive lowercase + warn log in filter_by_providers (#5846)
- Policy preset name validation at load time (#5787)
- Cluster-aware telemetry read path (#5828)
- Chevron discoverability (opacity-40 default) (#5837)

### Changed
- Board_listener removed — filesystem-first, PG relay redundant (#5809)
- Heuristic metadata matching replaced with deterministic Tool_dispatch sets (#5830)
- DRY `lower_string_list_opt` helper for allowed_providers parsing (#5844)
- Transport status reports canonical HTTP protocol (#5833)

### Docs
- Gate-Connector Protocol RFC: fail-closed, shorter URL TTL, replay protection (#5805)

## [2.260.0] - 2026-04-08

### Fixed
- Eio.Cancel.Cancelled re-raised instead of swallowed in bridge, dashboard, and metrics modules (#5810)
- truncate_tool_output now enforces hard cap on total output length (#5814)
- autonomous_turn_limit default set to 1 for single-slot servers (#5806)
- Yojson.Json_error catch narrowed in dashboard tool-quality (#5812)
- Branch-switch guard hardened with tab tokenization, global git options, and precise mutation detection (#5813)
- useEffect void prefix for floating promise lint (#5816)

### Changed
- Board votes now use stable post content hash instead of monotonic counter (#5817)
- K2K preset routing refined with forbidden_tools and improved score penalty (#5819)
- Deterministic read-only boundary enforcement for shell/gh tools (#5822)
 
