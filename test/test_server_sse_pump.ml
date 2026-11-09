open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Grade = Masc.Keeper_fleet_grade
module Pump = Server_sse_pump
module Sse = Server_sse_response

let ping_interval_s = 30.0
let queue_bound = 3

let proactive_interval =
  match F.Proactive_interval.of_seconds 300 with
  | Some interval -> interval
  | None -> failwith "300 seconds is a proactive interval"
;;

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
  ; fs_proactive_interval = proactive_interval
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
          | Pump.Source_stopped -> "Source_stopped"
          | Pump.Stalled -> "Stalled"
          | Pump.Finished -> "Finished"))
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

(* The pump in a fiber of its own, with the fleet stream's frames. [frames]
   receives every frame [send] is given, and [send] answers [Written] until
   [stop_after] frames were sent, then [refusal]. With a [gate], [send] does not
   return until the gate opens, from the [gate_from]th frame on, which is a
   client that stopped reading. The harness subscribes the hub to the queue as
   a route does: before [run], with the removal on the stream's switch. [live]
   counts the subscriptions it holds. [step] and [idle] default to the fleet
   stream's. *)
type served =
  { frames : string Eio.Stream.t
  ; ending : Pump.ending Eio.Promise.t
  }

let fleet_step event = Pump.Send (Server_routes_http_routes_fleet_stream.frame event)
let always_keepalive () = Pump.Keepalive

(* A stub response that never closes: the stream ends through [send]. *)
let never_closes () : unit = Eio.Fiber.await_cancel ()

(* Subscribes [hub] to a new queue the way a route does and runs [pump] on it;
   the subscription is removed when this returns, raises or is cancelled. *)
let with_subscribed_queue ~live hub pump =
  Eio.Switch.run (fun stream_sw ->
    let queue = Pump.Queue.create ~max_queued_events:queue_bound in
    incr live;
    let unsubscribe = Hub.subscribe hub ~on_event:(Pump.Queue.push queue) in
    Eio.Switch.on_release stream_sw (fun () ->
      decr live;
      unsubscribe ());
    pump queue)
;;

(* The SSE frames in [bytes], each with its blank-line terminator. *)
let split_frames bytes =
  let terminator = "\n\n" in
  let rec go from acc =
    match Str.search_forward (Str.regexp_string terminator) bytes from with
    | at -> go (at + 2) (String.sub bytes from (at + 2 - from) :: acc)
    | exception Not_found -> List.rev acc
  in
  go 0 []
;;

let serve ~sw ~clock ~live ?(stop_after = max_int) ?(refusal = Sse.Closed) ?gate ?(gate_from = 1)
    ?(step = fleet_step) ?(idle = always_keepalive) ?(closed = never_closes) hub =
  let frames = Eio.Stream.create max_int in
  let ending, resolve_ending = Eio.Promise.create () in
  let sent = ref 0 in
  (* One send may carry several queued frames. Each is recorded on its own,
     and [stop_after] and [gate_from] count frames: the send carrying the
     [stop_after]th frame is refused. *)
  let send bytes =
    let carried = split_frames bytes in
    List.iter (Eio.Stream.add frames) carried;
    sent := !sent + List.length carried;
    if !sent >= gate_from then Option.iter Eio.Promise.await gate;
    if !sent < stop_after then Sse.Written else refusal
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve
      resolve_ending
      (with_subscribed_queue ~live hub (fun queue ->
         Pump.run ~source:(Pump.Queue.source queue) ~step ~idle ~clock ~ping_interval_s ~closed
           ~send)));
  { frames; ending }
;;

let take_frames served count =
  List.init count (fun _ -> Eio.Stream.take served.frames)
  |> String.concat ""
  |> read_frames
;;

(* Scheduler turns the pump may need after a [send] returned before it sets
   the timer of its next keepalive. *)
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
  check ending_t "closed" Pump.Source_stopped ending;
  check int "only the Snapshot was sent, the queued events were dropped" 1 sent;
  check int "the subscription is removed" 0 live
;;

let test_a_client_exactly_at_the_bound_keeps_every_event () =
  let ending, sent, live = stalled_client ~hub:(new_hub ()) ~changes:queue_bound in
  check ending_t "not closed; it left after the last event" Pump.Client_gone ending;
  check int "the Snapshot and every queued event were sent" (1 + queue_bound) sent;
  check int "the subscription is removed" 0 live
;;

(* The pump does not time a [send]; the response does (Server_sse_response).
   A [Stalled] answer ends the pump. *)
let test_a_send_answered_stalled_ends_the_pump () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:1 ~refusal:Sse.Stalled hub in
      ignore (take_frames served 1 : _ list);
      check ending_t "stalled" Pump.Stalled (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

let test_a_keepalive_answered_stalled_ends_the_pump () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~stop_after:2 ~refusal:Sse.Stalled hub in
      ignore (take_frames served 1 : _ list);
      advance clock;
      check string "the keepalive was sent" Pump.keepalive_frame (Eio.Stream.take served.frames);
      check ending_t "the keepalive's answer ends it" Pump.Stalled (Eio.Promise.await served.ending);
      check int "the subscription is removed" 0 !live))
;;

(* While [send] waits, events pile up past the bound, but nothing acts on that
   until [send] returns. Its answer is what ends this connection. *)
let test_a_pile_up_behind_a_stalled_send_ends_as_stalled () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let gate, open_gate = Eio.Promise.create () in
      let served = serve ~sw ~clock ~live ~stop_after:1 ~refusal:Sse.Stalled ~gate hub in
      ignore (take_frames served 1 : _ list);
      for index = 1 to queue_bound + 1 do
        Hub.observe hub ~measured_at:(10.0 +. float_of_int index) (fleet ~running:(1 + index) ())
      done;
      Eio.Fiber.yield ();
      check bool "the pile-up alone does not end it" false (Eio.Promise.is_resolved served.ending);
      Eio.Promise.resolve open_gate ();
      check ending_t "the send's answer ends it" Pump.Stalled (Eio.Promise.await served.ending);
      check int "nothing was written after the Snapshot" 0 (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

let revision_is n event = F.Revision.to_int (F.revision_of_event event) = n

let test_a_skipped_event_writes_nothing () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let step event = if revision_is 2 event then Pump.Skip else fleet_step event in
      let served = serve ~sw ~clock ~live ~stop_after:2 ~step hub in
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      Hub.observe hub ~measured_at:30.0 (fleet ~running:3 ());
      check (list frame_t) "the Snapshot, then the change after the skipped one"
        [ Some "1", snapshot ~revision:1 ~measured_at:10.0 (fleet ~running:1 ())
        ; Some "3", changed ~revision:3 ~measured_at:30.0 (fleet ~running:3 ())
        ]
        (take_frames served 2);
      check ending_t "the client left" Pump.Client_gone (Eio.Promise.await served.ending)))
;;

let test_a_last_frame_ends_the_stream_once_written () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let step event =
        if revision_is 2 event
        then Pump.Send_last (Server_routes_http_routes_fleet_stream.frame event)
        else fleet_step event
      in
      let served = serve ~sw ~clock ~live ~step hub in
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      Hub.observe hub ~measured_at:30.0 (fleet ~running:3 ());
      check ending_t "finished" Pump.Finished (Eio.Promise.await served.ending);
      check int "the Snapshot and the last frame, nothing after" 2 (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

let test_a_stop_ends_the_stream_without_a_frame () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
    Eio.Switch.run (fun sw ->
      let step event = if revision_is 2 event then Pump.Stop else fleet_step event in
      let served = serve ~sw ~clock ~live ~step hub in
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      Hub.observe hub ~measured_at:30.0 (fleet ~running:3 ());
      check ending_t "finished" Pump.Finished (Eio.Promise.await served.ending);
      check int "only the Snapshot, nothing for the stop or after it" 1
        (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

let test_a_quiet_interval_writes_nothing_and_asks_again () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let asked = ref 0 in
      let idle () =
        incr asked;
        if !asked = 1 then Pump.Quiet else Pump.Keepalive
      in
      let served = serve ~sw ~clock ~live ~stop_after:2 ~idle hub in
      ignore (take_frames served 1 : _ list);
      advance clock;
      let rec until_asked turns_left =
        if !asked = 0 && turns_left > 0
        then (
          Eio.Fiber.yield ();
          until_asked (turns_left - 1))
      in
      until_asked max_turns_to_next_timer;
      check int "asked once" 1 !asked;
      check int "a quiet interval writes nothing" 0 (Eio.Stream.length served.frames);
      advance clock;
      check string "the next interval writes the keepalive" Pump.keepalive_frame
        (Eio.Stream.take served.frames);
      check ending_t "the client left" Pump.Client_gone (Eio.Promise.await served.ending)))
;;

let test_an_idle_finish_ends_the_stream_without_a_frame () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~idle:(fun () -> Pump.Finish) hub in
      ignore (take_frames served 1 : _ list);
      advance clock;
      check ending_t "finished" Pump.Finished (Eio.Promise.await served.ending);
      check int "nothing written after the Snapshot" 0 (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

(* A pump over plain numbered events whose [send] records the frames each send
   carried. Event [n]'s frame is [frame_for n]; [last] ends the stream. *)
let frame_for ?(size = 16) n = Printf.sprintf "data: %d%s\n\n" n (String.make size 'x')

let sends_of ?(capacity = 64) ?(on_send = fun _ _ -> ()) ~step events =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let queue = Pump.Queue.create ~max_queued_events:capacity in
    List.iter (Pump.Queue.push queue) events;
    let sends = ref [] in
    let ending =
      Pump.run ~source:(Pump.Queue.source queue) ~step:(step queue) ~idle:(fun () -> Pump.Finish)
        ~clock ~ping_interval_s ~closed:never_closes
        ~send:(fun bytes ->
          sends := split_frames bytes :: !sends;
          on_send queue (List.length !sends);
          Sse.Written)
    in
    ending, List.rev !sends)
;;

let numbered ~last ?size _queue n =
  if n = last then Pump.Send_last (frame_for ?size n) else Pump.Send (frame_for ?size n)
;;

let test_the_events_already_queued_go_out_in_one_send () =
  let ending, sends = sends_of ~step:(numbered ~last:5) [ 1; 2; 3; 4; 5 ] in
  check ending_t "the last frame ends the stream" Pump.Finished ending;
  check (list (list string)) "one send with every frame, in order"
    [ List.map frame_for [ 1; 2; 3; 4; 5 ] ] sends
;;

(* Frames of 40 KiB: a batch holding one takes the next and then is full. *)
let test_a_batch_takes_no_more_frames_once_it_is_full () =
  let size = 40 * 1024 in
  let ending, sends = sends_of ~step:(numbered ~last:4 ~size) [ 1; 2; 3; 4 ] in
  check ending_t "the last frame ends the stream" Pump.Finished ending;
  check (list int) "two sends of two frames" [ 2; 2 ] (List.map List.length sends);
  check bool "no send holds more than the bound plus one frame" true
    (List.for_all
       (fun frames ->
          let bytes = List.fold_left (fun total frame -> total + String.length frame) 0 frames in
          bytes <= Pump.max_batch_bytes + String.length (frame_for ~size 1))
       sends)
;;

(* Event 1's step overflows a queue of two, as producers do while the pump
   builds a batch. The batch stops there: event 2 is not taken, and the frame
   of event 1, taken before the pile-up, is not written either. *)
let test_a_batch_stops_at_a_pile_up () =
  let step queue n =
    if n = 1 then List.iter (Pump.Queue.push queue) [ 3; 4; 5 ];
    Pump.Send (frame_for n)
  in
  let ending, sends = sends_of ~capacity:2 ~step [ 1; 2 ] in
  check ending_t "the client fell behind" Pump.Source_stopped ending;
  check (list (list string)) "nothing is written after the pile-up" [] sends
;;

(* A producer on another domain can mark the queue behind at any moment,
   also between the pump taking an event (or asking [idle]) and the send.
   Here [step] and [idle] mark it at that moment, in the pump's own fiber, so
   the order is fixed. The look right before the send sees the pile-up. *)
let test_a_pile_up_marked_before_a_send_writes_nothing () =
  let overflow queue = List.iter (Pump.Queue.push queue) [ 2; 3; 4 ] in
  let step queue n =
    overflow queue;
    Pump.Send_last (frame_for n)
  in
  let ending, sends = sends_of ~capacity:2 ~step [ 1 ] in
  check ending_t "a last frame: the client fell behind" Pump.Source_stopped ending;
  check (list (list string)) "the last frame is not written" [] sends;
  let ending, sends =
    Eio_mock.Backend.run_full (fun env ->
      let queue = Pump.Queue.create ~max_queued_events:2 in
      let sends = ref [] in
      let ending =
        Pump.run ~source:(Pump.Queue.source queue)
          ~step:(fun n -> Pump.Send (frame_for n))
          ~idle:(fun () ->
            overflow queue;
            Pump.Keepalive)
          ~clock:(Eio.Stdenv.clock env) ~ping_interval_s ~closed:never_closes
          ~send:(fun bytes ->
            sends := bytes :: !sends;
            Sse.Written)
      in
      ending, !sends)
  in
  check ending_t "a keepalive: the client fell behind" Pump.Source_stopped ending;
  check (list string) "the keepalive is not written" [] sends
;;

let producer_domains = 4
let pushes_per_domain = 1_000

(* Rounds of producers racing for the last slots of a queue nobody takes
   from. A push that waited would hang its round. *)
let overflow_rounds = 500
let overflow_capacity = 16

(* Longer than every round needs; reaching it means a push waited. *)
let push_patience_s = 10.0

(* Producers on several domains push while the pump takes, so pushes wake a
   take that is waiting and takes race pushes: while the queue has room, no
   event is lost or doubled. Past the bound, producers racing for the last
   slots only mark the client behind and never wait. *)
let test_producers_on_several_domains_lose_no_event () =
  Eio_main.run (fun env ->
    let domain_mgr = Eio.Stdenv.domain_mgr env in
    let clock = Eio.Stdenv.clock env in
    let push_from_every_domain queue ~each =
      Eio.Fiber.List.iter
        (fun domain ->
           Eio.Domain_manager.run domain_mgr (fun () ->
             for index = 1 to each do
               Pump.Queue.push queue ((domain * each) + index)
             done))
        (List.init producer_domains Fun.id)
    in
    let total = producer_domains * pushes_per_domain in
    let fits = Pump.Queue.create ~max_queued_events:total in
    let taken = ref [] and count = ref 0 in
    let ending, () =
      Eio.Fiber.pair
        (fun () ->
           Pump.run ~source:(Pump.Queue.source fits)
             ~step:(fun n ->
               taken := n :: !taken;
               incr count;
               if !count = total then Pump.Send_last "" else Pump.Send "")
             ~idle:(fun () -> Pump.Finish)
             ~clock ~ping_interval_s ~closed:never_closes
             ~send:(fun _ -> Sse.Written))
        (fun () -> push_from_every_domain fits ~each:pushes_per_domain)
    in
    check ending_t "every event that fit was served" Pump.Finished ending;
    check (list int) "none lost or doubled"
      (List.init total (fun n -> n + 1))
      (List.sort compare !taken);
    for _ = 1 to overflow_rounds do
      let overflow = Pump.Queue.create ~max_queued_events:overflow_capacity in
      (match
         Eio.Time.with_timeout clock push_patience_s (fun () ->
           Ok (push_from_every_domain overflow ~each:overflow_capacity))
       with
       | Ok () -> ()
       | Error `Timeout -> fail "a push past the bound waited");
      check ending_t "past the bound the client is behind" Pump.Source_stopped
        (Pump.run ~source:(Pump.Queue.source overflow) ~step:(fun _ -> Pump.Send "")
           ~idle:(fun () -> Pump.Finish)
           ~clock ~ping_interval_s ~closed:never_closes ~send:(fun _ -> Sse.Written))
    done)
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
    (match
       with_subscribed_queue ~live hub (fun queue ->
         Pump.run ~source:(Pump.Queue.source queue) ~step:fleet_step ~idle:always_keepalive
           ~clock ~ping_interval_s ~closed:never_closes
           ~send:(fun _ -> failwith "socket write failed"))
     with
     | (_ : Pump.ending) -> fail "the failure should propagate"
     | exception Failure message -> check string "the failure" "socket write failed" message);
    check int "the subscription is removed" 0 !live)
;;

(* The transport ends the stream while nothing is queued: an HTTP/2 peer
   reset, or a route that closed the response from another fiber. The pump
   was waiting for an event and ends without a frame. *)
let test_a_response_that_closes_while_the_pump_waits_ends_it () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let hub = new_hub () in
    let live = ref 0 in
    Hub.observe hub ~measured_at:10.0 (fleet ());
    let closed, close = Eio.Promise.create () in
    Eio.Switch.run (fun sw ->
      let served = serve ~sw ~clock ~live ~closed:(fun () -> Eio.Promise.await closed) hub in
      ignore (take_frames served 1 : _ list);
      check bool "the pump waits for an event" false (Eio.Promise.is_resolved served.ending);
      Eio.Promise.resolve close ();
      check ending_t "the close ends it" Pump.Client_gone (Eio.Promise.await served.ending);
      check int "no further frame was written" 0 (Eio.Stream.length served.frames);
      check int "the subscription is removed" 0 !live))
;;

let () =
  run
    "server_sse_pump"
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
      , [ test_case "a send answered Stalled ends the pump" `Quick
            test_a_send_answered_stalled_ends_the_pump
        ; test_case "a keepalive answered Stalled ends the pump" `Quick
            test_a_keepalive_answered_stalled_ends_the_pump
        ; test_case "a pile-up behind a stalled send ends as stalled" `Quick
            test_a_pile_up_behind_a_stalled_send_ends_as_stalled
        ] )
    ; ( "closed response"
      , [ test_case "a response that closes while the pump waits ends it" `Quick
            test_a_response_that_closes_while_the_pump_waits_ends_it
        ] )
    ; ( "steps"
      , [ test_case "a skipped event writes nothing" `Quick test_a_skipped_event_writes_nothing
        ; test_case "a last frame ends the stream once written" `Quick
            test_a_last_frame_ends_the_stream_once_written
        ; test_case "a stop ends the stream without a frame" `Quick
            test_a_stop_ends_the_stream_without_a_frame
        ; test_case "the events already queued go out in one send" `Quick
            test_the_events_already_queued_go_out_in_one_send
        ; test_case "a batch takes no more frames once it is full" `Quick
            test_a_batch_takes_no_more_frames_once_it_is_full
        ; test_case "a batch stops at a pile-up" `Quick test_a_batch_stops_at_a_pile_up
        ; test_case "a pile-up marked before a send writes nothing" `Quick
            test_a_pile_up_marked_before_a_send_writes_nothing
        ; test_case "a quiet interval writes nothing and asks again" `Quick
            test_a_quiet_interval_writes_nothing_and_asks_again
        ; test_case "an idle finish ends the stream without a frame" `Quick
            test_an_idle_finish_ends_the_stream_without_a_frame
        ] )
    ; ( "queue"
      , [ test_case "producers on several domains lose no event" `Quick
            test_producers_on_several_domains_lose_no_event
        ] )
    ; ( "cleanup"
      , [ test_case "cancelling a connection removes its subscription" `Quick
            test_cancelling_a_connection_removes_its_subscription
        ; test_case "a send that raises removes the subscription and propagates" `Quick
            test_a_send_that_raises_removes_the_subscription_and_propagates
        ] )
    ]
;;
