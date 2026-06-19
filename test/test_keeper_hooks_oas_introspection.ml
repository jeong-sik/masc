(** Contract lock for {!Keeper_hooks_oas_introspection.hook_introspection_json}.

    This is a CONTRACT LOCK, not a live cross-check. The introspection is a
    hand-maintained static description of the keeper hook slots, so it can
    silently drift from the real wiring. This test pins the semantic contract
    (which slots exist, which are active, their sources, and the cost-telemetry
    "never enforced" invariant) so any edit to the introspection forces a
    conscious update here and a re-check against the real hook wiring:

    - lib/keeper/keeper_hooks_oas.ml ([make_hooks]) — the keeper_hooks_oas slots
    - lib/keeper/keeper_run_tools.ml — before_turn_params
    - lib/keeper/keeper_guards.ml — pre_tool_use

    A full runtime cross-check that builds the real [make_hooks] record and
    asserts each field's Some/None against these claims needs a
    Workspace.config / keeper_meta / turn_ctx_cell fixture and is deferred. *)

open Alcotest

let json = Masc.Keeper_hooks_oas_introspection.hook_introspection_json ~denied_tools:[] ()

let slots_of (j : Yojson.Safe.t) =
  match j with
  | `Assoc fields -> (
    match List.assoc_opt "slots" fields with
    | Some (`Assoc slots) -> slots
    | _ -> failwith "introspection JSON missing `slots` assoc")
  | _ -> failwith "introspection JSON is not an object"

let slot_field slot_name field =
  match List.assoc_opt slot_name (slots_of json) with
  | Some (`Assoc sf) -> List.assoc_opt field sf
  | _ -> None

let slot_bool slot_name field =
  match slot_field slot_name field with Some (`Bool b) -> Some b | _ -> None

let slot_string slot_name field =
  match slot_field slot_name field with Some (`String s) -> Some s | _ -> None

(* The 11 slots the introspection claims are wired, and the 3 it claims are
   not (compaction is handled by keeper_post_turn, not the SDK hooks). *)
let expected_active =
  [ "before_turn"
  ; "before_turn_params"
  ; "after_turn"
  ; "pre_tool_use"
  ; "post_tool_use"
  ; "post_tool_use_failure"
  ; "on_stop"
  ; "on_idle"
  ; "on_idle_escalated"
  ; "on_error"
  ; "on_tool_error"
  ]

let expected_inactive = [ "pre_compact"; "post_compact"; "on_context_compacted" ]

let test_slot_set () =
  let names = List.map fst (slots_of json) |> List.sort compare in
  let expected = List.sort compare (expected_active @ expected_inactive) in
  check (list string) "introspection exposes exactly the 14 known hook slots" expected names

let test_active_split () =
  List.iter
    (fun n -> check (option bool) (n ^ " is active") (Some true) (slot_bool n "active"))
    expected_active;
  List.iter
    (fun n -> check (option bool) (n ^ " is inactive") (Some false) (slot_bool n "active"))
    expected_inactive

let test_sources () =
  (* pre_tool_use and before_turn_params come from sibling modules, not the
     keeper_hooks_oas record; the rest of the active slots are keeper_hooks_oas. *)
  check (option string) "pre_tool_use source" (Some "keeper_guards")
    (slot_string "pre_tool_use" "source");
  check (option string) "before_turn_params source" (Some "keeper_run_tools")
    (slot_string "before_turn_params" "source");
  check (option string) "after_turn source" (Some "keeper_hooks_oas")
    (slot_string "after_turn" "source");
  List.iter
    (fun n ->
      check (option string) (n ^ " source") (Some "not_registered") (slot_string n "source"))
    expected_inactive

(* The cost budget is advisory-only: keeper_guards.cost_guard ignores
   max_cost_usd and always returns Continue. The introspection must therefore
   report enforced:false in BOTH the "no budget" and "budget set" branches —
   relabelling it as enforced would be a false claim of a control that does not
   block anything. *)
let enforced_of (j : Yojson.Safe.t) =
  match j with
  | `Assoc fields -> (
    match List.assoc_opt "cost_telemetry" fields with
    | Some (`Assoc ct) -> (
      match List.assoc_opt "enforced" ct with Some (`Bool b) -> Some b | _ -> None)
    | _ -> None)
  | _ -> None

let test_cost_telemetry_never_enforced () =
  check (option bool) "enforced is false with no budget" (Some false) (enforced_of json);
  let with_budget =
    Masc.Keeper_hooks_oas_introspection.hook_introspection_json ~denied_tools:[]
      ~max_cost_usd:5.0 ()
  in
  check (option bool) "enforced is false even when a budget is set" (Some false)
    (enforced_of with_budget)

let () =
  Alcotest.run "Keeper_hooks_oas_introspection"
    [ ( "slot contract"
      , [ test_case "exactly the 14 known slots" `Quick test_slot_set
        ; test_case "11 active / 3 inactive" `Quick test_active_split
        ; test_case "slot sources" `Quick test_sources
        ; test_case "cost telemetry is never enforced" `Quick test_cost_telemetry_never_enforced
        ] )
    ]
