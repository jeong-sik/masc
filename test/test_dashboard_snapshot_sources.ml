open Alcotest
open Masc
module Sources = Server_dashboard_snapshot_sources

let empty_cost_obs : Server_model_metrics_stream.cost_24h_observation =
  { cost_usd = None; read_failed = false; next_change_at = None; cache_was_absent = false }

let test_actual_writes_keep_independent_and_trailing_read_debt () =
  Eio_main.run (fun env ->
    Masc_test_deps.ensure_rng_initialized ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Dashboard_snapshot.reset_for_test ();
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
      (fun () -> Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        let config = Mcp_server.workspace_config state in
        ignore (Workspace.init config ~agent_name:None);
        let agent_path = Filename.concat (Workspace.agents_dir config) "source-agent.json" in
        let read_agent () = if Fs_compat.file_exists agent_path then
          Yojson.Safe.from_string (Fs_compat.load_file agent_path) else `Null in
        let started, set_started = Eio.Promise.create () in
        let release, set_release = Eio.Promise.create () in
        let block = ref true and tool_reads = ref 0 in
        let shell_notices = Eio.Stream.create 2 and tool_notices = Eio.Stream.create 2 in
        let readers : Sources.For_testing.readers = {
          shell = (fun ~light:_ _ ->
            let observed = read_agent () in
            if !block then (
              block := false; Eio.Promise.resolve set_started (); Eio.Promise.await release);
            observed);
          tools = (fun _ -> incr tool_reads;
            Dashboard_snapshot.Tools_ready (`Assoc ["read", `Int !tool_reads]));
          telemetry = (fun ~now:_ _ ->
            {Telemetry_unified.json = `Assoc []; next_change_at_unix = None; read_failed = false});
          cost_24h = (fun ~now:_ _ -> empty_cost_obs);
        } in
        Sources.For_testing.with_readers readers (fun () ->
          Eio.Switch.run (fun sw ->
            let id = "snapshot-sources:" ^ Random_id.uuid_v7 () in
            Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
              ~id ~callback:(fun event -> match event.Sse.ext_payload with
                | `Assoc fields -> (match Workspace_dataset_event.of_fields fields with
                  | Ok (Dashboard_observation {topic = `Tools; scope = `Workspace}) ->
                    (match Dashboard_snapshot.tools_for_config config with
                     | Some prepared -> Eio.Stream.add tool_notices prepared.json
                     | None -> fail "Tools completion preceded its component installation")
                  | Ok (Repositories | Backlog | Verification_requests | Harness_verdicts | Goals
                      | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
                      | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
                      | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
                      | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
                      | Keeper_oauth_attempts _ | Memory_health _ | World_memory | Play_seats
                      | Dashboard_observation _) | Error _ -> ())
                | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ()) ();
            Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
            Sources.install ~state ~sw ~clock:(Eio.Stdenv.clock env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~on_shell_published:(fun ~scope:_ ~shell ~shell_light:_ ->
                check bool "Shell installs before canonical completion" true
                  (Option.is_some (Dashboard_snapshot.shell_for_config config));
                Eio.Stream.add shell_notices shell);
            Eio.Promise.await started;
            ignore (Eio.Stream.take tool_notices);
            check bool "a blocked Shell does not hide completed Tools" true
              (Option.is_some (Dashboard_snapshot.tools_for_config config));
            Tool_metrics.clear ();
            let after_metric = Eio.Stream.take tool_notices in
            check bool "the actual metric writer wakes Tools while Shell is blocked" true
              Yojson.Safe.Util.(after_metric |> member "read" |> to_int > 1);
            let original : Masc_domain.agent = {
              id = None; name = "source-agent"; agent_type = "review";
              status = Active; capabilities = []; current_task = None;
              session_bound_at = "2026-11-10T00:00:00Z";
              last_seen = "2026-11-10T01:00:00Z"; meta = None } in
            Workspace_agent_record.write config agent_path ~previous:None original;
            Eio.Promise.resolve set_release ();
            let rec current_shell () = match Eio.Stream.take shell_notices with
              | `Null -> current_shell ()
              | json -> check string "a committed in-flight agent write remains owed"
                  original.name Yojson.Safe.Util.(json |> member "name" |> to_string) in
            current_shell ());
          let reads_at_release = !tool_reads in
          Tool_metrics.clear ();
          check int "normal release removes the leaf subscription" reads_at_release !tool_reads;
          check bool "normal release retires the active publisher" true
            (Option.is_none (Dashboard_snapshot.current ()))))))
;;

let test_cost_24h_warms_independently_and_signals_shell_on_change () =
  Eio_main.run (fun env ->
    Masc_test_deps.ensure_rng_initialized ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Dashboard_snapshot.reset_for_test ();
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
      (fun () -> Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        let config = Mcp_server.workspace_config state in
        ignore (Workspace.init config ~agent_name:None);
        let cost_started, set_cost_started = Eio.Promise.create () in
        let release_cost, set_release_cost = Eio.Promise.create () in
        let cached_cost = ref None in
        let next_cost = ref (Some 12.5) in
        let cost_reads = ref 0 in
        let shell_notices = Eio.Stream.create 4 in
        let readers : Sources.For_testing.readers = {
          shell = (fun ~light:_ _ ->
            `Assoc [ "cost_24h_usd", Json_util.float_opt_to_json !cached_cost ]);
          tools = (fun _ -> Dashboard_snapshot.Tools_ready (`Assoc []));
          telemetry = (fun ~now:_ _ ->
            { Telemetry_unified.json = `Assoc []
            ; next_change_at_unix = None
            ; read_failed = false
            });
          cost_24h = (fun ~now:_ _ ->
            incr cost_reads;
            if !cost_reads = 1 then (
              Eio.Promise.resolve set_cost_started ();
              Eio.Promise.await release_cost);
            let value = !next_cost in
            cached_cost := value;
            { Server_model_metrics_stream.cost_usd = value
            ; read_failed = false
            ; next_change_at = None
            ; cache_was_absent = !cost_reads = 1
            });
        } in
        Sources.For_testing.with_readers readers (fun () ->
          Eio.Switch.run (fun sw ->
            Sources.install ~state ~sw ~clock:(Eio.Stdenv.clock env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~on_shell_published:(fun ~scope:_ ~shell ~shell_light:_ ->
                Eio.Stream.add shell_notices shell);
            let initial_shell = Eio.Stream.take shell_notices in
            check bool "initial Shell publishes before cost_24h finishes warming" true
              (Yojson.Safe.Util.(initial_shell |> member "cost_24h_usd") = `Null);
            Eio.Promise.await cost_started;
            Eio.Promise.resolve set_release_cost ();
            let warmed_shell = Eio.Stream.take shell_notices in
            check (float 0.001) "warmed cost_24h signals Shell to republish" 12.5
              Yojson.Safe.Util.(warmed_shell |> member "cost_24h_usd" |> to_float);
            next_cost := Some 18.75;
            Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Runtime_metrics;
            let updated_shell = Eio.Stream.take shell_notices in
            check (float 0.001) "Runtime_metrics dataset input refreshes cost_24h and republishes Shell" 18.75
              Yojson.Safe.Util.(updated_shell |> member "cost_24h_usd" |> to_float);
            check int "cost_24h ran for initial warm and subsequent Runtime_metrics input" 2 !cost_reads)))))
;;

let test_cost_24h_retries_transient_failure_and_recovers_after_cache_eviction () =
  Eio_main.run (fun env ->
    Masc_test_deps.ensure_rng_initialized ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Dashboard_snapshot.reset_for_test ();
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
      (fun () -> Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        let config = Mcp_server.workspace_config state in
        ignore (Workspace.init config ~agent_name:None);
        let cached_cost = ref None in
        let cost_reads = ref 0 in
        let shell_notices = Eio.Stream.create 4 in
        let readers : Sources.For_testing.readers = {
          shell = (fun ~light:_ _ ->
            `Assoc [ "cost_24h_usd", Json_util.float_opt_to_json !cached_cost ]);
          tools = (fun _ -> Dashboard_snapshot.Tools_ready (`Assoc []));
          telemetry = (fun ~now:_ _ ->
            { Telemetry_unified.json = `Assoc []
            ; next_change_at_unix = None
            ; read_failed = false
            });
          cost_24h = (fun ~now:_ _ ->
            incr cost_reads;
            match !cost_reads with
            | 1 ->
              { Server_model_metrics_stream.cost_usd = None
              ; read_failed = true
              ; next_change_at = None
              ; cache_was_absent = true
              }
            | 2 ->
              cached_cost := Some 9.25;
              { Server_model_metrics_stream.cost_usd = Some 9.25
              ; read_failed = false
              ; next_change_at = None
              ; cache_was_absent = true
              }
            | _ ->
              cached_cost := Some 9.25;
              { Server_model_metrics_stream.cost_usd = Some 9.25
              ; read_failed = false
              ; next_change_at = None
              ; cache_was_absent = true
              });
        } in
        Sources.For_testing.with_readers readers (fun () ->
          Eio.Switch.run (fun sw ->
            Sources.install ~state ~sw ~clock:(Eio.Stdenv.clock env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~on_shell_published:(fun ~scope:_ ~shell ~shell_light:_ ->
                Eio.Stream.add shell_notices shell);
            let initial_shell = Eio.Stream.take shell_notices in
            check bool "initial Shell is unaffected by first cost_24h failure" true
              (Yojson.Safe.Util.(initial_shell |> member "cost_24h_usd") = `Null);
            let recovered_shell = Eio.Stream.take shell_notices in
            check (float 0.001) "transient cost_24h read failure retries and publishes Shell" 9.25
              Yojson.Safe.Util.(recovered_shell |> member "cost_24h_usd" |> to_float);
            (* Simulate cache eviction followed by repopulation with the same spend. *)
            cached_cost := None;
            Dashboard_observation_commit.written ~base_path ~scope:`Workspace `Model_metrics;
            let rewarmed_shell = Eio.Stream.take shell_notices in
            check (float 0.001) "cache_was_absent re-signals Shell even when spend value is unchanged" 9.25
              Yojson.Safe.Util.(rewarmed_shell |> member "cost_24h_usd" |> to_float);
            check int "cost_24h ran across failure, retry, and eviction recovery" 3 !cost_reads)))))
;;

let () = run "dashboard snapshot sources" ["production input", [
  test_case "actual writers, independent components and in-flight debt" `Quick
    test_actual_writes_keep_independent_and_trailing_read_debt;
  test_case "cost_24h warms independently and signals Shell on change" `Quick
    test_cost_24h_warms_independently_and_signals_shell_on_change;
  test_case "cost_24h retries transient failure and recovers after cache eviction" `Quick
    test_cost_24h_retries_transient_failure_and_recovers_after_cache_eviction]]
