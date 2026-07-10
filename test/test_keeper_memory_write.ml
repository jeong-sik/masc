(** Explicit keeper memory writes use a direct, typed persistence path. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Bank = Masc.Keeper_memory_bank

let make_args ~kind ~title ~content =
  `Assoc
    [ "kind", `String kind
    ; "title", `String title
    ; "content", `String content
    ]
;;

let error_label = Runtime.memory_write_error_kind_to_string

let assert_invalid ~expected = function
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string) "error kind" expected (error_label error_kind)
  | Runtime.Memory_write_ok _ ->
    Alcotest.failf "expected invalid memory write: %s" expected
;;

let assert_ok ~kind ~body = function
  | Runtime.Memory_write_ok valid ->
    Alcotest.(check string)
      "kind"
      kind
      (Bank.memory_kind_to_wire valid.kind);
    Alcotest.(check string) "body" body valid.body
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.failf "unexpected validation error: %s" (error_label error_kind)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "goal", `String "memory contract test"
        ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    let usage = { meta.runtime.usage with total_turns = 7 } in
    { meta with runtime = { meta.runtime with usage } }
;;

let json_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field: %s" key)
  | _ -> Alcotest.fail "expected JSON object"
;;

let string_field key json =
  match json_field key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field: %s" key
;;

let int_field key json =
  match json_field key json with
  | `Int value -> value
  | _ -> Alcotest.failf "expected int field: %s" key
;;

let only_jsonl_row path =
  let rows =
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  match rows with
  | [ row ] -> Yojson.Safe.from_string row
  | _ -> Alcotest.failf "expected one memory row, got %d" (List.length rows)
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"bogus" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"next" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"constraints" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"GOAL" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:" goal " ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"long_term" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"long_term_via_explicit_write_not_yet_supported";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:(String.make 121 'x') ~content:"body")
  |> assert_invalid ~expected:"title_too_long";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"none")
  |> assert_invalid ~expected:"content_rejected"
;;

let test_valid_body_has_no_intermediate_projection () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"decision" ~title:"hook" ~content:"body text")
  |> assert_ok ~kind:"decision" ~body:"**hook** body text";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"plain body")
  |> assert_ok ~kind:"goal" ~body:"plain body"
;;

let test_bank_rejects_nonwritable_kind () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "invalid-bank-write" in
  (match
     Bank.append_explicit_memory_note
       config
       meta
       ~turn:7
       ~kind:Bank.Long_term
       ~text:"reserved kind"
   with
   | Error (Bank.Explicit_memory_kind_not_writable Bank.Long_term) -> ()
   | _ -> Alcotest.fail "nonwritable kind must be rejected explicitly");
  match
    Bank.append_explicit_memory_note
      config
      meta
      ~turn:7
      ~kind:Bank.Goal
      ~text:"none"
  with
  | Error Bank.Rejected_explicit_memory_text -> ()
  | _ -> Alcotest.fail "filtered content must return a typed rejection"
;;

let test_tool_write_persists_typed_provenance () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "typed-provenance" in
  let response =
    Runtime.keeper_memory_write_json
      ~config
      ~meta
      ~args:(make_args ~kind:"decision" ~title:"choice" ~content:"Use typed rows")
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool) "write succeeds" true
    (match json_field "ok" response with `Bool value -> value | _ -> false);
  Alcotest.(check int) "one row" 1 (int_field "rows_written" response);
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let row = only_jsonl_row path in
  Alcotest.(check string)
    "typed source"
    "explicit_memory_write"
    (string_field "source" row);
  Alcotest.(check string) "kind" "decision" (string_field "kind" row);
  Alcotest.(check string) "horizon" "mid_term" (string_field "horizon" row);
  Alcotest.(check int) "turn comes from runtime usage SSOT" 7 (int_field "turn" row);
  Alcotest.(check string)
    "body"
    "**choice** Use typed rows"
    (string_field "text" row)
;;

let test_source_round_trip () =
  let source = Bank.Explicit_memory_write in
  let wire = Bank.memory_row_source_to_string source in
  Alcotest.(check string) "wire" "explicit_memory_write" wire;
  Alcotest.(check bool)
    "round trip"
    true
    (Bank.memory_row_source_of_string wire = source)
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "valid input remains a direct kind/body pair"
            `Quick
            test_valid_body_has_no_intermediate_projection
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "bank rejects nonwritable kinds"
            `Quick
            test_bank_rejects_nonwritable_kind
        ; Alcotest.test_case
            "tool write stores typed provenance"
            `Quick
            test_tool_write_persists_typed_provenance
        ; Alcotest.test_case "source round trips" `Quick test_source_round_trip
        ] )
    ]
;;
