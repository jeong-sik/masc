open Alcotest
open Masc

module Broadcast = Server_dashboard_observation_broadcast
module Commit = Dashboard_observation_commit

let with_workspace f =
  Eio_main.run (fun env ->
    Masc_test_deps.ensure_rng_initialized ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with
      | Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ()) (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        (* Fixture deadlock watchdog only; no product observation cadence. *)
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0
          (fun () -> f env state)))
;;

let observation (event : Sse.external_event) =
  match event.ext_payload with
  | `Assoc fields ->
      (match Workspace_dataset_event.of_fields fields with
       | Ok (Dashboard_observation payload) -> Some payload
       | Ok (Repositories | Verification_requests | Harness_verdicts | Goals
           | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
           | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
           | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
           | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
           | Keeper_oauth_attempts _ | Memory_health _ | World_memory | Play_seats)
       | Error _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let subscribe ~sw ~base_path callback =
  let id = "dashboard-commit-test:" ^ Random_id.uuid_v7 () in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
    ~id ~callback ();
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id)
;;

let test_actual_leaf_commit_invalidates_before_notice () =
  with_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let key = Server_dashboard_http_core_cache.tool_metrics_series_cache_key
        config ["tool", Some "isolated-observed-tool"] in
    ignore (Dashboard_cache.get_or_compute key ~ttl:60.0
      (Pool_work.cpu ~name:__FUNCTION__ (fun () -> `String "old series")));
    let delivered = Eio.Stream.create 1 in
    Eio.Switch.run (fun sw ->
      subscribe ~sw ~base_path:config.base_path (fun event ->
        match observation event with
        | Some { topic = `Tool_metrics; scope = `Workspace } ->
            check bool "REST cache is retired before the consumer wakes" true
              (Option.is_none (Dashboard_cache.peek key));
            Eio.Stream.add delivered ()
        | Some _ | None -> ());
      Broadcast.install ~state ~sw ~mono_clock:(Eio.Stdenv.mono_clock env);
      (* The real leaf writer has no dependency on this broadcaster. *)
      Tool_metrics.clear ();
      Eio.Stream.take delivered))
;;

let test_blocked_fanout_preserves_writer_and_trailing_change () =
  with_workspace (fun env state ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let release, resolve = Eio.Promise.create () in
    let started = Eio.Stream.create 1 and other = Eio.Stream.create 1 in
    let metric_notices = ref 0 and attribution_notices = ref 0 in
    Eio.Switch.run (fun sw ->
      subscribe ~sw ~base_path (fun event ->
        match observation event with
        | Some { topic = `Tool_metrics; scope = `Workspace } ->
            incr metric_notices;
            Eio.Stream.add started ();
            if !metric_notices = 1 then Eio.Promise.await release
        | Some { topic = `Attribution; scope = `Workspace } ->
            incr attribution_notices;
            Eio.Stream.add other ()
        | Some _ | None -> ());
      Broadcast.install ~state ~sw ~mono_clock:(Eio.Stdenv.mono_clock env);
      Tool_metrics.clear ();
      Eio.Stream.take started;
      (* This returns while the first delivery is still suspended. *)
      Tool_metrics.clear ();
      Dashboard_attribution.record
        (Attribution.passed ~origin:Det ~gate:"isolated-observation" ~evidence:`Null);
      Eio.Stream.take other;
      check int "another read model publishes independently" 1 !attribution_notices;
      Eio.Promise.resolve resolve ();
      Eio.Stream.take started;
      check int "an in-flight change is still published" 2 !metric_notices);
    (* Normal return retires both source listeners and quiet workers. *)
    Tool_metrics.clear ();
    Commit.process_written `Attribution;
    check int "released source cannot publish" 2 !metric_notices)
;;

let test_actual_activity_and_runtime_sample_wake_their_readers () =
  with_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let notices = Eio.Stream.create 2 in
    Eio.Switch.run (fun sw ->
      subscribe ~sw ~base_path:config.base_path (fun event ->
        match observation event with
        | Some { topic = (`Activity | `Runtime_observables) as topic; scope = `Workspace } ->
            Eio.Stream.add notices topic
        | Some _ | None -> ());
      Broadcast.install ~state ~sw ~mono_clock:(Eio.Stdenv.mono_clock env);
      let value = Activity_graph.emit config ~kind:"isolated.source-commit"
          ~payload:(`Assoc ["fixture", `Bool true]) () in
      check bool "the real activity writer precedes its invalidation" true
        (Eio.Stream.take notices = `Activity);
      let rows = Activity_graph.list_events config ~after_seq:0 ~limit:1 ~keep:(fun _ -> true) () in
      check bool "the event consumer can read the actual durable row" true
        (List.exists (fun (row : Activity_graph.event) -> row.seq = value.seq) rows);
      ignore (Otel_runtime_observables.For_testing.write_samples_to_store
        ~masc_root:(Workspace.masc_dir config) ());
      check bool "a completed runtime sample wakes its own reader" true
        (Eio.Stream.take notices = `Runtime_observables)))
;;

let test_canonical_keeper_commit_keeps_its_reader_scope () =
  with_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let composite = Server_dashboard_http_keeper_api_types.keeper_composite_cache_key
        ~base_path:config.base_path "exact-keeper" in
    let trace filter limit = Server_dashboard_http_keeper_api_types.keeper_runtime_trace_cache_key
        config "exact-keeper" ~trace_id:filter ~limit () in
    let traces = [trace "one" 1; trace "two" 2] in
    List.iter (fun key -> ignore (Dashboard_cache.get_or_compute key ~ttl:60.0
      (Pool_work.cpu ~name:__FUNCTION__ (fun () -> `String "old selection"))))
      (composite :: traces);
    let notices = Eio.Stream.create 2 in
    Eio.Switch.run (fun sw ->
      subscribe ~sw ~base_path:config.base_path (fun event ->
        match observation event with
        | Some { topic = (`Keeper_composite | `Keeper_runtime_trace) as topic; _ } as payload ->
            let keys = if topic = `Keeper_composite then [composite] else traces in
            List.iter (fun key -> check bool "every affected cache selection is retired first"
              true (Option.is_none (Dashboard_cache.peek key))) keys;
            Eio.Stream.add notices payload
        | Some _ | None -> ());
      Broadcast.install ~state ~sw ~mono_clock:(Eio.Stdenv.mono_clock env);
      Keeper_row_broadcast.changed ~base_path:config.base_path ~keeper_name:"exact-keeper";
      let first = Eio.Stream.take notices in
      let second = Eio.Stream.take notices in
      check bool "canonical row publication preserves the exact Keeper" true
        (List.for_all (function
          | Some { Sse_event.Types.scope = `Keeper "exact-keeper"; _ } -> true
          | Some _ | None -> false) [first; second])))
;;

let () = run "dashboard commit observation"
  ["production paths", [
    test_case "leaf commit retires the dependent REST cache" `Quick
      test_actual_leaf_commit_invalidates_before_notice;
    test_case "blocked fanout preserves writer and read debt" `Quick
      test_blocked_fanout_preserves_writer_and_trailing_change;
    test_case "real activity and sample commits wake their readers" `Quick
      test_actual_activity_and_runtime_sample_wake_their_readers;
    test_case "canonical Keeper row retains its scope" `Quick
      test_canonical_keeper_commit_keeps_its_reader_scope]]
;;
