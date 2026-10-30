module Types = Masc_domain

open Masc
open Test_operator_control_support

let test_usage_does_not_create_context_snapshot () =
  let model_budget = 256_000 in
  let base =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String "ctx-ratio-demo");
            ("trace_id", `String "trace-ctx-ratio-demo");
          ])
    with
    | Ok meta -> meta
    | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
  in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              last_input_tokens = 790_360;
              last_output_tokens = 17;
              last_total_tokens = 790_377;
              last_usage_reported_at = Some 1_700_000_000.0;
            };
        };
    }
  in
  let json =
    `Assoc
      (Keeper_context_observation_projection.missing_context_fields ())
  in
  Alcotest.(check bool)
    "fixture is deliberately above the assigned model budget"
    true
    (meta.runtime.usage.last_input_tokens > model_budget);
  Alcotest.(check bool)
    "usage is not context ratio" true
    Yojson.Safe.Util.(json |> member "context_ratio" = `Null);
  Alcotest.(check bool)
    "usage is not context tokens" true
    Yojson.Safe.Util.(json |> member "context_tokens" = `Null);
  Alcotest.(check bool)
    "model budget is not an observed context max" true
    Yojson.Safe.Util.(json |> member "context_max" = `Null);
  Alcotest.(check bool)
    "fallback source is not fabricated" true
    Yojson.Safe.Util.(json |> member "context_source" = `Null);
  Alcotest.(check string)
    "missing measurement kind" "not_observed"
    Yojson.Safe.Util.(
      json
      |> member "context_metrics_unavailable"
      |> member "kind"
      |> to_string);
  Alcotest.(check string)
    "missing measurement reason" "context_measurement_missing"
    Yojson.Safe.Util.(
      json
      |> member "context_metrics_unavailable"
      |> member "reason"
      |> to_string)
  ;
  let usage_json =
    Keeper_context_observation_projection.last_turn_usage_json_of_meta meta
  in
  Alcotest.(check int) "usage JSON input retained" 790_360
    Yojson.Safe.Util.(usage_json |> member "input_tokens" |> to_int);
  Alcotest.(check int) "usage JSON output retained" 17
    Yojson.Safe.Util.(usage_json |> member "output_tokens" |> to_int);
  Alcotest.(check int) "usage JSON total retained" 790_377
    Yojson.Safe.Util.(usage_json |> member "total_tokens" |> to_int);
  Alcotest.(check string) "usage JSON source is explicit"
    "keeper_runtime_usage"
    Yojson.Safe.Util.(usage_json |> member "source" |> to_string);
  Alcotest.(check string) "usage JSON keeps its own observation timestamp"
    "2023-11-14T22:13:20Z"
    Yojson.Safe.Util.(usage_json |> member "observed_at" |> to_string);
  let cumulative_sample : Keeper_usage_resolution.sample =
    { input_tokens = 1_200
    ; output_tokens = 30
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = Some 0.25
    }
  in
  let cumulative_resolution, _ =
    Keeper_usage_resolution.resolve
      ~cursor:None
      ~basis:
        (Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Keeper_usage_resolution.Fresh
           })
      ~observation:(Some cumulative_sample)
      ~observed_at:1_700_000_001.0
  in
  let cumulative_meta =
    { meta with
      runtime =
        { meta.runtime with
          last_usage_resolution = Some cumulative_resolution
        }
    }
  in
  let cumulative_json =
    Keeper_context_observation_projection.last_turn_usage_json_of_meta
      cumulative_meta
  in
  Alcotest.(check int)
    "cumulative provider exposes the resolved turn delta"
    1_200
    Yojson.Safe.Util.(cumulative_json |> member "input_tokens" |> to_int);
  Alcotest.(check int)
    "public total keeps the legacy shape"
    1_230
    Yojson.Safe.Util.(cumulative_json |> member "total_tokens" |> to_int);
  Alcotest.(check string)
    "resolved usage timestamp remains ISO-8601"
    "2023-11-14T22:13:21Z"
    Yojson.Safe.Util.(cumulative_json |> member "observed_at" |> to_string);
  Alcotest.(check string)
    "typed resolution is embedded separately"
    "conversation_counter"
    Yojson.Safe.Util.(
      cumulative_json
      |> member "usage_resolution"
      |> member "basis"
      |> member "kind"
      |> to_string)

let init_runtime_default_for_snapshot base_dir =
  let path = Filename.concat base_dir "runtime.toml" in
  let content =
    {|
version = 1

[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
max-concurrent = 1
|}
  in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error err -> Alcotest.failf "Runtime.init_default failed: %s" err

let test_snapshot_keeps_context_unobserved_and_usage_separate () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      init_runtime_default_for_snapshot base_dir;
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      (* masc_keeper_up refuses a sandbox_image with nothing promoted on this
         host; the keeper below names "base". *)
      Masc_test_deps.write_sandbox_image_catalog ~base_path:base_dir
        [ "base", Masc_test_deps.live_sandbox_image_tag ];
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
      Masc_test_deps.with_server_root_switch ~sw @@ fun () ->
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "owner";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let keeper_name = "ctx-truth" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("sandbox_profile", `String "docker");
                ("sandbox_image", `String "base");
                ("name", `String keeper_name);
                ("instructions", `String "Prefer metrics context truth");
                ("activation_mode", `String "on_demand");
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      ignore
        (Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           keeper_name);
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let updated_meta =
        {
          meta with
          runtime =
            {
              meta.runtime with
              usage =
                {
                  meta.runtime.usage with
                  last_input_tokens = 6_637_033;
                  last_total_tokens = 6_670_646;
                  last_usage_reported_at = Some 1_700_000_000.0;
                };
            };
        }
      in
      (match
         Keeper_owner_registry.commit_turn_runtime
           ~base_path:config.base_path
           ~keeper_name
           ~before:meta
           ~after:updated_meta
       with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.command_error_to_string error));
      Operator_control.invalidate_snapshot_cache ();
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      let keeper =
        match
          Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string) = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected keeper in snapshot"
      in
      Alcotest.(check bool) "keeper row omits dead agent projection" false
        (match keeper with
         | `Assoc fields -> List.mem_assoc "agent" fields
         | _ -> true);
      Alcotest.(check bool) "keeper row carries current_task_id, null when none is held" true
        (match keeper with
         | `Assoc fields ->
           List.assoc_opt "current_task_id" fields = Some `Null
         | _ -> false);
      Alcotest.(check bool) "unowned ratio is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_ratio" = `Null);
      Alcotest.(check bool) "unowned tokens are ignored" true
        Yojson.Safe.Util.(keeper |> member "context_tokens" = `Null);
      Alcotest.(check bool) "unowned max is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_max" = `Null);
      Alcotest.(check bool) "unowned source is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_source" = `Null);
      Alcotest.(check (float 0.1)) "summary keeper cadence is projected" 300.0
        Yojson.Safe.Util.(
          keeper |> member "keeper_keepalive_interval_s" |> to_float);
      Alcotest.(check (float 0.1)) "summary snapshot cadence is projected" 300.0
        Yojson.Safe.Util.(
          keeper |> member "keeper_snapshot_interval_s" |> to_float);
      Alcotest.(check string) "missing owner remains explicit" "not_observed"
        Yojson.Safe.Util.(
          keeper
          |> member "context_metrics_unavailable"
          |> member "kind"
          |> to_string);
      Alcotest.(check int) "live last-turn usage remains separate" 6_637_033
        Yojson.Safe.Util.(
          keeper
          |> member "last_turn_usage"
          |> member "input_tokens"
          |> to_int);
      Keeper_registry.For_testing.clear ();
      Operator_control.invalidate_snapshot_cache ();
      let persisted_json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      let persisted_keeper =
        match
          Yojson.Safe.Util.(
            persisted_json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string)
                 = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected persisted keeper in snapshot"
      in
      Alcotest.(check bool)
        "persisted token counters do not imply an observed last-turn usage"
        true
        Yojson.Safe.Util.(persisted_keeper |> member "last_turn_usage" = `Null))

let health_projection_meta ~total_turns =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "health-projection"
        ; "trace_id", `String "trace-health-projection"
        ; "total_turns", `Int total_turns
        ; "activation_mode", `String "autonomous"
        ])
  with
  | Ok meta -> meta
  | Error error -> Alcotest.fail error

let health_projection_diagnostic ~total_turns ~phase =
  Keeper_status_runtime.keeper_diagnostic_json
    ~meta:(health_projection_meta ~total_turns)
    ~phase
    ~history_items:[]
    ~now_ts:(Unix.gettimeofday ())

(* Health is a projection of the phase and the turn history: a phase that
   admits no turn reads offline, Running without a turn yet reads idle,
   Running with a turn behind it reads healthy, and Failing reads failing
   whatever its history. Nothing on disk is read for it. *)
let test_diagnostic_health_is_a_projection_of_phase_and_turns () =
  let open Yojson.Safe.Util in
  let health ~total_turns ~phase =
    health_projection_diagnostic ~total_turns ~phase
    |> member "health_state"
    |> to_string
  in
  Alcotest.(check string) "a keeper with no registry entry reads offline"
    "offline"
    (health ~total_turns:1 ~phase:None);
  Alcotest.(check string) "running without a turn yet reads idle" "idle"
    (health ~total_turns:0 ~phase:(Some Keeper_state_machine.Running));
  Alcotest.(check string) "running with a turn behind it reads healthy"
    "healthy"
    (health ~total_turns:1 ~phase:(Some Keeper_state_machine.Running));
  List.iter
    (fun total_turns ->
      Alcotest.(check string)
        (Printf.sprintf "failing with %d turns behind it reads failing"
           total_turns)
        "failing"
        (health ~total_turns ~phase:(Some Keeper_state_machine.Failing)))
    [ 0; 1 ];
  (* Every phase, so the enumeration in the projection and the state
     machine's own [can_execute_turn] cannot drift apart: offline is exactly
     the phases that admit no turn, and the published [keepalive_running]
     is that same answer. *)
  List.iter
    (fun phase ->
      let label = Keeper_state_machine.phase_to_string phase in
      let admits_turn = Keeper_state_machine.can_execute_turn phase in
      let diagnostic =
        health_projection_diagnostic ~total_turns:1 ~phase:(Some phase)
      in
      Alcotest.(check bool)
        (label ^ " reads offline exactly when it admits no turn")
        (not admits_turn)
        (String.equal
           (diagnostic |> member "health_state" |> to_string)
           "offline");
      Alcotest.(check bool)
        (label ^ " publishes keepalive_running as the phase answers it")
        admits_turn
        (diagnostic |> member "keepalive_running" |> to_bool))
    Keeper_state_machine.all_phases

(* A failing keeper is told to read its error first: the Failing phase says its
   turns fail, not that a restart fixes them. Its restart stays available,
   because the operator's keeper_recover action skips only keepers whose
   diagnostic is not [recoverable]. The same keeper in Running is the contrast:
   it is sent a message and nothing about its history makes it recoverable. *)
let test_failing_keeper_is_probed_and_stays_recoverable () =
  let open Yojson.Safe.Util in
  let failing =
    health_projection_diagnostic ~total_turns:4
      ~phase:(Some Keeper_state_machine.Failing)
  in
  let running =
    health_projection_diagnostic ~total_turns:4
      ~phase:(Some Keeper_state_machine.Running)
  in
  Alcotest.(check string) "a failing keeper's next action is probe"
    "probe"
    (failing |> member "next_action_path" |> to_string);
  Alcotest.(check bool) "a failing keeper is still recoverable" true
    (failing |> member "recoverable" |> to_bool);
  Alcotest.(check bool) "its keepalive is still running" true
    (failing |> member "keepalive_running" |> to_bool);
  Alcotest.(check string) "its status word stays active: it is still turning"
    "active"
    (Keeper_status_runtime.keeper_surface_status ~diagnostic:failing);
  Alcotest.(check string) "the same keeper in Running is sent a message"
    "direct_message"
    (running |> member "next_action_path" |> to_string);
  Alcotest.(check bool) "and is not recoverable" false
    (running |> member "recoverable" |> to_bool)

let test_snapshot_has_expected_sections () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Workspace.add_task config ~title:"operator backlog" ~priority:2 ~description:"");
      ignore (Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let root = Yojson.Safe.Util.member "workspace" json in
      Alcotest.(check bool) "root block present" true
        (root <> `Null);
      Alcotest.(check bool) "root initialized" true
        Yojson.Safe.Util.(root |> member "initialized" |> to_bool);
      Alcotest.(check bool) "project nonempty" true
        (String.trim Yojson.Safe.Util.(root |> member "project" |> to_string) <> "");
      Alcotest.(check bool) "sessions absent" true
        (Yojson.Safe.Util.member "sessions" json = `Null);
      Alcotest.(check bool) "keepers present" true
        (Yojson.Safe.Util.member "keepers" json <> `Null);
      Alcotest.(check bool) "recent_messages present" true
        (Yojson.Safe.Util.member "recent_messages" json <> `Null);
      Alcotest.(check bool) "pending-confirm envelope present" true
        (Yojson.Safe.Util.member "pending_confirm_envelope" json <> `Null);
      Alcotest.(check bool) "trace_id present" true
        (json |> Yojson.Safe.Util.member "trace_id" |> Yojson.Safe.Util.to_string
       <> "");
      Alcotest.(check string) "server profile" "operator_remote_v1"
        (json |> Yojson.Safe.Util.member "server_profile"
         |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "attention summary present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null);
      Alcotest.(check string) "judgment owner" "fallback_read_model"
        Yojson.Safe.Util.(json |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "no authoritative judgment" false
        Yojson.Safe.Util.(json |> member "authoritative_judgment_available" |> to_bool);
      let inference = Yojson.Safe.Util.member "inference_inflight" json in
      Alcotest.(check bool) "inference observation present" true
        (inference <> `Null);
      Alcotest.(check string) "inference boundary owner" "agent_core_runtime"
        Yojson.Safe.Util.(inference |> member "boundary_owner" |> to_string);
      Alcotest.(check int) "no inference active" 0
        Yojson.Safe.Util.(inference |> member "active" |> to_int);
      Alcotest.(check bool) "no MASC-owned inference capacity" true
        (Yojson.Safe.Util.member "max_concurrent" inference = `Null);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
        | `List _ -> true
        | _ -> false))

let test_snapshot_summary_view_excludes_retired_command_plane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      Alcotest.(check bool) "command_plane field absent" true
        (not (List.mem_assoc "command_plane"
           Yojson.Safe.Util.(to_assoc json)));
      Alcotest.(check bool) "swarm_status omitted" true
        (Yojson.Safe.Util.member "swarm_status" json = `Null);
      Alcotest.(check bool) "attention summary still present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary still present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null))

let test_snapshot_lightweight_summary_omits_heavy_activity () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:true
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let keepers =
        Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
      in
      List.iter
        (fun keeper ->
          Alcotest.(check int) "lightweight recent_activity omitted" 0
            Yojson.Safe.Util.(keeper |> member "recent_activity" |> to_list |> List.length))
        keepers;
      Alcotest.(check int) "lightweight recent_messages omitted" 0
        Yojson.Safe.Util.(json |> member "recent_messages" |> to_list |> List.length);
      Alcotest.(check int) "lightweight recent_actions omitted" 0
        Yojson.Safe.Util.(json |> member "recent_actions" |> to_list |> List.length))

(* Snapshot cache behavioural tests live in
   [test_operator_control_snapshot_cache.ml]; they drive the public
   [Operator_control_snapshot_cache] API directly rather than the removed
   internal cache types. *)

let test_digest_workspace_includes_tool_host_failure_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      Dashboard_tool_host_events.record ~fs:() config ~reported_by:"codex"
        {
          Dashboard_tool_host_events.agent_name = "codex";
          client_name = "codex";
          tool_name = "masc_keeper_msg";
          transport = "mcp_http";
          phase = Some "tools/call";
          cause = Failure_envelope.Tool_host_timeout;
          message = "timed out awaiting tools/call after 90s";
          request_id = Some "opsd-toolhost-1";
          session_id = Some "sess-toolhost-1";
          trace_id = Some "trace-toolhost-1";
          timeout_ms = Some 90000;
        };
      let digest =
        match Operator_control.digest_json ~actor:"dashboard"
                (operator_ctx env sw config "dashboard")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let attention_items =
        Yojson.Safe.Util.(digest |> member "attention_items" |> to_list)
      in
      let tool_host_attention =
        List.find_opt
          (fun item ->
            Yojson.Safe.Util.(item |> member "kind" |> to_string)
            = "tool_host_timeout"
            && Yojson.Safe.Util.
                 (item |> member "evidence" |> member "failure_envelope"
                |> member "evidence_ref" |> member "request_id" |> to_string)
               = "opsd-toolhost-1")
          attention_items
      in
      let item =
        match tool_host_attention with
        | Some item -> item
        | None -> Alcotest.fail "expected tool host attention item"
      in
      Alcotest.(check string) "tool host severity" "bad"
        Yojson.Safe.Util.(item |> member "severity" |> to_string);
      Alcotest.(check string) "tool host operator action" "masc_operator_digest"
        Yojson.Safe.Util.
          (item |> member "evidence" |> member "failure_envelope"
         |> member "operator_action" |> to_string))

let assert_snapshot_rejects_pending_confirm_store store_json =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      Workspace_utils.mkdir_p (Operator_control.operator_dir config);
      (match
         Workspace_utils.write_json_result config
           (Operator_control.pending_confirms_path config)
           store_json
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail error);
      match
        Operator_control.snapshot_json
          (operator_ctx env sw config "operator")
      with
      | _ -> Alcotest.fail "malformed pending-confirm store must reject snapshot"
      | exception Operator_control.Store_error _ -> ())

let test_snapshot_rejects_non_list_pending_confirm_store () =
  assert_snapshot_rejects_pending_confirm_store (`Assoc [])

let test_snapshot_rejects_pending_confirm_without_confirm_token () =
  assert_snapshot_rejects_pending_confirm_store
    (`List
      [ `Assoc
          [ "trace_id", `String "trace-missing-token"
          ; "actor", `String "operator"
          ; "action_type", `String "namespace_pause"
          ; "target_type", `String "workspace"
          ; "target_id", `Null
          ; "payload", `Assoc []
          ; "delegated_tool", `String "masc_pause"
          ; "created_at", `String "2026-08-08T00:00:00Z"
          ; "expires_at", `Null
          ]
      ])

let test_snapshot_rejects_pending_confirm_with_invalid_timestamp () =
  assert_snapshot_rejects_pending_confirm_store
    (`List
      [ `Assoc
          [ "confirm_token", `String "confirm-invalid-time"
          ; "trace_id", `String "trace-invalid-time"
          ; "actor", `String "operator"
          ; "action_type", `String "namespace_pause"
          ; "target_type", `String "workspace"
          ; "target_id", `Null
          ; "payload", `Assoc []
          ; "delegated_tool", `String "masc_pause"
          ; "created_at", `String "not-a-timestamp"
          ; "expires_at", `Null
          ]
      ])

(* The walk takes names from the newest rows and stops at the limit, so the
   rows behind the stopping point are never parsed. What it returns must not
   depend on that: the newest names, in the order the newest rows give them,
   and a malformed row it reaches is skipped rather than fatal. *)
(* The identity fields come from the record that defines them, the way the
   three other row builders in this suite already take them. Hand-written
   here, the row said "kind": "turn" -- the versionless shape the module
   docstring calls retired -- so kind_of_json answered None, every row
   contributed no names, and all three cases below read []. *)
let turn_row tools =
  Yojson.Safe.to_string
    (`Assoc
       (Keeper_metrics_record.fields Keeper_metrics_record.Turn
        @ [ "tools_used", `List (List.map (fun t -> `String t) tools) ]))
;;

(* The briefing ([current_work]) and the execution surface ([focus]) read
   [current_task_id] off a snapshot row; a row without the key showed every
   keeper as holding nothing (#31726). *)
let meta_holding ?current_task_id () =
  let task_field =
    match current_task_id with
    | Some id -> [ "current_task_id", `String id ]
    | None -> []
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        ([ "name", `String "holds-a-task"
         ; "trace_id", `String "trace-holds-a-task"
         ; "activation_mode", `String "autonomous"
         ]
         @ task_field))
  with
  | Ok meta -> meta
  | Error error -> Alcotest.fail error

let test_row_field_names_the_task_the_keeper_holds () =
  let key, value =
    Operator_control_snapshot_identity_fields.keeper_current_task_field
      (meta_holding ~current_task_id:"task-1844" ())
  in
  Alcotest.(check string) "the key readers look up" "current_task_id" key;
  Alcotest.(check string) "the held task" "task-1844"
    Yojson.Safe.Util.(value |> to_string)

let test_row_field_is_null_when_no_task_is_held () =
  let key, value =
    Operator_control_snapshot_identity_fields.keeper_current_task_field
      (meta_holding ())
  in
  Alcotest.(check string) "the key is still present" "current_task_id" key;
  Alcotest.(check bool) "null means none held" true (value = `Null)

let test_recent_tool_names_take_the_newest_rows () =
  let lines =
    [ turn_row [ "oldest_a"; "oldest_b" ]
    ; turn_row [ "middle" ]
    ; turn_row [ "newest_a"; "newest_b" ]
    ]
  in
  Alcotest.(check (list string))
    "newest row first, then older ones, up to the limit"
    [ "newest_a"; "newest_b"; "middle"; "oldest_a" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:4 lines);
  Alcotest.(check (list string))
    "a limit the newest row alone fills stops there"
    [ "newest_a" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:1 lines)
;;

let test_recent_tool_names_skip_a_malformed_row () =
  let lines =
    [ turn_row [ "oldest" ]; "{ not json"; turn_row [ "newest" ] ]
  in
  Alcotest.(check (list string))
    "a malformed row between two good ones is skipped, not fatal"
    [ "newest"; "oldest" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:4 lines)
;;

let test_recent_tool_names_ignore_blank_rows () =
  Alcotest.(check (list string))
    "blank rows carry no names and do not stop the walk"
    [ "only" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names
       ~limit:4
       [ ""; turn_row [ "only" ]; "   " ])
;;

let () =
  Alcotest.run
    "operator_control_snapshot"
    [
      ( "runtime status"
      , [
          Alcotest.test_case
            "diagnostic health is a projection of phase and turns"
            `Quick
            test_diagnostic_health_is_a_projection_of_phase_and_turns;
          Alcotest.test_case
            "a failing keeper is probed and stays recoverable"
            `Quick
            test_failing_keeper_is_probed_and_stays_recoverable;
        ] );
      ( "context metrics ledger"
      , [ Alcotest.test_case
            "last-turn usage does not create context"
            `Quick
            test_usage_does_not_create_context_snapshot
        ; Alcotest.test_case
            "snapshot keeps context unobserved and usage separate"
            `Quick
            test_snapshot_keeps_context_unobserved_and_usage_separate
        ] );
      ( "tool host attention"
      , [ Alcotest.test_case
            "digest includes typed tool-host failure"
            `Quick
            test_digest_workspace_includes_tool_host_failure_attention
        ] );
      ( "current task"
      , [ Alcotest.test_case
            "the row names the task the keeper holds"
            `Quick
            test_row_field_names_the_task_the_keeper_holds
        ; Alcotest.test_case
            "the row field is null when no task is held"
            `Quick
            test_row_field_is_null_when_no_task_is_held
        ] );
      ( "recent tool names"
      , [ Alcotest.test_case
            "newest rows fill the limit"
            `Quick
            test_recent_tool_names_take_the_newest_rows
        ; Alcotest.test_case
            "a malformed row is skipped"
            `Quick
            test_recent_tool_names_skip_a_malformed_row
        ; Alcotest.test_case
            "blank rows are ignored"
            `Quick
            test_recent_tool_names_ignore_blank_rows
        ] );
      ( "pending-confirm store"
      , [ Alcotest.test_case
            "non-list store rejects snapshot"
            `Quick
            test_snapshot_rejects_non_list_pending_confirm_store
        ; Alcotest.test_case
            "missing confirm token rejects snapshot"
            `Quick
            test_snapshot_rejects_pending_confirm_without_confirm_token
        ; Alcotest.test_case
            "invalid timestamp rejects snapshot"
            `Quick
            test_snapshot_rejects_pending_confirm_with_invalid_timestamp
        ] );
      ( "defined but never registered until task-1768",
          [ Alcotest.test_case "snapshot has expected sections" `Quick test_snapshot_has_expected_sections
          ; Alcotest.test_case "snapshot summary view excludes retired command plane" `Quick test_snapshot_summary_view_excludes_retired_command_plane
          ; Alcotest.test_case "snapshot lightweight summary omits heavy activity" `Quick test_snapshot_lightweight_summary_omits_heavy_activity
          ] );
    ]
;;
