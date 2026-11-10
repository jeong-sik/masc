open Alcotest
open Masc
module Sources = Server_dashboard_snapshot_sources

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
                  | Ok (Repositories | Verification_requests | Harness_verdicts | Goals
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

let () = run "dashboard snapshot sources" ["production input", [
  test_case "actual writers, independent components and in-flight debt" `Quick
    test_actual_writes_keep_independent_and_trailing_read_debt]]
