(** Tests for Keeper_tools_oas — OAS Tool.t wrapping of keeper tools. *)

module Mlog = Log
open Agent_sdk
open Alcotest
open Masc_mcp

let autoresearch_allowlist =
  [ "masc_autoresearch_start"
  ; "masc_autoresearch_cycle"
  ; "masc_autoresearch_status"
  ; "masc_autoresearch_stop"
  ; "masc_autoresearch_inject"
  ]
;;

let make_test_meta
      ?(name = "test-keeper")
      ?(preset = Keeper_types.Full)
      ?(also_allow = [])
      ?tool_access
      ()
  : Keeper_types.keeper_meta
  =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None -> Keeper_types.Preset { preset; also_allow }
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String "test-trace-001"
          ; "allowed_paths", `List [ `String "*" ]
          ; "tool_access", Keeper_types.tool_access_to_json tool_access
          ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)
;;

let make_test_ctx () = Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let test_make_tools_returns_nonempty () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       check bool "tools nonempty" true (List.length tools > 0))
;;

let test_tools_have_valid_schemas () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_schema_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       List.iter
         (fun (tool : Agent_sdk.Tool.t) ->
            check
              bool
              (Printf.sprintf "tool %s has name" tool.schema.name)
              true
              (String.length tool.schema.name > 0);
            check
              bool
              (Printf.sprintf "tool %s has description" tool.schema.name)
              true
              (String.length tool.schema.description > 0))
         tools)
;;

let test_tool_count_matches_allowed () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_count_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
       let tool_names = List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) tools in
       (* RFC-0006 Phase A.2: aliased Tool.t entries (Bash/Read) carry the
         public name on Tool.schema.name even though their handler dispatches
         the internal keeper_* name. Accept either: name in allowed OR the
         alias's internal target in allowed. *)
       check
         bool
         "all tools are in allowed list (or are an alias)"
         true
         (List.for_all
            (fun name ->
               List.mem name allowed
               ||
               match Keeper_tool_alias.route name with
               | Some r -> List.mem r.internal_name allowed
               | None -> false)
            tool_names))
;;

let find_tool name tools =
  List.find (fun (tool : Tool.t) -> String.equal tool.schema.name name) tools
;;

let dummy_schedule : Agent_sdk.Hooks.tool_schedule =
  { planned_index = 0
  ; batch_index = 0
  ; batch_size = 1
  ; concurrency_class = "default"
  ; batch_kind = "sequential"
  }
;;

let string_contains ~sub text =
  let text_len = String.length text in
  let sub_len = String.length sub in
  let rec loop idx =
    if idx + sub_len > text_len
    then false
    else if String.sub text idx sub_len = sub
    then true
    else loop (idx + 1)
  in
  sub_len = 0 || loop 0
;;

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
       Unix.rmdir path
     | _ -> Sys.remove path)
;;

let test_tool_side_effect_failures_are_observed () =
  let meta = make_test_meta ~name:"test-keeper-side-effects" () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.temp_file "test_keeper_tools_side_effects_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let decision_path =
         Keeper_types_support.keeper_decision_log_path config meta.name
       in
       Fs_compat.mkdir_p (Filename.dirname decision_path);
       Unix.mkdir decision_path 0o755;
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       let keeper_labels = [ "keeper", meta.name ] in
       let sse_before =
         Prometheus.metric_value_or_zero
           Masc_mcp.Keeper_metrics.metric_keeper_sse_broadcast_failures
           ~labels:keeper_labels
           ()
       in
       let decision_before =
         Prometheus.metric_value_or_zero
           Masc_mcp.Keeper_metrics.metric_keeper_decision_audit_flush_failures
           ~labels:keeper_labels
           ()
       in
       let original_hook = Atomic.get Sse.buffer_commit_test_hook in
       Fun.protect
         ~finally:(fun () -> Atomic.set Sse.buffer_commit_test_hook original_hook)
         (fun () ->
            Atomic.set
              Sse.buffer_commit_test_hook
              (Some (fun () -> failwith "forced keeper tool SSE failure"));
            match
              Tool.execute
                tool
                (`Assoc [ "path", `String "missing-side-effect-file.txt" ])
            with
            | Error _ -> ()
            | Ok _ -> fail "missing file should be surfaced as tool error");
       check
         (float 0.001)
         "SSE failure metric incremented"
         (sse_before +. 1.0)
         (Prometheus.metric_value_or_zero
            Masc_mcp.Keeper_metrics.metric_keeper_sse_broadcast_failures
            ~labels:keeper_labels
            ());
       check
         (float 0.001)
         "decision-log failure metric incremented"
         (decision_before +. 1.0)
         (Prometheus.metric_value_or_zero
            Masc_mcp.Keeper_metrics.metric_keeper_decision_audit_flush_failures
            ~labels:keeper_labels
            ()))
;;

let test_handler_persists_tool_call_io_without_post_hook () =
  let meta = make_test_meta ~name:"test-keeper-direct-tool-io" () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.temp_file "test_keeper_tools_direct_io_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      rm_rf dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       Keeper_tool_call_log.reset_for_testing ();
       Keeper_tool_call_log.init ~base_path:dir ();
       Keeper_tool_call_log.set_turn_context
         ~keeper_name:meta.name
         ~trace_id:"trace-direct-tool-io"
         ~turn:1
         ();
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_time_now" tools in
       (match Tool.execute tool (`Assoc []) with
        | Ok _ -> ()
        | Error { Agent_sdk.Types.message; _ } ->
          fail ("keeper_time_now should succeed: " ^ message));
       let entries = Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:10 () in
       check int "handler wrote one tool_call row" 1 (List.length entries);
       let row = List.hd entries in
       check
         string
         "tool"
         "keeper_time_now"
         Yojson.Safe.Util.(row |> member "tool" |> to_string);
       check
         string
         "trace id"
         "trace-direct-tool-io"
         Yojson.Safe.Util.(row |> member "trace_id" |> to_string))
;;

let test_post_hook_does_not_duplicate_handler_logged_io () =
  let meta = make_test_meta ~name:"test-keeper-direct-tool-dedupe" () in
  let meta_ref = ref meta in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.temp_file "test_keeper_tools_direct_dedupe_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      rm_rf dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       Keeper_tool_call_log.reset_for_testing ();
       Keeper_tool_call_log.init ~base_path:dir ();
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_time_now" tools in
       let output_text =
         match Tool.execute tool (`Assoc []) with
         | Ok { Agent_sdk.Types.content; _ } -> content
         | Error { Agent_sdk.Types.message; _ } ->
           fail ("keeper_time_now should succeed: " ^ message)
       in
       let hooks = Keeper_hooks_oas.make_hooks ~config ~meta_ref ~generation:1 () in
       let post_tool_use =
         match hooks.Agent_sdk.Hooks.post_tool_use with
         | Some hook -> hook
         | None -> fail "post_tool_use hook missing"
       in
       ignore
         (post_tool_use
            (Agent_sdk.Hooks.PostToolUse
               { tool_use_id = "tu-direct-dedupe"
               ; tool_name = "keeper_time_now"
               ; input = `Assoc []
               ; output =
                   Ok
                     ({ Agent_sdk.Types.content = output_text }
                      : Agent_sdk.Types.tool_output)
               ; result_bytes = String.length output_text
               ; duration_ms = 2.0
               ; schedule = dummy_schedule
               }));
       let entries = Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:10 () in
       check int "post hook did not duplicate handler row" 1 (List.length entries))
;;

let test_oas_wrapper_records_keeper_internal_tool_call () =
  let meta = make_test_meta ~name:"test-keeper-tool-registry" () in
  let ctx_snapshot = make_test_ctx () in
  let dir = Filename.temp_file "test_keeper_tools_registry_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Tool_registry.reset ();
       let config = Coord.default_config dir in
       let bundle = Keeper_tools_oas.make_tool_bundle ~config ~meta ~ctx_snapshot () in
       Fun.protect
         ~finally:(fun () ->
           bundle.cleanup ();
           Tool_registry.reset ())
         (fun () ->
            let tool = find_tool "keeper_stay_silent" bundle.tools in
            match Tool.execute tool (`Assoc []) with
            | Error { Agent_sdk.Types.message; _ } ->
              fail (Printf.sprintf "expected tool success, got error: %s" message)
            | Ok _ ->
              let stats = Tool_registry.get_stats () in
              let entry = List.assoc "keeper_stay_silent" stats in
              check int "call_count" 1 (Atomic.get entry.call_count);
              check int "success_count" 1 (Atomic.get entry.success_count);
              check int "keeper_internal_count" 1 (Atomic.get entry.keeper_internal_count)))
;;

let is_guardrail_message message =
  string_contains ~sub:"failed 3 times in a row with the same arguments" message
;;

let test_error_json_is_returned_as_tool_error () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_error_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       match
         Tool.execute
           tool
           (`Assoc [ "path", `String "missing-file-for-keeper-tools-oas.txt" ])
       with
       | Error { Agent_sdk.Types.message; _ } ->
         let json = Yojson.Safe.from_string message in
         (* After normalization, error results follow {"ok":false,"error":"...","detail":{...}} *)
         check bool "ok is false" false Yojson.Safe.Util.(member "ok" json |> to_bool);
         check
           bool
           "error field present"
           true
           (Option.is_some (Safe_ops.json_string_opt "error" json));
         let detail = Yojson.Safe.Util.member "detail" json in
         check
           bool
           "detail preserves path"
           true
           (Option.is_some (Safe_ops.json_string_opt "path" detail))
       | Ok _ -> fail "missing file should be surfaced as tool error")
;;

let test_oas_handler_rejects_missing_required_args () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_validate_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       match Tool.execute tool (`Assoc []) with
       | Error { Agent_sdk.Types.message; _ } ->
         let json = Yojson.Safe.from_string message in
         check bool "ok is false" false Yojson.Safe.Util.(member "ok" json |> to_bool);
         check
           bool
           "error mentions missing path"
           true
           (string_contains ~sub:"path" message);
         let detail = Yojson.Safe.Util.member "detail" json in
         check
           string
           "validation source"
           "oas_tool_middleware"
           Yojson.Safe.Util.(detail |> member "validation" |> to_string)
       | Ok _ -> fail "missing required path should be rejected by OAS validation")
;;

let latest_log_seq () =
  match Mlog.Ring.recent ~limit:1 () with
  | (entry : Mlog.Ring.entry) :: _ -> entry.seq
  | [] -> -1
;;

let test_error_result_logs_at_error_level () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_log_level_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       let baseline = latest_log_seq () in
       (match
          Tool.execute
            tool
            (`Assoc [ "path", `String "missing-file-for-keeper-tools-oas.txt" ])
        with
        | Error _ -> ()
        | Ok _ -> fail "missing file should be surfaced as tool error");
       let entry =
         Mlog.Ring.recent ~limit:50 ~module_filter:"Keeper" ~since_seq:baseline ()
         |> List.find_opt (fun (entry : Mlog.Ring.entry) ->
           string_contains ~sub:"returned error result" entry.message)
       in
       match entry with
       | None -> fail "expected keeper error log for failing tool result"
       | Some (entry : Mlog.Ring.entry) ->
         check string "failing tool result logs at ERROR" "ERROR" entry.normalized_level)
;;

let test_missing_file_error_includes_directory_suggestions () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_suggest_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let pg_dir =
         Filename.concat
           (Keeper_alerting_path.project_root_of_config config)
           (Keeper_alerting_path.playground_path_of_keeper meta.name)
       in
       Fs_compat.mkdir_p pg_dir;
       let existing = Filename.concat pg_dir "known.txt" in
       Out_channel.with_open_text existing (fun oc ->
         Out_channel.output_string oc "known");
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       match Tool.execute tool (`Assoc [ "path", `String "missing.txt" ]) with
       | Error { Agent_sdk.Types.message; _ } ->
         let json = Yojson.Safe.from_string message in
         let detail = Yojson.Safe.Util.member "detail" json in
         let suggestions =
           match Yojson.Safe.Util.member "suggested_entries" detail with
           | `List entries ->
             List.filter_map
               (function
                 | `String value -> Some value
                 | _ -> None)
               entries
           | _ -> []
         in
         check bool "known file suggested" true (List.mem "known.txt" suggestions)
       | Ok _ -> fail "missing file should be surfaced as tool error")
;;

let test_repeated_error_results_are_blocked () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_guard_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       let args = `Assoc [ "path", `String "missing-file-for-keeper-tools-oas.txt" ] in
       for _ = 1 to Keeper_tools_oas.max_consecutive_failures do
         match Tool.execute tool args with
         | Error _ -> ()
         | Ok _ -> fail "missing file should be counted as a failure"
       done;
       match Tool.execute tool args with
       | Error { Agent_sdk.Types.message; _ } ->
         check
           bool
           "guardrail blocks repeated failures"
           true
           (is_guardrail_message message)
       | Ok _ -> fail "guardrail should block the repeated failure")
;;

let test_failure_count_resets_after_success () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_reset_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      let reset_path = Filename.concat dir "reset-after-success.txt" in
      (try Sys.remove reset_path with
       | _ -> ());
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let pg_dir =
         Filename.concat
           (Keeper_alerting_path.project_root_of_config config)
           (Keeper_alerting_path.playground_path_of_keeper meta.name)
       in
       Fs_compat.mkdir_p pg_dir;
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       let path = "reset-after-success.txt" in
       let args = `Assoc [ "path", `String path ] in
       for _ = 1 to Keeper_tools_oas.max_consecutive_failures - 1 do
         match Tool.execute tool args with
         | Error _ -> ()
         | Ok _ -> fail "missing file should fail before reset"
       done;
       let abs_path = Filename.concat pg_dir path in
       Out_channel.with_open_text abs_path (fun oc -> Out_channel.output_string oc "ok");
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
         check
           bool
           "guardrail triggers only after fresh streak"
           true
           (is_guardrail_message message)
       | Ok _ -> fail "guardrail should eventually re-trigger after reset")
;;

let test_failure_tracking_is_independent_per_args () =
  let meta = make_test_meta () in
  let ctx_snapshot = make_test_ctx () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_tools_independent_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        Sys.readdir dir |> Array.iter (fun f -> Sys.remove (Filename.concat dir f));
        Unix.rmdir dir
      with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config dir in
       let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_snapshot () in
       let tool = find_tool "keeper_fs_read" tools in
       let args_a = `Assoc [ "path", `String "missing-a.txt" ] in
       let args_b = `Assoc [ "path", `String "missing-b.txt" ] in
       for _ = 1 to Keeper_tools_oas.max_consecutive_failures do
         match Tool.execute tool args_a with
         | Error _ -> ()
         | Ok _ -> fail "first path should fail before guardrail"
       done;
       (match Tool.execute tool args_b with
        | Error { Agent_sdk.Types.message; _ } ->
          check
            bool
            "different args are not blocked by prior failures"
            false
            (is_guardrail_message message)
        | Ok _ -> fail "second path should still fail normally");
       match Tool.execute tool args_a with
       | Error { Agent_sdk.Types.message; _ } ->
         check bool "original args are blocked" true (is_guardrail_message message)
       | Ok _ -> fail "guardrail should block original failing args")
;;

let make_research_meta ?tool_access () : Keeper_types.keeper_meta =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None -> Keeper_types.Preset { preset = Keeper_types.Research; also_allow = [] }
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String "test-researcher"
          ; "agent_name", `String "test-researcher"
          ; "trace_id", `String "test-trace-research"
          ; "soul_profile", `String "research"
          ; "tool_access", Keeper_types.tool_access_to_json tool_access
          ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_research_meta failed: %s" e)
;;

let test_research_keeper_has_autoresearch_tools () =
  let meta = make_research_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_cycle = List.mem "masc_autoresearch_cycle" allowed in
  let has_start = List.mem "masc_autoresearch_start" allowed in
  let has_status = List.mem "masc_autoresearch_status" allowed in
  check bool "has cycle" true has_cycle;
  check bool "has start" true has_start;
  check bool "has status" true has_status
;;

let test_non_research_keeper_has_autoresearch () =
  let meta =
    make_test_meta ~preset:Keeper_types.Minimal ~also_allow:autoresearch_allowlist ()
  in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_any =
    List.exists
      (fun n -> String.length n > 18 && String.sub n 0 18 = "masc_autoresearch_")
      allowed
  in
  check bool "has autoresearch tools" true has_any
;;

let test_research_model_tools_include_autoresearch () =
  let meta = make_research_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_model_tools meta in
  let has_cycle =
    List.exists
      (fun (t : Types_core.tool_schema) -> t.name = "masc_autoresearch_cycle")
      tools
  in
  check bool "model tools have cycle" true has_cycle
;;

let make_learned_meta () : Keeper_types.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String "test-learned"
          ; "agent_name", `String "test-learned"
          ; "trace_id", `String "test-trace-learned"
          ; ( "tool_access"
            , Keeper_types.tool_access_to_json
                (Keeper_types.Preset { preset = Keeper_types.Full; also_allow = [] }) )
          ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_learned_meta failed: %s" e)
;;

let test_all_keepers_have_library_tools () =
  let meta = make_learned_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_library_search" true (List.mem "keeper_library_search" allowed);
  check bool "has keeper_library_read" true (List.mem "keeper_library_read" allowed)
;;

let test_library_search_returns_results () =
  let fake_home =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_lib_home_%d" (Random.int 100000))
  in
  let lib_path = List.fold_left Filename.concat fake_home [ "me"; "docs"; "library" ] in
  let rec mkdir_p path =
    if not (Sys.file_exists path)
    then (
      mkdir_p (Filename.dirname path);
      try Unix.mkdir path 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p lib_path;
  let doc_path = Filename.concat lib_path "test-mlfq-scheduler-20260321.md" in
  let oc = open_out doc_path in
  output_string
    oc
    "---\n\
     title: MLFQ Scheduler for LLM Agents\n\
     source: research\n\
     confidence: 0.85\n\
     author: test\n\
     created: 2026-03-21\n\
     tags: [llm-scheduling, mlfq]\n\
     ---\n\n\
     Multi-Level Feedback Queue scheduler for LLM request priority.\n";
  close_out oc;
  let orig_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" fake_home;
  Fun.protect
    ~finally:(fun () ->
      (match orig_home with
       | Some h -> Unix.putenv "HOME" h
       | None -> ());
      try Sys.remove doc_path with
      | _ -> ())
    (fun () ->
       let ctx = Tool_library.{ agent_name = "test-keeper" } in
       (* Search *)
       let search_result =
         Tool_library.handle_search ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ "query", `String "mlfq" ])
       in
       check bool "search succeeds" true search_result.Tool_result.success;
       check
         bool
         "search finds mlfq doc"
         true
         (let low = String.lowercase_ascii search_result.Tool_result.legacy_message in
          String.length low > 0
          && not (Tool_library.string_contains ~sub:"no documents" low));
       (* Read *)
       let read_result =
         Tool_library.handle_read ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ "topic", `String "test-mlfq" ])
       in
       check bool "read succeeds" true read_result.Tool_result.success;
       check
         bool
         "read contains MLFQ content"
         true
         (Tool_library.string_contains ~sub:"Multi-Level Feedback Queue" read_result.Tool_result.legacy_message))
;;

let test_library_search_empty_query () =
  let ctx = Tool_library.{ agent_name = "test-keeper" } in
  let result = Tool_library.handle_search ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ "query", `String "" ]) in
  check bool "empty query fails" false result.Tool_result.success
;;

let test_library_read_missing_topic () =
  let ctx = Tool_library.{ agent_name = "test-keeper" } in
  let result =
    Tool_library.handle_read ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ "topic", `String "nonexistent-topic-xyz-999" ])
  in
  check bool "missing topic fails" false result.Tool_result.success
;;

(* ── normalize_tool_result tests ──────────────────────────── *)

let parse json_str = Yojson.Safe.from_string json_str
let json_bool key json = Yojson.Safe.Util.(member key json |> to_bool)
let json_string key json = Yojson.Safe.Util.(member key json |> to_string)

let test_normalize_success_json () =
  let raw = {|{"ok":true,"path":"/tmp/a.ml","bytes":42}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:true raw in
  let json = parse normalized in
  check bool "ok is true" true (json_bool "ok" json);
  let result = Yojson.Safe.Util.member "result" json in
  check
    string
    "path preserved"
    "/tmp/a.ml"
    Yojson.Safe.Util.(member "path" result |> to_string)
;;

let test_normalize_success_plain_text () =
  let raw = "📋 No tasks yet." in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:true raw in
  let json = parse normalized in
  check bool "ok is true" true (json_bool "ok" json);
  check string "result is text" "📋 No tasks yet." (json_string "result" json)
;;

let test_normalize_failure_error_field () =
  let raw = {|{"error":"file not found","path":"/tmp/missing"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error extracted" "file not found" (json_string "error" json);
  let detail = Yojson.Safe.Util.member "detail" json in
  check
    string
    "detail preserves path"
    "/tmp/missing"
    Yojson.Safe.Util.(member "path" detail |> to_string)
;;

let test_normalize_failure_status_error () =
  let raw = {|{"status":"error","agent_id":"v1","message":"voice unavailable"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error from message" "voice unavailable" (json_string "error" json)
;;

let test_normalize_failure_ok_false () =
  let raw = {|{"ok":false,"error":"command_blocked","reason":"not in allowlist"}|} in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error extracted" "command_blocked" (json_string "error" json)
;;

let test_normalize_failure_plain_text () =
  let raw = "tool keeper_bash failed (3/5): Unix_error(ENOENT)" in
  let normalized = Keeper_tools_oas.normalize_tool_result ~success:false raw in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check string "error is raw text" raw (json_string "error" json)
;;

let test_transient_mutex_contention_envelope () =
  let normalized =
    Keeper_tools_oas.transient_mutex_contention_tool_error
      ~tool_name:"keeper_shell"
      ~error_text:"Sys_error(\"Mutex.lock: Resource deadlock avoided\")"
      ~backtrace:"Raised at Mutex.lock"
      ()
  in
  let json = parse normalized in
  check bool "ok is false" false (json_bool "ok" json);
  check bool "recoverable" true Yojson.Safe.Util.(member "recoverable" json |> to_bool);
  check
    string
    "error_class"
    "transient_mutex_contention"
    Yojson.Safe.Util.(member "error_class" json |> to_string);
  check
    bool
    "retry recommended"
    true
    Yojson.Safe.Util.(member "retry_recommended" json |> to_bool);
  let detail = Yojson.Safe.Util.member "detail" json in
  check
    string
    "tool_name"
    "keeper_shell"
    Yojson.Safe.Util.(member "tool_name" detail |> to_string);
  check
    bool
    "backtrace available"
    true
    Yojson.Safe.Util.(member "backtrace_available" detail |> to_bool)
;;

let test_result_markers_capture_docker_approve () =
  let output =
    Keeper_tools_oas.normalize_tool_result
      ~success:true
      {|{"ok":true,"via":"docker","event":"APPROVE"}|}
  in
  let markers = Keeper_tools_oas.tool_exec_result_markers ~input:(`Assoc []) ~output in
  check bool "via marker" true (List.mem "via=docker" markers);
  check bool "approve marker" true (List.mem "event=APPROVE" markers)
;;

let test_result_markers_keep_git_push_class_only () =
  let output =
    Keeper_tools_oas.normalize_tool_result ~success:true {|{"ok":true,"via":"docker"}|}
  in
  let markers =
    Keeper_tools_oas.tool_exec_result_markers
      ~input:(`Assoc [ "cmd", `String "git push origin feature/secret-proof" ])
      ~output
  in
  check bool "git push class marker" true (List.mem "git push" markers);
  check bool "via marker" true (List.mem "via=docker" markers);
  check
    bool
    "raw command not persisted as marker"
    false
    (List.mem "git push origin feature/secret-proof" markers)
;;

let test_result_markers_ignore_lifecycle_mentions () =
  let output =
    Keeper_tools_oas.normalize_tool_result ~success:true {|{"ok":true,"via":"docker"}|}
  in
  let markers =
    Keeper_tools_oas.tool_exec_result_markers
      ~input:
        (`Assoc
            [ "cmd", `String "echo git push"; "command", `String "printf 'gh pr create'" ])
      ~output
  in
  check bool "mentioned git push not marked" false (List.mem "git push" markers);
  check bool "mentioned pr create not marked" false (List.mem "gh pr create" markers);
  check bool "output via marker still captured" true (List.mem "via=docker" markers)
;;

let test_result_markers_ignore_input_via () =
  let output = Keeper_tools_oas.normalize_tool_result ~success:true {|{"ok":true}|} in
  let markers =
    Keeper_tools_oas.tool_exec_result_markers
      ~input:(`Assoc [ "via", `String "docker" ])
      ~output
  in
  check bool "input via marker ignored" false (List.mem "via=docker" markers)
;;

let test_result_markers_ignore_input_route_fields () =
  let output = Keeper_tools_oas.normalize_tool_result ~success:true {|{"ok":true}|} in
  let markers =
    Keeper_tools_oas.tool_exec_result_markers
      ~input:
        (`Assoc
            [ "action", `String "push"
            ; "event", `String "APPROVE"
            ; "operation", `String "pr_create"
            ])
      ~output
  in
  check bool "input action marker ignored" false (List.mem "git push" markers);
  check bool "input event marker ignored" false (List.mem "event=APPROVE" markers);
  check bool "input operation marker ignored" false (List.mem "gh pr create" markers)
;;

let test_result_markers_reject_untrusted_via () =
  let output =
    Keeper_tools_oas.normalize_tool_result
      ~success:true
      {|{"ok":true,"via":"<script>alert(1)</script>"}|}
  in
  let markers = Keeper_tools_oas.tool_exec_result_markers ~input:(`Assoc []) ~output in
  check
    bool
    "untrusted via marker rejected"
    false
    (List.exists (fun marker -> String.starts_with ~prefix:"via=" marker) markers)
;;

let test_result_markers_capture_pr_create_operation () =
  let output =
    Keeper_tools_oas.normalize_tool_result
      ~success:true
      {|{"ok":true,"via":"docker","operation":"pr_create"}|}
  in
  let markers = Keeper_tools_oas.tool_exec_result_markers ~input:(`Assoc []) ~output in
  check bool "pr create marker" true (List.mem "gh pr create" markers);
  check bool "via marker" true (List.mem "via=docker" markers)
;;

(* ── Tool_output_validation tests (memory cap) ──────────────── *)

let test_cap_short_unchanged () =
  let short = "hello world" in
  let result = Tool_output_validation.cap short in
  check string "short output unchanged" short result
;;

let test_cap_exact_limit_unchanged () =
  let exact = String.make Tool_output_validation.max_output_chars 'x' in
  let result = Tool_output_validation.cap exact in
  check string "exact limit unchanged" exact result
;;

let test_cap_over_limit () =
  let long = String.make (Tool_output_validation.max_output_chars + 1000) 'a' in
  let result = Tool_output_validation.cap long in
  check
    bool
    "result shorter than original"
    true
    (String.length result < String.length long);
  check bool "contains capped marker" true (string_contains ~sub:"[capped:" result)
;;

let test_cap_preserves_prefix () =
  let prefix = "HEADER:" in
  let long = prefix ^ String.make (Tool_output_validation.max_output_chars + 1000) 'z' in
  let result = Tool_output_validation.cap long in
  check
    bool
    "prefix preserved"
    true
    (String.length result >= String.length prefix
     && String.sub result 0 (String.length prefix) = prefix)
;;

let () =
  let base_path = Masc_test_deps.find_project_root () in
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  run
    "Keeper_tools_oas"
    [ ( "make_tools"
      , [ test_case "returns nonempty" `Quick test_make_tools_returns_nonempty
        ; test_case "valid schemas" `Quick test_tools_have_valid_schemas
        ; test_case "count matches allowed" `Quick test_tool_count_matches_allowed
        ; test_case
            "error json becomes tool error"
            `Quick
            test_error_json_is_returned_as_tool_error
        ; test_case
            "missing required args rejected before keeper exec"
            `Quick
            test_oas_handler_rejects_missing_required_args
        ; test_case
            "error result logs at error level"
            `Quick
            test_error_result_logs_at_error_level
        ; test_case
            "missing file error includes suggestions"
            `Quick
            test_missing_file_error_includes_directory_suggestions
        ; test_case
            "repeated errors are blocked"
            `Quick
            test_repeated_error_results_are_blocked
        ; test_case
            "failure count resets after success"
            `Quick
            test_failure_count_resets_after_success
        ; test_case
            "failure tracking is independent per args"
            `Quick
            test_failure_tracking_is_independent_per_args
        ; test_case
            "tool side-effect failures are observed"
            `Quick
            test_tool_side_effect_failures_are_observed
        ; test_case
            "handler persists tool-call I/O without post hook"
            `Quick
            test_handler_persists_tool_call_io_without_post_hook
        ; test_case
            "post hook skips handler-logged tool-call I/O"
            `Quick
            test_post_hook_does_not_duplicate_handler_logged_io
        ; test_case
            "wrapper records keeper-internal calls"
            `Quick
            test_oas_wrapper_records_keeper_internal_tool_call
        ] )
    ; ( "normalize_tool_result"
      , [ test_case "success JSON wraps under result" `Quick test_normalize_success_json
        ; test_case
            "success plain text wraps as string"
            `Quick
            test_normalize_success_plain_text
        ; test_case
            "failure extracts error field"
            `Quick
            test_normalize_failure_error_field
        ; test_case
            "failure extracts message from status:error"
            `Quick
            test_normalize_failure_status_error
        ; test_case
            "failure handles ok:false hybrid"
            `Quick
            test_normalize_failure_ok_false
        ; test_case
            "failure plain text wraps as error"
            `Quick
            test_normalize_failure_plain_text
        ; test_case
            "EDEADLK envelope is recoverable"
            `Quick
            test_transient_mutex_contention_envelope
        ] )
    ; ( "result_markers"
      , [ test_case
            "captures docker approve markers"
            `Quick
            test_result_markers_capture_docker_approve
        ; test_case
            "keeps git push class only"
            `Quick
            test_result_markers_keep_git_push_class_only
        ; test_case
            "ignores lifecycle mentions"
            `Quick
            test_result_markers_ignore_lifecycle_mentions
        ; test_case
            "ignores caller-provided via marker"
            `Quick
            test_result_markers_ignore_input_via
        ; test_case
            "ignores caller-provided route fields"
            `Quick
            test_result_markers_ignore_input_route_fields
        ; test_case
            "rejects untrusted via marker"
            `Quick
            test_result_markers_reject_untrusted_via
        ; test_case
            "captures pr create operation"
            `Quick
            test_result_markers_capture_pr_create_operation
        ] )
    ; ( "research_profile"
      , [ test_case
            "has autoresearch tools"
            `Quick
            test_research_keeper_has_autoresearch_tools
        ; test_case
            "allowlisted non-research has autoresearch"
            `Quick
            test_non_research_keeper_has_autoresearch
        ; test_case
            "allowlisted model tools include autoresearch"
            `Quick
            test_research_model_tools_include_autoresearch
        ] )
    ; ( "library_tools"
      , [ test_case
            "all keepers have library tools"
            `Quick
            test_all_keepers_have_library_tools
        ; test_case "search returns results" `Quick test_library_search_returns_results
        ; test_case "empty query fails" `Quick test_library_search_empty_query
        ; test_case "missing topic fails" `Quick test_library_read_missing_topic
        ] )
    ; ( "output_cap"
      , [ test_case "short output unchanged" `Quick test_cap_short_unchanged
        ; test_case "exact limit unchanged" `Quick test_cap_exact_limit_unchanged
        ; test_case "over limit capped with marker" `Quick test_cap_over_limit
        ; test_case "prefix preserved after cap" `Quick test_cap_preserves_prefix
        ] )
    ]
;;
