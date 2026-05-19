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
     || Sys.getenv_opt "CI_TEST_TIMEOUT_SEC" <> None
  then Alcotest.skip ()
  else
    Eio_main.run @@ fun env ->
    let local_runtime_available =
      Masc_mcp.Local_runtime_pool.healthy_runtime_count () > 0
    in
    if not local_runtime_available then Alcotest.skip ()
    else
      ensure_fs env;
      if Masc_mcp.Local_runtime_pool.healthy_runtime_count () <= 0 then
        Alcotest.skip ()
      else
        Eio.Switch.run @@ fun sw ->
        let base_dir = temp_dir () in
        Fun.protect
          ~finally:(fun () ->
            Keeper_keepalive.stop_keepalive "mission-control-keeper";
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
            let keeper_name = "mission-control-keeper" in
            let ok, _ =
              dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
                ~args:
                  (`Assoc
                    [
                      ("name", `String keeper_name);
                      ( "goal",
                        `String
                          "Start projected execution sessions from explicit \
                           keeper messages" );
                      ("proactive_enabled", `Bool false);
                      ("autoboot_enabled", `Bool false);
                    ])
            in
            Alcotest.(check bool) "keeper up ok" true ok;
            let first_message =
              "QA the mission surface and report the first blocker."
            in
            let ok, body =
              dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
                ~args:
                  (`Assoc
                    [
                      ("name", `String keeper_name);
                      ("message", `String first_message);
                    ])
            in
            if not ok then (
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
                 || body_has "api key" || body_has "provider"
                 || body_has "runtime"
              then Alcotest.skip ()
              else Alcotest.failf "keeper msg failed unexpectedly: %s" body)
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
              ignore session_id;
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
              Alcotest.(check string)
                "status exposes auto execution session removal"
                "removed"
                Yojson.Safe.Util.(
                  status_json |> member "auto_execution_session"
                  |> member "status" |> to_string);
              Alcotest.(check bool)
                "status exposes auto execution session disabled"
                false
                Yojson.Safe.Util.(
                  status_json |> member "auto_execution_session_enabled"
                  |> to_bool);
              Alcotest.(check bool) "status omits execution session state" true
                Yojson.Safe.Util.(
                  status_json |> member "execution_session_state" = `Null);
              Alcotest.(check bool) "status omits execution session bridge" true
                Yojson.Safe.Util.(
                  status_json |> member "execution_session_bridge" = `Null);
              ignore (config, session_id);
              let ok, second_body =
                dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
                  ~args:
                    (`Assoc
                      [
                        ("name", `String keeper_name);
                        ("message", `String "Continue with execution notes.");
                      ])
              in
              Alcotest.(check bool) "second keeper msg ok" true ok;
              let second_json = parse_json_exn second_body in
              Alcotest.(check string) "reused session id" session_id
                Yojson.Safe.Util.(
                  second_json |> member "session_id" |> to_string);
              Alcotest.(check bool) "second created false" false
                Yojson.Safe.Util.(second_json |> member "created" |> to_bool);
              Alcotest.(check bool) "second reused true" true
                Yojson.Safe.Util.(second_json |> member "reused" |> to_bool);
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
              Alcotest.(check bool) "keeper paused on down" true
                meta_after_down.paused;
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
