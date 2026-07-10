(** Contract lock for {!Keeper_hooks_oas_introspection.hook_introspection_json}.

    The introspection is a hand-maintained static description of the keeper
    hook slots. This test pins the semantic contract and cross-checks the slots
    owned by [Keeper_hooks_oas.make_hooks] against the actual final hook record,
    so a runtime slot cannot be removed while the dashboard still reports it as
    active:

    - lib/keeper/keeper_hooks_oas.ml ([make_hooks]) — the keeper_hooks_oas slots
    - lib/keeper/keeper_run_tools.ml — before_turn_params
    - lib/keeper/keeper_guards.ml — pre_tool_use

    [before_turn_params] is assembled by [Keeper_run_tools_hooks], not
    [make_hooks], so its source/active claim remains a sibling-module contract
    lock here. *)

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

let slot_active slot_name =
  match slot_bool slot_name "active" with
  | Some active -> active
  | None -> failwith ("introspection slot missing active bool: " ^ slot_name)

(* The 9 slots the introspection claims are wired, and the 3 it claims are
   not (compaction is handled by keeper_post_turn, not the SDK hooks). *)
let expected_active =
  [ "before_turn"
  ; "before_turn_params"
  ; "after_turn"
  ; "pre_tool_use"
  ; "post_tool_use"
  ; "post_tool_use_failure"
  ; "on_stop"
  ; "on_error"
  ; "on_tool_error"
  ]

let expected_inactive = [ "pre_compact"; "post_compact"; "on_context_compacted" ]

let test_slot_set () =
  let names = List.map fst (slots_of json) |> List.sort compare in
  let expected = List.sort compare (expected_active @ expected_inactive) in
  check (list string) "introspection exposes exactly the 12 known hook slots" expected names

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

let make_meta_ref (name : string) : Masc.Keeper_meta_contract.keeper_meta ref =
  let json : Yojson.Safe.t =
    `Assoc
      [
        "name", `String name;
        "agent_name", `String name;
        "trace_id", `String "keeper-hooks-introspection-test";
        "tool_access", Json_util.json_string_list [];
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> ref meta
  | Error e -> failwith ("make_meta_ref: " ^ e)

let make_runtime_hooks () : Agent_sdk.Hooks.hooks =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("masc-hook-introspection-" ^ string_of_int (Unix.getpid ()))
  in
  let config = Masc.Workspace.default_config base_path in
  let meta_ref = make_meta_ref "hook-introspection-keeper" in
  let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
  Masc.Keeper_hooks_oas.make_hooks ~config ~meta_ref ~turn_ctx_cell ~generation:0 ()

let runtime_slots_of (hooks : Agent_sdk.Hooks.hooks) =
  [
    "before_turn", Option.is_some hooks.before_turn;
    "after_turn", Option.is_some hooks.after_turn;
    "pre_tool_use", Option.is_some hooks.pre_tool_use;
    "post_tool_use", Option.is_some hooks.post_tool_use;
    "post_tool_use_failure", Option.is_some hooks.post_tool_use_failure;
    "on_stop", Option.is_some hooks.on_stop;
    "on_error", Option.is_some hooks.on_error;
    "on_tool_error", Option.is_some hooks.on_tool_error;
    "pre_compact", Option.is_some hooks.pre_compact;
    "post_compact", Option.is_some hooks.post_compact;
    "on_context_compacted", Option.is_some hooks.on_context_compacted;
  ]

let test_runtime_active_claims_match_make_hooks () =
  make_runtime_hooks ()
  |> runtime_slots_of
  |> List.iter (fun (slot_name, active) ->
    check bool
      (slot_name ^ " active claim matches make_hooks")
      active
      (slot_active slot_name))

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
      , [ test_case "exactly the 12 known slots" `Quick test_slot_set
        ; test_case "9 active / 3 inactive" `Quick test_active_split
        ; test_case "slot sources" `Quick test_sources
        ; test_case "make_hooks active claims match runtime record" `Quick
            test_runtime_active_claims_match_make_hooks
        ; test_case "cost telemetry is never enforced" `Quick test_cost_telemetry_never_enforced
        ] )
    ]
