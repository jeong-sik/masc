(** Tests for Keeper_tools_oas — OAS Tool.t wrapping of keeper tools. *)

open Agent_sdk
open Alcotest
open Masc_mcp

let autoresearch_allowlist =
  ["masc_autoresearch_start"; "masc_autoresearch_cycle";
   "masc_autoresearch_status"; "masc_autoresearch_stop";
   "masc_autoresearch_inject"]

let make_test_meta ?(name = "test-keeper") ?(preset = Keeper_types.Full)
    ?(also_allow = []) ?tool_access ()
    : Keeper_types.keeper_meta =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None -> Keeper_types.Preset { preset; also_allow }
  in
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-001");
             ("allowed_paths", `List [`String "*"]);
             ("tool_access", Keeper_types.tool_access_to_json tool_access)]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)

let make_test_ctx () =
  Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let test_make_tools_returns_nonempty () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      check bool "tools nonempty" true (List.length tools > 0))

let test_tools_have_valid_schemas () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_schema_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      List.iter (fun (tool : Agent_sdk.Tool.t) ->
        check bool (Printf.sprintf "tool %s has name" tool.schema.name)
          true (String.length tool.schema.name > 0);
        check bool (Printf.sprintf "tool %s has description" tool.schema.name)
          true (String.length tool.schema.description > 0)
      ) tools)

let test_tool_count_matches_allowed () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_count_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
      let tool_names = List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) tools in
      check bool "all tools are in allowed list" true
        (List.for_all (fun name -> List.mem name allowed) tool_names))

let find_tool name tools =
  List.find (fun (tool : Tool.t) -> String.equal tool.schema.name name) tools

let string_contains ~sub text =
  let text_len = String.length text in
  let sub_len = String.length sub in
  let rec loop idx =
    if idx + sub_len > text_len then false
    else if String.sub text idx sub_len = sub then true
    else loop (idx + 1)
  in
  sub_len = 0 || loop 0

let is_guardrail_message message =
  string_contains
    ~sub:"failed 3 times in a row with the same arguments"
    message

let test_error_json_is_returned_as_tool_error () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_error_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let tool = find_tool "keeper_fs_read" tools in
      match Tool.execute tool
              (`Assoc [("path", `String "missing-file-for-keeper-tools-oas.txt")])
      with
      | Error { Agent_sdk.Types.message; _ } ->
          let json = Yojson.Safe.from_string message in
          (* After normalization, error results follow {"ok":false,"error":"...","detail":{...}} *)
          check bool "ok is false" false
            (Yojson.Safe.Util.(member "ok" json |> to_bool));
          check bool "error field present" true
            (Option.is_some (Safe_ops.json_string_opt "error" json));
          let detail = Yojson.Safe.Util.member "detail" json in
          check bool "detail preserves path" true
            (Option.is_some (Safe_ops.json_string_opt "path" detail))
      | Ok _ -> fail "missing file should be surfaced as tool error")

let test_missing_file_error_includes_directory_suggestions () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_suggest_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      let existing = Filename.concat dir "known.txt" in
      Out_channel.with_open_text existing
        (fun oc -> Out_channel.output_string oc "known");
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let tool = find_tool "keeper_fs_read" tools in
      match Tool.execute tool (`Assoc [("path", `String "missing.txt")]) with
      | Error { Agent_sdk.Types.message; _ } ->
          let json = Yojson.Safe.from_string message in
          let detail = Yojson.Safe.Util.member "detail" json in
          let suggestions =
            match Yojson.Safe.Util.member "suggested_entries" detail with
            | `List entries ->
              List.filter_map
                (function `String value -> Some value | _ -> None)
                entries
            | _ -> []
          in
          check bool "known file suggested" true (List.mem "known.txt" suggestions)
      | Ok _ -> fail "missing file should be surfaced as tool error")

let test_repeated_error_results_are_blocked () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_guard_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let tool = find_tool "keeper_fs_read" tools in
      let args =
        `Assoc [("path", `String "missing-file-for-keeper-tools-oas.txt")]
      in
      for _ = 1 to Keeper_tools_oas.max_consecutive_failures do
        match Tool.execute tool args with
        | Error _ -> ()
        | Ok _ -> fail "missing file should be counted as a failure"
      done;
      match Tool.execute tool args with
      | Error { Agent_sdk.Types.message; _ } ->
          check bool "guardrail blocks repeated failures" true
            (is_guardrail_message message)
      | Ok _ -> fail "guardrail should block the repeated failure")

let test_failure_count_resets_after_success () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_reset_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      let reset_path = Filename.concat dir "reset-after-success.txt" in
      (try Sys.remove reset_path with _ -> ());
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let tool = find_tool "keeper_fs_read" tools in
      let path = "reset-after-success.txt" in
      let args = `Assoc [("path", `String path)] in
      for _ = 1 to Keeper_tools_oas.max_consecutive_failures - 1 do
        match Tool.execute tool args with
        | Error _ -> ()
        | Ok _ -> fail "missing file should fail before reset"
      done;
      let abs_path = Filename.concat dir path in
      Out_channel.with_open_text abs_path
        (fun oc -> Out_channel.output_string oc "ok");
      (match Tool.execute tool args with
       | Ok _ -> ()
       | Error _ -> fail "existing file should reset failure count");
      Sys.remove abs_path;
      for _ = 1 to Keeper_tools_oas.max_consecutive_failures do
        match Tool.execute tool args with
        | Error { Agent_sdk.Types.message; _ } when is_guardrail_message message ->
            fail "failure count should have reset after success"
        | Error _ -> ()
        | Ok _ -> fail "missing file should fail after removing reset file"
      done;
      match Tool.execute tool args with
      | Error { Agent_sdk.Types.message; _ } ->
          check bool "guardrail triggers only after fresh streak" true
            (is_guardrail_message message)
      | Ok _ -> fail "guardrail should eventually re-trigger after reset")

let test_failure_tracking_is_independent_per_args () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_independent_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
      let tool = find_tool "keeper_fs_read" tools in
      let args_a = `Assoc [("path", `String "missing-a.txt")] in
      let args_b = `Assoc [("path", `String "missing-b.txt")] in
      for _ = 1 to Keeper_tools_oas.max_consecutive_failures do
        match Tool.execute tool args_a with
        | Error _ -> ()
        | Ok _ -> fail "first path should fail before guardrail"
      done;
      (match Tool.execute tool args_b with
       | Error { Agent_sdk.Types.message; _ } ->
           check bool "different args are not blocked by prior failures" false
             (is_guardrail_message message)
       | Ok _ -> fail "second path should still fail normally");
      match Tool.execute tool args_a with
      | Error { Agent_sdk.Types.message; _ } ->
          check bool "original args are blocked" true
            (is_guardrail_message message)
      | Ok _ -> fail "guardrail should block original failing args")

let make_research_meta ?tool_access ()
    : Keeper_types.keeper_meta =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None -> Keeper_types.Preset { preset = Keeper_types.Research; also_allow = [] }
  in
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String "test-researcher");
             ("agent_name", `String "test-researcher");
             ("trace_id", `String "test-trace-research");
             ("soul_profile", `String "research");
             ("tool_access", Keeper_types.tool_access_to_json tool_access)]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_research_meta failed: %s" e)

let test_research_keeper_has_autoresearch_tools () =
  let meta = make_research_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_cycle = List.mem "masc_autoresearch_cycle" allowed in
  let has_start = List.mem "masc_autoresearch_start" allowed in
  let has_status = List.mem "masc_autoresearch_status" allowed in
  check bool "has cycle" true has_cycle;
  check bool "has start" true has_start;
  check bool "has status" true has_status

let test_non_research_keeper_has_autoresearch () =
  let meta =
    make_test_meta
      ~preset:Keeper_types.Minimal
      ~also_allow:autoresearch_allowlist ()
  in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_any = List.exists (fun n ->
    String.length n > 18
    && String.sub n 0 18 = "masc_autoresearch_") allowed in
  check bool "has autoresearch tools" true has_any

let test_research_model_tools_include_autoresearch () =
  let meta = make_research_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_model_tools meta in
  let has_cycle = List.exists (fun (t : Types_core.tool_schema) ->
    t.name = "masc_autoresearch_cycle") tools in
  check bool "model tools have cycle" true has_cycle

let make_learned_meta () : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String "test-learned");
             ("agent_name", `String "test-learned");
             ("trace_id", `String "test-trace-learned");
             ( "tool_access",
               Keeper_types.tool_access_to_json
                 (Keeper_types.Preset { preset = Keeper_types.Full; also_allow = [] } ))]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_learned_meta failed: %s" e)

let test_all_keepers_have_library_tools () =
  let meta = make_learned_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_library_search" true (List.mem "keeper_library_search" allowed);
  check bool "has keeper_library_read" true (List.mem "keeper_library_read" allowed)

let test_library_search_returns_results () =
  let fake_home = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_lib_home_%d" (Random.int 100000)) in
  let lib_path = List.fold_left Filename.concat fake_home ["me"; "docs"; "library"] in
  let rec mkdir_p path =
    if not (Sys.file_exists path) then begin
      mkdir_p (Filename.dirname path);
      (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  mkdir_p lib_path;
  let doc_path = Filename.concat lib_path "test-mlfq-scheduler-20260321.md" in
  let oc = open_out doc_path in
  output_string oc
    "---\ntitle: MLFQ Scheduler for LLM Agents\nsource: research\n\
     confidence: 0.85\nauthor: test\ncreated: 2026-03-21\n\
     tags: [llm-scheduling, mlfq]\n---\n\n\
     Multi-Level Feedback Queue scheduler for LLM request priority.\n";
  close_out oc;
  let orig_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" fake_home;
  Fun.protect
    ~finally:(fun () ->
      (match orig_home with Some h -> Unix.putenv "HOME" h | None -> ());
      (try Sys.remove doc_path with _ -> ()))
    (fun () ->
      let ctx = Tool_library.{ agent_name = "test-keeper" } in
      (* Search *)
      let (ok, msg) = Tool_library.handle_search ctx
        (`Assoc [("query", `String "mlfq")]) in
      check bool "search succeeds" true ok;
      check bool "search finds mlfq doc" true
        (let low = String.lowercase_ascii msg in
         String.length low > 0
         && not (Tool_library.string_contains ~sub:"no documents" low));
      (* Read *)
      let (ok2, msg2) = Tool_library.handle_read ctx
        (`Assoc [("topic", `String "test-mlfq")]) in
      check bool "read succeeds" true ok2;
      check bool "read contains MLFQ content" true
        (Tool_library.string_contains ~sub:"Multi-Level Feedback Queue" msg2))

let test_library_search_empty_query () =
  let ctx = Tool_library.{ agent_name = "test-keeper" } in
  let (ok, _msg) = Tool_library.handle_search ctx
    (`Assoc [("query", `String "")]) in
  check bool "empty query fails" false ok

let test_library_read_missing_topic () =
  let ctx = Tool_library.{ agent_name = "test-keeper" } in
  let (ok, _msg) = Tool_library.handle_read ctx
    (`Assoc [("topic", `String "nonexistent-topic-xyz-999")]) in
  check bool "missing topic fails" false ok

(* ── normalize_tool_result tests ──────────────────────────── *)

let parse json_str =
  Yojson.Safe.from_string json_str

let json_bool key json =
  Yojson.Safe.Util.(member key json |> to_bool)

let json_string key json =
  Yojson.Safe.Util.(member key json |> to_string)

let test_normalize_success_json () =
  let raw = {|{"ok":true,"path":"/tmp/a.ml","bytes":42}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:true raw in
  let json = parse normalized in
  check bool "ok is true" true (json_bool "ok" json);
  let result = Yojson.Safe.Util.member "result" json in
  check string "path preserved" "/tmp/a.ml"
    Yojson.Safe.Util.(member "path" result |> to_string)

let test_normalize_success_plain_text () =
  let raw = "📋 No tasks yet." in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:true raw in
  let json = parse normalized in
  check bool "ok is true" true (json_bool "ok" json);
  check string "result is text" "📋 No tasks yet." (json_string "result" json)

let test_normalize_failure_error_field () =
  let raw = {|{"error":"file not found","path":"/tmp/missing"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error extracted" "file not found" (json_string "error" json);
  let detail = Yojson.Safe.Util.member "detail" json in
  check string "detail preserves path" "/tmp/missing"
    Yojson.Safe.Util.(member "path" detail |> to_string)

let test_normalize_failure_status_error () =
  let raw = {|{"status":"error","agent_id":"v1","message":"voice unavailable"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error from message" "voice unavailable" (json_string "error" json)

let test_normalize_failure_ok_false () =
  let raw = {|{"ok":false,"error":"command_blocked","reason":"not in allowlist"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error extracted" "command_blocked" (json_string "error" json)

let test_normalize_failure_plain_text () =
  let raw = "tool keeper_bash failed (3/5): Unix_error(ENOENT)" in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error is raw text" raw (json_string "error" json)

(* ── Tool_output_validation tests (memory cap) ──────────────── *)

let test_cap_short_unchanged () =
  let short = "hello world" in
  let result = Tool_output_validation.cap short in
  check string "short output unchanged" short result

let test_cap_exact_limit_unchanged () =
  let exact = String.make Tool_output_validation.max_output_chars 'x' in
  let result = Tool_output_validation.cap exact in
  check string "exact limit unchanged" exact result

let test_cap_over_limit () =
  let long = String.make (Tool_output_validation.max_output_chars + 1000) 'a' in
  let result = Tool_output_validation.cap long in
  check bool "result shorter than original" true
    (String.length result < String.length long);
  check bool "contains capped marker" true
    (string_contains ~sub:"[capped:" result)

let test_cap_preserves_prefix () =
  let prefix = "HEADER:" in
  let long = prefix ^ String.make (Tool_output_validation.max_output_chars + 1000) 'z' in
  let result = Tool_output_validation.cap long in
  check bool "prefix preserved" true
    (String.length result >= String.length prefix
     && String.sub result 0 (String.length prefix) = prefix)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  run "Keeper_tools_oas" [
    "make_tools", [
      test_case "returns nonempty" `Quick test_make_tools_returns_nonempty;
      test_case "valid schemas" `Quick test_tools_have_valid_schemas;
      test_case "count matches allowed" `Quick test_tool_count_matches_allowed;
      test_case "error json becomes tool error" `Quick test_error_json_is_returned_as_tool_error;
      test_case "missing file error includes suggestions" `Quick
        test_missing_file_error_includes_directory_suggestions;
      test_case "repeated errors are blocked" `Quick test_repeated_error_results_are_blocked;
      test_case "failure count resets after success" `Quick test_failure_count_resets_after_success;
      test_case "failure tracking is independent per args" `Quick test_failure_tracking_is_independent_per_args;
    ];
    "normalize_tool_result", [
      test_case "success JSON wraps under result" `Quick test_normalize_success_json;
      test_case "success plain text wraps as string" `Quick test_normalize_success_plain_text;
      test_case "failure extracts error field" `Quick test_normalize_failure_error_field;
      test_case "failure extracts message from status:error" `Quick test_normalize_failure_status_error;
      test_case "failure handles ok:false hybrid" `Quick test_normalize_failure_ok_false;
      test_case "failure plain text wraps as error" `Quick test_normalize_failure_plain_text;
    ];
    "research_profile", [
      test_case "has autoresearch tools" `Quick test_research_keeper_has_autoresearch_tools;
      test_case "allowlisted non-research has autoresearch" `Quick test_non_research_keeper_has_autoresearch;
      test_case "allowlisted model tools include autoresearch" `Quick test_research_model_tools_include_autoresearch;
    ];
    "library_tools", [
      test_case "all keepers have library tools" `Quick test_all_keepers_have_library_tools;
      test_case "search returns results" `Quick test_library_search_returns_results;
      test_case "empty query fails" `Quick test_library_search_empty_query;
      test_case "missing topic fails" `Quick test_library_read_missing_topic;
    ];
    "output_cap", [
      test_case "short output unchanged" `Quick test_cap_short_unchanged;
      test_case "exact limit unchanged" `Quick test_cap_exact_limit_unchanged;
      test_case "over limit capped with marker" `Quick test_cap_over_limit;
      test_case "prefix preserved after cap" `Quick test_cap_preserves_prefix;
    ];
  ]
