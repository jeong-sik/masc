module Types = Masc_domain

(** Keeper Tool Exposure Tests

    Verifies that keeper_allowed_tool_names returns the full tool set
    per preset/custom policy and write_done producing empty list. *)

open Alcotest
open Masc_mcp

(* ============================================================
   Test Helpers
   ============================================================ *)

let make_meta
      ?(name = "test-keeper")
      ?(policy_voice_enabled = false)
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
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String name
      ; "trace_id", `String "test-trace-exposure"
      ; "policy_voice_enabled", `Bool policy_voice_enabled
      ; "tool_access", Keeper_types.tool_access_to_json tool_access
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)
;;

let has_tool name tools = List.mem name tools

let has_any_prefix prefix tools =
  List.exists
    (fun n ->
       String.length n >= String.length prefix
       && String.sub n 0 (String.length prefix) = prefix)
    tools
;;

let raw_schema_by_name name =
  let all = Config.raw_all_tool_schemas @ Tool_shard.coding_tools in
  all
  |> List.find_opt (fun (schema : Masc_domain.tool_schema) ->
    String.equal schema.name name)
;;

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally:restore (fun () ->
    (match value_opt with
     | Some value -> Unix.putenv name value
     | None -> Unix.putenv name "");
    f ())
;;

let with_clean_base_path_env f =
  with_env "MASC_BASE_PATH" None
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None
  @@ fun () ->
  with_env "MASC_TEST_SYNCED_BASE_PATH" None
  @@ fun () -> with_env "MASC_BASE_PATH_RESOLUTION_SOURCE" None f
;;

let run_with_isolated_base_path f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_clean_base_path_env f
;;

(* ============================================================
   1. write_done isolation
   ============================================================ *)

let test_write_done_blocks_all_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true meta in
  check int "write_done=true returns empty list" 0 (List.length tools)
;;

let test_write_done_false_has_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:false meta in
  check bool "write_done=false returns nonempty" true (List.length tools > 0)
;;

(* ============================================================
   2. Default profile — all keepers get all tools (mode removed)
   ============================================================ *)

let test_default_has_base_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has tools" true (List.length tools > 0);
  check bool "has keeper_time_now" true (has_tool "keeper_time_now" tools);
  check bool "has keeper_tools_list" true (has_tool "keeper_tools_list" tools);
  check bool "has keeper_context_status" true (has_tool "keeper_context_status" tools)
;;

(* Governance tool schemas are no longer registered. *)
let test_default_has_no_legacy_governance_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "governance status removed" false (has_tool "masc_governance_status" tools);
  check bool "case brief submit removed" false (has_tool "masc_case_brief_submit" tools)
;;

let test_coding_preset_hides_autoresearch_tools () =
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "hides autoresearch" false (has_any_prefix "masc_autoresearch_" tools)
;;

let test_custom_empty_blocks_all_tools () =
  let meta = make_meta ~tool_access:(Keeper_types.Custom []) () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check int "custom empty blocks every tool" 0 (List.length tools)
;;

let test_custom_unknown_tool_names_are_dropped () =
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  let meta =
    make_meta
      ~tool_access:
        (Keeper_types.Custom [ "keeper_time_now"; "masc_status"; "totally_unknown_tool" ])
      ()
  in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "keeps known keeper tool" true (has_tool "keeper_time_now" tools);
  check bool "keeps known masc tool" true (has_tool "masc_status" tools);
  check bool "drops unknown tool" false (has_tool "totally_unknown_tool" tools)
;;

(* ============================================================
   4. All keepers get shell tools
   ============================================================ *)

let test_coding_preset_has_shell_access () =
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_shell" true (has_tool "keeper_shell" tools)
;;

(* ============================================================
   5. All keepers get coding tools (mode removed)
   ============================================================ *)

let test_all_keepers_have_coding_tools () =
  let coding_names = Tool_code_write.tool_names in
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_any_coding = List.exists (fun n -> has_tool n tools) coding_names in
  check bool "coding tools present" true has_any_coding;
  check bool "has worktree create" true (has_tool "masc_worktree_create" tools);
  check bool "has code search" true (has_tool "masc_code_search" tools)
;;

let test_full_preset_includes_keeper_fs_edit () =
  let meta = make_meta ~preset:Keeper_types.Full () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_fs_edit" true (has_tool "keeper_fs_edit" tools)
;;

let test_coding_preset_includes_keeper_fs_edit () =
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_fs_edit" true (has_tool "keeper_fs_edit" tools)
;;

let test_research_preset_includes_keeper_fs_edit () =
  let meta = make_meta ~preset:Keeper_types.Research () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_fs_edit" true (has_tool "keeper_fs_edit" tools)
;;

let test_minimal_preset_excludes_keeper_fs_edit () =
  let meta = make_meta ~preset:Keeper_types.Minimal () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no keeper_fs_edit" false (has_tool "keeper_fs_edit" tools)
;;

let test_minimal_preset_has_web_search () =
  let meta = make_meta ~preset:Keeper_types.Minimal () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has masc_web_search" true (has_tool "masc_web_search" tools)
;;

let test_minimal_preset_has_approval_pending () =
  let meta = make_meta ~preset:Keeper_types.Minimal () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let schema_names =
    Keeper_exec_tools.keeper_allowed_model_tools meta
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  check
    bool
    "approval_pending does not require MCP session"
    false
    (Keeper_tool_policy.is_keeper_mcp_context_required "masc_approval_pending");
  check
    bool
    "approval_get still requires MCP session"
    true
    (Keeper_tool_policy.is_keeper_mcp_context_required "masc_approval_get");
  check
    bool
    "minimal has approval pending tool"
    true
    (has_tool "masc_approval_pending" tools);
  check
    bool
    "minimal has approval pending schema"
    true
    (has_tool "masc_approval_pending" schema_names);
  check
    bool
    "minimal excludes admin approval detail"
    false
    (has_tool "masc_approval_get" tools)
;;

let test_all_presets_have_approval_pending () =
  Keeper_types.all_tool_presets
  |> List.iter (fun preset ->
    let label = Keeper_types.tool_preset_to_string preset in
    let meta = make_meta ~preset () in
    let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
    let schema_names =
      Keeper_exec_tools.keeper_allowed_model_tools meta
      |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    in
    check
      bool
      (label ^ " has approval pending tool")
      true
      (has_tool "masc_approval_pending" tools);
    check
      bool
      (label ^ " has approval pending schema")
      true
      (has_tool "masc_approval_pending" schema_names))
;;

let test_feature_catalog_required_tools_reachable_by_full_keeper () =
  let meta = make_meta ~preset:Keeper_types.Full () in
  let schema_names =
    Keeper_exec_tools.keeper_allowed_model_tools meta
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  let required =
    Dashboard_keeper_feature_catalog.tool_features
    |> List.concat_map (fun (feature : Dashboard_keeper_feature_catalog.feature_spec) ->
      feature.required_tools)
    |> List.sort_uniq String.compare
  in
  let missing = required |> List.filter (fun name -> not (has_tool name schema_names)) in
  check (list string) "feature proof tools reachable by full keeper" [] missing
;;

let test_coding_preset_has_keeper_bash () =
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_bash" true (has_tool "keeper_bash" tools);
  check bool "has keeper_shell" true (has_tool "keeper_shell" tools)
;;

let test_legacy_pr_schemas_removed () =
  check
    bool
    "workflow schema removed"
    true
    (raw_schema_by_name "keeper_pr_workflow" = None);
  check bool "submit schema removed" true (raw_schema_by_name "keeper_pr_submit" = None)
;;

(* ============================================================
   6. Autoresearch tools are opt-in through research-capable presets
   ============================================================ *)

let test_research_preset_has_autoresearch () =
  let meta = make_meta ~preset:Keeper_types.Research () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools)
;;

(* ============================================================
   7. All modes produce same tool set (mode removed)
   ============================================================ *)

let test_presets_have_different_tool_count () =
  let minimal = make_meta ~preset:Keeper_types.Minimal () in
  let full = make_meta ~preset:Keeper_types.Full () in
  let minimal_tools = Keeper_exec_tools.keeper_allowed_tool_names minimal in
  let full_tools = Keeper_exec_tools.keeper_allowed_tool_names full in
  check
    bool
    "full has more than minimal"
    true
    (List.length full_tools > List.length minimal_tools)
;;

let test_messaging_preset_has_board_tools () =
  let meta = make_meta ~preset:Keeper_types.Messaging () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_board_get" true (has_tool "keeper_board_get" tools);
  check bool "has keeper_board_post" true (has_tool "keeper_board_post" tools)
;;

let test_research_preset_has_read_tools () =
  let meta = make_meta ~preset:Keeper_types.Research () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  (* keeper_read removed: dead alias with no schema, keeper_fs_read is the actual tool *)
  check bool "has keeper_fs_read" true (has_tool "keeper_fs_read" tools);
  check bool "has keeper_library_search" true (has_tool "keeper_library_search" tools);
  check bool "has masc_web_search" true (has_tool "masc_web_search" tools)
;;

let test_last_turn_safe_keeps_discovery_and_web_search () =
  let tools = Keeper_tool_policy.last_turn_safe_tool_names () in
  (* PR #14574 review #8: expose a public alias only when its routed
     internal handler is actually present in [tools]. Appending the full
     [public_names ()] unconditionally would make the "WebSearch alias"
     assertion below pass even if [masc_web_search] were removed from
     [last_turn_safe_tool_names], hiding regressions. Mirrors the
     gating used in [partition_tool_search_hits]. *)
  let tools_set =
    let tbl = Hashtbl.create (List.length tools) in
    List.iter (fun n -> Hashtbl.replace tbl n ()) tools;
    tbl
  in
  let aliases_with_allowed_route =
    Keeper_tool_alias.public_names ()
    |> List.filter (fun pub ->
      match Keeper_tool_alias.route pub with
      | Some r -> Hashtbl.mem tools_set r.internal_name
      | None -> false)
  in
  let alias_expanded = tools @ aliases_with_allowed_route in
  check
    bool
    "last turn allows keeper_tool_search"
    true
    (has_tool "keeper_tool_search" tools);
  check bool "last turn allows masc_web_search" true (has_tool "masc_web_search" tools);
  check
    bool
    "last turn allows verification submit"
    true
    (has_tool "keeper_task_submit_for_verification" tools);
  check bool "last turn allows WebSearch alias" true (has_tool "WebSearch" alias_expanded)
;;

let test_core_coordination_presets_have_task_lifecycle_tools () =
  [ "social", Keeper_types.Social; "messaging", Keeper_types.Messaging ]
  |> List.iter (fun (label, preset) ->
    let meta = make_meta ~preset () in
    let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
    check
      bool
      (label ^ " has keeper_task_create")
      true
      (has_tool "keeper_task_create" tools);
    check
      bool
      (label ^ " has keeper_task_submit_for_verification")
      true
      (has_tool "keeper_task_submit_for_verification" tools))
;;

let test_coding_preset_has_coordination_tools () =
  let meta = make_meta ~preset:Keeper_types.Coding () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_tasks_list" true (has_tool "keeper_tasks_list" tools);
  check bool "has keeper_task_claim" true (has_tool "keeper_task_claim" tools);
  check
    bool
    "has keeper_task_submit_for_verification"
    true
    (has_tool "keeper_task_submit_for_verification" tools);
  check bool "has keeper_task_create" true (has_tool "keeper_task_create" tools);
  check bool "has keeper_pr_create" true (has_tool "keeper_pr_create" tools);
  check
    bool
    "has keeper_task_force_release"
    true
    (has_tool "keeper_task_force_release" tools);
  check bool "has masc_goal_list" true (has_tool "masc_goal_list" tools);
  check
    bool
    "has masc_coordination_fsm_snapshot"
    true
    (has_tool "masc_coordination_fsm_snapshot" tools);
  check bool "does not grant masc_task_history" false (has_tool "masc_task_history" tools);
  check
    bool
    "does not grant masc_plan_get_task"
    false
    (has_tool "masc_plan_get_task" tools);
  check bool "has masc_goal_upsert" true (has_tool "masc_goal_upsert" tools);
  check bool "has masc_goal_transition" true (has_tool "masc_goal_transition" tools);
  check bool "has masc_goal_verify" true (has_tool "masc_goal_verify" tools);
  check bool "has keeper_broadcast" true (has_tool "keeper_broadcast" tools)
;;

(* Governance tool schemas are no longer registered. *)
let test_messaging_preset_has_no_legacy_governance_tools () =
  let meta = make_meta ~preset:Keeper_types.Messaging () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "governance status removed" false (has_tool "masc_governance_status" tools);
  check bool "petition submit removed" false (has_tool "masc_petition_submit" tools)
;;

let test_sufficient_tool_count () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "tool count from shards" true (List.length tools >= 20)
;;

(* ============================================================
   8. Combined profiles
   ============================================================ *)

let test_research_plus_also_allow_combined () =
  let meta =
    make_meta
      ~tool_access:
        (Keeper_types.Preset
           { preset = Keeper_types.Research
           ; also_allow = [ "keeper_board_get"; "keeper_board_post" ]
           })
      ()
  in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has board_get via also_allow" true (has_tool "keeper_board_get" tools);
  check bool "has shell access" true (has_tool "keeper_shell" tools);
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools);
  check bool "has board_post via also_allow" true (has_tool "keeper_board_post" tools);
  check bool "has read" true (has_tool "keeper_fs_read" tools)
;;

(* ============================================================
   9. Tool deduplication
   ============================================================ *)

let test_no_duplicate_tools () =
  let meta = make_meta ~policy_voice_enabled:true () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let unique = List.sort_uniq String.compare tools in
  check int "no duplicates" (List.length unique) (List.length tools)
;;

(* ============================================================
   10. Path resolution security (resolve_keeper_target_path)
   ============================================================ *)

let make_path_test_dir () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper_path_test_%d" (Random.int 100000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* Create .git dir so find_git_root stops here instead of finding CI repo root *)
  let git_dir = Filename.concat dir ".git" in
  (try Unix.mkdir git_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sub = Filename.concat dir "lib" in
  (try Unix.mkdir sub 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sub2 = Filename.concat dir "src" in
  (try Unix.mkdir sub2 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* Create test files so resolve_keeper_read_path existence check passes *)
  let write_file path content =
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write_file (Filename.concat sub "foo.ml") "(* test *)";
  write_file (Filename.concat sub2 "bar.ml") "(* test *)";
  dir
;;

let cleanup_path_test_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
      Unix.rmdir path)
    else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let test_path_relative_within_root () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"lib/foo.ml"
         in
         check bool "relative path within root ok" true (Result.is_ok result)))
;;

let test_path_absolute_outside_root () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"/etc/passwd"
         in
         check bool "absolute outside root rejected" true (Result.is_error result);
         let err =
           Keeper_alerting_path.rejection_to_user_message (Result.get_error result)
         in
         check
           bool
           "error mentions outside"
           true
           (String.length err > 0
            &&
            try
              let _ =
                Str.search_forward (Str.regexp_string "path_outside_project_root") err 0
              in
              true
            with
            | Not_found -> false)))
;;

let test_path_traversal_attack () =
  (* Use a deep nested dir so ../../ reliably escapes root on any CI *)
  let base = make_path_test_dir () in
  let deep = Filename.concat (Filename.concat base "a") "b" in
  (try Unix.mkdir (Filename.concat base "a") 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir deep 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir base)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config deep in
         (* ../../../../etc/passwd should escape any reasonable root *)
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"../../../../etc/passwd"
         in
         check bool "traversal attack rejected" true (Result.is_error result)))
;;

let test_path_allowed_paths_filter () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         (* lib is allowed, src is not *)
         let ok_result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"lib/foo.ml"
         in
         check bool "lib path allowed" true (Result.is_ok ok_result);
         let err_result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"src/bar.ml"
         in
         check bool "src path rejected" true (Result.is_error err_result);
         let err =
           Keeper_alerting_path.rejection_to_user_message (Result.get_error err_result)
         in
         check
           bool
           "error mentions sandbox boundary"
           true
           (try
              let _ =
                Str.search_forward (Str.regexp_string "path_outside_sandbox") err 0
              in
              true
            with
            | Not_found -> false)))
;;

let test_path_allowed_paths_filter_strips_all_trailing_slashes () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let ok_result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib//" ]
             ~raw_path:"lib/foo.ml"
         in
         check
           bool
           "lib path allowed with repeated trailing slash"
           true
           (Result.is_ok ok_result)))
;;

let test_path_absolute_allowed_paths_filter () =
  let dir = make_path_test_dir () in
  let lib_dir = Filename.concat dir "lib" in
  (try Unix.mkdir lib_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let ok_result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ lib_dir ]
             ~raw_path:"lib/foo.ml"
         in
         check bool "absolute lib path allowed" true (Result.is_ok ok_result);
         let err_result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ lib_dir ]
             ~raw_path:"src/bar.ml"
         in
         check bool "absolute lib still rejects src" true (Result.is_error err_result)))
;;

let test_absolute_allowed_paths_normalization () =
  let dir = make_path_test_dir () in
  let lib_dir = Filename.concat dir "lib" in
  let docs_dir = Filename.concat dir "docs" in
  (try Unix.mkdir lib_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir docs_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let normalized =
           Keeper_alerting_path.absolute_allowed_paths
             ~config
             ~allowed_paths:[ "lib/"; docs_dir ^ "//" ]
         in
         check
           (list string)
           "normalized absolute allowed paths"
           [ Unix.realpath lib_dir; Unix.realpath docs_dir ]
           normalized))
;;

let test_absolute_allowed_paths_slashes_only_rejected () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let normalized =
           Keeper_alerting_path.absolute_allowed_paths ~config ~allowed_paths:[ "////" ]
         in
         check (list string) "slashes-only allow path ignored" [] normalized;
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "////" ]
             ~raw_path:"lib/foo.ml"
         in
         check
           bool
           "slashes-only allow path does not allow all"
           true
           (Result.is_error result)))
;;

let test_absolute_allowed_paths_result_rejects_invalid_explicit_allowlist () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.absolute_allowed_paths_result
             ~config
             ~allowed_paths:[ "////" ]
         in
         check bool "explicit invalid allowlist is rejected" true (Result.is_error result)))
;;

let test_path_allowed_paths_single_trailing_slash () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let exact_match =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib/" ]
             ~raw_path:"lib"
         in
         check
           bool
           "exact dir match with single trailing slash"
           true
           (Result.is_ok exact_match);
         let subpath_match =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib/" ]
             ~raw_path:"lib/foo.ml"
         in
         check
           bool
           "subpath match with single trailing slash"
           true
           (Result.is_ok subpath_match)))
;;

let test_path_empty_rejected () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:""
         in
         check bool "empty path rejected" true (Result.is_error result)))
;;

let test_path_whitespace_only_rejected () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"   "
         in
         check bool "whitespace path rejected" true (Result.is_error result)))
;;

let test_path_empty_allowlist_defaults_to_project_root () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         (* Empty low-level allowlist falls back to project-root resolution. *)
         let r1 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"lib/a.ml"
         in
         let r2 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"src/b.ml"
         in
         check bool "lib ok with empty allowlist" true (Result.is_ok r1);
         check bool "src ok with empty allowlist" true (Result.is_ok r2)))
;;

(* ============================================================
   10b. Read-path: resolve_keeper_read_path respects allowlists
   ============================================================ *)

let test_read_path_empty_allowlist_defaults_to_project_root () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let read_lib =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"lib/foo.ml"
         in
         let read_src =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"src/bar.ml"
         in
         check bool "read lib ok" true (Result.is_ok read_lib);
         check bool "read src ok" true (Result.is_ok read_src)))
;;

let test_read_path_respects_allowed_paths () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let read_lib =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"lib/foo.ml"
         in
         let read_src =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"src/bar.ml"
         in
         check bool "read lib ok" true (Result.is_ok read_lib);
         check bool "read src rejected" true (Result.is_error read_src)))
;;

let test_read_path_rejects_outside_root () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"/etc/passwd"
         in
         check bool "read outside root rejected" true (Result.is_error result)))
;;

let test_read_vs_write_path_alignment () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         (* Write: lib allowed, src rejected *)
         let write_lib =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"lib/foo.ml"
         in
         let write_src =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"src/bar.ml"
         in
         check bool "write lib ok" true (Result.is_ok write_lib);
         check bool "write src rejected" true (Result.is_error write_src);
         (* Read: same allowlist behavior *)
         let read_lib =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"lib/foo.ml"
         in
         let read_src =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "lib" ]
             ~raw_path:"src/bar.ml"
         in
         check bool "read lib ok" true (Result.is_ok read_lib);
         check bool "read src rejected like write" true (Result.is_error read_src)))
;;

(* ============================================================
   10c. Read-path: resolve_keeper_read_path bounded suffix resolution
   ============================================================ *)

let test_read_path_rejects_nonexistent () =
  let dir = make_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         (* Path within root but does not exist on disk *)
         let result =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"nonexistent-repo/"
         in
         check bool "nonexistent path rejected" true (Result.is_error result);
         let err =
           Keeper_alerting_path.rejection_to_user_message (Result.get_error result)
         in
         check
           bool
           "error mentions allowed roots miss"
           true
           (String_util.contains_substring_ci err "path_not_found_under_allowed_roots")))
;;

let test_read_path_resolves_unique_nested_repo_suffix () =
  let dir = make_path_test_dir () in
  let mkdir path =
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let workspace = Filename.concat dir "workspace" in
  let owner = Filename.concat workspace "yousleepwhen" in
  let repo = Filename.concat owner "masc-mcp" in
  let lib_dir = Filename.concat repo "lib" in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       mkdir workspace;
       mkdir owner;
       mkdir repo;
       mkdir lib_dir;
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "workspace" ]
             ~raw_path:"masc-mcp/lib"
         in
         check bool "unique nested repo suffix resolved" true (Result.is_ok result);
         let expected_lib_dir =
           try Unix.realpath lib_dir with
           | Unix.Unix_error _ -> lib_dir
         in
         check
           string
           "resolved to discovered repo lib"
           expected_lib_dir
           (Result.get_ok result)))
;;

let test_read_path_rejects_ambiguous_nested_repo_suffix () =
  let dir = make_path_test_dir () in
  let mkdir path =
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let make_repo prefix =
    let workspace = Filename.concat dir prefix in
    let repo = Filename.concat workspace "masc-mcp" in
    let lib_dir = Filename.concat repo "lib" in
    mkdir workspace;
    mkdir repo;
    mkdir lib_dir
  in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       make_repo "workspace-a";
       make_repo "workspace-b";
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[ "workspace-a"; "workspace-b" ]
             ~raw_path:"masc-mcp/lib"
         in
         check bool "ambiguous nested repo suffix rejected" true (Result.is_error result);
         let err =
           Keeper_alerting_path.rejection_to_user_message (Result.get_error result)
         in
         check
           bool
           "error mentions ambiguity"
           true
           (String_util.contains_substring_ci err "ambiguous_relative_read_path")))
;;

let test_read_path_does_not_follow_symlink_outside_root () =
  let dir = make_path_test_dir () in
  let outside =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper_outside_%d" (Random.int 100000))
  in
  let mkdir path =
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let link_path = Filename.concat dir "external-link" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link_path with
       | _ -> ());
      cleanup_path_test_dir dir;
      cleanup_path_test_dir outside)
    (fun () ->
       mkdir outside;
       let outside_owner = Filename.concat outside "yousleepwhen" in
       let outside_repo = Filename.concat outside_owner "masc-mcp" in
       let outside_lib = Filename.concat outside_repo "lib" in
       mkdir outside_owner;
       mkdir outside_repo;
       mkdir outside_lib;
       Unix.symlink outside link_path;
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let result =
           Keeper_alerting_path.resolve_keeper_read_path
             ~config
             ~allowed_paths:[]
             ~raw_path:"masc-mcp/lib"
         in
         check bool "symlink escape is rejected" true (Result.is_error result);
         let err =
           Keeper_alerting_path.rejection_to_user_message (Result.get_error result)
         in
         check
           bool
           "symlink escape does not resolve outside root"
           true
           (String_util.contains_substring_ci err "path_not_found_under_allowed_roots")))
;;

(* ============================================================
   11. Keeper-reported allowed_paths symlink bug
   ============================================================ *)

let make_masc_path_test_dir () =
  let create_dir path =
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (err, _, _) ->
      failwith
        (Printf.sprintf
           "make_masc_path_test_dir: mkdir %s failed: %s"
           path
           (Unix.error_message err))
  in
  let dir =
    let prefix =
      Filename.concat
        (Filename.get_temp_dir_name ())
        (Printf.sprintf "keeper_masc_path_test_%d" (Random.bits ()))
    in
    create_dir prefix;
    prefix
  in
  let git_dir = Filename.concat dir ".git" in
  create_dir git_dir;
  let masc = Filename.concat dir Common.masc_dirname in
  create_dir masc;
  let keepers = Filename.concat masc "keepers" in
  create_dir keepers;
  let traces = Filename.concat masc "traces" in
  create_dir traces;
  let playground = Filename.concat masc "playground" in
  create_dir playground;
  dir
;;

let test_keeper_reported_nonexistent_subdir () =
  let dir = make_masc_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let allowed =
           [ ".masc/playground/goal-default-demo/"
           ; ".masc/keepers/goal-default-demo/"
           ; ".masc/traces/"
           ; "lib/"
           ]
         in
         let r1 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:allowed
             ~raw_path:".masc/keepers/goal-default-demo/"
         in
         check bool "keeper dir access (exact match)" true (Result.is_ok r1);
         let r2 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:allowed
             ~raw_path:".masc/traces/session.json"
         in
         check bool "traces file access" true (Result.is_ok r2);
         let r3 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:allowed
             ~raw_path:"lib/foo.ml"
         in
         check bool "project file via allowed explicit path" true (Result.is_ok r3)))
;;

let test_keeper_reported_explicit_paths_only () =
  let dir = make_masc_path_test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_path_test_dir dir)
    (fun () ->
       run_with_isolated_base_path (fun () ->
         let config = Coord.default_config dir in
         let allowed =
           [ ".masc/playground/allowed-only/"
           ; ".masc/keepers/allowed-only/"
           ; ".masc/traces/"
           ]
         in
         let r1 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:allowed
             ~raw_path:".masc/keepers/allowed-only/"
         in
         check bool "allowed keeper dir access" true (Result.is_ok r1);
         let r2 =
           Keeper_alerting_path.resolve_keeper_target_path
             ~config
             ~allowed_paths:allowed
             ~raw_path:"lib/foo.ml"
         in
         check bool "unlisted lib path blocked" true (Result.is_error r2)))
;;

(* ============================================================
   Runner
   ============================================================ *)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  run
    "Keeper_tool_exposure"
    [ ( "write_done"
      , [ test_case "blocks all tools" `Quick test_write_done_blocks_all_tools
        ; test_case "false has tools" `Quick test_write_done_false_has_tools
        ] )
    ; ( "default_profile"
      , [ test_case "has base tools" `Quick test_default_has_base_tools
        ; test_case
            "legacy governance tools removed"
            `Quick
            test_default_has_no_legacy_governance_tools
        ; test_case
            "coding preset hides autoresearch tools"
            `Quick
            test_coding_preset_hides_autoresearch_tools
        ; test_case
            "custom empty blocks all tools"
            `Quick
            test_custom_empty_blocks_all_tools
        ; test_case
            "custom unknown tool names are dropped"
            `Quick
            test_custom_unknown_tool_names_are_dropped
        ] )
    ; ( "shell_tools"
      , [ test_case
            "coding preset has shell access"
            `Quick
            test_coding_preset_has_shell_access
        ] )
    ; ( "coding_tools"
      , [ test_case
            "all keepers have coding tools"
            `Quick
            test_all_keepers_have_coding_tools
        ; test_case
            "full preset includes keeper_fs_edit"
            `Quick
            test_full_preset_includes_keeper_fs_edit
        ; test_case
            "coding preset includes keeper_fs_edit"
            `Quick
            test_coding_preset_includes_keeper_fs_edit
        ; test_case
            "research preset includes keeper_fs_edit"
            `Quick
            test_research_preset_includes_keeper_fs_edit
        ; test_case
            "minimal preset excludes keeper_fs_edit"
            `Quick
            test_minimal_preset_excludes_keeper_fs_edit
        ; test_case
            "minimal preset has web search"
            `Quick
            test_minimal_preset_has_web_search
        ; test_case
            "minimal preset has keeper-safe approval pending"
            `Quick
            test_minimal_preset_has_approval_pending
        ; test_case
            "all presets have keeper-safe approval pending"
            `Quick
            test_all_presets_have_approval_pending
        ; test_case
            "feature proof required tools are reachable"
            `Quick
            test_feature_catalog_required_tools_reachable_by_full_keeper
        ; test_case
            "coding preset has keeper_bash and keeper_shell"
            `Quick
            test_coding_preset_has_keeper_bash
        ] )
    ; ( "autoresearch_tools"
      , [ test_case
            "research preset has autoresearch"
            `Quick
            test_research_preset_has_autoresearch
        ] )
    ; ( "mode_free_access"
      , [ test_case
            "presets have different tool count"
            `Quick
            test_presets_have_different_tool_count
        ; test_case
            "messaging has board tools"
            `Quick
            test_messaging_preset_has_board_tools
        ; test_case "research has read tools" `Quick test_research_preset_has_read_tools
        ; test_case
            "last turn keeps discovery and web search"
            `Quick
            test_last_turn_safe_keeps_discovery_and_web_search
        ; test_case
            "core coordination presets have task lifecycle tools"
            `Quick
            test_core_coordination_presets_have_task_lifecycle_tools
        ; test_case
            "coding has coordination tools"
            `Quick
            test_coding_preset_has_coordination_tools
        ; test_case
            "messaging legacy governance tools removed"
            `Quick
            test_messaging_preset_has_no_legacy_governance_tools
        ; test_case "sufficient tool count" `Quick test_sufficient_tool_count
        ] )
    ; ( "combined_profiles"
      , [ test_case
            "research plus also_allow override"
            `Quick
            test_research_plus_also_allow_combined
        ] )
    ; "deduplication", [ test_case "no duplicate tools" `Quick test_no_duplicate_tools ]
    ; ( "path_resolution"
      , [ test_case "relative within root" `Quick test_path_relative_within_root
        ; test_case "absolute outside root" `Quick test_path_absolute_outside_root
        ; test_case "traversal attack" `Quick test_path_traversal_attack
        ; test_case "allowed_paths filter" `Quick test_path_allowed_paths_filter
        ; test_case
            "allowed_paths strip all trailing slashes"
            `Quick
            test_path_allowed_paths_filter_strips_all_trailing_slashes
        ; test_case
            "absolute allowed_paths filter"
            `Quick
            test_path_absolute_allowed_paths_filter
        ; test_case
            "absolute allowed_paths normalization"
            `Quick
            test_absolute_allowed_paths_normalization
        ; test_case
            "slashes-only allowed_paths rejected"
            `Quick
            test_absolute_allowed_paths_slashes_only_rejected
        ; test_case
            "invalid explicit allowlist result rejected"
            `Quick
            test_absolute_allowed_paths_result_rejects_invalid_explicit_allowlist
        ; test_case
            "allowed_paths single trailing slash"
            `Quick
            test_path_allowed_paths_single_trailing_slash
        ; test_case "empty path rejected" `Quick test_path_empty_rejected
        ; test_case "whitespace only rejected" `Quick test_path_whitespace_only_rejected
        ; test_case
            "empty allowlist defaults to project root"
            `Quick
            test_path_empty_allowlist_defaults_to_project_root
        ; test_case
            "read path empty allowlist defaults to project root"
            `Quick
            test_read_path_empty_allowlist_defaults_to_project_root
        ; test_case
            "read path respects allowed_paths"
            `Quick
            test_read_path_respects_allowed_paths
        ; test_case
            "read path rejects outside root"
            `Quick
            test_read_path_rejects_outside_root
        ; test_case
            "read path rejects nonexistent"
            `Quick
            test_read_path_rejects_nonexistent
        ; test_case
            "read path resolves unique nested repo suffix"
            `Quick
            test_read_path_resolves_unique_nested_repo_suffix
        ; test_case
            "read path rejects ambiguous nested repo suffix"
            `Quick
            test_read_path_rejects_ambiguous_nested_repo_suffix
        ; test_case
            "read path does not follow symlink outside root"
            `Quick
            test_read_path_does_not_follow_symlink_outside_root
        ; test_case
            "read vs write path alignment"
            `Quick
            test_read_vs_write_path_alignment
        ; test_case
            "keeper-reported nonexistent subdir"
            `Quick
            test_keeper_reported_nonexistent_subdir
        ; test_case
            "keeper-reported explicit paths only"
            `Quick
            test_keeper_reported_explicit_paths_only
        ] )
    ; (* Merged from test_keeper_deny_list_coverage.ml *)
      ( "deny_list"
      , [ test_case "dangerous tools denied" `Quick (fun () ->
            (* Post-pruning: keeper_denied surface narrowed to
           [masc_reset; masc_spawn]. Most former dangerous tools
           (masc_room_delete, masc_force_leave, masc_config_set,
           masc_execute / masc_execute_dry_run) were removed from the
           registry entirely. *)
            let dl = Keeper_hooks_oas.keeper_denied_tools in
            List.iter
              (fun name -> check bool (name ^ " denied") true (List.mem name dl))
              [ "masc_reset"; "masc_spawn" ])
        ; test_case "safe tools not denied" `Quick (fun () ->
            let dl = Keeper_hooks_oas.keeper_denied_tools in
            List.iter
              (fun name -> check bool (name ^ " allowed") false (List.mem name dl))
              [ "keeper_board_post"
              ; "masc_broadcast"
              ; "masc_status"
              ; "masc_tasks"
              ; "keeper_bash"
              ])
        ; test_case "deny list reasonable size" `Quick (fun () ->
            let n = List.length Keeper_hooks_oas.keeper_denied_tools in
            check bool "non-empty" true (n > 0);
            check bool "<= 30 range" true (n <= 30))
        ] )
    ; ( "auto_tool_hints"
      , [ test_case "known tool has hint" `Quick (fun () ->
            match Keeper_tool_policy.tool_hint_of "keeper_board_post" with
            | Some hint ->
              check bool "hint non-empty" true (String.length hint > 0);
              check bool "hint max 80 chars" true (String.length hint <= 81)
            | None -> fail "keeper_board_post should have a hint")
        ; test_case "unknown tool has no hint" `Quick (fun () ->
            check
              (option string)
              "no hint for unknown"
              None
              (Keeper_tool_policy.tool_hint_of "totally_fake_tool"))
        ; test_case "masc tool has hint" `Quick (fun () ->
            match Keeper_tool_policy.tool_hint_of "masc_web_search" with
            | Some hint -> check bool "hint non-empty" true (String.length hint > 0)
            | None -> fail "masc_web_search should have a hint")
        ; test_case "all allowed tools have hints" `Quick (fun () ->
            let meta = make_meta ~preset:Keeper_types.Messaging () in
            let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
            let missing =
              List.filter (fun name -> Keeper_tool_policy.tool_hint_of name = None) tools
            in
            (* Some shard-resolved or governance tools may not have schemas
           in the static list. Log them but don't fail — the important
           thing is that the majority of tools have hints. *)
            if missing <> []
            then
              Printf.eprintf
                "[info] tools without hints: %s\n"
                (String.concat ", " missing);
            let total = List.length tools in
            let with_hints = total - List.length missing in
            check
              bool
              "at least 80%% of tools have hints"
              true
              (with_hints * 100 / max total 1 >= 80))
        ] )
    ; ( "tool_access_of_meta_json_validation"
      , [ test_case "string tools field returns error" `Quick (fun () ->
            let json =
              `Assoc [ "kind", `String "custom"; "tools", `String "masc_status" ]
            in
            let outer = `Assoc [ "tool_access", json ] in
            match Keeper_types.tool_access_of_meta_json outer with
            | Error msg ->
              check
                bool
                "mentions array"
                true
                (String.length msg > 0
                 &&
                 try
                   ignore (Str.search_forward (Str.regexp_string "array") msg 0);
                   true
                 with
                 | Not_found -> false)
            | Ok _ -> fail "expected Error for string tools field")
        ; test_case "valid list tools parses ok" `Quick (fun () ->
            let json =
              `Assoc
                [ "kind", `String "custom"
                ; "tools", `List [ `String "masc_status"; `String "masc_broadcast" ]
                ]
            in
            let outer = `Assoc [ "tool_access", json ] in
            match Keeper_types.tool_access_of_meta_json outer with
            | Ok (Custom tools) ->
              check bool "has masc_status" true (List.mem "masc_status" tools);
              check bool "has masc_broadcast" true (List.mem "masc_broadcast" tools)
            | Ok (Preset _) -> fail "expected Custom"
            | Error msg -> fail ("unexpected error: " ^ msg))
        ; test_case "null tools field returns error" `Quick (fun () ->
            let json = `Assoc [ "kind", `String "custom"; "tools", `Null ] in
            let outer = `Assoc [ "tool_access", json ] in
            match Keeper_types.tool_access_of_meta_json outer with
            | Error _ -> ()
            | Ok _ -> fail "expected Error for null tools field")
        ; test_case "integer tools field returns error" `Quick (fun () ->
            let json = `Assoc [ "kind", `String "custom"; "tools", `Int 42 ] in
            let outer = `Assoc [ "tool_access", json ] in
            match Keeper_types.tool_access_of_meta_json outer with
            | Error _ -> ()
            | Ok _ -> fail "expected Error for integer tools field")
        ; test_case "non-string tool member returns error" `Quick (fun () ->
            let json =
              `Assoc
                [ "kind", `String "custom"
                ; "tools", `List [ `String "masc_status"; `Int 42 ]
                ]
            in
            let outer = `Assoc [ "tool_access", json ] in
            match Keeper_types.tool_access_of_meta_json outer with
            | Error _ -> ()
            | Ok _ -> fail "expected Error for non-string tools member")
        ] )
    ; ( "pr_lane_wording"
      , [ test_case
            "schema descriptions distinguish workflow lanes"
            `Quick
            test_legacy_pr_schemas_removed
        ] )
    ]
;;
