(** [Keeper_tool_surface_ops.target_turn_age_fields] is what the delegate submit
    result and the status of a queued operation add to what the operation store
    reports: how long the target Keeper's live turn has run. A queued operation
    starts after that turn ends, and [queued_count] does not count the running
    turn, so a submitter that reads only the acceptance cannot tell a target
    that is idle from one that is deep into a long turn.

    Each case drives the registry through its public mutators, as
    test_keeper_composite_live_turn_surface does, then reads the projection. *)

open Alcotest
module Keeper_registry = Masc.Keeper_registry
module Observer = Masc.Keeper_composite_observer
module Surface_ops = Masc.Keeper_tool_surface_ops

let json = testable Yojson.Safe.pp Yojson.Safe.equal

let temp_base () =
  let d = Filename.temp_file "keeper_delegate_target_turn_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String ("trace-" ^ name));
        ])
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

let fields ~now ~base name =
  Surface_ops.target_turn_age_fields ~now ~base_path:base ~keeper_name:name
;;

let test_idle_target_adds_nothing () =
  let base = temp_base () in
  register ~base "idle-target";
  check (list (pair string json)) "a target between turns adds no field" []
    (fields ~now:1000.0 ~base "idle-target")
;;

let test_unregistered_target_adds_nothing () =
  let base = temp_base () in
  check (list (pair string json)) "a target the registry does not know adds no field" []
    (fields ~now:1000.0 ~base "nobody")
;;

let test_live_turn_reports_its_age_in_whole_seconds () =
  let base = temp_base () in
  register ~base "busy-target";
  start_turn ~base "busy-target";
  let started_at = turn_started_at ~base "busy-target" in
  check (list (pair string json)) "a live turn adds the seconds it has run"
    [ "target_turn_age_s", `Int 90 ]
    (fields ~now:(started_at +. 90.9) ~base "busy-target")
;;

let test_the_age_belongs_to_the_named_target () =
  let base = temp_base () in
  register ~base "busy-one";
  register ~base "idle-one";
  start_turn ~base "busy-one";
  let started_at = turn_started_at ~base "busy-one" in
  check (list (pair string json)) "the other target is idle" []
    (fields ~now:(started_at +. 5.0) ~base "idle-one");
  check (list (pair string json)) "the busy target reports its own turn"
    [ "target_turn_age_s", `Int 5 ]
    (fields ~now:(started_at +. 5.0) ~base "busy-one")
;;

let () =
  run
    "keeper_delegate_target_turn"
    [ ( "target_turn_age_fields"
      , [ test_case "an idle target adds nothing" `Quick test_idle_target_adds_nothing
        ; test_case
            "an unregistered target adds nothing"
            `Quick
            test_unregistered_target_adds_nothing
        ; test_case
            "a live turn reports its age in whole seconds"
            `Quick
            test_live_turn_reports_its_age_in_whole_seconds
        ; test_case
            "the age belongs to the named target"
            `Quick
            test_the_age_belongs_to_the_named_target
        ] )
    ]
;;
