# Domain D audit: Candle economy and satellites (2026-10-07, HEAD 7fb34c7172)

Scope: lib/candle, candle_runtime, candle_config, candle_store, keeper_portrait, lib/play, server_candle_appraiser, keeper_candle_tools, bin/masc_candle_grant. Read-only; live files read, nothing written under ~/me/.masc.

## 0. Live evidence (read 2026-10-07 ~04:40 KST)

- `config/candle.toml` (897 B, mtime 10-06 18:06): `half_life="off"`, `weight_max=1`, `deduction_rate=0`, `largest_remainder`, grades_milli trivial 100 / small 700 / medium=large=epic 1000, 18 shop prices.
- `candle-ledger.jsonl` 31 rows: granted 28 ("welcome gift", 10 milli each, 14:29:45Z), half_life_set 1 (07:52:37Z), purchased 1 (indie-geek-blue glasses, 0 milli, 07:57:26Z), equipped 1 (07:57:33Z). **Zero** snapshot / payout_owed / candidates / unattributed / paid / payout_failed rows.
- `goal_events.jsonl` after enable (07:53Z): one goal_created (15:29Z), one dropped (16:43Z). No Goal passed verification or got confirmed, so Snapshot -> PayoutOwed -> Candidates -> appraisal -> Paid never ran live. The appraiser lane has one slot: `runtime.toml:2331-2334` `claude_code_a8c76d7a.claude-opus-5-5` (cli_slots only).
- `system_log_2026-10-06`: `candle: off` until 07:22Z, `candle: enabled` 07:53:19Z, then 35 x 2 warnings `preparation/payout pass could not read ledger: ... row 4 does not read: candle event granted: unknown kind "granted"` every 60 s from 14:30:40Z to 15:04:41Z; restart at 15:05:52Z cleared it (see F1).
- Keeper tool calls: keeper_candle_balance 16 (10-06) + 6 (10-07 00:05-01:37), catalog 2, purchase 1, equip 1, all `outcome=ok`. 20 of 19,952 tool calls on 10-06.

Hops that ran live since 10-06 16:23: config on/off, half_life_set, purchase, equip, operator grant, balance reads, portrait with ledger equipment. Hops that never ran: Snapshot, PayoutOwed, Candidates, grade/relation/weights appraisal, payout split, Paid.

## 1. Change flow by day

- 09-30 (14 commits): payout chain lands: candle.toml on/off #39928, Snapshot before verifier commit #39978, PayoutOwed on confirm #39979, Candidates #39981, nonnegative arithmetic #39985, canonical foundation #40004. Play: invite link seats agents #40035, refusal shape `{error: sentence, code}` #40050, credential renewal #39986. Portrait: item preview PNGs #39987, TUI compact portraits #39886.
- 10-01 (9): Item stack root: purchase #40365, equip across server/dashboard/TUI #40010, wallet + supply view #40024; stored Paid receipts survive arithmetic changes #40066; exact payout + durable decay policy (half-life) #40392; stop replaying refused appraisals #40566; splash docs removed #40520. Play authority #40395, #40577.
- 10-02 (8): closed variants #40595, permanent-failure classification #40581, recovery after appraiser lane change #40670, payout recording/receipt replay #40302, debt kept when disabled #40303, lane backpressure #40742.
- 10-03 (1): TUI compact face icons #40814.
- 10-04 (3): typed refusals -> execution rejections #41008, configurable grading/distribution policy #40848, play controller read errors #40896.
- 10-05: none in domain.
- 10-06 (5 + live): test-only fns removed #41325 (+ tests #41326), judgment lanes get freed permits #41332, operator grants #41371 (merged 23:27:30 KST). Live: candle.toml created, enabled 16:53 KST, first purchase/equip 16:57, grants 23:29, 35-min ledger outage until 00:05 restart.
- 10-07: no domain commits before HEAD (01:29).

## 2. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Candle on/off | ran live (enabled 07:53Z) | missing file = Off; bad TOML = Disabled; first recovery failure = Disabled (#41322) | one start line; dashboard summary | Partial | candle_config.ml:155-185, candle_status.ml:131-140 |
| Snapshot / PayoutOwed | not exercised | ledger read failure refuses the proof commit and the confirmation (blocks Goal) | warn when Disabled | Unknown (code reads correct) | candle_snapshot.ml:51-68, workspace_goals.ml:551 |
| Candidates | not exercised | dup task ids removed at link reader (workspace_goal_index.ml:40) | info lines | Unknown | candle_candidates.ml:118-191 |
| Appraisal grade/relation/weights | not exercised; 1 Opus CLI slot | full restart from grade on every transient failure (#41323); single-keeper weights call (F6) | exact-lane run receipts | Partial | candle_appraise.ml:38-77 |
| Payout split | conserving under largest_remainder; dup names refused; zero weight gets 0 | 0 related -> Unattributed; 1 -> F6; `down` leaves `unallocated_milli` (recorded) | Paid row | OK (code) | candle_math.ml:100-138, candle_payment.ml:12-73 |
| Ledger store | 31 rows, CAS append | one unreadable row stops every reader (F1, #41321) | warn per pulse | Partial | candle_ledger.ml:144-156, 249-266 |
| Balance projection | 22 tool reads ok | read takes writer lock (F5); appraiser-gated (F4) | dashboard supply/balances | Partial | candle_shop.ml:57-64 |
| Operator grant | 28 rows live | same reason twice refused; CLI writes file directly (F1) | CLI receipt | Partial | candle_grant.ml:41-84 |
| Half-life | pure projection, no tick; live off | idempotent across restarts; new policy recorded at first write after edit (F5) | half_life_set row | OK | candle_decay.ml:79-95, candle_balance.ml:119-145, 238-261 |
| Purchase / catalog | 1 live (0 milli) | insufficient / already owned / unpriced refused | typed tool error codes | OK | candle_balance.ml:169-192, keeper_candle_tools.ml:99-133 |
| Equip | 1 live | slot+item mismatch checked at runtime (F7) | `changed` flag | Partial | candle_balance.ml:227-237 |
| Portrait | draws ledger equipment | readers disagree when Off/Disabled (F4); D9-01/02/05 open | etag | Partial | candle_observe.ml:23-26, candle_equipment.ml:8-16 |
| Play invite | CanAdmin, Player role, bounded expiry | link is 127.0.0.1 (F3); TUI drops `missing`/`taken_by` (F2) | refusal JSON | Partial | play_invite.ml:60-106, server_routes_http_routes_play.ml:54-80 |

Config note (not a code defect): with medium = large = epic = 1000 milli the Opus grade call above `medium` has no monetary effect.

## 3. Baseline (2026-10-01) status

| Id | Status | Evidence at HEAD |
|---|---|---|
| D8-05 | Still open, tracked #41322 | `for_recording` no longer checks the lane (candle_status.ml:134-136); first recovery failure still Disabled -> no Snapshot |
| D8-06 | Partial | 12 cases x 20 trials incl. title/metric/task injection exist for glm-5.3-flash (docs/evidence/2026-09-30-candle-grade-explicit-outcome/README.md:24-61); the live slot is claude-opus-5-5 via CLI and was not measured; README says human calibration still required |
| D8-07 | Still open, tracked #41323 | candle_appraise.ml:38-77 recomputes grade each attempt |
| D8-08 | Fixed for arithmetic | decode uses `validate_receipt` (candle_payment.ml:38-73,131); recompute only on append (candle_ledger.ml:236). Settlement-rule re-check on read remains: tracked #41321. Purchase replay also re-checks balance sufficiency (candle_balance.ml:169-185), same class |
| D8-09 | Fixed | Candle_decay + projection (#40392); constitution.xml:215 says balances decay; live config says off |
| D8-10 | Fixed | #40365, #40010, #40024; live purchase+equip |
| D8-11 | Partial | supply + per-keeper balance in dashboard (dashboard_http_keeper.ml:917-939); no pending-payout or last-rejection view |
| D8-12 | Fixed | 29 live goals, none with an unreadable-looking due_date (regex check, Medium) |
| D9-01 | Still open | body_of_name at bin/masc_tui_keeper_portrait.ml:64, keeper_portrait_read.ml:58, server_dashboard_http_keeper_portrait.ml:119 |
| D9-02 | Still open | keeper_portrait_look.ml:100-103 `pick` by List.length; :249-253 |
| D9-03 | Mitigated | #40188: compact drawing falls back to full drawing when non-dish slots are worn (bin/masc_tui_keeper_portrait.ml:66-70) |
| D9-04 | Fixed | #40520; no splash text in glossary or portrait lib |
| D9-05 | Still open | dashboard/src/components/keeper-config-v2-blocks.ts:6-27 sigil + "기획 단계" |
| D9-06 | Partial | named constants pinned by test against the toml (keeper_portrait_read.ml:1-7); two sources remain |
| D10-01 | Still open | see F3 |
| D10-04 | Still open | see F2 |
| W3-01 (Candle) | Still open | no candle entry in scripts/check-runtime-deployment-preflight.sh or bin/deployment_preflight_helper.ml |
| D16b-09 | Still open | see F9 |

## 4. New findings

### F1 (P2) Two binaries write one ledger; a newer writer's row stopped the older server's whole economy for 35 min
- Where: `bin/masc_candle_grant.ml:1-8` appends `Granted` straight into `<base>/.masc/candle-ledger.jsonl` via `Candle_grant.grant` (`lib/candle_runtime/candle_grant.ml:41-84`). Readers are strict: `candle_event.ml:414` dispatches by kind; `candle_ledger.ml:144-156` fails the whole read on one bad row.
- Introduced by #41371 (10-06). Merged 14:27:30Z, grants written 14:29:45Z by the new CLI, server still on the old binary until 15:05:52Z.
- Blast radius (code read end to end): payout pass and Candidates (`candle_payout_worker.ml:64-72`), balance/purchase/equip (`Candle_ledger.update`), and also Snapshot and PayoutOwed (`candle_snapshot.ml:41-49`, `candle_payout_owed.ml:19-36`), which run inside the verifier proof commit (`workspace_goals.ml:551-552`). A Goal pass or confirmation in that window would have been refused.
- Tick: every pulse re-reads, fails, logs 2 warns, defers. Open until a binary that knows the kind is deployed; only a deploy converges it.
- Fix: make the server the only writer. Add `POST /api/v1/candle/grants` (CanAdmin) that calls `Candle_grant.grant`; the CLI posts to it. A row the running server cannot read can then never be written.
- Confidence High (log + code). Tracked: no (#41321 is settlement re-validation, a different cause).

### F2 (P3, = D10-04) TUI play refusal decoder reads `message`; the server sends `error` + `code` + fields
- `lib/tui_decode.ml:7435-7470` reads `message`; `lib/server/server_refusal.ml:1-7` emits `{error: sentence, code, ...}`; comments at `bin/masc_tui_http.ml:612-615` and `tui_decode.ml:7435-7441` describe the old shape. Always `None`; the fallback shows the sentence and drops `missing` / `taken_by`.
- Fix: read `error` as the sentence, plus `missing` / `taken_by`, in one decoder; delete the old-shape comments. Confidence High. Tracked: no.

### F3 (P1, = D10-01) Invite readiness `No_public_base_url` can never fire
- `lib/server/server_bootstrap_http.ml:19-24` fills `MASC_HTTP_BASE_URL` with `http://<host>:<port>` when unset; issue route and agent guide read the same env (`server_routes_http_routes_play.ml:54`, `..._play_guide.ml:29`). With no operator value the link is `http://127.0.0.1:8935/play#<token>`. Fix as in baseline: keep the operator's explicit value in a separate boot-time option and read only that. Tracked: #39891 covers scheme-less values only.

### F4 (P3) Money and equipment readers use three different gates
- Purchase/catalog/balance/equip use `Candle_status.configured` (lane-gated, `candle_shop.ml:41-46,57-64`, `candle_equipment.ml:28-31`); grant uses `for_recording` ("a gift needs no appraisal", `candle_grant.ml:30-40`); dashboard/TUI equipment uses `Candle_observe` (lane-gated, Off -> name default, `candle_observe.ml:23-26`); PNG route and MCP `keeper_portrait_read` use `read_persisted` (ungated, `candle_equipment.ml:8-16`; `server_dashboard_http_keeper_portrait.ml:217`; `keeper_portrait_read.ml:61`).
- Scenario: the single appraiser slot loses admission (`Exact_lane_off` / `No_admitted_lane_slots`, `runtime_exact_output_registry.mli:108-111`) -> every keeper's balance, catalog, purchase and equip answer `candle_disabled`, none of which needs an appraisal. With Candle Off, the TUI draws name-default accessories while the PNG route and MCP tool draw purchased ones.
- Fix: `Candle_status.money_policy = for_recording` for every non-appraisal reader/writer; keep `configured` only in `Candle_payout_worker.pass` and `Candle_appraise.settle`; one `Candle_equipment.current` used by all four portrait readers. Confidence Med (not observed live; lane stayed up). Tracked: no.

### F5 (P3) `keeper_candle_balance` takes the writer lock and may append
- `Candle_shop.account` -> `Candle_status.current_view` -> `Candle_ledger.update` (`candle_status.ml:117-129`); dashboard uses read-only `observed_view` (`:107-115`) for the same account.
- Effect: a read fails as `ledger_unavailable` while another process holds the lock (`candle_ledger.ml:262`); after an operator edits `half_life`, the first balance read writes `Half_life_set`, so decay starts at the first keeper touch, not at the edit.
- Fix: `account` uses `observed_view`; policy rows only on money-moving writes. Confidence Med.

### F6 (P3) Weights stage calls the model when the answer is fixed
- `candle_appraise.ml:63-70` calls `A.Weights` for any non-empty `related`. With one keeper, `validate_weights` (`candle_appraisal.ml:44-50`) accepts only 1..weight_max and `split` pays the total regardless; live `weight_max = 1`. A model answer of 0 becomes `Invalid_response` -> `Rejected` -> waits for an event.
- Fix: `match keepers with [k] -> deterministic [(k, weight_max)]` with a trace variant that names the rule (not a fake run id). Confidence High.

### F7 (P3) Equipped carries a slot the item already fixes
- `candle_event.ml:28,70` (`slot` + `Default | Item`); `candle_balance.ml:229-233` checks `Wrong_equipment_slot` at runtime; `keeper_portrait_item.ml:3-10` already encodes the slot in the constructor; the tool uses the string sentinel `"default"` (`keeper_candle_tools.ml:56-64`).
- Fix: `type equipment_choice = Unequip of slot | Wear of Keeper_portrait_item.t`; hard-cut the one live row. Confidence High.

### F8 (P3, SSOT) Duplicated wire shape and duplicated provider retry tables
- Catalog entry JSON twice: `keeper_candle_tools.ml:25-35` and `server_dashboard_http_keeper_items.ml:18-28`.
- `server_candle_appraiser.ml:197-295` classifies every Codex/Claude/Antigravity/Muse error (about 100 lines); `keeper_lane_cli_oneshot.ml:31-45` classifies the same constructors for another purpose. Fix: one closed `failure_disposition` beside `Fusion_official_client`. Confidence Med.

### F9 (P3, = D16b-09) `masc_candle_store` links all of `masc_workspace` (83 files, 12.2k lines) for one path
- `lib/candle_store/dune` + `candle_ledger.ml:5-8` (`masc_dir_from_base_path`). Fix: pass the path in or move the helper to `masc_config_dir_resolver`.

Dead export (P3): `Candle_candidates.real_sources` has no caller outside its file and no test. Test-only exports: `Candle_balance.empty`, `Candle_config.of_toml_string/load_file/to_string`, `Candle_observation.amount_of_json`, `Candle_payment.to_yojson`, `Candle_event.of_yojson`.

Checked and closed (no finding): split conserves under largest_remainder and records `unallocated_milli` under `down`; duplicate task ids are removed at the link reader; Candidates cannot hold a Deleted task, so the relation-stage `Transport_unavailable` branch is unreachable; the half-life projection has no tick, so restarts cannot double-apply; every money write runs `prepare`, so a backwards row cannot be written; payout worker owners are pruned every pass; `Deferred Event` re-arms once per recovery.

## 5. Context and token cost

- 4 candle tools are `defer_loading = false` (`~/me/.masc/config/tools/keeper_candle_*.toml`, 1,582 B of TOML, roughly 400 tokens before schema wrapping) on every keeper request. They got 20 of 19,952 calls on 10-06 (0.10 %). Setting catalog/purchase/equip to deferred keeps balance visible and drops about 1.3 KB per request (cache-hit share not measured).
- Each appraisal receipt stores `effective_template` and the `rendered` prompt that contains it (`server_candle_appraiser.ml:345-350`). 0 bytes so far (no live appraisal).
- Every pulse loads candle.toml 2-3 times and parses the full ledger twice (`candle_payout_worker.ml:56-73`). Negligible at 31 rows.

## 6. Coupling

- candle_runtime -> Goal_store / Goal_verification / Goal_due / workspace task lookups: needed (payout derives from Goals). Goal reaches Candle only through injected hooks (`goal_verification_agent.ml:301`, `server_routes_http_routes_verification.ml:191`). Right direction, but the hooks return `Error`, so any Candle ledger fault blocks Goal completion (F1 shows it happening); operator decision DM-GT-02 still applies.
- Candle availability depends on the exact-output lane registry through an installed check (`server_runtime_bootstrap.ml:1474`). Fine for appraisal; too wide for money reads (F4).
- `prompt_preset.ml:648` and `server_prompt_override_mutation.ml:21` call `Candle_payout_worker.wake` directly. Separable: a prompt-change subscription would remove the prompt -> candle edge.
- Ledger schema imports `Keeper_portrait_item.t` (`candle_event.ml:26,67-70`; strict decode `:359-361`). Removing a portrait item makes old `purchased` rows unreadable, which stops the whole ledger. Item ids need to stay append-only, or the ledger needs its own item id type.
- Library split pure (`masc_candle`) <- store/config <- runtime <- server follows dependency direction; no cycles. The only unjustified edge is store -> masc_workspace (F9).
