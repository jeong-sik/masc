open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Grade = Masc.Keeper_fleet_grade
module Client = Masc_tui_fleet_stream
module Route = Server_routes_http_routes_fleet_stream

(* Short enough for a test to wait through, long enough that a loaded machine
   does not make a quiet stream look dead. *)
let ping_interval_s = 0.15
let reconnect_s = 0.05
let queue_bound = 64

(* No test waits this long on a server that is meant to keep a connection. *)
let kept_stalled_after_s = 600.0

(* Short enough that a reader that stopped is let go within a test's patience. *)
let short_stalled_after_s = 0.3

(* A wait that has not ended by now has failed. *)
let patience_s = 10.0
let poll_s = 0.002

let fleet ?(keepers = 0) ?(running = 1) () : F.fleet =
  let names =
    F.Names.of_list (List.init keepers (fun index -> Printf.sprintf "keeper-%04d" index))
  in
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
  ; fs_bootable_names = names
  ; fs_running_names = names
  ; fs_executable_names = names
  ; fs_turn_configuration_error_names = F.Names.empty
  ; fs_official_client_recovery_required_names = F.Names.empty
  ; fs_active_task_owner_without_fiber_count = 0
  ; fs_completion_authority_pending_count = 0
  ; fs_active_task_owner_scan_error_count = 0
  }
;;

let new_hub () =
  Hub.create ~on_subscriber_error:(fun exn ->
    failf "a subscriber raised %s" (Printexc.to_string exn))
;;

let with_env f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> f env)))
;;

(* How many subscriptions the server holds now and has made in all. *)
type subscriptions =
  { mutable live : int
  ; mutable total : int
  }

let counted hub counts ~on_event =
  counts.live <- counts.live + 1;
  counts.total <- counts.total + 1;
  let unsubscribe = Hub.subscribe hub ~on_event in
  fun () ->
    counts.live <- counts.live - 1;
    unsubscribe ()
;;

exception Server_stopped

type server =
  { port : int
  ; stop : unit -> unit  (** Returns once the listening socket is closed. *)
  }

(* The real accept loop and the route's [serve], on a loopback port: everything
   the server does for this stream but the authorization. *)
let start_server ~sw env ?port ?subscribe ?(stalled_after_s = kept_stalled_after_s) hub =
  let subscribe = Option.value subscribe ~default:(Hub.subscribe hub) in
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  let listening, resolve_listening = Eio.Promise.create () in
  let finished, resolve_finished = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    (match
       Eio.Switch.run (fun server_sw ->
         let socket =
           Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw:server_sw net
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, Option.value port ~default:0))
         in
         let bound =
           match Eio.Net.listening_addr socket with
           | `Tcp (_, bound) -> bound
           | `Unix _ -> fail "the test listens on TCP"
         in
         Eio.Promise.resolve
           resolve_listening
           { port = bound
           ; stop =
               (fun () ->
                  Eio.Switch.fail server_sw Server_stopped;
                  Eio.Promise.await finished)
           };
         Server_bootstrap_http.serve
           ~sw:server_sw
           ~clock
           ~socket
           ~addr_label:"loopback test"
           ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
             Route.serve
               ~sw:server_sw
               ~clock
               ~subscribe
               ~ping_interval_s
               ~stalled_after_s
               ~max_queued_events:queue_bound
               gluten_reqd.Gluten.Reqd.reqd))
     with
     | () -> ()
     | exception Server_stopped -> ());
    Eio.Promise.resolve resolve_finished ());
  Eio.Promise.await listening
;;

(* What the terminal's job does with a connection: read it into [reader], and
   when it ends, say so and open the next one after a pause. *)
let follow ~sw env ~port ?(on_bytes = fun (_ : string) -> ()) reader =
  let clock = Eio.Stdenv.clock env in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port F.stream_path in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Client.started reader;
      (match
         Masc_http_client.get_stream
           ~clock
           ~idle_timeout_sec:patience_s
           ~url
           ~headers:[ "Accept", "text/event-stream" ]
           ~on_chunk:(fun chunk ->
             let step = Client.feed reader chunk in
             on_bytes chunk;
             match step with
             | Client.Keep_reading -> ()
             | Client.Reconnect -> failwith "the stream asked for a new connection")
           ()
       with
       | Ok (Masc_http_client.Pool.Streamed _) | Error _ -> ()
       | Ok (Masc_http_client.Pool.Buffered { status; body; _ }) ->
         Client.refused reader ~status ~detail:body);
      Client.lost reader ~now:(Eio.Time.now clock);
      Eio.Time.sleep clock reconnect_s
    done;
    `Stop_daemon)
;;

let wait_until env what predicate =
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock patience_s (fun () ->
      while not (predicate ()) do
        Eio.Time.sleep clock poll_s
      done;
      Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> failf "gave up waiting for %s" what
;;

type trouble =
  | Fine
  | Scans_failing
  | Disconnected

(* The revision, the running count and what is wrong with them, or [None] while
   there is nothing to draw. *)
let position reader =
  match Client.view reader with
  | Client.Reading { reading; trouble } ->
    Some
      ( F.Revision.to_int reading.Client.revision
      , reading.Client.fleet.F.fs_running_count
      , match trouble with
        | None -> Fine
        | Some (Client.Scans_failing _) -> Scans_failing
        | Some (Client.Disconnected _) -> Disconnected )
  | Client.Awaiting_first_reading | Client.Unreachable _ | Client.Unavailable _
  | Client.Cannot_read _ -> None
;;

let position_t =
  testable
    (fun fmt -> function
       | None -> Format.pp_print_string fmt "nothing to draw"
       | Some (revision, running, trouble) ->
         Format.fprintf
           fmt
           "r%d running=%d %s"
           revision
           running
           (match trouble with
            | Fine -> "fine"
            | Scans_failing -> "scans failing"
            | Disconnected -> "disconnected"))
    ( = )
;;

let test_a_reader_follows_the_hub_over_http () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let hub = new_hub () in
      Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
      let server = start_server ~sw env hub in
      let reader = Client.create () in
      follow ~sw env ~port:server.port reader;
      wait_until env "the Snapshot" (fun () -> position reader = Some (1, 1, Fine));
      Hub.observe hub ~measured_at:20.0 (fleet ~running:2 ());
      Hub.note_degraded hub ~since:25.0 F.Scan_failed;
      wait_until env "the outage" (fun () -> position reader = Some (3, 2, Scans_failing));
      Hub.observe hub ~measured_at:40.0 (fleet ~running:3 ());
      (* A revision the reader missed would have asked for a new connection,
         which [follow] turns into a failure. *)
      wait_until env "the recovery" (fun () -> position reader = Some (4, 3, Fine));
      server.stop ()))
;;

let test_a_client_that_connects_before_the_first_reading_waits_for_it () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let hub = new_hub () in
      let server = start_server ~sw env hub in
      let reader = Client.create () in
      follow ~sw env ~port:server.port reader;
      Eio.Time.sleep (Eio.Stdenv.clock env) (ping_interval_s *. 2.0);
      check position_t "no reading yet" None (position reader);
      Hub.observe hub ~measured_at:10.0 (fleet ~running:4 ());
      wait_until env "the first reading" (fun () -> position reader = Some (1, 4, Fine));
      server.stop ()))
;;

let test_first_scan_failure_survives_reconnect_and_recovers_over_http () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let hub = new_hub () in
      let outage = { F.since = 10.0; reason = F.Scan_failed } in
      Hub.note_degraded hub ~since:outage.since outage.reason;
      let first = start_server ~sw env hub in
      let reader = Client.create () in
      follow ~sw env ~port:first.port reader;
      wait_until env "first failure snapshot" (fun () ->
        Client.view reader = Client.Unavailable { degradation = outage; disconnected_since = None });
      first.stop ();
      wait_until env "failure and disconnected stream" (fun () ->
        match Client.view reader with
        | Client.Unavailable { degradation; disconnected_since = Some _ } -> degradation = outage
        | Client.Unavailable { disconnected_since = None; _ }
        | Client.Awaiting_first_reading | Client.Unreachable _ | Client.Reading _
        | Client.Cannot_read _ -> false);
      let second = start_server ~sw env ~port:first.port hub in
      wait_until env "same failure on the new connection" (fun () ->
        Client.view reader = Client.Unavailable { degradation = outage; disconnected_since = None });
      Hub.observe hub ~measured_at:20.0 (fleet ~running:4 ());
      wait_until env "first actual reading" (fun () -> position reader = Some (2, 4, Fine));
      second.stop ()))
;;

let contains ~needle text =
  let needle_length = String.length needle in
  let rec from index =
    index + needle_length <= String.length text
    && (String.equal (String.sub text index needle_length) needle || from (index + 1))
  in
  from 0
;;

let test_a_keepalive_crosses_http_without_becoming_an_event () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let hub = new_hub () in
      Hub.observe hub ~measured_at:10.0 (fleet ~running:1 ());
      let server = start_server ~sw env hub in
      let reader = Client.create () in
      let keepalives = ref 0 in
      follow
        ~sw
        env
        ~port:server.port
        ~on_bytes:(fun chunk ->
          if contains ~needle:Server_fleet_stream_pump.keepalive_frame chunk
          then incr keepalives)
        reader;
      wait_until env "two keepalives" (fun () -> !keepalives >= 2);
      check position_t "the reading is the Snapshot's" (Some (1, 1, Fine)) (position reader);
      server.stop ()))
;;

let test_a_reader_recovers_from_a_server_restart_with_the_new_snapshot () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let before = new_hub () in
      Hub.observe before ~measured_at:10.0 (fleet ~running:5 ());
      Hub.observe before ~measured_at:20.0 (fleet ~running:6 ());
      let first = start_server ~sw env before in
      let reader = Client.create () in
      follow ~sw env ~port:first.port reader;
      wait_until env "revision 2" (fun () -> position reader = Some (2, 6, Fine));
      first.stop ();
      wait_until env "the loss" (fun () -> position reader = Some (2, 6, Disconnected));
      (* A new server numbers from 1 again, with a different fleet. *)
      let after = new_hub () in
      Hub.observe after ~measured_at:30.0 (fleet ~running:9 ());
      let second = start_server ~sw env ~port:first.port after in
      wait_until env "the new server's Snapshot" (fun () ->
        position reader = Some (1, 9, Fine));
      Hub.observe after ~measured_at:40.0 (fleet ~running:10 ());
      wait_until env "its first change" (fun () -> position reader = Some (2, 10, Fine));
      second.stop ()))
;;

(* Large enough that the kernel's buffers for one connection fill up long
   before the changes run out: 3,000 changes of about 13 KB each. *)
let stalled_keepers = 300
let stalled_changes = 3000
let changes_per_pause = 50

(* A reader that stops reading holds the connection's socket buffers and the
   pump's queue, and no more. The pump writes nothing more to it once its queue
   overflowed, so when it reads again it gets what was already on the wire and
   then the end of the response, and the new connection's Snapshot makes it
   right. A frame written after the overflow would reach it as a gap, which
   [follow] turns into a failure. *)
let test_a_reader_that_stops_reading_recovers_with_a_new_snapshot () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let hub = new_hub () in
      let counts = { live = 0; total = 0 } in
      Hub.observe hub ~measured_at:0.0 (fleet ~keepers:stalled_keepers ~running:0 ());
      let server = start_server ~sw env ~subscribe:(counted hub counts) hub in
      let reader = Client.create () in
      let gate, open_gate = Eio.Promise.create () in
      let stopped = ref false in
      follow
        ~sw
        env
        ~port:server.port
        ~on_bytes:(fun _ ->
          if not !stopped
          then (
            stopped := true;
            Eio.Promise.await gate))
        reader;
      wait_until env "the reader to stop reading" (fun () -> !stopped);
      for change = 1 to stalled_changes do
        Hub.observe
          hub
          ~measured_at:(float_of_int change)
          (fleet ~keepers:stalled_keepers ~running:change ());
        if change mod changes_per_pause = 0 then Eio.Time.sleep clock poll_s
      done;
      check int "the server still holds the one connection" 1 counts.total;
      Eio.Promise.resolve open_gate ();
      wait_until env "the reader to be right again" (fun () ->
        position reader = Some (stalled_changes + 1, stalled_changes, Fine));
      if counts.total < 2
      then fail "the reader never fell behind: it caught up on the connection it had";
      wait_until env "the server to let the old connection go" (fun () -> counts.live = 1);
      server.stop ()))
;;

(* Events this large fill the kernel's buffers for one connection within a few
   dozen of them. The pump is then waiting in [send] while fewer events than
   the queue holds are behind it, so the time bound on [send] is the only thing
   that can end the connection: a pile-up is not acted on until [send]
   returns. *)
let blocking_keepers = 6000
let blocking_changes = 100

(* The server lets go of a connection whose reader stopped reading for good,
   without the reader's help: the subscription is gone while the reader is
   still stopped. Reading again then ends at the end of the response, and a
   new connection's Snapshot makes the reader right. *)
let test_a_reader_that_does_not_read_again_is_let_go () =
  with_env (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let hub = new_hub () in
      let counts = { live = 0; total = 0 } in
      Hub.observe hub ~measured_at:0.0 (fleet ~keepers:blocking_keepers ~running:0 ());
      let server =
        start_server
          ~sw
          env
          ~stalled_after_s:short_stalled_after_s
          ~subscribe:(counted hub counts)
          hub
      in
      let reader = Client.create () in
      let gate, open_gate = Eio.Promise.create () in
      let stopped = ref false in
      follow
        ~sw
        env
        ~port:server.port
        ~on_bytes:(fun _ ->
          if not !stopped
          then (
            stopped := true;
            Eio.Promise.await gate))
        reader;
      wait_until env "the reader to stop reading" (fun () -> !stopped);
      (* One change per pause, so the pump keeps up until the buffers are full. *)
      for change = 1 to blocking_changes do
        Hub.observe
          hub
          ~measured_at:(float_of_int change)
          (fleet ~keepers:blocking_keepers ~running:change ());
        Eio.Time.sleep clock poll_s
      done;
      wait_until env "the server to let the stopped reader go" (fun () -> counts.live = 0);
      check int "it was the one connection" 1 counts.total;
      Eio.Promise.resolve open_gate ();
      wait_until env "the reader to be right again" (fun () ->
        position reader = Some (blocking_changes + 1, blocking_changes, Fine));
      server.stop ()))
;;

let () =
  run
    "fleet_stream_loopback"
    [ ( "http"
      , [ test_case "a reader follows the hub" `Quick test_a_reader_follows_the_hub_over_http
        ; test_case "a client that connects first waits for the reading" `Quick
            test_a_client_that_connects_before_the_first_reading_waits_for_it
        ; test_case "first scan failure survives reconnect and recovers" `Quick
            test_first_scan_failure_survives_reconnect_and_recovers_over_http
        ; test_case "a keepalive is not an event" `Quick
            test_a_keepalive_crosses_http_without_becoming_an_event
        ; test_case "a reader recovers from a server restart" `Quick
            test_a_reader_recovers_from_a_server_restart_with_the_new_snapshot
        ; test_case "a reader that stops reading recovers with a new snapshot" `Quick
            test_a_reader_that_stops_reading_recovers_with_a_new_snapshot
        ; test_case "a reader that does not read again is let go" `Quick
            test_a_reader_that_does_not_read_again_is_let_go
        ] )
    ]
;;
