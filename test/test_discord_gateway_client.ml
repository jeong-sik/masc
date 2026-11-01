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
  let exception Owner_cancelled in
  Eio_main.run (fun _env ->
    let queued_runs = ref [] in
    let failures = ref [] in
    let lane_a = Ingress.Keeper_lane "keeper-a" in
    let lane_b = Ingress.Keeper_lane "keeper-b" in
    let event opaque_id : Ingress.event_id = { source = "test"; opaque_id } in
    let active_event = event "a1" in
    let queued = [ lane_a, event "a2"; lane_a, event "a3"; lane_b, event "b1" ] in
    let first_started, resolve_first_started = Eio.Promise.create () in
    let blocked, _ = Eio.Promise.create () in
    let owner_cancelled =
      try
        Eio.Switch.run (fun sw ->
          let ingress =
            Ingress.create
              ~sw
              ~on_failure:(fun failure ->
                Eio.Fiber.check ();
                failures := failure :: !failures)
              ()
          in
          submit_exn ingress ~lane:lane_a ~event_id:active_event (fun () ->
            Eio.Promise.resolve resolve_first_started ();
            Eio.Promise.await blocked);
          Eio.Promise.await first_started;
          (* Submission only broadcasts to the run queue. Without yielding,
             these jobs remain queued until the owner is cancelled. *)
          List.iter
            (fun (lane, event_id) ->
               submit_exn ingress ~lane ~event_id (fun () ->
                 queued_runs := event_id :: !queued_runs))
            queued;
          Eio.Switch.fail sw Owner_cancelled);
        false
      with Owner_cancelled -> true
    in
    check bool "owner cancellation retains the original exception" true owner_cancelled;
    check int "queued callbacks never execute" 0 (List.length !queued_runs);
    let observed = List.rev !failures in
    check int "every accepted event has exactly one failure" 4 (List.length observed);
    let failure_for lane event_id =
      let matching =
        List.filter
          (fun (failure : Ingress.failure) -> failure.event_id = event_id)
          observed
      in
      match matching with
      | [ failure ] ->
        check bool "failure retains its Keeper lane" true (failure.lane = lane);
        failure
      | matches ->
        failf
          "expected one failure for %s, got %d"
          (Ingress.event_id_to_string event_id)
          (List.length matches)
    in
    check bool "active callback reports cancellation" true
      (match (failure_for lane_a active_event).reason with
       | Ingress.Callback_cancelled _ -> true
       | Ingress.Callback_raised _ | Ingress.Owner_released -> false);
    List.iter
      (fun (lane, event_id) ->
         check bool "queued callback reports owner release" true
           (match (failure_for lane event_id).reason with
            | Ingress.Owner_released -> true
            | Ingress.Callback_raised _ | Ingress.Callback_cancelled _ -> false))
      queued;
    let released_a =
      List.filter_map
        (fun (failure : Ingress.failure) ->
           match failure.reason with
           | Ingress.Owner_released when failure.lane = lane_a ->
             Some failure.event_id.opaque_id
           | Ingress.Owner_released
           | Ingress.Callback_raised _
           | Ingress.Callback_cancelled _ -> None)
        observed
    in
    check (list string) "queued failures preserve same-lane FIFO"
      [ "a2"; "a3" ] released_a)

(* -- the policy the step loop judges by -------------------------- *)

(* The client is what makes a policy change take effect without a restart: the
   state machine is pure and would go on deciding with whatever [config] it was
   built with. So the property under test is not "the state machine reads
   config" — [test_discord_gateway_state] covers that — but "the step the run
   loop takes carries the policy as it is right now".

   Deleting the [with_trigger_policy] call inside
   [Client.For_testing.step_with_current_policy] must turn these red. *)

let config_with policy : State.config =
  { token = "bot-token"; intents = []; bot_user_id = None; trigger_policy = policy }
;;

let policy_after ~built_with ~now_returning =
  let state = State.create ~config:(config_with built_with) in
  let stepped, (_ : State.gateway_effect list) =
    Client.For_testing.step_with_current_policy state
      ~trigger_policy:(fun () -> now_returning)
      ~now_mono:0.0
      State.Connect_requested
  in
  (State.config stepped).trigger_policy
;;

let policy_name = State.trigger_policy_to_string

let test_step_takes_the_current_policy () =
  check string "a policy changed after connect governs the next step"
    (policy_name State.All)
    (policy_name (policy_after ~built_with:State.Mention_only ~now_returning:State.All))
;;

let test_step_keeps_an_unchanged_policy () =
  check string "an unchanged policy survives the step"
    (policy_name State.Mention_only)
    (policy_name
       (policy_after ~built_with:State.Mention_only ~now_returning:State.Mention_only))
;;

(* The reader is called per step, not once: a client that cached the first
   answer would pass the two checks above and still need a reconnect. *)
let test_step_rereads_the_policy_each_time () =
  let answers = ref [ State.Mention_only; State.All; State.Mention_or_thread ] in
  let next () =
    match !answers with
    | [] -> fail "policy reader called more often than the test has answers"
    | a :: rest -> answers := rest; a
  in
  let state = ref (State.create ~config:(config_with State.Mention_only)) in
  let seen =
    List.map
      (fun () ->
        let s', (_ : State.gateway_effect list) =
          Client.For_testing.step_with_current_policy !state
            ~trigger_policy:next ~now_mono:0.0 State.Connect_requested
        in
        state := s';
        policy_name (State.config s').trigger_policy)
      [ (); (); () ]
  in
  check (list string) "each step took the reading current at that step"
    [ policy_name State.Mention_only
    ; policy_name State.All
    ; policy_name State.Mention_or_thread
    ]
    seen
;;

let () =
  run "discord_gateway_client"
    [
      ( "trigger_policy_injection"
      , [
          test_case "the step takes the policy current at that moment" `Quick
            test_step_takes_the_current_policy
        ; test_case "an unchanged policy survives the step" `Quick
            test_step_keeps_an_unchanged_policy
        ; test_case "the policy is re-read on every step" `Quick
            test_step_rereads_the_policy_each_time
        ] )
    ; ( "reader_policy"
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
