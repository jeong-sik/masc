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
          let swarm_continue =
            match find_action "swarm_run_continue" with
            | Some row -> row
            | None -> Alcotest.fail "expected swarm_run_continue in available_actions"
          in
          Alcotest.(check string) "swarm continue target_type" "swarm_run"
            Yojson.Safe.Util.(swarm_continue |> member "target_type" |> to_string);
          Alcotest.(check bool) "swarm continue confirm true" true
            Yojson.Safe.Util.(swarm_continue |> member "confirm_required" |> to_bool))

let test_select_checkin_agents_manual_override_quiet_hours () =
  let current_hour = Lodge_heartbeat.current_hour_kst () in
  let config =
    {
      Lodge_heartbeat.default_config with
      quiet_hours = (current_hour, current_hour + 1);
      agents_per_tick = 1;
      min_checkin_gap_s = 0.0;
    }
  in
  let agent_name = "operator-lodge-quiet-override-test" in
  let agents =
    [
      {
        Lodge_heartbeat.name = agent_name;
        preferred_hours = [];
        peak_hour = None;
        traits = [];
        interests = [];
        personality_hint = None;
        activity_level = 0.7;
      };
    ]
  in
  let pending_triggers = [ (agent_name, Lodge_heartbeat.ManualTrigger) ] in
  let blocked =
    Lodge_heartbeat.select_checkin_agents ~ignore_quiet_hours:false ~config
      ~agents ~pending_triggers
  in
  Alcotest.(check int) "quiet hours block selection" 0 (List.length blocked);
  let overridden =
    Lodge_heartbeat.select_checkin_agents ~ignore_quiet_hours:true ~config
      ~agents ~pending_triggers
  in
  Alcotest.(check int) "manual override selects one agent" 1
    (List.length overridden)

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
        { config; sw; clock = Eio.Stdenv.clock env }
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
        { config; sw; clock = Eio.Stdenv.clock env }
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

let test_manual_lodge_tick_updates_observable_state () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let before = Lodge_heartbeat.lodge_status () in
      let result : Lodge_heartbeat.heartbeat_result =
        {
          timestamp = Unix.gettimeofday ();
          current_hour = 11;
          agents_checked = 2;
          checkins =
            [
              ( "historian",
                Lodge_heartbeat.ManualTrigger,
                Lodge_heartbeat.Passed "no valuable contribution" );
            ];
          agents_woken = [];
          encounter_rolled = None;
          activity_report = "manual test tick";
        }
      in
      Lodge_heartbeat.record_tick_result result;
      let after = Lodge_heartbeat.lodge_status () in
      Alcotest.(check int) "manual tick increments total ticks"
        (before.ls_total_ticks + 1) after.ls_total_ticks;
      Alcotest.(check int) "manual tick increments total checkins"
        (before.ls_total_checkins + List.length result.Lodge_heartbeat.checkins)
        after.ls_total_checkins;
      Alcotest.(check bool) "manual tick stores last result" true
        (Option.is_some after.ls_last_result);
      Alcotest.(check bool) "manual tick running cleared" false
        after.ls_manual_tick_running)
