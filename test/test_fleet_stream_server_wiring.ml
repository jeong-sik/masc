open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Refresh = Server_routes_http_runtime.For_testing

let with_server_state f =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let previous = Server_auth.For_testing.snapshot_server_state () in
  let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
  Server_auth.For_testing.restore_server_state (Some state);
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous;
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> f state)
;;

let hub_for state scope =
  match Server_routes_http_runtime.fleet_stream_hub_for_scope ~state ~scope with
  | Some hub -> hub
  | None -> fail "expected the current workspace hub"
;;

(* The fleet section as the scan writes it. Only the running count varies; the
   other keys take the empty value of their type, except the proactive
   interval, which has none and takes the setting's default. *)
let fleet_section ~running : Yojson.Safe.t =
  let counts =
    List.map
      (fun key -> key, `Int 0)
      [ "bootable_keeper_count"
      ; "executable_keeper_fiber_count"
      ; "failing_keeper_fiber_count"
      ; "recovering_keeper_fiber_count"
      ; "turn_configuration_error_keeper_count"
      ; "official_client_recovery_required_keeper_count"
      ; "paused_keeper_count"
      ; "target_reaction_capacity_count"
      ; "reaction_capacity_shortfall_count"
      ; "active_task_owner_without_executable_fiber_count"
      ; "completion_authority_pending_task_count"
      ; "active_task_owner_scan_error_count"
      ]
  in
  let names =
    List.map
      (fun key -> key, `List [])
      [ "bootable_keeper_names"
      ; "running_keeper_names"
      ; "executable_keeper_names"
      ; "turn_configuration_error_keeper_names"
      ; "official_client_recovery_required_keeper_names"
      ]
  in
  `Assoc
    ([ "schema", `String Masc.Keeper_fleet_blocker.reading_schema
     ; "status", `String "ok"
     ; "blocker", `Null
     ; "operator_action_required", `Bool false
     ; "running_keeper_fiber_count", `Int running
     ; "proactive_interval_sec", `Int 300
     ]
     @ counts
     @ names)
;;

let health_fields section : (string * Yojson.Safe.t) list =
  [ "overall_status", `String "ok"; "keeper_fleet_safety", section ]
;;

let read_full_health () =
  let authority =
    match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority
    | Error `Malformed -> fail "invalid test authority"
  in
  Server_routes_http_runtime.make_health_response_json ~request_authority:authority
    (Httpun.Request.create `GET "/health?full=1")
;;

let full_health_status () =
  let open Yojson.Safe.Util in
  read_full_health () |> member "full_health_snapshot" |> member "status" |> to_string
;;

(* What an event says, without the time the scan finished. *)
let describe : F.event -> string = function
  | F.Unavailable_snapshot { revision; degradation } ->
    Printf.sprintf "unavailable r%d %s" (F.Revision.to_int revision)
      (match degradation.F.reason with
       | F.Scan_timed_out -> "timed_out"
       | F.Scan_failed -> "failed")
  | F.Snapshot { revision; fleet; degraded; _ } ->
    Printf.sprintf "snapshot r%d running=%d degraded=%s" (F.Revision.to_int revision)
      fleet.F.fs_running_count
      (match degraded with
       | None -> "no"
       | Some { F.reason = F.Scan_timed_out; _ } -> "timed_out"
       | Some { F.reason = F.Scan_failed; _ } -> "failed")
  | F.Changed { revision; fleet; _ } ->
    Printf.sprintf "changed r%d running=%d" (F.Revision.to_int revision)
      fleet.F.fs_running_count
  | F.Degraded { revision; degradation } ->
    Printf.sprintf "degraded r%d %s" (F.Revision.to_int revision)
      (match degradation.F.reason with
       | F.Scan_timed_out -> "timed_out"
       | F.Scan_failed -> "failed")
;;

let test_the_cached_snapshot_publishes_to_the_hub () =
  with_server_state (fun state ->
  Refresh.reset_full_health_snapshot ();
  let hub = hub_for state (Masc.Mcp_server.workspace_scope state) in
  let seen = ref [] in
  let (_ : unit -> unit) =
    Hub.subscribe hub ~on_event:(fun event ->
      seen := describe event :: !seen)
  in
  let told () = List.rev !seen in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let scan fields =
        Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () -> Ok fields)
      in
      scan (health_fields (`Assoc [ "status", `String "warming"; "component_timed_out", `Bool false ]));
      check (list string) "warming is not a failure" [] (told ());
      let initial_error = health_fields
          (`Assoc [ "status", `String "error"; "component_timed_out", `Bool false ]) in
      scan initial_error;
      check (list string) "first section error is visible without a reading"
        [ "unavailable r1 failed" ] (told ());
      let initial = Hub.current hub in
      scan initial_error;
      check bool "first outage keeps its original time" true
        (initial = Hub.current hub);
      let late_initial = ref [] in
      let unsubscribe_initial = Hub.subscribe hub
          ~on_event:(fun event -> late_initial := describe event :: !late_initial) in
      check (list string) "first failure is visible on reconnect" [ "unavailable r1 failed" ] !late_initial;
      unsubscribe_initial ();
      scan (health_fields (fleet_section ~running:1));
      check (list string) "the first reading recovers"
        [ "unavailable r1 failed"; "changed r2 running=1" ] (told ());
      scan (health_fields (fleet_section ~running:1));
      check int "the same reading makes no event" 2 (List.length (told ()));
      scan (health_fields (fleet_section ~running:2));
      check string "a different reading" "changed r3 running=2" (List.nth (told ()) 2);
      Refresh.mark_full_health_snapshot_failure (Proactive_refresh.Raised (Failure "scan raised"));
      check string "a failed scan" "degraded r4 failed" (List.nth (told ()) 3);
      Refresh.mark_full_health_snapshot_failure (Proactive_refresh.Raised (Failure "again"));
      check int "a second failure makes no event" 4 (List.length (told ()));
      scan (health_fields (fleet_section ~running:2));
      check string "the same reading ends the outage" "changed r5 running=2"
        (List.nth (told ()) 4);
      let section_error = health_fields
          (`Assoc [ "status", `String "error"; "component_timed_out", `Bool false ]) in
      scan section_error;
      check string "a failed fleet section degrades the last reading"
        "degraded r6 failed" (List.nth (told ()) 5);
      let before = Hub.current hub in
      scan section_error;
      check int "repeated section failure does not emit again" 6 (List.length (told ()));
      check bool "the original failure time remains stable" true
        (before = Hub.current hub);
      let late = ref [] in
      let unsubscribe = Hub.subscribe hub
          ~on_event:(fun event -> late := describe event :: !late) in
      check (list string) "a new subscriber sees the failed section"
        [ "snapshot r6 running=2 degraded=failed" ] !late;
      unsubscribe ();
      scan (health_fields (fleet_section ~running:2));
      check string "the same fleet recovers after a section error"
        "changed r7 running=2" (List.nth (told ()) 6);
      scan (health_fields (`Assoc [ "status", `String "timeout"; "component_timed_out", `Bool true ]));
      check string "a timed out section is reported"
        "degraded r8 timed_out" (List.nth (told ()) 7);
      scan (health_fields (fleet_section ~running:2));
      check string "a timed out section recovers" "changed r9 running=2" (List.nth (told ()) 8);
      scan (health_fields (`Assoc [ "schema", `String Masc.Keeper_fleet_blocker.reading_schema ]));
      check string "an unreadable section is reported"
        "degraded r10 failed" (List.nth (told ()) 9);
      scan (health_fields (fleet_section ~running:2));
      check string "an unreadable section recovers" "changed r11 running=2" (List.nth (told ()) 10);
      Refresh.mark_full_health_snapshot_failure
        (Proactive_refresh.Timed_out
           { Proactive_refresh.label = "full_health_snapshot"
           ; phase = Proactive_refresh.Refresh
           ; timeout_s = 30.0
           ; elapsed_s = 31.0
           });
      check string "a scan that ran out of time" "degraded r12 timed_out"
        (List.nth (told ()) 11);
      (* No reading does not replace an existing outage. *)
      scan [ "overall_status", `String "ok" ];
      scan
        (health_fields
           (`Assoc [ "status", `String "warming"; "component_timed_out", `Bool false ]));
      scan
        (health_fields
           (`Assoc [ "schema", `String Masc.Keeper_fleet_blocker.reading_schema ]));
      check int "nothing came of them" 12 (List.length (told ()));
      match Hub.current hub with
      | Some state ->
        check string "the state is still the outage"
          "snapshot r12 running=2 degraded=timed_out" (describe state)
      | None -> fail "no state")))
;;

let test_scope_replacement_rejects_old_scan_and_failure () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let old_scope = Masc.Mcp_server.workspace_scope state in
    let old_hub = hub_for state old_scope in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let scan running =
          Refresh.run_full_health_refresh_worker ~sw
            ~compute:(fun () -> Ok (health_fields (fleet_section ~running)))
        in
        scan 1;
        let old_reading = Hub.current old_hub in
        check bool "the first scope has a reading" true (Option.is_some old_reading);
        let started, start = Eio.Promise.create () in
        let continue, resume = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await continue;
            Ok (health_fields (fleet_section ~running:9)));
          Eio.Promise.resolve finish ());
        Eio.Promise.await started;
        let other_config =
          { old_scope.config with
            workspace_path = Filename.concat old_scope.config.workspace_path "other-workspace" }
        in
        (match Masc.Mcp_server.set_workspace_config state other_config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        let other_scope = Masc.Mcp_server.workspace_scope state in
        let other_hub = hub_for state other_scope in
        check bool "the intermediate scope starts without the old reading" true
          (Option.is_none (Hub.current other_hub));
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        let new_scope = Masc.Mcp_server.workspace_scope state in
        check bool "returning to the same path changes the epoch" false
          (Masc.Mcp_server.Workspace_scope_epoch.equal old_scope.epoch new_scope.epoch);
        check bool "the old scope cannot obtain a hub" true
          (Option.is_none
             (Server_routes_http_runtime.fleet_stream_hub_for_scope ~state ~scope:old_scope));
        let new_hub = hub_for state new_scope in
        check bool "the returned scope uses a new hub" false (new_hub == other_hub);
        check bool "the new scope starts without the old reading" true
          (Option.is_none (Hub.current new_hub));
        Refresh.mark_full_health_refresh_wait_failure
          (Proactive_refresh.Raised (Failure "old worker timed out"));
        (match Hub.current new_hub with
         | Some event -> check string "the blocked shared refresh is unavailable"
             "unavailable r1 failed" (describe event)
         | None -> fail "the new scope did not report the blocked refresh");
        Eio.Promise.resolve resume ();
        Eio.Promise.await finished;
        (match Hub.current new_hub with
         | Some event -> check string "the old scan cannot populate the new scope"
             "unavailable r1 failed" (describe event)
         | None -> fail "the new scope lost its unavailable state");
        check bool "the replaced hub keeps its prior state" true
          (old_reading = Hub.current old_hub);
        scan 2;
        match Hub.current new_hub with
        | Some event -> check string "a new-scope scan supplies its first reading"
            "snapshot r2 running=2 degraded=no" (describe event)
        | None -> fail "new scope has no reading")))
;;

let test_worker_begins_after_scope_replacement ?(early_timeout = false)
    ?(subscribe_after_start = false) ~timeout () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let old_scope = Masc.Mcp_server.workspace_scope state in
    ignore (hub_for state old_scope : Hub.t);
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let admitted, admit = Eio.Promise.create () in
        let begin_scan, begin_ = Eio.Promise.create () in
        let scanning, started = Eio.Promise.create () in
        let finish_scan, finish_ = Eio.Promise.create () in
        let done_, done_resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          (try
             Refresh.run_full_health_refresh_worker_before_scope ~sw
               ~before_scope:(fun () ->
                 Eio.Promise.resolve admit ();
                 Eio.Promise.await begin_scan)
               ~compute:(fun () ->
                 Eio.Promise.resolve started ();
                 Eio.Promise.await finish_scan;
                 if timeout then Ok (health_fields (fleet_section ~running:2))
                 else failwith "new-scope scan failed")
           with
           | Failure message when not timeout && String.equal message "new-scope scan failed" -> ()
           | exn -> raise exn);
          Eio.Promise.resolve done_resolver ());
        Eio.Promise.await admitted;
        if early_timeout then
          Refresh.mark_full_health_refresh_wait_failure
            (Proactive_refresh.Timed_out
               { Proactive_refresh.label = "full_health_snapshot"
               ; phase = Proactive_refresh.Refresh
               ; timeout_s = 1.; elapsed_s = 1. });
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        if subscribe_after_start then begin
          Eio.Promise.resolve begin_ ();
          Eio.Promise.await scanning
        end;
        let new_hub = hub_for state (Masc.Mcp_server.workspace_scope state) in
        if early_timeout then
          (match Hub.current new_hub with
           | Some event -> check string "a new scope sees the timed-out shared wait"
               "unavailable r1 timed_out" (describe event)
           | None -> fail "the new scope did not report its blocked refresh");
        if not subscribe_after_start then begin
          Eio.Promise.resolve begin_ ();
          Eio.Promise.await scanning
        end;
        if timeout then begin
          Refresh.mark_full_health_refresh_wait_failure
            (Proactive_refresh.Timed_out
               { Proactive_refresh.label = "full_health_snapshot"
               ; phase = Proactive_refresh.Refresh
               ; timeout_s = 1.; elapsed_s = 1. });
          if early_timeout then begin
            check string "the new workspace records its own timeout" "timeout" (full_health_status ());
            check int "the old timeout is excluded" 1 (Refresh.full_health_observation_failures ());
            Refresh.mark_full_health_refresh_wait_failure
              (Proactive_refresh.Timed_out
                 { Proactive_refresh.label = "full_health_snapshot"
                 ; phase = Proactive_refresh.Refresh
                 ; timeout_s = 1.; elapsed_s = 1. });
            check int "a repeated wait does not count twice" 1 (Refresh.full_health_observation_failures ())
          end;
          (match Hub.current new_hub with
           | Some event -> check string "the new-scope timeout is visible"
               "unavailable r1 timed_out" (describe event)
           | None -> fail "the new-scope timeout was not published")
        end;
        Eio.Promise.resolve finish_ ();
        Eio.Promise.await done_;
        if early_timeout && timeout then
          check int "a successful new-scope scan recovers" 0 (Refresh.full_health_observation_failures ());
        if early_timeout && not timeout then begin
          check string "the new workspace records its own failure" "error" (full_health_status ());
          check int "the new failure counts once" 1 (Refresh.full_health_observation_failures ())
        end;
        if not timeout then
          match Hub.current new_hub with
          | Some event -> check string "the new-scope exception is visible"
              (if early_timeout then "unavailable r1 timed_out" else "unavailable r1 failed")
              (describe event)
          | None -> fail "the new-scope exception was not published")))
;;

let test_old_wait_failure_does_not_degrade_a_new_reading () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let old_scope = Masc.Mcp_server.workspace_scope state in
    ignore (hub_for state old_scope : Hub.t);
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let waiting, wait_resolver = Eio.Promise.create () in
        let release, release_resolver = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker_before_scope ~sw
            ~before_scope:(fun () ->
              Eio.Promise.resolve wait_resolver ();
              Eio.Promise.await release)
            ~compute:(fun () -> Ok (health_fields (fleet_section ~running:2)));
          Eio.Promise.resolve finish ());
        Eio.Promise.await waiting;
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        let hub = hub_for state (Masc.Mcp_server.workspace_scope state) in
        let fleet =
          match Masc.Fleet_stream_health_section.fleet_of_health_fields
              (health_fields (fleet_section ~running:7)) with
          | Ok fleet -> fleet
          | Error error -> fail (Masc.Fleet_stream_health_section.error_to_string error)
        in
        Hub.observe hub ~measured_at:1. fleet;
        Refresh.mark_full_health_refresh_wait_failure
          (Proactive_refresh.Raised (Failure "old scope blocked"));
        (match Hub.current hub with
         | Some event -> check string "old wait failure cannot degrade a new reading"
             "snapshot r1 running=7 degraded=no" (describe event)
         | None -> fail "new reading was lost");
        Eio.Promise.resolve release_resolver ();
        Eio.Promise.await finished)))
;;

let test_late_demand_does_not_inherit_a_settled_worker_failure () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let old_scope = Masc.Mcp_server.workspace_scope state in
    ignore (hub_for state old_scope : Hub.t);
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let scanning, started = Eio.Promise.create () in
        let finish_scan, finish_ = Eio.Promise.create () in
        let settled, settle = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve started ();
            Eio.Promise.await finish_scan;
            Error (Proactive_refresh.Raised (Failure "old scan failed")));
          Eio.Promise.resolve settle ());
        Eio.Promise.await scanning;
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        let new_scope = Masc.Mcp_server.workspace_scope state in
        let selected, select = Eio.Promise.create () in
        let register, register_ = Eio.Promise.create () in
        let selector = Domain.spawn (fun () ->
          Eio_main.run (fun _ ->
            Refresh.fleet_stream_hub_for_scope_before_registration
              ~state ~scope:new_scope ~before_registration:(fun () ->
                Eio.Promise.resolve select ();
                Eio.Promise.await register)))
        in
        Eio.Promise.await selected;
        Eio.Promise.resolve finish_ ();
        Eio.Promise.await settled;
        Eio.Promise.resolve register_ ();
        let hub = match Domain.join selector with
          | Some hub -> hub
          | None -> fail "the new scope was unexpectedly rejected"
        in
        check bool "a demand admitted after settlement does not inherit the old failure" true
          (Option.is_none (Hub.current hub)))))
;;

let test_subscriber_joins_a_current_scan_without_requesting_another () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let scanning, started = Eio.Promise.create () in
        let finish_scan, finish_ = Eio.Promise.create () in
        let settled, settle = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve started ();
            Eio.Promise.await finish_scan;
            Ok (health_fields (fleet_section ~running:4)));
          Eio.Promise.resolve settle ());
        Eio.Promise.await scanning;
        let _, _, _, generation_before, _, _ = Refresh.full_health_refresh_worker_stats () in
        let hub = hub_for state (Masc.Mcp_server.workspace_scope state) in
        let _, _, _, generation_after, _, _ = Refresh.full_health_refresh_worker_stats () in
        check int "joining a current scan does not invalidate it" generation_before generation_after;
        Eio.Promise.resolve finish_ ();
        Eio.Promise.await settled;
        (match Hub.current hub with
         | Some event -> check string "the joined scan supplies the snapshot"
             "snapshot r1 running=4 degraded=no" (describe event)
         | None -> fail "the joined scan did not supply a reading");
        let _, _, _, _, _, requested = Refresh.full_health_refresh_worker_stats () in
        check bool "the join did not request a successor scan" false requested)))
;;

let test_worker_fails_before_scan ~timeout () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let hub = hub_for state (Masc.Mcp_server.workspace_scope state) in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let waiting, wait_resolver = Eio.Promise.create () in
        let release, release_resolver = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          (try
             Refresh.run_full_health_refresh_worker_before_scope ~sw
               ~before_scope:(fun () ->
                 Eio.Promise.resolve wait_resolver ();
                 Eio.Promise.await release;
                 if not timeout then failwith "scan never started")
               ~compute:(fun () -> Ok (health_fields (fleet_section ~running:3)))
           with
           | Failure message when not timeout && String.equal message "scan never started" -> ()
           | exn -> raise exn);
          Eio.Promise.resolve finish ());
        Eio.Promise.await waiting;
        if timeout then begin
          Refresh.mark_full_health_refresh_wait_failure
            (Proactive_refresh.Timed_out
               { Proactive_refresh.label = "full_health_snapshot"
               ; phase = Proactive_refresh.Refresh
               ; timeout_s = 1.; elapsed_s = 1. });
          (match Hub.current hub with
           | Some event -> check string "waiting timeout reaches the admitted scope"
               "unavailable r1 timed_out" (describe event)
           | None -> fail "waiting timeout was not published")
        end;
        Eio.Promise.resolve release_resolver ();
        Eio.Promise.await finished;
        if not timeout then
          match Hub.current hub with
          | Some event -> check string "pre-scan exception reaches the admitted scope"
              "unavailable r1 failed" (describe event)
          | None -> fail "pre-scan exception was not published")))
;;

let test_full_health_cache_is_scoped_to_the_workspace_generation () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    let original = Masc.Mcp_server.workspace_scope state in
    let other_config =
      { original.config with
        workspace_path = Filename.concat original.config.workspace_path "other-workspace" }
    in
    let switch config =
      match Masc.Mcp_server.set_workspace_config state config with
      | Ok () -> ()
      | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error)
    in
    let authority =
      match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
      | Ok authority -> authority
      | Error `Malformed -> fail "invalid test authority"
    in
    let read () =
      Server_routes_http_runtime.make_health_response_json ~request_authority:authority
        (Httpun.Request.create `GET "/health?full=1")
    in
    let field key json = Yojson.Safe.Util.member key json in
    let status json = field "status" (field "full_health_snapshot" json) in
    let fields marker =
      ("scope_test_marker", `String marker) :: health_fields (fleet_section ~running:1)
    in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let scan marker =
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () -> Ok (fields marker))
        in
        scan "A";
        check bool "A is served in its own scope" true
          (field "scope_test_marker" (read ()) = `String "A");
        switch other_config;
        let warming = read () in
        check bool "B does not see A's fields" true (field "scope_test_marker" warming = `Null);
        check bool "B starts warming" true (status warming = `String "warming");
        Refresh.mark_full_health_snapshot_failure (Proactive_refresh.Raised (Failure "B failed"));
        let failed = read () in
        check bool "B's cold failure does not retain A" true
          (field "scope_test_marker" failed = `Null);
        check bool "B sees its own failure" true (status failed = `String "error");
        scan "B";
        check bool "B serves its own reading" true
          (field "scope_test_marker" (read ()) = `String "B");
        let started, start = Eio.Promise.create () in
        let resume, release = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await resume;
            Ok (fields "late-B"));
          Eio.Promise.resolve finish ());
        Eio.Promise.await started;
        switch original.config;
        let returned = read () in
        check bool "returning to A starts a new generation" true
          (field "scope_test_marker" returned = `Null && status returned = `String "warming");
        Eio.Promise.resolve release ();
        Eio.Promise.await finished;
        let after_old_worker = read () in
        check bool "late B worker cannot publish into the new A" true
          (field "scope_test_marker" after_old_worker = `Null
           && status after_old_worker = `String "warming");
        scan "new-A";
        check bool "new A serves its own reading" true
          (field "scope_test_marker" (read ()) = `String "new-A");
        let started, start = Eio.Promise.create () in
        let resume, release = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await resume;
            Ok (fields "server-removed"));
          Eio.Promise.resolve finish ());
        Eio.Promise.await started;
        Server_auth.For_testing.restore_server_state None;
        Eio.Promise.resolve release ();
        Eio.Promise.await finished;
        let without_server = read () in
        check bool "a changed-to-absent scope is not an unscoped scan" true
          (field "scope_test_marker" without_server = `Null
           && status without_server = `String "warming");
        Server_auth.For_testing.restore_server_state (Some state);
        check bool "the interrupted scan did not replace A's good reading" true
          (field "scope_test_marker" (read ()) = `String "new-A"))))
;;

let test_new_scope_health_request_survives_old_worker () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    ignore (Refresh.take_full_health_wakeup_nonblocking ());
    let old_scope = Masc.Mcp_server.workspace_scope state in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let started, start = Eio.Promise.create () in
        let resume, release = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await resume;
            Ok (health_fields (fleet_section ~running:1)));
          Eio.Promise.resolve finish ());
        Eio.Promise.await started;
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        check string "the new scope starts warming" "warming" (full_health_status ());
        let _, _, _, _, _, requested = Refresh.full_health_refresh_worker_stats () in
        check bool "the new scope requests a refresh" true requested;
        check bool "the new-scope read wakes the worker" true
          (Refresh.take_full_health_wakeup_nonblocking ());
        Eio.Promise.resolve release ();
        Eio.Promise.await finished;
        let _, _, _, _, _, requested = Refresh.full_health_refresh_worker_stats () in
        check bool "old completion retains the new request" true requested;
        check bool "old completion wakes a successor" true
          (Refresh.take_full_health_wakeup_nonblocking ());
        Refresh.run_full_health_refresh_worker ~sw
          ~compute:(fun () -> Ok (health_fields (fleet_section ~running:2)));
        check string "the successor publishes for the new scope" "ready" (full_health_status ()))))
;;

let test_new_scope_first_health_read_wakes_after_old_worker () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    ignore (Refresh.take_full_health_wakeup_nonblocking ());
    let old_scope = Masc.Mcp_server.workspace_scope state in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let started, start = Eio.Promise.create () in
        let resume, release = Eio.Promise.create () in
        let finished, finish = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await resume;
            Ok (health_fields (fleet_section ~running:1)));
          Eio.Promise.resolve finish ());
        Eio.Promise.await started;
        (match Masc.Mcp_server.set_workspace_config state old_scope.config with
         | Ok () -> ()
         | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
        Eio.Promise.resolve release ();
        Eio.Promise.await finished;
        ignore (Refresh.take_full_health_wakeup_nonblocking ());
        check string "B starts warming after the old worker" "warming" (full_health_status ());
        check bool "B's first read wakes its own refresh" true
          (Refresh.take_full_health_wakeup_nonblocking ());
        Refresh.run_full_health_refresh_worker ~sw
          ~compute:(fun () -> Ok (health_fields (fleet_section ~running:2)));
        check string "the new-scope scan publishes" "ready" (full_health_status ()))))
;;

let test_health_read_keeps_its_selected_snapshot () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    ignore (Refresh.take_full_health_wakeup_nonblocking ());
    let old_scope = Masc.Mcp_server.workspace_scope state in
    let authority =
      match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
      | Ok authority -> authority
      | Error `Malformed -> fail "invalid test authority"
    in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        Refresh.run_full_health_refresh_worker ~sw
          ~compute:(fun () -> Ok (("scope_test_marker", `String "A")
                                  :: health_fields (fleet_section ~running:1)));
        let result =
          Refresh.make_cached_full_health_json_after_selection
            ~after_selection:(fun () ->
              match Masc.Mcp_server.set_workspace_config state old_scope.config with
              | Ok () -> ()
              | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error))
            ~request_authority:authority (Httpun.Request.create `GET "/health?full=1")
        in
        let open Yojson.Safe.Util in
        check bool "the in-flight read retains its selected A snapshot" true
          (result |> member "scope_test_marker" = `String "A");
        check string "the same selection supplies its metadata" "ready"
          (result |> member "full_health_snapshot" |> member "status" |> to_string);
        check string "the next read selects B" "warming" (full_health_status ());
        check bool "the B read wakes its refresh" true
          (Refresh.take_full_health_wakeup_nonblocking ());
        Refresh.run_full_health_refresh_worker ~sw
          ~compute:(fun () -> Ok (health_fields (fleet_section ~running:2)));
        check string "B becomes ready" "ready" (full_health_status ()))))
;;

let test_new_scope_wakeup_runs_a_refresh_loop_successor () =
  with_server_state (fun state ->
    Refresh.reset_full_health_snapshot ();
    ignore (Refresh.take_full_health_wakeup_nonblocking ());
    let old_scope = Masc.Mcp_server.workspace_scope state in
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let started, start = Eio.Promise.create () in
      let resume, release = Eio.Promise.create () in
      let successor, finish_successor = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      let scans = ref 0 in
      Eio.Time.with_timeout_exn clock 8. (fun () ->
        Eio.Fiber.first
          (fun () ->
            Eio.Switch.run (fun sw ->
              let config =
                { (Proactive_refresh.default_config ~label:"fleet-health-scope-test"
                     ~interval_s:60.) with
                  timeout_s = 5.
                ; wakeup = Some (Refresh.full_health_wakeup_stream ())
                ; wakeup_coalesce_s = Refresh.full_health_refresh_wakeup_coalesce_sec ()
                }
              in
              Proactive_refresh.start ~sw ~clock ~config ~on_result:Fun.id
                ~compute:(fun () ->
                  Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () ->
                    incr scans;
                    if !scans = 1 then begin
                      Eio.Promise.resolve start ();
                      Eio.Promise.await resume;
                      Ok (health_fields (fleet_section ~running:1))
                    end else Ok (health_fields (fleet_section ~running:2)));
                  if !scans >= 2 then ignore (Eio.Promise.try_resolve finish_successor ())) ;
              Eio.Promise.await never))
          (fun () ->
            Eio.Promise.await started;
            (match Masc.Mcp_server.set_workspace_config state old_scope.config with
             | Ok () -> ()
             | Error error -> fail (Masc.Mcp_server.workspace_switch_error_to_string error));
            let _, joins_before, _, _, _, _ = Refresh.full_health_refresh_worker_stats () in
            check string "B is warming while A runs" "warming" (full_health_status ());
            let rec await_join () =
              let _, joins, _, _, _, _ = Refresh.full_health_refresh_worker_stats () in
              if joins <= joins_before then (Eio.Fiber.yield (); await_join ())
            in
            await_join ();
            Eio.Promise.resolve release ();
            Eio.Promise.await successor;
            check string "the loop publishes B without waiting for the interval"
              "ready" (full_health_status ());
            let open Yojson.Safe.Util in
            check int "the published fleet came from B's scan" 2
              (read_full_health () |> member "keeper_fleet_safety"
               |> member "running_keeper_fiber_count" |> to_int)))))
;;

let () =
  run "fleet_stream_server_wiring"
    [ ( "publishing"
      , [ test_case "the cached snapshot publishes to the hub" `Quick
            test_the_cached_snapshot_publishes_to_the_hub
        ; test_case "full health cache belongs to one workspace generation" `Quick
            test_full_health_cache_is_scoped_to_the_workspace_generation
        ; test_case "new health demand survives the old worker" `Quick
            test_new_scope_health_request_survives_old_worker
        ; test_case "first new health read wakes after the old worker" `Quick
            test_new_scope_first_health_read_wakes_after_old_worker
        ; test_case "a health read keeps one selected snapshot" `Quick
            test_health_read_keeps_its_selected_snapshot
        ; test_case "refresh loop runs a successor for the new scope" `Quick
            test_new_scope_wakeup_runs_a_refresh_loop_successor
        ; test_case "scope replacement rejects old scan and failure" `Quick
            test_scope_replacement_rejects_old_scan_and_failure
        ; test_case "a new-scope scan reports its timeout" `Quick
            (test_worker_begins_after_scope_replacement ~timeout:true)
        ; test_case "a new-scope timeout remains visible after an old-scope timeout" `Quick
            (test_worker_begins_after_scope_replacement ~early_timeout:true ~timeout:true)
        ; test_case "old-scope wait failure is retained when the new scan already began" `Quick
            (test_worker_begins_after_scope_replacement ~early_timeout:true
               ~subscribe_after_start:true ~timeout:true)
        ; test_case "a new-scope scan reports its exception" `Quick
            (test_worker_begins_after_scope_replacement ~timeout:false)
        ; test_case "a new-scope exception follows the old wait timeout" `Quick
            (test_worker_begins_after_scope_replacement ~early_timeout:true ~timeout:false)
        ; test_case "a same-scope pre-scan wait reports timeout" `Quick
            (test_worker_fails_before_scan ~timeout:true)
        ; test_case "a same-scope pre-scan exception is visible" `Quick
            (test_worker_fails_before_scan ~timeout:false)
        ; test_case "an old wait cannot degrade a new reading" `Quick
            test_old_wait_failure_does_not_degrade_a_new_reading
        ; test_case "late demand cannot inherit a settled worker failure" `Quick
            test_late_demand_does_not_inherit_a_settled_worker_failure
        ; test_case "a subscriber joins the current scan without requesting another" `Quick
            test_subscriber_joins_a_current_scan_without_requesting_another
        ] )
    ]
;;
