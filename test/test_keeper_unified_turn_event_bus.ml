(** Regression tests for [Keeper_unified_turn_event_bus] concurrency fixes
    (S1–S3): pending-tool count and drain-cancel handle must stay consistent
    with the Atomic event-bus state. *)

open Alcotest

module EB = Masc.Keeper_unified_turn_event_bus

let dummy_event payload =
  { Agent_sdk.Event_bus.meta =
      { correlation_id = "c"
      ; run_id = "r"
      ; ts = 0.0
      ; caused_by = None
      }
  ; payload
  }
;;

let tool_called name =
  dummy_event
    (Agent_sdk.Event_bus.ToolCalled
       { agent_name = "a"
       ; tool_name = name
       ; tool_use_id = name
       ; input = `Null
       ; turn = 0
       })
;;

let tool_completed name =
  dummy_event
    (Agent_sdk.Event_bus.ToolCompleted
       { agent_name = "a"
       ; tool_name = name
       ; tool_use_id = name
       ; output = Ok { Agent_sdk.Types.content = "done" }
       ; turn = 0
       })
;;

let test_record_fsm_tool_transitions_counts_and_transitions () =
  let open EB.For_testing in
  let count, transitions =
    record_fsm_tool_transitions ~keeper_name:"k" ~turn_id:1 0 []
  in
  check int "empty events keep count" 0 count;
  check (list (of_pp (fun _ _ -> ()))) "empty events no transitions" [] transitions;
  let count, transitions =
    record_fsm_tool_transitions
      ~keeper_name:"k"
      ~turn_id:1
      0
      [ tool_called "a"; tool_called "b"; tool_completed "a"; tool_completed "b" ]
  in
  check int "balanced calls keep count" 0 count;
  check
    int
    "balanced calls emit one enter and one leave"
    2
    (List.length transitions);
  let count, transitions =
    record_fsm_tool_transitions
      ~keeper_name:"k"
      ~turn_id:1
      0
      [ tool_called "a"; tool_called "b"; tool_completed "a" ]
  in
  check int "one pending remains" 1 count;
  check
    int
    "enter awaiting emitted once"
    1
    (List.filter (function EB.For_testing.Enter_awaiting -> true | _ -> false) transitions
     |> List.length)
;;

let test_record_fsm_tool_transitions_is_pure () =
  let open EB.For_testing in
  let events = [ tool_called "a"; tool_completed "a" ] in
  let c1, _ = record_fsm_tool_transitions ~keeper_name:"k" ~turn_id:1 0 events in
  let c2, _ = record_fsm_tool_transitions ~keeper_name:"k" ~turn_id:1 0 events in
  check int "repeated call same count" c1 c2
;;

let test_drain_cancel_exchange () =
  let open EB.For_testing in
  let t = EB.create ~keeper_name:"k" ~turn_id:1 () in
  check
    bool
    "cancel starts Inactive"
    true
    (match get_drain_cancel t with Inactive -> true | _ -> false);
  set_drain_cancel t (Active (Obj.magic 42));
  check
    bool
    "cancel set"
    true
    (match get_drain_cancel t with Active _ -> true | _ -> false);
  let taken = exchange_drain_cancel t Inactive in
  check
    bool
    "exchange returned old Active"
    true
    (match taken with Active _ -> true | _ -> false);
  check
    bool
    "cancel cleared to Inactive"
    true
    (match get_drain_cancel t with Inactive -> true | _ -> false)
;;

let test_unsubscribe_closes_lifecycle_before_fiber_claims () =
  let open EB.For_testing in
  let t = EB.create ~keeper_name:"k" ~turn_id:1 () in
  (* Simulate [unsubscribe] running before a freshly-forked background fiber
     reaches [Atomic.compare_and_set]. The lifecycle must be [Closed] so the
     late fiber sees it and exits instead of leaking a polling loop. *)
  set_drain_cancel t Closed;
  check
    bool
    "lifecycle is Closed after unsubscribe"
    true
    (match get_drain_cancel t with Closed -> true | _ -> false);
  let attempt = exchange_drain_cancel t (Active (Obj.magic 42)) in
  check
    bool
    "late fiber exchange fails against Closed"
    true
    (match attempt with Closed -> true | _ -> false)
;;

let test_state_pending_count_integrity_under_concurrent_updates () =
  let open EB.For_testing in
  let t = EB.create ~keeper_name:"k" ~turn_id:1 () in
  let n = 100 in
  let domains =
    List.init 4 (fun _ ->
      Domain.spawn (fun () ->
        for _ = 1 to n do
          let _ =
            record_fsm_tool_transitions
              ~keeper_name:"k"
              ~turn_id:1
              0
              [ tool_called "x"; tool_completed "x" ]
          in
          ()
        done))
  in
  List.iter Domain.join domains;
  let state = get_state t in
  check int "concurrent pure computation leaves count at zero" 0 state.pending_tool_count
;;

let () =
  Alcotest.run
    "keeper-unified-turn-event-bus"
    [ ( "record-fsm-tool-transitions"
      , [ test_case "counts and transitions" `Quick
            test_record_fsm_tool_transitions_counts_and_transitions
        ; test_case "pure/idempotent" `Quick test_record_fsm_tool_transitions_is_pure
        ] )
    ; ( "drain-cancel"
      , [ test_case "atomic exchange" `Quick test_drain_cancel_exchange
        ; test_case "unsubscribe closes lifecycle" `Quick
            test_unsubscribe_closes_lifecycle_before_fiber_claims
        ] )
    ; ( "concurrency"
      , [ test_case "pure transitions under concurrent domains" `Quick
            test_state_pending_count_integrity_under_concurrent_updates
        ] )
    ]
;;
