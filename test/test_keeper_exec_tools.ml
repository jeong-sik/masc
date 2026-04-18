open Alcotest

module KET = Masc_mcp.Keeper_exec_tools

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target
        |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end else
        Unix.unlink target
  in
  try rm path with _ -> ()

let make_meta ?(name = "keeper-exec-tools") ?tool_access () =
  let tool_access =
    match tool_access with
    | Some value -> value
    | None ->
        Masc_mcp.Keeper_types.Preset
          { preset = Masc_mcp.Keeper_types.Full; also_allow = [] }
  in
  match
    Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String "keeper-exec-tools-trace");
          ("allowed_paths", `List [ `String "*" ]);
          ( "tool_access",
            Masc_mcp.Keeper_types.tool_access_to_json tool_access );
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc_mcp.Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let with_exec_fixture ?tool_access name fn =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc_mcp.Coord.default_config dir in
      let meta = make_meta ?tool_access () in
      fn ~config ~meta ~ctx_work:(make_ctx ()))

let payload_kind = function
  | KET.Structured_success -> "structured_success"
  | KET.Structured_error -> "structured_error"
  | KET.Plain_text -> "plain_text"
  | KET.Malformed_structured _ -> "malformed_structured"

let check_kind ~msg expected payload =
  check string msg expected
    (payload_kind (KET.classify_tool_result_payload payload))

let test_plain_text_is_success_shape () =
  check_kind
    ~msg:"plain text stays plain_text"
    "plain_text"
    "## Search Results\n\n- keeper_fs_read"

let test_plain_text_with_leading_whitespace_stays_plain () =
  check_kind
    ~msg:"leading whitespace plain text stays plain_text"
    "plain_text"
    "  completed successfully"

let test_structured_success_json () =
  check_kind
    ~msg:"ok=true object is structured_success"
    "structured_success"
    {|{"ok":true,"result":"done"}|}

let test_structured_error_json () =
  check_kind
    ~msg:"error object is structured_error"
    "structured_error"
    {|{"ok":false,"error":"boom"}|}

let test_structured_array_counts_as_success_shape () =
  check_kind
    ~msg:"json array remains structured_success"
    "structured_success"
    {|[{"task_id":"T-1"}]|}

let test_malformed_json_like_payload_detected () =
  match KET.classify_tool_result_payload {|{"ok":true|} with
  | KET.Malformed_structured detail ->
    check bool "detail mentions JSON parse error"
      true (String.length detail > 0)
  | other ->
    fail
      (Printf.sprintf "expected malformed_structured, got %s"
         (payload_kind other))

let test_execute_with_outcome_policy_gate_is_non_failure () =
  with_exec_fixture
    ~tool_access:(Masc_mcp.Keeper_types.Custom [ "keeper_tools_list" ])
    "keeper_exec_tools_policy_gate"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_read"
          ~input:(`Assoc [ ("path", `String "blocked.txt") ])
          ()
      in
      check string "policy gate outcome" "success"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "policy gate payload shape" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
      check string "policy gate error" "tool_not_allowed"
        Yojson.Safe.Util.(member "error" json |> to_string))

let test_execute_with_outcome_missing_file_is_failure () =
  with_exec_fixture "keeper_exec_tools_missing_file"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_read"
          ~input:(`Assoc [ ("path", `String "missing.txt") ])
          ()
      in
      check string "missing file outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "missing file payload shape" "structured_error"
        (payload_kind result.payload_shape))

let test_execute_with_outcome_bad_query_is_failure () =
  with_exec_fixture "keeper_exec_tools_bad_query"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work
          ~name:"keeper_tool_search"
          ~input:(`Assoc [ ("query", `String "") ])
          ()
      in
      check string "bad query outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "bad query payload shape" "structured_error"
        (payload_kind result.payload_shape))

let call_keeper_fs_edit ~config ~meta ~ctx_work args =
  KET.execute_keeper_tool_call_with_outcome
    ~config ~meta ~ctx_work
    ~name:"keeper_fs_edit"
    ~input:(`Assoc args)
    ()

let parse_result_json (result : KET.executed_tool_result) =
  Yojson.Safe.from_string result.raw_output

let test_keeper_fs_edit_empty_mode_uses_overwrite () =
  with_exec_fixture "keeper_exec_tools_fs_empty_mode"
    (fun ~config ~meta ~ctx_work ->
      let path = "notes.txt" in
      let first =
        call_keeper_fs_edit ~config ~meta ~ctx_work
          [ ("path", `String path); ("content", `String "old") ]
      in
      check string "first outcome" "success"
        (match first.outcome with `Success -> "success" | `Failure -> "failure");
      let second =
        call_keeper_fs_edit ~config ~meta ~ctx_work
          [ ("path", `String path); ("content", `String "new"); ("mode", `String "") ]
      in
      check string "second outcome" "success"
        (match second.outcome with `Success -> "success" | `Failure -> "failure");
      let json = parse_result_json second in
      check string "empty mode reports overwrite" "overwrite"
        Yojson.Safe.Util.(member "mode" json |> to_string);
      let target = Yojson.Safe.Util.(member "path" json |> to_string) in
      check string "content overwritten" "new"
        (Stdlib.In_channel.with_open_bin target Stdlib.In_channel.input_all))

let test_keeper_fs_edit_append_mode_appends () =
  with_exec_fixture "keeper_exec_tools_fs_append_mode"
    (fun ~config ~meta ~ctx_work ->
      let path = "append.txt" in
      let first =
        call_keeper_fs_edit ~config ~meta ~ctx_work
          [ ("path", `String path); ("content", `String "hello") ]
      in
      check string "seed write outcome" "success"
        (match first.outcome with `Success -> "success" | `Failure -> "failure");
      let second =
        call_keeper_fs_edit ~config ~meta ~ctx_work
          [ ("path", `String path); ("content", `String "\nworld"); ("mode", `String "append") ]
      in
      check string "append outcome" "success"
        (match second.outcome with `Success -> "success" | `Failure -> "failure");
      let json = parse_result_json second in
      check string "append mode reported" "append"
        Yojson.Safe.Util.(member "mode" json |> to_string);
      let target = Yojson.Safe.Util.(member "path" json |> to_string) in
      check string "content appended" "hello\nworld"
        (Stdlib.In_channel.with_open_bin target Stdlib.In_channel.input_all))

let () =
  Masc_test_deps.init_keeper_tool_registry ();
  ignore
    (Result.get_ok
       (KET.init_policy_config ~base_path:(Masc_test_deps.find_project_root ())));
  run "Keeper_exec_tools" [
    ("classify_tool_result_payload", [
      test_case "plain text" `Quick test_plain_text_is_success_shape;
      test_case "plain text with leading whitespace" `Quick
        test_plain_text_with_leading_whitespace_stays_plain;
      test_case "structured success object" `Quick
        test_structured_success_json;
      test_case "structured error object" `Quick
        test_structured_error_json;
      test_case "structured array" `Quick
        test_structured_array_counts_as_success_shape;
      test_case "malformed json-like payload" `Quick
        test_malformed_json_like_payload_detected;
    ]);
    ("execute_keeper_tool_call_with_outcome", [
      test_case "policy gate stays non-failure" `Quick
        test_execute_with_outcome_policy_gate_is_non_failure;
      test_case "missing file is failure" `Quick
        test_execute_with_outcome_missing_file_is_failure;
      test_case "bad query is failure" `Quick
        test_execute_with_outcome_bad_query_is_failure;
      test_case "keeper_fs_edit empty mode overwrites" `Quick
        test_keeper_fs_edit_empty_mode_uses_overwrite;
      test_case "keeper_fs_edit append mode appends" `Quick
        test_keeper_fs_edit_append_mode_appends;
    ]);
  ]
