---
title: ToolDescriptor Ecosystem Coverage Extension to Workspace Tools
rfc: "0179"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0064"]
implementation_prs: []
---

# RFC-0179 — ToolDescriptor Ecosystem Coverage Extension to Workspace Tools

Status: Draft · Architectural question, no code yet
Related: RFC-0064 (LLM-native two-surface tool model — 7 public-name hard-cut)

## 0. Problem framing

RFC-0064 landed the descriptor spine for the seven LLM-native public tools (`Execute`, `SearchFiles`, `ReadFile`, `EditFile`, `WriteFile`, `SearchWeb`, `FetchWeb`). The spine is empirically complete for that surface — invariant tests pin the seven, ratchets block legacy public-name re-emergence, route evidence is recorded per call.

After that work landed, an audit (2026-05-26) of the broader tool ecosystem found:

| Layer | Count | Descriptor-backed |
|---|---|---|
| LLM-native public | 7 | 7 (100%) |
| `masc_*` MCP public | ~104 | 0 |
| Keeper web backend names | 2 (`masc_web_search`, `masc_web_fetch`, not MCP `tools/list` public) | 2 (via `In_process` / `Tool_masc_misc_dispatch`) |
| `keeper_*` internal workspace collaboration | ~37 | 0 |
| **Total** | **~286** | **7 (~2.5%)** |

The 26 legacy match arms in `Agent_tool_dispatch_runtime.execute_keeper_tool_call` (lines 427-503) dispatch the bulk of workspace collaboration tools (`keeper_time_now`, `keeper_broadcast`, `keeper_task_*` cluster of 9, `keeper_voice_*` cluster of 6, `keeper_memory_*`, `keeper_library_*`, `keeper_board_*`, etc.) by string match. They do not flow through `Agent_tool_runtime.handle_internal`.

PR #18677 (merged 2026-05-26) removed three executor enum cases (`In_process`, `Gh_cli`, `Oas_bridge`) on YAGNI grounds because no descriptor used them. That decision was correct *for the current 7-descriptor scope* but contradicts any extension of the spine to workspace collaboration tools — most of which would target `In_process`.

This RFC formalizes the architectural choice the extension requires.

## 1. The conflation

`Agent_tool_descriptor.public_descriptors : t list` currently serves three roles simultaneously:

1. **LLM-native public-name list** — what the model sees as its first-class tool surface. Invariant: exactly 7. Test `test_alias_table_is_stable` pins this count.
2. **Descriptor-backed dispatch table** — `Agent_tool_runtime.handle_internal` walks this list for routing.
3. **Receipt-evidence source** — `route_evidence_json` consumes descriptors to emit per-call evidence.

For the seven LLM-native tools the three roles align: each is public, dispatched via descriptor, and emits evidence. Extending the spine to workspace collaboration tools breaks role (1): `keeper_time_now` is not an LLM-native public name in the RFC-0064 sense, so adding it to `public_descriptors` either:

- Conflates "descriptor-backed" with "public LLM-native", inflating the pinned-7 invariant, or
- Requires bifurcating the descriptor list.

## 2. Options

### Option A — Bifurcate the descriptor list

Introduce `internal_descriptors : t list` separate from `public_descriptors : t list`. Both flow through `Agent_tool_runtime.handle_internal`, both feed `route_evidence_json`, but only `public_descriptors` defines the LLM-native public surface.

```ocaml
val public_descriptors : t list      (* 7 LLM-native, invariant-pinned *)
val internal_descriptors : t list    (* keeper_* / masc_* workspace collaboration, growing *)
val all_descriptors : unit -> t list (* concatenation, used by runtime *)
```

Tests:
- `test_alias_table_is_stable` continues to pin `List.length public_descriptors = 7`.
- New `test_internal_descriptor_invariants` verifies internal descriptors have `internal_name = public_name` (no LLM rename), no `Tool_*` runtime_handler enum case (those are reserved for the seven).

Trade-offs:
- ✅ Preserves RFC-0064 hard-cut semantics (public-name surface is locked at 7).
- ✅ Workspace tools get descriptor benefits (typed dispatch, receipt evidence, policy SSOT) without surface inflation.
- ⚠️ Two-list model is more complex to reason about. New contributor friction.

### Option B — Unify, rename the invariant

Drop the "exactly 7" pin. Rename `public_descriptors` to `descriptors`. The seven LLM-native are now a *subset* identified by some marker (e.g. `policy.visibility = Public_llm_native`). Public-surface emission filters by that marker.

Trade-offs:
- ✅ One list, simpler model.
- ⚠️ Public-surface protection moves from list-membership to a policy field. Easier to drift accidentally.
- ⚠️ Ratchet `no-legacy-tool-surface-name.sh` already scans `public_descriptors` declaration sites — would need rewiring.

### Option C — Leave workspace collaboration tools out of descriptor model

Workspace tools (`keeper_*`, `masc_*` non-descriptor-backed) stay in `Agent_tool_dispatch_runtime` legacy match chain forever. Descriptor model is *intentionally* LLM-native-only.

Trade-offs:
- ✅ No architectural churn. Status quo holds.
- ❌ Loses the user-visible benefit: typed dispatch, route receipt, policy SSOT for ~280 tools.
- ❌ The legacy match chain (606 LOC, growing) becomes the de-facto SSOT for workspace collaboration dispatch — a parallel system to descriptors. Two SSOTs in one codebase.

## 3. Recommendation

**Option A** (bifurcate). Reasons:

1. RFC-0064's hard-cut was about *LLM-native* surface protection. The seven names are a contract with the model, not with operators. Workspace tools don't share that contract — operators see them via different channels (capability hints, runbooks, dashboard).
2. The seven's invariant (pinned count, retired-name opaque test) is operationally protective. Diluting it via Option B weakens that protection without compensating benefit.
3. Workspace tools' migration is *progressive* — RFC-0179-PR-1 might add only `keeper_time_now`, RFC-0179-PR-2 adds the task cluster, etc. Option A makes each step a clean addition to one list; Option B/C require either re-typing all workspace collaboration tools at once (B) or accepting permanent parallel system (C).

## 4. Implementation sketch (Option A)

### PR-1 — list bifurcation, no behavior change

1. `Agent_tool_descriptor.mli`:
   ```ocaml
   val public_descriptors : t list      (* existing, 7 entries unchanged *)
   val internal_descriptors : t list    (* new, [] initially *)
   val all_descriptors : unit -> t list (* new, public ++ internal *)
   ```
2. `Agent_tool_descriptor.ml`: define `internal_descriptors = []`. `all_descriptors` concatenates.
3. `Agent_tool_runtime.ml`: change `descriptor_for_internal` and any other walkers to use `all_descriptors ()` instead of `public_descriptors`.
4. Test: `test_internal_descriptors_empty_initially` pins `[]` so any addition is intentional.
5. `test_alias_table_is_stable` unchanged (still 7).

### PR-2 — first workspace collaboration migration (keeper_time_now)

1. Re-add `In_process` to executor enum (undoes part of #18677 — explicitly mark in commit message as superseding #18677's YAGNI rationale).
2. Add `Tool_time_now` to `runtime_handler` enum.
3. Add descriptor entry in `internal_descriptors`:
   ```ocaml
   ; descriptor
       ~id:"keeper_time_now"
       ~public_name:"keeper_time_now"
       ~internal_name:"keeper_time_now"
       ~description:"Return current ISO 8601 timestamp and Unix epoch seconds."
       ~input_schema:(`Assoc [...empty object schema...])
       ~policy:{ visibility = Hidden_active; readonly = Some true; ... }
       ~executor:In_process
       ~backend:Ocaml_runtime
       ~sandbox:No_sandbox
       ~runtime_handler:Tool_time_now
       ...
   ```
4. New `lib/keeper/agent_tool_in_process_runtime.{ml,mli}` with `handle_time_now : context -> args:Yojson.Safe.t -> string`.
5. Wire `handle_in_process` in `agent_tool_runtime.ml`.
6. Remove legacy match arm for `"keeper_time_now"` from `Agent_tool_dispatch_runtime:448-451`.
7. Test: descriptor route for `keeper_time_now`, parity with legacy output JSON.

### PR-3..N — cluster migrations

Each cluster (task, board, voice, memory, library) becomes one PR. Cluster size 1-9. Same pattern.

## 5. Invariants

- **Public-surface lock**: `List.length public_descriptors = 7`. Pinned forever (or until a follow-up RFC explicitly expands the LLM-native surface).
- **Internal-surface monotonic**: `internal_descriptors` grows but each addition removes one legacy match arm (no double-dispatch).
- **No catch-all in `Agent_tool_runtime.handle`**: every new executor case forces a dispatch function (structurally exhaustive). PR #18677 enabled this; this RFC preserves it.

## 6. Out of scope

- Migration of all ~106 `masc_*` MCP tools — these are predominantly external workspace collaboration via Workspace runtime, not single-keeper dispatch. Separate RFC.
- Renaming `Agent_tool_dispatch_runtime` after legacy chain shrinks. The chain may end up empty after full cluster migration — at that point a follow-up RFC retires the module.
- `Gh_cli` / `Oas_bridge` re-introduction. Neither has a concrete near-term consumer. YAGNI holds for them until a real PR-N targets them.

## 7. Open questions

- Does the `Tool_catalog.visibility` field already capture the public-vs-internal distinction well enough that Option B isn't actually weaker? Need to inspect existing visibility variants and how they flow.
- The `runtime_handler` enum currently has six `Tool_*` cases tightly bound to the seven public names. Extending to workspace collaboration tools means many more enum cases. Should `runtime_handler` move to a string handler key, or stay enum with growth?

## 8. Decision request

Pick A, B, or C. If A or B, this RFC moves to Implementation phase and PR-1 lands. If C, document the parallel-SSOT explicitly so future contributors know not to extend the descriptor model.
