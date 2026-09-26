(** Drift gate for the explicit current Keeper-meta key set. *)

open Masc

let target_keys =
  [ "instructions"
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

(* The keys #39025 retired, with the values every earlier writer stored. *)
let with_retired_fields json =
  json
  |> add_field "last_handoff_ts" (`Float 0.0)
  |> add_field "trace_history" (`List [])
;;

let retired_field =
  Alcotest.testable
    (fun fmt field ->
       Format.pp_print_string
         fmt
         (Keeper_meta_json_current_schema.retired_field_name field))
    ( = )
;;

(* One-release tolerance (#39200): a file written before #39025 decodes, and
   the decoder reports each retired key it dropped exactly once. *)
let test_retired_fields_are_dropped_and_reported () =
  let current = valid_json () in
  match
    Keeper_meta_json_parse.decode_current_meta_json (with_retired_fields current)
  with
  | Error detail -> Alcotest.fail ("meta with retired fields was rejected: " ^ detail)
  | Ok { Keeper_meta_json_parse.decoded_meta; retired_fields } ->
    Alcotest.(check (list retired_field))
      "each retired key is reported once"
      Keeper_meta_json_current_schema.[ Trace_history; Last_handoff_ts ]
      retired_fields;
    let encode meta = Yojson.Safe.to_string (Keeper_meta_json.meta_to_json meta) in
    (match Keeper_meta_json_parse.meta_of_json current with
     | Error detail -> Alcotest.fail ("current meta was rejected: " ^ detail)
     | Ok current_meta ->
       Alcotest.(check string)
         "dropping the retired keys leaves the same meta as the current file"
         (encode current_meta)
         (encode decoded_meta))
;;

let test_current_meta_reports_no_retired_fields () =
  match Keeper_meta_json_parse.decode_current_meta_json (valid_json ()) with
  | Error detail -> Alcotest.fail ("current meta was rejected: " ^ detail)
  | Ok { Keeper_meta_json_parse.retired_fields; _ } ->
    Alcotest.(check (list retired_field)) "nothing dropped" [] retired_fields
;;

(* The tolerance names two keys and nothing else: an unknown key next to them
   still makes the file not current. *)
let test_unknown_field_beside_retired_fields_is_rejected () =
  valid_json ()
  |> with_retired_fields
  |> add_field "future_field" (`String "unsupported")
  |> check_rejected "unknown metadata field beside retired fields"
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
    ; ( "retired_fields"
      , [ Alcotest.test_case
            "retired fields are dropped and reported"
            `Quick
            test_retired_fields_are_dropped_and_reported
        ; Alcotest.test_case
            "current meta reports no retired fields"
            `Quick
            test_current_meta_reports_no_retired_fields
        ; Alcotest.test_case
            "unknown field beside retired fields is rejected"
            `Quick
            test_unknown_field_beside_retired_fields_is_rejected
        ] )
    ]
;;
