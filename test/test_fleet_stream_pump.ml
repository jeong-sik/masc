open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Grade = Masc.Keeper_fleet_grade
module Pump = Server_fleet_stream_pump

let ping_interval_s = 30.0
let stalled_after_s = 100.0
let queue_bound = 3

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

let snapshot ~revision:n ~measured_at fleet =
  F.Snapshot { revision = revision n; measured_at; fleet; degraded = None }
;;

let changed ~revision:n ~measured_at fleet =
  F.Changed { revision = revision n; measured_at; fleet }
;;

let degraded ~revision:n ~since reason =
  F.Degraded { revision = revision n; degradation = { F.since; reason } }
;;

let ending_t =
  testable
    (fun fmt ending ->
       Format.pp_print_string
         fmt
         (match ending with
          | Pump.Client_gone -> "Client_gone"
          | Pump.Fell_behind -> "Fell_behind"
          | Pump.Stalled -> "Stalled"))
    ( = )
;;

(* A frame as the client sees it: the id the SSE decoder reads, and the event
   the strict codec makes of the data. *)
let frame_t =
  testable
    (fun fmt (id, event) ->
       Format.fprintf
         fmt
         "id=%s %s"
         (Option.value id ~default:"-")
         (Yojson.Safe.to_string (F.encode event)))
    ( = )
;;

let read_frames bytes =
  Sse_wire.feed (Sse_wire.create_decoder ()) bytes
  |> List.map (fun (frame : Sse_wire.frame) ->
    match F.decode (Yojson.Safe.from_string frame.data) with
    | Ok event -> frame.id, event
    | Error error -> failf "a frame does not decode: %s" (F.decode_error_to_string error))
;;

let new_hub () =
  Hub.create ~on_subscriber_error:(fun exn -> failf "subscriber raised %s" (Printexc.to_string exn))
;;

(* The pump in a fiber of its own. [frames] receives every frame [send] is
   given, and [send] answers [true] until [stop_after] frames were sent. With a
   [gate], [send] does not return until the gate opens, from the [gate_from]th
   frame on, which is a client that stopped reading. [live] counts the
   subscriptions the pump holds. *)
type served =
  { frames : string Eio.Stream.t
  ; ending : Pump.ending Eio.Promise.t
  }

let serve ~sw ~clock ~live ?(stop_after = max_int) ?gate ?(gate_from = 1) hub =
  let frames = Eio.Stream.create max_int in
  let ending, resolve_ending = Eio.Promise.create () in
  let subscribe ~on_event =
    incr live;
    let unsubscribe = Hub.subscribe hub ~on_event in
    fun () ->
      decr live;
      unsubscribe ()
  in
  let sent = ref 0 in
  let send frame =
    Eio.Stream.add frames frame;
    incr sent;
    if !sent >= gate_from then Option.iter Eio.Promise.await gate;
    !sent < stop_after
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve
      resolve_ending
      (Pump.run
         ~subscribe
         ~clock
         ~ping_interval_s
         ~stalled_after_s
         ~max_queued_events:queue_bound
         ~send));
  { frames; ending }
;;

let take_frames served count =
  List.init count (fun _ -> Eio.Stream.take served.frames)
  |> String.concat ""
  |> read_frames
;;

(* Scheduler turns the pump may need after a [send] returned before it waits
   for the next event: the time bound on the [send] ends first. *)
let max_turns_to_next_timer = 16

(* Moves the mock clock to the pump's next timer. *)
let advance clock =
  let rec go turns_left =
    Eio.Fiber.yield ();
    if not (Eio_mock.Clock.try_advance clock)
    then if turns_left = 0 then fail "the pump set no timer" else go (turns_left - 1)
  in
  go max_turns_to_next_timer
;;

let test_the_first_frame_is_the_snapshot_the_hub_holds () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:1 hub in
      check ending_t "the client left after one frame" Pump.Client_gone (Eio.Promise.await served.ending);
      check
        (list frame_t)
        "the Snapshot, numbered by its revision"
        [ Some "1", snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ]
        (take_frames served 1);
      check int "the subscription is removed" 0 !live))
;;

let test_events_follow_in_order_numbered_by_revision () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:4 hub in
      let first = take_frames served 1 in
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      Hub.note_degraded hub ~since:25.0 F.Scan_failed;
      Hub.observe hub ~measured_at:40.0 (fleet ~running:2 ());
      let rest = take_frames served 3 in
      check
        (list frame_t)
        "snapshot, change, outage, recovery"
        [ Some "1", snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())
        ; Some "2", changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ())
        ; Some "3", degraded ~revision:3 ~since:25.0 F.Scan_failed
        ; Some "4", changed ~revision:4 ~measured_at:40.0 (fleet ~running:2 ())
        ]
        (first @ rest);
      check ending_t "the client left after four frames" Pump.Client_gone (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

let test_initial_failure_frame_and_first_reading_are_ordered () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.note_degraded hub ~since:5.0 F.Scan_failed;
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:2 hub in
      let first_bytes = Eio.Stream.take served.frames in
      (match Sse_wire.feed (Sse_wire.create_decoder ()) first_bytes with
       | [ frame ] ->
         let json = Yojson.Safe.from_string frame.Sse_wire.data in
         check (option int) "first state carries the wire schema"
           (Some F.schema_version)
           (match Yojson.Safe.Util.member "schema" json with `Int n -> Some n | _ -> None)
       | _ -> fail "first send must contain one SSE frame");
      Hub.observe hub ~measured_at:10.0 (fleet ());
      let second_bytes = Eio.Stream.take served.frames in
      check (list frame_t) "unavailable snapshot then first reading with consecutive ids"
        [ Some "1", F.Unavailable_snapshot
            { revision = revision 1; degradation = { F.since = 5.0; reason = F.Scan_failed } }
        ; Some "2", changed ~revision:2 ~measured_at:10.0 (fleet ()) ]
        (read_frames (first_bytes ^ second_bytes));
      check ending_t "the client left" Pump.Client_gone (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

let test_a_client_that_connects_before_the_first_reading_gets_it_as_the_snapshot () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:1 hub in
      Eio.Fiber.yield ();
      check int "subscribed and waiting" 1 !live;
      check bool "nothing is sent before a reading" true (Eio.Stream.is_empty served.frames);
      Hub.observe hub ~measured_at:10.0 (fleet ());
      check
        (list frame_t)
        "the first reading is the Snapshot"
        [ Some "1", snapshot ~revision:1 ~measured_at:10.0 (fleet ()) ]
        (take_frames served 1);
      check ending_t "the client left" Pump.Client_gone (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

let test_an_idle_connection_gets_a_keepalive_that_readers_ignore () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:3 hub in
      ignore (take_frames served 1 : _ list);
      advance clock;
      check string "after one interval" Pump.keepalive_frame (Eio.Stream.take served.frames);
      advance clock;
      check string "and after the next" Pump.keepalive_frame (Eio.Stream.take served.frames);
      check
        (list frame_t)
        "the SSE decoder yields no event for a keepalive"
        []
        (read_frames Pump.keepalive_frame);
      check ending_t "the client left after three frames" Pump.Client_gone (Eio.Promise.await served.ending)))
;;

let test_the_interval_counts_from_the_last_frame () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:3 hub in
      ignore (take_frames served 1 : _ list);
      Eio_mock.Clock.set_time clock 20.0;
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      check
        (list frame_t)
        "a change at second 20"
        [ Some "2", changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()) ]
        (take_frames served 1);
      (* The next timer is the one set after the change. One counted from the
         first frame would have fallen due at second 30. *)
      advance clock;
      check
        (float 0.0)
        "the keepalive falls due 30 seconds after the change"
        (20.0 +. ping_interval_s)
        (Eio.Time.now clock);
      check string "and it is a keepalive" Pump.keepalive_frame (Eio.Stream.take served.frames)))
;;

let test_an_event_that_arrives_with_a_due_keepalive_is_sent_not_the_keepalive () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:2 hub in
      ignore (take_frames served 1 : _ list);
      Eio.Fiber.yield ();
      (* The keepalive falls due and the event arrives before the pump runs
         again, so both of its wake-ups are queued. *)
      Eio_mock.Clock.set_time clock ping_interval_s;
      Hub.observe hub ~measured_at:30.0 (fleet ~running:2 ());
      check
        (list frame_t)
        "the event"
        [ Some "2", changed ~revision:2 ~measured_at:30.0 (fleet ~running:2 ()) ]
        (take_frames served 1);
      check ending_t "the client left" Pump.Client_gone (Eio.Promise.await served.ending)))
;;

let stalled_client ~hub ~changes =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let gate, open_gate = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~stop_after:(1 + queue_bound) ~gate hub in
      (* The Snapshot is in [send], which has not returned. *)
      ignore (take_frames served 1 : _ list);
      for index = 1 to changes do
        Hub.observe hub ~measured_at:(10.0 +. float_of_int index) (fleet ~running:(1 + index) ())
      done;
      Eio.Promise.resolve open_gate ();
      let ending = Eio.Promise.await served.ending in
      ending, 1 + Eio.Stream.length served.frames, !live))
;;

let test_a_client_that_stops_reading_is_closed_once_the_queue_is_full () =
  let ending, sent, live = stalled_client ~hub:(new_hub ()) ~changes:(queue_bound + 1) in
  check ending_t "closed" Pump.Fell_behind ending;
  check int "only the Snapshot was sent, the queued events were dropped" 1 sent;
  check int "the subscription is removed" 0 live
;;

let test_a_client_exactly_at_the_bound_keeps_every_event () =
  let ending, sent, live = stalled_client ~hub:(new_hub ()) ~changes:queue_bound in
  check ending_t "not closed; it left after the last event" Pump.Client_gone ending;
  check int "the Snapshot and every queued event were sent" (1 + queue_bound) sent;
  check int "the subscription is removed" 0 live
;;

(* A client that stopped reading leaves [send] waiting, and nothing the client
   does later is needed to free the connection: the bound runs on the clock. *)
let test_a_send_that_does_not_return_in_time_ends_the_pump () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let gate, (_never_opened : unit Eio.Promise.u) = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~gate hub in
      (* The Snapshot is in [send], which does not return. *)
      ignore (take_frames served 1 : _ list);
      Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
      Eio.Fiber.yield ();
      check bool "still waiting a second before the bound" false (Eio.Promise.is_resolved served.ending);
      check int "and still subscribed" 1 !live;
      Eio_mock.Clock.set_time clock stalled_after_s;
      check ending_t "stalled at the bound" Pump.Stalled (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

let test_a_keepalive_that_is_not_accepted_in_time_stalls_too () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let gate, (_never_opened : unit Eio.Promise.u) = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~gate ~gate_from:2 hub in
      ignore (take_frames served 1 : _ list);
      advance clock;
      check string "the keepalive is in send" Pump.keepalive_frame (Eio.Stream.take served.frames);
      Eio_mock.Clock.set_time clock (ping_interval_s +. stalled_after_s -. 1.0);
      Eio.Fiber.yield ();
      check bool "still waiting a second before the bound" false (Eio.Promise.is_resolved served.ending);
      Eio_mock.Clock.set_time clock (ping_interval_s +. stalled_after_s);
      check ending_t "the bound counts from the keepalive" Pump.Stalled (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

(* The bound belongs to one [send]. A client that took the first frame late,
   but in time, is read again from its next frame on. *)
let test_a_send_that_returns_before_the_bound_does_not_stall_the_pump () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let gate, open_gate = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~stop_after:2 ~gate hub in
      ignore (take_frames served 1 : _ list);
      Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
      Eio.Promise.resolve open_gate ();
      Eio.Fiber.yield ();
      (* Past the deadline the first [send] had. *)
      Eio_mock.Clock.set_time clock (stalled_after_s +. 1.0);
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      check
        (list frame_t)
        "the next event is still sent"
        [ Some "2", changed ~revision:2 ~measured_at:20.0 (fleet ~running:2 ()) ]
        (take_frames served 1);
      check ending_t "the client left; the first deadline did not end the pump"
        Pump.Client_gone (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

(* While [send] waits, events pile up past the bound, but nothing acts on that
   until [send] returns. The time bound is what ends this connection. *)
let test_a_pile_up_behind_a_send_that_never_returns_ends_as_stalled () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let gate, (_never_opened : unit Eio.Promise.u) = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~gate hub in
      ignore (take_frames served 1 : _ list);
      for index = 1 to queue_bound + 1 do
        Hub.observe hub ~measured_at:(10.0 +. float_of_int index) (fleet ~running:(1 + index) ())
      done;
      Eio.Fiber.yield ();
      check bool "the pile-up alone does not end it" false (Eio.Promise.is_resolved served.ending);
      Eio_mock.Clock.set_time clock stalled_after_s;
      check ending_t "the bound ends it" Pump.Stalled (Eio.Promise.await served.ending);
      check int "nothing was written after the Snapshot" 0 (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

let test_cancelling_a_connection_removes_its_subscription () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    (match
       Eio.Switch.run (fun sw ->
         let served = serve ~sw ~clock ~live hub in
         ignore (take_frames served 1 : _ list);
         check int "subscribed while it waits" 1 !live;
         Eio.Switch.fail sw Exit)
     with
     | () -> fail "the switch should have failed"
     | exception Exit -> ());
    check int "the subscription is removed" 0 !live)
;;

let test_a_send_that_raises_removes_the_subscription_and_propagates () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    let subscribe ~on_event =
      incr live;
      let unsubscribe = Hub.subscribe hub ~on_event in
      fun () ->
        decr live;
        unsubscribe ()
    in
    (match
       Pump.run
         ~subscribe
         ~clock
         ~ping_interval_s
         ~stalled_after_s
         ~max_queued_events:queue_bound
         ~send:(fun _ -> failwith "socket write failed")
     with
     | (_ : Pump.ending) -> fail "the failure should propagate"
     | exception Failure message -> check string "the failure" "socket write failed" message);
    check int "the subscription is removed" 0 !live)
;;

let () =
  run
    "fleet_stream_pump"
    [ ( "frames"
      , [ test_case "the first frame is the snapshot the hub holds" `Quick
            test_the_first_frame_is_the_snapshot_the_hub_holds
        ; test_case "events follow in order, numbered by revision" `Quick
            test_events_follow_in_order_numbered_by_revision
        ; test_case "initial failure and first reading are ordered" `Quick
            test_initial_failure_frame_and_first_reading_are_ordered
        ; test_case "a client that connects before the first reading gets it" `Quick
            test_a_client_that_connects_before_the_first_reading_gets_it_as_the_snapshot
        ] )
    ; ( "keepalive"
      , [ test_case "an idle connection gets a keepalive readers ignore" `Quick
            test_an_idle_connection_gets_a_keepalive_that_readers_ignore
        ; test_case "the interval counts from the last frame" `Quick
            test_the_interval_counts_from_the_last_frame
        ; test_case "an event that arrives with a due keepalive is sent" `Quick
            test_an_event_that_arrives_with_a_due_keepalive_is_sent_not_the_keepalive
        ] )
    ; ( "slow client"
      , [ test_case "a client that stops reading is closed once the queue is full" `Quick
            test_a_client_that_stops_reading_is_closed_once_the_queue_is_full
        ; test_case "a client exactly at the bound keeps every event" `Quick
            test_a_client_exactly_at_the_bound_keeps_every_event
        ] )
    ; ( "stalled client"
      , [ test_case "a send that does not return in time ends the pump" `Quick
            test_a_send_that_does_not_return_in_time_ends_the_pump
        ; test_case "a keepalive that is not accepted in time stalls too" `Quick
            test_a_keepalive_that_is_not_accepted_in_time_stalls_too
        ; test_case "a send that returns before the bound does not stall the pump" `Quick
            test_a_send_that_returns_before_the_bound_does_not_stall_the_pump
        ; test_case "a pile-up behind a send that never returns ends as stalled" `Quick
            test_a_pile_up_behind_a_send_that_never_returns_ends_as_stalled
        ] )
    ; ( "cleanup"
      , [ test_case "cancelling a connection removes its subscription" `Quick
            test_cancelling_a_connection_removes_its_subscription
        ; test_case "a send that raises removes the subscription and propagates" `Quick
            test_a_send_that_raises_removes_the_subscription_and_propagates
        ] )
    ]
;;
