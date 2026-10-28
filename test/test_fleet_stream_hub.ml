open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Grade = Masc.Keeper_fleet_grade

let fleet ?(running = 1) () : F.fleet =
  { F.fs_status = Grade.Fleet_ok
  ; fs_blocker = None
  ; fs_operator_action_required = false
  ; fs_bootable_count = 0
  ; fs_running_count = running
  ; fs_executable_count = 0
  ; fs_failing_count = 0
  ; fs_recovering_count = 0
  ; fs_turn_configuration_error_count = 0
  ; fs_official_client_recovery_required_count = 0
  ; fs_paused_count = 0
  ; fs_target_reaction_capacity = 0
  ; fs_reaction_capacity_shortfall = 0
  ; fs_bootable_names = F.Names.empty
  ; fs_running_names = F.Names.empty
  ; fs_executable_names = F.Names.empty
  ; fs_turn_configuration_error_names = F.Names.empty
  ; fs_official_client_recovery_required_names = F.Names.empty
  ; fs_active_task_owner_without_fiber_count = 0
  ; fs_completion_authority_pending_count = 0
  ; fs_active_task_owner_scan_error_count = 0
  }
;;

let revision n =
  match F.Revision.of_int n with
  | Some revision -> revision
  | None -> failf "revision %d" n
;;

let event_t =
  testable
    (fun fmt event ->
       Format.pp_print_string fmt (Yojson.Safe.to_string (F.encode event)))
    ( = )
;;

(* Collects what a subscriber is told. *)
let recorder () =
  let seen = ref [] in
  (fun event -> seen := event :: !seen), fun () -> List.rev !seen
;;

let hub_with_error_log () =
  let errors = ref [] in
  let hub = Hub.create ~on_subscriber_error:(fun exn -> errors := exn :: !errors) in
  hub, fun () -> List.rev !errors
;;

let snapshot ~revision:n ~measured_at ?degraded fleet =
  F.Snapshot { revision = revision n; measured_at; fleet; degraded }
;;

let test_a_waiting_subscriber_gets_the_first_reading_as_a_snapshot () =
  let hub, _ = hub_with_error_log () in
  let on_event, seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event in
  check (list event_t) "nothing before a reading" [] (seen ());
  check (option event_t) "no state yet" None (Hub.current hub);
  Hub.observe hub ~measured_at:10.0 (fleet ());
  check (list event_t) "the Snapshot" [ snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ] (seen ())
;;

let test_a_late_subscriber_starts_from_the_current_state () =
  let hub, _ = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
  Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
  let on_event, seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event in
  check (list event_t) "the current Snapshot, at once"
    [ snapshot ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()) ]
    (seen ());
  check (option event_t) "current" (Some (snapshot ~revision:2 ~measured_at:20.0 (fleet ~running:2 ())))
    (Hub.current hub)
;;

let test_a_reading_that_changes_nothing_makes_no_event () =
  let hub, _ = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ());
  let on_event, seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event in
  Hub.observe hub ~measured_at:20.0 (fleet ());
  Hub.observe hub ~measured_at:30.0 (fleet ());
  check int "only the Snapshot" 1 (List.length (seen ()));
  let late, late_seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:late in
  check (list event_t) "a later subscriber is told the latest scan time"
    [ snapshot ~revision:1 ~measured_at:30.0 (fleet ()) ]
    (late_seen ())
;;

let test_a_different_reading_makes_the_next_revision () =
  let hub, _ = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
  let on_event, seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event in
  Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
  Hub.observe hub ~measured_at:30.0 (fleet ~running:3 ());
  check (list event_t) "Snapshot then two changes"
    [ snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())
    ; F.Changed { revision = revision 2; measured_at = 20.0; fleet = fleet ~running:2 () }
    ; F.Changed { revision = revision 3; measured_at = 30.0; fleet = fleet ~running:3 () }
    ]
    (seen ())
;;

let test_an_outage_is_told_once_and_ends_with_a_change () =
  let hub, _ = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ());
  let on_event, seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event in
  Hub.note_degraded hub ~since:20.0 F.Scan_timed_out;
  Hub.note_degraded hub ~since:25.0 F.Scan_failed;
  let outage = { F.since = 20.0; reason = F.Scan_timed_out } in
  check (list event_t) "one Degraded, with the first failure"
    [ snapshot ~revision:1 ~measured_at:10.0 (fleet ())
    ; F.Degraded { revision = revision 2; degradation = outage }
    ]
    (seen ());
  let during, during_seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:during in
  check (list event_t) "a subscriber that connects during the outage is told"
    [ snapshot ~revision:2 ~measured_at:10.0 ~degraded:outage (fleet ()) ]
    (during_seen ());
  Hub.observe hub ~measured_at:40.0 (fleet ());
  check (list event_t) "the same reading still ends it"
    [ F.Changed { revision = revision 3; measured_at = 40.0; fleet = fleet () } ]
    (List.filteri (fun index _ -> index >= 2) (seen ()));
  check (list event_t) "and the one connected during it hears it too"
    [ snapshot ~revision:2 ~measured_at:10.0 ~degraded:outage (fleet ())
    ; F.Changed { revision = revision 3; measured_at = 40.0; fleet = fleet () }
    ]
    (during_seen ());
  Hub.note_degraded hub ~since:50.0 F.Scan_failed;
  check (option event_t) "a new outage is new"
    (Some (snapshot ~revision:4 ~measured_at:40.0
             ~degraded:{ F.since = 50.0; reason = F.Scan_failed } (fleet ())))
    (Hub.current hub)
;;

let test_first_failure_is_a_snapshot_and_first_reading_recovers () =
  let hub, _ = hub_with_error_log () in
  let on_event, seen = recorder () in
  let unsubscribe = Hub.subscribe hub ~on_event in
  Hub.note_degraded hub ~since:5.0 F.Scan_failed;
  let outage = { F.since = 5.0; reason = F.Scan_failed } in
  let initial = F.Unavailable_snapshot { revision = revision 1; degradation = outage } in
  check (list event_t) "waiting subscriber sees first failure" [ initial ] (seen ());
  Hub.note_degraded hub ~since:6.0 F.Scan_timed_out;
  check (option event_t) "first failure remains current" (Some initial) (Hub.current hub);
  unsubscribe ();
  let on_reconnect, reconnected = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:on_reconnect in
  check (list event_t) "reconnect sees the same failure" [ initial ] (reconnected ());
  Hub.observe hub ~measured_at:10.0 (fleet ());
  check (list event_t) "first reading advances revision and recovers"
    [ initial; F.Changed { revision = revision 2; measured_at = 10.0; fleet = fleet () } ]
    (reconnected ());
  check (option event_t) "later subscribers see a measured snapshot"
    (Some (snapshot ~revision:2 ~measured_at:10.0 (fleet ()))) (Hub.current hub)
;;

let test_unsubscribing_stops_the_events () =
  let hub, _ = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
  let leaving, leaving_seen = recorder () in
  let staying, staying_seen = recorder () in
  let unsubscribe = Hub.subscribe hub ~on_event:leaving in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:staying in
  unsubscribe ();
  unsubscribe ();
  Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
  check int "the one that left" 1 (List.length (leaving_seen ()));
  check int "the one that stayed" 2 (List.length (staying_seen ()))
;;

let test_a_subscriber_that_raises_is_removed_and_reported () =
  let hub, errors = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
  let calls = ref 0 in
  let broken event =
    incr calls;
    match event with
    | F.Snapshot _ -> ()
    | F.Unavailable_snapshot _ | F.Changed _ | F.Degraded _ -> failwith "full"
  in
  let healthy, healthy_seen = recorder () in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:broken in
  let (_ : unit -> unit) = Hub.subscribe hub ~on_event:healthy in
  Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
  Hub.observe hub ~measured_at:30.0 (fleet ~running:3 ());
  check int "the broken one was called for the Snapshot and one change" 2 !calls;
  check int "it was reported once" 1 (List.length (errors ()));
  check int "the healthy one heard everything" 3 (List.length (healthy_seen ()))
;;

let test_a_subscriber_that_raises_on_its_snapshot_is_not_registered () =
  let hub, errors = hub_with_error_log () in
  Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
  let calls = ref 0 in
  let unsubscribe =
    Hub.subscribe hub ~on_event:(fun _ ->
      incr calls;
      failwith "no room")
  in
  Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
  unsubscribe ();
  check int "called only for the Snapshot" 1 !calls;
  check int "reported" 1 (List.length (errors ()))
;;

(* Publishers on three domains and watchers that connect and leave while they
   run. Every watcher must see its Snapshot followed by consecutive revisions.
   A gap would mean a subscriber was registered between a Snapshot and the
   event that followed it. *)
let test_no_watcher_sees_a_gap_under_concurrent_publishers () =
  let hub, errors = hub_with_error_log () in
  Hub.observe hub ~measured_at:0.0 (fleet ~running:0 ());
  let publishing = Atomic.make true in
  let watcher () =
    let violations = ref 0 in
    let connections = ref 0 in
    while Atomic.get publishing do
      let last = ref None in
      let on_event event =
        let revision = F.revision_of_event event in
        (match event, !last with
         | (F.Snapshot _ | F.Unavailable_snapshot _), _ -> ()
         | (F.Changed _ | F.Degraded _), Some previous ->
           if not (F.Revision.is_next ~after:previous revision) then incr violations
         | (F.Changed _ | F.Degraded _), None -> incr violations);
        last := Some revision
      in
      let unsubscribe = Hub.subscribe hub ~on_event in
      incr connections;
      for _ = 1 to 200 do
        Domain.cpu_relax ()
      done;
      unsubscribe ()
    done;
    !violations, !connections
  in
  let watchers = List.init 2 (fun _ -> Domain.spawn watcher) in
  let per_publisher = 300 in
  let publishers =
    List.init 3 (fun p ->
      Domain.spawn (fun () ->
        for i = 1 to per_publisher do
          Hub.observe hub ~measured_at:(Float.of_int i) (fleet ~running:((p * 1000) + i) ())
        done))
  in
  List.iter Domain.join publishers;
  Atomic.set publishing false;
  let results = List.map Domain.join watchers in
  List.iter
    (fun (violations, connections) ->
       check int "no gap or stray event" 0 violations;
       check bool "the watcher connected at least once" true (connections > 0))
    results;
  check int "no subscriber failed" 0 (List.length (errors ()));
  (* Every reading differs from the one before it, so each is one event. *)
  match Hub.current hub with
  | Some (F.Snapshot { revision; _ }) ->
    check int "every reading made one revision" (1 + (3 * per_publisher))
      (F.Revision.to_int revision)
  | Some (F.Unavailable_snapshot _ | F.Changed _ | F.Degraded _) | None -> fail "no snapshot"
;;

let () =
  run "fleet_stream_hub"
    [ ( "events"
      , [ test_case "a waiting subscriber gets the first reading" `Quick
            test_a_waiting_subscriber_gets_the_first_reading_as_a_snapshot
        ; test_case "a late subscriber starts from the current state" `Quick
            test_a_late_subscriber_starts_from_the_current_state
        ; test_case "a reading that changes nothing makes no event" `Quick
            test_a_reading_that_changes_nothing_makes_no_event
        ; test_case "a different reading makes the next revision" `Quick
            test_a_different_reading_makes_the_next_revision
        ; test_case "an outage is told once and ends with a change" `Quick
            test_an_outage_is_told_once_and_ends_with_a_change
        ; test_case "first failure survives reconnect and recovers" `Quick
            test_first_failure_is_a_snapshot_and_first_reading_recovers
        ] )
    ; ( "subscribers"
      , [ test_case "unsubscribing stops the events" `Quick
            test_unsubscribing_stops_the_events
        ; test_case "a subscriber that raises is removed and reported" `Quick
            test_a_subscriber_that_raises_is_removed_and_reported
        ; test_case "a subscriber that raises on its snapshot is not registered" `Quick
            test_a_subscriber_that_raises_on_its_snapshot_is_not_registered
        ; test_case "no gap under concurrent publishers" `Quick
            test_no_watcher_sees_a_gap_under_concurrent_publishers
        ] )
    ]
;;
