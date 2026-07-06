(** Frontend tests for IDE diagnostics — covers the public JSON contract from
    [Ide_annotation_types].

    Sources verified against:
    - lib/ide/ide_annotation_types.ml

    Tests intentionally use only values exported by the interface. *)

let yojson = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

(* ── annotation_kind round-trip tests ────────────────────────────── *)

let kinds =
  [ Ide_annotation_types.Comment
  ; Ide_annotation_types.Decision
  ; Ide_annotation_types.Question
  ; Ide_annotation_types.Bookmark
  ]
;;

let expected_strings = [ "Comment"; "Decision"; "Question"; "Bookmark" ]

let test_annotation_kind_to_string () =
  let results = List.map Ide_annotation_types.annotation_kind_to_string kinds in
  Alcotest.(check (list string)) "to_string" expected_strings results
;;

let test_annotation_kind_of_string_valid () =
  let results =
    List.map Ide_annotation_types.annotation_kind_of_string expected_strings
  in
  List.iter2
    (fun kind result ->
      match result with
      | Some k ->
        Alcotest.(check bool) "round-trip preserves kind" true (k = kind)
      | None -> Alcotest.fail "of_string returned None for valid string")
    kinds results
;;

let test_annotation_kind_of_string_invalid () =
  let result = Ide_annotation_types.annotation_kind_of_string "Nonexistent" in
  Alcotest.(check (option string)) "invalid -> None" None
    (Option.map (fun _ -> "") result)
;;

(* ── annotation_to_json field presence tests ─────────────────────── *)

let make_test_annotation () =
  { Ide_annotation_types.id = "ann-001"
  ; file_path = "lib/test.ml"
  ; line_start = 10
  ; line_end = 15
  ; keeper_id = "rondo"
  ; kind = Ide_annotation_types.Comment
  ; content = "test annotation"
  ; goal_id = Some "goal-1"
  ; task_id = Some "task-1"
  ; board_post_id = None
  ; comment_id = None
  ; pr_id = None
  ; git_ref = None
  ; log_id = None
  ; session_id = None
  ; operation_id = None
  ; worker_run_id = None
  ; created_at_ms = 1700000000000L
  ; updated_at_ms = 1700000000000L
  }
;;

let test_annotation_to_json_has_required_fields () =
  let json = Ide_annotation_types.annotation_to_json (make_test_annotation ()) in
  match json with
  | `Assoc fields ->
    let keys = List.map fst fields in
    Alcotest.(check (list string)) "annotation JSON keys"
      [ "id"
      ; "file_path"
      ; "line_start"
      ; "line_end"
      ; "keeper_id"
      ; "kind"
      ; "content"
      ; "goal_id"
      ; "task_id"
      ; "board_post_id"
      ; "comment_id"
      ; "pr_id"
      ; "git_ref"
      ; "log_id"
      ; "session_id"
      ; "operation_id"
      ; "worker_run_id"
      ; "created_at_ms"
      ; "updated_at_ms"
      ]
      keys
  | _ -> Alcotest.fail "annotation_to_json did not produce Assoc"
;;

let test_annotation_to_json_optional_fields_null_when_none () =
  let a = make_test_annotation () in
  let json = Ide_annotation_types.annotation_to_json a in
  match json with
  | `Assoc fields ->
    let find key =
      List.assoc_opt key fields |> Option.value ~default:`Null
    in
    Alcotest.check yojson "board_post_id is Null" `Null (find "board_post_id");
    Alcotest.check yojson "pr_id is Null" `Null (find "pr_id");
    Alcotest.check yojson "goal_id is String" (`String "goal-1") (find "goal_id")
  | _ -> Alcotest.fail "annotation_to_json did not produce Assoc"
;;

let test_annotation_to_json_kind_is_string () =
  let a = make_test_annotation () in
  let json = Ide_annotation_types.annotation_to_json a in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String s) ->
      Alcotest.(check string) "kind string" "Comment" s
     | _ -> Alcotest.fail "kind field is not a String")
  | _ -> Alcotest.fail "annotation_to_json did not produce Assoc"
;;

let test_annotation_json_round_trip () =
  let original = make_test_annotation () in
  match
    original
    |> Ide_annotation_types.annotation_to_json
    |> Ide_annotation_types.annotation_of_json
  with
  | Ok parsed ->
    Alcotest.(check bool) "annotation round-trip preserves record" true
      (parsed = original)
  | Error msg ->
    Alcotest.failf "annotation_of_json rejected annotation_to_json output: %s" msg
;;

let test_annotation_of_json_rejects_non_object () =
  match Ide_annotation_types.annotation_of_json (`List []) with
  | Error msg ->
    Alcotest.(check string) "non-object diagnostic"
      "Expected JSON object for annotation, got array"
      msg
  | Ok _ ->
    Alcotest.fail "annotation_of_json accepted a non-object"
;;

let test_region_json_round_trip_tool_call () =
  let original =
    { Ide_annotation_types.file_path = "lib/server.ml"
    ; line_start = 7
    ; line_end = 9
    ; keeper_id = "rondo"
    ; source = Ide_annotation_types.Tool_call { tool_name = "masc_status"; turn = 42 }
    ; timestamp_ms = 1700000000123L
    }
  in
  match
    original
    |> Ide_annotation_types.region_to_json
    |> Ide_annotation_types.region_of_json
  with
  | Ok parsed ->
    Alcotest.(check bool) "tool-call region round-trip preserves record" true
      (parsed = original)
  | Error msg ->
    Alcotest.failf "region_of_json rejected region_to_json output: %s" msg
;;

let test_region_json_round_trip_manual () =
  let original =
    { Ide_annotation_types.file_path = "lib/manual.ml"
    ; line_start = 1
    ; line_end = 1
    ; keeper_id = "nova"
    ; source = Ide_annotation_types.Manual { note = "operator bookmark" }
    ; timestamp_ms = 1700000000999L
    }
  in
  match
    original
    |> Ide_annotation_types.region_to_json
    |> Ide_annotation_types.region_of_json
  with
  | Ok parsed ->
    Alcotest.(check bool) "manual region round-trip preserves record" true
      (parsed = original)
  | Error msg ->
    Alcotest.failf "region_of_json rejected region_to_json output: %s" msg
;;

(* ── test suite ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "IDE diagnostics"
    [ ( "annotation_kind"
      , [ Alcotest.test_case "to_string" `Quick test_annotation_kind_to_string
        ; Alcotest.test_case "of_string valid" `Quick
            test_annotation_kind_of_string_valid
        ; Alcotest.test_case "of_string invalid" `Quick
            test_annotation_kind_of_string_invalid
        ] )
    ; ( "annotation_to_json"
      , [ Alcotest.test_case "required fields" `Quick
            test_annotation_to_json_has_required_fields
        ; Alcotest.test_case "optional null" `Quick
            test_annotation_to_json_optional_fields_null_when_none
        ; Alcotest.test_case "kind is string" `Quick
            test_annotation_to_json_kind_is_string
        ; Alcotest.test_case "round-trip" `Quick test_annotation_json_round_trip
        ] )
    ; ( "annotation_of_json"
      , [ Alcotest.test_case "rejects non-object" `Quick
            test_annotation_of_json_rejects_non_object
        ] )
    ; ( "region_json"
      , [ Alcotest.test_case "tool-call round-trip" `Quick
            test_region_json_round_trip_tool_call
        ; Alcotest.test_case "manual round-trip" `Quick
            test_region_json_round_trip_manual
        ] )
    ]
;;
