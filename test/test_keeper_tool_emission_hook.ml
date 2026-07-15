(* Keeper tool-emission capture accepts only producer-owned typed objects.
   JSON-looking text from the model-facing OAS body is never reparsed. *)

module H = Masc.Keeper_tool_emission_hook

let assert_size label expected acc =
  Alcotest.(check int) label expected (H.accumulator_size acc)
;;

let tagged ~kind ~id fields =
  `Assoc
    ([ Multimodal.Tool_emission.multimodal_kind_key, `String kind
     ; Multimodal.Tool_emission.multimodal_id_key, `String id
     ]
     @ fields)
;;

let test_typed_object_is_captured () =
  let acc = H.create_accumulator () in
  H.capture_typed_result
    acc
    (tagged ~kind:"code" ~id:"typed" [ "source", `String "x" ]);
  assert_size "typed object" 1 acc
;;

let test_json_looking_string_is_opaque () =
  let acc = H.create_accumulator () in
  H.capture_typed_result
    acc
    (`String
      {|{"__multimodal_kind":"code","__multimodal_id":"fabricated"}|});
  assert_size "opaque string" 0 acc
;;

let test_non_object_typed_values_are_ignored () =
  let acc = H.create_accumulator () in
  List.iter
    (H.capture_typed_result acc)
    [ `Null; `Bool true; `Int 1; `List [ `String "not an artifact" ] ];
  assert_size "non-object values" 0 acc
;;

let test_drain_empties_accumulator () =
  let acc = H.create_accumulator () in
  H.capture_typed_result
    acc
    (tagged ~kind:"code" ~id:"code-1" [ "source", `String "x" ]);
  H.capture_typed_result
    acc
    (tagged ~kind:"image" ~id:"image-1" [ "data_url", `String "data:..." ]);
  assert_size "before drain" 2 acc;
  let context = H.drain_into_working_context acc ~working_context:None in
  let artifacts, _ =
    match Multimodal.Wirein_helpers.extract_raw_artifacts context with
    | Ok value -> value
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int) "emitted" 2 (List.length artifacts);
  assert_size "after drain" 0 acc
;;

let test_snapshot_does_not_drain () =
  let acc = H.create_accumulator () in
  H.capture_typed_result acc (tagged ~kind:"doc" ~id:"01900000-0000-7000-8000-000000000001" []);
  Alcotest.(check int) "snapshot" 1 (List.length (H.snapshot acc));
  Alcotest.(check int) "artifact refs" 1 (Result.get_ok (H.snapshot_artifact_refs acc) |> List.length);
  assert_size "snapshot preserves" 1 acc
;;

let test_drain_skips_unmarked_object () =
  let acc = H.create_accumulator () in
  H.capture_typed_result acc (tagged ~kind:"doc" ~id:"doc-2" []);
  H.capture_typed_result acc (`Assoc [ "echo", `String "hello" ]);
  let context = H.drain_into_working_context acc ~working_context:None in
  let artifacts, _ =
    match Multimodal.Wirein_helpers.extract_raw_artifacts context with
    | Ok value -> value
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int) "only marked object" 1 (List.length artifacts)
;;

let test_registry_isolates_keepers () =
  let suffix = string_of_int (Unix.getpid ()) in
  let alpha = "emission-alpha-" ^ suffix in
  let beta = "emission-beta-" ^ suffix in
  H.drop_keeper_accumulator alpha;
  H.drop_keeper_accumulator beta;
  H.capture_typed_result_for_keeper
    ~keeper_name:alpha
    (tagged ~kind:"code" ~id:"alpha" []);
  assert_size "alpha" 1 (H.accumulator_for_keeper alpha);
  assert_size "beta" 0 (H.accumulator_for_keeper beta);
  H.drop_keeper_accumulator alpha;
  H.drop_keeper_accumulator beta
;;

let test_registry_get_or_create_and_drop () =
  let name = "emission-registry-" ^ string_of_int (Unix.getpid ()) in
  H.drop_keeper_accumulator name;
  let first = H.accumulator_for_keeper name in
  let second = H.accumulator_for_keeper name in
  Alcotest.(check bool) "same accumulator" true (first == second);
  H.drop_keeper_accumulator name;
  let replacement = H.accumulator_for_keeper name in
  Alcotest.(check bool) "fresh after drop" false (first == replacement);
  H.drop_keeper_accumulator name
;;

let () =
  Alcotest.run
    "keeper_tool_emission"
    [ ( "typed capture"
      , [ Alcotest.test_case "typed object captured" `Quick test_typed_object_is_captured
        ; Alcotest.test_case
            "JSON-looking string stays opaque"
            `Quick
            test_json_looking_string_is_opaque
        ; Alcotest.test_case
            "non-object typed values ignored"
            `Quick
            test_non_object_typed_values_are_ignored
        ; Alcotest.test_case "drain empties" `Quick test_drain_empties_accumulator
        ; Alcotest.test_case "snapshot preserves" `Quick test_snapshot_does_not_drain
        ; Alcotest.test_case
            "unmarked object not emitted"
            `Quick
            test_drain_skips_unmarked_object
        ] )
    ; ( "keeper registry"
      , [ Alcotest.test_case "isolates keepers" `Quick test_registry_isolates_keepers
        ; Alcotest.test_case
            "get create and drop"
            `Quick
            test_registry_get_or_create_and_drop
        ] )
    ]
;;
