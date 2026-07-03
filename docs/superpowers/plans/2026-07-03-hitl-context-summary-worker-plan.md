# HITL Context-Aware LLM Judgment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-blocking HITL summary worker that enriches pending approval entries with LLM-generated context summaries, keeping the approval queue decoupled from Board/Goal/Task stores.

**Architecture:** Extend `pending_approval` with immutable summary fields; spawn an `Eio.Fiber` after `record_pending`; collect context by IDs in `Hitl_summary_worker`; call OAS via `Llm_provider.Complete.complete` with a structured output schema; write the summary back with copy-on-write; expose optional fields in dashboard JSON.

**Tech Stack:** OCaml 5.4, Eio, MASC, OAS `Llm_provider`, `Yojson.Safe.t`

---

## File map

| File | Responsibility |
|------|----------------|
| `lib/keeper_contract/keeper_approval_queue_rules_types.ml` | New `hitl_context_summary`, `suggested_option`, `summary_status` types; extend `pending_approval`. |
| `lib/keeper/hitl_summary_worker.ml` (new) | Collect context, build prompt, call LLM, parse structured output, write back. |
| `lib/keeper/hitl_summary_worker.mli` (new) | Minimal interface: `spawn ~sw ~approval_id ()`. |
| `lib/keeper/keeper_approval_queue.ml` | Spawn worker after `record_pending` in `submit_and_await` and `submit_pending`; include summary in JSON. |
| `lib/keeper/keeper_structured_output_schema.ml` | Add HITL summary JSON schema helper. |
| `test/test_hitl_summary_worker.ml` (new) | Unit + integration tests for summary worker and JSON round-trip. |

---

## Task 1: Extend approval queue types

**Files:**
- Modify: `lib/keeper_contract/keeper_approval_queue_rules_types.ml`
- Modify: `lib/keeper_contract/keeper_approval_queue_rules_types.mli`

- [ ] **Step 1: Add summary types before `pending_approval`**

```ocaml
type risk_level =
  | Low
  | Medium
  | High
  | Critical

type suggested_option =
  { label : string
  ; rationale : string
  ; estimated_risk_delta : risk_level option
  }

type hitl_context_summary =
  { summary_version : int
  ; generated_at : float
  ; model_run_id : string
  ; context_summary : string
  ; key_questions : string list
  ; suggested_options : suggested_option list
  ; risk_rationale : string option
  ; uncertainty : float
  }

and summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string; retryable : bool }
```

- [ ] **Step 2: Extend `pending_approval` with optional summary fields**

Append to the existing `pending_approval` record:

```ocaml
type pending_approval =
  { id : string
  ; ... (* existing fields unchanged *)
  ; context_summary : hitl_context_summary option
  ; summary_status : summary_status
  }
```

Default in `create_entry`: `context_summary = None; summary_status = Summary_not_requested`.

- [ ] **Step 3: Add JSON helpers**

Add `hitl_context_summary_to_yojson` and `summary_status_to_yojson` functions in the same file, using `Json_util` helpers where available.

- [ ] **Step 4: Update `.mli` to export new types**

```ocaml
type suggested_option = ...
type hitl_context_summary = ...
type summary_status = ...

val hitl_context_summary_to_yojson : hitl_context_summary -> Yojson.Safe.t
val summary_status_to_yojson : summary_status -> Yojson.Safe.t
```

- [ ] **Step 5: Build the contract library**

Run:
```bash
MASC_DUNE_ALLOW_BARE_DUNE=1 scripts/dune-local.sh build lib/keeper_contract --display quiet
```

Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/keeper_contract/keeper_approval_queue_rules_types.ml lib/keeper_contract/keeper_approval_queue_rules_types.mli
git commit -m "feat(keeper_contract): add HITL context summary types"
```

---

## Task 2: Add structured output schema helper

**Files:**
- Modify: `lib/keeper/keeper_structured_output_schema.ml`
- Modify: `lib/keeper/keeper_structured_output_schema.mli`

- [ ] **Step 1: Define the HITL summary JSON schema**

Add a function that returns a `Yojson.Safe.t` schema:

```ocaml
let hitl_context_summary_schema () : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; "required",
      `List
        [ `String "context_summary"
        ; `String "key_questions"
        ; `String "suggested_options"
        ; `String "uncertainty"
        ]
    ; "properties",
      `Assoc
        [ "context_summary", `Assoc [ "type", `String "string" ]
        ; "key_questions",
          `Assoc
            [ "type", `String "array"
            ; "items", `Assoc [ "type", `String "string" ]
            ]
        ; "suggested_options",
          `Assoc
            [ "type", `String "array"
            ; "items",
              `Assoc
                [ "type", `String "object"
                ; "properties",
                  `Assoc
                    [ "label", `Assoc [ "type", `String "string" ]
                    ; "rationale", `Assoc [ "type", `String "string" ]
                    ; "estimated_risk_delta",
                      `Assoc [ "type", `String "string"; "nullable", `Bool true ]
                    ]
                ]
            ]
        ; "risk_rationale",
          `Assoc [ "type", `String "string"; "nullable", `Bool true ]
        ; "uncertainty", `Assoc [ "type", `String "number" ]
        ]
    ]
;;
```

- [ ] **Step 2: Add `apply_hitl_summary_schema_to_config`**

```ocaml
let apply_hitl_summary_schema_to_config config =
  let schema = hitl_context_summary_schema () in
  Llm_provider.Provider_config.make
    ~kind:config.Llm_provider.Provider_config.kind
    ~model_id:config.model_id
    ~base_url:config.base_url
    ~api_key:(config.api_key :> string)
    ~headers:config.headers
    ?request_path:None
    ~response_format:(Llm_provider.Types.JsonSchema schema)
    ~output_schema:schema
    ()
```

- [ ] **Step 3: Export in `.mli`**

```ocaml
val hitl_context_summary_schema : unit -> Yojson.Safe.t
val apply_hitl_summary_schema_to_config : Llm_provider.Provider_config.t -> Llm_provider.Provider_config.t
```

- [ ] **Step 4: Commit**

```bash
git add lib/keeper/keeper_structured_output_schema.ml lib/keeper/keeper_structured_output_schema.mli
git commit -m "feat(structured_output): add HITL summary schema"
```

---

## Task 3: Implement Hitl_summary_worker

**Files:**
- Create: `lib/keeper/hitl_summary_worker.ml`
- Create: `lib/keeper/hitl_summary_worker.mli`

- [ ] **Step 1: Create the module interface**

```ocaml
(* lib/keeper/hitl_summary_worker.mli *)

(** Spawn an asynchronous HITL context-summary worker.
    The worker is fire-and-forget: it updates the approval entry in the
    global queue if the entry still exists, and silently drops the result
    if the operator has already resolved it. *)
val spawn
  :  sw:Eio.Switch.t
  -> approval_id:string
  -> unit
```

- [ ] **Step 2: Implement context collection skeleton**

```ocaml
(* lib/keeper/hitl_summary_worker.ml *)

open Keeper_approval_queue_rules_types

let build_context_bundle ~entry =
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "risk_level", `String (risk_level_to_string entry.risk_level)
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
    ; "input", entry.input
    ]
;;
```

- [ ] **Step 3: Implement LLM call with timeout/fallback**

Use `Keeper_llm_bridge.run_with_timeout_and_fallback` and `Llm_provider.Complete.complete`. Parse structured output.

```ocaml
let call_summary_llm ~context_bundle ~provider_config () =
  let config =
    Keeper_structured_output_schema.apply_hitl_summary_schema_to_config provider_config
  in
  let prompt =
    [ Llm_provider.Types.System
        "You are a neutral forensic analyst. Summarize the HITL approval context for a human operator."
    ; Llm_provider.Types.User (Yojson.Safe.to_string context_bundle)
    ]
  in
  Keeper_llm_bridge.run_with_timeout_and_fallback
    ~timeout_s:30.0
    (fun () -> Llm_provider.Complete.complete ~config ~messages:prompt ())
;;
```

- [ ] **Step 4: Parse structured response into `hitl_context_summary`**

```ocaml
let parse_summary ~model_run_id json =
  let open Yojson.Safe.Util in
  { summary_version = 1
  ; generated_at = Unix.gettimeofday ()
  ; model_run_id
  ; context_summary = json |> member "context_summary" |> to_string
  ; key_questions = json |> member "key_questions" |> convert_each to_string
  ; suggested_options = json |> member "suggested_options" |> convert_each parse_suggested_option
  ; risk_rationale = json |> member "risk_rationale" |> to_string_option
  ; uncertainty = json |> member "uncertainty" |> to_float
  }
```

- [ ] **Step 5: Implement write-back with copy-on-write**

```ocaml
let update_entry_with_summary ~approval_id summary =
  Keeper_approval_queue.update_pending_entry ~id:approval_id (fun entry ->
    { entry with
      context_summary = Some summary
    ; summary_status = Summary_available summary
    })
;;
```

(Requires adding `update_pending_entry` to `Keeper_approval_queue` in Task 4.)

- [ ] **Step 6: Wire `spawn`**

```ocaml
let spawn ~sw ~approval_id () =
  Eio.Fiber.fork ~sw (fun () ->
    match Keeper_approval_queue.get_pending_entry ~id:approval_id with
    | None -> ()
    | Some entry ->
      let context_bundle = build_context_bundle ~entry in
      match call_summary_llm ~context_bundle ~provider_config:... () with
      | Ok response ->
        (match parse_summary ~model_run_id:response.run_id response.body with
         | summary -> update_entry_with_summary ~approval_id summary
         | exception exn ->
           update_entry_with_failure ~approval_id ~reason:(Printexc.to_string exn) ~retryable:true ())
      | Error err ->
        update_entry_with_failure ~approval_id ~reason:(Agent_sdk.Error.to_string err) ~retryable:true ())
```

- [ ] **Step 7: Commit**

```bash
git add lib/keeper/hitl_summary_worker.ml lib/keeper/hitl_summary_worker.mli
git commit -m "feat(keeper): add HITL summary worker"
```

---

## Task 4: Integrate worker into approval queue

**Files:**
- Modify: `lib/keeper/keeper_approval_queue.ml`
- Modify: `lib/keeper/keeper_approval_queue.mli`

- [ ] **Step 1: Update `create_entry` defaults**

In `create_entry`, set:

```ocaml
{ ...
; context_summary = None
; summary_status = Summary_not_requested
}
```

- [ ] **Step 2: Add `update_pending_entry` helper**

```ocaml
let update_pending_entry ~id f =
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry -> SMap.add id (f entry) map)
;;
```

- [ ] **Step 3: Spawn summary worker after `record_pending`**

In `submit_and_await` after line 843 (`record_pending entry`):

```ocaml
let () = Hitl_summary_worker.spawn ~sw ~approval_id:entry.id () in
```

In `submit_pending` after line 1019 (`record_pending entry`):

```ocaml
let () = Hitl_summary_worker.spawn ~sw ~approval_id:entry.id () in
```

- [ ] **Step 4: Add summary fields to `pending_entry_json_fields`**

Append to the returned assoc list:

```ocaml
; "summary_status", summary_status_to_yojson entry.summary_status
; "context_summary",
  match entry.context_summary with
  | Some s -> hitl_context_summary_to_yojson s
  | None -> `Null
```

- [ ] **Step 5: Export `update_pending_entry` and `get_pending_entry` in `.mli`**

```ocaml
val get_pending_entry : id:string -> pending_approval option
val update_pending_entry : id:string -> (pending_approval -> pending_approval) -> unit
```

- [ ] **Step 6: Build and commit**

```bash
MASC_DUNE_ALLOW_BARE_DUNE=1 scripts/dune-local.sh build lib/keeper_contract lib/keeper --display quiet
git add lib/keeper/keeper_approval_queue.ml lib/keeper/keeper_approval_queue.mli
git commit -m "feat(approval_queue): spawn HITL summary worker and expose summary fields"
```

---

## Task 5: Add tests

**Files:**
- Create: `test/test_hitl_summary_worker.ml`
- Modify: `test/stanzas/test_hitl_summary_worker.inc` (new dune stanza)

- [ ] **Step 1: Add dune test stanza**

```lisp
(test
 (name test_hitl_summary_worker)
 (modules test_hitl_summary_worker)
 (libraries alcotest masc masc_test_deps eio_main))
```

- [ ] **Step 2: Write JSON round-trip test**

```ocaml
let test_summary_json_roundtrip () =
  let summary =
    { Keeper_approval_queue_rules_types.summary_version = 1
    ; generated_at = 1234567890.0
    ; model_run_id = "run-abc"
    ; context_summary = "Keeper wants to edit a file in an active task."
    ; key_questions = [ "Is the path within scope?" ]
    ; suggested_options = []
    ; risk_rationale = Some "File edits are irreversible."
    ; uncertainty = 0.2
    }
  in
  let json = Keeper_approval_queue_rules_types.hitl_context_summary_to_yojson summary in
  Alcotest.(check string) "context_summary preserved" summary.context_summary
    (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "context_summary" json))
;;
```

- [ ] **Step 3: Write non-blocking test**

```ocaml
let test_worker_does_not_block_resolve () =
  (* Submit a pending approval, resolve it immediately, then verify the worker
     does not crash or re-add the entry. *)
  ...
```

- [ ] **Step 4: Run focused test**

```bash
MASC_DUNE_ALLOW_BARE_DUNE=1 scripts/dune-local.sh runtest test/test_hitl_summary_worker.ml --display quiet
```

- [ ] **Step 5: Commit**

```bash
git add test/test_hitl_summary_worker.ml test/stanzas/test_hitl_summary_worker.inc
git commit -m "test(keeper): add HITL summary worker tests"
```

---

## Task 6: Verify and open draft PR

- [ ] **Step 1: Run quality checks**

```bash
ocamlformat --check lib/keeper_contract/keeper_approval_queue_rules_types.ml lib/keeper/hitl_summary_worker.ml lib/keeper/keeper_approval_queue.ml
cd /Users/dancer/me/workspace/yousleepwhen/masc && bash scripts/hardening-ratchet.sh --check
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin feat/hitl-context-summary-worker
```

- [ ] **Step 3: Open draft PR**

```bash
gh pr create --draft --title "feat(keeper): HITL context-aware LLM judgment summary worker" \
  --body-file /Users/dancer/me/memory/design-hitl-context-llm-judgment.html
```

- [ ] **Step 4: Start CI watcher**

```bash
gh pr checks $(gh pr view --json number -q '.number') --watch
```

---

## Spec coverage self-check

| Design requirement | Task |
|--------------------|------|
| Keeper non-blocking | Task 4 spawns `Eio.Fiber.fork ~sw` after `record_pending`, before `await`. |
| Weak coupling | Task 3 worker reads Board/Goal/Task; queue only sees summary result. |
| SSOT paths | Task 3 uses `Common.masc_dir_from_base_path` for audit paths. |
| Immutable update | Task 4 uses copy-on-write `update_pending_entry`. |
| Silent failure forbidden | Task 3 writes `Summary_failed` on all errors. |
| Operator authority preserved | Task 4 `resolve_with_policy` unchanged; summary is recommendation only. |
| Dashboard exposure | Task 4 adds fields to `pending_entry_json_fields`. |
| Chat→Task/Goal linkage | Task 3 `build_context_bundle` includes `task_id`, `goal_id`, `goal_ids`. |

## Open questions recorded

- Summary worker concurrency limit and risk threshold are policy-record concerns; this first PR defaults to spawning for every Medium+ approval.
- Fusion result inclusion in HITL context is out of scope; tracked in design doc §12.
