let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-turn-attempt-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module Observer = Masc.Keeper_turn_attempt_observer
module Registry = Masc.Keeper_registry

let base_path () = Sys.getenv "MASC_BASE_PATH"

let register_keeper keeper =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper; "agent_name", `String keeper ])
    with
    | Ok meta -> meta
    | Error error -> Alcotest.failf "register_keeper %s: %s" keeper error
  in
  ignore
    (Registry.register ~base_path:(base_path ()) keeper meta : Registry.registry_entry)
;;

let test_observations_never_gate () =
  Eio_main.run @@ fun _env ->
  let keeper = "turn-attempt-observer" in
  register_keeper keeper;
  Observer.reset_for_tests ();
  let base_path = base_path () in
  Alcotest.(check bool)
    "first start"
    true
    (Observer.record_turn_start ~base_path ~keeper ~turn_id:10 = Observer.Fresh);
  for expected_previous_attempts = 1 to 100 do
    match Observer.record_turn_start ~base_path ~keeper ~turn_id:10 with
    | Observer.Reattempt { previous_attempts; _ } ->
      Alcotest.(check int)
        "every same-turn attempt remains observable"
        expected_previous_attempts
        previous_attempts
    | Observer.Fresh | Observer.Regression _ ->
      Alcotest.fail "same turn must remain a reattempt observation"
  done;
  match Observer.record_turn_start ~base_path ~keeper ~turn_id:9 with
  | Observer.Regression { previous_turn_id } ->
    Alcotest.(check int) "regression source" 10 previous_turn_id
  | Observer.Fresh | Observer.Reattempt _ ->
    Alcotest.fail "backward turn id must be observed as a regression"
;;

let () =
  Alcotest.run
    "keeper_turn_attempt_observer"
    [ ( "observation-only"
      , [ Alcotest.test_case
            "100 same-turn attempts never produce a gate"
            `Quick
            test_observations_never_gate
        ] )
    ]
;;
