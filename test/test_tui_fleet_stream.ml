open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Grade = Masc.Keeper_fleet_grade
module Client = Masc_tui_fleet_stream

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

let snapshot ?degraded ~revision:n ~measured_at fleet =
  F.Snapshot { revision = revision n; measured_at; fleet; degraded }
;;

let changed ~revision:n ~measured_at fleet =
  F.Changed { revision = revision n; measured_at; fleet }
;;

let degraded ~revision:n ~since reason =
  F.Degraded { revision = revision n; degradation = { F.since; reason } }
;;

(* The bytes the server writes for an event. *)
let frame_of_json event_json =
  Sse_wire.format_event_yojson ~id:1 event_json
;;

let frame event =
  Sse_wire.format_event_yojson
    ~id:(F.Revision.to_int (F.revision_of_event event))
    (F.encode event)
;;

let keepalive = ": keepalive\n\n"

let reading ?degraded ~revision:n ~measured_at fleet : Client.reading =
  { Client.revision = revision n; measured_at; fleet; degraded }
;;

let describe_view : Client.view -> string = function
  | Client.Awaiting_first_reading -> "awaiting first reading"
  | Client.Unreachable { since } -> Printf.sprintf "unreachable since %g" since
  | Client.Reading { reading; trouble } ->
    Printf.sprintf
      "reading r%d running=%d %s"
      (F.Revision.to_int reading.revision)
      reading.fleet.F.fs_running_count
      (match trouble with
       | None -> "no trouble"
       | Some (Client.Scans_failing { F.since; _ }) -> Printf.sprintf "scans failing since %g" since
       | Some (Client.Disconnected { since }) -> Printf.sprintf "disconnected since %g" since)
  | Client.Unavailable { degradation = { F.since; _ }; disconnected_since } ->
    Printf.sprintf "unavailable since %g, disconnected=%s" since
      (match disconnected_since with None -> "no" | Some at -> string_of_float at)
  | Client.Cannot_read (Client.Refused { status; _ }) -> Printf.sprintf "refused %d" status
  | Client.Cannot_read (Client.Schema_mismatch { expected; received }) ->
    Printf.sprintf "schema %d, expected %d" received expected
  | Client.Cannot_read (Client.Frame_rejected detail) -> "rejected: " ^ detail
;;

let view_t = testable (fun fmt view -> Format.pp_print_string fmt (describe_view view)) ( = )

let step_t =
  testable
    (fun fmt step ->
       Format.pp_print_string
         fmt
         (match step with
          | Client.Keep_reading -> "Keep_reading"
          | Client.Reconnect -> "Reconnect"))
    ( = )
;;

let following ?(trouble = None) reading : Client.view = Client.Reading { reading; trouble }

(* A client whose connection delivered these events. *)
let connected events =
  let client = Client.create () in
  Client.started client;
  List.iter
    (fun event ->
       check step_t "the events follow" Client.Keep_reading (Client.feed client (frame event)))
    events;
  client
;;

let test_a_client_that_has_read_nothing_awaits_the_first_reading () =
  let client = Client.create () in
  check view_t "new" Client.Awaiting_first_reading (Client.view client);
  Client.started client;
  check view_t "connected, nothing yet" Client.Awaiting_first_reading (Client.view client)
;;

(* A connection that never delivers a snapshot is not the wait for the first
   scan: the screen has to say the stream is down. *)
let test_a_loss_before_any_reading_is_unreachable_until_a_snapshot () =
  let client = Client.create () in
  Client.started client;
  Client.lost client ~now:5.0;
  check view_t "a loss before any reading" (Client.Unreachable { since = 5.0 })
    (Client.view client);
  Client.started client;
  check view_t "reconnecting keeps the loss" (Client.Unreachable { since = 5.0 })
    (Client.view client);
  Client.lost client ~now:9.0;
  check view_t "a repeated loss keeps the first time" (Client.Unreachable { since = 5.0 })
    (Client.view client);
  Client.started client;
  check step_t "the snapshot" Client.Keep_reading
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ()))));
  (match Client.view client with
   | Client.Reading { trouble = None; _ } -> ()
   | other -> fail ("a snapshot ends the loss: " ^ describe_view other))
;;

let test_an_unavailable_snapshot_ends_unreachable_too () =
  let outage = { F.since = 10.0; reason = F.Scan_failed } in
  let client = Client.create () in
  Client.started client;
  Client.lost client ~now:5.0;
  Client.started client;
  ignore
    (Client.feed
       client
       (frame (F.Unavailable_snapshot { revision = revision 1; degradation = outage }))
     : Client.step);
  check view_t "the connection is up and the scan is failing"
    (Client.Unavailable { degradation = outage; disconnected_since = None })
    (Client.view client)
;;

let test_a_refusal_shows_over_unreachable_until_a_snapshot_arrives () =
  let client = Client.create () in
  Client.started client;
  Client.lost client ~now:5.0;
  Client.started client;
  Client.refused client ~status:404 ~detail:"not found";
  Client.lost client ~now:7.0;
  check view_t "refused"
    (Client.Cannot_read (Client.Refused { status = 404; detail = "not found" }))
    (Client.view client);
  Client.started client;
  ignore
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:10.0 (fleet ()))) : Client.step);
  check view_t "a Snapshot ends both"
    (following (reading ~revision:1 ~measured_at:10.0 (fleet ())))
    (Client.view client)
;;

(* The producer sends [Degraded] only over a reading. One after an
   [Unavailable_snapshot] has no reading to mark, so the connection is not
   followed any further. *)
let test_an_outage_event_after_an_unavailable_snapshot_asks_for_a_new_connection () =
  let outage = { F.since = 10.0; reason = F.Scan_failed } in
  let client = Client.create () in
  Client.started client;
  check step_t "the unavailable snapshot" Client.Keep_reading
    (Client.feed
       client
       (frame (F.Unavailable_snapshot { revision = revision 1; degradation = outage })));
  check step_t "an outage with no reading to mark" Client.Reconnect
    (Client.feed client (frame (degraded ~revision:2 ~since:12.0 F.Scan_failed)));
  check view_t "the view stays unavailable"
    (Client.Unavailable { degradation = outage; disconnected_since = None })
    (Client.view client)
;;

(* The Keepers screen draws what the job that follows the stream posted. The
   view lives inside the following state, so a job that is gone leaves nothing
   behind: withdrawing the readings ends the follow and the screen with it. *)
let test_the_screen_draws_only_what_a_following_job_posted () =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  check view_t "no job" Client.Awaiting_first_reading (Masc_tui_types.fleet_stream_view state);
  let posted = following (reading ~revision:1 ~measured_at:10.0 (fleet ())) in
  state.Masc_tui_types.fleet_stream_reader <- Masc_tui_types.Fleet_stream_following posted;
  check view_t "the job's view" posted (Masc_tui_types.fleet_stream_view state);
  Masc_tui_types.suspend_workspace_readings state;
  check view_t "readings withdrawn" Client.Awaiting_first_reading
    (Masc_tui_types.fleet_stream_view state);
  check bool "and a job can start again" true
    (state.Masc_tui_types.fleet_stream_reader = Masc_tui_types.Fleet_stream_idle)
;;

let test_first_scan_failure_is_visible_until_a_real_reading () =
  let outage = { F.since = 10.0; reason = F.Scan_failed } in
  let client = Client.create () in
  Client.started client;
  check step_t "unavailable snapshot" Client.Keep_reading
    (Client.feed client (frame (F.Unavailable_snapshot { revision = revision 1; degradation = outage })));
  check view_t "no fabricated fleet"
    (Client.Unavailable { degradation = outage; disconnected_since = None }) (Client.view client);
  Client.lost client ~now:12.0;
  Client.started client;
  Client.lost client ~now:13.0;
  check view_t "scan failure and first connection loss survive reconnect"
    (Client.Unavailable { degradation = outage; disconnected_since = Some 12.0 }) (Client.view client);
  Client.started client;
  check step_t "unavailable snapshot after reconnect" Client.Keep_reading
    (Client.feed client (frame (F.Unavailable_snapshot { revision = revision 1; degradation = outage })));
  check view_t "reconnected, still no fleet"
    (Client.Unavailable { degradation = outage; disconnected_since = None }) (Client.view client);
  check step_t "first successful scan follows unavailable" Client.Keep_reading
    (Client.feed client (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))));
  check view_t "only the actual scan supplies counts"
    (following (reading ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))) (Client.view client)
;;

let test_restarted_server_unavailable_replaces_old_reading () =
  let client = connected [ snapshot ~revision:57 ~measured_at:10.0 (fleet ~running:3 ()) ] in
  let outage = { F.since = 30.0; reason = F.Scan_timed_out } in
  Client.lost client ~now:20.0;
  Client.started client;
  check step_t "new server's unavailable snapshot resets the cursor" Client.Keep_reading
    (Client.feed client (frame (F.Unavailable_snapshot { revision = revision 1; degradation = outage })));
  check view_t "old server counts are not attributed to the new server"
    (Client.Unavailable { degradation = outage; disconnected_since = None }) (Client.view client);
  check step_t "gap after unavailable reconnects" Client.Reconnect
    (Client.feed client (frame (changed ~revision:3 ~measured_at:31.0 (fleet ()))));
  check view_t "gap retains the last observed failure"
    (Client.Unavailable { degradation = outage; disconnected_since = None }) (Client.view client)
;;

let test_a_snapshot_then_changes_follow_the_server () =
  let client = Client.create () in
  Client.started client;
  check step_t "snapshot" Client.Keep_reading
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ()))));
  check view_t "snapshot"
    (following (reading ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())))
    (Client.view client);
  check step_t "change" Client.Keep_reading
    (Client.feed client (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))));
  check view_t "change"
    (following (reading ~revision:2 ~measured_at:20.0 (fleet ~running:2 ())))
    (Client.view client)
;;

let sequence =
  [ snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())
  ; changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ())
  ; degraded ~revision:3 ~since:25.0 F.Scan_timed_out
  ; changed ~revision:4 ~measured_at:40.0 (fleet ~running:2 ())
  ]
;;

let sequence_bytes = String.concat keepalive (List.map frame sequence)

let test_every_split_of_the_bytes_gives_the_same_view () =
  let final = following (reading ~revision:4 ~measured_at:40.0 (fleet ~running:2 ())) in
  let feed_in_pieces pieces =
    let client = Client.create () in
    Client.started client;
    List.iter
      (fun piece ->
         check step_t "no event is lost between chunks" Client.Keep_reading (Client.feed client piece))
      pieces;
    Client.view client
  in
  let length = String.length sequence_bytes in
  for offset = 0 to length do
    check view_t
      (Printf.sprintf "split at %d" offset)
      final
      (feed_in_pieces
         [ String.sub sequence_bytes 0 offset
         ; String.sub sequence_bytes offset (length - offset)
         ])
  done;
  check view_t "one byte at a time" final
    (feed_in_pieces (List.init length (fun index -> String.sub sequence_bytes index 1)))
;;

let test_a_gap_asks_for_a_new_connection_and_the_reading_stays () =
  let client = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ()) ] in
  check step_t "revision 3 after 1" Client.Reconnect
    (Client.feed client (frame (changed ~revision:3 ~measured_at:30.0 (fleet ~running:3 ()))));
  check view_t "the reading is the last one that followed"
    (following (reading ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())))
    (Client.view client);
  Client.lost client ~now:100.0;
  check view_t "once the connection is closed, it is down"
    (following
       ~trouble:(Some (Client.Disconnected { since = 100.0 }))
       (reading ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())))
    (Client.view client)
;;

let test_an_event_before_any_snapshot_asks_for_a_new_connection () =
  let client = Client.create () in
  Client.started client;
  check step_t "a change first" Client.Reconnect
    (Client.feed client (frame (changed ~revision:2 ~measured_at:20.0 (fleet ()))));
  check view_t "nothing was taken" Client.Awaiting_first_reading (Client.view client);
  check step_t "an outage first" Client.Reconnect
    (Client.feed client (frame (degraded ~revision:3 ~since:30.0 F.Scan_failed)))
;;

let test_a_repeated_or_older_revision_asks_for_a_new_connection () =
  let at_revision_two () =
    connected
      [ snapshot ~revision:1 ~measured_at:10.0 (fleet ())
      ; changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ())
      ]
  in
  check step_t "revision 2 again" Client.Reconnect
    (Client.feed
       (at_revision_two ())
       (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))));
  check step_t "revision 1 after 2" Client.Reconnect
    (Client.feed
       (at_revision_two ())
       (frame (changed ~revision:1 ~measured_at:5.0 (fleet ~running:5 ()))))
;;

let test_after_an_event_is_refused_nothing_is_followed_until_a_snapshot () =
  let after_snapshot () = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ] in
  let gap = after_snapshot () in
  check step_t "a gap" Client.Reconnect
    (Client.feed gap (frame (changed ~revision:3 ~measured_at:30.0 (fleet ~running:3 ()))));
  check step_t "the revision that would have followed 1 is not taken" Client.Reconnect
    (Client.feed gap (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))));
  check step_t "a Snapshot is" Client.Keep_reading
    (Client.feed gap (frame (snapshot ~revision:9 ~measured_at:40.0 (fleet ~running:4 ()))));
  check step_t "and then the stream follows it" Client.Keep_reading
    (Client.feed gap (frame (changed ~revision:10 ~measured_at:41.0 (fleet ~running:5 ()))));
  let bad = after_snapshot () in
  check step_t "a frame this build cannot read" Client.Reconnect (Client.feed bad "data: nope\n\n");
  check step_t "the revision that would have followed 1 is not taken either" Client.Reconnect
    (Client.feed bad (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))))
;;

let test_a_restarted_server_starts_over_at_revision_one () =
  let client = connected [ snapshot ~revision:57 ~measured_at:10.0 (fleet ~running:3 ()) ] in
  Client.lost client ~now:20.0;
  Client.started client;
  check step_t "the new connection's Snapshot" Client.Keep_reading
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:30.0 (fleet ~running:4 ()))));
  check view_t "taken whatever its number"
    (following (reading ~revision:1 ~measured_at:30.0 (fleet ~running:4 ())))
    (Client.view client);
  check step_t "and the stream goes on from it" Client.Keep_reading
    (Client.feed client (frame (changed ~revision:2 ~measured_at:31.0 (fleet ~running:5 ()))))
;;

let test_an_outage_shows_until_a_change_ends_it () =
  let client = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ()) ] in
  ignore
    (Client.feed client (frame (degraded ~revision:2 ~since:25.0 F.Scan_timed_out)) : Client.step);
  let outage = { F.since = 25.0; reason = F.Scan_timed_out } in
  check view_t "the reading is the last one, with the outage"
    (following
       ~trouble:(Some (Client.Scans_failing outage))
       (reading ~degraded:outage ~revision:2 ~measured_at:10.0 (fleet ~running:1 ())))
    (Client.view client);
  ignore
    (Client.feed client (frame (changed ~revision:3 ~measured_at:40.0 (fleet ~running:1 ()))) : Client.step);
  check view_t "a change with the same fleet still ends it"
    (following (reading ~revision:3 ~measured_at:40.0 (fleet ~running:1 ())))
    (Client.view client)
;;

let test_a_snapshot_taken_during_an_outage_says_so () =
  let outage = { F.since = 25.0; reason = F.Scan_failed } in
  let client =
    connected [ snapshot ~degraded:outage ~revision:7 ~measured_at:10.0 (fleet ~running:2 ()) ]
  in
  check view_t "outage from the first frame"
    (following
       ~trouble:(Some (Client.Scans_failing outage))
       (reading ~degraded:outage ~revision:7 ~measured_at:10.0 (fleet ~running:2 ())))
    (Client.view client)
;;

let test_keepalives_change_nothing () =
  let client = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ] in
  let before = Client.view client in
  check step_t "a keepalive" Client.Keep_reading (Client.feed client keepalive);
  check step_t "two in one chunk" Client.Keep_reading (Client.feed client (keepalive ^ keepalive));
  check view_t "the view" before (Client.view client)
;;

let test_the_first_loss_fixes_the_time_the_connection_went_down () =
  let snapshot_frame n = frame (snapshot ~revision:n ~measured_at:10.0 (fleet ())) in
  let client = Client.create () in
  Client.started client;
  ignore (Client.feed client (snapshot_frame 1) : Client.step);
  Client.lost client ~now:10.0;
  Client.lost client ~now:20.0;
  Client.started client;
  Client.lost client ~now:30.0;
  check view_t "down since the first loss"
    (following
       ~trouble:(Some (Client.Disconnected { since = 10.0 }))
       (reading ~revision:1 ~measured_at:10.0 (fleet ())))
    (Client.view client);
  Client.started client;
  ignore (Client.feed client (snapshot_frame 1) : Client.step);
  check view_t "back"
    (following (reading ~revision:1 ~measured_at:10.0 (fleet ())))
    (Client.view client);
  Client.lost client ~now:40.0;
  check view_t "a new outage has its own time"
    (following
       ~trouble:(Some (Client.Disconnected { since = 40.0 }))
       (reading ~revision:1 ~measured_at:10.0 (fleet ())))
    (Client.view client)
;;

let with_schema schema event =
  match F.encode event with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) -> if String.equal key "schema" then key, `Int schema else key, value)
         fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    fail "an event encodes as an object"
;;

let test_a_schema_this_build_does_not_read_is_refused_until_a_good_snapshot () =
  let client = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ] in
  Client.lost client ~now:20.0;
  Client.started client;
  let other = F.schema_version + 1 in
  check step_t "schema from the future" Client.Reconnect
    (Client.feed
       client
       (frame_of_json (with_schema other (snapshot ~revision:1 ~measured_at:30.0 (fleet ())))));
  check view_t "the old reading is not shown as if it were current"
    (Client.Cannot_read (Client.Schema_mismatch { expected = F.schema_version; received = other }))
    (Client.view client);
  Client.lost client ~now:31.0;
  Client.started client;
  ignore
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:40.0 (fleet ~running:2 ()))) : Client.step);
  check view_t "a Snapshot this build reads clears it"
    (following (reading ~revision:1 ~measured_at:40.0 (fleet ~running:2 ())))
    (Client.view client)
;;

let test_a_frame_this_build_cannot_read_asks_for_a_new_connection () =
  let is_rejected = function
    | Client.Cannot_read (Client.Frame_rejected _) -> true
    | Client.Awaiting_first_reading | Client.Unreachable _ | Client.Reading _
    | Client.Unavailable _
    | Client.Cannot_read (Client.Refused _ | Client.Schema_mismatch _) -> false
  in
  List.iter
    (fun (label, bytes) ->
       let client = Client.create () in
       Client.started client;
       check step_t label Client.Reconnect (Client.feed client bytes);
       check bool (label ^ ": the view says so") true (is_rejected (Client.view client)))
    [ "not JSON", "data: nope\n\n"
    ; "an event this build does not know", "data: {\"event\":\"mystery\"}\n\n"
    ; "an empty data field", "data:\n\n"
    ]
;;

let test_a_new_connection_starts_from_its_own_snapshot_even_if_the_old_one_never_reported_its_loss () =
  let client = connected [ snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ] in
  Client.started client;
  check step_t "revision 2 on a connection with no Snapshot" Client.Reconnect
    (Client.feed client (frame (changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()))))
;;

let test_half_a_frame_from_a_lost_connection_does_not_leak_into_the_next () =
  let first = frame (snapshot ~revision:1 ~measured_at:10.0 (fleet ())) in
  let client = Client.create () in
  Client.started client;
  check step_t "half a frame" Client.Keep_reading
    (Client.feed client (String.sub first 0 (String.length first / 2)));
  Client.lost client ~now:11.0;
  Client.started client;
  check step_t "a whole frame on the next connection" Client.Keep_reading
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:20.0 (fleet ~running:2 ()))));
  check view_t "read as itself"
    (following (reading ~revision:1 ~measured_at:20.0 (fleet ~running:2 ())))
    (Client.view client)
;;

let test_a_refusal_shows_until_a_snapshot_arrives () =
  let client = Client.create () in
  Client.started client;
  Client.refused client ~status:401 ~detail:"unauthorized";
  Client.lost client ~now:5.0;
  check view_t "refused"
    (Client.Cannot_read (Client.Refused { status = 401; detail = "unauthorized" }))
    (Client.view client);
  Client.started client;
  ignore
    (Client.feed client (frame (snapshot ~revision:1 ~measured_at:10.0 (fleet ()))) : Client.step);
  check view_t "a Snapshot clears it"
    (following (reading ~revision:1 ~measured_at:10.0 (fleet ())))
    (Client.view client)
;;

(* Whatever the hub does and however the bytes are cut, a client that follows
   the hub's events ends with the hub's state. *)
let test_a_client_ends_with_the_hubs_state_under_random_operations_and_chunks () =
  let random = Random.State.make [| 477 |] in
  for round = 1 to 300 do
    let hub = Hub.create ~on_subscriber_error:(fun exn -> raise exn) in
    let events = ref [] in
    let (_ : unit -> unit) = Hub.subscribe hub ~on_event:(fun event -> events := event :: !events) in
    let clock = ref 0.0 in
    for _ = 1 to Random.State.int random 20 do
      clock := !clock +. 1.0;
      match Random.State.int random 3 with
      | 0 -> Hub.observe hub ~measured_at:!clock (fleet ~running:(Random.State.int random 3) ())
      | 1 ->
        Hub.note_degraded
          hub
          ~since:!clock
          (if Random.State.bool random then F.Scan_failed else F.Scan_timed_out)
      | _ -> Hub.observe hub ~measured_at:!clock (fleet ~running:1 ())
    done;
    let bytes = String.concat "" (List.rev_map frame !events) in
    let client = Client.create () in
    Client.started client;
    let position = ref 0 in
    while !position < String.length bytes do
      let size = 1 + Random.State.int random 40 in
      let size = min size (String.length bytes - !position) in
      check step_t "every event follows" Client.Keep_reading
        (Client.feed client (String.sub bytes !position size));
      position := !position + size
    done;
    let label = Printf.sprintf "round %d" round in
    (match Hub.current hub, Client.view client with
     | None, view -> check view_t (label ^ ": no reading") Client.Awaiting_first_reading view
     | Some (F.Unavailable_snapshot { degradation; _ }), Client.Unavailable observed ->
       check bool (label ^ ": first failure") true
         (observed.degradation = degradation && observed.disconnected_since = None)
     | Some (F.Unavailable_snapshot _), (Client.Awaiting_first_reading | Client.Unreachable _ | Client.Reading _ | Client.Cannot_read _) ->
       fail (label ^ ": the hub is unavailable and the client does not show it")
     | Some (F.Snapshot { revision; measured_at; fleet; degraded }), Client.Reading { reading; trouble } ->
       check bool (label ^ ": revision") true (F.Revision.equal revision reading.revision);
       check bool (label ^ ": fleet") true (F.equal_fleet fleet reading.fleet);
       check bool (label ^ ": outage") true (degraded = reading.degraded);
       (* A scan that finds the same fleet makes no event, so the client's
          time is the scan of the last event, never later than the hub's. *)
       check bool (label ^ ": time") true (reading.measured_at <= measured_at);
       check bool (label ^ ": trouble is the outage") true
         (trouble = Option.map (fun degradation -> Client.Scans_failing degradation) degraded)
     | Some (F.Snapshot _), (Client.Awaiting_first_reading | Client.Unreachable _ | Client.Unavailable _ | Client.Cannot_read _) ->
       fail (label ^ ": the hub has a reading and the client does not")
     | Some (F.Changed _ | F.Degraded _), _ -> fail "current is a Snapshot")
  done
;;

let () =
  run
    "tui_fleet_stream"
    [ ( "following"
      , [ test_case "a client that has read nothing awaits the first reading" `Quick
            test_a_client_that_has_read_nothing_awaits_the_first_reading
        ; test_case "a loss before any reading is unreachable until a snapshot" `Quick
            test_a_loss_before_any_reading_is_unreachable_until_a_snapshot
        ; test_case "an unavailable snapshot ends unreachable too" `Quick
            test_an_unavailable_snapshot_ends_unreachable_too
        ; test_case "first scan failure remains visible until a reading" `Quick
            test_first_scan_failure_is_visible_until_a_real_reading
        ; test_case "server restart replaces a previous reading with unavailable" `Quick
            test_restarted_server_unavailable_replaces_old_reading
        ; test_case "a snapshot then changes follow the server" `Quick
            test_a_snapshot_then_changes_follow_the_server
        ; test_case "every split of the bytes gives the same view" `Quick
            test_every_split_of_the_bytes_gives_the_same_view
        ; test_case "keepalives change nothing" `Quick test_keepalives_change_nothing
        ; test_case "an outage shows until a change ends it" `Quick
            test_an_outage_shows_until_a_change_ends_it
        ; test_case "a snapshot taken during an outage says so" `Quick
            test_a_snapshot_taken_during_an_outage_says_so
        ] )
    ; ( "new connection"
      , [ test_case "a gap asks for a new connection and the reading stays" `Quick
            test_a_gap_asks_for_a_new_connection_and_the_reading_stays
        ; test_case "an event before any snapshot asks for a new connection" `Quick
            test_an_event_before_any_snapshot_asks_for_a_new_connection
        ; test_case "a repeated or older revision asks for a new connection" `Quick
            test_a_repeated_or_older_revision_asks_for_a_new_connection
        ; test_case "after an event is refused nothing is followed until a snapshot" `Quick
            test_after_an_event_is_refused_nothing_is_followed_until_a_snapshot
        ; test_case "a restarted server starts over at revision one" `Quick
            test_a_restarted_server_starts_over_at_revision_one
        ; test_case "the first loss fixes the time the connection went down" `Quick
            test_the_first_loss_fixes_the_time_the_connection_went_down
        ] )
    ; ( "cannot read"
      , [ test_case "a schema this build does not read is refused" `Quick
            test_a_schema_this_build_does_not_read_is_refused_until_a_good_snapshot
        ; test_case "a frame this build cannot read asks for a new connection" `Quick
            test_a_frame_this_build_cannot_read_asks_for_a_new_connection
        ; test_case "a new connection needs its own snapshot" `Quick
            test_a_new_connection_starts_from_its_own_snapshot_even_if_the_old_one_never_reported_its_loss
        ; test_case "half a frame from a lost connection does not leak into the next" `Quick
            test_half_a_frame_from_a_lost_connection_does_not_leak_into_the_next
        ; test_case "a refusal shows until a snapshot arrives" `Quick
            test_a_refusal_shows_until_a_snapshot_arrives
        ; test_case "a refusal shows over unreachable until a snapshot arrives" `Quick
            test_a_refusal_shows_over_unreachable_until_a_snapshot_arrives
        ; test_case "an outage event after an unavailable snapshot asks for a new connection" `Quick
            test_an_outage_event_after_an_unavailable_snapshot_asks_for_a_new_connection
        ] )
    ; ( "the screen"
      , [ test_case "the screen draws only what a following job posted" `Quick
            test_the_screen_draws_only_what_a_following_job_posted
        ] )
    ; ( "with the hub"
      , [ test_case "a client ends with the hub's state" `Quick
            test_a_client_ends_with_the_hubs_state_under_random_operations_and_chunks
        ] )
    ]
;;
