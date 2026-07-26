(** Exhaustive current Keeper-meta schema conformance proof. *)

open Alcotest
open Masc

let current_json () =
  Masc_test_deps.current_meta_json_fixture ~name:"current-meta" ()
;;

let fields_exn = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "current fixture must be an object"
;;

let replace_field name value json =
  let fields = fields_exn json in
  `Assoc ((name, value) :: List.remove_assoc name fields)
;;

let remove_field name json =
  `Assoc (List.remove_assoc name (fields_exn json))
;;

let duplicate_field name json =
  let fields = fields_exn json in
  `Assoc ((name, List.assoc name fields) :: fields)
;;

let expect_rejected label json =
  match Keeper_meta_json_parse.meta_of_json json with
  | Error detail ->
    check bool (label ^ " has stable classification") true
      (Astring.String.is_prefix
         ~affix:"invalid current keeper meta:"
         detail);
    check bool (label ^ " requires reset") true
      (Astring.String.is_infix ~affix:"runtime reset required" detail)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" label
;;

let expect_current label json =
  match Keeper_meta_json_parse.meta_of_json json with
  | Ok _ -> ()
  | Error detail -> Alcotest.failf "%s rejected: %s" label detail
;;

let wrong_value = function
  | `Bool _ -> `String "not-a-boolean"
  | `Float _ | `Int _ | `Intlit _ -> `String "not-a-number"
  | `String _ -> `Bool false
  | `List _ | `Assoc _ | `Null -> `Bool false
;;

let nullable_field_names =
  [ "persona"
  ; "message_scope_ack_id"
  ; "last_blocker"
  ; "last_runtime_attempt"
  ; "latched_reason"
  ; "current_task_id"
  ; "keeper_id"
  ]
;;

let test_current_writer_roundtrip_and_keyset () =
  check int
    "current schema has 54 fields"
    54
    (List.length Keeper_meta_json.current_field_names);
  let meta =
    match Keeper_meta_json_parse.meta_of_json (current_json ()) with
    | Ok meta -> meta
    | Error detail -> Alcotest.fail detail
  in
  let writer_fields = Keeper_meta_json.meta_to_json meta |> fields_exn in
  let expected = List.sort String.compare Keeper_meta_json.current_field_names in
  let actual = List.map fst writer_fields |> List.sort String.compare in
  check (list string) "writer emits exactly the current key set" expected actual;
  expect_current "writer roundtrip" (Keeper_meta_json.meta_to_json meta)
;;

let test_every_current_field_is_required () =
  List.iter
    (fun key ->
       expect_rejected
         ("missing " ^ key)
         (current_json () |> remove_field key))
    Keeper_meta_json.current_field_names
;;

let test_every_duplicate_is_rejected () =
  List.iter
    (fun key ->
       expect_rejected
         ("duplicate " ^ key)
         (current_json () |> duplicate_field key))
    Keeper_meta_json.current_field_names
;;

let test_every_field_rejects_a_wrong_type () =
  current_json ()
  |> fields_exn
  |> List.iter (fun (key, value) ->
    expect_rejected
      ("wrong type " ^ key)
      (current_json () |> replace_field key (wrong_value value)))
;;

let test_nullability_is_exact () =
  List.iter
    (fun key ->
       let json = current_json () |> replace_field key `Null in
       if List.mem key nullable_field_names
       then expect_current ("nullable " ^ key) json
       else expect_rejected ("non-null " ^ key) json)
    Keeper_meta_json.current_field_names
;;

let test_every_outside_field_has_one_classification () =
  [ "outside_current_a"; "outside_current_b" ]
  |> List.iter (fun key ->
    expect_rejected
      ("outside current " ^ key)
      (current_json () |> replace_field key (`String "ignored-value")))
;;

let () =
  run
    "keeper_meta_current_schema"
    [ ( "current-schema"
      , [ test_case "writer roundtrip and keyset" `Quick
            test_current_writer_roundtrip_and_keyset
        ; test_case "all 54 fields are required" `Quick
            test_every_current_field_is_required
        ; test_case "all 54 duplicate fields reject" `Quick
            test_every_duplicate_is_rejected
        ; test_case "all 54 fields reject a wrong type" `Quick
            test_every_field_rejects_a_wrong_type
        ; test_case "nullability is exact" `Quick
            test_nullability_is_exact
        ; test_case "outside fields share one classification" `Quick
            test_every_outside_field_has_one_classification
        ] )
    ]
;;
