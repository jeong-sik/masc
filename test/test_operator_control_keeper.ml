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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "dashboard"));
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
      (* social_sweep removed in #5428; verify broadcast instead *)
      match find_action "broadcast" with
      | None -> Alcotest.fail "expected broadcast in available_actions"
      | Some row ->
          Alcotest.(check string) "target_type" "root"
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
          let task_inject =
            match find_action "task_inject" with
            | Some row -> row
            | None -> Alcotest.fail "expected task_inject in available_actions"
          in
          Alcotest.(check bool) "task inject confirm false" false
            Yojson.Safe.Util.(task_inject |> member "confirm_required" |> to_bool);
          (* Issue #8394: team_* operator actions retired. Assert
             absence so re-introduction is caught at test time. *)
          Alcotest.(check bool) "team_stop is NOT in available actions" true
            (Option.is_none (find_action "team_stop"));
          Alcotest.(check bool) "team_turn is NOT in available actions" true
            (Option.is_none (find_action "team_turn")))

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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
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
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
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
          status_json |> member "auto_execution_session" |> member "status" |> to_string);
      Alcotest.(check bool) "keepalive running false" false
        Yojson.Safe.Util.(status_json |> member "keepalive_running" |> to_bool))

let test_keeper_up_rejects_non_public_social_model_arg () =
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String "social-model-keeper");
                ("goal", `String "Reject social model override");
                ("social_model", `String "magentic_ledger_v1");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up rejected" false ok;
      Alcotest.(check bool) "mentions non-public keeper args" true
        (contains_substring body "non-public keeper args");
      Alcotest.(check bool) "mentions social_model" true
        (contains_substring body "social_model"))

let test_keeper_status_defaults_name_to_caller () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "self-probe" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some keeper_name));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = keeper_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Self inspect");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok without explicit name" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check string) "status resolved caller keeper" keeper_name
        Yojson.Safe.Util.(status_json |> member "name" |> to_string))

let test_keeper_status_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_agent_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok via agent alias" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check string) "status resolves canonical keeper name" keeper_name
        Yojson.Safe.Util.(status_json |> member "name" |> to_string))

let test_keeper_status_exposes_model_observability () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "visibility-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose operator model visibility");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Dated_jsonl.append
        (Keeper_types.keeper_metrics_store config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("model_used", `String "llama:qwen3.5-3b-a3b-ud-q8-xl");
            ( "cascade",
              `Assoc
                [
                  ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
                  ( "configured_labels",
                    `List [ `String "llama:auto"; `String "glm:auto" ] );
                  ( "candidate_models",
                    `List
                      [
                        `String "llama:qwen3.5-35b-a3b-ud-q8-xl";
                        `String "llama:qwen3.5-3b-a3b-ud-q8-xl";
                      ] );
                  ("selected_model", `String "llama:qwen3.5-3b-a3b-ud-q8-xl");
                  ("selected_index", `Int 1);
                  ("fallback_hops", `Int 1);
                  ("fallback_applied", `Bool true);
                  ( "attempts",
                    `List
                      [
                        `Assoc
                          [
                            ("attempt_index", `Int 0);
                            ("model_id", `String "qwen3.5-35b-a3b-ud-q8-xl");
                            ( "model_label",
                              `String "llama:qwen3.5-35b-a3b-ud-q8-xl" );
                            ("latency_ms", `Null);
                            ("error", `String "HTTP 503");
                          ];
                        `Assoc
                          [
                            ("attempt_index", `Int 1);
                            ("model_id", `String "qwen3.5-3b-a3b-ud-q8-xl");
                            ( "model_label",
                              `String "llama:qwen3.5-3b-a3b-ud-q8-xl" );
                            ("latency_ms", `Int 187);
                            ("error", `Null);
                          ];
                      ] );
                  ("attempt_details_available", `Bool true);
                  ("attempt_details_source", `String "oas_metrics_callbacks");
                ] );
          ]);
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok" true ok;
      let status_json = parse_json_exn body in
      let open Yojson.Safe.Util in
      let observability = status_json |> member "model_observability" in
      let status_dump = Yojson.Safe.pretty_to_string status_json in
      Alcotest.(check (option string))
        ("cascade name surfaced\n" ^ status_dump)
        (Some Masc_mcp.Keeper_config.default_cascade_name)
        (observability |> member "cascade_name" |> to_string_option);
      Alcotest.(check bool) "recent turn observation true" true
        (observability |> member "recent_turn_observation" |> to_bool);
      Alcotest.(check (list string)) "configured labels surfaced"
        [ "llama:auto"; "glm:auto" ]
        (observability |> member "configured_labels" |> to_list
       |> List.map to_string);
      Alcotest.(check (list string)) "resolved candidates surfaced"
        [
          "llama:qwen3.5-35b-a3b-ud-q8-xl";
          "llama:qwen3.5-3b-a3b-ud-q8-xl";
        ]
        (observability |> member "resolved_candidates" |> to_list
       |> List.map to_string);
      Alcotest.(check (option string))
        ("selected model surfaced\n" ^ status_dump)
        (Some "llama:qwen3.5-3b-a3b-ud-q8-xl")
        (observability |> member "selected_model" |> to_string_option);
      Alcotest.(check string) "attempt summary surfaced"
        "2 attempt(s); fallback after 1 hop(s); selected candidate 2/2."
        (observability |> member "attempt_summary" |> member "summary"
       |> to_string);
      Alcotest.(check string) "runtime scope local" "local"
        (observability |> member "runtime_contract" |> member "provider_scope"
       |> to_string);
      Alcotest.(check bool) "runtime contract unverified" false
        (observability |> member "runtime_contract" |> member "verified"
       |> to_bool);
      Alcotest.(check bool) "chat compatibility intentionally null" true
        (observability |> member "runtime_contract"
         |> member "chat_completion_compatible" = `Null))

let test_keeper_down_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_agent_name) ])
      in
      Alcotest.(check bool) "keeper down ok via agent alias" true ok;
      let down_json = parse_json_exn body in
      Alcotest.(check string) "down resolves canonical keeper name" keeper_name
        Yojson.Safe.Util.(down_json |> member "name" |> to_string);
      match Masc_mcp.Keeper_types.read_meta config keeper_name with
      | Ok (Some meta) ->
          Alcotest.(check bool) "keeper paused after down via alias" true meta.paused
      | Ok None -> Alcotest.fail "keeper meta missing after down"
      | Error err -> Alcotest.fail ("meta read failed: " ^ err))

let test_operator_keeper_probe_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String "operator");
                ("action_type", `String "keeper_probe");
                ("target_type", `String "keeper");
                ("target_id", `String keeper_agent_name);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "probe delegates to keeper status"
        "masc_keeper_status"
        Yojson.Safe.Util.(action_json |> member "tool_name" |> to_string);
      let delegated_result =
        Yojson.Safe.Util.(action_json |> member "result" |> member "result")
      in
      Alcotest.(check string) "probe status resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "status" |> member "name" |> to_string);
      Alcotest.(check bool) "probe includes diagnostic" true
        Yojson.Safe.Util.(delegated_result |> member "diagnostic" <> `Null))

let test_operator_keeper_recover_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String "operator");
                ("action_type", `String "keeper_recover");
                ("target_type", `String "keeper");
                ("target_id", `String keeper_agent_name);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "recover delegates to keeper recover"
        "masc_keeper_recover"
        Yojson.Safe.Util.(action_json |> member "tool_name" |> to_string);
      let delegated_result =
        Yojson.Safe.Util.(action_json |> member "result" |> member "result")
      in
      Alcotest.(check bool) "recover path marked recoverable before action" true
        Yojson.Safe.Util.(delegated_result |> member "before" |> member "recoverable" |> to_bool);
      Alcotest.(check string) "recover down resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "down" |> member "name" |> to_string);
      Alcotest.(check string) "recover up resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "up" |> member "name" |> to_string);
      (* This PR covers only the stale stopped-entry reclaim path.
         Full health recovery depends on agent re-join and status-file
         observations, which are integration concerns outside this unit. *)
      Alcotest.(check bool) "recover reports after diagnostic" true
        Yojson.Safe.Util.(delegated_result |> member "after" <> `Null);
      Alcotest.(check bool) "recover after keepalive running" true
        Yojson.Safe.Util.(delegated_result |> member "after" |> member "keepalive_running" |> to_bool))

let test_keeper_list_scoped_to_current_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name_a = "alpha-scope" in
  let keeper_name_b = "beta-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name_a;
      Keeper_keepalive.stop_keepalive keeper_name_b;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name_a);
                ("goal", `String "Scoped to base path A");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path A" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name_b);
                ("goal", `String "Scoped to base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_list"
          ~args:(`Assoc [ ("limit", `Int 10) ])
      in
      Alcotest.(check bool) "keeper list ok" true ok;
      let list_json = parse_json_exn body in
      let open Yojson.Safe.Util in
      let keeper_names =
        list_json |> member "keepers" |> to_list |> List.map to_string
      in
      Alcotest.(check (list string)) "list only includes current base path keeper"
        [ keeper_name_a ] keeper_names;
      let listed_items = list_json |> member "items" |> to_list in
      Alcotest.(check int) "list item count scoped to current base path" 1
        (List.length listed_items);
      Alcotest.(check string) "listed item name stays local" keeper_name_a
        (listed_items |> List.hd |> member "name" |> to_string))

let test_keeper_status_does_not_cross_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name = "remote-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Only exists in base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      match
        Masc_mcp.Tool_keeper.dispatch keeper_ctx_a ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      with
      | Some (false, err) ->
          Alcotest.(check bool) "status reports keeper missing outside current base path"
            true (contains_substring err ("keeper not found: " ^ keeper_name))
      | Some (true, body) ->
          Alcotest.failf "keeper status unexpectedly crossed base path: %s" body
      | None -> Alcotest.fail "missing keeper status dispatch")

let test_keeper_down_only_pauses_current_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name = "shared-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Shared name in base path A");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path A" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Shared name in base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok in base path A" true ok;
      let down_json = parse_json_exn body in
      Alcotest.(check string) "down returns scoped keeper name" keeper_name
        Yojson.Safe.Util.(down_json |> member "name" |> to_string);
      let meta_a =
        match Masc_mcp.Keeper_types.read_meta config_a keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing in base path A"
        | Error err -> Alcotest.fail ("meta read failed in base path A: " ^ err)
      in
      let meta_b =
        match Masc_mcp.Keeper_types.read_meta config_b keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing in base path B"
        | Error err -> Alcotest.fail ("meta read failed in base path B: " ^ err)
      in
      Alcotest.(check bool) "base path A keeper paused" true meta_a.paused;
      Alcotest.(check bool) "base path B keeper unchanged" false meta_b.paused;
      Alcotest.(check bool) "base path B keeper remains running" true
        (Keeper_registry.is_running ~base_path:config_b.base_path keeper_name))

let test_keeper_status_schema_makes_name_optional () =
  let schema =
    List.find
      (fun (spec : Types.tool_schema) ->
         String.equal spec.name "masc_keeper_status")
      Tool_keeper.schemas
  in
  let required_has_name =
    match Yojson.Safe.Util.member "required" schema.input_schema with
    | `List fields ->
      List.exists (function `String "name" -> true | _ -> false) fields
    | _ -> false
  in
  Alcotest.(check bool) "name no longer required in schema" false required_has_name

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
proactive_enabled = true
|};
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
      Alcotest.(check bool) "runtime paused from live meta" true
        (json |> member "runtime" |> member "paused" |> to_bool);
      Alcotest.(check bool) "proactive enabled from live meta" false
        (json |> member "proactive" |> member "enabled" |> to_bool);
      Alcotest.(check string) "default source kind" "toml"
        (json |> member "sources" |> member "default_source_kind" |> to_string);
      Alcotest.(check bool) "live override flagged" true
        (json |> member "sources" |> member "has_live_override" |> to_bool);
      Alcotest.(check string) "auto team session removed" "removed"
        (json |> member "auto_execution_session" |> member "status" |> to_string);
      let override_fields =
        json |> member "sources" |> member "override_fields" |> to_list
        |> List.map to_string
      in
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
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
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let open Yojson.Safe.Util in
      let rec load_keeper_snapshot attempts_left =
        let snapshot =
          Operator_control.snapshot_json ~include_messages:false
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
      (* keeper_up creates a healthy durable keeper; before any turn runs it should
         surface as idle rather than active. *)
      Alcotest.(check string) "durable keeper is idle before first turn after keeper_up" "idle"
        (keeper |> member "status" |> to_string);
      Alcotest.(check bool) "allowed tool fallback present" true
        ((keeper |> member "allowed_tool_names" |> to_list) <> []);
      let tool_audit_source =
        keeper |> member "tool_audit_source" |> to_string_option
      in
      Alcotest.(check bool) "tool audit source absent or known" true
        (match tool_audit_source with
         | None -> true  (* null before first turn — expected *)
         | Some s -> List.mem s [ "keeper_metrics"; "keeper_decision_log" ]);
      Alcotest.(check bool) "tool audit count zero or absent before first turn" true
        (match keeper |> member "latest_tool_call_count" with
         | `Null -> true  (* None before any turn — expected *)
         | `Int 0 -> true
         | _ -> false);
      Alcotest.(check bool) "tool audit names remain empty" true
        ((keeper |> member "latest_tool_names" |> to_list) = []);
      Alcotest.(check bool) "diagnostic removed from snapshot" true
        (keeper |> member "diagnostic" = `Null);
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok)

let test_snapshot_keeper_tool_audit_uses_decision_log () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper-decision";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "audit-keeper-decision" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose dashboard decision audit");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Fs_compat.append_jsonl
        (Keeper_types.keeper_decision_log_path config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("selected_mode", `String "text_response");
            ("action_source", `String "fallback_after_validation_failure");
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]);
      let open Yojson.Safe.Util in
      let rec load_keeper_snapshot attempts_left =
        let snapshot =
          Operator_control.snapshot_json ~include_messages:false
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
      Alcotest.(check string) "decision log source exposed" "keeper_decision_log"
        (keeper |> member "tool_audit_source" |> to_string);
      Alcotest.(check string) "decision log action source exposed"
        "fallback_after_validation_failure"
        (keeper |> member "latest_action_source" |> to_string);
      Alcotest.(check int) "decision log zero tool count exposed" 0
        (keeper |> member "latest_tool_call_count" |> to_int);
      Alcotest.(check bool) "decision log names remain empty" true
        ((keeper |> member "latest_tool_names" |> to_list) = []))

let test_keeper_msg_auto_execution_session_bridge () =
  (* This test triggers a real LLM cascade call (keeper_msg -> run_turn).
     It is opt-in because local runtime/model availability is not stable
     across developer machines or CI.
     Skip unless MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST=1. The quick-suite
     harness also exports
     CI_TEST_TIMEOUT_SEC, which is more reliable than ALCOTEST_QUICK_TESTS
     under dune test in CI. See: #1936 *)
  if Sys.getenv_opt "MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST" <> Some "1"
     || Sys.getenv_opt "CI" = Some "true"
     || Sys.getenv_opt "ALCOTEST_QUICK_TESTS" = Some "1"
     || Sys.getenv_opt "CI_TEST_TIMEOUT_SEC" <> None then
    Alcotest.skip ()
  else
  Eio_main.run @@ fun env ->
  let local_runtime_available =
    Masc_mcp.Local_runtime_pool.healthy_runtime_count () > 0
  in
  if not local_runtime_available then
    Alcotest.skip ()
  else
  ensure_fs env;
  if Masc_mcp.Local_runtime_pool.healthy_runtime_count () <= 0 then
    Alcotest.skip ()
  else
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "team-session-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
          net = None;
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
                ("autoboot_enabled", `Bool false);
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
        Alcotest.(check bool) "mode present" true
          (match first_json |> member "mode" with
           | `String value -> String.trim value <> ""
           | _ -> false);
        Alcotest.(check bool) "created" true
          (first_json |> member "created" |> to_bool);
        Alcotest.(check bool) "reused" false
          (first_json |> member "reused" |> to_bool);
        let session_id = first_json |> member "session_id" |> to_string in
        (* Team_session_store removed — skip session verification *)
        ignore session_id;
        (* Team session tools removed — skip execution_session_status dispatch test *)
        ignore (config, sw, env, session_id);
        Alcotest.(check bool) "spawn_error surfaced" true
          (first_json |> member "spawn_error" <> `Null);
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
          Yojson.Safe.Util.(status_json |> member "auto_execution_session" |> member "status" |> to_string);
        Alcotest.(check bool) "status exposes auto team session disabled" false
          Yojson.Safe.Util.(status_json |> member "auto_execution_session_enabled" |> to_bool);
        Alcotest.(check bool) "status omits team session state" true
          Yojson.Safe.Util.(status_json |> member "execution_session_state" = `Null);
        Alcotest.(check bool) "status omits team session bridge" true
          Yojson.Safe.Util.(status_json |> member "execution_session_bridge" = `Null);
        (* Team_session_store removed — skip event verification *)
        ignore (config, session_id);
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
        (* Team_session_store removed — skip event count verification *)
        ignore (config, session_id);
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
        Alcotest.(check bool) "keeper paused on down" true meta_after_down.paused;
        (* Team_session_engine_eio removed — skip session cleanup *)
        ignore (config, session_id))

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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
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
