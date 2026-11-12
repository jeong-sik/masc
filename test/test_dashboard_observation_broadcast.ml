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

let () = run "dashboard commit observation"
  ["production paths", [
    test_case "leaf commit retires the dependent REST cache" `Quick
      test_actual_leaf_commit_invalidates_before_notice;
    test_case "blocked fanout preserves writer and read debt" `Quick
      test_blocked_fanout_preserves_writer_and_trailing_change]]
;;
