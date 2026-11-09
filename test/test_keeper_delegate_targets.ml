(** [masc_keeper_delegate_targets] lets a Keeper read the queue and live turn of
    the Keepers it could delegate to before it submits. The submit result
    reports [queued_count] and [target_turn_age_s] only after the work is
    queued; docs/evidence/delegate-target-load-2026-11 measures what that cost
    the one Keeper that makes almost every delegation and chooses among five
    reviewers without seeing either.

    The registry cases drive the registry through its public mutators, as
    test_keeper_delegate_target_turn does. The queue counts need an installed
    owner inventory with a queued operation, which test_keeper_owner builds, so
    that case lives there. *)

open Alcotest
module Keeper_registry = Masc.Keeper_registry
module Observer = Masc.Keeper_composite_observer
module Targets = Masc.Keeper_delegate_targets

let json = testable Yojson.Safe.pp Yojson.Safe.equal

let presence =
  let pp fmt = function
    | Targets.Not_registered -> Format.pp_print_string fmt "Not_registered"
    | Targets.Between_turns -> Format.pp_print_string fmt "Between_turns"
    | Targets.In_turn { age_s } -> Format.fprintf fmt "In_turn %ds" age_s
  in
  testable pp ( = )
;;

let temp_base () =
  let d = Filename.temp_file "keeper_delegate_targets_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let register ~base name =
  ignore (Keeper_registry.For_testing.register ~base_path:base name (make_meta name))
;;

let start_turn ~base name =
  let observation_token = Masc.Keeper_turn_observation_token.fresh () in
  Keeper_registry.mark_turn_started
    ~observation_token
    ~base_path:base
    ~wake:Keeper_registry.Proactive_tick
    name
;;

let turn_started_at ~base name =
  match Keeper_registry.get ~base_path:base name with
  | None -> failwith "keeper vanished from registry after register"
  | Some entry ->
    (match Observer.live_turn_observation entry with
     | Some observation -> observation.Keeper_registry.started_at
     | None -> failwith "the turn did not start")
;;

let test_unregistered_is_not_between_turns () =
  let base = temp_base () in
  register ~base "registered";
  check presence "a Keeper the registry lacks has no turn to wait for" Targets.Not_registered
    (Targets.presence ~now:1000.0 ~base_path:base "nobody");
  check presence "a registered Keeper outside a turn is between turns" Targets.Between_turns
    (Targets.presence ~now:1000.0 ~base_path:base "registered")
;;

let test_live_turn_reports_its_age () =
  let base = temp_base () in
  register ~base "busy";
  register ~base "idle";
  start_turn ~base "busy";
  let started_at = turn_started_at ~base "busy" in
  check presence "the busy Keeper reports the seconds its turn has run"
    (Targets.In_turn { age_s = 90 })
    (Targets.presence ~now:(started_at +. 90.9) ~base_path:base "busy");
  check presence "the age belongs to the named Keeper" Targets.Between_turns
    (Targets.presence ~now:(started_at +. 90.9) ~base_path:base "idle")
;;

let test_age_is_whole_seconds_and_never_negative () =
  check int "a clock behind the start reads as zero" 0 (Targets.age_seconds ~now:5.0 ~since:10.0);
  check int "whole seconds, rounded down" 90 (Targets.age_seconds ~now:100.9 ~since:10.0);
  check int "an instant that has just begun is zero" 0 (Targets.age_seconds ~now:10.0 ~since:10.0)
;;

let test_rows_keep_their_wire_shape () =
  let available presence queue = Targets.Available { name = "reviewer"; presence; queue } in
  check json "in a turn with work waiting"
    (`Assoc
       [ "name", `String "reviewer"
       ; "turn", `String "in_turn"
       ; "turn_age_s", `Int 1830
       ; "queued_count", `Int 2
       ; "oldest_queued_age_s", `Int 960
       ])
    (Targets.row_to_json
       (available
          (Targets.In_turn { age_s = 1830 })
          { Targets.queued_count = 2; oldest_queued_age_s = Some 960 }));
  check json "between turns with nothing waiting"
    (`Assoc [ "name", `String "reviewer"; "turn", `String "between_turns"; "queued_count", `Int 0 ])
    (Targets.row_to_json
       (available Targets.Between_turns { Targets.queued_count = 0; oldest_queued_age_s = None }));
  check json "absent from the registry"
    (`Assoc [ "name", `String "reviewer"; "turn", `String "not_registered"; "queued_count", `Int 0 ])
    (Targets.row_to_json
       (available Targets.Not_registered { Targets.queued_count = 0; oldest_queued_age_s = None }));
  List.iter
    (fun (reason, code) ->
       check json ("unavailable: " ^ code)
         (`Assoc [ "name", `String "reviewer"; "unavailable", `String code ])
         (Targets.row_to_json (Targets.Unavailable { name = "reviewer"; reason })))
    [ Targets.Unknown_keeper, "unknown_keeper"
    ; Targets.Owner_unavailable, "owner_unavailable"
    ; Targets.Store_unavailable, "store_unavailable"
    ]
;;

let test_input_outside_the_contract_is_rejected () =
  let config = Masc.Workspace.default_config (temp_base ()) in
  List.iter
    (fun (label, args) ->
       let result = Targets.body ~config args in
       check bool (label ^ " is refused") false (Tool_result.is_success result);
       check bool (label ^ " is a policy rejection") true
         (Tool_result.failure_class result = Some Tool_result.Policy_rejection))
    [ "a name outside the Keeper grammar", `Assoc [ "names", `List [ `String "bad keeper!" ] ]
    ; "a name that is not a string", `Assoc [ "names", `List [ `Int 3 ] ]
    ; "an empty list", `Assoc [ "names", `List [] ]
    ; "no names", `Assoc []
    ; "an extra key", `Assoc [ "names", `List [ `String "a" ]; "limit", `Int 1 ]
    ]
;;

let test_unknown_names_are_rows_not_errors () =
  let config = Masc.Workspace.default_config (temp_base ()) in
  let result =
    Targets.body ~config (`Assoc [ "names", `List [ `String "a"; `String "b" ] ])
  in
  check bool "a well-formed name nobody owns still answers" true (Tool_result.is_success result);
  match Tool_result.data result with
  | `Assoc [ ("targets", `List [ `Assoc a; `Assoc b ]) ] ->
    List.iter
      (fun (name, row) ->
         check (option json) (name ^ " keeps the order asked") (Some (`String name))
           (List.assoc_opt "name" row);
         check bool (name ^ " carries a reason, not facts") true (List.mem_assoc "unavailable" row))
      [ "a", a; "b", b ]
  | other -> fail ("unexpected body: " ^ Yojson.Safe.to_string other)
;;

let () =
  run
    "keeper_delegate_targets"
    [ ( "registry"
      , [ test_case "an unregistered Keeper is told apart" `Quick test_unregistered_is_not_between_turns
        ; test_case "a live turn reports its age" `Quick test_live_turn_reports_its_age
        ; test_case "ages are whole seconds" `Quick test_age_is_whole_seconds_and_never_negative
        ] )
    ; ( "tool"
      , [ test_case "rows keep their wire shape" `Quick test_rows_keep_their_wire_shape
        ; test_case "input outside the contract is rejected" `Quick test_input_outside_the_contract_is_rejected
        ; test_case "unknown names are rows" `Quick test_unknown_names_are_rows_not_errors
        ] )
    ]
;;
