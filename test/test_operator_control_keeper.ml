open Masc_mcp
open Test_operator_control_support

let test_snapshot_exposes_keeper_and_social_actions () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
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
          Alcotest.(check bool) "lodge_tick hidden from available actions" true
            (Option.is_none (find_action "lodge_tick"));
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
            Yojson.Safe.Util.(worker_spawn_batch |> member "confirm_required" |> to_bool))

(* test_select_checkin_agents_manual_override_quiet_hours removed — Lodge deprecated #1596 *)

let test_keeper_status_exposes_summary_and_recoverable () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
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
      let keeper_name = "probe-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
                ("presence_keepalive", `Bool false);
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok;
      (match
         Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
           ~args:(`Assoc [ ("name", `String keeper_name) ])
       with
      | Some (false, err) ->
          Alcotest.(check string) "resident status missing after down"
            (Printf.sprintf "resident keeper not found: %s" keeper_name)
            err
      | Some (true, _) -> Alcotest.fail "resident keeper should not remain registered after down"
      | None -> Alcotest.fail "missing resident keeper status dispatch");
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
      let diagnostic = parse_json_exn body |> Yojson.Safe.Util.member "diagnostic" in
      Alcotest.(check string) "health_state" "offline"
        Yojson.Safe.Util.(diagnostic |> member "health_state" |> to_string);
      Alcotest.(check string) "next action recover" "recover"
        Yojson.Safe.Util.(diagnostic |> member "next_action_path" |> to_string);
      Alcotest.(check bool) "recoverable true" true
        Yojson.Safe.Util.(diagnostic |> member "recoverable" |> to_bool);
      Alcotest.(check bool) "summary present" true
        (String.length Yojson.Safe.Util.(diagnostic |> member "summary" |> to_string) > 0))

let test_snapshot_keeper_tool_audit_fallback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
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
                ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
                ("presence_keepalive", `Bool false);
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let snapshot =
        Operator_control.snapshot_json ~include_messages:false ~include_sessions:false
          ~include_keepers:true (operator_ctx env sw config "operator")
      in
      let open Yojson.Safe.Util in
      let keeper =
        snapshot
        |> member "keepers" |> member "items" |> to_list
        |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      Alcotest.(check string) "offline when no agent runtime" "offline"
        (keeper |> member "status" |> to_string);
      Alcotest.(check bool) "allowed tool fallback present" true
        ((keeper |> member "allowed_tool_names" |> to_list) <> []);
      Alcotest.(check bool) "tool audit source omitted without evidence" true
        (keeper |> member "tool_audit_source" = `Null);
      Alcotest.(check bool) "diagnostic present" true
        (keeper |> member "diagnostic" <> `Null);
      Alcotest.(check string) "diagnostic health offline" "offline"
        (keeper |> member "diagnostic" |> member "health_state" |> to_string);
      Alcotest.(check string) "diagnostic continuity offline" "offline"
        (keeper |> member "diagnostic" |> member "continuity_state" |> to_string))

let test_keeper_msg_auto_team_session_bridge () =
  (* This test triggers a real LLM cascade call (keeper_msg -> run_turn).
     In CI there is no LLM server, so the cascade hangs until timeout.
     Skip when CI=true or ALCOTEST_QUICK_TESTS=1 to prevent the build
     from timing out.  See: #1936 *)
  if Sys.getenv_opt "CI" = Some "true"
     || Sys.getenv_opt "ALCOTEST_QUICK_TESTS" = Some "1" then
    Alcotest.skip ()
  else
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
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
                ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
                ("auto_team_session_enabled", `Bool true);
                ("presence_keepalive", `Bool false);
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
      Alcotest.(check bool) "keeper msg ok" true ok;
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
      Alcotest.(check bool) "auto team session enabled" true
        meta.auto_team_session_enabled;
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
      Alcotest.(check bool) "status exposes opt-in" true
        Yojson.Safe.Util.(status_json |> member "auto_team_session_enabled" |> to_bool);
      Alcotest.(check string) "status exposes running bridge" "running"
        Yojson.Safe.Util.(status_json |> member "team_session_state" |> to_string);
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


(* test_manual_lodge_tick_updates_observable_state removed — Lodge deprecated #1596 *)
