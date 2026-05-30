(** Harness tests for WARN root cause fixes.

    1. AllowList pruning: core_discovery_tools filtered by preset
    2. Atomic agent JSON writes: no empty-file race condition *)

open Alcotest
open Masc_mcp

(* ── Helpers ──────────────────────────────────────────────────── *)

let init_registry () =
  Masc_test_deps.init_keeper_tool_registry ();
  let base_path = Masc_test_deps.find_project_root () in
  match Keeper_tool_policy.init_policy_config ~base_path with
  | Ok () -> ()
  | Error e -> failwith (Printf.sprintf "init_policy_config failed: %s" e)

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

let require_write_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s: %s" label msg

let make_meta ?(name = "test-keeper") () : Keeper_meta_contract.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-warn")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

(* Preset-based write gate tests removed: tool_preset type deleted by #19499.
   Write-intent restrictions now handled by task contract gating, not presets. *)

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
  require_write_ok "atomic write" (Coord_utils.write_json_local path json);
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
    (Coord_utils.write_json_local path
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
      require_write_ok "concurrent write" (Coord_utils.write_json_local path json);
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
       {|"keeper:%s cascade=%s missing OAS checkpoint after run"|});
  check bool "memory write failures log at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|"keeper:%s memory_write failed: %s"|});
  check bool "memory write failures are no longer WARN" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|Log.Keeper.warn
               "keeper:%s memory_write failed: %s"|});
  check bool "episode creation failures log at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_memory_episode.ml"
       {|"keeper:%s episode_create failed: %s"|});
  check bool "episode creation failures are no longer WARN" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_memory_episode.ml"
       {|Log.Keeper.warn "keeper:%s episode_create failed: %s"|})

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

let tool_policy_unloaded_metric accessor =
  Prometheus.metric_value_or_zero Prometheus.metric_tool_policy_unloaded_query
    ~labels:[("accessor", accessor)]
    ()

let test_tool_policy_unloaded_accessors_emit_metric () =
  Keeper_tool_policy.reset_policy_config_for_test ();
  let fallback_accessors =
    [
      ( "preset_can_satisfy",
        fun () ->
          ignore
            (Keeper_tool_policy.preset_can_satisfy ~agent_preset:"delivery"
               ~required_preset:"minimal") );
      ( "configured_preset_names",
        fun () -> ignore (Keeper_tool_policy.preset_can_satisfy ~agent_preset:"delivery" ~required_preset:"minimal") );
    ]
  in
  List.iter
    (fun (accessor, call) ->
      let before = tool_policy_unloaded_metric accessor in
      call ();
      let after = tool_policy_unloaded_metric accessor in
      check bool (accessor ^ " pre-init query increments metric") true
        (after >= before +. 1.0))
    fallback_accessors;
  init_registry ()

let tool_policy_init_failed_metric base_path =
  Prometheus.metric_value_or_zero Prometheus.metric_tool_policy_init_failed
    ~labels:[("base_path", base_path)]
    ()

let test_tool_policy_init_failure_emits_metric () =
  let base_path = "/tmp/masc-test-tool-policy-init-failed" in
  let before = tool_policy_init_failed_metric base_path in
  Server_runtime_bootstrap.record_tool_policy_init_failure ~base_path
    "synthetic test failure";
  let after = tool_policy_init_failed_metric base_path in
  check bool "tool policy init failure increments metric" true
    (after >= before +. 1.0)

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  run "Warn_root_causes"
    [
      (* allowlist_preset_filter tests removed: preset system deleted by #19499 *)
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
          test_case "tool policy pre-init accessors emit metric" `Quick
            test_tool_policy_unloaded_accessors_emit_metric;
          test_case "tool policy init failure emits metric" `Quick
            test_tool_policy_init_failure_emits_metric;
        ] );
    ]
