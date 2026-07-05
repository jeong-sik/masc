(** Frontend tests for IDE diagnostics — covers pure functions from
    [Ide_annotation_types] and [Ide_event_types].

    Sources verified against:
    - lib/ide/ide_annotation_types.ml
    - lib/ide/ide_event_types.ml

    NOTE: serialization round-trip tests (annotation_to_json / of_json)
    require Yojson.Safe.t comparison. We test the building blocks
    (json_kind_name, string_opt_to_json, annotation_kind conversion)
    which are the most error-prone parts. *)

(* ── json_kind_name tests ────────────────────────────────────────── *)

let test_json_kind_name_null () =
  let result = Ide_annotation_types.json_kind_name `Null in
  Alcotest.(check string) "Null" "null" result
;;

let test_json_kind_name_bool () =
  let result = Ide_annotation_types.json_kind_name (`Bool true) in
  Alcotest.(check string) "Bool" "bool" result
;;

let test_json_kind_name_int () =
  let result = Ide_annotation_types.json_kind_name (`Int 42) in
  Alcotest.(check string) "Int" "int" result
;;

let test_json_kind_name_intlit () =
  let result = Ide_annotation_types.json_kind_name (`Intlit "999") in
  Alcotest.(check string) "Intlit" "intlit" result
;;

let test_json_kind_name_float () =
  let result = Ide_annotation_types.json_kind_name (`Float 3.14) in
  Alcotest.(check string) "Float" "float" result
;;

let test_json_kind_name_string () =
  let result = Ide_annotation_types.json_kind_name (`String "hello") in
  Alcotest.(check string) "String" "string" result
;;

let test_json_kind_name_assoc () =
  let result = Ide_annotation_types.json_kind_name (`Assoc []) in
  Alcotest.(check string) "Assoc" "object" result
;;

let test_json_kind_name_list () =
  let result = Ide_annotation_types.json_kind_name (`List []) in
  Alcotest.(check string) "List" "array" result
;;

(* ── string_opt_to_json tests ────────────────────────────────────── *)

let test_string_opt_none () =
  let result = Ide_annotation_types.string_opt_to_json None in
  Alcotest.(check bool) "None -> `Null" true (result = `Null)
;;

let test_string_opt_some () =
  let result = Ide_annotation_types.string_opt_to_json (Some "test") in
  Alcotest.(check bool) "Some -> `String" true (result = `String "test")
;;

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
    Alcotest.(check bool) "has id" true (List.mem "id" keys);
    Alcotest.(check bool) "has file_path" true (List.mem "file_path" keys);
    Alcotest.(check bool) "has line_start" true (List.mem "line_start" keys);
    Alcotest.(check bool) "has keeper_id" true (List.mem "keeper_id" keys);
    Alcotest.(check bool) "has kind" true (List.mem "kind" keys);
    Alcotest.(check bool) "has content" true (List.mem "content" keys);
    Alcotest.(check bool) "has created_at_ms" true (List.mem "created_at_ms" keys);
    Alcotest.(check int) "field count >= 15" 15 (List.length fields)
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
    Alcotest.(check bool) "board_post_id is Null" true
      (find "board_post_id" = `Null);
    Alcotest.(check bool) "pr_id is Null" true (find "pr_id" = `Null);
    Alcotest.(check bool) "goal_id is String" true
      (find "goal_id" = `String "goal-1")
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

(* ── test suite ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "IDE diagnostics"
    [ ( "json_kind_name"
      , [ Alcotest.test_case "Null" `Quick test_json_kind_name_null
        ; Alcotest.test_case "Bool" `Quick test_json_kind_name_bool
        ; Alcotest.test_case "Int" `Quick test_json_kind_name_int
        ; Alcotest.test_case "Intlit" `Quick test_json_kind_name_intlit
        ; Alcotest.test_case "Float" `Quick test_json_kind_name_float
        ; Alcotest.test_case "String" `Quick test_json_kind_name_string
        ; Alcotest.test_case "Assoc" `Quick test_json_kind_name_assoc
        ; Alcotest.test_case "List" `Quick test_json_kind_name_list
        ] )
    ; ( "string_opt_to_json"
      , [ Alcotest.test_case "None" `Quick test_string_opt_none
        ; Alcotest.test_case "Some" `Quick test_string_opt_some
        ] )
    ; ( "annotation_kind"
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
        ] )
    ]
;;