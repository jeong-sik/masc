open Masc_tui_core
open Masc_tui_net
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_term

type bus_key =
  | Key_get of string
  | Key_read of string * Clock.Mono.t
  | Key_freshness of Subscriptions.stream_id

let equal_bus_key a b =
  match a, b with
  | Key_get x, Key_get y -> String.equal x y
  | Key_freshness x, Key_freshness y -> Subscriptions.equal_stream_kind x y
  | Key_read (x, tx), Key_read (y, ty) ->
      String.equal x y && Clock.Mono.equal tx ty
  | Key_get _, (Key_freshness _ | Key_read _)
  | Key_freshness _, (Key_get _ | Key_read _)
  | Key_read _, (Key_get _ | Key_freshness _) -> false

let stream_kind_tag = function
  | Subscriptions.Stream_observer -> 0
  | Subscriptions.Stream_fleet -> 1
  | Subscriptions.Stream_model_metrics -> 2
  | Subscriptions.Stream_tool_metrics_series -> 3
  | Subscriptions.Stream_logs _ -> 4

let hash_bus_key = function
  | Key_get path -> Hashtbl.hash (0, path)
  | Key_read (path, stamp) -> Hashtbl.hash (2, path, Clock.Mono.to_ns stamp)
  | Key_freshness stream -> Hashtbl.hash (1, stream_kind_tag stream)

type bus = (bus_key, Msg.t, Msg.t) Ui_bus.t

let create_bus ?stream_capacity ?on_wake () =
  Ui_bus.create ?stream_capacity ~key_equal:equal_bus_key
    ~key_hash:hash_bus_key ?on_wake ()

let admin_token_path ~base_path =
  Filename.concat (Common.auth_dir_from_base_path ~base_path) "admin.token"

let nonblank_trimmed s =
  let t = String.trim s in
  if String.equal t "" then None else Some t

let read_first_nonblank_line path =
  match In_channel.open_text path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () ->
          let rec scan () =
            match In_channel.input_line ic with
            | None -> None
            | Some line -> (
                match nonblank_trimmed line with
                | Some tok -> Some tok
                | None -> scan ())
          in
          scan ())
  | exception (Sys_error _ | Unix.Unix_error _) -> None

let load_bearer_token ?(getenv = Sys.getenv_opt) ~base_path () =
  match Option.bind (getenv "MASC_TOKEN") nonblank_trimmed with
  | Some _ as env_tok -> env_tok
  | None -> read_first_nonblank_line (admin_token_path ~base_path)

let endpoint_of_cli ?bearer_token (cli : Cli_args.config) =
  let token =
    match bearer_token with
    | Some tok_opt -> tok_opt
    | None -> load_bearer_token ~base_path:cli.base_path ()
  in
  Http_client.make_endpoint ~scheme:cli.scheme ~host:cli.host ~port:cli.port
    ?bearer_token:token ()

let msg_error_of_http = function
  | Http_client.Transport err -> Msg.Transport err
  | Http_client.Workspace_mismatch
      {
        expected_instance;
        observed_instance;
        observed_workspace_sha256;
        message;
      } ->
      Msg.Workspace_mismatch
        {
          expected_instance;
          observed_instance;
          observed_workspace_sha256;
          message;
        }
  | Http_client.Http_error { status; body; api_error } ->
      Msg.Http_error { status; body; api_error }
  | Http_client.Decode_error msg -> Msg.Decode_error msg

let standard_timeout_sec = 12.0
let heavy_timeout_sec = 30.0
let chat_stream_header_timeout_sec = 45.0

let timeout_sec_for_get : Cmd.get_request -> float = function
  (* Standard tier: lightweight state reads and single-entity lookups *)
  | Cmd.Get_health
  | Cmd.Get_keeper_turns
  | Cmd.Get_chat_queue _
  | Cmd.Get_chat_status _
  | Cmd.Get_chat_operation_events _
  | Cmd.Get_schedules _
  | Cmd.Get_asks _
  | Cmd.Get_tool_approvals
  | Cmd.Get_gate_pending
  | Cmd.Get_board_hearths
  | Cmd.Get_wiki_page _
  | Cmd.Get_artifact_checks
  | Cmd.Get_setup_login_status _
  | Cmd.Get_connectors
  | Cmd.Get_mcp_clients
  | Cmd.Get_tui_preferences
  | Cmd.Get_workspace_children _
  | Cmd.Get_oauth_providers
  | Cmd.Get_oauth_attached_tools _
  | Cmd.Get_oauth_attempt_status _
  | Cmd.Get_board_quarantines _
  | Cmd.Get_keeper_operator_note _
  | Cmd.Get_tool_approval_modes
  | Cmd.Get_late_approval_attempts
  | Cmd.Get_keeper_waiting_inventory _
  | Cmd.Get_skill_editor_sources
  | Cmd.Get_skill_editor_tools
  | Cmd.Get_async_requests
  | Cmd.Get_prompts
  | Cmd.Get_presets
  | Cmd.Get_preset_show _
  | Cmd.Get_runtime_params
  | Cmd.Get_lanes_inventory
  | Cmd.Get_standalone_lanes
  | Cmd.Get_exact_lane_run_detail _
  | Cmd.Get_verification_runs
  | Cmd.Get_goal_verification_runs
  | Cmd.Get_goal_confirmation _
  | Cmd.Get_keeper_board_attention_quarantines _
  | Cmd.Get_lane_addon_declaration _
  | Cmd.Get_lane_addon_action_status _
  | Cmd.Get_lane_addon_slice _
  | Cmd.Get_lane_addon_asks _ ->
      standard_timeout_sec
  (* Heavy tier: dashboard/analytics aggregates, disk/git/ripgrep scans,
     memory/keeper context & history reads, probes, and published artifacts *)
  | Cmd.Get_dashboard_shell
  | Cmd.Get_keepers_roster
  | Cmd.Get_keeper_turn_records _
  | Cmd.Get_chat_history _
  | Cmd.Get_planning
  | Cmd.Get_verifications _
  | Cmd.Get_candle_ledger _
  | Cmd.Get_board_feed _
  | Cmd.Get_board_thread _
  | Cmd.Get_wiki_index _
  | Cmd.Get_wiki_log _
  | Cmd.Get_wiki_search _
  | Cmd.Get_wiki_lint
  | Cmd.Get_artifacts
  | Cmd.Get_artifact_detail _
  | Cmd.Get_world_memory
  | Cmd.Get_memory_diff _
  | Cmd.Get_keeper_memory_os_internals _
  | Cmd.Get_keeper_memory_facts _
  | Cmd.Get_keeper_memory_activity _
  | Cmd.Get_keeper_memory_health _
  | Cmd.Get_keeper_context_turn_records _
  | Cmd.Get_keeper_provider_input _
  | Cmd.Get_keeper_provider_input_part _
  | Cmd.Get_keeper_cache_outcome _
  | Cmd.Get_keeper_next_request _
  | Cmd.Get_keeper_turn_transcript _
  | Cmd.Get_keeper_tool_stats _
  | Cmd.Get_keeper_tool_calls _
  | Cmd.Get_keeper_tool_result _
  | Cmd.Get_provider_usage _
  | Cmd.Get_keeper_costs _
  | Cmd.Get_efficiency _
  | Cmd.Get_models_metrics _
  | Cmd.Get_runtime_metrics
  | Cmd.Get_runtime_resolved
  | Cmd.Get_runtime_config_raw
  | Cmd.Get_setup_inventory
  | Cmd.Get_runtime_probe _
  | Cmd.Get_exact_lane_runs _
  | Cmd.Get_fusion_runs
  | Cmd.Get_tool_series _
  | Cmd.Get_tool_series_filtered _
  | Cmd.Get_tools_catalog _
  | Cmd.Get_skills
  | Cmd.Get_browser_lane
  | Cmd.Get_lane_addons
  | Cmd.Get_sandboxes
  | Cmd.Get_keeper_sandbox _
  | Cmd.Get_repositories
  | Cmd.Get_repository_pulls
  | Cmd.Get_repository_detail _
  | Cmd.Get_repository_activity _
  | Cmd.Get_system_logs _
  | Cmd.Get_config_schema _
  | Cmd.Get_fusion_run_detail _
  | Cmd.Get_fusion_config
  | Cmd.Get_fusion_board_evidence _
  | Cmd.Get_harness_health
  | Cmd.Get_verification_evidence _
  | Cmd.Get_verification_summary
  | Cmd.Get_verification_specs
  | Cmd.Get_verification_tlc_results
  | Cmd.Get_activity_events _
  | Cmd.Get_keeper_runtime_trace _
  | Cmd.Get_keeper_metrics _
  | Cmd.Get_keeper_sandbox_logs _
  | Cmd.Get_workspace_files _
  | Cmd.Get_workspace_search _
  | Cmd.Get_workspace_file _
  | Cmd.Get_git_branches _
  | Cmd.Get_git_worktrees _
  | Cmd.Get_git_status _
  | Cmd.Get_git_blame _
  | Cmd.Get_git_log _
  | Cmd.Get_git_diff _
  | Cmd.Get_workspace_memory_ledger
  | Cmd.Get_workspace_memory_context
  | Cmd.Get_keeper_memory_journal _
  | Cmd.Get_github_identity _
  | Cmd.Get_addon_package_catalog _
  | Cmd.Get_addon_package_preview _
  | Cmd.Get_connector_names _
  | Cmd.Get_keeper_turn_flow _
  | Cmd.Get_keeper_checkpoints _
  | Cmd.Get_tool_quality _
  | Cmd.Get_gate_tool_events _ ->
      heavy_timeout_sec

let timeout_sec_for_post : Cmd.post_request -> float = function
  (* Standard tier: quick mutations *)
  | Cmd.Post_ask_answer _
  | Cmd.Post_tool_approval _
  | Cmd.Post_gate_resolution _
  | Cmd.Post_goal_transition _
  | Cmd.Post_goal_confirmation _
  | Cmd.Post_task_create _
  | Cmd.Post_task_transition _
  | Cmd.Post_task_link_goal _
  | Cmd.Post_goal_upsert _
  | Cmd.Post_board_pin _
  | Cmd.Post_board_delete _
  | Cmd.Post_verification_verdict _
  | Cmd.Post_runtime_assignment _
  | Cmd.Post_runtime_default_route _
  | Cmd.Post_runtime_lane_create _
  | Cmd.Post_runtime_lane_update _
  | Cmd.Post_runtime_lane_delete _
  | Cmd.Post_setup_account_key _
  | Cmd.Post_setup_login_input _
  | Cmd.Post_tui_preference _
  | Cmd.Post_keeper_turn_interrupt _
  | Cmd.Post_keeper_lifecycle
      { op = Wire_fleet.(Keeper_wakeup | Keeper_pause); _ }
  | Cmd.Post_keeper_purge _
  | Cmd.Post_lane_addon_attach _
  | Cmd.Post_lane_addon_detach _
  | Cmd.Post_lane_addon_action _
  | Cmd.Post_lane_addon_ask_answer _
  | Cmd.Post_board_create _
  | Cmd.Post_board_comment _
  | Cmd.Post_board_vote _
  | Cmd.Post_board_comment_vote _
  | Cmd.Post_artifact_check _
  | Cmd.Post_artifact_share _
  | Cmd.Post_schedule_create _
  | Cmd.Post_connector_bind _
  | Cmd.Post_connector_unbind _
  | Cmd.Post_task_cancel _
  | Cmd.Post_harness_overrule _
  | Cmd.Post_oauth_identity_switch _
  | Cmd.Post_oauth_disconnect _
  | Cmd.Post_board_recovery _
  | Cmd.Post_keeper_directive _
  | Cmd.Post_discord_reply _
  | Cmd.Post_keeper_operator_note _
  | Cmd.Post_keeper_run_next _
  | Cmd.Post_gate_resolution_policy _
  | Cmd.Post_gate_mode _
  | Cmd.Post_gate_rule_delete _
  | Cmd.Post_gate_retry _
  | Cmd.Post_keeper_tool_approval_mode _
  | Cmd.Post_hitl_ack_uncertain _
  | Cmd.Post_hitl_late_approval_restore
  | Cmd.Post_skill_editor_read _
  | Cmd.Post_skill_editor_preview_new _
  | Cmd.Post_skill_editor_create _
  | Cmd.Post_skill_editor_preview _
  | Cmd.Post_skill_editor_save _
  | Cmd.Post_skills_refresh
  | Cmd.Post_prompt_override _
  | Cmd.Post_preset_save _
  | Cmd.Post_preset_create _
  | Cmd.Post_preset_restore _
  | Cmd.Post_preset_delete _
  | Cmd.Post_runtime_param_set _
  | Cmd.Post_runtime_param_clear _
  | Cmd.Post_runtime_routing_action _
  | Cmd.Post_runtime_config_raw_preview _
  | Cmd.Post_board_attention_quarantine_recovery _
  | Cmd.Post_lane_addon_declaration_save _
  | Cmd.Post_lane_addon_observe _
  | Cmd.Post_lane_addon_retain _
  | Cmd.Post_lane_addon_evidence _
  | Cmd.Post_lane_addon_act _
  | Cmd.Post_lane_addon_operator _ ->
      standard_timeout_sec
  (* Heavy tier: probes, fusion launches, config patches, memory recovery,
     OAuth/GitHub/repo/browser CLI or external-service calls *)
  | Cmd.Post_sandbox_probe _
  | Cmd.Post_fusion_launch _
  | Cmd.Post_config_patch _
  | Cmd.Post_memory_act _
  | Cmd.Post_oauth_identity_refresh _
  | Cmd.Post_oauth_login _
  | Cmd.Post_browser_tabs _
  | Cmd.Post_setup_login_start _
  | Cmd.Post_repo_add _
  | Cmd.Post_github_token _
  | Cmd.Post_keeper_control_lifecycle _
  | Cmd.Post_keeper_clear _
  | Cmd.Post_keeper_checkpoints _
  | Cmd.Post_mcp_tools_list _
  | Cmd.Post_mcp_tools_call _
  | Cmd.Post_browser_scene _
  | Cmd.Post_browser_screenshot _
  | Cmd.Post_browser_command _
  | Cmd.Post_browser_interact _
  | Cmd.Post_keeper_lifecycle
      {
        op =
          Wire_fleet.(
            Keeper_boot | Keeper_shutdown | Keeper_resume _ | Keeper_reset);
        _;
      } ->
      heavy_timeout_sec

let stream_spec_of_id = function
  | Subscriptions.Stream_observer -> Sse_hub.Stream_spec.default_observer
  | Subscriptions.Stream_fleet -> Sse_hub.Stream_spec.default_fleet
  | Subscriptions.Stream_model_metrics -> Sse_hub.Stream_spec.model_metrics
  | Subscriptions.Stream_tool_metrics_series ->
      Sse_hub.Stream_spec.tool_metrics_series
  | Subscriptions.Stream_logs { since_seq } ->
      Sse_hub.Stream_spec.logs ?since_seq ()

let stream_id_of_kind = function
  | Sse_hub.Stream_spec.Observer -> Subscriptions.Stream_observer
  | Sse_hub.Stream_spec.Fleet -> Subscriptions.Stream_fleet
  | Sse_hub.Stream_spec.Model_metrics -> Subscriptions.Stream_model_metrics
  | Sse_hub.Stream_spec.Tool_metrics_series ->
      Subscriptions.Stream_tool_metrics_series
  | Sse_hub.Stream_spec.Logs { since_seq } ->
      Subscriptions.Stream_logs { since_seq }

let is_safe_external_url url =
  let trimmed = String.trim url in
  let has_scheme =
    String.starts_with ~prefix:"http://" trimmed
    || String.starts_with ~prefix:"https://" trimmed
  in
  if not has_scheme then false
  else
    let len = String.length trimmed in
    let rec check i =
      if i = len then true
      else
        let code = Char.code trimmed.[i] in
        if code <= 0x20 || code = 0x7F then false else check (i + 1)
    in
    check 0

let is_existing_dir path =
  try Sys.is_directory path with Sys_error _ -> false

let resolve_artifact_export_dir ?(getenv = Sys.getenv_opt)
    ?(is_dir = is_existing_dir) ~base_path () =
  match Option.bind (getenv "HOME") nonblank_trimmed with
  | Some home ->
      let downloads = Filename.concat home "Downloads" in
      if is_dir downloads then Filename.concat downloads "masc-artifacts"
      else Filename.concat (Common.masc_dir_from_base_path ~base_path) "exports"
  | None ->
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "exports"

let normalize_export_ext ext =
  match String.lowercase_ascii (String.trim ext) with
  | ".html" | "html" -> ".html"
  | ".md" | "md" | "markdown" -> ".md"
  | _ -> ".md"

let build_artifact_export_filename ~filename_stem ~id ~ext =
  let safe_ext = normalize_export_ext ext in
  let raw_stem = Common.safe_filename (String.trim filename_stem) in
  let stem =
    let s =
      if String.length raw_stem > 48 then String.sub raw_stem 0 48 else raw_stem
    in
    if String.equal s "" then "artifact" else s
  in
  let safe_id = Common.safe_filename (String.trim id) in
  let stripped_id =
    if String.starts_with ~prefix:"artifact-" safe_id
       && String.length safe_id > String.length "artifact-"
    then
      String.sub safe_id
        (String.length "artifact-")
        (String.length safe_id - String.length "artifact-")
    else safe_id
  in
  let short_id =
    let len = String.length stripped_id in
    if len > 8 then String.sub stripped_id (len - 8) 8 else stripped_id
  in
  let suffix =
    if String.equal short_id "" then "" else "-" ^ short_id
  in
  stem ^ suffix ^ safe_ext

let is_safe_local_export_file path =
  let lower = String.lowercase_ascii (String.trim path) in
  let ext_ok =
    String.ends_with ~suffix:".html" lower || String.ends_with ~suffix:".md" lower
  in
  if not ext_ok then false
  else
    try
      let st = Unix.lstat path in
      match st.Unix.st_kind with
      | Unix.S_REG -> true
      | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          false
    with Unix.Unix_error _ -> false

let fetch_planning_with_tasks ~observed_at ~fetch_planning ~fetch_tasks =
  match fetch_planning () with
  | Error error -> Error (Msg.Planning_goals_failed error)
  | Ok (snap : Wire_work.planning_snapshot) when snap.tasks <> [] -> Ok snap
  | Ok snap -> (
      match fetch_tasks () with
      | Ok tasks ->
          Ok (Wire_work.enrich_planning_with_tasks ~observed_at snap tasks)
      | Error error ->
          Error (Msg.Planning_tasks_failed error))

let is_health_body_ready body =
  match Yojson.Safe.from_string body with
  | json -> (
      match Wire_common.decode_server_health json with
      | Ok health -> (
          health.ok
          &&
          match health.ready with
          | Some false -> false
          | Some true | None -> true)
      | Error _ -> false)
  | exception Yojson.Json_error _ -> false

let is_local_host host =
  match String.lowercase_ascii (String.trim host) with
  | "127.0.0.1" | "localhost" | "::1" | "[::1]" -> true
  | _ -> false

let editor_file_path ~base_path = function
  | Cmd.Edit_runtime_toml ->
      let config_dir =
        Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
      in
      Some (Filename.concat config_dir "runtime.toml")
  | Cmd.Edit_keeper_toml keeper ->
      let keepers_dir =
        Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config")
          "keepers"
      in
      Some (Filename.concat keepers_dir (Common.safe_filename keeper ^ ".toml"))
  | Cmd.Edit_wiki_page _ -> None

type editor_handoff = {
  pause_terminal : unit -> unit;
  resume_terminal : unit -> unit;
}

let noop_editor_handoff =
  { pause_terminal = (fun () -> ()); resume_terminal = (fun () -> ()) }

type t = {
  sw : Eio.Switch.t;
  closed : bool Atomic.t;
  io : Io_domain.t;
  worker : Worker_pool.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cli : Cli_args.config;
  bus : bus;
  explicit_bearer_override : bool;
  endpoint : Http_client.endpoint Atomic.t;
  stream_epoch : Epoch.t Atomic.t;
  owned_server : Masc_server_lifecycle.owned_server option Atomic.t;
  active_memory_diagram_cancel : bool Atomic.t option Atomic.t;
  mcp_tools_list_in_flight : bool Atomic.t;
  skill_read_in_flight : string option Atomic.t;
  sse_hub : Sse_hub.t;
  voice_runner : Voice_runner.t;
  editor_handoff : editor_handoff;
  pending_editor : (unit -> unit) option Atomic.t;
  wiki_editor_gen : int Atomic.t;
  editor_active : bool Atomic.t;
  in_flight_gets_mu : Stdlib.Mutex.t;
  in_flight_gets : (string, (Epoch.t * Cmd.get_request) option ref) Hashtbl.t;
  on_editor_ready : unit -> unit;
  on_quit : Exit_reason.t -> unit;
  on_restart : unit -> unit;
}

let dynamic_voice_backend ~io ~clock ~endpoint_ref : Voice_runner.backend =
  let current () =
    Voice_runner.http_and_local_backend ~io ~clock
      ~endpoint:(Atomic.get endpoint_ref)
  in
  {
    Voice_runner.probe = (fun () -> (current ()).probe ());
    record_until_stopped =
      (fun ~device ~stop_signal ~on_level ->
        (current ()).record_until_stopped ~device ~stop_signal ~on_level);
    transcribe = (fun ~audio_path -> (current ()).transcribe ~audio_path);
    cleanup_audio =
      (fun ~audio_path -> (current ()).cleanup_audio ~audio_path);
  }

let msg_of_voice_event = function
  | Voice_runner.Phase_changed Voice_runner.Voice_idle -> Msg.Voice_idle
  | Voice_runner.Phase_changed (Voice_runner.Voice_recording _) ->
      Msg.Voice_started
  | Voice_runner.Phase_changed Voice_runner.Voice_transcribing ->
      Msg.Voice_transcribing
  | Voice_runner.Phase_changed (Voice_runner.Voice_failed reason) ->
      Msg.Voice_failed reason
  | Voice_runner.Level_meter db -> Msg.Voice_level db
  | Voice_runner.Transcript_ready text -> Msg.Voice_transcript text
  | Voice_runner.Capabilities c ->
      Msg.Voice_capabilities
        {
          recorder_available = c.recorder_available;
          recorder_cmd = c.recorder_cmd;
          stt_available = c.stt_available;
        }
  | Voice_runner.Voice_error reason -> Msg.Voice_failed reason

(* A view-stream frame that cannot be applied is reported like an
   undecodable observer frame, so the failure is on the incident list instead
   of vanishing. *)
let skipped_stream_frame ~epoch detail =
  [
    ( None
    , Msg.Sse_event
        {
          epoch;
          event =
            Msg.Sse_observer_delivery
              { cursor = None; decoded = Wire_observer.Undecodable detail };
        } );
  ]

let decode_hub_event_msgs ~epoch ~observed_at ev =
  match ev with
  | Sse_hub.Freshness { stream; freshness } ->
      let sid = stream_id_of_kind stream in
      [ (Some (Key_freshness sid), Msg.Sse_freshness { epoch; stream = sid; freshness }) ]
  | Sse_hub.Observer_handshake hs ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_observer_handshake hs }) ]
  | Sse_hub.Observer_delivery delivery ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_observer_delivery delivery }) ]
  | Sse_hub.Fleet_event fleet_ev ->
      [ (None, Msg.Sse_event { epoch; event = Msg.Sse_fleet fleet_ev }) ]
  | Sse_hub.Raw_frame { stream; frame } -> (
      match stream with
      | Sse_hub.Stream_spec.Logs _ -> (
          match Yojson.Safe.from_string frame.data with
          | exception Yojson.Json_error msg ->
              skipped_stream_frame ~epoch ("log stream: invalid JSON frame: " ^ msg)
          | json -> (
              match Wire_infra.decode_system_log_frame json with
              | Ok log_frame ->
                  [ (None, Msg.Sse_event { epoch; event = Msg.Sse_log_frame log_frame }) ]
              | Error reason -> skipped_stream_frame ~epoch ("log stream: " ^ reason)))
      | Sse_hub.Stream_spec.Model_metrics -> (
          (* The stream is opened with the chart's window and bucket
             (Wire_runtime.models_metrics_stream_path), so every snapshot
             frame replaces the chart. *)
          let skipped = skipped_stream_frame ~epoch in
          match Yojson.Safe.from_string frame.data with
          | exception Yojson.Json_error msg ->
              skipped ("model metrics stream: invalid JSON frame: " ^ msg)
          | json ->
              if Wire_common.has_field json "window_minutes" then (
                match Wire_runtime.decode_models_metrics ~observed_at json with
                | Ok snap
                  when snap.window_minutes
                       = Wire_runtime.models_chart_window_minutes
                       && snap.bucket_minutes
                          = Wire_runtime.models_chart_bucket_minutes ->
                    [
                      ( None
                      , Msg.Sse_event
                          {
                            epoch;
                            event = Msg.Sse_models_metrics_snapshot snap;
                          } );
                    ]
                | Ok snap ->
                    skipped
                      (Printf.sprintf
                         "model metrics stream answered window=%d \
                          bucket_min=%d; the chart asked window=%d \
                          bucket_min=%d"
                         snap.window_minutes snap.bucket_minutes
                         Wire_runtime.models_chart_window_minutes
                         Wire_runtime.models_chart_bucket_minutes)
                | Error reason -> skipped ("model metrics stream: " ^ reason))
              else if Wire_common.has_field json "error" then
                skipped
                  (match Wire_common.optional_nonblank_string json "error" with
                  | Ok (Some msg) -> "model metrics stream: " ^ msg
                  | Ok None | Error _ -> "model metrics stream error")
              else skipped "model metrics stream: frame has neither window_minutes nor error")
      | Sse_hub.Stream_spec.Tool_metrics_series -> (
          match Yojson.Safe.from_string frame.data with
          | exception Yojson.Json_error msg ->
              skipped_stream_frame ~epoch
                ("tool series stream: invalid JSON frame: " ^ msg)
          | json -> (
              match Wire_runtime.decode_tool_series json with
              | Ok series ->
                  [
                    ( None
                    , Msg.Sse_event { epoch; event = Msg.Sse_tool_series series } );
                  ]
              | Error reason ->
                  (* A failed read arrives as {"error": detail}, and the server
                     then ends the stream (Server_tool_metrics_series_stream). *)
                  skipped_stream_frame ~epoch
                    (match Wire_common.optional_nonblank_string json "error" with
                    | Ok (Some detail) -> "tool series stream: " ^ detail
                    | Ok None | Error _ -> "tool series stream: " ^ reason)))
      | Sse_hub.Stream_spec.Observer | Sse_hub.Stream_spec.Fleet -> [])

let worker_decode_threshold_bytes = 4096

let publish_hub_event ~worker ~bus ~stream_epoch ev =
  let epoch = Atomic.get stream_epoch in
  let observed_at = Clock.Mono.now () in
  let msgs =
    match ev with
    | Sse_hub.Raw_frame { frame; _ }
      when String.length frame.data > worker_decode_threshold_bytes ->
        Worker_pool.submit_cpu worker ~name:"tui_sse_frame_decode" (fun () ->
            decode_hub_event_msgs ~epoch ~observed_at ev)
    | Sse_hub.Freshness _
    | Sse_hub.Observer_handshake _
    | Sse_hub.Observer_delivery _
    | Sse_hub.Fleet_event _
    | Sse_hub.Raw_frame _ ->
        decode_hub_event_msgs ~epoch ~observed_at ev
  in
  List.iter
    (function
      | Some key, msg -> Ui_bus.publish_snapshot bus ~key msg
      | None, msg -> Ui_bus.publish_stream bus msg)
    msgs

let create ~sw ~io ~worker ~clock ~cli ~bus ?bearer_token ?voice_backend
    ?(editor_handoff = noop_editor_handoff) ?(on_editor_ready = fun () -> ())
    ~on_quit ~on_restart () =
  Eio.Switch.check sw;
  let clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let explicit_bearer_override =
    (match bearer_token with Some _ -> true | None -> false)
    || Option.is_some (Option.bind (Sys.getenv_opt "MASC_TOKEN") nonblank_trimmed)
  in
  let initial_ep = endpoint_of_cli ?bearer_token cli in
  let endpoint = Atomic.make initial_ep in
  let stream_epoch = Atomic.make Epoch.initial in
  let owned_server = Atomic.make None in
  let active_memory_diagram_cancel = Atomic.make None in
  let pending_editor = Atomic.make None in
  let wiki_editor_gen = Atomic.make 0 in
  let editor_active = Atomic.make false in
  let in_flight_gets_mu = Stdlib.Mutex.create () in
  let in_flight_gets = Hashtbl.create 32 in
  let mcp_tools_list_in_flight = Atomic.make false in
  let skill_read_in_flight = Atomic.make None in
  let sse_hub =
    Sse_hub.create ~io ~clock ~endpoint:initial_ep
      ~on_event:(publish_hub_event ~worker ~bus ~stream_epoch)
  in
  let backend =
    match voice_backend with
    | Some b -> b
    | None -> dynamic_voice_backend ~io ~clock ~endpoint_ref:endpoint
  in
  let voice_runner =
    Voice_runner.create ~sw ~backend ~on_event:(fun ev ->
        let msg = Msg.Voice_event (msg_of_voice_event ev) in
        match ev with
        | Voice_runner.Level_meter _ -> Ui_bus.publish_stream bus msg
        | Voice_runner.Phase_changed _
        | Voice_runner.Transcript_ready _
        | Voice_runner.Capabilities _
        | Voice_runner.Voice_error _ ->
            Ui_bus.publish_stream_receipt bus msg)
  in
  let closed = Atomic.make false in
  Eio.Switch.on_release sw (fun () ->
      Atomic.set closed true;
      Stdlib.Mutex.lock in_flight_gets_mu;
      Fun.protect
        ~finally:(fun () -> Stdlib.Mutex.unlock in_flight_gets_mu)
        (fun () -> Hashtbl.clear in_flight_gets);
      ignore (Atomic.fetch_and_add wiki_editor_gen 1 : int);
      ignore (Atomic.exchange pending_editor None : (unit -> unit) option);
      match Atomic.exchange active_memory_diagram_cancel None with
      | Some flag -> Atomic.set flag true
      | None -> ());
  {
    sw;
    closed;
    io;
    worker;
    clock;
    cli;
    bus;
    explicit_bearer_override;
    endpoint;
    stream_epoch;
    owned_server;
    active_memory_diagram_cancel;
    mcp_tools_list_in_flight;
    skill_read_in_flight;
    sse_hub;
    voice_runner;
    editor_handoff;
    pending_editor;
    wiki_editor_gen;
    editor_active;
    in_flight_gets_mu;
    in_flight_gets;
    on_editor_ready;
    on_quit;
    on_restart;
  }

let current_endpoint t = Atomic.get t.endpoint

let has_pending_editor t = Option.is_some (Atomic.get t.pending_editor)

let run_pending_editor ?(can_launch = fun () -> true) t =
  if not (Atomic.get t.closed) then
    match Atomic.exchange t.pending_editor None with
    | Some fn ->
        if (not (Atomic.get t.editor_active)) && can_launch () then fn ()
    | None -> ()

let update_workspace_guard t ~instance_id ~workspace_sha256 =
  let guard : Http_client.workspace_guard =
    { expected_instance = instance_id; expected_workspace = workspace_sha256 }
  in
  let next_ep = Http_client.with_guard (Atomic.get t.endpoint) guard in
  Atomic.set t.endpoint next_ep;
  Sse_hub.update_endpoint t.sse_hub next_ep

let run_cpu_if_large t ~name ~bytes work =
  if bytes > worker_decode_threshold_bytes then
    Worker_pool.submit_cpu t.worker ~name work
  else work ()

let decode_raw_json t ~decode raw_body =
  let work () =
    match Yojson.Safe.from_string raw_body with
    | json -> (
        match decode json with
        | Ok v -> Ok v
        | Error msg -> Error (Msg.Decode_error msg)
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception ex -> Error (Msg.Decode_error (Printexc.to_string ex)))
    | exception Yojson.Json_error msg ->
        Error (Msg.Decode_error ("invalid JSON: " ^ msg))
  in
  run_cpu_if_large t ~name:"tui_json_decode" ~bytes:(String.length raw_body) work

let fetch_and_decode_get ~timeout_sec t ~path ~decode =
  let ep = Atomic.get t.endpoint in
  match Http_client.get_raw ~io:t.io ~clock:t.clock ~timeout_sec ep ~path with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw -> decode_raw_json t ~decode raw

let post_and_decode ~timeout_sec t ~path ~body ~decode =
  let ep = Atomic.get t.endpoint in
  let body_str = Yojson.Safe.to_string body in
  match
    Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec
      ~content_type:"application/json" ~body:body_str ep ~path
  with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw -> decode_raw_json t ~decode raw

let post_mcp_and_decode ~timeout_sec t ~method_ ~tool_name ~path ~body ~decode =
  let ep = Atomic.get t.endpoint in
  let body_str = Yojson.Safe.to_string body in
  let extra_headers = Wire_runtime.mcp_headers ~method_ ?tool_name () in
  match
    Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec ~extra_headers
      ~content_type:"application/json" ~body:body_str ep ~path
  with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw -> decode_raw_json t ~decode raw

let parse_post_ack_body raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then Ok ()
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error _ -> Ok ()
    | `Assoc fields -> (
        let ok_false =
          match List.assoc_opt "ok" fields with
          | Some (`Bool false) -> true
          | Some
              ( `Bool true
              | `Null
              | `Int _
              | `Intlit _
              | `Float _
              | `String _
              | `List _
              | `Assoc _ )
          | None ->
              false
        in
        let err_str key =
          match List.assoc_opt key fields with
          | Some (`String s) when not (String.equal (String.trim s) "") ->
              Some (String.trim s)
          | Some
              ( `String _
              | `Null
              | `Bool _
              | `Int _
              | `Intlit _
              | `Float _
              | `List _
              | `Assoc _ )
          | None ->
              None
        in
        match (ok_false, err_str "error", err_str "error_code") with
        | true, Some e, _ -> Error (Msg.Decode_error e)
        | true, None, Some code -> (
            let detail =
              match err_str "detail" with
              | Some d -> code ^ ": " ^ d
              | None -> code
            in
            Error (Msg.Decode_error detail))
        | true, None, None -> (
            let proj =
              match err_str "projection" with
              | Some p -> "operation incomplete: " ^ p
              | None -> "server reported ok=false"
            in
            Error (Msg.Decode_error proj))
        | false, _, Some code -> (
            let detail =
              match err_str "detail" with
              | Some d -> code ^ ": " ^ d
              | None -> code
            in
            Error (Msg.Decode_error detail))
        | false, Some e, None -> Error (Msg.Decode_error e)
        | false, None, None -> Ok ())
    | `Null
    | `Bool _
    | `Int _
    | `Intlit _
    | `Float _
    | `String _
    | `List _ ->
        Ok ()

let post_ack ~timeout_sec t ~path ~body =
  let ep = Atomic.get t.endpoint in
  let body_str = Yojson.Safe.to_string body in
  match
    Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec
      ~content_type:"application/json" ~body:body_str ep ~path
  with
  | Error err -> Error (msg_error_of_http err)
  | Ok raw ->
      run_cpu_if_large t ~name:"tui_post_ack_decode"
        ~bytes:(String.length raw) (fun () -> parse_post_ack_body raw)

let fork_safe t fn =
  if Atomic.get t.closed then ()
  else begin
    Eio.Switch.check t.sw;
    Eio.Fiber.fork ~sw:t.sw (fun () ->
        match fn () with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception Io_domain.Closed -> ()
        | exception ex ->
            Ui_bus.publish_stream_receipt t.bus
              (Msg.Http_reply
                 {
                   epoch = Atomic.get t.stream_epoch;
                   reply =
                     Msg.Reply_action_ack
                       {
                         label =
                           Say.make ~ko:"비동기 요청 오류"
                             ~en:"Async command error";
                         ack_scope = Msg.Ack_toast_only;
                         for_modal = None;
                         result =
                           Error
                             (Msg.Transport
                                (Health.Other_io (Printexc.to_string ex)));
                       };
                 }))
  end

let board_snapshot_key ~epoch ~path ids =
  let scope = string_of_int (Epoch.to_int epoch) :: ids in
  Key_get (path ^ "#" ^ String.concat "/" (List.map Wire_common.percent_encode scope))

let read_chat_queue ~timeout_sec t ~keeper ~partial =
  let endpoint = Atomic.get t.endpoint in
  (* A move to the end assigns a new sequence between pages. Emit each
     operation at its last observed position. *)
  let rows acc =
    List.fold_left
      (fun (seen, ordered) (row : Wire_fleet.chat_operation) ->
         let id = Keeper_chat_operation.Operation_id.to_string row.id in
         if Fleet_store.String_set.mem id seen then seen, ordered
         else Fleet_store.String_set.add id seen, row :: ordered)
      (Fleet_store.String_set.empty, []) acc |> snd
  in
  let rec read after acc running_batch =
    if Atomic.get t.closed then
      rows acc, running_batch, Error (Msg.Transport (Health.Other_io "executor closed"))
    else
      let path = Wire_fleet.chat_queue_path ~keeper ~after in
      let decode json =
        Result.bind (Wire_fleet.decode_chat_queue ~after json) (fun page ->
          if Option.is_none after then
            Result.map (fun batch -> (page, batch)) (Wire_fleet.decode_running_chat_batch json)
          else Ok (page, running_batch))
      in
      let page = match Http_client.get_raw ~io:t.io ~clock:t.clock ~timeout_sec endpoint ~path with
        | Error err -> Error (msg_error_of_http err)
        | Ok raw -> decode_raw_json t ~decode raw in
      match page with
      | Error err -> rows acc, running_batch, Error err
      | Ok ([], running_batch) -> rows acc, running_batch, Ok ()
      | Ok (page, running_batch) ->
          let acc = List.rev_append page acc in
          partial (rows acc) running_batch;
          (* The decoder checked that every sequence advances the requested
             cursor. Yield to other work and observe cancellation between pages. *)
          Eio.Fiber.yield ();
          read (Some (List.hd acc).sequence) acc running_batch
  in
  read None [] None

let get_request_keys ~epoch ~path ~requested_at (req : Cmd.get_request) =
  let base = Printf.sprintf "%d:%s" (Epoch.to_int epoch) path in
  (* One URL can feed distinct reducers. Preserve that identity both while
     the HTTP request is running and while its reply awaits the UI drain. *)
  let scoped suffix =
    let key = base ^ suffix in
    Some key, Key_get key
  in
  match req with
  (* Timestamped queue/status reads use [Key_read (path, requested_at)] so a
     newer overlapping refresh can overtake a stalled older read; never merge
     them under single-flight dedup. *)
  | Cmd.Get_chat_queue _ | Cmd.Get_chat_status _ -> None, Key_read (path, requested_at)
  | Cmd.Get_board_quarantines { generation; _ } ->
      Some (Printf.sprintf "%s#quarantines=%d" base generation),
      board_snapshot_key ~epoch ~path [string_of_int generation]
  | Cmd.Get_keeper_turn_records _ -> scoped "#fleet-turns"
  | Cmd.Get_keeper_context_turn_records _ -> scoped "#context-turns"
  | Cmd.Get_keeper_tool_calls { turn_ref = Some tr; _ } -> scoped ("#turn_ref=" ^ tr)
  | Cmd.Get_keeper_tool_calls { turn_ref = None; _ } -> scoped "#tool-calls"
  | Cmd.Get_keeper_operator_note { modal_prefill_id = Some id; _ } ->
      scoped (Printf.sprintf "#note-prefill=%d" id)
  | Cmd.Get_keeper_operator_note { modal_prefill_id = None; _ } ->
      (* A post-save readback must be able to complete ahead of an older
         passive Context read in the same Keeper and epoch. *)
      None, Key_read (base, requested_at)
  | Cmd.Get_tool_series _ -> scoped "#tool-series"
  | Cmd.Get_tool_series_filtered _ -> scoped "#tool-series-filtered"
  | Cmd.Get_planning | Cmd.Get_verifications _ | Cmd.Get_asks _
  | Cmd.Get_tool_approvals | Cmd.Get_gate_pending -> scoped ""
  | Cmd.Get_health
  | Cmd.Get_dashboard_shell
  | Cmd.Get_keepers_roster
  | Cmd.Get_keeper_turns
  | Cmd.Get_chat_history _
  | Cmd.Get_chat_operation_events _
  | Cmd.Get_schedules _
  | Cmd.Get_candle_ledger _
  | Cmd.Get_board_feed _
  | Cmd.Get_board_hearths
  | Cmd.Get_board_thread _
  | Cmd.Get_wiki_index _
  | Cmd.Get_wiki_page _
  | Cmd.Get_wiki_log _
  | Cmd.Get_wiki_search _
  | Cmd.Get_wiki_lint
  | Cmd.Get_artifacts
  | Cmd.Get_artifact_detail _
  | Cmd.Get_artifact_checks
  | Cmd.Get_world_memory
  | Cmd.Get_memory_diff _
  | Cmd.Get_keeper_memory_os_internals _
  | Cmd.Get_keeper_memory_facts _
  | Cmd.Get_keeper_memory_activity _
  | Cmd.Get_keeper_memory_health _
  | Cmd.Get_keeper_provider_input _
  | Cmd.Get_keeper_provider_input_part _
  | Cmd.Get_keeper_cache_outcome _
  | Cmd.Get_keeper_next_request _
  | Cmd.Get_keeper_turn_transcript _
  | Cmd.Get_keeper_tool_stats _
  | Cmd.Get_keeper_tool_result _
  | Cmd.Get_provider_usage _
  | Cmd.Get_keeper_costs _
  | Cmd.Get_efficiency _
  | Cmd.Get_models_metrics _
  | Cmd.Get_runtime_metrics
  | Cmd.Get_runtime_resolved
  | Cmd.Get_runtime_config_raw
  | Cmd.Get_setup_inventory
  | Cmd.Get_setup_login_status _
  | Cmd.Get_runtime_probe _
  | Cmd.Get_exact_lane_runs _
  | Cmd.Get_fusion_runs
  | Cmd.Get_tools_catalog _
  | Cmd.Get_skills
  | Cmd.Get_connectors
  | Cmd.Get_browser_lane
  | Cmd.Get_lane_addons
  | Cmd.Get_mcp_clients
  | Cmd.Get_sandboxes
  | Cmd.Get_keeper_sandbox _
  | Cmd.Get_repositories
  | Cmd.Get_repository_pulls
  | Cmd.Get_repository_detail _
  | Cmd.Get_repository_activity _
  | Cmd.Get_system_logs _
  | Cmd.Get_tui_preferences
  | Cmd.Get_config_schema _
  | Cmd.Get_fusion_run_detail _
  | Cmd.Get_fusion_config
  | Cmd.Get_fusion_board_evidence _
  | Cmd.Get_harness_health
  | Cmd.Get_verification_evidence _
  | Cmd.Get_verification_summary
  | Cmd.Get_verification_specs
  | Cmd.Get_verification_tlc_results
  | Cmd.Get_activity_events _
  | Cmd.Get_keeper_runtime_trace _
  | Cmd.Get_keeper_metrics _
  | Cmd.Get_keeper_sandbox_logs _
  | Cmd.Get_workspace_children _
  | Cmd.Get_workspace_files _
  | Cmd.Get_workspace_search _
  | Cmd.Get_workspace_file _
  | Cmd.Get_git_branches _
  | Cmd.Get_git_worktrees _
  | Cmd.Get_git_status _
  | Cmd.Get_git_blame _
  | Cmd.Get_git_log _
  | Cmd.Get_git_diff _
  | Cmd.Get_workspace_memory_ledger
  | Cmd.Get_workspace_memory_context
  | Cmd.Get_keeper_memory_journal _
  | Cmd.Get_oauth_providers
  | Cmd.Get_oauth_attached_tools _
  | Cmd.Get_oauth_attempt_status _
  | Cmd.Get_github_identity _
  | Cmd.Get_addon_package_catalog _
  | Cmd.Get_addon_package_preview _
  | Cmd.Get_connector_names _
  | Cmd.Get_keeper_turn_flow _
  | Cmd.Get_keeper_checkpoints _
  | Cmd.Get_tool_approval_modes
  | Cmd.Get_late_approval_attempts
  | Cmd.Get_tool_quality _
  | Cmd.Get_gate_tool_events _
  | Cmd.Get_keeper_waiting_inventory _
  | Cmd.Get_skill_editor_sources
  | Cmd.Get_skill_editor_tools
  | Cmd.Get_async_requests
  | Cmd.Get_prompts
  | Cmd.Get_presets
  | Cmd.Get_preset_show _
  | Cmd.Get_runtime_params
  | Cmd.Get_lanes_inventory
  | Cmd.Get_standalone_lanes
  | Cmd.Get_exact_lane_run_detail _
  | Cmd.Get_verification_runs
  | Cmd.Get_goal_verification_runs
  | Cmd.Get_goal_confirmation _
  | Cmd.Get_keeper_board_attention_quarantines _
  | Cmd.Get_lane_addon_declaration _
  | Cmd.Get_lane_addon_action_status _
  | Cmd.Get_lane_addon_slice _
  | Cmd.Get_lane_addon_asks _ ->
      Some base, Key_get path

let rec execute_get t ~epoch req =
  let path = Cmd.get_request_path req in
  let timeout_sec = timeout_sec_for_get req in
  let fetch_and_decode_get t ~path ~decode =
    fetch_and_decode_get ~timeout_sec t ~path ~decode
  in
  let requested_at = Clock.Mono.now () in
  let inflight_key, snapshot_key = get_request_keys ~epoch ~path ~requested_at req in
  let inflight_slot =
    match inflight_key with
    | None -> `Run_unlocked
    | Some inflight_key ->
        Stdlib.Mutex.lock t.in_flight_gets_mu;
        Fun.protect
          ~finally:(fun () -> Stdlib.Mutex.unlock t.in_flight_gets_mu)
          (fun () ->
            match Hashtbl.find_opt t.in_flight_gets inflight_key with
            | Some pending_ref ->
                (* Coalesce concurrent duplicates into at most one sequential
                   follow-up so post-mutation / SSE / manual refreshes are
                   never dropped while preventing duplicate GET storms. *)
                pending_ref := Some (epoch, req);
                `Coalesced
            | None ->
                let pending_ref = ref None in
                Hashtbl.add t.in_flight_gets inflight_key pending_ref;
                `Admitted (inflight_key, pending_ref))
  in
  match inflight_slot with
  | `Coalesced -> ()
  | `Run_unlocked | `Admitted _ ->
      let release_inflight ~capture_followup =
        match inflight_slot with
        | `Run_unlocked | `Coalesced -> None
        | `Admitted (inflight_key, pending_ref) ->
            Stdlib.Mutex.lock t.in_flight_gets_mu;
            Fun.protect
              ~finally:(fun () -> Stdlib.Mutex.unlock t.in_flight_gets_mu)
              (fun () ->
                match Hashtbl.find_opt t.in_flight_gets inflight_key with
                | Some slot when slot == pending_ref ->
                    let followup = if capture_followup then !slot else None in
                    Hashtbl.remove t.in_flight_gets inflight_key;
                    followup
                | Some _ | None -> None)
      in
      if Atomic.get t.closed then
        ignore
          (release_inflight ~capture_followup:false
            : (Epoch.t * Cmd.get_request) option)
      else
        try
          fork_safe t (fun () ->
              let completed_ok = ref false in
              let next_followup = ref None in
              Fun.protect
                ~finally:(fun () ->
                  next_followup :=
                    release_inflight ~capture_followup:!completed_ok)
                (fun () ->
                  let observed_at = Clock.Mono.now () in
                  let msg =
        match req with
        | Cmd.Get_health ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_common.decode_server_health
            in
            Msg.Server_health_result { epoch; result }
        | Cmd.Get_dashboard_shell ->
            let reply =
              Msg.Reply_dashboard_shell
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_fleet.decode_dashboard_shell ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keepers_roster ->
            let roster_res =
              fetch_and_decode_get t ~path ~decode:(fun json ->
                  match Wire_fleet.decode_keepers_roster ~observed_at json with
                  | Error _ as err -> err
                  | Ok roster ->
                      let extras =
                        match Wire_fleet.decode_keepers_roster_extras json with
                        | Ok ex -> Some ex
                        | Error _ -> None
                      in
                      Ok (roster, extras))
            in
            let reply =
              match roster_res with
              | Ok (roster, extras_opt) ->
                  Option.iter
                    (fun ex ->
                      Ui_bus.publish_snapshot t.bus
                        ~key:(Key_get (path ^ "#extras"))
                        (Msg.Http_reply
                           { epoch; reply = Msg.Reply_keepers_roster_extras ex }))
                    extras_opt;
                  Msg.Reply_keepers_roster (Ok roster)
              | Error _ as err -> Msg.Reply_keepers_roster err
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_turns ->
            let reply =
              Msg.Reply_keeper_turns
                (fetch_and_decode_get t ~path
                   ~decode:Wire_fleet.decode_keeper_turns)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_turn_records { keeper; _ } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_fleet.decode_keeper_turn_records
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_keeper_turn_records { keeper; result } }
        | Cmd.Get_chat_queue { keeper } ->
            let reply operations running_batch result =
              Msg.Http_reply { epoch; reply = Msg.Reply_chat_queue {
                keeper; requested_at; operations; running_batch; result } } in
            let partial rows batch =
              Ui_bus.publish_snapshot t.bus ~key:snapshot_key (reply rows batch None) in
            let rows, batch, result = read_chat_queue ~timeout_sec t ~keeper ~partial in
            reply rows batch (Some result)
        | Cmd.Get_chat_status { keeper; operation_id } ->
            (* Preserve each exact observation until the reducer has consumed it.
               A delayed queued read cannot replace a running or terminal one. *)
            let decode json =
              match Wire_fleet.decode_chat_operation json with
              | Ok row when String.equal (Keeper_chat_operation.Operation_id.to_string row.id) operation_id -> Ok row
              | Ok _ -> Error "chat operation returned a different id"
              | Error _ as err -> err
            in
            let result = fetch_and_decode_get t ~path ~decode in
            let reply = Msg.chat_status_reply ~keeper ~operation_id ~requested_at result in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_chat_history { keeper; _ } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_fleet.decode_chat_history_page
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_chat_history { keeper; result } }
        | Cmd.Get_chat_operation_events { keeper; operation_id; from } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:(Wire_chat_journal.decode_page ~operation_id)
            in
            Msg.Http_reply
              {
                epoch;
                reply =
                  Msg.Reply_chat_operation_events
                    { keeper; operation_id; from; result };
              }
        | Cmd.Get_planning ->
            let planning_res =
              fetch_planning_with_tasks ~observed_at
                ~fetch_planning:(fun () ->
                  let result = fetch_and_decode_get t ~path ~decode:(fun json ->
                      match
                        Wire_work.decode_planning_snapshot ~observed_at json
                      with
                      | Error _ as err -> err
                      | Ok snap ->
                          (match Wire_work.decode_planning_backlog_counts json with
                          | Ok (Some counts) ->
                              Ui_bus.publish_snapshot t.bus
                                ~key:(Key_get (Printf.sprintf "%d:%s#backlog" (Epoch.to_int epoch) path))
                                (Msg.Http_reply
                                   {
                                     epoch;
                                     reply = Msg.Reply_planning_backlog counts;
                                   })
                          | Ok None | Error _ -> ());
                          Ok snap)
                  in
                  (match result with
                  | Ok (snap : Wire_work.planning_snapshot) ->
                      Ui_bus.publish_stream_receipt t.bus
                        (Msg.Http_reply
                           { epoch; reply = Msg.Reply_planning_goals snap.goals })
                  | Error _ -> ());
                  result)
                ~fetch_tasks:(fun () ->
                  fetch_and_decode_get t ~path:Wire_work.execution_tasks_path
                    ~decode:(fun json ->
                      (match
                         Wire_fleet.decode_execution_keeper_enrichments json
                       with
                      | Ok ((_ :: _ as enrichments), candle_opt) ->
                          Ui_bus.publish_snapshot t.bus
                            ~key:
                              (Key_get
                                 (Wire_work.execution_tasks_path ^ "#enrich"))
                            (Msg.Http_reply
                               {
                                 epoch;
                                 reply =
                                   Msg.Reply_execution_enrichments
                                     (enrichments, candle_opt);
                               })
                      | Ok ([], Some candle) ->
                          Ui_bus.publish_snapshot t.bus
                            ~key:
                              (Key_get
                                 (Wire_work.execution_tasks_path ^ "#enrich"))
                            (Msg.Http_reply
                               {
                                 epoch;
                                 reply =
                                   Msg.Reply_execution_enrichments
                                     ([], Some candle);
                               })
                      | Ok ([], None) | Error _ -> ());
                      Wire_work.decode_execution_tasks json))
            in
            let reply = Msg.Reply_planning planning_res in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verifications { view; generation; _ } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_work.decode_verification_snapshot
            in
            Msg.Http_reply { epoch; reply = Msg.Reply_verifications { view; generation; result } }
        | Cmd.Get_schedules _ ->
            let reply =
              Msg.Reply_schedules
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_schedules_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_asks _ ->
            let reply =
              Msg.Reply_asks
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_asks_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_approvals ->
            let reply =
              Msg.Reply_tool_approvals
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_tool_approvals)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_gate_pending ->
            let reply =
              Msg.Reply_gate_snapshot
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_gate_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_candle_ledger _ ->
            let reply =
              Msg.Reply_candle_ledger
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_candle_ledger)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_feed _ ->
            let feed_res =
              fetch_and_decode_get t ~path ~decode:(fun json ->
                  match Wire_knowledge.decode_board_feed ~observed_at json with
                  | Error _ as err -> err
                  | Ok feed ->
                      let meta =
                        match Wire_knowledge.decode_board_feed_meta json with
                        | Ok m -> Some m
                        | Error _ -> None
                      in
                      Ok (feed, meta))
            in
            let reply =
              match feed_res with
              | Ok (feed, meta_opt) ->
                  (match meta_opt with
                   | Some meta ->
                       Ui_bus.publish_snapshot t.bus
                         ~key:(Key_get (path ^ "#meta"))
                         (Msg.Http_reply
                            { epoch; reply = Msg.Reply_board_feed_meta meta })
                   | None -> ());
                  Msg.Reply_board_feed (Ok feed)
              | Error _ as err -> Msg.Reply_board_feed err
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_hearths ->
            let reply =
              Msg.Reply_board_hearths
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_board_hearths)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_thread { post_id; _ } ->
            let thread_res =
              fetch_and_decode_get t ~path ~decode:(fun json ->
                  match Wire_knowledge.decode_board_thread ~observed_at json with
                  | Error _ as err -> err
                  | Ok thread ->
                      let meta =
                        match Wire_knowledge.decode_board_thread_meta json with
                        | Ok m -> Some m
                        | Error _ -> None
                      in
                      Ok (thread, meta))
            in
            let result =
              match thread_res with
              | Ok (thread, meta_opt) ->
                  (match meta_opt with
                   | Some meta ->
                       Ui_bus.publish_snapshot t.bus
                         ~key:(Key_get (path ^ "#meta"))
                         (Msg.Http_reply
                            { epoch; reply = Msg.Reply_board_thread_meta meta })
                   | None -> ());
                  Ok thread
              | Error _ as err -> err
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_board_thread { post_id; result } }
        | Cmd.Get_wiki_index _ ->
            let reply =
              Msg.Reply_wiki_index
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_index)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_page { page } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:Wire_knowledge.decode_wiki_page_detail
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_wiki_page { page; result } }
        | Cmd.Get_wiki_log _ ->
            let reply =
              Msg.Reply_wiki_log
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_log)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_search _ ->
            let reply =
              Msg.Reply_wiki_search
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_search)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_wiki_lint ->
            let reply =
              Msg.Reply_wiki_lint
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_wiki_lint)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_artifacts ->
            let reply =
              Msg.Reply_artifacts
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_artifacts_list)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_artifact_detail { id; _ } ->
            let reply =
              Msg.Reply_artifact_detail
                {
                  id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_published_artifact_detail;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_artifact_checks ->
            let reply =
              Msg.Reply_artifact_checks
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_artifact_checks)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_world_memory ->
            let primary =
              fetch_and_decode_get t ~path
                ~decode:Wire_knowledge.decode_world_memory
            in
            let resolved =
              match primary with
              | Error (Msg.Http_error { status = 404; _ }) ->
                  fetch_and_decode_get t
                    ~path:Wire_knowledge.workspace_memory_inventory_path
                    ~decode:
                      Wire_knowledge.decode_workspace_memory_inventory_as_world_memory
              | Ok _
              | Error
                  ( Msg.Http_error _
                  | Msg.Transport _
                  | Msg.Workspace_mismatch _
                  | Msg.Decode_error _ ) ->
                  primary
            in
            let reply = Msg.Reply_world_memory resolved in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_memory_diff { keeper; window } ->
            let reply =
              Msg.Reply_memory_diff
                {
                  keeper;
                  window;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_memory_diff;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_os_internals { keeper } ->
            let reply =
              Msg.Reply_keeper_memory_os_internals
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_memory_os_internals;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_facts { keeper } ->
            let reply =
              Msg.Reply_keeper_memory_facts
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_facts;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_activity { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_memory_activity
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_activity;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_health { keeper = None } ->
            let reply =
              Msg.Reply_keeper_memory_health
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_keeper_memory_health_fleet)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_context_turn_records { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_context_turn_records
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_turn_records;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_provider_input { keeper; turn_ref } ->
            let reply =
              Msg.Reply_keeper_provider_input
                {
                  keeper;
                  turn_ref;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_provider_input_manifest;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_provider_input_part { keeper; turn_ref; index } ->
            let reply =
              Msg.Reply_keeper_provider_input_part
                {
                  keeper;
                  turn_ref;
                  index;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_provider_input_part;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_cache_outcome { keeper; turn_ref } ->
            let reply =
              Msg.Reply_keeper_cache_outcome
                {
                  keeper;
                  turn_ref;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_cache_outcome;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_next_request { keeper } ->
            let reply =
              Msg.Reply_keeper_next_request
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_next_request_forecast;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_turn_transcript { keeper; turn_ref } ->
            let reply =
              Msg.Reply_keeper_turn_transcript
                {
                  keeper;
                  turn_ref;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_turn_transcript;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_tool_stats { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_tool_stats
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_keeper_tool_stats;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_tool_calls { keeper; turn_ref; _ } ->
            let reply =
              Msg.Reply_keeper_tool_calls
                {
                  keeper;
                  turn_ref;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_keeper_tool_calls;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_tool_result { keeper; execution_id; _ } ->
            let reply =
              Msg.Reply_keeper_tool_result
                {
                  keeper;
                  execution_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_tool_result;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_provider_usage _ ->
            let reply =
              Msg.Reply_provider_usage_history
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_provider_usage_history)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_costs _ ->
            let reply =
              Msg.Reply_keeper_costs
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_keeper_costs_window ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_efficiency _ ->
            let reply =
              Msg.Reply_efficiency
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_efficiency_month ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_models_metrics _ ->
            let reply =
              Msg.Reply_models_metrics
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_models_metrics ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_metrics ->
            let reply =
              Msg.Reply_runtime_metrics
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_runtime.decode_runtime_metrics ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_resolved ->
            let resolved_res =
              fetch_and_decode_get t ~path ~decode:(fun json ->
                  match Wire_runtime.decode_runtime_resolved json with
                  | Error _ as err -> err
                  | Ok snap ->
                      let standings_res =
                        Wire_runtime.decode_runtime_standings json
                      in
                      Ok (snap, standings_res))
            in
            let reply =
              match resolved_res with
              | Ok (snap, standings_res) ->
                  Ui_bus.publish_snapshot t.bus
                    ~key:(Key_get (path ^ "#standings"))
                    (Msg.Http_reply
                       { epoch; reply = Msg.Reply_runtime_standings standings_res });
                  Msg.Reply_runtime_resolved (Ok snap)
              | Error _ as err -> Msg.Reply_runtime_resolved err
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_config_raw ->
            let reply =
              Msg.Reply_runtime_config_raw
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_config_raw_meta)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_setup_inventory ->
            let reply =
              Msg.Reply_setup_inventory
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_setup_inventory)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_setup_login_status _ ->
            let reply =
              Msg.Reply_setup_login_receipt
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_setup_login_receipt)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_probe _ ->
            let reply =
              Msg.Reply_runtime_probe
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_probe)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_exact_lane_runs _ ->
            let reply =
              Msg.Reply_exact_lane_runs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_exact_lane_runs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_fusion_runs ->
            let reply =
              Msg.Reply_fusion_runs_snapshot
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_fusion_runs_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_series _ ->
            let reply =
              Msg.Reply_tool_series
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_tool_series)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_series_filtered { since_hours; tool; _ } ->
            let reply =
              Msg.Reply_tool_series_summary
                {
                  tool;
                  since_hours;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_tool_series_summary;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tools_catalog { keeper } ->
            let reply =
              Msg.Reply_tools_dashboard
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:(Wire_runtime.decode_tools_dashboard ~observed_at);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_skills ->
            let reply =
              Msg.Reply_skills
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_skills_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_connectors ->
            let reply =
              Msg.Reply_connectors
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_connectors)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_browser_lane ->
            let reply =
              Msg.Reply_browser_lane
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_browser_lane)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lane_addons ->
            let reply =
              Msg.Reply_lane_addons
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_lane_addons)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_mcp_clients ->
            let reply =
              Msg.Reply_mcp_clients
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_mcp_clients)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_sandboxes ->
            let reply =
              Msg.Reply_sandboxes
                (fetch_and_decode_get t ~path
                   ~decode:(Wire_infra.decode_sandboxes_snapshot ~observed_at))
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_sandbox { keeper } ->
            let result =
              fetch_and_decode_get t ~path
                ~decode:(fun json ->
                  Result.bind (Wire_infra.decode_keeper_sandbox ~observed_at json)
                    (fun (detail : Wire_infra.keeper_sandbox_response) ->
                      if String.equal detail.keeper keeper then Ok detail
                      else Error "sandbox telemetry belongs to another Keeper"))
            in
            Msg.Http_reply
              { epoch; reply = Msg.Reply_keeper_sandbox { keeper; result } }
        | Cmd.Get_repositories ->
            let reply =
              Msg.Reply_repositories
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_repositories)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_repository_pulls ->
            let reply =
              Msg.Reply_repository_pulls
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_repository_pulls)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_repository_detail { repo_id } ->
            let reply =
              Msg.Reply_repository_detail
                {
                  repo_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_repository_observation;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_repository_activity { repo_id } ->
            let reply =
              Msg.Reply_repository_activity
                {
                  repo_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:(Wire_infra.decode_repository_activity ~repo_id);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_system_logs _ ->
            let reply =
              Msg.Reply_system_logs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_system_log_snapshot)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tui_preferences ->
            let reply =
              Msg.Reply_tui_preferences
                (fetch_and_decode_get t ~path
                   ~decode:Wire_config.decode_tui_preferences)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_config_schema _ ->
            let res =
              fetch_and_decode_get t ~path
                ~decode:Wire_config.decode_config_schema_with_meta
            in
            let reply =
              match res with
              | Ok (schema, meta) ->
                  if meta <> [] then
                    Ui_bus.publish_snapshot t.bus
                      ~key:(Key_get (path ^ "#meta"))
                      (Msg.Http_reply
                         {
                           epoch;
                           reply =
                             Msg.Reply_config_schema_meta
                               { target = schema.target; meta };
                         });
                  Msg.Reply_config_schema (Ok schema)
              | Error err -> Msg.Reply_config_schema (Error err)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_fusion_run_detail { run_id } ->
            let reply =
              Msg.Reply_fusion_run_detail
                {
                  run_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_fusion_run_detail;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_fusion_config ->
            let reply =
              Msg.Reply_fusion_config
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_fusion_config_options)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_fusion_board_evidence { post_id } ->
            let reply =
              Msg.Reply_fusion_board_evidence
                {
                  post_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_fusion_board_evidence;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_harness_health ->
            let reply =
              Msg.Reply_harness_health
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_harness_health)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verification_evidence { verification_id; _ } ->
            let reply =
              Msg.Reply_verification_evidence
                {
                  verification_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_work.decode_verification_evidence;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verification_summary ->
            let reply =
              Msg.Reply_verification_summary
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_verification_summary)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verification_specs ->
            let reply =
              Msg.Reply_verification_specs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_verification_specs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verification_tlc_results ->
            let reply =
              Msg.Reply_verification_tlc_results
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_verification_tlc_results)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_activity_events _ ->
            let reply =
              Msg.Reply_activity_events
                (fetch_and_decode_get t ~path
                   ~decode:Wire_infra.decode_activity_events_page)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_runtime_trace { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_runtime_trace
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_runtime_trace;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_metrics { keeper } ->
            let reply =
              Msg.Reply_keeper_metrics
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_keeper_metrics;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_sandbox_logs { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_sandbox_logs
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_keeper_sandbox_logs;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_children { scope; dir } ->
            let reply =
              Msg.Reply_workspace_children
                {
                  scope;
                  dir;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_workspace_children;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_files { scope } ->
            let reply =
              Msg.Reply_workspace_files
                {
                  scope;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_workspace_files;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_search { scope; _ } ->
            let reply =
              Msg.Reply_workspace_search
                {
                  scope;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_workspace_search;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_file { scope; path = fpath } ->
            let reply =
              Msg.Reply_workspace_file
                {
                  scope;
                  path = fpath;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:(Wire_infra.decode_workspace_file ~path:fpath);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_branches { scope } ->
            let reply =
              Msg.Reply_git_branches
                {
                  scope;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_branches;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_worktrees { scope } ->
            let reply =
              Msg.Reply_git_worktrees
                {
                  scope;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_worktrees;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_status { scope } ->
            let reply =
              Msg.Reply_git_status
                {
                  scope;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_status;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_blame { scope; path = fpath } ->
            let reply =
              Msg.Reply_git_blame
                {
                  scope;
                  path = fpath;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_blame;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_log { scope; path = fpath } ->
            let reply =
              Msg.Reply_git_log
                {
                  scope;
                  path = fpath;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_log;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_git_diff { scope; path = fpath } ->
            let reply =
              Msg.Reply_git_diff
                {
                  scope;
                  path = fpath;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_infra.decode_git_diff;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_health { keeper = Some keeper } ->
            let reply =
              Msg.Reply_memory_health_keeper
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_health_single;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_memory_ledger ->
            let reply =
              Msg.Reply_workspace_memory_ledger
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_workspace_memory_ledger)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_workspace_memory_context ->
            let reply =
              Msg.Reply_workspace_memory_context
                (fetch_and_decode_get t ~path
                   ~decode:Wire_knowledge.decode_workspace_memory_context)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_memory_journal { keeper; _ } ->
            let reply =
              Msg.Reply_keeper_memory_journal
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_knowledge.decode_keeper_memory_journal;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_oauth_providers ->
            let reply =
              Msg.Reply_oauth_providers
                (fetch_and_decode_get t ~path
                   ~decode:Wire_keeper_context.decode_oauth_providers)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_oauth_attached_tools { keeper } ->
            let reply =
              Msg.Reply_oauth_attached_tools
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_oauth_attached_tools;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_oauth_attempt_status { keeper; provider; attempt_id } ->
            let reply =
              Msg.Reply_oauth_attempt_status
                {
                  keeper; provider; attempt_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_oauth_attempt_status;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_board_quarantines { keeper; generation } ->
            let result = fetch_and_decode_get t ~path ~decode:(Board_quarantine.inventory_of_json ~keeper) in
            Msg.Http_reply { epoch; reply = Msg.Reply_board_quarantines { keeper; generation; result } }
        | Cmd.Get_github_identity { keeper } ->
            let reply =
              Msg.Reply_github_identity
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_keeper_context.decode_github_identity;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_addon_package_catalog _ ->
            let reply =
              Msg.Reply_addon_package_catalog
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_addon_package_catalog)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_addon_package_preview { manifest_path } ->
            let reply =
              Msg.Reply_addon_package_preview
                {
                  manifest_path;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_addon_package_preview;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_connector_names { connector; _ } ->
            let reply =
              Msg.Reply_connector_names
                {
                  connector;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_connector_names_page;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_turn_flow { keeper; trace_id; turn_id; turn_ref } ->
            let reply =
              Msg.Reply_keeper_turn_flow
                {
                  keeper;
                  turn_ref;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:
                        (Wire_keeper_context.decode_turn_flow ~keeper ~trace_id
                           ~turn_id);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_checkpoints { keeper } ->
            let reply =
              Msg.Reply_keeper_checkpoints
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:
                        Wire_keeper_context.decode_keeper_checkpoints_inventory;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_operator_note { keeper; modal_prefill_id } ->
            let reply =
              Msg.Reply_keeper_operator_note_loaded
                {
                  keeper;
                  modal_prefill_id;
                  requested_at;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:(Wire_keeper_context.decode_keeper_operator_note ~keeper);
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_approval_modes ->
            let reply =
              Msg.Reply_tool_approval_modes
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_tool_approval_modes)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_late_approval_attempts ->
            let reply =
              Msg.Reply_late_approval_attempts
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_late_approval_attempts)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_tool_quality _ ->
            let reply =
              Msg.Reply_tool_quality
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_tool_quality)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_gate_tool_events _ ->
            let reply =
              Msg.Reply_gate_tool_events
                (fetch_and_decode_get t ~path
                   ~decode:Wire_work.decode_gate_tool_events)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_waiting_inventory { keeper } ->
            let reply =
              Msg.Reply_keeper_waiting_inventory
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_keeper_waiting_inventory;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_skill_editor_sources ->
            let reply =
              Msg.Reply_skill_editor_sources
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_skill_editor_sources)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_skill_editor_tools ->
            let reply =
              Msg.Reply_skill_editor_tools
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_skill_editor_tools)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_async_requests ->
            let reply =
              Msg.Reply_async_requests
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_async_requests)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_prompts ->
            let reply =
              Msg.Reply_prompts
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_prompts_catalog)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_presets ->
            let reply =
              Msg.Reply_presets
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_presets_listing)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_preset_show { name } ->
            let reply =
              Msg.Reply_preset_detail
                {
                  name;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_preset_detail;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_runtime_params ->
            let reply =
              Msg.Reply_runtime_params
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_runtime_params)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lanes_inventory ->
            let reply =
              Msg.Reply_lanes_inventory
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_lane_inventory)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_standalone_lanes ->
            let reply =
              Msg.Reply_standalone_lanes
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_standalone_lanes)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_exact_lane_run_detail { run_id } ->
            let reply =
              Msg.Reply_exact_lane_run_detail
                {
                  run_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_exact_lane_run_detail;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_verification_runs ->
            let reply =
              Msg.Reply_verification_runs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_verification_runs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_goal_verification_runs ->
            let reply =
              Msg.Reply_goal_verification_runs
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_goal_verification_runs)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_goal_confirmation { goal_id } ->
            let reply =
              Msg.Reply_goal_confirmation
                {
                  goal_id;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_work.decode_goal_confirmation;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_keeper_board_attention_quarantines { keeper } ->
            let reply =
              Msg.Reply_keeper_board_attention_quarantines
                {
                  keeper;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_board_attention_quarantines;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lane_addon_declaration { source_path } ->
            let reply =
              Msg.Reply_lane_addon_declaration
                {
                  source_path;
                  result =
                    fetch_and_decode_get t ~path
                      ~decode:Wire_runtime.decode_addon_declaration_document;
                }
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lane_addon_action_status _ ->
            let reply =
              Msg.Reply_lane_addon_action_receipt
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_addon_action_receipt)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lane_addon_slice _ ->
            let reply =
              Msg.Reply_lane_addon_slice
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_addon_slice)
            in
            Msg.Http_reply { epoch; reply }
        | Cmd.Get_lane_addon_asks _ ->
            let reply =
              Msg.Reply_lane_addon_asks
                (fetch_and_decode_get t ~path
                   ~decode:Wire_runtime.decode_lane_addon_asks)
            in
            Msg.Http_reply { epoch; reply }
      in
      (* A later Goals receipt can arrive before the UI drains this terminal
         result. Keep both in arrival order so a completed Tasks read survives
         a subsequent Execution failure as the last observation. *)
      ((match req with
        | Cmd.Get_planning
        | Cmd.Get_keeper_operator_note { modal_prefill_id = Some _; _ } ->
            Ui_bus.publish_stream_receipt t.bus msg
        | _ -> Ui_bus.publish_snapshot t.bus ~key:snapshot_key msg)
        [@warning "-4"]);
      completed_ok := true);
      match !next_followup with
      | Some (next_epoch, next_req) when not (Atomic.get t.closed) ->
          execute_get t ~epoch:next_epoch next_req
      | Some _ | None -> ())
        with exn ->
          ignore
            (release_inflight ~capture_followup:false
              : (Epoch.t * Cmd.get_request) option);
          raise exn

let is_terminal_setup_login_status status =
  match String.lowercase_ascii (String.trim status) with
  | "complete" | "completed" | "failed" | "canceled" | "cancelled"
  | "interrupted" ->
      true
  | _ -> false

let run_setup_login_stream
    ?(on_output = fun ~text:_ ~auth_url:_ ~device_code:_ -> ())
    ?(on_input_ready = fun ~login_id:_ -> ())
    ~on_interrupted
    ~(publish :
       (Wire_runtime.setup_login_receipt, Msg.http_error) result -> unit)
    ~(stream : on_chunk:(string -> unit) -> (unit, Msg.http_error) result) () :
    unit =
  let sse_decoder = Sse_wire.create_decoder () in
  let terminal_published = ref false in
  let last_login_id = ref None in
  let interrupt error =
    match !last_login_id with
    | Some login_id -> on_interrupted ~login_id error
    | None -> publish (Error error)
  in
  let string_field fields key =
    match List.assoc_opt key fields with
    | Some (`String s) when not (String.equal (String.trim s) "") ->
        Some (String.trim s)
    | Some _ | None -> None
  in
  let first_string_field fields keys =
    List.find_map (fun k -> string_field fields k) keys
  in
  let update_login_id fields =
    match string_field fields "login_id" with
    | Some id -> last_login_id := Some id
    | None -> ()
  in
  let on_chunk raw =
    let frames = Sse_wire.feed_named sse_decoder raw in
    List.iter
      (fun (event, (frame : Sse_wire.frame)) ->
        if !terminal_published then () else
        let ev_name =
          Option.map
            (fun s -> String.lowercase_ascii (String.trim s))
            event
        in
        match ev_name with
        | Some "input_ready" ->
            (match Yojson.Safe.from_string frame.data with
            | `Assoc fields -> update_login_id fields
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
            | `List _ ->
                ()
            | exception Yojson.Json_error _ -> ());
            on_input_ready ~login_id:!last_login_id
        | Some "auth_url" -> (
            match Yojson.Safe.from_string frame.data with
            | `Assoc fields ->
                update_login_id fields;
                let text =
                  Option.value (string_field fields "text") ~default:""
                in
                let auth_url =
                  match first_string_field fields [ "url"; "auth_url" ] with
                  | Some _ as u -> u
                  | None -> Wire_runtime.extract_https_url text
                in
                if (not (String.equal text "")) || Option.is_some auth_url then
                  on_output ~text ~auth_url ~device_code:None
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
            | `List _ ->
                ()
            | exception Yojson.Json_error _ -> ())
        | Some "device_code" -> (
            match Yojson.Safe.from_string frame.data with
            | `Assoc fields ->
                update_login_id fields;
                let text =
                  Option.value (string_field fields "text") ~default:""
                in
                let device_code =
                  match first_string_field fields [ "code"; "device_code" ] with
                  | Some _ as c -> c
                  | None -> Wire_runtime.extract_device_code text
                in
                let auth_url =
                  match
                    first_string_field fields
                      [ "verification_uri"; "url"; "auth_url" ]
                  with
                  | Some _ as u -> u
                  | None -> Wire_runtime.extract_https_url text
                in
                if
                  (not (String.equal text ""))
                  || Option.is_some auth_url
                  || Option.is_some device_code
                then on_output ~text ~auth_url ~device_code
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
            | `List _ ->
                ()
            | exception Yojson.Json_error _ -> ())
        | Some _ | None -> (
            match Yojson.Safe.from_string frame.data with
            | json -> (
                match Wire_runtime.decode_setup_login_receipt json with
                | Ok receipt ->
                    last_login_id := Some receipt.login_id;
                    if is_terminal_setup_login_status receipt.status then (
                      terminal_published := true;
                      publish (Ok receipt))
                    else publish (Ok receipt)
                | Error _ -> (
                    match json with
                    | `Assoc fields -> (
                        update_login_id fields;
                        match
                          ( ev_name
                          , first_string_field fields [ "error"; "message" ] )
                        with
                        | Some "error", Some err_msg ->
                            terminal_published := true;
                            interrupt (Msg.Transport (Health.Other_io err_msg))
                        | (Some _ | None), (Some _ | None) ->
                            (* With ?auth_hints=1 enabled, rely exclusively on
                               server-side auth_url / device_code SSE events so
                               partial PTY/pipe chunks never race ahead with
                               truncated URLs or false-positive device codes. *)
                            let text =
                              Option.value (string_field fields "text")
                                ~default:""
                            in
                            if not (String.equal text "") then
                              on_output ~text ~auth_url:None ~device_code:None)
                    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
                    | `String _ | `List _ ->
                        ()))
            | exception Yojson.Json_error _ -> ()))
      frames
  in
  let stream_res = stream ~on_chunk in
  if not !terminal_published then
    match stream_res, !last_login_id with
    | Error err, _ -> interrupt err
    | Ok (), Some _ -> interrupt (Msg.Transport Health.Stream_eof)
    | Ok (), None ->
        publish (Error (Msg.Decode_error "setup login stream closed without a login receipt"))

let execute_post t ~epoch req =
  let path = Cmd.post_request_path req in
  let body = Cmd.post_request_body req in
  let timeout_sec = timeout_sec_for_post req in
  let post_and_decode t ~path ~body ~decode =
    post_and_decode ~timeout_sec t ~path ~body ~decode
  in
  let post_mcp_and_decode t ~method_ ~tool_name ~path ~body ~decode =
    post_mcp_and_decode ~timeout_sec t ~method_ ~tool_name ~path ~body ~decode
  in
  let post_ack t ~path ~body = post_ack ~timeout_sec t ~path ~body in
  let post_mcp_ack tool_name =
    let ep = Atomic.get t.endpoint in
    let body_str = Yojson.Safe.to_string body in
    let extra_headers =
      [
        ("Accept", "application/json, text/event-stream");
        ("Mcp-Protocol-Version", Wire_work.mcp_protocol_version);
        ("Mcp-Method", "tools/call");
        ("Mcp-Name", tool_name);
        ("X-Masc-Force-Json", "true");
      ]
    in
    match
      Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec ~extra_headers
        ~content_type:"application/json" ~body:body_str ep ~path
    with
    | Error err -> Error (msg_error_of_http err)
    | Ok raw ->
        run_cpu_if_large t ~name:"tui_mcp_ack_decode"
          ~bytes:(String.length raw) (fun () ->
            match Wire_work.decode_mcp_tool_call_ack raw with
            | Ok () -> Ok ()
            | Error detail ->
                Error
                  (Msg.Http_error
                     { status = 400; body = detail; api_error = None })
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception ex ->
                Error (Msg.Decode_error (Printexc.to_string ex)))
  in
  fork_safe t (fun () ->
      let reply_opt =
        match req with
        | Cmd.Post_ask_answer { keeper; ask_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_work_mutation
                 {
                   label = Say.make ~ko:"질문 응답 완료" ~en:"Ask answered";
                   attention_id = Some ("ask:" ^ ask_id);
                   decision_kind = Some Work_store.Decision_ask_answered;
                   target_id = Some ask_id;
                   keeper = Some keeper;
                   result;
                 })
        | Cmd.Post_tool_approval { keeper; approval_id; decision; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_work.decode_tool_approval_outcome
            in
            Some
              (Msg.Reply_tool_approval
                 {
                   keeper;
                   approval_id;
                   attention_id = "tool:" ^ approval_id;
                   decision;
                   result;
                 })
        | Cmd.Post_gate_resolution { id; approved; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              if approved then
                ( Say.make ~ko:"게이트 승인됨" ~en:"Gate approved"
                , Work_store.Decision_gate_approved )
              else
                ( Say.make ~ko:"게이트 거절됨" ~en:"Gate rejected"
                , Work_store.Decision_gate_rejected )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = Some ("gate:" ^ id);
                   decision_kind = Some decision_kind;
                   target_id = Some id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_goal_transition { goal_id; action; _ } ->
            let result = post_ack t ~path ~body in
            let ack_scope, for_modal =
              match action with
              | Wire_work.Drop ->
                  ( Msg.Ack_close_modal_and_refresh
                  , Some (Nav.Goal_drop goal_id) )
              | Wire_work.Request_complete
              | Wire_work.Pause
              | Wire_work.Resume
              | Wire_work.Block
              | Wire_work.Unblock
              | Wire_work.Reopen ->
                  (Msg.Ack_refresh_view, None)
            in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"목표 상태 변경됨" ~en:"Goal transitioned";
                   ack_scope;
                   for_modal;
                   result;
                 })
        | Cmd.Post_goal_confirmation confirm ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_work_mutation
                 {
                   label = Say.make ~ko:"목표 완료 확정됨" ~en:"Goal confirmed";
                   attention_id = Some ("goal:" ^ confirm.goal_id);
                   decision_kind = Some Work_store.Decision_goal_confirmed;
                   target_id = Some confirm.goal_id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_verification_verdict { verification_id; verdict; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              match verdict with
              | Wire_work.Verdict_approve ->
                  ( Say.make ~ko:"검증 승인됨" ~en:"Verification approved"
                  , Work_store.Decision_verification_approved )
              | Wire_work.Verdict_reject _ ->
                  ( Say.make ~ko:"검증 반려됨" ~en:"Verification rejected"
                  , Work_store.Decision_verification_rejected )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = None;
                   decision_kind = Some decision_kind;
                   target_id = Some verification_id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_memory_act { keeper; _ } ->
            let ep = Atomic.get t.endpoint in
            let body_str = Yojson.Safe.to_string body in
            let result =
              match
                Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec
                  ~content_type:"application/json" ~body:body_str ep ~path
              with
              | Ok raw ->
                  decode_raw_json t
                    ~decode:
                      (Wire_knowledge.decode_memory_act_answer ~status_code:200)
                    raw
              | Error (Http_client.Http_error { status; body = err_body; _ } as err)
                -> (
                  match
                    decode_raw_json t
                      ~decode:
                        (Wire_knowledge.decode_memory_act_answer
                           ~status_code:status)
                      err_body
                  with
                  | Ok ans -> Ok ans
                  | Error _ -> Error (msg_error_of_http err))
              | Error
                  (( Http_client.Transport _
                   | Http_client.Workspace_mismatch _
                   | Http_client.Decode_error _ ) as err) ->
                  Error (msg_error_of_http err)
            in
            Some (Msg.Reply_memory_act { keeper; result })
        | Cmd.Post_fusion_launch _ ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_fusion_launch result)
        | Cmd.Post_runtime_assignment { keeper_name; runtime_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_assignment { keeper_name; runtime_id; result })
        | Cmd.Post_runtime_default_route { runtime_id } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_runtime_routing { runtime_id; result })
        | Cmd.Post_runtime_lane_create { lane_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_lane_mutation
                 { lane_id; operation = `Create; result })
        | Cmd.Post_runtime_lane_update { lane_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_lane_mutation
                 { lane_id; operation = `Update; result })
        | Cmd.Post_runtime_lane_delete { lane_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_lane_mutation
                 { lane_id; operation = `Delete; result })
        | Cmd.Post_setup_account_key { integration_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_setup_account_key { integration_id; result })
        | Cmd.Post_setup_login_start _ ->
            let ep = Atomic.get t.endpoint in
            let body_str = Yojson.Safe.to_string body in
            let publish res =
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Http_reply
                   { epoch; reply = Msg.Reply_setup_login_receipt res })
            in
            let on_output ~text ~auth_url ~device_code =
              Ui_bus.publish_stream t.bus
                (Msg.Setup_login_output { epoch; text; auth_url; device_code })
            in
            let on_input_ready ~login_id =
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Setup_login_input_ready { epoch; login_id })
            in
            let on_interrupted ~login_id error =
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Http_reply { epoch; reply = Msg.Reply_setup_login_interrupted { login_id; error } })
            in
            run_setup_login_stream ~on_output ~on_input_ready ~on_interrupted ~publish
              ~stream:(fun ~on_chunk ->
                Http_client.post_stream ~io:t.io ~clock:t.clock
                  ~content_type:"application/json" ~body:body_str
                  ~on_response:(fun ~status:_ ~headers:_ -> ())
                  ~on_chunk ep ~path
                |> Result.map_error msg_error_of_http) ();
            None
        | Cmd.Post_setup_login_input { login_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"로그인 입력 전송됨"
                       ~en:"Login input submitted";
                   ack_scope = Msg.Ack_close_modal;
                   for_modal = Some (Nav.Setup_login_input_form { login_id });
                   result;
                 })
        | Cmd.Post_sandbox_probe _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"샌드박스 프로브 요청됨"
                       ~en:"Sandbox probe requested";
                   ack_scope = Msg.Ack_refresh_view;
                   for_modal = None;
                   result;
                 })
        | Cmd.Post_config_patch patch_req ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_config.decode_patch_response
            in
            Some
              (Msg.Reply_config_patch { dry_run = patch_req.dry_run; result })
        | Cmd.Post_tui_preference _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"TUI 설정 저장됨" ~en:"Preferences saved";
                   ack_scope = Msg.Ack_toast_only;
                   for_modal = None;
                   result;
                 })
        | Cmd.Post_keeper_turn_interrupt { keeper; target } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_fleet.decode_turn_interrupt_response
            in
            Ui_bus.publish_stream_receipt t.bus
              (Msg.Http_reply
                 { epoch; reply = Msg.Reply_turn_interrupt { keeper; target; result } });
            None
        | Cmd.Post_board_create _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"게시글 작성 완료" ~en:"Board post created";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some Nav.Board_new_post;
                   result;
                 })
        | Cmd.Post_board_comment { post_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_board_comment { post_id; result })
        | Cmd.Post_board_vote { post_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_board_vote { post_id; result })
        | Cmd.Post_board_comment_vote { post_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_board_vote { post_id; result })
        | Cmd.Post_artifact_check { id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_knowledge.decode_artifact_check_reply
            in
            Some (Msg.Reply_artifact_check { id; result })
        | Cmd.Post_artifact_share { id; _ } ->
            let ep = Atomic.get t.endpoint in
            let body_str = Yojson.Safe.to_string body in
            let result =
              match
                Http_client.post_raw ~io:t.io ~clock:t.clock ~timeout_sec
                  ~content_type:"application/json" ~body:body_str ep ~path
              with
              | Ok raw ->
                  decode_raw_json t
                    ~decode:Wire_knowledge.decode_artifact_share_response raw
              | Error
                  (Http_client.Http_error { status = 409; body = err_body; _ } as
                   err) -> (
                  match
                    decode_raw_json t
                      ~decode:Wire_knowledge.decode_artifact_share_response
                      err_body
                  with
                  | Ok ans -> Ok ans
                  | Error _ -> Error (msg_error_of_http err))
              | Error
                  (( Http_client.Http_error _
                   | Http_client.Transport _
                   | Http_client.Workspace_mismatch _
                   | Http_client.Decode_error _ ) as err) ->
                  Error (msg_error_of_http err)
            in
            Some (Msg.Reply_artifact_share { id; result })
        | Cmd.Post_schedule_create _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"일정 생성 완료" ~en:"Schedule created";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some Nav.Schedule_form;
                   result;
                 })
        | Cmd.Post_connector_bind _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"커넥터 연결 완료" ~en:"Connector bound";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some Nav.Connector_form;
                   result;
                 })
        | Cmd.Post_connector_unbind _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"커넥터 바인딩 해제됨" ~en:"Connector unbound";
                   ack_scope = Msg.Ack_refresh_view;
                   for_modal = None;
                   result;
                 })
        | Cmd.Post_repo_add _ ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"저장소 추가 완료" ~en:"Repository added";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some Nav.Repo_add_form;
                   result;
                 })
        | Cmd.Post_task_cancel { task_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"작업 취소 완료" ~en:"Task cancelled";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some (Nav.Task_cancel task_id);
                   result;
                 })
        | Cmd.Post_harness_overrule { notes_hash; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"판정 재정의 전송됨"
                       ~en:"Harness overrule submitted";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some (Nav.Harness_overrule notes_hash);
                   result;
                 })
        | Cmd.Post_browser_tabs { client_id } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_browser_tabs_response
            in
            Some (Msg.Reply_browser_tabs { client_id; result })
        | Cmd.Post_oauth_login { keeper; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_keeper_context.decode_oauth_login_result
            in
            Some (Msg.Reply_oauth_login { keeper; result })
        | Cmd.Post_oauth_identity_refresh { keeper; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_oauth_mutation
                 {
                   keeper;
                   label =
                     Say.make ~ko:"OAuth 도구 새로고침 완료"
                       ~en:"OAuth tools refreshed";
                   result;
                 })
        | Cmd.Post_oauth_identity_switch { keeper; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_oauth_mutation
                 {
                   keeper;
                   label =
                     Say.make ~ko:"OAuth 공급자 상태 전환됨"
                       ~en:"OAuth provider toggled";
                   result;
                 })
        | Cmd.Post_oauth_disconnect { keeper; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_oauth_mutation
                 {
                   keeper;
                   label =
                     Say.make ~ko:"OAuth 연결 해제됨" ~en:"OAuth disconnected";
                   result;
                 })
        | Cmd.Post_board_recovery item ->
            let result = post_and_decode t ~path ~body ~decode:(Board_quarantine.recovery_confirmed item) in
            let key = board_snapshot_key ~epoch ~path [item.candidate_id; item.quarantine_id] in
            Ui_bus.publish_snapshot t.bus ~key
              (Msg.Http_reply { epoch; reply = Msg.Reply_board_recovery { item; result } });
            None
        | Cmd.Post_github_token { keeper; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_keeper_context.decode_github_identity
            in
            Some (Msg.Reply_github_token_save { keeper; result })
        | Cmd.Post_task_create _ ->
            let result = post_mcp_ack "masc_add_task" in
            Some
              (Msg.Reply_action_ack
                 {
                   label = Say.make ~ko:"작업 생성 완료" ~en:"Task created";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some Nav.Task_create_form;
                   result;
                 })
        | Cmd.Post_task_transition { task_id; _ } ->
            let result = post_mcp_ack "masc_transition" in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"작업 상태 전환 완료"
                       ~en:"Task transitioned";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some (Nav.Task_transition_form { task_id });
                   result;
                 })
        | Cmd.Post_task_link_goal { task_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"작업-목표 연결 완료"
                       ~en:"Task linked to goal";
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some (Nav.Task_link_goal { task_id });
                   result;
                 })
        | Cmd.Post_goal_upsert { id; _ } ->
            let result = post_mcp_ack "masc_goal_upsert" in
            let label =
              match id with
              | Some _ -> Say.make ~ko:"목표 수정 완료" ~en:"Goal updated"
              | None -> Say.make ~ko:"목표 생성 완료" ~en:"Goal created"
            in
            Some
              (Msg.Reply_action_ack
                 {
                   label;
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal = Some (Nav.Goal_upsert_form id);
                   result;
                 })
        | Cmd.Post_board_pin { pinned; _ } ->
            let result = post_ack t ~path ~body in
            let label =
              if pinned then Say.make ~ko:"게시글 고정됨" ~en:"Post pinned"
              else Say.make ~ko:"게시글 고정 해제됨" ~en:"Post unpinned"
            in
            Some
              (Msg.Reply_action_ack
                 {
                   label;
                   ack_scope = Msg.Ack_refresh_view;
                   for_modal = None;
                   result;
                 })
        | Cmd.Post_board_delete { post_id } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_board_delete { post_id; result })
        | Cmd.Post_keeper_lifecycle
            { keeper; op; req_seq; modal_submission_id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_fleet.decode_keeper_lifecycle_reply
            in
            Some
              (Msg.Reply_keeper_lifecycle
                 { keeper; op; req_seq; modal_submission_id; result })
        | Cmd.Post_keeper_purge { keeper; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_keeper_purge { keeper; result })
        | Cmd.Post_lane_addon_attach { from_modal; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make ~ko:"애드온 연결(Attach) 요청 완료"
                       ~en:"Lane addon attached";
                   ack_scope = (if from_modal then Msg.Ack_close_modal_and_refresh else Msg.Ack_refresh_view);
                   for_modal = (if from_modal then Some Nav.Addon_attach_form else None);
                   result;
                 })
        | Cmd.Post_lane_addon_detach { instance_id } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make
                       ~ko:("애드온 분리 완료: " ^ instance_id)
                       ~en:("Lane addon detached: " ^ instance_id);
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal =
                     Some (Nav.Addon_detach_confirm { instance_id; title = "" });
                   result;
                 })
        | Cmd.Post_lane_addon_action { instance_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_action_ack
                 {
                   label =
                     Say.make
                       ~ko:("애드온 액션 호출됨: " ^ instance_id)
                       ~en:("Lane addon action queued: " ^ instance_id);
                   ack_scope = Msg.Ack_close_modal_and_refresh;
                   for_modal =
                     Some
                       (Nav.Addon_invoke_action
                          { instance_id; action_names = [] });
                   result;
                 })
        | Cmd.Post_lane_addon_ask_answer { declaration_id; ask_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_lane_addon_ask_answer { declaration_id; ask_id; result })
        | Cmd.Post_keeper_control_lifecycle { keeper; action; _ } ->
            let result = post_ack t ~path ~body in
            let label =
              match action with
              | `Boot ->
                  Say.make ~ko:("키퍼 부팅 요청 완료: " ^ keeper)
                    ~en:("Keeper boot applied: " ^ keeper)
              | `Up ->
                  Say.make ~ko:("키퍼 시작(up) 완료: " ^ keeper)
                    ~en:("Keeper up applied: " ^ keeper)
              | `Shutdown ->
                  Say.make ~ko:("키퍼 종료 완료: " ^ keeper)
                    ~en:("Keeper shutdown applied: " ^ keeper)
              | `Reset ->
                  Say.make ~ko:("키퍼 리셋 완료: " ^ keeper)
                    ~en:("Keeper reset applied: " ^ keeper)
            in
            Some
              (Msg.Reply_keeper_control
                 { keeper; label; refresh_roster = true; result })
        | Cmd.Post_keeper_clear { keeper; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_keeper_control
                 {
                   keeper;
                   label =
                     Say.make ~ko:("키퍼 대화 이력 초기화 완료: " ^ keeper)
                       ~en:("Keeper history cleared: " ^ keeper);
                   refresh_roster = true;
                   result;
                 })
        | Cmd.Post_keeper_directive { keeper; directive; _ } ->
            let result = post_ack t ~path ~body in
            let label =
              match directive with
              | Wire_keeper_context.Directive_pause ->
                  Say.make ~ko:("키퍼 일시 정지됨: " ^ keeper)
                    ~en:("Keeper paused: " ^ keeper)
              | Wire_keeper_context.Directive_wakeup ->
                  Say.make ~ko:("키퍼 기상(wakeup) 전송됨: " ^ keeper)
                    ~en:("Keeper wakeup sent: " ^ keeper)
              | Wire_keeper_context.Directive_resume _ ->
                  Say.make ~ko:("키퍼 재개(resume) 완료: " ^ keeper)
                    ~en:("Keeper resumed: " ^ keeper)
            in
            Some
              (Msg.Reply_keeper_control
                 { keeper; label; refresh_roster = true; result })
        | Cmd.Post_keeper_checkpoints { keeper; action = `Preview_purge | `Apply_purge }
          ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_keeper_context.decode_checkpoint_purge_result
            in
            Some (Msg.Reply_keeper_checkpoint_purge { keeper; result })
        | Cmd.Post_keeper_checkpoints { keeper; action = `Delete_history _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_keeper_context.decode_checkpoint_delete_result
            in
            Some (Msg.Reply_keeper_checkpoint_delete { keeper; result })
        | Cmd.Post_discord_reply { request; workspace } ->
            let result = post_and_decode t ~path ~body ~decode:(Wire_discord_reply.decode request) in
            Some (Msg.Reply_discord_reply { request; workspace; result })
        | Cmd.Post_keeper_operator_note { keeper; modal_submission_id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:(Wire_keeper_context.decode_keeper_operator_note ~keeper)
            in
            Some
              (Msg.Reply_keeper_operator_note_saved
                 { keeper; modal_submission_id; result })
        | Cmd.Post_keeper_run_next { keeper; request_id; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_keeper_run_next { keeper; request_id; result })
        | Cmd.Post_gate_resolution_policy { id; approved; remember_rule; _ } ->
            let result = post_ack t ~path ~body in
            let label, decision_kind =
              if approved && remember_rule then
                ( Say.make ~ko:"게이트 승인 + Always-Approve 규칙 저장됨"
                    ~en:"Gate approved + Always-Approve rule saved"
                , Work_store.Decision_gate_approved )
              else if approved then
                ( Say.make ~ko:"게이트 승인됨" ~en:"Gate approved"
                , Work_store.Decision_gate_approved )
              else
                ( Say.make ~ko:"게이트 거절됨" ~en:"Gate rejected"
                , Work_store.Decision_gate_rejected )
            in
            Some
              (Msg.Reply_work_mutation
                 {
                   label;
                   attention_id = Some ("gate:" ^ id);
                   decision_kind = Some decision_kind;
                   target_id = Some id;
                   keeper = None;
                   result;
                 })
        | Cmd.Post_gate_mode { external_lane; mode } ->
            let result = post_ack t ~path ~body in
            let mode_s = Wire_work.gate_mode_to_string mode in
            let label =
              if external_lane then
                Say.make
                  ~ko:("외부 서비스 Gate 모드 변경됨: " ^ mode_s)
                  ~en:("External Gate mode set: " ^ mode_s)
              else
                Say.make
                  ~ko:("워크스페이스 Gate 모드 변경됨: " ^ mode_s)
                  ~en:("Workspace Gate mode set: " ^ mode_s)
            in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label;
                   refresh_gate = true;
                   refresh_modes = false;
                   refresh_late = false;
                   result;
                 })
        | Cmd.Post_gate_rule_delete { id } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label =
                     Say.make ~ko:("Always-Approve 규칙 삭제됨: " ^ id)
                       ~en:("Always-Approve rule deleted: " ^ id);
                   refresh_gate = true;
                   refresh_modes = false;
                   refresh_late = false;
                   result;
                 })
        | Cmd.Post_gate_retry { meta; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label =
                     Say.make ~ko:("Auto-Judge 재시도 요청됨: " ^ meta.id)
                       ~en:("Auto-Judge retry requested: " ^ meta.id);
                   refresh_gate = true;
                   refresh_modes = false;
                   refresh_late = false;
                   result;
                 })
        | Cmd.Post_keeper_tool_approval_mode { keeper; mode } ->
            let result = post_ack t ~path ~body in
            let mode_s = Wire_work.keeper_tool_approval_mode_to_string mode in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label =
                     Say.make
                       ~ko:(Printf.sprintf "키퍼 승인 모드 변경됨: %s=%s" keeper
                              mode_s)
                       ~en:(Printf.sprintf "Keeper approval mode set: %s=%s"
                              keeper mode_s);
                   refresh_gate = false;
                   refresh_modes = true;
                   refresh_late = false;
                   result;
                 })
        | Cmd.Post_hitl_ack_uncertain { consume_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label =
                     Say.make ~ko:("불확실 늦은 승인 확인됨: " ^ consume_id)
                       ~en:("Uncertain late-approval acknowledged: " ^ consume_id);
                   refresh_gate = false;
                   refresh_modes = false;
                   refresh_late = true;
                   result;
                 })
        | Cmd.Post_hitl_late_approval_restore ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_gate_mutation
                 {
                   label =
                     Say.make ~ko:"늦은 승인 저널 복원 완료"
                       ~en:"Late-approval journal restored";
                   refresh_gate = false;
                   refresh_modes = false;
                   refresh_late = true;
                   result;
                 })
        | Cmd.Post_mcp_tools_list _ ->
            if Atomic.compare_and_set t.mcp_tools_list_in_flight false true then
              Fun.protect
                ~finally:(fun () ->
                  Atomic.set t.mcp_tools_list_in_flight false)
                (fun () ->
                  let result =
                    post_mcp_and_decode t ~method_:"tools/list" ~tool_name:None ~path ~body
                      ~decode:Wire_runtime.decode_mcp_tools_list
                  in
                  Some (Msg.Reply_mcp_tools_list result))
            else None
        | Cmd.Post_mcp_tools_call { rpc_id; tool_name; _ } ->
            let result =
              post_mcp_and_decode t ~method_:"tools/call" ~tool_name:(Some tool_name) ~path ~body
                ~decode:(Wire_runtime.decode_mcp_tools_call_result ~tool_name)
            in
            Some (Msg.Reply_mcp_tools_call { rpc_id; tool_name; result })
        | Cmd.Post_skill_editor_read { reference; _ } ->
            let acquired =
              let rec claim () =
                match Atomic.get t.skill_read_in_flight with
                | Some cur when String.equal cur reference -> false
                | (Some _ | None) as cur ->
                    if
                      Atomic.compare_and_set t.skill_read_in_flight cur
                        (Some reference)
                    then true
                    else claim ()
              in
              claim ()
            in
            if acquired then
              Fun.protect
                ~finally:(fun () ->
                  let cur = Atomic.get t.skill_read_in_flight in
                  if Option.equal String.equal cur (Some reference) then
                    ignore
                      (Atomic.compare_and_set t.skill_read_in_flight cur None))
                (fun () ->
                  let result =
                    post_and_decode t ~path ~body
                      ~decode:Wire_runtime.decode_skill_editor_loaded
                  in
                  Some (Msg.Reply_skill_editor_loaded { reference; result }))
            else None
        | Cmd.Post_skill_editor_preview_new _ | Cmd.Post_skill_editor_preview _ ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_skill_editor_preview
            in
            Some (Msg.Reply_skill_editor_preview result)
        | Cmd.Post_skill_editor_create { package_id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_skill_editor_outcome
            in
            Some
              (Msg.Reply_skill_editor_outcome
                 { action = `Create; reference = package_id; result })
        | Cmd.Post_skill_editor_save { reference; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_skill_editor_outcome
            in
            Some
              (Msg.Reply_skill_editor_outcome
                 { action = `Save; reference; result })
        | Cmd.Post_skills_refresh ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_skill_refresh_receipt
            in
            Some (Msg.Reply_skills_refreshed result)
        | Cmd.Post_prompt_override { key; value } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_prompt_override
                 { key; cleared = Option.is_none value; result })
        | Cmd.Post_preset_save { name; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_preset_mutation
                 {
                   label =
                     Say.make ~ko:("프리셋 저장: " ^ name)
                       ~en:("Preset saved: " ^ name);
                   result;
                 })
        | Cmd.Post_preset_create { name; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_preset_mutation
                 {
                   label =
                     Say.make ~ko:("프리셋 생성: " ^ name)
                       ~en:("Preset created: " ^ name);
                   result;
                 })
        | Cmd.Post_preset_restore { name } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_preset_restore_report
            in
            Some (Msg.Reply_preset_restore { name; result })
        | Cmd.Post_preset_delete { name } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_preset_mutation
                 {
                   label =
                     Say.make ~ko:("프리셋 삭제: " ^ name)
                       ~en:("Preset deleted: " ^ name);
                   result;
                 })
        | Cmd.Post_runtime_param_set { param_key; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_param_mutation
                 { param_key; cleared = false; result })
        | Cmd.Post_runtime_param_clear { param_key } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_runtime_param_mutation
                 { param_key; cleared = true; result })
        | Cmd.Post_runtime_routing_action { label; _ } ->
            let result = post_ack t ~path ~body in
            Some (Msg.Reply_runtime_routing_action { label; result })
        | Cmd.Post_runtime_config_raw_preview _ ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_runtime_raw_preview
            in
            Some (Msg.Reply_runtime_config_raw_preview result)
        | Cmd.Post_board_attention_quarantine_recovery
            { keeper; partition_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_board_attention_quarantine_recovery
                 { keeper; partition_id; result })
        | Cmd.Post_lane_addon_declaration_save { file_name; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_addon_declaration_document
            in
            Some
              (Msg.Reply_lane_addon_declaration_saved { file_name; result })
        | Cmd.Post_lane_addon_observe { instance_id } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_lane_addon_mutation
                 {
                   label =
                     Say.make ~ko:("애드온 관측 트리거: " ^ instance_id)
                       ~en:("Addon observe triggered: " ^ instance_id);
                   refresh_addons = true;
                   result;
                 })
        | Cmd.Post_lane_addon_retain { instance_id } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_lane_addon_mutation
                 {
                   label =
                     Say.make ~ko:("애드온 리소스 인수 완료: " ^ instance_id)
                       ~en:("Addon resources retained: " ^ instance_id);
                   refresh_addons = true;
                   result;
                 })
        | Cmd.Post_lane_addon_evidence { instance_id; _ } ->
            let result = post_ack t ~path ~body in
            Some
              (Msg.Reply_lane_addon_mutation
                 {
                   label =
                     Say.make ~ko:("애드온 증거 보존/전달 완료: " ^ instance_id)
                       ~en:("Addon evidence preserved/delivered: " ^ instance_id);
                   refresh_addons = false;
                   result;
                 })
        | Cmd.Post_lane_addon_act _ ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_addon_action_receipt
            in
            Some (Msg.Reply_lane_addon_action_receipt result)
        | Cmd.Post_lane_addon_operator { instance_id; mode; _ } ->
            let mode_label =
              match mode with
              | Wire_runtime.Operator_describe -> "describe"
              | Wire_runtime.Operator_invoke _ -> "invoke"
            in
            let result =
              post_and_decode t ~path ~body ~decode:(fun j -> Ok j)
            in
            Some
              (Msg.Reply_lane_addon_operator
                 { instance_id; mode_label; result })
        | Cmd.Post_browser_scene { client_id; tab_id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_browser_scene_response
            in
            Some (Msg.Reply_browser_scene { client_id; tab_id; result })
        | Cmd.Post_browser_screenshot { client_id; tab_id } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_browser_screenshot_response
            in
            Some (Msg.Reply_browser_screenshot { client_id; tab_id; result })
        | Cmd.Post_browser_command _ ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_browser_op_receipt
            in
            Some
              (Msg.Reply_browser_op_receipt
                 {
                   label =
                     Say.make ~ko:"브라우저 명령 완료" ~en:"Browser command completed";
                   result;
                 })
        | Cmd.Post_browser_interact { action; tab_id; _ } ->
            let result =
              post_and_decode t ~path ~body
                ~decode:Wire_runtime.decode_browser_op_receipt
            in
            Some
              (Msg.Reply_browser_op_receipt
                 {
                   label =
                     Say.make
                       ~ko:(Printf.sprintf "브라우저 인터랙션 완료 (%s · #%d)" action tab_id)
                       ~en:(Printf.sprintf "Browser interact ok (%s · #%d)" action tab_id);
                   result;
                 })
      in
      Option.iter
        (fun reply ->
          Ui_bus.publish_stream_receipt t.bus (Msg.Http_reply { epoch; reply }))
        reply_opt)

let execute_put t ~epoch req =
  let path = Cmd.put_request_path req in
  let body = Cmd.put_request_body req in
  fork_safe t (fun () ->
      match req with
      | Cmd.Put_wiki_page { page; _ } ->
          let ep = Atomic.get t.endpoint in
          let result =
            match
              let body_str = Yojson.Safe.to_string body in
              match
                Http_client.put_raw ~io:t.io ~clock:t.clock
                  ~timeout_sec:standard_timeout_sec
                  ~content_type:"application/json" ~body:body_str ep ~path
              with
              | Error err -> Error (msg_error_of_http err)
              | Ok raw ->
                  decode_raw_json t ~decode:Wire_knowledge.decode_wiki_put_result
                    raw
            with
            | r -> r
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception Io_domain.Closed ->
                Error (Msg.Transport (Health.Other_io "IO domain closed"))
            | exception ex ->
                Error (Msg.Transport (Health.Other_io (Printexc.to_string ex)))
          in
          Ui_bus.publish_stream_receipt t.bus
            (Msg.Http_reply { epoch; reply = Msg.Reply_wiki_put { page; result } }))

let execute_delete t ~epoch req =
  let path = Cmd.delete_request_path req in
  let body = Cmd.delete_request_body req in
  fork_safe t (fun () ->
      match req with
      | Cmd.Delete_skill_editor { reference; _ } ->
          let ep = Atomic.get t.endpoint in
          let result =
            match
              let body_str = Yojson.Safe.to_string body in
              match
                Http_client.delete_raw ~io:t.io ~clock:t.clock
                  ~content_type:"application/json" ~body:body_str ep ~path
              with
              | Error err -> Error (msg_error_of_http err)
              | Ok raw ->
                  decode_raw_json t
                    ~decode:Wire_runtime.decode_skill_editor_outcome raw
            with
            | r -> r
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception Io_domain.Closed ->
                Error (Msg.Transport (Health.Other_io "IO domain closed"))
            | exception ex ->
                Error (Msg.Transport (Health.Other_io (Printexc.to_string ex)))
          in
          Ui_bus.publish_stream_receipt t.bus
            (Msg.Http_reply
               {
                 epoch;
                 reply =
                   Msg.Reply_skill_editor_outcome
                     { action = `Delete; reference; result };
               }))

(* A chat operation keeps running when its stream drops: the server journals
   every event and answers a re-POST of the same request with the events
   past [since_seq] before going live (Server_routes_http_keeper_stream
   serve_accepted_chat). The stream is attached again only while the last
   acceptance reports the operation queued or running and no terminal frame
   arrived; a failure before acceptance stays the submit's own error. An
   acceptance that reports the operation settled is followed by a close
   without a terminal when none was journaled, and the store then settles the
   request from the history. *)
let chat_reattach_backoff_s = [| 1.0; 2.0; 4.0; 8.0; 15.0 |]

let chat_reattach_delay ~(acceptance : Keeper_chat_operation.State_name.t option)
    ~terminal_seen ~reattaches (result : (unit, Msg.http_error) result) =
  match acceptance with
  | None
  | Some
      ( Keeper_chat_operation.State_name.Succeeded | Keeper_chat_operation.State_name.Failed
      | Keeper_chat_operation.State_name.Cancelled ) ->
      None
  | Some (Keeper_chat_operation.State_name.Queued | Keeper_chat_operation.State_name.Running) -> (
      if terminal_seen || reattaches >= Array.length chat_reattach_backoff_s
      then None
      else
        match result with
        | Ok () -> Some chat_reattach_backoff_s.(reattaches)
        | Error err when Msg.http_error_retryable err ->
            Some chat_reattach_backoff_s.(reattaches)
        | Error _ -> None)

(* Only the server process that accepted a request runs its turn, and the
   guard names that process. A reattach goes out only while the endpoint
   still names the same instance: a restarted server is another instance and
   a new epoch, where the store settles the request from the history. Until
   /health names the new instance the guard still names the old one, so a
   reattach can reach the restarted server; it answers 409, which moves the
   epoch the same way. A request sent before /health named an instance is not
   reattached. *)
let chat_reattach_same_instance ~(submitted_to : Http_client.workspace_guard)
    (current : Http_client.workspace_guard) =
  match
    ( submitted_to.Http_client.expected_instance,
      current.Http_client.expected_instance )
  with
  | Some held, Some now -> String.equal held now
  | Some _, None | None, Some _ | None, None -> false

let run_chat_stream_result fn =
  try fn () with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | Io_domain.Closed as ex -> raise ex
  | ex -> Error (Msg.Transport (Health.Other_io (Printexc.to_string ex)))

let run_github_login_stream ~publish_chunk ~publish_done ~stream =
  let sse_decoder = Sse_wire.create_decoder () in
  let final_obs = ref None in
  let final_err = ref None in
  let on_chunk raw =
    let frames = Sse_wire.feed sse_decoder raw in
    List.iter
      (fun (frame : Sse_wire.frame) ->
        match Yojson.Safe.from_string frame.data with
        | json -> (
            let has_key k =
              match json with
              | `Assoc fields -> List.mem_assoc k fields
              | _ -> false
            in
            if has_key "observation" || has_key "stored" then (
              let obs_json =
                match json with
                | `Assoc fields -> (
                    match List.assoc_opt "observation" fields with
                    | Some o -> o
                    | None -> json)
                | _ -> json
              in
              match
                Wire_keeper_context.decode_github_identity obs_json
              with
              | Ok obs -> final_obs := Some obs
              | Error reason ->
                  final_err :=
                    Some ("github identity decode: " ^ reason))
            else if has_key "text" then (
              match Wire_common.optional_nonblank_string json "text" with
              | Ok (Some text) -> publish_chunk text
              | Ok None | Error _ -> ())
            else if has_key "message" || has_key "error" then
              let msg =
                match
                  Wire_common.optional_nonblank_string json "message"
                with
                | Ok (Some m) -> m
                | Ok None | Error _ -> (
                    match
                      Wire_common.optional_nonblank_string json "error"
                    with
                    | Ok (Some m) -> m
                    | Ok None | Error _ -> "github login error")
              in
              final_err := Some msg
            else ())
        | exception Yojson.Json_error _ ->
            if not (String.equal (String.trim frame.data) "") then
              publish_chunk frame.data)
      frames
  in
  let res = run_chat_stream_result (fun () -> stream ~on_chunk) in
  let error =
    match !final_err, res with
    | Some e, _ -> Some e
    | None, Error err -> Some (Msg.http_error_detail err)
    | None, Ok () -> None
  in
  publish_done ~observation:!final_obs ~error

let execute_post_stream t ~epoch req =
  match req with
  | Cmd.Stream_keeper_chat { request; is_btw } ->
      fork_safe t (fun () ->
          (* Written from the stream's chunk callback, read between attempts. *)
          let acceptance = Atomic.make None in
          let terminal_seen = Atomic.make false in
          let last_seq = Atomic.make request.since_seq in
          let note_frame_seq (frame : Sse_wire.frame) =
            match Option.bind frame.id int_of_string_opt with
            | None -> ()
            | Some seq -> (
                match Atomic.get last_seq with
                | Some held when held >= seq -> ()
                | Some _ | None -> Atomic.set last_seq (Some seq))
          in
          let publish_chunk ?(receipt = false) chunk =
            let publish =
              if receipt then Ui_bus.publish_stream_receipt else Ui_bus.publish_stream
            in
            publish t.bus
              (Msg.Chat_stream_chunk
                 {
                   epoch;
                   keeper = request.keeper_name;
                   request_id = request.request_id;
                   is_btw;
                   chunk;
                 })
          in
          let publish_warning reason =
            Ui_bus.publish_stream t.bus
              (Msg.Chat_stream_decode_warning
                 {
                   epoch;
                   keeper = request.keeper_name;
                   request_id = request.request_id;
                   reason;
                 })
          in
          let on_response ~status:_ ~headers:_ = () in
          let on_chunk sse_decoder raw =
            let frames = Sse_wire.feed sse_decoder raw in
            List.iter
              (fun (frame : Sse_wire.frame) ->
                note_frame_seq frame;
                match Yojson.Safe.from_string frame.data with
                | json -> (
                    match Wire_fleet.decode_chat_stream_chunk json with
                    | Ok Wire_fleet.Chunk_ignored -> ()
                    | Ok (Wire_fleet.Chunk_accepted { state; _ } as chunk) ->
                        Atomic.set acceptance (Some state);
                        publish_chunk chunk
                    (* A refused re-POST also arrives as an error frame. It
                       shows as the request's failure, and the history read
                       the store sends with it clears that failure once the
                       reply is persisted. *)
                    | Ok
                        ((Wire_fleet.Chunk_turn_done _ | Wire_fleet.Chunk_error _)
                         as chunk) ->
                        Atomic.set terminal_seen true;
                        publish_chunk ~receipt:true chunk
                    | Ok
                        (( Wire_fleet.Chunk_run_started _
                         | Wire_fleet.Chunk_runtime_attempt_started _
                         | Wire_fleet.Chunk_provider_retry _
                         | Wire_fleet.Chunk_continuation_checkpoint _
                         | Wire_fleet.Chunk_native_tool_progress _
                         | Wire_fleet.Chunk_stream_protocol_error _
                         | Wire_fleet.Chunk_text_delta _
                         | Wire_fleet.Chunk_thinking_delta _
                         | Wire_fleet.Chunk_thinking_snapshot _
                         | Wire_fleet.Chunk_model_content _
                         | Wire_fleet.Chunk_model_response_start _
                         | Wire_fleet.Chunk_model_response_stop _
                         | Wire_fleet.Chunk_tool_start _
                         | Wire_fleet.Chunk_tool_args _
                         | Wire_fleet.Chunk_tool_block_end _
                         | Wire_fleet.Chunk_tool_end _
                         | Wire_fleet.Chunk_tool_quarantined _
                         | Wire_fleet.Chunk_reply_details _ ) as chunk) ->
                        publish_chunk chunk
                    | Error reason -> publish_warning reason)
                | exception Yojson.Json_error msg ->
                    publish_warning ("invalid JSON SSE frame: " ^ msg))
              frames
          in
          let attempt ep ~since_seq =
            let body =
              Wire_fleet.encode_chat_submit_request { request with since_seq }
              |> Yojson.Safe.to_string
            in
            Http_client.post_stream ~io:t.io ~clock:t.clock
              ~header_timeout_sec:chat_stream_header_timeout_sec
              ~content_type:"application/json" ~body ~on_response
              ~on_chunk:(on_chunk (Sse_wire.create_decoder ()))
              ep ~path:Wire_fleet.keeper_chat_stream_path
            |> Result.map_error msg_error_of_http
          in
          let submitted_to = Atomic.get t.endpoint in
          let rec run ep ~reattaches ~since_seq =
            let result = attempt ep ~since_seq in
            match
              chat_reattach_delay ~acceptance:(Atomic.get acceptance)
                ~terminal_seen:(Atomic.get terminal_seen) ~reattaches result
            with
            | None -> result
            | Some delay_s ->
                Eio.Time.sleep t.clock delay_s;
                let current = Atomic.get t.endpoint in
                if
                  Epoch.equal (Atomic.get t.stream_epoch) epoch
                  && chat_reattach_same_instance
                       ~submitted_to:submitted_to.Http_client.guard
                       current.Http_client.guard
                then
                  run current ~reattaches:(reattaches + 1)
                    ~since_seq:(Atomic.get last_seq)
                else result
          in
          let result =
            run_chat_stream_result (fun () ->
                run submitted_to ~reattaches:0 ~since_seq:request.since_seq)
          in
          Ui_bus.publish_stream_receipt t.bus
            (Msg.Chat_stream_done
               {
                 epoch;
                 keeper = request.keeper_name;
                 request_id = request.request_id;
                 is_btw;
                 result;
               }))
  | Cmd.Stream_github_login { keeper } ->
      fork_safe t (fun () ->
          let ep = Atomic.get t.endpoint in
          let path = Wire_keeper_context.github_login_path ~keeper in
          let on_response ~status:_ ~headers:_ = () in
          run_github_login_stream
            ~publish_chunk:(fun text ->
              Ui_bus.publish_stream t.bus
                (Msg.Github_login_chunk { epoch; keeper; text }))
            ~publish_done:(fun ~observation ~error ->
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Github_login_done { epoch; keeper; observation; error }))
            ~stream:(fun ~on_chunk ->
              Http_client.post_stream ~io:t.io ~clock:t.clock
                ~content_type:"application/json" ~body:"{}" ~on_response
                ~on_chunk ep ~path
              |> Result.map_error msg_error_of_http))

let voice_cmd_of_store = function
  | Cmd.Start_ptt { device } -> Voice_runner.Start_ptt { device }
  | Cmd.Stop_ptt -> Voice_runner.Stop_ptt
  | Cmd.Cancel_ptt -> Voice_runner.Cancel_ptt
  | Cmd.Probe_capabilities -> Voice_runner.Probe_capabilities

let url_opener_timeout_s = 3.0

let kill_and_reap_pid pid =
  (match Unix.kill pid Sys.sigkill with
   | () -> ()
   | exception Unix.Unix_error _ -> ());
  let rec reap () =
    match Unix.waitpid [] pid with
    | _, _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
    | exception Unix.Unix_error _ -> ()
  in
  reap ()

let wait_reap_pid ?(timeout_s = url_opener_timeout_s)
    ?(cancelled = fun () -> false) pid =
  let timeout_s =
    if Float.is_finite timeout_s && timeout_s > 0.0 then timeout_s
    else url_opener_timeout_s
  in
  let deadline = Clock.Mono.after_s (Clock.Mono.now ()) timeout_s in
  let rec loop poll_s =
    if cancelled () then begin
      kill_and_reap_pid pid;
      Error "url opener cancelled"
    end
    else
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
          let remaining =
            Clock.Mono.seconds_since deadline ~since:(Clock.Mono.now ())
          in
          if remaining <= 0.0 then begin
            kill_and_reap_pid pid;
            Error (Printf.sprintf "url opener timed out after %.1fs" timeout_s)
          end
          else begin
            Unix.sleepf (Float.min poll_s remaining);
            loop (Float.min 0.025 (poll_s *. 1.5))
          end
      | _, Unix.WEXITED 0 -> Ok ()
      | _, Unix.WEXITED code ->
          Error (Printf.sprintf "url opener exited with status %d" code)
      | _, Unix.WSIGNALED sig_num ->
          Error (Printf.sprintf "url opener stopped by signal %d" sig_num)
      | _, Unix.WSTOPPED sig_num ->
          kill_and_reap_pid pid;
          Error (Printf.sprintf "url opener stopped by signal %d" sig_num)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop poll_s
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Ok ()
      | exception Unix.Unix_error (err, fn, _) ->
          kill_and_reap_pid pid;
          Error (Printf.sprintf "%s: %s" fn (Unix.error_message err))
  in
  try loop 0.005 with
  | Eio.Cancel.Cancelled _ as ex ->
      Eio.Cancel.protect (fun () -> kill_and_reap_pid pid);
      raise ex
  | ex ->
      kill_and_reap_pid pid;
      raise ex

let run_cancellable_systhread ~closed fn =
  let cancel_flag = Atomic.make false in
  let is_cancelled () = Atomic.get cancel_flag || Atomic.get closed in
  let done_p, done_u = Eio.Promise.create () in
  let result_ref = ref None in
  Eio.Fiber.both
    (fun () ->
      try Eio.Promise.await done_p
      with Eio.Cancel.Cancelled _ as ex ->
        Atomic.set cancel_flag true;
        raise ex)
    (fun () ->
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve done_u ())
        (fun () ->
          let res =
            Eio_unix.run_in_systhread (fun () -> fn ~cancelled:is_cancelled)
          in
          result_ref := Some res));
  !result_ref

let open_url_sync ?timeout_s ?(cancelled = fun () -> false) url =
  let opener =
    match Executable_path.absolute_on_path "open" with
    | Some bin -> Some bin
    | None -> Executable_path.absolute_on_path "xdg-open"
  in
  match opener with
  | None -> Error "neither 'open' nor 'xdg-open' found on PATH"
  | Some bin -> (
      match Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 with
      | devnull ->
          Fun.protect
            ~finally:(fun () ->
              try Unix.close devnull with Unix.Unix_error _ -> ())
            (fun () ->
              if cancelled () then Error "url opener cancelled"
              else
                match
                  Unix.create_process bin [| bin; url |] devnull devnull devnull
                with
                | pid -> wait_reap_pid ?timeout_s ~cancelled pid
                | exception Unix.Unix_error (err, fn, _) ->
                    Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))
      | exception Unix.Unix_error (err, fn, _) ->
          Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))

type dos_screen_file = Empty | Live of string | Released

let remove_dos_screen_file path =
  try Sys.remove path with Sys_error _ -> ()

let release_dos_screen_file file =
  match Atomic.exchange file Released with
  | Live path -> remove_dos_screen_file path
  | Empty | Released -> ()

let dos_screen_cancelled = "DOS screen opening cancelled"

let open_dos_screen_file ~file ~cancelled png =
  let cancelled () =
    cancelled ()
    || match Atomic.get file with Released -> true | Empty | Live _ -> false
  in
  if cancelled () then Error dos_screen_cancelled
  else
    try
      let path, channel =
        Filename.open_temp_file ~mode:[ Open_binary ] "masc-dos-" ".png"
      in
      let written =
        Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
            if Atomic.compare_and_set file Empty (Live path) then begin
              output_string channel png;
              flush channel;
              Ok ()
            end else begin
              remove_dos_screen_file path;
              Error dos_screen_cancelled
            end)
      in
      Result.bind written (fun () -> open_url_sync ~cancelled path)
    with Sys_error detail -> Error detail

let open_dos_screen ~sw ~closed ~is_current png =
  let file = Atomic.make Empty in
  let release () = release_dos_screen_file file in
  (* A cancelled fiber may never receive the worker's result. *)
  let hook = Eio.Switch.on_release_cancellable sw release in
  let keep_file = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !keep_file then begin
        Eio.Switch.remove_hook hook;
        release ()
      end)
    (fun () ->
      match
        run_cancellable_systhread ~closed (fun ~cancelled ->
            let cancelled () = cancelled () || not (is_current ()) in
            open_dos_screen_file ~file ~cancelled png)
      with
      | Some (Ok ()) when is_current () ->
          keep_file := true;
          Ok ()
      | Some (Error detail) -> Error detail
      | Some (Ok ()) | None -> Error dos_screen_cancelled)

let read_file_or_empty path =
  match In_channel.open_bin path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () -> Ok (In_channel.input_all ic))
  | exception Sys_error _ -> Ok ""

let run_editor_roundtrip t ~suffix initial =
  ignore (Atomic.fetch_and_add t.wiki_editor_gen 1 : int);
  Atomic.set t.editor_active true;
  Fun.protect
    ~finally:(fun () -> Atomic.set t.editor_active false)
    (fun () ->
      t.editor_handoff.pause_terminal ();
      match
        Eio_unix.run_in_systhread (fun () ->
            Masc_cli_editor.roundtrip
              ~restore:(fun () -> ())
              ~reenter:(fun () -> ())
              ~suffix initial)
      with
      | res ->
          t.editor_handoff.resume_terminal ();
          res
      | exception (Eio.Cancel.Cancelled _ as ex) ->
          Eio.Cancel.protect t.editor_handoff.resume_terminal;
          raise ex
      | exception ex ->
          Eio.Cancel.protect t.editor_handoff.resume_terminal;
          Error (Masc_cli_editor.Form_unreadable (Printexc.to_string ex)))

let run_terminal_program t ~executable args =
  Atomic.set t.editor_active true;
  Fun.protect
    ~finally:(fun () -> Atomic.set t.editor_active false)
    (fun () ->
      t.editor_handoff.pause_terminal ();
      match
        Eio_unix.run_in_systhread (fun () -> Music_launch.run ~executable args)
      with
      | res ->
          t.editor_handoff.resume_terminal ();
          res
      | exception (Eio.Cancel.Cancelled _ as ex) ->
          Eio.Cancel.protect t.editor_handoff.resume_terminal;
          raise ex
      | exception ex ->
          Eio.Cancel.protect t.editor_handoff.resume_terminal;
          Error (Printexc.to_string ex))

(* The score viewer draws with Kitty graphics and needs the measured size of
   one terminal cell; [None] when either is missing. *)
let kitty_cell_pixels () =
  let probe = Probe.current_observation () in
  match
    ( Graphics.protocol_of_probe ~graphics:probe.Probe.graphics
        ~term_program:(Graphics.effective_term_program ~getenv:Sys.getenv_opt),
      probe.Probe.cell_pixels )
  with
  | Graphics.Kitty_protocol, Some (width, height) when width > 0 && height > 0 ->
      Some (width, height)
  | Graphics.Kitty_protocol, (Some _ | None)
  | (Graphics.ITerm2_protocol | Graphics.Unsupported_protocol), _ ->
      None

let execute_terminal_program t program =
  if Atomic.get t.editor_active then ()
  else
    match
      Result.bind (Music_launch.executable ()) (fun executable ->
          Music_launch.with_launch ~cell_pixels:(kitty_cell_pixels ()) program
            (fun launch ->
              run_terminal_program t ~executable
                (Music_launch.args ~base_path:t.cli.base_path launch)))
    with
    | Ok () -> ()
    | Error detail ->
        Ui_bus.publish_stream_receipt t.bus
          (Msg.Http_reply
             {
               epoch = Atomic.get t.stream_epoch;
               reply =
                 Msg.Reply_action_ack
                   {
                     label = Say.make ~ko:"음악 작업대" ~en:"Music workbench";
                     ack_scope = Msg.Ack_toast_only;
                     for_modal = None;
                     result = Error (Msg.Transport (Health.Other_io detail));
                   };
             })

let can_edit_local_toml t =
  is_local_host t.cli.host || Option.is_some (Atomic.get t.owned_server)

let remote_editor_blocked_message =
  "Remote server attached: edit config via Settings (HTTP /api/v1/config/patch), local $EDITOR blocked"

let execute_editor_escape_hatch t target =
  let epoch = Atomic.get t.stream_epoch in
  let ko = Say.equal_lang t.cli.lang Say.Lang_ko in
  let emit_ack ?(ack_scope = Msg.Ack_toast_only) ~label result =
    Ui_bus.publish_stream_receipt t.bus
      (Msg.Http_reply
         {
           epoch;
           reply =
             Msg.Reply_action_ack
               { label; ack_scope; for_modal = None; result };
         })
  in
  match target with
  | Cmd.Edit_runtime_toml | Cmd.Edit_keeper_toml _ ->
      if Atomic.get t.editor_active then ()
      else if not (can_edit_local_toml t) then
        emit_ack
          ~label:
            (Say.make
               ~ko:"원격 서버 연결: 설정 화면(HTTP /api/v1/config/patch)에서 편집하세요 (로컬 $EDITOR 차단)"
               ~en:remote_editor_blocked_message)
          (Error
             (Msg.Transport (Health.Other_io remote_editor_blocked_message)))
      else (
        match editor_file_path ~base_path:t.cli.base_path target with
      | None -> ()
      | Some path -> (
          let initial =
            match read_file_or_empty path with Ok s -> s | Error _ -> ""
          in
          match run_editor_roundtrip t ~suffix:".toml" initial with
          | Error abort ->
              let detail = Masc_cli_editor.abort_detail ~ko abort in
              emit_ack
                ~label:(Say.make ~ko:"편집기 종료" ~en:"Editor aborted")
                (Error (Msg.Transport (Health.Other_io detail)))
          | Ok edited ->
              if String.equal edited initial then
                emit_ack
                  ~label:(Say.make ~ko:"변경 사항 없음" ~en:"No changes made")
                  (Ok ())
              else begin
                Fs_compat.mkdir_p (Filename.dirname path);
                match Fs_compat.save_file_atomic path edited with
                | Ok () ->
                    emit_ack ~ack_scope:Msg.Ack_editor_saved
                      ~label:
                        (Say.make ~ko:"TOML 파일 저장 완료"
                           ~en:"Saved TOML file")
                      (Ok ());
                    let schema_target =
                      match target with
                      | Cmd.Edit_runtime_toml -> Wire_config.Target_runtime
                      | Cmd.Edit_keeper_toml name ->
                          Wire_config.Target_keeper name
                      | Cmd.Edit_wiki_page _ -> Wire_config.Target_runtime
                    in
                    execute_get t ~epoch (Cmd.Get_config_schema schema_target)
                | Error err ->
                    emit_ack
                      ~label:(Say.make ~ko:"TOML 저장 실패" ~en:"Save TOML")
                      (Error (Msg.Transport (Health.Other_io err)))
              end))
  | Cmd.Edit_wiki_page page ->
      if Atomic.get t.editor_active then ()
      else
        let my_gen = Atomic.fetch_and_add t.wiki_editor_gen 1 + 1 in
        ignore (Atomic.exchange t.pending_editor None : (unit -> unit) option);
        let path = Wire_knowledge.wiki_page_path ~page in
        let is_still_current () =
          (not (Atomic.get t.closed))
          && (not (Atomic.get t.editor_active))
          && Atomic.get t.wiki_editor_gen = my_gen
          && Epoch.equal (Atomic.get t.stream_epoch) epoch
        in
        fork_safe t (fun () ->
            match
              fetch_and_decode_get
                ~timeout_sec:(timeout_sec_for_get (Cmd.Get_wiki_page { page }))
                t ~path ~decode:Wire_knowledge.decode_wiki_page_detail
            with
            | Error err ->
                if is_still_current () then
                  emit_ack
                    ~label:(Say.make ~ko:"위키 문서 불러오기" ~en:"Load wiki page")
                    (Error err)
            | Ok detail ->
                if is_still_current () then begin
                  let launch () =
                    if is_still_current () then
                      match
                        run_editor_roundtrip t ~suffix:".md" detail.body_markdown
                      with
                      | Error abort ->
                          let detail_str =
                            Masc_cli_editor.abort_detail ~ko abort
                          in
                          emit_ack
                            ~label:
                              (Say.make ~ko:"편집기 종료" ~en:"Editor aborted")
                            (Error (Msg.Transport (Health.Other_io detail_str)))
                      | Ok edited ->
                          if String.equal edited detail.body_markdown then
                            emit_ack
                              ~label:
                                (Say.make ~ko:"변경 사항 없음"
                                   ~en:"No changes made")
                              (Ok ())
                          else
                            let put_req : Wire_knowledge.wiki_put_request =
                              {
                                expected_revision =
                                  Some detail.frontmatter.revision;
                                expected_sha256 = Some detail.sha256;
                                title = detail.frontmatter.title;
                                summary = detail.frontmatter.summary;
                                source = detail.frontmatter.source;
                                tags = detail.frontmatter.tags;
                                body = edited;
                                note = "edited via $EDITOR";
                              }
                            in
                            execute_put t ~epoch
                              (Cmd.Put_wiki_page { page; request = put_req })
                  in
                  Atomic.set t.pending_editor (Some launch);
                  if not (is_still_current ()) then
                    ignore
                      (Atomic.exchange t.pending_editor None
                        : (unit -> unit) option)
                  else t.on_editor_ready ()
                end)

let stop_owned_server_async owned =
  Eio.Cancel.protect (fun () ->
      Eio_unix.run_in_systhread (fun () ->
          Masc_server_lifecycle.stop owned ~grace_sec:5.0))

let execute_start_local_server t =
  if not t.cli.auto_start then
    Ui_bus.publish_stream_receipt t.bus
      (Msg.Server_start_result (Error "auto-start disabled (--no-auto-start)"))
  else
    fork_safe t (fun () ->
        let discovery =
          Eio_unix.run_in_systhread (fun () ->
              Masc_server_lifecycle.discover_server_binary
                ~tui_exe:Sys.executable_name
                ~file_exists:Executable_path.regular_file_is_executable
                ~path_lookup:Executable_path.absolute_on_path
                ~base_path:t.cli.base_path ~host:t.cli.host ~port:t.cli.port)
        in
        match discovery with
        | Masc_server_lifecycle.Not_found { manual_command } ->
            Ui_bus.publish_stream_receipt t.bus
              (Msg.Server_start_result
                 (Error
                    ("masc binary not found; start manually: " ^ manual_command)))
        | Masc_server_lifecycle.Sibling masc_bin
        | Masc_server_lifecycle.On_path masc_bin -> (
            let start_res =
              Eio_unix.run_in_systhread (fun () ->
                  Masc_server_lifecycle.start ~masc_bin
                    ~base_path:t.cli.base_path ~host:t.cli.host
                    ~port:t.cli.port ~env:(Unix.environment ()))
            in
            match start_res with
            | Error err ->
                Ui_bus.publish_stream_receipt t.bus (Msg.Server_start_result (Error err))
            | Ok owned -> (
                (match Atomic.exchange t.owned_server (Some owned) with
                | Some prev -> stop_owned_server_async prev
                | None -> ());
                let health_ok () =
                  let ep = Atomic.get t.endpoint in
                  match
                    Http_client.get_raw ~io:t.io ~clock:t.clock ~timeout_sec:1.0
                      ep ~path:Wire_common.health_path
                  with
                  | Ok body -> is_health_body_ready body
                  | Error _ -> false
                in
                let child_exit () =
                  Eio_unix.run_in_systhread (fun () ->
                      Masc_server_lifecycle.exit_report owned)
                in
                let sleep () = Eio.Time.sleep t.clock 0.25 in
                match
                  Masc_server_lifecycle.wait_healthy ~health_ok ~child_exit
                    ~attempts:40 ~sleep
                with
                | Masc_server_lifecycle.Ready ->
                    (* Reload admin.token whenever no explicit MASC_TOKEN or
                       bearer_token override was supplied so a freshly minted
                       token replaces any stale pre-boot file token. *)
                    if not t.explicit_bearer_override then begin
                      let fresh_tok =
                        Eio_unix.run_in_systhread (fun () ->
                            load_bearer_token ~base_path:t.cli.base_path ())
                      in
                      let cur = Atomic.get t.endpoint in
                      let next_ep = { cur with bearer_token = fresh_tok } in
                      Atomic.set t.endpoint next_ep;
                      Sse_hub.update_endpoint t.sse_hub next_ep
                    end;
                    Ui_bus.publish_stream_receipt t.bus (Msg.Server_start_result (Ok ()))
                | Masc_server_lifecycle.Server_exited report ->
                    ignore (Atomic.exchange t.owned_server None : _ option);
                    let detail =
                      Printf.sprintf "%s (%s; %s)" report.status
                        (Masc_server_lifecycle.describe_last_line
                           report.last_line)
                        (Masc_server_lifecycle.describe_output report.output)
                    in
                    Ui_bus.publish_stream_receipt t.bus
                      (Msg.Server_start_result (Error detail))
                | Masc_server_lifecycle.Timed_out attempts ->
                    (match Atomic.exchange t.owned_server None with
                    | Some srv -> stop_owned_server_async srv
                    | None -> stop_owned_server_async owned);
                    let detail =
                      Printf.sprintf "server not healthy after %d probes (%s)"
                        attempts
                        (Masc_server_lifecycle.describe_output
                           (Masc_server_lifecycle.startup_output owned))
                    in
                    Ui_bus.publish_stream_receipt t.bus
                      (Msg.Server_start_result (Error detail)))))

let pele_timeout_s = 8.0

let combine_fallback_note primary extra =
  match extra with
  | Some detail when not (String.equal (String.trim detail) "") ->
      primary ^ " · " ^ detail
  | Some _ | None -> primary

let render_memory_diagram_payload ?run_pele ?(theme_preset = Theme.Midnight)
    ~(probe : Probe.observation) ~term_program ~(palette : Palette.t option)
    ~keeper ~kind ~mode ~ko ~tz_offset_sec ~now_unix ~max_width ~chart () :
    Knowledge_store.memory_diagram_payload =
  let render_mermaid () =
    Memory_diagram.render_mermaid_fallback ~tz_offset_sec ~ko ~now:now_unix
      ~max_width ~kind chart
  in
  let render_tree () =
    Memory_diagram.render_tree_lines ~tz_offset_sec ~ko ~now:now_unix
      ~keeper_name:keeper ~max_width chart
    |> List.map (fun (ln : Masc_tui_ui.Memory_tree.line) -> ln.text)
  in
  match mode with
  | Knowledge_store.Diagram_mode_mermaid ->
      let lines, note = render_mermaid () in
      Knowledge_store.Diagram_text { lines; note }
  | Knowledge_store.Diagram_mode_tree ->
      Knowledge_store.Diagram_text { lines = render_tree (); note = None }
  | Knowledge_store.Diagram_mode_auto -> (
      let proto =
        Graphics.protocol_of_probe ~graphics:probe.graphics ~term_program
      in
      let graphics_supported =
        not (Graphics.equal_graphics_protocol proto Graphics.Unsupported_protocol)
      in
      let now_ms =
        if Float.is_finite now_unix && now_unix > 0.0 then
          Int64.of_float (now_unix *. 1000.0)
        else 0L
      in
      let effective_palette =
        match palette with
        | Some p -> p
        | None -> Palette.of_theme (Theme.of_preset theme_preset)
      in
      let source format label render_lineage =
        match chart with
        | Masc_tui_ui.Memory_lineage.Lineage lineage ->
            (format, label, render_lineage lineage)
        | Masc_tui_ui.Memory_lineage.Current_snapshot snapshot ->
            (Pele.Mermaid, "Pele Mermaid",
             Masc_tui_ui.Memory_lineage.snapshot_mermaid ~tz_offset_sec ~ko
               ~now:now_unix snapshot)
      in
      let run_scene scene =
        match run_pele with
        | Some f -> f scene
        | None -> Error "Pele runner unavailable"
      in
      match kind with
      | Knowledge_store.Diagram_pele_card -> (
          let fallback_lines, mermaid_note = render_mermaid () in
          if not graphics_supported then
            let reason =
              if ko then "그래픽 미지원 터미널 · Mermaid 텍스트 폴백"
              else "Terminal graphics unsupported · Mermaid fallback"
            in
            Knowledge_store.Diagram_text
              {
                lines = fallback_lines;
                note = Some (combine_fallback_note reason mermaid_note);
              }
          else
            let format, format_label, input =
              source Pele.Svg "Pele SVG"
                (Masc_tui_ui.Memory_lineage.transition_svg ~tz_offset_sec ~ko
                   ~now:now_unix ~palette:effective_palette)
            in
            let colors = Some (Pele.colors_of_palette effective_palette) in
            let scene =
              Pele.scene ~format ~max_width:1240 ~font_size:15 ~now_ms
                ~colors input
            in
            match run_scene scene with
            | Ok png -> (
                match Memory_diagram.parse_png_dimensions png with
                | Some _ as pixel_size ->
                    Knowledge_store.Diagram_pele_png
                      {
                        png;
                        pixel_size;
                        format_label;
                        fallback_lines;
                      }
                | None ->
                    let reason =
                      if ko then "Pele PNG 헤더 손상 · Mermaid 텍스트 폴백"
                      else "Invalid Pele PNG header · Mermaid fallback"
                    in
                    Knowledge_store.Diagram_text
                      {
                        lines = fallback_lines;
                        note = Some (combine_fallback_note reason mermaid_note);
                      })
            | Error err ->
                let reason =
                  if ko then Printf.sprintf "Pele 불가 (%s) · Mermaid 폴백" err
                  else Printf.sprintf "Pele unavailable (%s) · Mermaid fallback" err
                in
                Knowledge_store.Diagram_text
                  {
                    lines = fallback_lines;
                    note = Some (combine_fallback_note reason mermaid_note);
                  })
      | Knowledge_store.Diagram_formation_tree ->
          let tree_lines = render_tree () in
          if not graphics_supported then
            let reason =
              if ko then "그래픽 미지원 터미널 · 형성 트리 텍스트 폴백"
              else "Terminal graphics unsupported · Formation tree fallback"
            in
            Knowledge_store.Diagram_text { lines = tree_lines; note = Some reason }
          else
            let format, format_label, input =
              source Pele.Graph "Pele Graph"
                (Masc_tui_ui.Memory_lineage.formation_graph_json ~tz_offset_sec ~ko
                   ~now:now_unix ~palette:effective_palette ~keeper_name:keeper)
            in
            let colors = Some (Pele.colors_of_palette effective_palette) in
            let scene =
              Pele.scene ~format ~max_width:1400 ~font_size:14
                ~now_ms ~colors input
            in
            match run_scene scene with
            | Ok png -> (
                match Memory_diagram.parse_png_dimensions png with
                | Some _ as pixel_size ->
                    Knowledge_store.Diagram_pele_png
                      {
                        png;
                        pixel_size;
                        format_label;
                        fallback_lines = tree_lines;
                      }
                | None ->
                    let reason =
                      if ko then
                        "Pele PNG 헤더 손상 · 형성 트리 텍스트 폴백"
                      else "Invalid Pele PNG header · Formation tree fallback"
                    in
                    Knowledge_store.Diagram_text
                      { lines = tree_lines; note = Some reason })
            | Error err ->
                let reason =
                  if ko then
                    Printf.sprintf "Pele 불가 (%s) · 형성 트리 폴백" err
                  else
                    Printf.sprintf "Pele unavailable (%s) · Formation tree fallback"
                      err
                in
                Knowledge_store.Diagram_text
                  { lines = tree_lines; note = Some reason })

let cancel_active_memory_diagram t =
  match Atomic.exchange t.active_memory_diagram_cancel None with
  | Some flag -> Atomic.set flag true
  | None -> ()

let execute_render_memory_diagram t ~epoch ~request_id ~keeper ~event_identity
    ~kind ~mode ~theme_preset ~ko ~tz_offset_sec ~now_unix ~max_width ~chart =
  if Atomic.get t.closed then cancel_active_memory_diagram t
  else
    let cancel_flag = Atomic.make false in
    let slot = Some cancel_flag in
    (match Atomic.exchange t.active_memory_diagram_cancel slot with
    | Some prev -> Atomic.set prev true
    | None -> ());
    let is_cancelled () = Atomic.get cancel_flag || Atomic.get t.closed in
    let probe = Probe.current_observation () in
    let term_program =
      Graphics.effective_term_program ~getenv:Sys.getenv_opt
    in
    let palette =
      match Palette.current () with
      | Some _ as p -> p
      | None -> probe.palette
    in
    fork_safe t (fun () ->
        let release_slot () =
          ignore
            (Atomic.compare_and_set t.active_memory_diagram_cancel slot None
              : bool)
        in
        Fun.protect ~finally:release_slot (fun () ->
            Eio.Fiber.yield ();
            if not (is_cancelled ()) then begin
              let done_p, done_u = Eio.Promise.create () in
              let result_ref = ref None in
              Eio.Fiber.both
                (fun () ->
                  try Eio.Promise.await done_p
                  with Eio.Cancel.Cancelled _ as ex ->
                    Atomic.set cancel_flag true;
                    raise ex)
                (fun () ->
                  Fun.protect
                    ~finally:(fun () -> Eio.Promise.resolve done_u ())
                    (fun () ->
                      let res =
                        match mode with
                        | Knowledge_store.Diagram_mode_mermaid
                        | Knowledge_store.Diagram_mode_tree ->
                            (* Pure-OCaml diagram rendering: run on Worker_pool
                               rather than a Domain 0 systhread so it never
                               contends for Domain 0's runtime lock. *)
                            Worker_pool.submit_cpu t.worker
                              ~name:"tui_memory_diagram_text" (fun () ->
                                if is_cancelled () then
                                  Error "diagram render cancelled"
                                else
                                  try
                                    Ok
                                      (render_memory_diagram_payload
                                         ~theme_preset ~probe ~term_program
                                         ~palette ~keeper ~kind ~mode ~ko
                                         ~tz_offset_sec ~now_unix ~max_width
                                         ~chart ())
                                  with
                                  | Eio.Cancel.Cancelled _ as ex -> raise ex
                                  | ex -> Error (Printexc.to_string ex))
                        | Knowledge_store.Diagram_mode_auto ->
                            Eio_unix.run_in_systhread (fun () ->
                                if is_cancelled () then Error "Pele was cancelled"
                                else
                                  try
                                    let run_pele scene =
                                      if is_cancelled () then
                                        Error "Pele was cancelled"
                                      else
                                        let cache_dir =
                                          Pele.cache_dir ~base_path:t.cli.base_path
                                        in
                                        Pele.render ~cache_dir
                                          ~timeout_s:pele_timeout_s
                                          ~cancelled:is_cancelled scene
                                    in
                                    Ok
                                      (render_memory_diagram_payload ~run_pele
                                         ~theme_preset ~probe ~term_program
                                         ~palette ~keeper ~kind ~mode ~ko
                                         ~tz_offset_sec ~now_unix ~max_width
                                         ~chart ())
                                  with
                                  | Eio.Cancel.Cancelled _ as ex -> raise ex
                                  | ex -> Error (Printexc.to_string ex))
                      in
                      result_ref := Some res));
              if not (is_cancelled ()) then
                match !result_ref with
                | Some result ->
                    Ui_bus.publish_stream_receipt t.bus
                      (Msg.Memory_diagram_rendered
                         {
                           epoch;
                           request_id;
                           keeper;
                           event_identity;
                           kind;
                           mode;
                           result;
                         })
                | None -> ()
            end))

let open_local_export_file ?timeout_s ?cancelled path =
  if not (is_safe_local_export_file path) then
    Error ("refusing to open unsafe or missing export file: " ^ path)
  else open_url_sync ?timeout_s ?cancelled path

(* Run external clipboard tools off the UI domain via a cancellable, bounded
   systhread, capturing any OSC 52 payload instead of writing to [Terminal_out]
   from a background OS thread. Emitting OSC 52 back on the UI-domain fiber
   keeps every write strictly atomic with [Presenter.present_back]. *)
let copy_text_to_clipboard_async t ~in_tmux text =
  let session = Clipboard.copy_session Sys.getenv_opt in
  match
    run_cancellable_systhread ~closed:t.closed (fun ~cancelled ->
        let osc52_raw = ref None in
        let outcome =
          Clipboard.copy_text ~cancelled session
            ~write_osc52:(fun raw -> osc52_raw := Some raw)
            text
        in
        (outcome, !osc52_raw))
  with
  | None -> None
  | Some (outcome, osc52_raw) ->
      (match osc52_raw with
       | Some raw
         when (not (Atomic.get t.closed)) && not (Atomic.get t.editor_active) ->
           let seq = Clipboard.osc52_sequence ~in_tmux raw in
           Terminal_out.write seq;
           Terminal_out.flush ()
       | Some _ | None -> ());
      Some outcome

let publish_clipboard_outcome t ~epoch ~bytes outcome =
  let say = Clipboard.copy_outcome_say outcome in
  let label =
    Say.make
      ~ko:(Printf.sprintf "%s (%dB)" (Say.resolve Say.Lang_ko say) bytes)
      ~en:(Printf.sprintf "%s (%dB)" (Say.resolve Say.Lang_en say) bytes)
  in
  Ui_bus.publish_stream_receipt t.bus
    (Msg.Http_reply
       {
         epoch;
         reply =
           Msg.Reply_action_ack
             {
               label;
               ack_scope = Msg.Ack_toast_only;
               for_modal = None;
               result = Ok ();
             };
       })
let rec execute t = function
  | Cmd.Batch cmds -> List.iter (execute t) cmds
  | Cmd.Http_get { epoch; req } -> execute_get t ~epoch req
  | Cmd.Http_post { epoch; req } -> execute_post t ~epoch req
  | Cmd.Http_put { epoch; req } -> execute_put t ~epoch req
  | Cmd.Http_delete { epoch; req } -> execute_delete t ~epoch req
  | Cmd.Http_post_stream { epoch; req } -> execute_post_stream t ~epoch req
  | Cmd.Sync_streams { epoch; streams } ->
      (* On epoch transitions, fence & stop previous streams while stream_epoch
         still names the old epoch so old-epoch cancellation callbacks cannot
         tag events with the new epoch, and discard any in-flight/queued
         async wiki $EDITOR handoff belonging to the old epoch. *)
      if not (Epoch.equal (Atomic.get t.stream_epoch) epoch) then begin
        ignore (Atomic.fetch_and_add t.wiki_editor_gen 1 : int);
        ignore (Atomic.exchange t.pending_editor None : (unit -> unit) option);
        ignore
          (Sse_hub.sync_streams t.sse_hub [] : (Sse_hub.sync_diff, string) result)
      end;
      Atomic.set t.stream_epoch epoch;
      let specs = List.map stream_spec_of_id streams in
      (match Sse_hub.sync_streams t.sse_hub specs with
      | Ok _ -> ()
      | Error msg ->
          Ui_bus.publish_stream_receipt t.bus
            (Msg.Http_reply
               {
                 epoch;
                 reply =
                   Msg.Reply_action_ack
                     {
                       label =
                         Say.make ~ko:"SSE 스트림 동기화" ~en:"SSE stream sync";
                       ack_scope = Msg.Ack_toast_only;
                       for_modal = None;
                       result = Error (Msg.Transport (Health.Protocol_error msg));
                     };
               }))
  | Cmd.Update_workspace_guard { instance_id; workspace_sha256 } ->
      update_workspace_guard t ~instance_id ~workspace_sha256
  | Cmd.Voice_cmd vc -> Voice_runner.dispatch t.voice_runner (voice_cmd_of_store vc)
  | Cmd.Copy_clipboard text ->
      let epoch = Atomic.get t.stream_epoch in
      fork_safe t (fun () ->
          let in_tmux = Option.is_some (Sys.getenv_opt "TMUX") in
          match copy_text_to_clipboard_async t ~in_tmux text with
          | Some outcome ->
              publish_clipboard_outcome t ~epoch ~bytes:(String.length text)
                outcome
          | None -> ())
  | Cmd.Render_memory_diagram
      {
        epoch;
        request_id;
        keeper;
        event_identity;
        kind;
        mode;
        theme_preset;
        ko;
        tz_offset_sec;
        now_unix;
        max_width;
        chart;
      } ->
      execute_render_memory_diagram t ~epoch ~request_id ~keeper ~event_identity
        ~kind ~mode ~theme_preset ~ko ~tz_offset_sec ~now_unix ~max_width ~chart
  | Cmd.Cancel_memory_diagram -> cancel_active_memory_diagram t
  | Cmd.Fetch_artifact_and_copy { epoch; id; revision } ->
      fork_safe t (fun () ->
          let path = Wire_knowledge.published_artifact_detail_path ~id ?revision () in
          match
            fetch_and_decode_get ~timeout_sec:heavy_timeout_sec t ~path
              ~decode:Wire_knowledge.decode_published_artifact_detail
          with
          | Ok detail ->
              Ui_bus.publish_snapshot t.bus ~key:(Key_get path)
                (Msg.Http_reply
                   {
                     epoch;
                     reply = Msg.Reply_artifact_detail { id; result = Ok detail };
                   });
              let in_tmux = Option.is_some (Sys.getenv_opt "TMUX") in
              (match
                 copy_text_to_clipboard_async t ~in_tmux detail.content
               with
               | Some outcome ->
                   publish_clipboard_outcome t ~epoch
                     ~bytes:(String.length detail.content) outcome
               | None -> ())
          | Error err ->
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Http_reply
                   {
                     epoch;
                     reply =
                       Msg.Reply_action_ack
                         {
                           label =
                             Say.make ~ko:"아티팩트 본문 복사"
                               ~en:"Copy artifact body";
                           ack_scope = Msg.Ack_toast_only;
                           for_modal = None;
                           result = Error err;
                         };
                   }))
  | Cmd.Export_artifact
      { epoch; id; revision; filename_stem; ext; content_opt; open_after } ->
      fork_safe t (fun () ->
          let content_res =
            match content_opt with
            | Some body -> Ok body
            | None -> (
                let path =
                  Wire_knowledge.published_artifact_detail_path ~id ?revision ()
                in
                match
                  fetch_and_decode_get ~timeout_sec:heavy_timeout_sec t ~path
                    ~decode:Wire_knowledge.decode_published_artifact_detail
                with
                | Ok detail ->
                    Ui_bus.publish_snapshot t.bus ~key:(Key_get path)
                      (Msg.Http_reply
                         {
                           epoch;
                           reply =
                             Msg.Reply_artifact_detail { id; result = Ok detail };
                         });
                    Ok detail.content
                | Error err -> Error err)
          in
          match content_res with
          | Error err ->
              Ui_bus.publish_stream_receipt t.bus
                (Msg.Http_reply
                   {
                     epoch;
                     reply =
                       Msg.Reply_action_ack
                         {
                           label =
                             Say.make ~ko:"아티팩트 내보내기"
                               ~en:"Export artifact";
                           ack_scope = Msg.Ack_toast_only;
                           for_modal = None;
                           result = Error err;
                         };
                   })
          | Ok content -> (
              let save_res =
                let primary_dir =
                  resolve_artifact_export_dir ~base_path:t.cli.base_path ()
                in
                let fallback_dir =
                  Filename.concat
                    (Filename.concat t.cli.base_path Common.masc_dirname)
                    "exports"
                in
                let fname =
                  build_artifact_export_filename ~filename_stem ~id ~ext
                in
                let try_write_in dir =
                  try
                    Fs_compat.mkdir_p dir;
                    let full_path = Filename.concat dir fname in
                    Eio_unix.run_in_systhread (fun () ->
                        try
                          match Fs_compat.save_file_atomic full_path content with
                          | Ok () -> Ok full_path
                          | Error detail -> Error detail
                        with
                        | Sys_error detail -> Error detail
                        | Unix.Unix_error (code, fn, arg) ->
                            Error
                              (Printf.sprintf "%s(%s): %s" fn arg
                                 (Unix.error_message code)))
                  with
                  | Sys_error detail -> Error detail
                  | Unix.Unix_error (code, fn, arg) ->
                      Error
                        (Printf.sprintf "%s(%s): %s" fn arg
                           (Unix.error_message code))
                in
                let write_res =
                  match try_write_in primary_dir with
                  | Ok _ as ok -> ok
                  | Error _ when not (String.equal primary_dir fallback_dir) ->
                      try_write_in fallback_dir
                  | Error _ as err -> err
                in
                match write_res with
                | Ok full_path ->
                    if open_after then
                      match
                        run_cancellable_systhread ~closed:t.closed
                          (fun ~cancelled ->
                            open_local_export_file ~cancelled full_path)
                      with
                      | Some (Ok ()) -> Ok full_path
                      | Some (Error open_err) ->
                          Error
                            (Printf.sprintf "saved %s (open failed: %s)"
                               full_path open_err)
                      | None ->
                          Error
                            (Printf.sprintf "saved %s (open cancelled)"
                               full_path)
                    else Ok full_path
                | Error detail -> Error detail
              in
              match save_res with
              | Ok saved_path ->
                  let label =
                    if open_after then
                      Say.make
                        ~ko:("저장 및 열기: " ^ saved_path)
                        ~en:("Exported & opened: " ^ saved_path)
                    else
                      Say.make
                        ~ko:("저장됨: " ^ saved_path)
                        ~en:("Exported: " ^ saved_path)
                  in
                  Ui_bus.publish_stream_receipt t.bus
                    (Msg.Http_reply
                       {
                         epoch;
                         reply =
                           Msg.Reply_action_ack
                             {
                               label;
                               ack_scope = Msg.Ack_toast_only;
                               for_modal = None;
                               result = Ok ();
                             };
                       })
              | Error detail ->
                  Ui_bus.publish_stream_receipt t.bus
                    (Msg.Http_reply
                       {
                         epoch;
                         reply =
                           Msg.Reply_action_ack
                             {
                               label =
                                 Say.make ~ko:"아티팩트 내보내기"
                                   ~en:"Export artifact";
                               ack_scope = Msg.Ack_toast_only;
                               for_modal = None;
                               result =
                                 Error (Msg.Transport (Health.Other_io detail));
                             };
                       })))
  | Cmd.Open_dos_screen { epoch } ->
      let is_current () =
        not (Atomic.get t.closed)
        && Epoch.equal (Atomic.get t.stream_epoch) epoch
      in
      let endpoint = current_endpoint t in
      fork_safe t (fun () ->
          if is_current () then begin
            let response =
              Http_client.get_raw ~io:t.io ~clock:t.clock endpoint
                ~path:"/api/v1/play/screen.png"
            in
            if is_current () then begin
              let result =
                match response with
                | Error err -> Error (msg_error_of_http err)
                | Ok png
                  when not (String.starts_with ~prefix:"\137PNG\r\n\026\n" png) ->
                    Error (Msg.Decode_error "DOS screen response is not PNG")
                | Ok png ->
                    open_dos_screen ~sw:t.sw ~closed:t.closed ~is_current png
                    |> Result.map_error (fun detail ->
                           Msg.Transport (Health.Other_io detail))
              in
              if is_current () then
                Ui_bus.publish_stream_receipt t.bus
                  (Msg.Http_reply
                     {
                       epoch;
                       reply =
                         Msg.Reply_action_ack
                           {
                             label =
                               Say.make ~ko:"DOS 화면 열기" ~en:"Open DOS screen";
                             ack_scope = Msg.Ack_toast_only;
                             for_modal = None;
                             result;
                           };
                     })
            end
          end)
  | Cmd.Open_external_url url ->
      if is_safe_external_url url then
        fork_safe t (fun () ->
            match
              run_cancellable_systhread ~closed:t.closed (fun ~cancelled ->
                  open_url_sync ~cancelled url)
            with
            | Some (Ok ()) | None -> ()
            | Some (Error detail) ->
                Ui_bus.publish_stream_receipt t.bus
                  (Msg.Http_reply
                     {
                       epoch = Atomic.get t.stream_epoch;
                       reply =
                         Msg.Reply_action_ack
                           {
                             label =
                               Say.make ~ko:"외부 링크 열기"
                                 ~en:"Open external URL";
                             ack_scope = Msg.Ack_toast_only;
                             for_modal = None;
                             result =
                               Error (Msg.Transport (Health.Other_io detail));
                           };
                     }))
  | Cmd.Open_editor_escape_hatch target -> execute_editor_escape_hatch t target
  | Cmd.Open_terminal_program program -> execute_terminal_program t program
  | Cmd.Start_local_server -> execute_start_local_server t
  | Cmd.Restart_tui -> t.on_restart ()
  | Cmd.Quit reason -> t.on_quit reason

let execute_all t cmds = List.iter (execute t) (Cmd.flatten cmds)

let shutdown ?(preserve_owned_server = false) t =
  Atomic.set t.closed true;
  ignore (Atomic.fetch_and_add t.wiki_editor_gen 1 : int);
  ignore (Atomic.exchange t.pending_editor None : (unit -> unit) option);
  cancel_active_memory_diagram t;
  Voice_runner.stop t.voice_runner;
  Sse_hub.shutdown t.sse_hub;
  if not preserve_owned_server then
    match Atomic.exchange t.owned_server None with
    | Some owned -> stop_owned_server_async owned
    | None -> ()
