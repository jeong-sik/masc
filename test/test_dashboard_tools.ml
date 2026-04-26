(** Dashboard tools projection regression tests. *)

module Lib = Masc_mcp
open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_tools" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path)
      else Sys.remove path
  in
  rm dir
;;

let test_dashboard_tools_projection () =
  let dir = test_dir () in
  let runtime_probe_calls = Atomic.make 0 in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord_utils.default_config dir in
       ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
       Lib.Tool_usage_log.init ~base_path:dir ();
       let json = Lib.Server_dashboard_http.dashboard_tools_http_json config in
       let open Yojson.Safe.Util in
       let inventory = json |> member "tool_inventory" in
       let inventory_rows = inventory |> member "tools" |> to_list in
       let usage = json |> member "tool_usage" in
       let config_resolution = json |> member "config_resolution" in
       let runtime_resolution = json |> member "runtime_resolution" in
       check bool "inventory has tools" true (List.length inventory_rows > 0);
       (* Verify registered_count is a valid integer field *)
       let reg_count = usage |> member "registered_count" |> to_int in
       check bool "registered_count is non-negative" true (reg_count >= 0);
       check
         string
         "tool usage source"
         "tool_usage"
         (usage |> member "source" |> to_string);
       check
         string
         "tool usage producer"
         "tool_usage_log"
         (usage |> member "producer" |> to_string);
       check
         string
         "tool usage dashboard surface"
         "/api/v1/dashboard/tools"
         (usage |> member "dashboard_surface" |> to_string);
       check
         bool
         "tool usage durable store present"
         true
         (match usage |> member "durable_store" with
          | `String value -> String.length value > 0
          | _ -> false);
       check
         int
         "tool usage durable rows initially empty"
         0
         (usage |> member "entry_count" |> to_int);
       check
         string
         "tool usage health empty"
         "empty"
         (usage |> member "health" |> to_string);
       check
         bool
         "config root path surfaced"
         true
         (match config_resolution |> member "config_root" |> member "path" with
          | `String value -> String.length value > 0
          | _ -> false);
       check
         bool
         "config warnings surfaced as list"
         true
         (match config_resolution |> member "warnings" with
          | `List _ -> true
          | _ -> false);
       check
         bool
         "cascade authoring path surfaced"
         true
         (match config_resolution |> member "cascade_authoring" |> member "path" with
          | `String value -> String.length value > 0
          | _ -> false);
       check
         bool
         "runtime data_root path surfaced"
         true
         (match runtime_resolution |> member "data_root" |> member "path" with
          | `String value -> String.length value > 0
          | _ -> false);
       check
         bool
         "runtime source_mismatch surfaced"
         true
         (match runtime_resolution |> member "source_mismatch" with
          | `Bool _ -> true
          | _ -> false);
       check
         bool
         "runtime diagnostics surfaced as list"
         true
         (match runtime_resolution |> member "diagnostics" with
          | `List _ -> true
          | _ -> false);
       check
         bool
         "build started_at surfaced"
         true
         (match runtime_resolution |> member "build" |> member "started_at" with
          | `String value -> String.length value > 0
          | _ -> false);
       let stub_probe () =
         Atomic.set runtime_probe_calls (Atomic.get runtime_probe_calls + 1);
         `Assoc [ "source", `String "test runtime probe"; "probe_ok", `Bool true ]
       in
       Lib.Server_dashboard_http.clear_dashboard_runtime_probe_cache_for_tests ();
       Lib.Server_dashboard_http.set_dashboard_runtime_probe_runner_for_tests stub_probe;
       Fun.protect
         ~finally:(fun () ->
           Lib.Server_dashboard_http.clear_dashboard_runtime_probe_runner_for_tests ();
           Lib.Server_dashboard_http.clear_dashboard_runtime_probe_cache_for_tests ())
         (fun () ->
            let runtime_probe =
              Lib.Server_dashboard_http.dashboard_runtime_probe_http_json ()
            in
            let runtime_probe_cached =
              Lib.Server_dashboard_http.dashboard_runtime_probe_http_json ()
            in
            check
              bool
              "runtime probe envelope contains generated_at"
              true
              (match runtime_probe |> member "generated_at" with
               | `String value -> String.length value > 0
               | _ -> false);
            check
              bool
              "runtime probe contains cache age"
              true
              (match runtime_probe |> member "cache_age_sec" with
               | `Float _ | `Int _ -> true
               | _ -> false);
            check
              bool
              "runtime probe contains probe payload"
              true
              (match runtime_probe |> member "probe" |> member "source" with
               | `String value -> String.length value > 0
               | _ -> false);
            check
              bool
              "runtime probe first request is cache miss"
              false
              (runtime_probe |> member "cache_hit" |> to_bool);
            check
              bool
              "runtime probe second request is cache hit"
              true
              (runtime_probe_cached |> member "cache_hit" |> to_bool);
            let runtime_probe_forced =
              Lib.Server_dashboard_http.dashboard_runtime_probe_http_json ~force:true ()
            in
            check
              bool
              "runtime probe forced refresh reuses recent cache"
              true
              (runtime_probe_forced |> member "cache_hit" |> to_bool);
            check int "runtime probe computed once" 1 (Atomic.get runtime_probe_calls));
       check
         bool
         "usage dispatch flag present"
         true
         (match usage |> member "dispatch_v2_enabled" with
          | `Bool _ -> true
          | _ -> false);
       (* Hidden tools remain auto-filtered outside public_mcp_tools. *)
       let hidden_tool =
         inventory_rows
         |> List.find_opt (fun row ->
           row |> member "name" |> to_string = "masc_code_search")
       in
       let public_tool =
         inventory_rows
         |> List.find_opt (fun row -> row |> member "name" |> to_string = "masc_status")
       in
       let spawned_agent_tool =
         inventory_rows
         |> List.find_opt (fun row ->
           row |> member "name" |> to_string = "masc_workflow_guide")
       in
       let local_worker_tool =
         inventory_rows
         |> List.find_opt (fun row ->
           row |> member "name" |> to_string = "masc_worktree_create")
       in
       check bool "includes hidden tool" true (Option.is_some hidden_tool);
       check bool "includes public tool" true (Option.is_some public_tool);
       check bool "includes spawned agent tool" true (Option.is_some spawned_agent_tool);
       check bool "includes local worker tool" true (Option.is_some local_worker_tool);
       (match public_tool with
        | None -> ()
        | Some row ->
          let public_surface_count =
            row
            |> member "surfaces"
            |> to_list
            |> List.fold_left
                 (fun acc -> function
                    | `String "public_mcp" -> acc + 1
                    | _ -> acc)
                 0
          in
          check bool "public tool tagged public_mcp" true (public_surface_count > 0);
          check int "public_mcp not duplicated on public tool" 1 public_surface_count);
       (match spawned_agent_tool with
        | None -> ()
        | Some row ->
          check
            bool
            "spawned agent tool keeps spawned_agent_mcp surface"
            true
            (row
             |> member "surfaces"
             |> to_list
             |> List.exists (function
               | `String "spawned_agent_mcp" -> true
               | _ -> false)));
       (match local_worker_tool with
        | None -> ()
        | Some row ->
          check
            bool
            "local worker tool keeps local_worker surface"
            true
            (row
             |> member "surfaces"
             |> to_list
             |> List.exists (function
               | `String "local_worker" -> true
               | _ -> false)));
       match hidden_tool with
       | None -> ()
       | Some row ->
         check
           string
           "visibility surfaced"
           "hidden"
           (row |> member "visibility" |> to_string);
         check
           string
           "lifecycle surfaced"
           "active"
           (row |> member "lifecycle" |> to_string);
         check
           bool
           "direct call flag surfaced"
           true
           (row |> member "direct_call_allowed" |> to_bool);
         check
           bool
           "hidden tool not mislabeled public_mcp"
           false
           (row
            |> member "surfaces"
            |> to_list
            |> List.exists (function
              | `String "public_mcp" -> true
              | _ -> false)))
;;

let test_dashboard_tools_usage_surfaces_coverage_gap () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord_utils.default_config dir in
       ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
       Lib.Tool_usage_log.init ~base_path:dir ();
       let masc_root = Lib.Coord.masc_root_dir config in
       Lib.Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_usage"
         ~producer:"tool_usage_log"
         ~durable_store:(Filename.concat masc_root "tool_usage")
         ~dashboard_surface:"/api/v1/dashboard/tools"
         ~stale_reason:"tool_usage_append_failed"
         ~error:"synthetic append failure"
         ();
       let json = Lib.Server_dashboard_http.dashboard_tools_http_json config in
       let open Yojson.Safe.Util in
       let usage = json |> member "tool_usage" in
       check
         string
         "tool usage coverage gap health"
         "coverage_gap"
         (usage |> member "health" |> to_string);
       check
         string
         "tool usage coverage gap stale reason"
         "tool_usage_append_failed"
         (usage |> member "stale_reason" |> to_string);
       check
         int
         "tool usage coverage gap count"
         1
         (usage |> member "coverage_gap_count" |> to_int))
;;

let test_tool_usage_store_failure_records_coverage_gap () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let masc_root = Filename.concat dir ".masc" in
       Fs_compat.mkdir_p masc_root;
       Fs_compat.save_file (Filename.concat masc_root "tool_usage") "not a directory";
       Lib.Tool_usage_log.init ~base_path:dir ();
       Lib.Tool_usage_log.log_call
         ~tool_name:"keeper_tasks_list"
         ~success:true
         ~caller:(Some "oracle");
       let gaps = Lib.Telemetry_coverage_gap.read_recent ~masc_root ~n:10 in
       let reasons =
         List.filter_map (fun gap -> Safe_ops.json_string_opt "stale_reason" gap) gaps
       in
       check
         bool
         "tool usage store failure records coverage gap"
         true
         (List.exists
            (fun reason ->
               reason = "tool_usage_init_failed" || reason = "tool_usage_append_failed")
            reasons))
;;

let test_dashboard_tools_usage_marks_store_path_collision () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord_utils.default_config dir in
       ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
       let masc_root = Lib.Coord.masc_root_dir config in
       Fs_compat.mkdir_p masc_root;
       Fs_compat.save_file (Filename.concat masc_root "tool_usage") "not a directory";
       let json = Lib.Server_dashboard_http.dashboard_tools_http_json config in
       let open Yojson.Safe.Util in
       let usage = json |> member "tool_usage" in
       check
         string
         "tool usage path collision is coverage gap"
         "coverage_gap"
         (usage |> member "health" |> to_string);
       check
         string
         "tool usage path collision stale reason"
         "tool_usage_store_not_directory"
         (usage |> member "stale_reason" |> to_string);
       check
         int
         "tool usage path collision has synthetic gap"
         1
         (usage |> member "coverage_gap_count" |> to_int))
;;

let () =
  run
    "dashboard_tools"
    [ ( "projection"
      , [ test_case
            "full inventory + usage summary"
            `Quick
            test_dashboard_tools_projection
        ; test_case
            "tool usage surfaces coverage gap"
            `Quick
            test_dashboard_tools_usage_surfaces_coverage_gap
        ; test_case
            "tool usage store failure records coverage gap"
            `Quick
            test_tool_usage_store_failure_records_coverage_gap
        ; test_case
            "tool usage marks store path collision"
            `Quick
            test_dashboard_tools_usage_marks_store_path_collision
        ] )
    ]
;;
