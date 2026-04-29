(** Dashboard Execution read-model regression tests. *)

let () = Masc_mcp.Server_startup_state.mark_state_ready ~backend_mode:"test"
let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Masc_mcp.Keeper_exec_tools.init_policy_config ~base_path))

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_execution" "" in
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

let save_jsonl path entries =
  let body =
    entries
    |> List.map Yojson.Safe.to_string
    |> String.concat "\n"
  in
  Fs_compat.save_file path (if body = "" then "" else body ^ "\n")

let post_json ~id ~author ?(title = "") ?(body = "") ?hearth ?thread_id
    ?(created_at = 1000.0) () =
  let fields =
    [
      ("id", `String id);
      ("author", `String author);
      ("title", `String title);
      ("body", `String body);
      ("content", `String body);
      ("post_kind", `String "automation");
      ("visibility", `String "internal");
      ("created_at", `Float created_at);
      ("updated_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
      ("reply_count", `Int 0);
    ]
  in
  let fields =
    match hearth with
    | Some value -> ("hearth", `String value) :: fields
    | None -> fields
  in
  let fields =
    match thread_id with
    | Some value -> ("thread_id", `String value) :: fields
    | None -> fields
  in
  `Assoc fields

let comment_json ~id ~post_id ~author ~content ?(created_at = 1000.0) () =
  `Assoc
    [
      ("id", `String id);
      ("post_id", `String post_id);
      ("author", `String author);
      ("content", `String content);
      ("created_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
    ]

let warm_meta_cognition_summary (config : Lib.Coord.config) =
  let key =
    Lib.Server_dashboard_http.dashboard_cache_key config
      "meta_cognition_summary" "dashboard_shell"
  in
  ignore
    (Lib.Dashboard_cache.get_or_compute key ~ttl:120.0 (fun () ->
         Lib.Meta_cognition.summary_json config));
  Lib.Dashboard_cache.invalidate_prefix
    (Printf.sprintf "shell:coord=%s:" config.base_path)

let with_execution_cache json f =
  let surface = Lib.Server_dashboard_http._execution_cache in
  let original_json = surface.json in
  let original_last_success_at = surface.last_success_at in
  let original_last_success_unix = surface.last_success_unix in
  let original_last_attempt_at = surface.last_attempt_at in
  let original_last_attempt_unix = surface.last_attempt_unix in
  let original_last_error = surface.last_error in
  let original_last_error_at = surface.last_error_at in
  let original_last_error_unix = surface.last_error_unix in
  Fun.protect
    ~finally:(fun () ->
      surface.json <- original_json;
      surface.last_success_at <- original_last_success_at;
      surface.last_success_unix <- original_last_success_unix;
      surface.last_attempt_at <- original_last_attempt_at;
      surface.last_attempt_unix <- original_last_attempt_unix;
      surface.last_error <- original_last_error;
      surface.last_error_at <- original_last_error_at;
      surface.last_error_unix <- original_last_error_unix)
    (fun () ->
      Lib.Server_dashboard_http_cache.mark_cached_surface_success surface json;
      f ())

let test_dashboard_execution_fixture () =
  let dir = test_dir () in
  (* Force filesystem backend to prevent PG auto-detection in hermetic tests *)
  let saved_storage = Sys.getenv_opt "MASC_STORAGE_TYPE" in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir dir;
      (match saved_storage with
       | Some v -> Unix.putenv "MASC_STORAGE_TYPE" v
       | None -> Unix.putenv "MASC_STORAGE_TYPE" ""))
    (fun () ->
      let config = Coord_utils.default_config dir in
      Unix.putenv "MASC_DASHBOARD_FIXTURES_ENABLED" "true";
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~fixture:"execution_smoke"
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let execution_queue = json |> member "execution_queue" |> to_list in
        let operation_briefs = json |> member "operation_briefs" |> to_list in
        let worker_briefs = json |> member "worker_support_briefs" |> to_list in
        let continuity_briefs = json |> member "continuity_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        check bool "summary removed from execution payload" true
          (json |> member "summary" = `Null);
        check string "top queue kind" "operation"
          (execution_queue |> List.hd |> member "kind" |> to_string);
        check string "top queue target" "op-runtime-002"
          (execution_queue |> List.hd |> member "target_id" |> to_string);
        check string "top queue handoff surface" "command"
          (execution_queue |> List.hd |> member "top_handoff" |> member "surface" |> to_string);
        check int "operation briefs" 2 (List.length operation_briefs);
        check int "worker briefs" 3 (List.length worker_briefs);
        check string "worker signal truth" "live"
          (worker_briefs |> List.hd |> member "signal_truth" |> to_string);
        check string "worker evidence source" "message"
          (worker_briefs |> List.hd |> member "evidence_source" |> to_string);
        check int "continuity briefs" 1 (List.length continuity_briefs);
        check int "offline worker briefs" 1 (List.length offline_worker_briefs);
        check string "continuity skill route summary" "scene-director · +1 · judgment"
          (continuity_briefs |> List.hd |> member "skill_route_summary" |> to_string);
        check (list string) "continuity recent tools keep window semantics"
          [ "masc_keeper_status"; "masc_board_post" ]
          (continuity_briefs |> List.hd |> member "recent_tool_names"
         |> to_list |> List.map to_string);
        check (list string) "continuity latest tools stay latest-only"
          [ "masc_board_post" ]
          (continuity_briefs |> List.hd |> member "latest_tool_names"
         |> to_list |> List.map to_string);
        check string "continuity recent output stays concrete"
          "Prepared the next scene transition and handoff summary"
          (continuity_briefs |> List.hd |> member "recent_output_preview" |> to_string);
        check string "continuity summary remains separate"
          "Continuity pressure is high; handoff prep is underway"
          (continuity_briefs |> List.hd |> member "continuity_summary" |> to_string);
        check int "continuity allowed tool count" 3
          (continuity_briefs |> List.hd |> member "allowed_tool_count" |> to_int);
        check (list string) "continuity allowed tool preview"
          [ "masc_board_get"; "masc_board_post"; "masc_keeper_status" ]
          (continuity_briefs |> List.hd |> member "allowed_tool_preview"
         |> to_list |> List.map to_string);
        check bool "worker focus carries operation without session" true
          (worker_briefs
           |> List.exists (fun row ->
                  row |> member "name" |> to_string = "local-alpha"
                  && row |> member "related_session_id" = `Null
                  && row |> member "related_operation_id" |> to_string = "op-runtime-001"));
      ))

let test_dashboard_execution_live_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord_utils.default_config dir in
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let status = json |> member "status" in
        let key_absent key j =
          List.assoc_opt key (to_assoc j) = None
        in
        check bool "namespace_id carrier removed" true (key_absent "namespace_id" status);
        check bool "namespace carrier removed" true (key_absent "namespace" status);
        check bool "namespace_mode carrier removed" true (key_absent "namespace_mode" status);
        check int "execution queue empty" 0
          (json |> member "execution_queue" |> to_list |> List.length);
        check int "operation briefs empty" 0
          (json |> member "operation_briefs" |> to_list |> List.length);
        check int "worker briefs empty" 0
          (json |> member "worker_support_briefs" |> to_list |> List.length);
        check int "continuity briefs empty" 0
          (json |> member "continuity_briefs" |> to_list |> List.length);
      ))

let test_dashboard_execution_namespace_status () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord_utils.default_config dir in
      Eio_main.run @@ fun env ->
      ignore (Lib.Coord.init config ~agent_name:None);
      Lib.Coord.ensure_room_bootstrap config;
      check (option string) "room state current_room flattened" (Some "default")
        (Lib.Coord.read_current_room config);
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let key_absent key json =
          List.assoc_opt key (to_assoc json) = None
        in
        let status = json |> member "status" in
        check bool "status namespace_id removed" true
          (key_absent "namespace_id" status);
        check bool "status namespace removed" true
          (key_absent "namespace" status);
        check bool "status current_namespace removed" true
          (key_absent "current_namespace" status);
        check bool "status namespace_mode removed" true
          (key_absent "namespace_mode" status);
        check bool "legacy room removed" true
          (key_absent "room" status);
        check bool "legacy room base path removed" true
          (key_absent "room_base_path" status);
        let batch = Lib.Server_dashboard_http_core.dashboard_batch_json config in
        let batch_status = batch |> member "status" in
        check string "batch cluster exposed" ("default")
          (batch_status |> member "cluster" |> to_string);
        check bool "batch current_namespace removed" true
          (key_absent "current_namespace" batch_status);
        check bool "batch current_room removed" true
          (key_absent "current_room" batch_status);
      ))

let test_dashboard_shell_namespace_status () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      Lib.Coord.ensure_room_bootstrap config;
      let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let key_absent key json =
        List.assoc_opt key (to_assoc json) = None
      in
      let status = json |> member "status" in
      check string "shell cluster exposed" ("default")
        (status |> member "cluster" |> to_string);
      check bool "shell namespace_id removed" true
        (key_absent "namespace_id" status);
      check bool "shell namespace removed" true
        (key_absent "namespace" status);
      check bool "shell current_namespace removed" true
        (key_absent "current_namespace" status);
      check bool "shell current_room removed" true
        (key_absent "current_room" status);
      check bool "shell namespace_mode removed" true
        (key_absent "namespace_mode" status);
      check string "shell coordination root surfaced" dir
        (status |> member "coordination_root" |> to_string);
      check string "shell workspace path surfaced" dir
        (status |> member "workspace_path" |> to_string);
      check bool "shell workspace differs false when same root" false
        (status |> member "workspace_differs" |> to_bool);
      check string "shell diagnostics surface" "shell"
        (json |> member "projection_diagnostics" |> member "surface" |> to_string))

let test_dashboard_shell_surfaces_workspace_when_different () =
  let dir = test_dir () in
  let worktrees_dir = Filename.concat dir ".worktrees" in
  let workspace = Filename.concat worktrees_dir "demo" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Unix.mkdir worktrees_dir 0o755;
      Unix.mkdir workspace 0o755;
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config =
        { (Coord_utils.default_config dir) with workspace_path = workspace }
      in
      ignore (Lib.Coord.init config ~agent_name:None);
      let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let status = json |> member "status" in
      check string "shell coordination root remains base path" dir
        (status |> member "coordination_root" |> to_string);
      check string "shell workspace path uses input path" workspace
        (status |> member "workspace_path" |> to_string);
      check bool "shell workspace differs true when worktree input" true
        (status |> member "workspace_differs" |> to_bool);
      check string "diagnostics coordination root surfaced" dir
        (json |> member "projection_diagnostics" |> member "coordination_root"
         |> to_string);
      check string "diagnostics workspace path surfaced" workspace
        (json |> member "projection_diagnostics" |> member "workspace_path"
         |> to_string))

let test_dashboard_shell_includes_meta_cognition_summary () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      let masc_dir = Lib.Coord.masc_dir config in
      save_jsonl
        (Filename.concat masc_dir "board_posts.jsonl")
        [
          post_json ~id:"p-root" ~author:"admin-keeper"
            ~title:"RBAC blockage"
            ~body:
              "All masc_* tools tested return unregistered_masc_tool. \
               Operator intervention needed. keeper_* tools function normally."
            ~hearth:"ops" ~created_at:1000.0 ();
        ];
      save_jsonl
        (Filename.concat masc_dir "board_comments.jsonl")
        [
          comment_json ~id:"c-1" ~post_id:"p-root" ~author:"keeper-a"
            ~content:
              "This contradicts the uniform block hypothesis. Access may be per-agent."
            ~created_at:1010.0 ();
        ];
      Lib.Dashboard_cache.invalidate_all ();
      Atomic.set Lib.Server_dashboard_http._shell_warmed false;
      Atomic.set Lib.Server_dashboard_http._last_good_shell (`Assoc []);
      let cold_json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      check bool "cold shell defers meta cognition while warming" true
        (cold_json |> member "meta_cognition" = `Null);
      warm_meta_cognition_summary config;
      let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let meta = json |> member "meta_cognition" in
      check int "meta belief count" 2
        (meta |> member "belief_count" |> to_int);
      check int "meta contested belief count" 1
        (meta |> member "contested_belief_count" |> to_int);
      check string "dominant belief surfaced" "belief:masc_tools_blocked"
        (meta |> member "dominant_belief" |> member "id" |> to_string);
      check string "dominant belief shows contested status" "contested"
        (meta |> member "dominant_belief" |> member "status" |> to_string);
      check string "top tension surfaced" "tension:masc_tool_blockage"
        (meta |> member "top_tension" |> member "id" |> to_string);
      check bool "top tension retains operator flag" true
        (meta |> member "top_tension" |> member "needs_operator" |> to_bool);
      check string "top desire surfaced" "desire:operator_guidance"
        (meta |> member "top_desire" |> member "id" |> to_string))

let create_keeper env sw config name =
  let ctx : _ Lib.Tool_keeper.context =
    {
      config;
      agent_name = "tester";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env); net = None;
    }
  in
  match
    Lib.Tool_keeper.dispatch ctx ~name:"masc_keeper_up"
      ~args:
        (`Assoc
          [
            ("name", `String name);
            ("goal", `String "Dashboard keeper fixture");
            ("sandbox_profile", `String "local");
            ("network_mode", `String "inherit");
            ("proactive_enabled", `Bool false);
            ("autoboot_enabled", `Bool false);
          ])
  with
  | Some (true, _) -> ()
  | Some (false, err) -> fail err
  | None -> fail "missing masc_keeper_up dispatch"

let append_execution_receipt config ~keeper_name =
  let meta =
    match Lib.Keeper_types.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> fail ("keeper meta missing for receipt: " ^ keeper_name)
    | Error err -> fail ("read_meta failed for receipt: " ^ err)
  in
  let started_at = Types.now_iso () in
  let ended_at = Types.now_iso () in
  let receipt : Lib.Keeper_execution_receipt.t =
    {
      keeper_name;
      agent_name = meta.agent_name;
      trace_id = Lib.Keeper_id.Trace_id.to_string meta.runtime.trace_id;
      generation = meta.runtime.generation;
      turn_count = Some 3;
      current_task_id = None;
      goal_ids = meta.active_goal_ids;
      outcome = "ok";
      terminal_reason_code = "completed";
      response_text_present = true;
      model_used = Some "custom:mock";
      requested_tools = [ "keeper_task_claim"; "keeper_fs_read" ];
      reported_tools = [ "Read" ];
      observed_tools = [ "keeper_fs_read" ];
      canonical_tools = [ "keeper_fs_read" ];
      unexpected_tools = [ "WebSearch" ];
      tools_used = [ "keeper_fs_read" ];
      tool_contract_result = "satisfied";
      tool_surface =
        {
          turn_lane = "tool";
          tool_surface_class = "mixed";
          tool_requirement = "required";
          visible_tool_count = 2;
          tool_gate_enabled = true;
          tool_surface_fallback_used = false;
          required_tools = [];
          missing_required_tools = [];
        };
      sandbox_kind =
        Lib.Keeper_execution_receipt.sandbox_kind_of_meta meta;
      sandbox_root = Some config.base_path;
      network_mode = Lib.Keeper_types.network_mode_to_string meta.network_mode;
      approval_profile = Some "trusted_local";
      approval_profile_derived = false;
      cascade_name = meta.cascade_name;
      cascade_selected_model = Some "custom:mock";
      cascade_attempt_count = 2;
      cascade_fallback_applied = true;
      cascade_outcome = "passed_to_next_model";
      degraded_retry_applied = true;
      degraded_retry_cascade = Some Lib.Keeper_config.local_recovery_cascade_name;
      fallback_reason = Some "turn_timeout";
      cascade_rotation_attempts =
        [
          {
            from_cascade = Lib.Keeper_config.default_cascade_name;
            to_cascade = Lib.Keeper_config.local_recovery_cascade_name;
            reason = "turn_timeout";
            outcome = "retry_scheduled";
            error_kind = Some "internal";
            error_message = Some "turn timeout";
            recorded_at = ended_at;
          };
        ];
      stop_reason = Some "completed";
      error_kind = None;
      error_message = None;
      started_at;
      ended_at;
    }
  in
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let base_dir =
    Filename.concat
      (Lib.Keeper_types.keeper_dir config)
      (keeper_name ^ "/execution-receipts")
  in
  let month_dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_jsonl
    (Filename.concat month_dir day)
    (Lib.Keeper_execution_receipt.to_json receipt)

let test_dashboard_shell_splits_active_and_configured_keepers () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-alpha";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-beta")
          (fun () ->
            create_keeper env sw config "keeper-alpha";
            create_keeper env sw config "keeper-beta";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-alpha";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-beta";
            let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
            let open Yojson.Safe.Util in
            let counts = json |> member "counts" in
            check int "shell active keeper count uses runtime" 0
              (counts |> member "keepers" |> to_int);
            check bool "shell configured keeper inventory stays visible" true
              (json |> member "configured_keepers" |> to_int >= 2))))

let test_dashboard_shell_excludes_keeper_agents_from_general_count () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      ignore
        (Lib.Coord.join config
           ~agent_name:"keeper-sangsu-agent"
           ~agent_type_override:(Some "keeper")
           ~capabilities:["keeper"]
           ());
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
            let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
            let open Yojson.Safe.Util in
            let counts = json |> member "counts" in
            check int "keeper-backed room has no general agents" 0
              (counts |> member "agents" |> to_int);
            check int "stopped keeper is not counted as active" 0
              (counts |> member "keepers" |> to_int);
            check bool "configured keeper inventory remains visible" true
              (json |> member "configured_keepers" |> to_int >= 1))))

let test_dashboard_execution_fresh_join_not_marked_stale () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord_utils.default_config dir in
      Eio_main.run @@ fun env ->
      ignore (Lib.Coord.init config ~agent_name:None);
      ignore (Lib.Coord.join config ~agent_name:"test-agent-fox" ~capabilities:["housekeeping"] ());
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let worker_briefs = json |> member "worker_support_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        let has_test_agent =
          List.exists
            (fun row ->
              row |> member "name" |> to_string = "test-agent-fox")
            (worker_briefs @ offline_worker_briefs)
        in
        check bool "freshly joined agent should not appear stale in execution worker briefs"
          false has_test_agent
      ))

let test_dashboard_execution_surfaces_keeper_diagnostic () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            let json =
              Lib.Dashboard_execution.json
                ~config
                ~sw
                ~clock:(Eio.Stdenv.clock env)
                ~proc_mgr:None
                ()
            in
            let open Yojson.Safe.Util in
            let row =
              json |> member "keepers" |> to_list
              |> List.find (fun keeper -> keeper |> member "name" |> to_string = "sangsu")
            in
            check bool "diagnostic surfaced on execution keeper row" true
              (row |> member "diagnostic" <> `Null);
            check bool "diagnostic health state surfaced" true
              (row |> member "diagnostic" |> member "health_state" <> `Null);
            check bool "diagnostic next action surfaced" true
              (row |> member "diagnostic" |> member "next_action_path" <> `Null);
            check string "raw cascade surfaced on execution keeper row"
              Lib.Keeper_config.default_cascade_name
              (row |> member "cascade_name" |> to_string);
            check string "canonical cascade surfaced on execution keeper row"
              Lib.Keeper_config.default_cascade_name
              (row |> member "cascade_canonical" |> to_string);
            check bool "primary model surfaced on execution keeper row" true
              (row |> member "primary_model" <> `Null);
            check bool "active model label surfaced on execution keeper row" true
              (row |> member "active_model_label" <> `Null))))

let test_execution_trust_surfaces_latest_receipt () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            append_execution_receipt config ~keeper_name:"sangsu";
            let compact_json =
              Lib.Dashboard_http_keeper.keepers_dashboard_json
                ~compact:true config
            in
            let trust_json =
              Lib.Dashboard_http_keeper.execution_trust_dashboard_json config
            in
            let open Yojson.Safe.Util in
            check string "execution trust source" "execution_receipt"
              (trust_json |> member "source" |> to_string);
            check string "execution trust producer"
              "keeper_agent_run.execution_receipt"
              (trust_json |> member "producer" |> to_string);
            check string "execution trust dashboard surface"
              "/api/v1/dashboard/execution-trust"
              (trust_json |> member "dashboard_surface" |> to_string);
            check int "execution trust entry count" 1
              (trust_json |> member "entry_count" |> to_int);
            check string "execution trust health" "ok"
              (trust_json |> member "health" |> to_string);
            check bool "execution trust latest age present" true
              (trust_json |> member "latest_age_s" <> `Null);
            let compact_row =
              compact_json |> member "keepers" |> to_list
              |> List.find (fun keeper ->
                     keeper |> member "name" |> to_string = "sangsu")
            in
            let trust_row =
              trust_json |> member "keepers" |> to_list
              |> List.find (fun keeper ->
                     keeper |> member "name" |> to_string = "sangsu")
            in
            check string "compact keeper row exposes trust outcome" "ok"
              (compact_row |> member "trust" |> member "last_outcome"
             |> to_string);
            check string "compact keeper row exposes trust contract result"
              "satisfied"
              (compact_row |> member "trust" |> member "tool_contract_result"
             |> to_string);
            check string "execution trust row preserves sandbox kind"
              "local"
              (trust_row |> member "trust" |> member "sandbox"
             |> member "kind" |> to_string);
            check string "execution trust row preserves cascade outcome"
              "passed_to_next_model"
              (trust_row |> member "trust" |> member "cascade"
             |> member "outcome" |> to_string);
            check string "execution trust row exposes operator disposition"
              "fail_open_next_cascade"
              (trust_row |> member "trust" |> member "operator_disposition"
             |> to_string);
            check string "execution trust row exposes operator disposition reason"
              "degraded_retry"
              (trust_row |> member "trust" |> member "operator_disposition_reason"
             |> to_string);
            check bool "execution trust row preserves degraded retry flag" true
              (trust_row |> member "trust" |> member "cascade"
             |> member "degraded_retry_applied" |> to_bool);
            check (option string) "execution trust row preserves degraded retry lane"
              (Some Lib.Keeper_config.local_recovery_cascade_name)
              (trust_row |> member "trust" |> member "cascade"
             |> member "degraded_retry_cascade" |> to_string_option);
            check (option string) "execution trust row preserves fallback reason"
              (Some "turn_timeout")
              (trust_row |> member "trust" |> member "cascade"
             |> member "fallback_reason" |> to_string_option);
            check string "execution trust row preserves rotation target"
              Lib.Keeper_config.local_recovery_cascade_name
              (trust_row |> member "trust" |> member "cascade"
             |> member "rotation_attempts" |> to_list |> List.hd
             |> member "to_cascade" |> to_string);
            check (list string) "execution trust row preserves unexpected tools"
              [ "WebSearch" ]
              (trust_row |> member "trust" |> member "unexpected_tools"
             |> to_list |> List.map to_string);
            let execution_json =
              Lib.Dashboard_execution.json
                ~config
                ~sw
                ~clock:(Eio.Stdenv.clock env)
                ~proc_mgr:None
                ()
            in
            let execution_row =
              execution_json |> member "keepers" |> to_list
              |> List.find (fun keeper ->
                     keeper |> member "name" |> to_string = "sangsu")
            in
            check int "execution row exposes provider attempt count" 2
              (execution_row |> member "trust" |> member "execution_summary"
             |> member "provider_attempt_count" |> to_int);
            check string "execution row exposes provider selected model"
              "custom:mock"
              (execution_row |> member "trust" |> member "execution_summary"
             |> member "provider_selected_model" |> to_string);
            check bool "execution row exposes provider fallback" true
              (execution_row |> member "trust" |> member "execution_summary"
             |> member "provider_fallback_applied" |> to_bool);
            check string "execution row exposes cascade outcome"
              "passed_to_next_model"
              (execution_row |> member "trust" |> member "execution_summary"
             |> member "cascade_outcome" |> to_string))))

let test_execution_trust_surfaces_coverage_gap_health () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      let masc_root = Lib.Coord.masc_root_dir config in
      Lib.Telemetry_coverage_gap.record
        ~masc_root
        ~source:"execution_receipt"
        ~producer:"keeper_agent_run.execution_receipt"
        ~durable_store:(Filename.concat masc_root "keepers/*/execution-receipts")
        ~dashboard_surface:"/api/v1/dashboard/execution-trust"
        ~stale_reason:"execution_receipt_append_failed"
        ~keeper_name:"sangsu"
        ~trace_id:"trace-exec-gap"
        ();
      let trust_json =
        Lib.Dashboard_http_keeper.execution_trust_dashboard_json config
      in
      let open Yojson.Safe.Util in
      check string "execution trust coverage gap health"
        "coverage_gap"
        (trust_json |> member "health" |> to_string);
      check string "execution trust coverage gap stale reason"
        "execution_receipt_append_failed"
        (trust_json |> member "stale_reason" |> to_string);
      check int "execution trust coverage gap count" 1
        (trust_json |> member "coverage_gap_count" |> to_int))

let test_patch_keeper_dependent_caches_tolerates_null_agent () =
  let execution_json =
    `Assoc
      [
        ("status", `Assoc [("namespace", `String "default")]);
        ( "keepers",
          `List
            [
              `Assoc
                [
                  ("name", `String "sangsu");
                  ("status", `String "running");
                  ("agent", `Null);
                ];
            ] );
      ]
  in
  with_execution_cache execution_json (fun () ->
    Lib.Server_dashboard_http.patch_keeper_dependent_caches
      ~keeper_name:"sangsu" ~event:"started";
    let open Yojson.Safe.Util in
    let keepers =
      Lib.Server_dashboard_http._execution_cache.json
      |> member "keepers" |> to_list
    in
    let row = List.hd keepers in
    check string "patched status falls back to idle"
      "idle"
      (row |> member "status" |> to_string);
    check bool "keepalive running patched"
      true
      (row |> member "keepalive_running" |> to_bool))

let test_patch_surface_json_for_running_keepers_tolerates_null_agent () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:None);
      ignore
        (Lib.Coord.join config
           ~agent_name:"keeper-sangsu-agent"
           ~agent_type_override:(Some "keeper")
           ~capabilities:["keeper"]
           ());
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            let json =
              `Assoc
                [
                  ( "keepers",
                    `List
                      [
                        `Assoc
                          [
                            ("name", `String "sangsu");
                            ("status", `String "running");
                            ("agent", `Null);
                          ];
                      ] );
                ]
            in
            let patched =
              Lib.Server_dashboard_http.patch_surface_json_for_running_keepers
                config json
            in
            let open Yojson.Safe.Util in
            let row = patched |> member "keepers" |> to_list |> List.hd in
            check string "running keepers patch remains stable"
              "idle"
              (row |> member "status" |> to_string))))

let test_patch_keeper_row_tolerates_null_agent_shape () =
  let row =
    `Assoc
      [
        ("name", `String "keeper-alpha");
        ("agent", `Null);
        ("status", `String "unknown");
      ]
  in
  let patched =
    Lib.Server_dashboard_http.patch_keeper_row
      ~keeper_name:"keeper-alpha"
      ~event:"reconciled"
      ~keepalive_running:true row
  in
  let open Yojson.Safe.Util in
  check string "null agent falls back to idle"
    "idle"
    (patched |> member "status" |> to_string);
  check string "phase still patched"
    "running"
    (patched |> member "phase" |> to_string)

let () =
  Alcotest.run "Dashboard Execution"
    [
      ( "read_model",
        [
          Alcotest.test_case "fixture response" `Quick test_dashboard_execution_fixture;
          Alcotest.test_case "live empty room is safe" `Quick test_dashboard_execution_live_empty_room;
          Alcotest.test_case "current room drives status" `Quick
            test_dashboard_execution_namespace_status;
          Alcotest.test_case "shell follows current room" `Quick
            test_dashboard_shell_namespace_status;
          Alcotest.test_case "shell surfaces workspace separately" `Quick
            test_dashboard_shell_surfaces_workspace_when_different;
          Alcotest.test_case "shell includes meta cognition summary" `Quick
            test_dashboard_shell_includes_meta_cognition_summary;
          Alcotest.test_case "shell splits active and configured keepers" `Quick
            test_dashboard_shell_splits_active_and_configured_keepers;
          Alcotest.test_case "shell excludes keeper agents from general count" `Quick
            test_dashboard_shell_excludes_keeper_agents_from_general_count;
          Alcotest.test_case "fresh join is not stale" `Quick
            test_dashboard_execution_fresh_join_not_marked_stale;
          Alcotest.test_case "execution surfaces keeper diagnostic" `Quick
            test_dashboard_execution_surfaces_keeper_diagnostic;
          Alcotest.test_case "execution trust surfaces latest receipt" `Quick
            test_execution_trust_surfaces_latest_receipt;
          Alcotest.test_case "execution trust surfaces coverage gap health" `Quick
            test_execution_trust_surfaces_coverage_gap_health;
          Alcotest.test_case "lifecycle patch tolerates null agent" `Quick
            test_patch_keeper_dependent_caches_tolerates_null_agent;
          Alcotest.test_case "running keeper patch tolerates null agent" `Quick
            test_patch_surface_json_for_running_keepers_tolerates_null_agent;
          Alcotest.test_case "patch keeper row tolerates null agent shape" `Quick
            test_patch_keeper_row_tolerates_null_agent_shape;
        ] );
    ]
