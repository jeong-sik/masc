open Alcotest

module KET = Masc_mcp.Keeper_exec_tools
module KES = Masc_mcp.Keeper_exec_shared

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
    Masc_test_deps.meta_of_json_fixture
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

let json_list_contains name = function
  | `List values ->
      List.exists
        (function
          | `String value -> String.equal value name
          | _ -> false)
        values
  | _ -> false

let json_contains_tool name = function
  | `Assoc fields ->
      List.exists (fun (_, value) -> json_list_contains name value) fields
  | _ -> false

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

let test_execute_with_outcome_policy_gate_is_failure () =
  with_exec_fixture
    ~tool_access:(Masc_mcp.Keeper_types.Custom [ "keeper_tools_list" ])
    "keeper_exec_tools_policy_gate"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_fs_read"
          ~input:(`Assoc [ ("path", `String "blocked.txt") ])
          ()
      in
      check string "policy gate outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "policy gate payload shape" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
      check string "policy gate error" "tool_not_allowed"
        Yojson.Safe.Util.(member "error" json |> to_string))

let counter_for_tool_not_allowed ~keeper ~tool ~reason =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_tool_not_allowed
    ~labels:[ ("keeper", keeper); ("tool", tool); ("reason", reason) ]
    ()

(* #13xxx: tool_not_allowed Prometheus counter *)
let test_tool_not_allowed_increments_counter () =
  (* A keeper with only keeper_tools_list allowed tries to call
     keeper_fs_read — should land in reason=not_in_allow_set. *)
  let keeper = "test-exec-tools-not-allowed-a" in
  let tool = "keeper_fs_read" in
  let reason = "not_in_allow_set" in
  with_exec_fixture
    ~tool_access:(Masc_mcp.Keeper_types.Custom [ "keeper_tools_list" ])
    "keeper_exec_tools_not_allowed_counter"
    (fun ~config ~meta ~ctx_work ->
      let before = counter_for_tool_not_allowed ~keeper ~tool ~reason in
      ignore
        (KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta:{ meta with name = keeper }
           ~ctx_work ~exec_cache:None
           ~name:tool
           ~input:(`Assoc [ ("path", `String "blocked.txt") ])
           ());
      check (float 0.0001) "not_in_allow_set counter +1"
        (before +. 1.0)
        (counter_for_tool_not_allowed ~keeper ~tool ~reason))

let test_tool_not_allowed_denied_by_policy_counter () =
  (* A keeper whose denylist contains keeper_board_post should land in
     reason=denied_by_policy. *)
  let keeper = "test-exec-tools-not-allowed-b" in
  let tool = "keeper_board_post" in
  let reason = "denied_by_policy" in
  (* Build meta that has board_post in the allowlist but also on the denylist
     so can_execute returns false via the deny-set path. *)
  let meta_with_deny =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ ("name", `String keeper)
          ; ("agent_name", `String keeper)
          ; ("trace_id", `String "test-not-allowed-b")
          ; ("allowed_paths", `List [ `String "*" ])
          ; ( "tool_access"
            , Masc_mcp.Keeper_types.tool_access_to_json
                (Masc_mcp.Keeper_types.Custom [ "keeper_board_post" ]) )
          ; ( "tool_denylist"
            , `List [ `String "keeper_board_post" ] )
          ])
    with
    | Ok m -> m
    | Error e -> failwith ("meta_of_json_fixture: " ^ e)
  in
  let dir =
    let d = Filename.temp_file "keeper_exec_not_allowed_b" "" in
    Unix.unlink d; Unix.mkdir d 0o755; d
  in
  let cleanup () =
    let rec rm t =
      if Sys.file_exists t then
        if Sys.is_directory t then begin
          Sys.readdir t |> Array.iter (fun n -> rm (Filename.concat t n));
          Unix.rmdir t
        end else Unix.unlink t
    in
    try rm dir with _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Masc_mcp.Coord.default_config dir in
    let before = counter_for_tool_not_allowed ~keeper ~tool ~reason in
    ignore
      (KET.execute_keeper_tool_call_with_outcome
         ~config ~meta:meta_with_deny ~ctx_work:(make_ctx ())
         ~exec_cache:None ~name:tool ~input:(`Assoc []) ());
    check (float 0.0001) "denied_by_policy counter +1"
      (before +. 1.0)
      (counter_for_tool_not_allowed ~keeper ~tool ~reason))

let test_tool_not_allowed_reason_label_is_bounded () =
  (* Verify that the reason label written into the JSON payload is one
     of the three bounded vocabulary values, not a free-form string. *)
  with_exec_fixture
    ~tool_access:(Masc_mcp.Keeper_types.Custom [ "keeper_tools_list" ])
    "keeper_exec_tools_reason_bounded"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_fs_read"
          ~input:(`Assoc [ ("path", `String "x") ])
          ()
      in
      let json = Yojson.Safe.from_string result.raw_output in
      let reason = Yojson.Safe.Util.(member "reason" json |> to_string) in
      let valid = [ "not_in_candidate_set"; "denied_by_policy"; "not_in_allow_set" ] in
      check bool "reason label is bounded vocabulary"
        true (List.mem reason valid))

let test_keeper_tools_list_json_uses_typed_groups () =
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "keeper_board_post";
             "keeper_board_fake";
             "keeper_voice_speak";
             "keeper_task_claim";
             "keeper_shell";
             "keeper_fs_read";
             "keeper_memory_search";
           ])
      ()
  in
  let json = Yojson.Safe.from_string (KES.keeper_tools_list_json ~meta) in
  let member group name =
    json_list_contains name Yojson.Safe.Util.(member group json)
  in
  check bool "board canonical tool grouped" true
    (member "board" "keeper_board_post");
  check bool "fake board-looking tool excluded" false
    (json_contains_tool "keeper_board_fake" json);
  check bool "voice tool grouped" true
    (member "voice" "keeper_voice_speak");
  check bool "task tool grouped as coordination" true
    (member "coordination" "keeper_task_claim");
  check bool "shell tool grouped" true
    (member "shell" "keeper_shell");
  check bool "fs tool grouped" true
    (member "fs" "keeper_fs_read");
  check bool "memory tool grouped" true
    (member "memory" "keeper_memory_search")

let test_execute_with_outcome_missing_file_is_failure () =
  with_exec_fixture "keeper_exec_tools_missing_file"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
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
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_tool_search"
          ~input:(`Assoc [ ("query", `String "") ])
          ()
      in
      check string "bad query outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "bad query payload shape" "structured_error"
        (payload_kind result.payload_shape))

let test_preflight_structured_block_is_execution_success () =
  with_exec_fixture "keeper_exec_tools_preflight_block"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_preflight_check"
          ~input:(`Assoc [])
          ()
      in
      check string "preflight outcome" "success"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "raw diagnostic shape still blocks" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
      check bool "preflight raw ok=false preserved" false
        Yojson.Safe.Util.(member "ok" json |> to_bool))

let registered_dispatch_probe_tool = "test_keeper_registered_dispatch_probe"

let register_registered_dispatch_probe () =
  Masc_mcp.Tool_dispatch.register_name_tag
    ~tool_name:registered_dispatch_probe_tool
    ~tag:Masc_mcp.Tool_dispatch.Mod_misc;
  Masc_mcp.Tool_dispatch.register
    ~tool_name:registered_dispatch_probe_tool
    ~handler:(fun ~name ~args:_ ->
      Some
        ( true
        , Yojson.Safe.to_string
            (`Assoc
              [ ("ok", `Bool true)
              ; ("tool", `String name)
              ; ("route", `String "registered")
              ]) ))

let test_registered_tool_dispatch_without_masc_prefix () =
  register_registered_dispatch_probe ();
  check bool "probe has no masc_ prefix" false
    (String.starts_with ~prefix:"masc_" registered_dispatch_probe_tool);
  with_exec_fixture "keeper_exec_registered_dispatch"
    (fun ~config ~meta ~ctx_work:_ ->
      match
        Masc_mcp.Keeper_exec_masc.handle_registered_keeper_tool
          ~config
          ~keeper_name:meta.name
          ~name:registered_dispatch_probe_tool
          ~args:(`Assoc [])
      with
      | None -> fail "expected registered keeper tool dispatch"
      | Some raw ->
        let json = Yojson.Safe.from_string raw in
        check string "registered tool name" registered_dispatch_probe_tool
          Yojson.Safe.Util.(member "tool" json |> to_string);
        check string "registered route" "registered"
          Yojson.Safe.Util.(member "route" json |> to_string))

(* ── Exec cache integration tests ──────────────────────────── *)

let test_exec_cache_miss_then_hit () =
  with_exec_fixture "keeper_exec_cache_hit"
    (fun ~config ~meta ~ctx_work ->
      let cache = Masc_exec.Exec_cache.create () in
      let result1 =
        KET.execute_keeper_tool_call
          ~config ~meta ~ctx_work ~exec_cache:(Some cache)
          ~name:"keeper_bash"
          ~input:(`Assoc [ ("cmd", `String "echo hello_cache_test") ])
          ()
      in
      let json1 = Yojson.Safe.from_string result1 in
      (* First call: no cached field *)
      check bool "first call not cached"
        true
        (match Yojson.Safe.Util.member "cached" json1 with
         | `Bool true -> false
         | _ -> true);
      (* Second call with same command: should hit cache *)
      let result2 =
        KET.execute_keeper_tool_call
          ~config ~meta ~ctx_work ~exec_cache:(Some cache)
          ~name:"keeper_bash"
          ~input:(`Assoc [ ("cmd", `String "echo hello_cache_test") ])
          ()
      in
      let json2 = Yojson.Safe.from_string result2 in
      check bool "second call cached"
        true
        (match Yojson.Safe.Util.member "cached" json2 with
         | `Bool true -> true
         | _ -> false);
      (* Cache stats: 1 hit, 1 miss *)
      let hits, misses = Masc_exec.Exec_cache.stats cache in
      check int "cache hits" 1 hits;
      check int "cache misses" 1 misses)

let test_exec_cache_none_no_caching () =
  with_exec_fixture "keeper_exec_cache_none"
    (fun ~config ~meta ~ctx_work ->
      (* With exec_cache=None, two identical calls both execute *)
      let result1 =
        KET.execute_keeper_tool_call
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_bash"
          ~input:(`Assoc [ ("cmd", `String "echo no_cache_test") ])
          ()
      in
      let json1 = Yojson.Safe.from_string result1 in
      let result2 =
        KET.execute_keeper_tool_call
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_bash"
          ~input:(`Assoc [ ("cmd", `String "echo no_cache_test") ])
          ()
      in
      let json2 = Yojson.Safe.from_string result2 in
      (* Neither should have cached:true *)
      check bool "first call not cached"
        true
        (match Yojson.Safe.Util.member "cached" json1 with
         | `Bool true -> false
         | _ -> true);
      check bool "second call not cached"
        true
        (match Yojson.Safe.Util.member "cached" json2 with
         | `Bool true -> false
         | _ -> true))

let test_exec_cache_stats_json () =
  let cache = Masc_exec.Exec_cache.create () in
  let json = Masc_exec.Exec_cache.to_json cache in
  check int "initial hit_count" 0
    Yojson.Safe.Util.(member "hit_count" json |> to_int);
  check int "initial miss_count" 0
    Yojson.Safe.Util.(member "miss_count" json |> to_int);
  check int "initial entry_count" 0
    Yojson.Safe.Util.(member "entry_count" json |> to_int);
  (* Store an entry and check *)
  Masc_exec.Exec_cache.store cache ~cmd:"test_cmd" ~exit_code:0
    ~output:"test output" ~duration_ms:100;
  let json2 = Masc_exec.Exec_cache.to_json cache in
  check int "after store entry_count" 1
    Yojson.Safe.Util.(member "entry_count" json2 |> to_int);
  (* Lookup triggers a hit *)
  ignore (Masc_exec.Exec_cache.lookup cache "test_cmd");
  let json3 = Masc_exec.Exec_cache.to_json cache in
  check int "after lookup hit_count" 1
    Yojson.Safe.Util.(member "hit_count" json3 |> to_int)

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
      test_case "policy gate is failure" `Quick
        test_execute_with_outcome_policy_gate_is_failure;
      test_case "missing file is failure" `Quick
        test_execute_with_outcome_missing_file_is_failure;
      test_case "bad query is failure" `Quick
        test_execute_with_outcome_bad_query_is_failure;
      test_case "preflight block is execution success" `Quick
        test_preflight_structured_block_is_execution_success;
      test_case "registered dispatch does not require masc_ prefix" `Quick
        test_registered_tool_dispatch_without_masc_prefix;
    ]);
    ("tool_not_allowed_counter", [
      test_case "increments for not_in_allow_set" `Quick
        test_tool_not_allowed_increments_counter;
      test_case "increments for denied_by_policy" `Quick
        test_tool_not_allowed_denied_by_policy_counter;
      test_case "reason label is bounded vocabulary" `Quick
        test_tool_not_allowed_reason_label_is_bounded;
    ]);
    ("keeper_tools_list_json", [
      test_case "uses typed groups" `Quick
        test_keeper_tools_list_json_uses_typed_groups;
    ]);
    ("exec_cache", [
      test_case "miss then hit" `Quick test_exec_cache_miss_then_hit;
      test_case "no cache when None" `Quick test_exec_cache_none_no_caching;
      test_case "stats json" `Quick test_exec_cache_stats_json;
    ]);
  ]
