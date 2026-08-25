module Subsystem_health = Masc.Subsystem_health
module State = Masc.Subsystem_health_state

let apply event state = State.apply state event

let require_entry name entries =
  match List.assoc_opt name entries with
  | Some health -> health
  | None -> Alcotest.failf "missing subsystem %s" name
;;

let test_state_transitions_are_typed_and_sorted () =
  let state =
    State.empty
    |> apply (State.Registered { name = "zeta" })
    |> apply (State.Registered { name = "alpha" })
    |> apply (State.Crashed { name = "zeta"; crashed_at = 42.5 })
  in
  let entries = State.entries state in
  Alcotest.(check (list string))
    "names are canonical map order"
    [ "alpha"; "zeta" ]
    (List.map fst entries);
  (match require_entry "alpha" entries with
   | State.Alive -> ()
   | State.Dead _ -> Alcotest.fail "registered subsystem is not alive");
  match require_entry "zeta" entries with
  | State.Dead { crashed_at } ->
    Alcotest.(check (float 0.001)) "crash timestamp retained" 42.5 crashed_at
  | State.Alive -> Alcotest.fail "crashed subsystem is still alive"
;;

let test_reregister_clears_crash_state () =
  let state =
    State.empty
    |> apply (State.Crashed { name = "worker"; crashed_at = 10.0 })
    |> apply (State.Registered { name = "worker" })
  in
  match require_entry "worker" (State.entries state) with
  | State.Alive -> ()
  | State.Dead _ -> Alcotest.fail "re-registration retained stale crash state"
;;

let test_wire_projection_keeps_current_shape () =
  let string_field name json =
    match Yojson.Safe.Util.member name json with
    | `String value -> Some value
    | _ -> None
  in
  Subsystem_health.register "wire-alive";
  Subsystem_health.mark_dead "wire-dead";
  match Subsystem_health.to_yojson () with
  | `Assoc fields ->
    Alcotest.(check bool)
      "keys are sorted"
      true
      (List.map fst fields = [ "wire-alive"; "wire-dead" ]);
    Alcotest.(check (option string))
      "alive status"
      (Some "alive")
      (Option.bind (List.assoc_opt "wire-alive" fields) (string_field "status"));
    (match List.assoc_opt "wire-dead" fields with
     | Some (`Assoc dead_fields) ->
       Alcotest.(check (option string))
         "dead status"
         (Some "dead")
         (Option.bind
            (List.assoc_opt "status" dead_fields)
            (function
              | `String value -> Some value
              | _ -> None));
       Alcotest.(check bool)
         "dead timestamp present"
         true
         (List.mem_assoc "crashed_at" dead_fields)
     | Some _ | None -> Alcotest.fail "dead subsystem JSON object missing")
  | _ -> Alcotest.fail "subsystem health projection is not an object"
;;

let () =
  Alcotest.run
    "subsystem_health_state"
    [ ( "state"
      , [ Alcotest.test_case
            "typed transitions and ordering"
            `Quick
            test_state_transitions_are_typed_and_sorted
        ; Alcotest.test_case
            "re-register clears crash"
            `Quick
            test_reregister_clears_crash_state
        ; Alcotest.test_case
            "wire projection"
            `Quick
            test_wire_projection_keeps_current_shape
        ] )
    ]
;;
