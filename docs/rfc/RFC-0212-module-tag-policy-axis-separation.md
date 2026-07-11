---
rfc: "0212"
title: "Separate keeper-exposure policy from the Tool-dispatch routing tag (module_tag three-role de-overload)"
status: Draft
created: 2026-06-03
updated: 2026-06-03
author: jeong-sik
supersedes: []
related: ["0042", "0001"]
implementation_prs: []
---

# RFC-0212 — `module_tag` three-role de-overload (Tool ⊥ keeper-exposure)

- Status: Draft. Design SSOT for the gated `tool_domain_policy_axis` cuts
  surfaced by the 2026-06-03 decouple-completion audit. The Tool-substrate
  domain cut is file-contested with `feat/tool-name-partition`; this document
  is the design the in-flight branch and any follow-up cut must converge on.
- Date: 2026-06-03
- Builds on: RFC-0042 (substring-classifier closure / terminal-reason closed
  sum), RFC-0001 (silent-substitution anti-pattern).
- Verified anchors (main HEAD `c475b9c9e4`): `lib/tool/tool_dispatch.ml:287-289`,
  `lib/keeper/keeper_tool_policy.ml:183-190`, `lib/keeper/keeper_tag_dispatch.ml:45,116,184`.

## 0. Summary

`Tool_dispatch.module_tag` (a closed sum, ~16 variants) is consumed in three
semantically independent roles. Because one type carries all three, a change to
one role silently perturbs the others. This RFC separates **keeper-exposure
policy** into its own typed axis that does not read the dispatch tag, and pins
the **legacy metrics backend label** to its own closed sum, leaving `module_tag` to mean
only "which handler dispatches this tool".

This is the same class of error RFC-0042 closed for `terminal_reason_code`: a
decision that should be a typed value is instead re-derived from a shared
carrier by a catch-all match. The load-bearing failure here is the
`Some _ -> true` catch-all at `keeper_tool_policy.ml:189`.

## 1. Problem (verified evidence)

`module_tag` is consumed in three roles:

1. **Routing (legitimate).** `keeper_tag_dispatch.ml` matches typed module tags
   to select a dispatch module. This is the tag's real job.

2. **Keeper-exposure policy (the bug).** `keeper_tool_policy.ml:183-190`:

   ```ocaml
   (match Tool_dispatch.lookup_tag name with
    | Some Tool_dispatch.Mod_inline
    | Some Tool_dispatch.Mod_compact
    | Some Tool_dispatch.Mod_operator -> false  (* keeper-hidden *)
    | Some _ -> true                            (* keeper-exposed *)
    | None  -> false)
   ```

   The `Some _ -> true` catch-all is load-bearing: whether a keeper may list/call
   a tool is decided by its *dispatch home*. A tool whose routing tag changes
   silently flips keeper visibility. This is duplicated as a runtime guard at
   `keeper_tag_dispatch.ml:116`. Per CLAUDE.md, a `Some _ -> true` / `_ -> false`
   catch-all on a policy decision is the FSM-sparse-match anti-pattern.

3. **legacy metrics backend label (cardinality coupling).** `keeper_tag_dispatch.ml:45`
   `string_of_tag` turns the routing constructor name into a metric label
   (`~labels:[ "tag", string_of_tag tag ]`, line 184). Renaming a routing
   variant silently shifts metric cardinality / breaks dashboards.

**Root entanglement — the substrate names domains.** `tool_dispatch.ml:287-289`:

```ocaml
| Task _  -> Some Mod_task
| Board _ -> Some Mod_inline
| Goal _  -> Some Mod_state
```

The Tool substrate destructures `Task/Board/Goal` — it must not know these
domains exist. **Board is the trap:** `Board _ -> Some Mod_inline` collapses
Board onto `Mod_inline`, which is *also* the home of genuine non-domain inline
tools and is keeper-hidden (role 2). So Board's keeper-hiddenness is an
*accidental consequence of sharing a routing tag*, not an intentional policy
decision. No code states "Board tools are hidden from keepers"; it falls out of
tag-sharing.

## 2. Why "Why this" is a trade-off

- **Cost:** a new typed field on the tool descriptor / `Tool_name`-keyed table,
  plus migrating two consumers (`keeper_tool_policy`, `keeper_tag_dispatch`) to
  read it. Touches a contested file (`keeper_tool_policy.ml`) — must coordinate
  with `feat/tool-name-partition`.
- **Benefit:** keeper-exposure becomes an explicit, exhaustive, compile-checked
  decision per tool; "how a tool dispatches" and "may a keeper call it" stop
  being the same fact; metric label vocabulary stops tracking routing-ctor names.
- **Not free:** full compiler enforcement of "the substrate cannot name domains"
  needs the larger `Tool_name` god-enum split (§4), which is a separate,
  multi-site PR. Until then the substrate-side cut is convention + ratchet.

## 3. The separation

**Keeper-exposure becomes its own typed axis** that does NOT read the dispatch tag:

```ocaml
type hidden_reason =
  | Lifecycle_mutating
  | Mcp_client_only
  | Removed_operator_surface
  | Mcp_session_required
  | Internal_context_tool

type keeper_exposure =
  | Exposed
  | Hidden of hidden_reason
```

Carried as a typed field on the tool descriptor / `Tool_spec.t` (or keyed on the
typed `Tool_name` domain), defined once, consumed by BOTH the listing filter
(`keeper_tool_policy`) and the runtime guard (`keeper_tag_dispatch`) via an
**exhaustive match** — no `Some _ -> true`. "How a tool dispatches" and "may a
keeper list/call it" become orthogonal.

**The legacy metrics backend label gets its own closed sum** `tag_metric_label` with a total
`metric_label_of_module_tag : module_tag -> tag_metric_label`, so the label
vocabulary is a contract independent of routing-constructor renames.

## 4. Migration order

1. **Task / Goal / Operator (clean).** Route each to a dedicated tag
   (`Mod_task` / `Mod_state` / `Mod_operator`); their exposure is already
   unambiguous (all currently `Some _ -> true`). Move the domain→tag mapping into
   per-domain registration via the existing `register_module_tag` path so the
   substrate sees only `string -> tag`, never `Task_name.t -> tag`.

2. **Add the typed `keeper_exposure` field FIRST, then Board (entangled).**
   Because `Mod_inline = keeper-hidden` is shared with non-domain inline tools,
   Board cannot be split off routing until exposure is a separate field. Add
   `Mod_board`, point Board's routing there, and declare Board's exposure
   independently — never via `is_registered` / `Some _ -> true`.

3. **Replace both `Some _ -> true` catch-alls** (`keeper_tool_policy.ml:189`,
   `keeper_tag_dispatch.ml:116`) with exhaustive 16-variant matches **in the same
   PR** as the field introduction, so no tag can be added without an explicit
   exposure decision.

## 5. Compiler / ratchet enforcement

- Exhaustive match over the closed `keeper_exposure` / `hidden_reason` /
  `module_tag` / `tag_metric_label` sums forces every new tag to declare an
  explicit exposure + label at compile time. A new tag that forgets its exposure
  is a compile error, not a silent visibility flip.
- FULL enforcement of "the substrate cannot name domains" requires pulling
  `Task_name / Board_name / Goal_name / Operator_name` submodules OUT of
  `Tool_name.t` so `tool_dispatch.ml` literally cannot write `Task _` — a
  multi-site, separate PR (the god-enum split). Until then, back the convention
  with the boundary ratchet (a `lib/tool/` lint that rejects `Task _` / `Board _`
  / `Goal _` destructuring in the dispatch substrate).

## 6. Coordination

`keeper_tool_policy.ml` and `keeper_tag_dispatch.ml` are listed by
`feat/tool-name-partition` (Step-2 consumer migration: "drop domain arms from
static routing + keeper_tool_policy membership axis"). This RFC must converge
with that branch — do NOT land a parallel cut on the same lines. Sequence: this
RFC defines the target; the in-flight branch (or a coordinated successor)
implements §4 step-by-step; the substrate-domain-naming removal (§5) lands only
after the `Tool_name` split.

## 7. Out of scope

- The `Tool_name` god-enum split itself (separate RFC / PR).
- The `module_tag`-as-legacy metrics backend-label inversion beyond pinning the label sum
  (the broader keeper→legacy metrics backend inversion is RFC-pending under the
  domain_infra_inversion lens).
