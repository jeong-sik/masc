(** Harness tests for WARN root cause fixes.

    1. Tool access discovery: the per-turn core surface
       (effective_core_tools) stays visible across narrow tool_access lists
       and is hidden by denylist
    2. Atomic agent JSON writes: no empty-file race condition *)

open Alcotest
open Masc

(* ── Helpers ──────────────────────────────────────────────────── *)

let init_registry () =
  Masc_test_deps.init_keeper_tool_registry ()

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        if String.length pattern = 0 then true
        else
          let re = Str.regexp_string pattern in
          (try ignore (Str.search_forward re content 0); true
           with Not_found -> false))

let file_not_contains_pattern file_rel pattern =
  not (file_contains_pattern file_rel pattern)

let string_contains text pattern =
  if String.length pattern = 0 then true
  else
    let re = Str.regexp_string pattern in
    try
      ignore (Str.search_forward re text 0);
      true
    with Not_found -> false

let require_write_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s: %s" label msg

let make_meta ?(name = "test-keeper") () : Keeper_meta_contract.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-warn")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

(** Build the visible policy set used by the local filter mirror. *)
let build_policy_allowed_tool_set (meta : Keeper_meta_contract.keeper_meta) =
  let allowed_names = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  let internal_set = Keeper_tool_policy.tool_name_set allowed_names in
  let public_of_internal name =
    match Keeper_tool_descriptor_resolution.public_names_for_internal name with
    | [] -> [ name ]
    | public_names -> public_names
  in
  let public_set =
    Keeper_tool_policy.StringSet.of_list
      (List.concat_map public_of_internal allowed_names)
  in
  Keeper_tool_policy.StringSet.union
    (Keeper_tool_policy.StringSet.union internal_set public_set)
    (Keeper_tool_policy.tool_name_set Keeper_tool_registry.core_always_tools)

(** Filter the PRODUCTION per-turn core surface through the current
    policy-visible set. [effective_core_tools ()] is the exact function the
    keeper turn loop uses to build the always-visible core (see
    [Keeper_run_tools_setup.compute_tool_surface]); asserting against it — not
    the static [core_discovery_tools] discovery pool — is what makes the #23440
    shadowing/exclusion regression fail CI. *)
let filter_core_by_tool_access (meta : Keeper_meta_contract.keeper_meta) =
  let policy_allowed_tool_set = build_policy_allowed_tool_set meta in
  List.filter
    (fun name -> Keeper_tool_policy.StringSet.mem name policy_allowed_tool_set)
    (Keeper_tool_dispatch_runtime.effective_core_tools ())

let write_tools = [ "Edit" ]

let shell_bridge_tools = [ "Execute" ]
let read_model_tools = [ "Grep"; "Read" ]

let write_enabled_tool_access =
  [ "tool_edit_file"; "tool_execute" ]

let test_core_tools_visible_with_empty_tool_access () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-empty-access" ()) with
      tool_access = [];
      tool_denylist = [] }
  in
  (* Precondition: the native-executor code tools are in the unfiltered
     production core surface, so a filtered-out result below is the policy
     filter's doing rather than an absent base entry. *)
  let unfiltered_core = Keeper_tool_dispatch_runtime.effective_core_tools () in
  List.iter (fun t ->
    if not (List.mem t unfiltered_core) then
      fail (Printf.sprintf "precondition: %s missing from effective_core_tools" t)
  ) (write_tools @ read_model_tools);
  let filtered = filter_core_by_tool_access meta in
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "%s must stay visible without explicit tool_access" t)
  ) (write_tools @ read_model_tools);
  (* Core always-tools must survive *)
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "core_always %s must survive tool_access filter" t)
  ) Keeper_tool_registry.core_always_tools

let test_core_tools_visible_with_read_only_tool_access () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-read-only-access" ()) with
      tool_access = [ "tool_read_file"; "tool_search_files" ];
      tool_denylist = [] }
  in
  let filtered = filter_core_by_tool_access meta in
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "%s should stay visible for read-only tool_access" t)
  ) (write_tools @ read_model_tools)

let test_core_tools_include_write_for_write_enabled_tool_access () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-write-access" ()) with
      tool_access = write_enabled_tool_access;
      tool_denylist = [] }
  in
  let filtered = filter_core_by_tool_access meta in
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "%s should be included for write-enabled tool_access" t)
  ) (write_tools @ shell_bridge_tools)

let test_core_tools_hidden_by_denylist () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-deny-access" ()) with
      tool_access = [];
      tool_denylist = [ "Edit"; "Search" ] }
  in
  let filtered = filter_core_by_tool_access meta in
  List.iter (fun t ->
    if List.mem t filtered then
      fail (Printf.sprintf "%s should be excluded by denylist" t)
  ) [ "Edit"; "Grep"; "Search" ]

let test_web_alias_bundle_visible_without_injected_masc_schema () =
  ignore (init_registry ());
  let prior_masc_schemas = Keeper_tool_dispatch_runtime.masc_schemas_snapshot () in
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_web_alias_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_dispatch_runtime.set_masc_schemas prior_masc_schemas;
      try Unix.rmdir dir with _ -> ())
    (fun () ->
      Keeper_tool_dispatch_runtime.set_masc_schemas [];
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-web-alias-no-injected-schema" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
          ~max_tokens:4000
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle ~config ~meta ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
          in
          check bool "WebSearch remains bundle-visible" true
            (List.mem "WebSearch" names);
          check bool "WebFetch remains bundle-visible" true
            (List.mem "WebFetch" names);
          check bool "Grep preferred projection is bundle-visible" true
            (List.mem "Grep" names);
          check bool "Search compatibility alias is not model-visible" false
            (List.mem "Search" names);
          check bool "search_files compatibility alias is not model-visible" false
            (List.mem "search_files" names);
          check bool "Grep internal route is not model-visible" false
            (List.mem "tool_search_files" names);
          check int
            "bundle model names are unique"
            (List.length names)
            (List.length (List.sort_uniq String.compare names))))

let test_fusion_default_descriptor_is_bundle_visible () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_fusion_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-fusion-default-descriptor" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
          ~max_tokens:4000
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle ~config ~meta ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
          in
          check bool "masc_fusion is in the executable OAS tool bundle" true
            (List.mem "masc_fusion" names)))

let test_missing_current_task_reconciled_before_transition_hint () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_stale_task_hint_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test-stale-task-hint"));
      let task_id =
        match Keeper_id.Task_id.of_string "task-1468" with
        | Ok task_id -> task_id
        | Error msg -> failf "task id parse failed: %s" msg
      in
      let meta =
        { (make_meta ~name:"test-stale-task-hint" ()) with
          current_task_id = Some task_id
        }
      in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
          ~max_tokens:4000
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle ~config ~meta ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let description =
            bundle.tools
            |> List.find_map (fun (tool : Agent_sdk.Tool.t) ->
                 if String.equal tool.schema.name "masc_transition"
                 then Some tool.schema.description
                 else None)
          in
          match description with
          | None -> fail "masc_transition not found in bundle"
          | Some description ->
            check bool "missing task hint removed" false
              (string_contains description "not found in backlog");
            check bool "reconciled hint asks for claim/list" true
              (string_contains description "No task currently assigned")))

let test_tool_bundle_does_not_emit_full_universe_assignment () =
  ignore (init_registry ());
  Tool_assignment_telemetry.reset_for_testing ();
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_assignment_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-assignment-bundle" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
          ~max_tokens:4000
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle ~config ~meta ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          check
            (option string)
            "bundle assembly must not claim an LLM-visible assignment"
            None
            (Tool_assignment_telemetry.find_latest_assignment_id
               ~agent_id:meta.agent_name)))

let test_tool_assignment_telemetry_is_before_turn_scoped () =
  check bool "bundle source does not emit assignment" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_oas_bundle.ml"
       "Tool_assignment_telemetry.emit_assigned");
  check bool "legacy bundle reason removed" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_oas_bundle.ml"
       "keeper tool bundle assembly");
  check bool "before-turn hook records computed schema filter" true
    (file_contains_pattern
       "lib/keeper/keeper_run_tools_hooks.ml"
       "record_tool_assignment ~turn ~tool_list:schema_filter ~lane");
  check bool "setup owns assignment telemetry emission" true
    (file_contains_pattern
       "lib/keeper/keeper_run_tools_setup.ml"
       "Tool_assignment_telemetry.emit_assigned")

(* ── Test 2: Atomic agent JSON writes ─────────────────────────── *)

let test_atomic_write_not_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_atomic_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "test_agent.json" in
  let json =
    `Assoc [ ("name", `String "test"); ("status", `String "ok") ]
  in
  require_write_ok "atomic write" (Workspace_utils.write_json_local path json);
  let content = Fs_compat.load_file path in
  check bool "file not empty after atomic write" true
    (String.length content > 0);
  let parsed = Yojson.Safe.from_string content in
  check string "name field" "test"
    (Yojson.Safe.Util.member "name" parsed |> Yojson.Safe.Util.to_string);
  (* Verify .tmp is cleaned up *)
  check bool "no leftover .tmp" false (Sys.file_exists (path ^ ".tmp"));
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(** Concurrent writes via atomic pattern must never produce empty reads. *)
let test_concurrent_atomic_writes_never_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_concurrent_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "agent.json" in
  (* Seed with initial content *)
  require_write_ok "seed write"
    (Workspace_utils.write_json_local path
       (`Assoc [ ("name", `String "init") ]));
  let empty_seen = ref false in
  let iterations = 200 in
  Eio.Switch.run @@ fun sw ->
  (* Writer fiber: rapidly update the file *)
  Eio.Fiber.fork ~sw (fun () ->
    for i = 1 to iterations do
      let json =
        `Assoc [ ("name", `String (Printf.sprintf "v%d" i)) ]
      in
      require_write_ok "concurrent write" (Workspace_utils.write_json_local path json);
      Eio.Fiber.yield ()
    done);
  (* Reader fiber: read concurrently *)
  Eio.Fiber.fork ~sw (fun () ->
    for _ = 1 to iterations do
      (try
         let content = Fs_compat.load_file path in
         if String.trim content = "" then empty_seen := true
       with _ -> ());
      Eio.Fiber.yield ()
    done);
  check bool "concurrent reads never see empty file" false !empty_seen;
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(* ── Test 3: Keeper/OAS failure severities on main path ─────────────── *)

let test_keeper_mainline_failures_log_at_error () =
  check bool "missing checkpoint after run logs at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_run_finalize_response.ml"
       {|"runtime=%s missing OAS checkpoint after run"|});
  check bool "memory write failures log at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|"memory_write failed: %s"|});
  check bool "memory write failures are no longer WARN" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|Log.Keeper.warn
               "memory_write failed: %s"|});
  check bool "stale episode creation failure string is absent" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run.ml"
       {|episode_create failed|})

let test_oas_mainline_warns_are_promoted_in_bridge () =
  check bool "bridge promotes MCP server failure" true
    (file_contains_pattern "lib/agent_sdk_log_bridge.ml"
       {|Warn, "agent_config", "MCP server failed" -> true|});
  check bool "bridge promotes context injector failure" true
    (file_contains_pattern "lib/agent_sdk_log_bridge.ml"
       {|Warn, "agent_turn", "context_injector raised" -> true|});
  check bool "bridge promotes approval callback gap" true
    (file_contains_pattern "lib/agent_sdk_log_bridge.ml"
       {|Warn, "agent_tools", "ApprovalRequired but no approval callback — executing"|})

let test_correction_pipeline_log_preserves_detail_fields () =
  List.iter
    (fun (key, pattern) ->
      check bool ("bridge renders correction detail " ^ key) true
        (file_contains_pattern "lib/agent_sdk_log_bridge.ml"
           pattern))
    [ "fields", {|[ "fields"|}
    ; "stages", {|; "stages"|}
    ; "input_keys", {|; "input_keys"|}
    ; "corrected_keys", {|; "corrected_keys"|}
    ; "added_fields", {|; "added_fields"|}
    ; "changed_fields", {|; "changed_fields"|}
    ]

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  run "Warn_root_causes"
    [
      ( "allowlist_tool_access_filter",
        [
          test_case "empty tool_access keeps descriptor public tools visible" `Quick
            test_core_tools_visible_with_empty_tool_access;
          test_case "read-only tool_access keeps descriptor public tools visible" `Quick
            test_core_tools_visible_with_read_only_tool_access;
          test_case "write-enabled tool_access includes shell + write tools" `Quick
            test_core_tools_include_write_for_write_enabled_tool_access;
          test_case "denylist excludes descriptor public tools" `Quick
            test_core_tools_hidden_by_denylist;
          test_case "web aliases survive missing injected masc schema" `Quick
            test_web_alias_bundle_visible_without_injected_masc_schema;
          test_case "fusion default descriptor reaches OAS bundle" `Quick
            test_fusion_default_descriptor_is_bundle_visible;
          test_case "missing current task reconciles before transition hint" `Quick
            test_missing_current_task_reconciled_before_transition_hint;
          test_case "bundle assembly does not emit assignment" `Quick
            test_tool_bundle_does_not_emit_full_universe_assignment;
          test_case "assignment telemetry is before-turn scoped" `Quick
            test_tool_assignment_telemetry_is_before_turn_scoped;
        ] );
      ( "atomic_agent_json",
        [
          test_case "atomic write produces non-empty file" `Quick
            test_atomic_write_not_empty;
          test_case "concurrent writes never produce empty reads" `Quick
            test_concurrent_atomic_writes_never_empty;
        ] );
      ( "mainline_failure_levels",
        [
          test_case "keeper mainline failures log at error" `Quick
            test_keeper_mainline_failures_log_at_error;
          test_case "oas mainline warns are promoted in bridge" `Quick
            test_oas_mainline_warns_are_promoted_in_bridge;
          test_case "correction pipeline log preserves detail fields" `Quick
            test_correction_pipeline_log_preserves_detail_fields;
        ] );
    ]
