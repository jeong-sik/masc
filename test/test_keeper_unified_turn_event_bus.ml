(** Regression tests for [Keeper_unified_turn_event_bus] concurrency fixes
    (S1–S3): pending-tool count and drain-cancel handle must stay consistent
    with the Atomic event-bus state. *)

open Alcotest

module EB = Masc.Keeper_unified_turn_event_bus
module Kmsg = Masc.Keeper_msg_async
module Ops = Masc.Keeper_tool_surface_ops

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
       ; output = Ok { Agent_sdk.Types.content = "done"; _meta = None }
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

let test_keeper_event_bus_is_intentionally_process_wide () =
  let bus = Agent_sdk.Event_bus.create () in
  Keeper_event_bus.set bus;
  let worker = Domain.spawn (fun () -> Keeper_event_bus.get ()) in
  check
    (option pass)
    "event bus is intentionally process-wide and visible from another domain"
    (Some bus)
    (Domain.join worker)
;;

let test_turn_event_bus_uses_creation_bus_after_fallback_changes () =
  Eio_main.run @@ fun _env ->
  let captured_bus = Agent_sdk.Event_bus.create () in
  let later_bus = Agent_sdk.Event_bus.create () in
  Keeper_event_bus.set captured_bus;
  let t = EB.create ~keeper_name:"a" ~turn_id:1 () in
  let unsubscribed = ref false in
  let unsubscribe_once () =
    if not !unsubscribed
    then (
      unsubscribed := true;
      EB.unsubscribe t)
  in
  Fun.protect
    ~finally:(fun () ->
      unsubscribe_once ();
      Keeper_event_bus.set captured_bus)
    (fun () ->
       Keeper_event_bus.set later_bus;
       Agent_sdk.Event_bus.publish captured_bus (tool_called "captured");
       Agent_sdk.Event_bus.publish later_bus (tool_called "later");
       let summary = EB.drain ~site:"test_creation_bus" t in
       check int "captured bus only" 1 summary.event_count;
       check
         int
         "pending count from captured bus"
         1
         (EB.For_testing.get_state t).pending_tool_count;
       unsubscribe_once ();
       Agent_sdk.Event_bus.publish captured_bus (tool_called "after-unsubscribe");
       let summary_after_unsubscribe =
         EB.drain ~site:"test_after_unsubscribe" t
       in
       check
         int
         "captured subscription removed without new events"
         summary.event_count
         summary_after_unsubscribe.event_count)
;;

let test_turn_event_bus_prefers_injected_bus_over_fallback () =
  Eio_main.run @@ fun _env ->
  let injected_bus = Agent_sdk.Event_bus.create () in
  let fallback_bus = Agent_sdk.Event_bus.create () in
  Keeper_event_bus.set fallback_bus;
  let t = EB.create ~event_bus:injected_bus ~keeper_name:"a" ~turn_id:1 () in
  Fun.protect
    ~finally:(fun () ->
      EB.unsubscribe t;
      Keeper_event_bus.set fallback_bus)
    (fun () ->
       Agent_sdk.Event_bus.publish fallback_bus (tool_called "fallback");
       Agent_sdk.Event_bus.publish injected_bus (tool_called "injected");
       let summary = EB.drain ~site:"test_injected_bus" t in
       check int "injected bus only" 1 summary.event_count;
       check
         int
         "pending count from injected bus"
         1
         (EB.For_testing.get_state t).pending_tool_count)
;;

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let keeper_msg_caller = "event-bus-test-caller"

let wait_for_done ~clock ~base_path request_id =
  let rec loop remaining =
    match Kmsg.poll ~base_path ~caller:keeper_msg_caller request_id with
    | Kmsg.Found { Kmsg.status = Kmsg.Done { ok = true; _ }; _ } ->
      ()
    | Kmsg.Found { Kmsg.status = Kmsg.Done { ok = false; body }; _ } ->
      Alcotest.failf "keeper_msg request failed: %s" body
    | _ when remaining <= 0 ->
      Alcotest.failf "keeper_msg request %s did not complete" request_id
    | _ ->
      Eio.Time.sleep clock 0.01;
      loop (remaining - 1)
  in
  loop 100
;;

let test_keeper_msg_async_submit_uses_captured_event_bus () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir "keeper-msg-event-bus-" in
  let captured_bus = Agent_sdk.Event_bus.create () in
  let later_bus = Agent_sdk.Event_bus.create () in
  let observed_bus = ref None in
  Keeper_event_bus.set captured_bus;
  Fun.protect
    ~finally:(fun () ->
      Kmsg.For_testing.clear ();
      Keeper_event_bus.set captured_bus)
    (fun () ->
       let request_id =
         Ops.For_testing.submit_keeper_msg_with_captured_event_bus
           ~background_sw:sw
           ~base_path
           ~caller:keeper_msg_caller
           ~keeper_name:"event-bus-test"
           ~f:(fun ?event_bus _request_sw ->
             Keeper_event_bus.set later_bus;
             observed_bus := event_bus;
             Tool_result.ok ~tool_name:"keeper-event-bus-test" ~start_time:0.0 "{}")
           ()
         |> function
         | Ok
             ({ acceptance = Kmsg.Durably_accepted; request_id }
               : Kmsg.submit_outcome) ->
           request_id
         | Ok outcome ->
           Alcotest.failf
             "keeper_msg submission requires reconciliation: %s"
             (Kmsg.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
         | Error error ->
           Alcotest.failf
             "keeper_msg submission rejected: %s"
             (Kmsg.submit_error_to_json error |> Yojson.Safe.to_string)
       in
       wait_for_done ~clock:env#clock ~base_path request_id;
       check
         (option pass)
         "worker received boundary-captured bus"
         (Some captured_bus)
         !observed_bus;
       check
         (option pass)
         "worker changed fallback bus after capture"
         (Some later_bus)
       (Keeper_event_bus.get ()))
;;

let require_unique_assoc label = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    let unique_keys = List.sort_uniq String.compare keys in
    check int (label ^ " has no duplicate keys") (List.length keys)
      (List.length unique_keys);
    fields
  | _ -> Alcotest.fail (label ^ " must be a JSON object")
;;

let test_keeper_msg_submission_projection_has_unique_keys () =
  let reason = "directory fsync could not confirm publication" in
  let outcome : Kmsg.submit_outcome =
    { request_id = "kmsg-reconciliation-projection"
    ; acceptance = Kmsg.Reconciliation_required { reason }
    }
  in
  let core_fields =
    Kmsg.submit_outcome_to_json outcome
    |> require_unique_assoc "core reconciliation outcome"
  in
  check
    (option string)
    "uncertainty reason has a dedicated field"
    (Some reason)
    (Option.bind
       (List.assoc_opt "reason" core_fields)
       (function `String value -> Some value | _ -> None));
  let tool_fields =
    Ops.For_testing.submit_outcome_with_keeper_json
      ~keeper_name:"projection-keeper"
      outcome
    |> require_unique_assoc "tool reconciliation outcome"
  in
  check bool "operator instruction is explicit" true
    (List.mem_assoc "operator_instruction" tool_fields);
  let entry : Kmsg.entry =
    { request_id = "kmsg-entry-projection"
    ; keeper_name = "projection-keeper"
    ; base_path = "/projection/base"
    ; submitted_by = "projection-caller"
    ; status = Kmsg.Running
    ; submitted_at = 0.0
    ; completed_at = None
    }
  in
  let entry_fields =
    Kmsg.entry_to_json entry |> require_unique_assoc "request entry projection"
  in
  check int "entry status is projected exactly once" 1
    (List.fold_left
       (fun count (key, _) -> if String.equal key "status" then count + 1 else count)
       0
       entry_fields)
;;

let test_take_drain_cancel_clears_active_without_spin () =
  let open EB.For_testing in
  let t = EB.create ~keeper_name:"k" ~turn_id:1 () in
  set_drain_cancel t (Active (Obj.magic 42));
  (* The previous [unsubscribe] reconstructed [Active cc] as the CAS [seen]
     value; physical inequality made the CAS fail forever and the close loop
     busy-spun at 100% CPU (server-wide hang, regression from #21447).
     [take_drain_cancel] uses [Atomic.exchange] — it takes the handle and
     closes the lifecycle in one step that cannot spin. *)
  check bool "take returns the displaced active handle" true
    (match take_drain_cancel t with Some _ -> true | None -> false);
  check bool "lifecycle is Closed after take" true
    (match get_drain_cancel t with Closed -> true | _ -> false);
  (* idempotent: a second take observes [Closed] and yields nothing. *)
  check bool "second take returns None" true
    (match take_drain_cancel t with None -> true | Some _ -> false);
  check bool "lifecycle stays Closed" true
    (match get_drain_cancel t with Closed -> true | _ -> false)
;;

let test_background_drain_continues_after_first_poll () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env
    ~net:env#net
    ~clock:env#clock
    ~mono_clock:env#mono_clock
    ~sw
  @@ fun () ->
  let bus = Agent_sdk.Event_bus.create () in
  Keeper_event_bus.set bus;
  let t = EB.create ~keeper_name:"a" ~turn_id:1 () in
  let interval = Masc.Keeper_turn_helpers.turn_event_bus_drain_interval_sec () in
  let rec wait_for_event_count expected attempts =
    if (EB.For_testing.get_state t).summary.event_count >= expected
    then true
    else if attempts <= 0
    then false
    else (
      Eio.Time.sleep env#clock interval;
      wait_for_event_count expected (attempts - 1))
  in
  Fun.protect
    ~finally:(fun () ->
      match EB.For_testing.take_drain_cancel t with
      | None -> ()
      | Some cc -> Eio.Cancel.cancel cc (Failure "background_drain_test_done"))
    (fun () ->
       Agent_sdk.Event_bus.publish bus (tool_called "first");
       EB.start_background_drain ~clock:env#clock t;
       check bool "first event drained" true (wait_for_event_count 1 20);
       Agent_sdk.Event_bus.publish bus (tool_called "second");
       check bool "background drain keeps polling" true (wait_for_event_count 2 20))
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
        ; test_case "take_drain_cancel clears active without spin" `Quick
            test_take_drain_cancel_clears_active_without_spin
        ] )
    ; ( "concurrency"
      , [ test_case "pure transitions under concurrent domains" `Quick
            test_state_pending_count_integrity_under_concurrent_updates
        ; test_case "event bus is intentionally process-wide" `Quick
            test_keeper_event_bus_is_intentionally_process_wide
        ; test_case "turn event bus keeps creation bus" `Quick
            test_turn_event_bus_uses_creation_bus_after_fallback_changes
        ; test_case "turn event bus prefers injected bus" `Quick
            test_turn_event_bus_prefers_injected_bus_over_fallback
        ; test_case "keeper msg async submit uses captured event bus" `Quick
            test_keeper_msg_async_submit_uses_captured_event_bus
        ; test_case "keeper msg submission JSON keys are unique" `Quick
            test_keeper_msg_submission_projection_has_unique_keys
        ] )
    ; ( "background-drain"
      , [ test_case "continues after first poll" `Quick
            test_background_drain_continues_after_first_poll
        ] )
    ]
;;
