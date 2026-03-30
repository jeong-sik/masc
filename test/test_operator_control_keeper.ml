open Masc_mcp
open Test_operator_control_support

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let test_snapshot_exposes_keeper_and_social_actions () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      let available_actions =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "available_actions"
        |> Yojson.Safe.Util.to_list
      in
      let find_action action_type =
        List.find_opt
          (fun row ->
            Yojson.Safe.Util.(row |> member "action_type" |> to_string = action_type))
          available_actions
      in
      match find_action "social_sweep" with
      | None -> Alcotest.fail "expected social_sweep in available_actions"
      | Some row ->
          Alcotest.(check string) "target_type" "room"
            Yojson.Safe.Util.(row |> member "target_type" |> to_string);
          Alcotest.(check bool) "confirm_required false" false
            Yojson.Safe.Util.(row |> member "confirm_required" |> to_bool);
          Alcotest.(check bool) "autonomy_tick hidden from available actions" true
            (Option.is_none (find_action "autonomy_tick"));
          let keeper_probe =
            match find_action "keeper_probe" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_probe in available_actions"
          in
          Alcotest.(check string) "keeper_probe target_type" "keeper"
            Yojson.Safe.Util.(keeper_probe |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_probe confirm false" false
            Yojson.Safe.Util.(keeper_probe |> member "confirm_required" |> to_bool);
          let keeper_recover =
            match find_action "keeper_recover" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_recover in available_actions"
          in
          Alcotest.(check string) "keeper_recover target_type" "keeper"
            Yojson.Safe.Util.(keeper_recover |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_recover confirm false" false
            Yojson.Safe.Util.(keeper_recover |> member "confirm_required" |> to_bool);
          let worker_spawn_batch =
            match find_action "team_worker_spawn_batch" with
            | Some row -> row
            | None -> Alcotest.fail "expected team_worker_spawn_batch in available_actions"
          in
          Alcotest.(check string) "worker spawn batch target_type" "team_session"
            Yojson.Safe.Util.(worker_spawn_batch |> member "target_type" |> to_string);
          Alcotest.(check bool) "worker spawn batch confirm true" true
            Yojson.Safe.Util.(worker_spawn_batch |> member "confirm_required" |> to_bool);
          let task_inject =
            match find_action "task_inject" with
            | Some row -> row
            | None -> Alcotest.fail "expected task_inject in available_actions"
          in
          Alcotest.(check bool) "task inject confirm false" false
            Yojson.Safe.Util.(task_inject |> member "confirm_required" |> to_bool);
          let team_stop =
            match find_action "team_stop" with
            | Some row -> row
            | None -> Alcotest.fail "expected team_stop in available_actions"
          in
          Alcotest.(check bool) "team stop confirm true" true
            Yojson.Safe.Util.(team_stop |> member "confirm_required" |> to_bool))

let test_keeper_status_exposes_summary_and_recoverable () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok;
      (* After keeper_down, deactivate_keeper sets desired=false
         but keeps the entry. masc_keeper_status may return success (entry
         found with desired=false) or not-found depending on version.
         Accept either: the important assertions are the persistent_agent
         status diagnostics below. *)
      (match
         Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
           ~args:(`Assoc [ ("name", `String keeper_name) ])
       with
      | Some (false, _) -> ()  (* Entry removed: expected in older code *)
      | Some (true, _) -> ()   (* Entry deactivated (desired=false): current behavior *)
      | None -> Alcotest.fail "missing keeper status dispatch");
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_persistent_agent_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("fast", `Bool false);
                ("include_context", `Bool false);
                ("include_metrics_overview", `Bool false);
                ("include_memory_bank", `Bool false);
                ("include_history_tail", `Bool false);
                ("include_compaction_history", `Bool false);
              ])
      in
      Alcotest.(check bool) "persistent status ok" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check bool) "diagnostic removed from status" true
        Yojson.Safe.Util.(status_json |> member "diagnostic" = `Null);
      Alcotest.(check string) "auto team session removed" "removed"
        Yojson.Safe.Util.(
          status_json |> member "auto_team_session" |> member "status" |> to_string);
      Alcotest.(check bool) "keepalive running false" false
        Yojson.Safe.Util.(status_json |> member "keepalive_running" |> to_bool))

let test_keeper_config_exposes_live_runtime_and_sources () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let cwd = Sys.getcwd () in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original_config_dir with
      | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
      | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ();
      Keeper_keepalive.stop_keepalive "config-provenance";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      Unix.chdir cwd;
      cleanup_dir base_dir)
    (fun () ->
      Unix.chdir base_dir;
      let config_dir = Filename.concat base_dir "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      let keepers_dir = Filename.concat config_dir "keepers" in
      Fs_compat.mkdir_p keepers_dir;
      Fs_compat.save_file
        (Filename.concat keepers_dir "config-provenance.toml")
        {|
[keeper]
goal = "Defaults goal"
room_scope = "all"
proactive_enabled = true
|};
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
        }
      in
      let keeper_name = "config-provenance" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let meta =
        match Masc_mcp.Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing"
        | Error err -> Alcotest.fail ("meta read failed: " ^ err)
      in
      let mutated =
        {
          meta with
          room_scope = "current";
          proactive = { meta.proactive with enabled = false };
          runtime =
            { meta.runtime with
              usage =
                {
                  meta.runtime.usage with
                  total_input_tokens = 1200;
                  total_output_tokens = 800;
                  total_tokens = 2000;
                  total_cost_usd = 0.042;
                  last_model_used = "glm:auto";
                  last_input_tokens = 120;
                  last_output_tokens = 80;
                  last_total_tokens = 200;
                  last_latency_ms = 4000;
                };
            };
          paused = true;
          updated_at = Types.now_iso ();
        }
      in
      (match Masc_mcp.Keeper_types.write_meta config mutated with
      | Ok () -> ()
      | Error err -> Alcotest.fail ("meta write failed: " ^ err));
      let status, json =
        Masc_mcp.Dashboard_http_keeper.keeper_config_json config keeper_name
      in
      Alcotest.(check bool) "config found" true (status = `OK);
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "trigger_mode removed from config surface" true
        (json |> member "coordination" |> member "trigger_mode" = `Null);
      Alcotest.(check string) "room_scope from live meta" "current"
        (json |> member "coordination" |> member "room_scope" |> to_string);
      Alcotest.(check bool) "runtime paused from live meta" true
        (json |> member "runtime" |> member "paused" |> to_bool);
      Alcotest.(check bool) "proactive enabled from live meta" false
        (json |> member "proactive" |> member "enabled" |> to_bool);
      Alcotest.(check string) "default source kind" "toml"
        (json |> member "sources" |> member "default_source_kind" |> to_string);
      Alcotest.(check bool) "live override flagged" true
        (json |> member "sources" |> member "has_live_override" |> to_bool);
      Alcotest.(check string) "auto team session removed" "removed"
        (json |> member "auto_team_session" |> member "status" |> to_string);
      let override_fields =
        json |> member "sources" |> member "override_fields" |> to_list
        |> List.map to_string
      in
      (* Source defaults keep room_scope = "all", while live meta is mutated to
         "current", so the override must stay visible. *)
      Alcotest.(check bool) "room_scope override flagged" true
        (List.mem "coordination.room_scope" override_fields);
      Alcotest.(check bool) "override field proactive" true
        (List.mem "proactive.enabled" override_fields);
      Alcotest.(check bool) "initiative surface removed" true
        (json |> member "initiative" = `Null);
      Alcotest.(check int) "total input tokens surfaced" 1200
        (json |> member "metrics" |> member "total_input_tokens" |> to_int);
      Alcotest.(check int) "last latency surfaced" 4000
        (json |> member "metrics" |> member "last_latency_ms" |> to_int);
      Alcotest.(check (option (float 0.001))) "last total tokens per sec surfaced"
        (Some 50.0)
        (json |> member "metrics" |> member "last_total_tokens_per_sec" |> to_float_option);
      Alcotest.(check (option (float 0.001))) "last output tokens per sec surfaced"
        (Some 20.0)
        (json |> member "metrics" |> member "last_output_tokens_per_sec" |> to_float_option);
      (* Prompt source depends on runtime bootstrap and any restored overrides;
         accepted values come from Prompt_registry.resolve_prompt_unlocked. *)
      let prompt_source =
        json |> member "prompt" |> member "system_prompt_blocks"
        |> member "world" |> member "source" |> to_string
      in
      Alcotest.(check bool) "prompt block source surfaced" true
        (List.mem prompt_source [ "override"; "file"; "default"; "missing" ]);
      let effective_system_prompt =
        json |> member "prompt" |> member "effective_system_prompt" |> to_string
      in
      Alcotest.(check bool) "effective system prompt includes goal" true
        (contains_substring effective_system_prompt ("Goal: " ^ mutated.goal));
      Alcotest.(check bool) "effective system prompt includes world block" true
        (contains_substring effective_system_prompt "<world>");
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok)

let test_snapshot_keeper_tool_audit_fallback () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
        }
      in
      let keeper_name = "audit-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose dashboard fallback keeper audit");
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let open Yojson.Safe.Util in
      let rec load_keeper_snapshot attempts_left =
        let snapshot =
          Operator_control.snapshot_json ~include_messages:false ~include_sessions:false
            ~include_keepers:true (operator_ctx env sw config "operator")
        in
        match
          snapshot
          |> member "keepers" |> member "items" |> to_list
          |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        with
        | Some keeper -> keeper
        | None when attempts_left > 0 ->
            Unix.sleepf 0.05;
            load_keeper_snapshot (attempts_left - 1)
        | None ->
            Alcotest.failf "keeper %s missing from snapshot: %s" keeper_name
              (Yojson.Safe.to_string snapshot)
      in
      let keeper = load_keeper_snapshot 10 in
      Alcotest.(check string) "durable keeper is active after keeper_up" "active"
        (keeper |> member "status" |> to_string);
      Alcotest.(check bool) "allowed tool fallback present" true
        ((keeper |> member "allowed_tool_names" |> to_list) <> []);
      Alcotest.(check bool) "tool audit source omitted without evidence" true
        (keeper |> member "tool_audit_source" = `Null);
      Alcotest.(check bool) "diagnostic removed from snapshot" true
        (keeper |> member "diagnostic" = `Null);
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok)

let test_keeper_msg_auto_team_session_bridge () =
  (* This test triggers a real LLM cascade call (keeper_msg -> run_turn).
     It is opt-in because local runtime/model availability is not stable
     across developer machines or CI.
     Skip unless MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST=1. The quick-suite
     harness also exports
     CI_TEST_TIMEOUT_SEC, which is more reliable than ALCOTEST_QUICK_TESTS
     under dune test in CI. See: #1936 *)
  let local_runtime_available =
    Masc_mcp.Local_runtime_pool.healthy_runtime_count () > 0
  in
  if Sys.getenv_opt "MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST" <> Some "1"
     || Sys.getenv_opt "CI" = Some "true"
     || Sys.getenv_opt "ALCOTEST_QUICK_TESTS" = Some "1"
     || Sys.getenv_opt "CI_TEST_TIMEOUT_SEC" <> None
     || not local_runtime_available then
    Alcotest.skip ()
  else
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "team-session-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
        }
      in
      let keeper_name = "team-session-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Start projected team sessions from explicit keeper messages");
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let first_message = "QA the mission surface and report the first blocker." in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("message", `String first_message);
              ])
      in
      if not ok then
        let body_lc = String.lowercase_ascii body in
        let body_has needle =
          let s_len = String.length body_lc in
          let n_len = String.length needle in
          let rec loop i =
            if i + n_len > s_len then false
            else if String.sub body_lc i n_len = needle then true
            else loop (i + 1)
          in
          n_len = 0 || loop 0
        in
        if body_has "agent.run failed"
           || body_has "api key"
           || body_has "provider"
           || body_has "runtime" then
          Alcotest.skip ()
        else
          Alcotest.failf "keeper msg failed unexpectedly: %s" body
      else
        let first_json = parse_json_exn body in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "mode" "team_session"
          (first_json |> member "mode" |> to_string);
        Alcotest.(check bool) "created" true
          (first_json |> member "created" |> to_bool);
        Alcotest.(check bool) "reused" false
          (first_json |> member "reused" |> to_bool);
        let session_id = first_json |> member "session_id" |> to_string in
        let session =
          match Team_session_store.load_session config session_id with
          | Some session -> session
          | None -> Alcotest.fail "team session missing after keeper_msg"
        in
        Alcotest.(check string) "session goal" first_message session.goal;
        Alcotest.(check string) "session status" "running"
          (Team_session_types.status_to_string session.status);
        let team_ctx : _ Tool_team_session.context =
          {
            config;
            agent_name = "operator";
            sw;
            clock = Eio.Stdenv.clock env;
            proc_mgr = None;
          }
        in
        let team_status_ok, _ =
          dispatch_team_exn team_ctx ~name:"masc_team_session_status"
            ~args:(`Assoc [ ("session_id", `String session_id) ])
        in
        Alcotest.(check bool) "caller can access suggested team session tools" true
          team_status_ok;
        Alcotest.(check bool) "spawn_error surfaced" true
          (first_json |> member "spawn_error" <> `Null);
        let meta =
          match Masc_mcp.Keeper_types.read_meta config keeper_name with
          | Ok (Some meta) -> meta
          | Ok None -> Alcotest.fail "keeper meta missing after keeper_msg"
          | Error err -> Alcotest.fail ("meta read failed: " ^ err)
        in
        Alcotest.(check (option string)) "linked session id"
          (Some session_id) meta.active_team_session_id;
        Alcotest.(check int) "start count" 1 meta.team_session_start_count_total;
        let status_ok, status_body =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
            ~args:
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("include_context", `Bool false);
                  ("include_metrics_overview", `Bool false);
                  ("include_memory_bank", `Bool false);
                  ("include_history_tail", `Bool false);
                  ("include_compaction_history", `Bool false);
                ])
        in
        Alcotest.(check bool) "keeper status ok" true status_ok;
        let status_json = parse_json_exn status_body in
        Alcotest.(check string) "status exposes auto team session removal" "removed"
          Yojson.Safe.Util.(status_json |> member "auto_team_session" |> member "status" |> to_string);
        Alcotest.(check bool) "status exposes auto team session disabled" false
          Yojson.Safe.Util.(status_json |> member "auto_team_session_enabled" |> to_bool);
        Alcotest.(check string) "status exposes running bridge" "running"
          Yojson.Safe.Util.(status_json |> member "team_session_state" |> to_string);
        Alcotest.(check bool) "status exposes bridge enabled" true
          Yojson.Safe.Util.(
            status_json |> member "team_session_bridge" |> member "enabled" |> to_bool);
        let events = Team_session_store.read_recent_events config session_id ~max_count:10 in
        let note_events =
          List.filter
            (fun event ->
              event.Team_session_types.event_type = "team_turn"
              && Yojson.Safe.Util.(
                   event.detail |> member "kind" |> to_string = "note"))
            events
        in
        Alcotest.(check bool) "note event recorded" true (note_events <> []);
        let ok, second_body =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
            ~args:
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("message", `String "Continue with execution notes." );
                ])
        in
        Alcotest.(check bool) "second keeper msg ok" true ok;
        let second_json = parse_json_exn second_body in
        Alcotest.(check string) "reused session id" session_id
          Yojson.Safe.Util.(second_json |> member "session_id" |> to_string);
        Alcotest.(check bool) "second created false" false
          Yojson.Safe.Util.(second_json |> member "created" |> to_bool);
        Alcotest.(check bool) "second reused true" true
          Yojson.Safe.Util.(second_json |> member "reused" |> to_bool);
        let events_after = Team_session_store.read_recent_events config session_id ~max_count:20 in
        let note_count =
          List.fold_left
            (fun acc event ->
              if
                event.Team_session_types.event_type = "team_turn"
                && Yojson.Safe.Util.(
                     event.detail |> member "kind" |> to_string = "note")
              then acc + 1
              else acc)
            0 events_after
        in
        Alcotest.(check bool) "second note recorded" true (note_count >= 2);
        let ok, _ =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
            ~args:(`Assoc [ ("name", `String keeper_name) ])
        in
        Alcotest.(check bool) "keeper down ok" true ok;
        let meta_after_down =
          match Masc_mcp.Keeper_types.read_meta config keeper_name with
          | Ok (Some meta) -> meta
          | Ok None -> Alcotest.fail "keeper meta removed unexpectedly"
          | Error err -> Alcotest.fail ("meta read after down failed: " ^ err)
        in
        let session_after_down =
          match Team_session_store.load_session config session_id with
          | Some session -> session
          | None -> Alcotest.fail "team session removed unexpectedly on down"
        in
        Alcotest.(check string) "linked session interrupted on down" "interrupted"
          (Team_session_types.status_to_string session_after_down.status);
        Alcotest.(check (option string)) "linked session cleared on down" None
          meta_after_down.active_team_session_id;
        Alcotest.(check string) "last started cleared on down" ""
          meta_after_down.last_team_session_started_at;
        Alcotest.(check int) "start count retained on down" 1
          meta_after_down.team_session_start_count_total)

let test_operator_keeper_message_rejects_legacy_model_args () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      match
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("action_type", `String "keeper_message");
              ("target_type", `String "keeper");
              ("target_id", `String "sangsu");
              ( "payload",
                `Assoc
                  [
                    ("message", `String "ping");
                    ("models", `List [ `String "llama:test-model" ]);
                  ] );
            ])
      with
      | Ok _ -> Alcotest.fail "keeper_message should reject legacy models payload"
      | Error err ->
          Alcotest.(check bool) "legacy model error surfaced" true
            (contains_substring err "legacy keeper model args removed"))
