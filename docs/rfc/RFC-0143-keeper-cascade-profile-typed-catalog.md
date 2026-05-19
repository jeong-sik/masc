---
rfc: "0143"
title: "keeper_cascade_profile Typed Catalog Query Result"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0141"]
implementation_prs: []
---

# RFC-0143 — keeper_cascade_profile Typed Catalog Query Result

## 1. Summary

`lib/keeper/keeper_cascade_profile.ml` has six sites where `catalog_metadata_result ()` returns `Error _` and the call silently falls back to `false`, `[]`, or `None`. These are not dead arms — they fire when the catalog file is unreadable, missing, or malformed. The current behavior:

- `Catalog read failure` and `keeper is not assignable` collapse into the same `false`.
- `Catalog read failure` and `no system catalogs configured` collapse into the same `[]`.

Callers cannot tell whether the absence is intentional config or a runtime fault, so misconfigured fleets degrade silently.

The fix needs a typed catalog query result variant and a caller-side decision protocol. 25+ caller files makes this an N-of-M migration — RFC required to scope the rollout (CLAUDE.md `<agent_delegation>` `keeper_*` neighborhood; not a hard gate but bundling 25+ files in a single PR violates Surgical Changes).

## 2. Surface today

| Line | Function | `Error _` arm | Behavior |
|---|---|---|---|
| `:173-174` | `catalog_names` (path branch) | `Error _ -> []` | "if declarative parse fails, return empty" |
| `:182-183` | `catalog_names` (fallback branch) | `Error _ -> []` | "if fallback also fails, return empty" |
| `:200-201` | `catalog_lookup_names` | `Error _ -> []` | same |
| `:207-208` | `catalog_lookup_names` fallback | `Error _ -> []` | same |
| `:405` | `is_system_only_cascade` | `Error _ -> false` | "if metadata read fails, treat as non-system" |
| `:415` | `system_catalog_names` | `Error _ -> []` | "if metadata fails, no system names" |
| `:489-490` | `normalize_keeper_runtime_declared_name` | `Error _ -> false` | "if metadata fails, not keeper_assignable" |

The two `false` arms (`:405`, `:489-490`) are the most dangerous because they routing-default to "ignore this name" — a misconfigured catalog silently denies keeper assignability for every name, producing no diagnostic.

Caller surface (25 OCaml files):

```
lib/cascade/cascade_catalog_runtime_resolve.ml
lib/cascade/cascade_metrics.ml
lib/cascade/cascade_routes.ml
lib/dashboard_cascade_config.ml
lib/keeper/keeper_cascade_profile.ml         (self)
lib/keeper/keeper_error_classify.ml
lib/keeper/keeper_exec_preflight.ml
lib/keeper/keeper_persona_authoring.ml
lib/keeper/keeper_runtime.ml
lib/keeper/keeper_status_bridge.ml
lib/keeper/keeper_turn_cascade_budget_routing.ml
lib/keeper/keeper_turn_up_args.ml
lib/keeper/keeper_types_profile.ml
lib/keeper/keeper_unified_turn.ml
lib/keeper/keeper_world_observation.ml
lib/server/server_routes_http_routes_dashboard.ml
test/test_keeper_cascade_profile_partial.ml
test/test_keeper_toml_config_validation.ml
test/test_keeper_unified.ml
(plus *.mli files for the keeper modules)
```

## 3. Proposal — `catalog_query_result`

```ocaml
(** Result of a catalog metadata query. The [Unavailable] variant is
    distinct from [Ok []] (which means "catalog exists and is empty")
    and from [Ok meta] (which means "catalog exists and has these
    entries"). *)
type 'a catalog_query_result =
  | Catalog_ok of 'a
  | Catalog_unavailable of {
      reason: catalog_unavailable_reason;
      message: string;     (** for diagnostic logging *)
    }

and catalog_unavailable_reason =
  | Catalog_path_not_resolved
  | Catalog_file_not_found of string
  | Catalog_parse_error of string
  | Catalog_runtime_snapshot_unavailable
```

Call-site decision protocol:

```ocaml
let is_system_only_cascade raw =
  match catalog_metadata_query () with
  | Catalog_ok meta -> List.mem (public_name_of_target raw) meta.system_names
  | Catalog_unavailable { reason = Catalog_file_not_found _; _ } ->
      false  (* expected on first-boot empty install — preserve current behavior *)
  | Catalog_unavailable { reason; message } ->
      Log.Cascade.warn "[CascadeProfile] is_system_only_cascade: catalog \
                        unavailable (%s); defaulting to non-system: %s"
                       (catalog_unavailable_reason_to_string reason) message;
      Cascade_metrics.on_catalog_unavailable ~site:"is_system_only_cascade" ();
      false
```

Two important details:

- **First-boot `Catalog_file_not_found` keeps `false`** (preserves today's behavior on legitimate empty installs).
- **Other failure modes log and counter-increment**, then default conservatively. This is *not* a Counter-as-Fix (RFC-0088 §3.1) because the counter is *diagnostic alongside the typed variant* — the root fix *is* the variant. The log + counter exist only so a misconfigured fleet shows up in operator dashboards rather than as silent denial.

## 4. Migration steps

This RFC requires careful phased migration because the variant rename touches ~25 caller files. To keep each PR self-contained:

1. **PR-1 — bridge phase**: introduce `catalog_metadata_query` (new name, typed result) alongside the existing `catalog_metadata_result` (old, `('a, string) result`). The new function calls the old one internally and translates the string error to a typed `Unavailable` variant by inspecting Otoml's error message. Unit-test the translation table.

2. **PR-2 — call-site migration, batch A (6 sites in `keeper_cascade_profile.ml` itself)**: switch the seven sites listed above to the new query. Each `false`/`[]` arm gets an explicit `Catalog_unavailable` branch.

3. **PR-3 — call-site migration, batch B (8 caller files in `lib/keeper/` outside the SSOT)**: `keeper_runtime`, `keeper_exec_preflight`, `keeper_status_bridge`, `keeper_unified_turn`, `keeper_persona_authoring`, `keeper_turn_up_args`, `keeper_turn_cascade_budget_routing`, `keeper_world_observation`.

4. **PR-4 — call-site migration, batch C (5 caller files in `lib/cascade/` + dashboard + server)**.

5. **PR-5 — `catalog_metadata_result` deletion + ratchet regenerate**: only remove the old API after all callers migrated. The `silent-failure-ratchet.sh` baseline drops `error_result_silence` by 6 in this PR (the original keeper_cascade_profile sites). Cross-batch sites in keeper_runtime/keeper_status_bridge may drop additional counts.

Each PR builds clean. PR-2..PR-4 are *batch-mechanical* — same shape applied to disjoint file sets — so they can be reviewed in parallel.

## 5. Compatibility

- The bridge phase (PR-1) is purely additive. `catalog_metadata_result` keeps its current signature.
- PR-2..PR-4 behavioral change: misconfigured catalogs that today silently produce `false`/`[]` will start emitting `Log.Cascade.warn` lines and `cascade_catalog_unavailable_count{site=…}` metric.
- PR-5 is the only PR that removes API surface; it must be the last in the stack.
- No wire/API compat impact — `keeper_cascade_profile` is internal.

## 6. Non-goals

- Changing what counts as "system" vs "keeper-assignable" — RFC scope is purely the `Error _ -> false/[]` boundary, not the routing logic itself.
- Replacing `catalog_metadata_result` for tests; tests can continue to use the result type (or migrate at the author's discretion).
- Re-litigating the `system_names` vs `keeper_assignable_names` SSOT (separate concern).

## 7. Test plan

| Phase | Test |
|---|---|
| PR-1 | Unit: bridge function translates 4 known Otoml error messages to the 4 typed variants. Round-trip: catalog file missing → `Catalog_file_not_found`; catalog file malformed → `Catalog_parse_error`. |
| PR-2 | Existing `test_keeper_cascade_profile_partial.ml` + `test_keeper_toml_config_validation.ml` + `test_keeper_unified.ml` must pass without modification. Add a "first-boot empty install" test asserting `is_system_only_cascade` returns `false` without logging. |
| PR-3..4 | Each batch's test suite must pass. No new tests required at batch level — the behavior change is centralized in the call-site decision template. |
| PR-5 | `silent-failure-ratchet.sh` baseline regenerate: `error_result_silence` drops by ≥6. `cascade_catalog_unavailable_count` metric is exported. |

## 8. RFC-0088 conformance

- **§3.1 (Counter-as-Fix)**: `Cascade_metrics.on_catalog_unavailable` is diagnostic *alongside* the typed-variant root fix. The variant *is* the fix.
- **§3.2 (String classifier)**: PR-1's translation from Otoml's string error to typed variant uses string substring matching internally — this is *temporary*, scoped to the bridge phase. PR-5 deletes the bridge once Otoml's typed error API is exposed (tracked as a separate prerequisite issue).
- **§3.3 (N-of-M)**: This RFC explicitly schedules 4 PRs to cover all 25 sites, with PR-5 as the closeout marker. PR-2 introduces no new partial coverage — all 7 self-sites move in one batch.
- **§3.4 (Symptom suppression)**: no cap/cooldown/repair.

## 9. Open questions

1. Should the `Catalog_file_not_found` first-boot path emit a one-shot info log so operators can confirm "empty install detected, defaulting"? Tentative answer: yes, behind a `MASC_LOG_FIRST_BOOT_CATALOG` env var, emitted once per process.
2. Should the metric be a counter (event count) or gauge (current unavailable site count)? Counter — matches existing `cascade_*_count` siblings.

## 10. Related work

- RFC-0088 — workaround rejection bar.
- RFC-0141 — TOML field typed variant (sister RFC for repo_manager/credential subsystem, same 2026-05-20 audit).
- MEMORY `project_cascade_tier_group_misroute_2026_05_17` — same silent-drop family at the cascade.toml boundary.
