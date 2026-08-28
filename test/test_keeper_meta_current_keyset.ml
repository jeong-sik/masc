(** Drift gate for the explicit current Keeper-meta key set. *)

open Masc

let target_keys =
  [ "trace_history"
  ; "instructions"
  ; "last_runtime_attempt"
  ; "current_task_id"
  ; "keeper_id"
  ; "agent_core_env"
  ; "schema"
  ]

let test_canonical_includes_runtime_keys () =
  let canonical = Keeper_meta_json.canonical_keeper_meta_key_names in
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf
           "canonical_keeper_meta_key_names contains %s"
           key)
        true
        (List.mem key canonical))
    target_keys

let valid_json () =
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "strict-meta"
         ; "trace_id", `String "trace-strict-meta"
         ])
    |> Result.get_ok
  in
  Keeper_meta_json.meta_to_json meta
;;

let add_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: fields)
  | _ -> Alcotest.fail "metadata encoder did not return an object"
;;

let check_rejected label json =
  match Keeper_meta_json_parse.meta_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (label ^ " was accepted")
;;

let test_unknown_field_is_rejected () =
  valid_json ()
  |> add_field "future_field" (`String "unsupported")
  |> check_rejected "unknown metadata field"
;;

let test_wrong_schema_is_rejected () =
  match valid_json () with
  | `Assoc fields ->
    `Assoc (("schema", `String "unsupported") :: List.remove_assoc "schema" fields)
    |> check_rejected "wrong metadata schema"
  | _ -> Alcotest.fail "metadata encoder did not return an object"
;;

let () =
  Alcotest.run
    "keeper_meta_current_keyset"
    [ ( "drift_gate"
      , [ Alcotest.test_case
            "runtime keys present"
            `Quick
            test_canonical_includes_runtime_keys
        ; Alcotest.test_case
            "unknown field is rejected"
            `Quick
            test_unknown_field_is_rejected
        ; Alcotest.test_case
            "wrong schema is rejected"
            `Quick
            test_wrong_schema_is_rejected
        ] )
    ]
;;
