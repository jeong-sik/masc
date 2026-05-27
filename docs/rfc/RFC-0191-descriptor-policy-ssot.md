---
title: Descriptor as Policy SSOT — Consolidate keeper_tool_policy axes onto descriptor.policy
rfc: "0191"
status: Draft
created: 2026-05-27
updated: 2026-05-27
author: vincent
supersedes: []
superseded_by: null
related: ["0064", "0179", "0182", "0190"]
implementation_prs: []
---

# RFC-0191 — Descriptor as Policy SSOT

Status: Draft · Architectural framing, no code yet
Related: RFC-0179 (`keeper_*` descriptor coverage), RFC-0182 (`masc_*` descriptor projection), RFC-0190 (visibility SSOT)

## 0. Problem framing

`Agent_tool_descriptor.t` already carries a `policy` record:

```ocaml
type policy =
  { visibility           : Tool_catalog.visibility
  ; readonly_of_input    : readonly_of_input
  ; readonly_hint        : bool option
  ; effect_domain        : Tool_catalog.effect_domain option
  ; approval             : approval
  ; retryable            : bool
  ; cwd_scope            : string option
  ; credential_profile   : string option
  }
```

Yet `lib/keeper/keeper_tool_policy.ml` is **670 LoC, 63 definitions**, and the only point of contact with the descriptor system is one line (`Agent_tool_descriptor_resolution.capability_has` at line 181). The module independently owns:

| Sub-axis | Hand-managed in `keeper_tool_policy.ml` | Equivalent descriptor field |
|---|---|---|
| Writable path prefix list | `keeper_writable_prefixes` (3 entries, hardcoded) | none — should be derived per descriptor (`cwd_scope` + tool-specific) |
| Path normalization | `normalize_path`, `is_masc_write_allowed` | none |
| Denied-set | `keeper_denied_set` Hashtbl | `visibility = Keeper_denied` |
| Tool preset enum | `Minimal/Social/Messaging/Dispatch/Research/Delivery/Full` (7) + `preset_allows_privileged_operations`, `allows_workflow_for_preset`, `allows_shell_write_for_preset` | none — preset is an agent attribute, but the *per-tool* preset gate is missing as a descriptor field |
| Per-tool inline safety | `keeper_safe_inline_tools` list (handmade) | descriptor `executor = In_process` already captures it |
| Maintenance gates | `keeper_maintenance_only_tools` list | none — should be `approval = Human_required` + new `audience` field |
| Last-turn safety | `last_turn_safe_tool_names` list | none — should be a derived property (`readonly_hint = Some true` + `effect_domain = None`) |
| Allowlist by preset | `preset_allowlist` | should be a descriptor-driven projection |
| Universe filter | `tool_access_lookup_of_meta`, `filter_by_universe`, `filter_by_access` | should be a descriptor capability check |

Net result: two SSOTs, the smaller (`policy` record) defines structure, the larger (`keeper_tool_policy.ml`) defines truth. Any preset change requires editing the larger one, and the descriptor never gets consulted.

## 1. Why this is dangerous

This is the workaround bar's §2 (string/substring classifier) and §3 (N-of-M) double-trigger:

- §2: `keeper_safe_inline_tools`, `keeper_maintenance_only_tools`, `last_turn_safe_tool_names`, `keeper_denied_set` are all string lists/sets growing per migration. New tools must be added to N lists separately or be silently mis-policied.
- §3: every time a new tool category surfaces (board sub-boards, persona authoring, sandbox lifecycle), at least one of these lists is patched in isolation. There is no compile-time guarantee that a descriptor's `policy.visibility = Keeper_denied` and the `keeper_denied_set` agree.

CLAUDE.md "워크어라운드 거부 §2/§3" mandates RFC-level resolution.

## 2. Goal

`Agent_tool_descriptor.policy` becomes the authoritative per-tool policy declaration. `keeper_tool_policy.ml` is reduced to:

1. Agent-level state (the *agent's* preset, allowlist resolution at runtime).
2. Boundary helpers that cannot live on the descriptor (path normalization, preset enum semantics).

Every per-tool policy decision (`is_keeper_denied`, `is_keeper_safe_inline_tool`, `is_keeper_maintenance_only_tool`, `last_turn_safe_tool_names`) is computed from `descriptor.policy`.

## 3. Non-goals

- Move agent-preset semantics into the descriptor. Preset is an agent attribute, not a tool attribute.
- Eliminate `Keeper_tool_policy_config` (`config/tool_policy.toml`). The TOML is the *operator-tunable* layer; the descriptor is the *source-of-truth* layer. They compose.
- Touch path-normalization helpers. They predate the descriptor system and have no equivalent.

## 4. Model change

```ocaml
type policy =
  { visibility           : Tool_catalog.visibility
  ; readonly_of_input    : readonly_of_input
  ; readonly_hint        : bool option
  ; effect_domain        : Tool_catalog.effect_domain option
  ; approval             : approval
  ; retryable            : bool
  ; cwd_scope            : string option
  ; credential_profile   : string option
  ; (* NEW *)
    audience             : audience_class
    (* Minimum agent preset required to be granted this tool. *)
  ; minimum_preset       : tool_preset
    (* Whether this tool may execute on the final turn before turn cap.
       Currently a hand-curated list; will be derived from
       (readonly_hint = Some true && effect_domain = None). *)
  ; last_turn_safe       : bool
    (* Whether the tool is permitted on the inline-dispatch fast path
       (no Eio plumbing). Currently a hand list. *)
  ; inline_safe          : bool
  ; (* Maintenance-only tools require an explicit operator gate. *)
    maintenance_only     : bool
  }

and audience_class =
  | Audience_keeper_facing
  | Audience_operator_facing
  | Audience_both
  | Audience_admin_only
```

`audience_class` and `minimum_preset` are *new* descriptor fields, not derived. The other three (`last_turn_safe`, `inline_safe`, `maintenance_only`) are bridges: introduced as explicit fields in P1, then narrowed in P3 to be *derived* from other fields where possible.

## 5. Implementation phases

| Phase | PR scope | Verifiable end-state |
|---|---|---|
| **P1** | Extend `policy` record with 4 new fields. Every existing descriptor literal gets explicit values matching current `keeper_tool_policy.ml` decisions. No callers migrate yet. | Build green. `Agent_tool_descriptor.all_descriptors ()` answers every per-tool policy question. Cross-check test: for each descriptor, assert agreement with `keeper_tool_policy.<predicate>`. Cross-check pass is the migration safety gate. |
| **P2** | Migrate `is_keeper_denied`, `is_keeper_safe_inline_tool`, `is_keeper_maintenance_only_tool` to descriptor-driven projections. Drop the corresponding string lists/Hashtbls. | `keeper_tool_policy.ml` LoC down by ~60. Test from P1 still passes (no semantic change). |
| **P3** | Migrate `last_turn_safe_tool_names` to a derivation rule (`readonly_hint = Some true && effect_domain = None`). Drop the hand list. Audit any descriptor whose old-vs-new disagrees — the disagreement *is* the latent bug, fix by descriptor edit. | Last hand list of per-tool policy classification removed. |
| **P4** | Migrate `preset_allowlist` to read `descriptor.policy.minimum_preset`. Drop preset-keyed string list construction. | `tool_access_lookup_of_meta` becomes a descriptor filter. |
| **P5** | Drop everything in `keeper_tool_policy.ml` that has no agent-level role. Target: < 250 LoC, only `tool_preset` enum + agent-side state + path normalization + descriptor projections. | LoC reduction ~420. |
| **P6** (follow-up RFC) | Re-evaluate whether `Keeper_tool_policy_config` (TOML loader) can be regenerated from descriptors instead of edited by operators. Likely no — operators tune presets, not per-tool policy. | Out of scope. |

P1's cross-check test is the central safety device. The test compares every descriptor's projected predicate against the existing `keeper_tool_policy` answer; **the migration is only permitted to advance if all descriptors agree**. Disagreements found in P1 are P1's job to resolve (by descriptor edit, never by changing the predicate to be more permissive).

## 6. Workaround-bar check

This RFC does *not* trigger workaround signatures:

- §1 telemetry-as-fix: no.
- §2 string/substring classifier: no — this RFC *removes* 4+ string classifiers in favor of a typed record.
- §3 N-of-M: each phase strictly removes one source-of-truth axis. P5 is the only phase that *deletes* code in bulk, and only after P1–P4's cross-check passes prove equivalence. The "delete 420 LoC" PR in P5 has zero behavior change by construction.

## 7. Open questions

1. **`audience_class` enum granularity.** Today the de facto audience is binary (operator-facing on `public_mcp_surface_tools` vs. keeper-facing on `keeper_internal_tools`), but `Tool_catalog_surfaces.keeper_internal_replacement` already encodes a 1:1 mapping for tools with both surfaces. Audience may want a fifth variant `Audience_both_with_distinct_handler` — open for discussion in P1.
2. **Maintenance gate consolidation.** `maintenance_only` overlaps `approval = Human_required`. The distinction today: maintenance can be operator-bypassed for a single tool call, approval is a per-call queue event. Keep both fields in P1; reconsider in P5.
3. **Preset bypass for `tool_preset = Full`.** `Full` preset agents currently skip all preset checks. Keep this behavior — encode as `minimum_preset` defaulting to `Minimal` and a single bypass at the preset evaluator, not as descriptor-level fields.
4. **`Keeper_tool_policy_config` TOML.** Operators edit it. If a descriptor's static `minimum_preset = Dispatch` is overridden by TOML to `Research`, the TOML wins (operator > source). Document precedence in P4.

## 8. Rejected alternatives

- **Single-PR rewrite of `keeper_tool_policy.ml`.** Rejected: workaround §3 (N-of-M dressed as completeness). The 4 sub-axes are independently risky; bundling them defeats the cross-check test's purpose of catching per-axis semantic drift.
- **Keep both SSOTs, add a sync test.** Rejected: drift-by-default; sync test only detects, doesn't prevent. Same critique as RFC-0190 (B-only).
- **Move policy onto `Tool_catalog.metadata`.** Rejected: `Tool_catalog` is the operator-tunable layer (TOML + schema registry); descriptor is the typed-runtime layer. Putting policy on the operator-tunable layer reintroduces the original split that this RFC closes.

## 9. Acceptance criteria

- RFC merged.
- P1's cross-check test exists and passes on every descriptor for every migrated predicate.
- P2–P5 PRs all merged.
- `keeper_tool_policy.ml` is < 250 LoC.
- `is_keeper_denied`, `is_keeper_safe_inline_tool`, `is_keeper_maintenance_only_tool`, `last_turn_safe_tool_names`, `preset_allowlist` all read from `Agent_tool_descriptor.{public,internal}_descriptors`.
- No string list of tool names remains in `keeper_tool_policy.ml` outside of preset enum semantics.
