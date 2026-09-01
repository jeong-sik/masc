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
  [ "message_scope_ack_id"
  ; "usage_cursor"
  ; "last_usage_resolution"
  ; "last_runtime_attempt"
  ; "latched_reason"
  ; "current_task_id"
  ; "keeper_id"
  ]
;;

let test_current_writer_roundtrip_and_keyset () =
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

let test_current_writer_rejects_non_finite_values () =
  let meta =
    match Keeper_meta_json_parse.meta_of_json (current_json ()) with
    | Ok meta -> meta
    | Error detail -> Alcotest.fail detail
  in
  let invalid =
    { meta with
      runtime =
        { meta.runtime with
          usage =
            { meta.runtime.usage with total_cost_usd = Float.nan }
        }
    }
  in
  match Keeper_meta_json.current_write_json invalid with
  | Error detail ->
    check bool
      "write-side non-finite rejection is current-schema classified"
      true
      (Astring.String.is_infix ~affix:"must be finite" detail)
  | Ok _ -> Alcotest.fail "current writer accepted a non-finite value"
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

let test_retired_active_goal_ids_requires_reset () =
  expect_rejected
    "retired active_goal_ids"
    (current_json ()
     |> replace_field "active_goal_ids" (`List [ `String "goal-a" ]))
;;

let test_retired_compaction_failure_authority_requires_reset () =
  expect_rejected
    "retired compaction failure authority"
    (current_json ()
     |> replace_field "compaction_consecutive_failures" (`Int 3))
;;

let test_v1_requires_reset_and_v2_usage_state_roundtrips () =
  expect_rejected
    "v1 schema"
    (current_json () |> replace_field "schema" (`String "masc.keeper_meta.v1"));
  let sample : Keeper_usage_resolution.sample =
    { input_tokens = 160
    ; output_tokens = 20
    ; cache_creation_input_tokens = 4
    ; cache_read_input_tokens = 100
    ; cost_usd = Some 1.6
    }
  in
  let basis =
    Keeper_usage_resolution.Conversation_counter
      { runtime_id = "antigravity"
      ; conversation_id = "conversation-1"
      ; position = Keeper_usage_resolution.Resumed
      }
  in
  let resolution, cursor =
    Keeper_usage_resolution.resolve
      ~cursor:None
      ~basis
      ~observation:(Some sample)
      ~observed_at:1_700_000_000.0
  in
  let json =
    current_json ()
    |> replace_field
         "usage_cursor"
         (Option.fold
            ~none:`Null
            ~some:Keeper_usage_resolution.cursor_to_json
            cursor)
    |> replace_field
         "last_usage_resolution"
         (Keeper_usage_resolution.to_json resolution)
  in
  let inconsistent_resolution =
    match Keeper_usage_resolution.to_json resolution with
    | `Assoc fields ->
      `Assoc (("status", `String "exact") :: List.remove_assoc "status" fields)
    | _ -> fail "usage resolution encoder did not return an object"
  in
  expect_rejected
    "contradictory exact resolution"
    (json |> replace_field "last_usage_resolution" inconsistent_resolution);
  match Keeper_meta_json_parse.meta_of_json json with
  | Error detail -> failf "v2 usage state rejected: %s" detail
  | Ok meta ->
    check bool "cursor roundtrips" true (meta.runtime.usage_cursor = cursor);
    check bool
      "last resolution roundtrips"
      true
      (meta.runtime.last_usage_resolution = Some resolution)
;;

let () =
  run
    "keeper_meta_current_schema"
    [ ( "current-schema"
      , [ test_case "writer roundtrip and keyset" `Quick
            test_current_writer_roundtrip_and_keyset
        ; test_case "every field is required" `Quick
            test_every_current_field_is_required
        ; test_case "every duplicate is rejected" `Quick
            test_every_duplicate_is_rejected
        ; test_case "every field rejects a wrong type" `Quick
            test_every_field_rejects_a_wrong_type
        ; test_case "nullability is exact" `Quick
            test_nullability_is_exact
        ; test_case "outside fields share one classification" `Quick
            test_every_outside_field_has_one_classification
        ; test_case "retired active_goal_ids requires reset" `Quick
            test_retired_active_goal_ids_requires_reset
        ; test_case
            "retired compaction failure authority requires reset"
            `Quick
            test_retired_compaction_failure_authority_requires_reset
        ; test_case "writer rejects non-finite values" `Quick
            test_current_writer_rejects_non_finite_values
        ; test_case "v1 cut and v2 usage state roundtrip" `Quick
            test_v1_requires_reset_and_v2_usage_state_roundtrips
        ] )
    ]
;;
