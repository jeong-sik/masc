(** Dashboard tools projection regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_tools" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_stubbed_git_probe f =
  Lib.Server_dashboard_http.clear_git_rev_parse_short_cache_for_tests ();
  Lib.Server_dashboard_http.set_git_rev_parse_short_probe_hook_for_tests
    (fun _ -> Some "test");
  Fun.protect
    ~finally:(fun () ->
      Lib.Server_dashboard_http.clear_git_rev_parse_short_probe_hook_for_tests ();
      Lib.Server_dashboard_http.clear_git_rev_parse_short_cache_for_tests ())
    f

let seed_git_probe_cache config =
  let refreshed_at = Unix.gettimeofday () in
  let seed path =
    Lib.Server_dashboard_http.seed_git_rev_parse_short_cache_for_tests path
      (Some "test")
      ~refreshed_at
  in
  seed config.Coord_utils_backend_setup.base_path;
  seed config.Coord_utils_backend_setup.workspace_path;
  Option.iter seed (Lib.Build_identity.repo_root ())

let with_dashboard_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Lib.Cascade_legacy_runner.start_actor_if_needed ~sw;
  f ()

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop index =
    if needle_len = 0
    then true
    else if index + needle_len > haystack_len
    then false
    else if String.equal (String.sub haystack index needle_len) needle
    then true
    else loop (index + 1)
  in
  loop 0
;;

let test_dashboard_tools_projection () =
  let dir = test_dir () in
  let runtime_probe_calls = Atomic.make 0 in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_stubbed_git_probe @@ fun () ->
      with_dashboard_eio @@ fun () ->
      let config = Coord_utils.default_config dir in
      seed_git_probe_cache config;
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
      check string "tool usage source" "tool_usage"
        (usage |> member "source" |> to_string);
      check string "tool usage producer" "tool_usage_log"
        (usage |> member "producer" |> to_string);
      check string "tool usage dashboard surface" "/api/v1/dashboard/tools"
        (usage |> member "dashboard_surface" |> to_string);
      check bool "tool usage durable store present" true
        (match usage |> member "durable_store" with
         | `String value -> String.length value > 0
         | _ -> false);
      check int "tool usage durable rows initially empty" 0
        (usage |> member "entry_count" |> to_int);
      check string "tool usage health empty" "empty"
        (usage |> member "health" |> to_string);
      check bool "config root path surfaced" true
        (match config_resolution |> member "config_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "config warnings surfaced as list" true
        (match config_resolution |> member "warnings" with
         | `List _ -> true
         | _ -> false);
      check bool "cascade authoring path surfaced" true
        (match config_resolution |> member "cascade_authoring" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "runtime data_root path surfaced" true
        (match runtime_resolution |> member "data_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "runtime source_mismatch surfaced" true
        (match runtime_resolution |> member "source_mismatch" with
         | `Bool _ -> true
         | _ -> false);
      check bool "runtime binary git commit surfaced" true
        (match runtime_resolution |> member "runtime_binary_git_commit" with
         | `Null | `String _ -> true
         | _ -> false);
      check bool "runtime repo head git commit surfaced" true
        (match runtime_resolution |> member "runtime_repo_head_git_commit" with
         | `Null | `String _ -> true
         | _ -> false);
      let server_workspace_mismatch =
        match runtime_resolution |> member "server_workspace_mismatch" with
        | `Bool value -> value
        | _ -> false
      in
      check bool "runtime server_workspace_mismatch surfaced" true
        (match runtime_resolution |> member "server_workspace_mismatch" with
         | `Bool _ -> true
         | _ -> false);
      if server_workspace_mismatch
      then
        check bool "runtime server/workspace warning surfaced" true
          (runtime_resolution
           |> member "warnings"
           |> to_list
           |> List.exists (function
             | `String warning ->
               contains_substring ~needle:"Server binary checkout" warning
             | _ -> false));
      check bool "runtime diagnostics surfaced as list" true
        (match runtime_resolution |> member "diagnostics" with
         | `List _ -> true
         | _ -> false);
      check bool "runtime keeper_fibers surfaced" true
        (match runtime_resolution |> member "keeper_fibers" with
         | `Int _ -> true
         | _ -> false);
      check bool "runtime paused_keepers count surfaced" true
        (match runtime_resolution |> member "paused_keepers" with
         | `Int _ -> true
         | _ -> false);
      check bool "runtime keeper fd pressure surfaced" true
        (match runtime_resolution |> member "keeper_fd_pressure" with
         | `Assoc _ -> true
         | _ -> false);
      check bool "runtime keeper fleet safety surfaced" true
        (match runtime_resolution |> member "keeper_fleet_safety" with
         | `Assoc _ -> true
         | _ -> false);
      check bool "runtime keeper reaction ledger surfaced" true
        (match runtime_resolution |> member "keeper_reaction_ledger" with
         | `Assoc _ -> true
         | _ -> false);
      check bool "build started_at surfaced" true
        (match runtime_resolution |> member "build" |> member "started_at" with
         | `String value -> String.length value > 0
         | _ -> false);
      let deployment_state = runtime_resolution |> member "deployment_state" in
      check string "deployment state schema" "masc.runtime_deployment_state.v1"
        (deployment_state |> member "schema" |> to_string);
      check bool "deployment state status surfaced" true
        (match deployment_state |> member "status" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "deployment state merged commit surfaced" true
        (match deployment_state |> member "merged" |> member "commit" with
         | `Null | `String _ -> true
         | _ -> false);
      check bool "deployment state built proof surfaced" true
        (match deployment_state |> member "built" |> member "proof" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "deployment state deployed path surfaced" true
        (match deployment_state |> member "deployed" |> member "executable_path" with
         | `String value -> String.length value > 0
         | _ -> false);
      check bool "deployment state match checks surfaced" true
        (match
           deployment_state |> member "checks" |> member "deployed_matches_merged"
         with
         | `Null | `Bool _ -> true
         | _ -> false);
      let stub_probe () =
        Atomic.set runtime_probe_calls (Atomic.get runtime_probe_calls + 1);
        `Assoc
          [
            ("source", `String "test runtime probe");
            ("probe_ok", `Bool true);
          ]
      in
      Lib.Server_dashboard_http.clear_dashboard_runtime_probe_cache_for_tests ();
      Lib.Server_dashboard_http.set_dashboard_runtime_probe_runner_for_tests
        stub_probe;
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
          check bool "runtime probe envelope contains generated_at" true
            (match runtime_probe |> member "generated_at" with
             | `String value -> String.length value > 0
             | _ -> false);
          check bool "runtime probe contains cache age" true
            (match runtime_probe |> member "cache_age_sec" with
             | `Float _ | `Int _ -> true
             | _ -> false);
          check bool "runtime probe contains probe payload" true
            (match runtime_probe |> member "probe" |> member "source" with
             | `String value -> String.length value > 0
             | _ -> false);
          check bool "runtime probe first request is cache miss" false
            (runtime_probe |> member "cache_hit" |> to_bool);
          check bool "runtime probe second request is cache hit" true
            (runtime_probe_cached |> member "cache_hit" |> to_bool);
          let runtime_probe_forced =
            Lib.Server_dashboard_http.dashboard_runtime_probe_http_json ~force:true ()
          in
          check bool "runtime probe forced refresh reuses recent cache" true
            (runtime_probe_forced |> member "cache_hit" |> to_bool);
          check int "runtime probe computed once" 1
            (Atomic.get runtime_probe_calls));
      (* RFC-0084 host-config-cleanup-J — [dispatch_v2_enabled] JSON
         field was removed alongside the [MASC_DISPATCH_V2] flag. *)
      let _ = usage in
      (* Hidden tools remain auto-filtered outside public_mcp_tools. *)
      let find_tool name =
        inventory_rows
        |> List.find_opt (fun row -> row |> member "name" |> to_string = name)
      in
      let has_surface surface row =
        row |> member "surfaces" |> to_list
        |> List.exists (function
             | `String value -> String.equal value surface
             | _ -> false)
      in
      let hidden_tool = find_tool "masc_code_search" in
      let public_tool = find_tool "masc_status" in
      let spawned_agent_tool = find_tool "masc_workflow_guide" in
      let local_worker_tool = find_tool "masc_worktree_create" in
      let deprecated_alias_tool = find_tool "masc_register_capabilities" in
      check bool "includes hidden tool" true (Option.is_some hidden_tool);
      check bool "includes public tool" true (Option.is_some public_tool);
      check bool "includes spawned agent tool" true
        (Option.is_some spawned_agent_tool);
      check bool "includes local worker tool" true
        (Option.is_some local_worker_tool);
      check bool "includes deprecated alias tool" true
        (Option.is_some deprecated_alias_tool);
      (match public_tool with
      | None -> ()
      | Some row ->
          check bool "public tool has registered schema" true
            (row |> member "registered_schema" |> to_bool);
          check bool "public tool has dispatch registration" true
            (row |> member "dispatch_registered" |> to_bool);
          let public_surface_count =
            row |> member "surfaces" |> to_list
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
          check bool "spawned agent tool keeps spawned_agent_mcp surface" true
            (has_surface "spawned_agent_mcp" row));
      (match local_worker_tool with
      | None -> ()
      | Some row ->
          check bool "local worker tool keeps local_worker surface" true
            (has_surface "local_worker" row));
      (match deprecated_alias_tool with
      | None -> ()
      | Some row ->
          check bool "deprecated alias has registered schema" true
            (row |> member "registered_schema" |> to_bool);
          check bool "deprecated alias has dispatch registration" true
            (row |> member "dispatch_registered" |> to_bool);
          check string "deprecated alias visibility surfaced" "hidden"
            (row |> member "visibility" |> to_string);
          check string "deprecated alias lifecycle surfaced" "deprecated"
            (row |> member "lifecycle" |> to_string);
          check string "deprecated alias replacement surfaced"
            "masc_agent_update"
            (row |> member "replacement" |> to_string);
          check bool "deprecated alias not assigned a surface" false
            (row |> member "surfaces" |> to_list <> []));
      match hidden_tool with
      | None -> ()
      | Some row ->
          check bool "hidden tool has registered schema" true
            (row |> member "registered_schema" |> to_bool);
          check bool "hidden tool has dispatch registration" true
            (row |> member "dispatch_registered" |> to_bool);
          check string "visibility surfaced" "hidden"
            (row |> member "visibility" |> to_string);
          check string "lifecycle surfaced" "active"
            (row |> member "lifecycle" |> to_string);
          check bool "direct call flag surfaced" true
            (row |> member "direct_call_allowed" |> to_bool);
          check bool "hidden tool not mislabeled public_mcp" false
            (has_surface "public_mcp" row))

let test_dashboard_tools_usage_surfaces_coverage_gap () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_stubbed_git_probe @@ fun () ->
      with_dashboard_eio @@ fun () ->
      let config = Coord_utils.default_config dir in
      seed_git_probe_cache config;
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
      check string "tool usage coverage gap health" "coverage_gap"
        (usage |> member "health" |> to_string);
      check string "tool usage coverage gap stale reason"
        "tool_usage_append_failed"
        (usage |> member "stale_reason" |> to_string);
      check int "tool usage coverage gap count" 1
        (usage |> member "coverage_gap_count" |> to_int))

let test_tool_usage_store_failure_records_coverage_gap () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_stubbed_git_probe @@ fun () ->
      let masc_root = Filename.concat dir ".masc" in
      Fs_compat.mkdir_p masc_root;
      Fs_compat.save_file (Filename.concat masc_root "tool_usage")
        "not a directory";
      Lib.Tool_usage_log.init ~base_path:dir ();
      Lib.Tool_usage_log.log_call
        ~tool_name:"keeper_tasks_list"
        ~success:true
        ~caller:(Some "oracle");
      let gaps = Lib.Telemetry_coverage_gap.read_recent ~masc_root ~n:10 in
      let reasons =
        List.filter_map
          (fun gap -> Safe_ops.json_string_opt "stale_reason" gap)
          gaps
      in
      check bool "tool usage store failure records coverage gap" true
        (List.exists
           (fun reason ->
             reason = "tool_usage_init_failed"
             || reason = "tool_usage_append_failed")
           reasons))

let test_dashboard_tools_usage_marks_store_path_collision () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_stubbed_git_probe @@ fun () ->
      with_dashboard_eio @@ fun () ->
      let config = Coord_utils.default_config dir in
      seed_git_probe_cache config;
      ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
      let masc_root = Lib.Coord.masc_root_dir config in
      Fs_compat.mkdir_p masc_root;
      Fs_compat.save_file (Filename.concat masc_root "tool_usage")
        "not a directory";
      let json = Lib.Server_dashboard_http.dashboard_tools_http_json config in
      let open Yojson.Safe.Util in
      let usage = json |> member "tool_usage" in
      check string "tool usage path collision is coverage gap"
        "coverage_gap"
        (usage |> member "health" |> to_string);
      check string "tool usage path collision stale reason"
        "tool_usage_store_not_directory"
        (usage |> member "stale_reason" |> to_string);
      check int "tool usage path collision has synthetic gap" 1
        (usage |> member "coverage_gap_count" |> to_int))

let () =
  run "dashboard_tools"
    [
      ("projection", [
           test_case "full inventory + usage summary" `Quick
             test_dashboard_tools_projection;
           test_case "tool usage surfaces coverage gap" `Quick
             test_dashboard_tools_usage_surfaces_coverage_gap;
           test_case "tool usage store failure records coverage gap" `Quick
             test_tool_usage_store_failure_records_coverage_gap;
           test_case "tool usage marks store path collision" `Quick
             test_dashboard_tools_usage_marks_store_path_collision;
         ]);
    ]
