open Alcotest

module Client = Discord_gateway_client
module Ingress = Connector_ingress_lane
module State = Discord_gateway_state

let submit_exn ingress ~lane ~event_id run =
  match Ingress.submit ingress ~lane ~event_id run with
  | Ok () -> ()
  | Error error ->
    fail
      ("unexpected connector ingress rejection: "
       ^ Ingress.submit_error_to_string error)
;;

let dummy_frame : State.frame =
  { op = State.Op_hello
  ; s = None
  ; t = None
  ; d = `Assoc [ ("heartbeat_interval", `Int 41_250) ]
  }

let check_continue label input expected =
  check bool label expected
    (Client.For_testing.reader_should_continue_after_input input)

let test_reader_stops_after_close_input () =
  check_continue "close input stops reader"
    (State.Wss_closed { code = 1000; reason = "remote close" })
    false

let test_reader_continues_after_non_close_inputs () =
  let cases =
    [ "connect", State.Connect_requested
    ; "frame", State.Frame_received dummy_frame
    ; "parse_error", State.Frame_parse_error "bad json"
    ; "heartbeat_tick", State.Heartbeat_tick
    ; "heartbeat_ack_timeout", State.Heartbeat_ack_timeout
    ; "backoff_elapsed", State.Backoff_elapsed
    ; "status_change", State.Status_change State.Online
    ]
  in
  List.iter
    (fun (label, input) -> check_continue label input true)
    cases

let test_ingress_isolates_lanes_and_preserves_lane_fifo () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let trace_mutex = Stdlib.Mutex.create () in
      let trace = ref [] in
      let record value =
        Stdlib.Mutex.protect trace_mutex (fun () -> trace := value :: !trace)
      in
      let trace_snapshot () =
        Stdlib.Mutex.protect trace_mutex (fun () -> List.rev !trace)
      in
      let first_started, resolve_first_started = Eio.Promise.create () in
      let release_first, resolve_release_first = Eio.Promise.create () in
      let second_done, resolve_second_done = Eio.Promise.create () in
      let other_done, resolve_other_done = Eio.Promise.create () in
      let ingress =
        Ingress.create
          ~sw
          ~on_failure:(fun failure ->
            fail
              ("unexpected connector callback failure: "
               ^ Ingress.failure_reason_to_string failure.reason))
          ()
      in
      let event opaque_id : Ingress.event_id =
        { source = "test"; opaque_id }
      in
      submit_exn
        ingress
        ~lane:(Ingress.Keeper_lane "keeper-a")
        ~event_id:(event "first")
        (fun () ->
           record "first-start";
           Eio.Promise.resolve resolve_first_started ();
           Eio.Promise.await release_first;
           record "first-end");
      Eio.Promise.await first_started;
      submit_exn
        ingress
        ~lane:(Ingress.Keeper_lane "keeper-a")
        ~event_id:(event "second")
        (fun () ->
           record "second";
           Eio.Promise.resolve resolve_second_done ());
      submit_exn
        ingress
        ~lane:(Ingress.Keeper_lane "keeper-b")
        ~event_id:(event "other")
        (fun () ->
           record "other";
           Eio.Promise.resolve resolve_other_done ());
      Eio.Promise.await other_done;
      check
        bool
        "blocked lane did not block another Keeper lane"
        false
        (List.mem "second" (trace_snapshot ()));
      Eio.Promise.resolve resolve_release_first ();
      Eio.Promise.await second_done;
      let same_lane_trace =
        trace_snapshot () |> List.filter (fun value -> value <> "other")
      in
      check
        (list string)
        "same Keeper lane retains connector arrival order"
        [ "first-start"; "first-end"; "second" ]
        same_lane_trace))

let test_ingress_observes_callback_failure_and_continues () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let failure_seen, resolve_failure_seen = Eio.Promise.create () in
      let later_done, resolve_later_done = Eio.Promise.create () in
      let observed = ref None in
      let ingress =
        Ingress.create
          ~sw
          ~on_failure:(fun failure ->
            observed := Some failure;
            Eio.Promise.resolve resolve_failure_seen ())
          ()
      in
      let lane = Ingress.Keeper_lane "keeper-a" in
      submit_exn
        ingress
        ~lane
        ~event_id:{ source = "test"; opaque_id = "failed" }
        (fun () -> failwith "callback boom");
      submit_exn
        ingress
        ~lane
        ~event_id:{ source = "test"; opaque_id = "later" }
        (fun () -> Eio.Promise.resolve resolve_later_done ());
      Eio.Promise.await failure_seen;
      Eio.Promise.await later_done;
      match !observed with
      | None -> fail "callback failure was not observed"
      | Some failure ->
        check
          string
          "failure retains exact event identity"
          "test:failed"
          (Ingress.event_id_to_string failure.event_id);
        check
          string
          "failure retains Keeper lane"
          "keeper:keeper-a"
          (Ingress.lane_to_string failure.lane);
        check
          bool
          "failure detail is explicit"
          true
          (String.length (Ingress.failure_reason_to_string failure.reason) > 0)))

let test_ingress_dispatcher_has_switch_scoped_lifetime () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      ignore
        (Ingress.create
           ~sw
           ~on_failure:(fun failure ->
            fail
               ("unexpected connector callback failure: "
                ^ Ingress.failure_reason_to_string failure.reason))
           ())))

let test_ingress_rejects_submission_after_owner_release () =
  Eio_main.run (fun _env ->
    let ingress =
      Eio.Switch.run (fun sw ->
        Ingress.create
          ~sw
          ~on_failure:(fun failure ->
            fail
              ("unexpected connector callback failure: "
               ^ Ingress.failure_reason_to_string failure.reason))
          ())
    in
    match
      Ingress.submit
        ingress
        ~lane:(Ingress.Keeper_lane "keeper-a")
        ~event_id:{ source = "test"; opaque_id = "after-release" }
        (fun () -> fail "released ingress executed callback")
    with
    | Error Ingress.Owner_unavailable -> ()
    | Ok () -> fail "released ingress accepted callback")

let test_ingress_accounts_for_accepted_work_at_owner_release () =
  Eio_main.run (fun _env ->
    let executed = ref false in
    let failures = ref [] in
    Eio.Switch.run (fun sw ->
      let ingress =
        Ingress.create
          ~sw
          ~on_failure:(fun failure -> failures := failure :: !failures)
          ()
      in
      submit_exn
        ingress
        ~lane:(Ingress.Keeper_lane "keeper-a")
        ~event_id:{ source = "test"; opaque_id = "owner-release" }
        (fun () -> executed := true));
    let released =
      List.exists
        (fun failure ->
           match failure.Ingress.reason with
           | Ingress.Owner_released -> true
           | Ingress.Callback_raised _ | Ingress.Callback_cancelled _ -> false)
        !failures
    in
    check bool "accepted work executed or received terminal failure" true
      (!executed || released))

let () =
  run "discord_gateway_client"
    [
      ( "reader_policy"
      , [
          test_case "stops after WSS close input" `Quick
            test_reader_stops_after_close_input
        ; test_case "continues after non-close inputs" `Quick
            test_reader_continues_after_non_close_inputs
        ] )
    ; ( "ingress_lanes"
      , [ test_case
            "blocked callback isolates lanes and preserves same-lane FIFO"
            `Quick
            test_ingress_isolates_lanes_and_preserves_lane_fifo
        ; test_case
            "callback failure is observed and later work continues"
            `Quick
            test_ingress_observes_callback_failure_and_continues
        ; test_case
            "dispatcher ends with its owner switch"
            `Quick
            test_ingress_dispatcher_has_switch_scoped_lifetime
        ; test_case
            "submission after owner release is rejected"
            `Quick
            test_ingress_rejects_submission_after_owner_release
        ; test_case
            "accepted work is accounted for at owner release"
            `Quick
            test_ingress_accounts_for_accepted_work_at_owner_release
        ] )
    ]
