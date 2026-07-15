---
rfc: "0306"
title: "Typed, comment-preserving fusion settings editor"
status: Draft
created: 2026-07-04
updated: 2026-07-04
author: vincent
supersedes: []
superseded_by: null
related: ["0283", "0298", "0300"]
implementation_prs:
  - "fix/fusion-settings-layout" # Phase 0 — layout regression fix (set-line CSS + set-card-b-wide)
---

# RFC-0306 — Typed, comment-preserving fusion settings editor

## 1. Problem

The dashboard fusion settings surface (`#settings?section=fusion`) exposes four
editable scalars while the fusion backend schema and the judge-of-judges (JoJ,
RFC-0283) engine behind it are fully implemented. The operator cannot edit the
panel roster, the meta judge, the JoJ first-round judges, or any timeout from the
UI; they render read-only. The complaint "fusion 자유도 zero / JoJ 설정 불가" is
accurate.

### 1.1 What is editable today vs what the backend supports

Editable in the panel (frontend line-surgical scalar writer,
`dashboard/src/lib/fusion-settings.ts:262-277`):

- `[fusion].enabled`, `[fusion].default_preset`

Read-only display only (`dashboard/src/lib/fusion-preset-view.ts`, header comment
"display-only reader — it never writes back"):

- `panel = [...]` roster, `judge` (meta), `[[fusion.presets.<name>.judges]]` (JoJ
  first-round judges), `panel_timeout_s`, `judge_timeout_s`,
  `staged_judge_group_size`.

Backend schema (`lib/fusion_core/fusion_config.ml`, `lib/fusion_core/fusion_policy.ml`)
and orchestrator (`lib/fusion/fusion_orchestrator.ml:145` `run_judge_of_judges`)
support the remaining fields above. The gap is UI/write-path, not engine.

### 1.2 Root cause

The frontend edits `runtime.toml` by line-surgical string replacement of scalar
keys. That method cannot express multi-line arrays (`panel`) or array-of-tables
(`[[...judges]]`), so those fields were left read-only rather than given a wrong
writer. The reason the frontend does line surgery at all is comment preservation:
`config/runtime.toml`'s `[fusion]` block carries 38 comment lines that document
per-field intent (concurrency knob separation, capability requirements, prompt
sourcing). Those comments are load-bearing operator documentation.

Otoml cannot round-trip them: its lexer discards comments
(`toml_lexer.ml:read_comment` emits no token) and its AST has no comment node
(`impl_sigs.ml` `type t`), so `Otoml.Printer.to_string` reconstructs a
comment-free file. **Comment preservation is therefore a hard constraint, and any
approach that regenerates the file from a parsed AST is disqualified.**

### 1.3 Layout regression (Phase 0, already fixed on `fix/fusion-settings-layout`)

`fusion-settings-panel.ts` renders rows with classes `set-fusion-editor` /
`set-line` that were never defined in CSS (introduced by #23056), so labels and
controls rendered inline. Additionally `settings-surface.ts:1038` omits `fusion`
from the `set-card-b-wide` list, capping the section at 760px. Both are corrected
in Phase 0. This RFC covers the remaining editability work.

## 2. Principles and constraints

1. **Comment preservation is mandatory.** Writes edit the original text at line
   granularity; unmatched lines (comments, blanks, other keys, other tables) pass
   through byte-for-byte. Evidence that this is required, not preferred: §1.2.
2. **Typed validation is the correctness SSOT.** The write mechanism is text-level,
   but every write is re-parsed and validated through `Fusion_config.of_toml` +
   `Fusion_policy.Validated_preset.of_preset` and rejected on any violation. String
   editing is a rendering detail; correctness is enforced by types. This keeps the
   design clear of the "string classifier" anti-pattern (CLAUDE.md workaround bar).
3. **Reuse the existing comment-preserving editor.** `lib/runtime/runtime.ml`
   already implements a line-based TOML editor for the routing/assignment patch
   endpoints (`update_runtime_scalar_text`, `update_runtime_string_array_text`,
   `update_runtime_assignment_text`, `split_lines`/`join_lines`,
   `assignment_key_of_line`). It preserves comments and is the precedent. It is
   runtime.toml-specific and internal (not in `.mli`), and it handles only scalars
   and single-line arrays. Fusion needs multi-line arrays and array-of-tables.
4. **No hardcoded model lists.** Panel/judge pickers draw from the runtime catalog
   (`GET /api/v1/providers` → `fetchRuntimeProviders` → `runtimeSelectOptionsFromCatalog`),
   the same source the default-runtime select already uses. `runtime_id` is
   `provider.model`.
5. **MASC → OAS stays one-way.** Model resolution uses the existing MASC→OAS
   catalog path (`oas-models.toml` seed projection; `Runtime_oas_runner`,
   `Fusion_oas`). No new coupling; OAS remains unaware of fusion.
6. **No silent failure.** Every write step returns `result`; failures produce a
   JSON error body plus an audit `Failure` record, mirroring
   `save_config_text` (`server_routes_http_routes_dashboard.ml:562`).
7. **No LLM boundary here.** Fusion config editing is fully deterministic. Per the
   product boundary rule, no judgment step is introduced; this surface is
   declarative config only.

## 3. Scope

### 3.1 Typed read endpoint

Add `GET /api/v1/runtime/config/fusion` returning a typed JSON projection of the
active `Fusion_policy.t` (presets, panel rosters, meta judge, JoJ judges,
timeouts, concurrency knobs). No serializer exists today
(`Fusion_policy.t`/`preset`/`judge_spec` derive only `show`/`eq`;
`fusion-runs` serializes run history with preset-as-name only). A new
`fusion_config_json.ml` serializer is required. The raw endpoint remains for
fallback.

### 3.2 Comment-preserving TOML editor generalization

Extract the internal line editor from `runtime.ml` into a reusable module
(working name `Toml_line_editor`) with a comment-preserving contract, and have
`runtime.ml` delegate to it so routing/assignment behavior is unchanged (guarded
by their existing tests). Add two new primitives fusion needs:

- **Multi-line inline array replace**: locate `key = [` inside a target table,
  consume to the matching `]`, replace element lines from a typed list; keep the
  `key = [` / `]` framing and any leading/trailing comments.
- **Array-of-tables region edit**: for `[[<table>.judges]]`, address the
  contiguous run of blocks as a region and regenerate it from the typed judge
  list (add/remove/reorder). See open question §7.1 on per-block comment fate.

Table addressing generalizes from the hardcoded `[runtime]`/`[runtime.assignments]`
headers to an arbitrary dotted table path (`[fusion.presets.<name>]`).

### 3.3 Typed write endpoint

Add `POST /api/v1/runtime/config/fusion` (`CanAdmin`), body = typed fusion patch.
Flow, all `result`, short-circuit on first error:

1. Parse typed body → build `preset` / `Fusion_policy` model.
2. Validate: `Validated_preset.of_preset` + JoJ `judges >= 2` (§3.4) + staged
   check (`staged_judge_groups`) when the strategy is staged. On failure return a
   structured JSON error (§3.4).
3. Apply via the §3.2 editor to the loaded `runtime.toml` text (comments preserved).
4. Re-validate the whole file (`Runtime_toml.parse_string` + `materialize_config`),
   as `save_config_text` does.
5. `Fs_compat.save_file_atomic` then `init_default` reload.
6. Audit `Success`/`Failure` via `audit_runtime_config_write`.

### 3.4 Validation surface

- Serialize the closed error variants (`Fusion_config.config_error`,
  `Fusion_policy.invalid`, `staged_judge_group_error`) to JSON with their payloads,
  so the UI can render field-level errors. Today the only consumer flattens them
  with `show` + string concat (`fusion_config_loader.ml:22-31`); the editor path
  must not go through that collapse.
- **Lift the JoJ `judges >= 2` invariant into `of_preset`.** Currently
  `judges = []` passes config load and only fails at runtime as
  `Internal_error` inside `run_judge_of_judges`. Moving it to config validation
  removes a silent-until-runtime failure and lets the editor reject at save time.
  The check applies when the preset's strategy is JoJ/staged; a preset that never
  dispatches JoJ is unaffected.

### 3.5 Frontend structured form

Replace the read-only preset view with an editing form matching the approved
layout: enabled checkbox; default_preset select (from preset names); panel roster
multi-select (add/remove from catalog); meta judge select; JoJ first-round judges
list (add/remove; each: model select + system-prompt textarea + timeout);
timeouts and `max_tool_calls_per_panel`; concurrency knobs. Populated from §3.1,
submitted to §3.3, errors rendered from §3.4. Model options come from the shared
runtime catalog resource (Principle 4).

### 3.6 Structured-output capability exposure (advisory)

Add `supports_structured_output` to the provider entry JSON
(`runtime_inventory_entry_json`, one field from `caps.supports_structured_output`)
and the frontend snapshot type. Use it to annotate the judge picker (judges use
native structured output, fail-soft to prompt tier — `fusion_judge.ml:149-179`).
This is advisory, not enforced: panels are free text since 2026-07-01
(`fusion_panel.ml:14-23`), so no panel filter.

### 3.7 Stale comment correction

`config/runtime.toml:998-1002` and `:1039-1042` still state that panels require
`supports-structured-output`. That has been false since panels became free text
(§3.6). Correct the comment so the editor does not surface a constraint the engine
no longer enforces.

## 4. Non-goals

- The fusion **run/observation** surface (`fusion/fusion-surface.ts`, JoJ topology
  display) — covered by `docs/design/2026-06-24-fusion-dashboard-wiring-rich-text-design.md`.
- Budget/cost/turn controls — collected, not edited (product rule).
- Creating/deleting whole presets from the UI (edit existing presets only); preset
  CRUD is a possible follow-up, see §7.2.
- Per-call `timeout_s` range validation beyond what `of_preset` already checks
  (`Bad_meta_timeout`, `Bad_adaptive_factor`).

## 5. Implementation plan

Each phase is independently mergeable and keeps main deployable.

- **Phase 0 (done, `fix/fusion-settings-layout`)**: layout regression fix.
- **Phase 1**: typed read serializer + `GET .../fusion` (§3.1); §3.7 comment fix.
  Low risk, unblocks form population.
- **Phase 2**: `Toml_line_editor` extraction + multi-line array and array-of-tables
  primitives (§3.2), with comment-preservation golden tests. Highest-risk phase;
  gated by runtime.ml routing/assignment tests staying green.
- **Phase 3**: `POST .../fusion` write path (§3.3) + validation JSON + JoJ invariant
  in `of_preset` (§3.4).
- **Phase 4**: frontend structured form + model pickers + error rendering (§3.5).
- **Phase 5**: `supports_structured_output` exposure + judge advisory (§3.6).

## 6. Verification

- **Comment preservation (golden)**: fixture `runtime.toml` with the 38-line
  `[fusion]` comment block; apply each edit kind (scalar, panel array, judge add,
  judge remove); assert every comment line is byte-identical and only the intended
  value lines changed.
- **Validation → JSON**: table-drive each `invalid` / `config_error` /
  `staged_judge_group_error` variant to its JSON shape; assert payloads survive.
- **JoJ invariant**: `of_preset` rejects a JoJ-strategy preset with `judges = []`
  and with one judge; accepts with two.
- **Round-trip**: load → serialize (§3.1) → edit → write (§3.3) → reload; assert
  the reloaded `Fusion_policy.t` equals the intended model.
- **Write failure is loud**: invalid patch returns JSON error + audit `Failure`,
  file unchanged (atomic write not reached).
- **Frontend (vitest)**: populate form from a JSON fixture; produce the patch;
  render a server error payload to field-level messages.
- **Boundary**: no new `masc → oas` reference beyond the existing catalog path;
  OAS has no fusion reference.

## 7. Resolved questions

1. **Per-block comment fate on array-of-tables regeneration (§3.2). Resolved:
   accept the loss.** Regenerating the `[[...judges]]` region from the typed list
   preserves the surrounding `[fusion]` comments but drops comments *inside* a
   judge block. The documented comments are the top-level `[fusion]` scalars
   (preserved via scalar line-edit); per-judge blocks carry short label comments
   that map to the `label` field surfaced in the UI. A golden test asserts the
   top-level comment block is byte-identical after a judge edit.
2. **Preset CRUD (§4). Resolved: edit-existing-only.** No create/delete of whole
   presets from the UI in this RFC. Preset-name key management is a possible
   follow-up if needed.
3. **JoJ `>= 2` placement (§3.4). Resolved: lift into `of_preset`.** The runtime
   failure it prevents is a real silent-until-dispatch bug, not just a UI concern,
   so config validation is the correct site. The check applies only when the
   preset's strategy dispatches JoJ/staged.

## 8. Boundary classification

Per the product boundary rule, this surface is entirely **deterministic /
declarative**: typed config in, validated TOML out, no heuristic and no LLM
judgment. The only external boundary is the MASC→OAS model catalog read, which is
unchanged. Observability (audit records, reload confirmation) is retained from the
existing raw path.
