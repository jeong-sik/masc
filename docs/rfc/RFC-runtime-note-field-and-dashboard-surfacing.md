# RFC: Per-runtime `note` field & dashboard surfacing

> **Status**: Draft
> **Authors**: vincent (with Claude Opus 4.8)
> **Created**: 2026-06-25
> **Related RFCs**: RFC-0211-persona-runtime-decouple-opaque-id-runtime-toml-ssot (runtime.toml is the SSOT; this RFC extends its schema with one optional metadata field), RFC-0206-runtime-concept-runtime-rebirth (the `Runtime_toml` parser that must keep ignoring non-dispatch fields), RFC-0273-dashboard-driven-keeper-config-and-runtime-persistence (the dashboard write path `POST /api/v1/runtime/config/raw` and the Settings/runtime panels this RFC surfaces into)
> **Anchor commit**: `6c9029bcbf` (#22222 — current main at draft time)

## 1. Problem

The rationale for *why* a runtime is configured a certain way lives **only** as free-form TOML comments in `runtime.toml`, and those comments are surfaced in **no structured view**.

Grounded against the live config (`<base-path>/.masc/config/runtime.toml`, 2026-06-25):

- The global default is `ollama_cloud.minimax-m3`. The reason is a 11-line comment block above `[runtime].default`: RunPod 404 outage on 2026-06-19 forced all keepers to Ollama Cloud, then `deepseek-v4-flash` could not emit structured JSON so the anti-rationalization evaluator returned empty 10/20 times and auto-approved by liveness (#8688), so the default was swapped to the JSON-capable `minimax-m3`.
- That reasoning is **invisible** anywhere except by reading the raw TOML. A operator looking at the dashboard sees the *effect* (minimax is default) but not the *why*.

Observed symptom (this session): the operator asked "왜 default가 minimax가 됐지?" — the answer existed, but only buried in a comment. Then: "설정에서 잘 안보임" (it is not visible in Settings).

> **Premise correction (2026-06-25, post-verification).** An earlier draft of this RFC claimed a third cause — "comments are lost on dashboard save because the write path re-serializes the TOML." **That claim was falsified by direct verification (§6).** The entire read→edit→write pipeline is comment-preserving (raw textarea editor + line-surgical field edits + verbatim backend write + text-transform assignment edits). So this RFC is **not** a data-loss fix. Its justification is narrower and softer: rationale is preserved but surfaced in **no structured view**. Weigh the (smaller) benefit against the schema+UI cost accordingly.

Two structural causes, grounded:

| Cause | Evidence |
|---|---|
| No typed rationale field exists | `dashboard/src/lib/runtime-toml-config.ts` parses `RuntimeTomlProvider`/`Model`/`Binding`; `rg note` → 0 hits. The only optional string is `displayName` (`runtime-toml-config.ts:194`). |
| Dashboard runtime detail surfaces no rationale | `dashboard/src/components/runtime-panel.ts:20,160-167`: the `런타임` tab = "OAS health chip + runtime monitor only" (operational); the `runtime.toml` tab = a **raw textarea** (`runtime-toml-editor.ts:511-526`). The rationale exists only as raw-text comments visible in that textarea — there is no structured per-runtime rationale surface in the `런타임`/`전체` views, so an operator scanning the structured runtime list cannot see "why this default" without dropping into raw text. |

## 2. Boundary & invariants

### 2.1 `note` is a non-dispatch field — the load-bearing invariant

`runtime.toml` has **two independent consumers**:

| Consumer | Reads | Source |
|---|---|---|
| OCaml `Runtime_toml` | **only** Layer 1-3 (`[providers.*]`, `[models.*]`, `[<p>.<m>]` bindings) + `[runtime].default` | `lib/runtime/runtime_toml.mli` (docstring: routing layers 4/5 and strategy tables are "intentionally NOT parsed"; dropped) |
| Dashboard `runtime-toml-config.ts` | the structured editor model incl. `display-name`, `keeper-assignable`, etc. | RFC-0273 surfaces |

`note` is **purely a dashboard/operator field**. It MUST NOT influence inference dispatch. **Verified (§6 V1):** the OCaml `Runtime_toml` parser reads only specific known keys via `Otoml.find_opt tbl getter [key]` / `find_or ~default` (`runtime_toml.ml:107-108,164,182,244-258`); it does **not** enumerate keys or reject unknowns. The only `unknown_*` errors are for an *invalid value* of a known key (`protocol`, credential `type`) — never for an unexpected key. So an extra `note` key is simply never read → dispatch-invisible by construction, the same already-tolerated class as `display-name` / `[providers.*.healthcheck]` / `[voice.*]`. The invariant is additionally locked by test (§5).

### 2.2 Precedent: this is metadata, not a new concept

Spec §7.3.1 (`masc-mcp/docs/spec/14-configuration.md`) already defines `keeper-assignable` — a typed `bool` metadata field on `tier`/`runtime` consumed by the dashboard/runtime manager, ignored by the dispatch parser. `note` follows the identical pattern: typed, optional, dashboard-consumed, dispatch-ignored. We are extending an established metadata lane, not inventing one.

### 2.3 OAS boundary

Untouched. OAS owns provider/model/transport/turn-lifecycle. `note` never crosses into OAS — it is not in `Runtime_schema.config`.

### 2.4 No second SSOT

`note` lives **inside** `runtime.toml` (the existing SSOT, RFC-0211). This RFC explicitly rejects a sidecar note store (separate JSON/DB keyed by runtime id) because that creates a second source of truth that drifts from the config it annotates. See §4 Rejected alternatives.

## 3. Design

### 3.1 Schema (extends RFC-0211)

Add an **optional** `note` key (TOML string; may be a multi-line triple-quoted string to hold a dated changelog) to:

- `[providers.<id>]` — why this provider/endpoint exists, auth quirks, outage history.
- `[models.<id>]` — model provenance, quant, verified capabilities.
- `[<provider>.<model>]` binding tables — why this binding's concurrency/params are set as they are.
- `[runtime]` — `default-note` (string): **why the current `default` was chosen.** This is the field that directly answers "왜 default가 minimax가 됐지?".

```toml
[runtime]
default = "ollama_cloud.minimax-m3"
default-note = """
2026-06-19: RunPod 404 outage forced all keepers to Ollama Cloud. flash could not
emit structured JSON (anti-rationalization evaluator empty 10/20, auto-approved by
liveness #8688) → swapped to JSON-capable minimax-m3. Revert when RunPod returns.
"""

[providers.runpod_fable5]
note = "Added 2026-06-25. RunPod pod l427t1tmzge86g:19123, llama.cpp. Probe-verified tools+thinking."
```

Multi-line strings preserve the existing dated-changelog comment style **as a typed value**, so no separate `note : string list` array is needed for v1 (kept as a documented future option, §7).

### 3.2 OCaml `Runtime_toml` — explicit ignore + test

No behavioral change. `note`/`default-note` are not added to `Runtime_schema.config`. A regression test asserts:

- a config carrying `note` on every table kind + `default-note` parses `Ok`, and
- the resulting `Runtime_schema.config` is byte-identical to the same config with the `note` keys removed (i.e. `note` is provably dispatch-invisible).

### 3.3 Dashboard `runtime-toml-config.ts` — parse + round-trip preserve

- Add `note?: string` to `RuntimeTomlProvider`, `RuntimeTomlModel`, `RuntimeTomlBinding`; add `defaultNote?: string` to the document/runtime model.
- Parse it exactly like `displayName` (`runtime-toml-config.ts:194` pattern: `asString(values['note'], undefined)`).
- **Serialize it back** on write so a dashboard-driven save (RFC-0273 `/api/v1/runtime/config/raw`) does not drop it.

### 3.4 Dashboard surfacing — the "설정에서 잘 안보임" fix

- **Default rationale callout** (highest priority): in `runtime-panel.ts` `전체`/`런타임` view, render `[runtime].default` with its `default-note` as a prominent banner at the top. This is the single most-asked question ("why this default") and must be answerable at a glance.
- **Per-runtime note**: in the `런타임` (providers) view, render each provider/model/binding's `note` inline (e.g. an `ⓘ` affordance expanding to the note). Inert/unassigned runtimes (like a freshly-added `runpod_fable5`) are listed too, so an added-but-not-routed runtime is discoverable — addressing the "added it but can't see it" half of the complaint.
- **Editor**: in `runtime-toml-editor.ts`, `note` is a labeled field, not a comment, so it round-trips and is editable structurally.

### 3.5 Write path

Reuse RFC-0273's existing `POST /api/v1/runtime/config/raw` (`Runtime.save_config_text` + reload) under the same operator-auth gate. **No new endpoint.**

## 4. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Parse TOML comments → notes | String/positional heuristic over comments is fragile and is exactly the "string classifier" anti-pattern (CLAUDE.md workaround bar §2). Comments also aren't addressable per-table. |
| Sidecar note store (JSON/DB by runtime id) | Second SSOT; drifts from the config it annotates (§2.4). |
| `note : string list` (dated array) | More schema for v1 with no proven need; multi-line string already captures dated history. Deferred to §7. |

## 5. Test plan

- **OCaml** `test/test_runtime_toml*.ml`: §3.2 dispatch-invisibility test (parse Ok + config identical with/without `note`); round-trip via `save_config_text` preserves `note`/`default-note`.
- **Dashboard** `runtime-toml-config.test.ts`: parse `note` from each table kind + `default-note`; serialize preserves them.
- **Dashboard component** `runtime-panel`/`runtime-toml-editor` test: default-note banner renders; per-runtime note renders; inert runtime appears in list.

## 6. Verification (closed) & open questions

Direct grounding against `main` (worktree `6c9029bcbf`, 2026-06-25):

- **V1 — parser tolerates `note` (CONFIRMED).** `runtime_toml.ml` picks known keys with `Otoml.find_opt`/`find_or`; no unknown-key rejection path. Extra `note` is never read. See §2.1.
- **O1 — comment survival (CLOSED, was the falsified premise).** The full pipeline preserves comments; there is **no** re-serialization that drops them:
  - Backend write `Runtime.save_config_text` (`runtime.ml:673-678`) = `validate` then `Fs_compat.save_file_atomic path content` — **verbatim raw write**.
  - Keeper-assignment write `set_runtime_id_for_keeper` → `update_runtime_assignment_text` (`runtime.ml:619-627`) = `split_lines`-based **text transform**, not AST re-serialize.
  - Dashboard editor `runtime-toml-editor.ts:511-526` = **raw `<textarea>`** on the source text; structured field edits `setRuntimeTomlKey` (`runtime-toml-config.ts:319-333`) replace only the matched line's value. Comments untouched.
  - **Consequence:** the "typed field survives serialization" argument is *moot* (comments already survive). The only real gap is **structured surfacing** — see §1 premise correction.
- **O2 (open)**: Should `default-note` live on `[runtime]` or be auto-derived from the `note` of whichever binding is currently `default`? Proposed: separate `default-note` ("why this is the default" ≠ "what this runtime is"), but see §8 staleness risk.

## 7. Non-goals / future

- No change to dispatch/routing semantics, no new endpoint, no comment migration mandate (comments stay valid for non-surfaced detail).
- Future: `note : string list` dated-entry array with per-entry author/timestamp, if a structured changelog is wanted over a multi-line string.

## 8. Workaround self-check (CLAUDE.md bar)

- Telemetry-as-fix? No — adds a typed field + UI, not a counter over an unfixed failure.
- String/substring classifier? No — `note` is a typed `string` value; this RFC *rejects* comment-string-parsing (§4).
- N-of-M? No.
- Cap/cooldown/dedup/repair? No.
- Second SSOT? Explicitly avoided (§2.4).
- **Staleness honesty (acknowledged risk).** `note`/`default-note` is free-form prose, so it *can* go stale when the value it explains changes (e.g. default flips but the note still describes the old reason). This is inherent to any human rationale and is **not** the "two concepts in one typed value" anti-pattern (note is explicitly metadata, not an overloaded typed field). Nothing enforces freshness. Mitigation, not enforcement: the dashboard renders `default-note` **directly next to the live `default` value**, so a stale note is visible to the operator at the point of reading. No write-time validation is proposed (validating prose against intent is not mechanizable).
