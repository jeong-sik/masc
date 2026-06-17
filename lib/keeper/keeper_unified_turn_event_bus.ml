(** Turn-scoped OAS event-bus state for [Keeper_unified_turn]. *)

type event_bus_state =
  { summary : Keeper_turn_runtime_budget.turn_event_bus_summary
  ; tracker : Keeper_unified_turn_types.turn_tool_event_tracker
  }

type t =
  { keeper_name : string
  ; turn_id : int
  ; event_bus_sub : Agent_sdk_metrics_bridge.handle option
  ; drain_cancel : Eio.Cancel.t option ref
  ; state : event_bus_state Atomic.t
  ; pending_tool_count : int ref
  }

let create ~keeper_name ~turn_id () =
  let event_bus_sub =
    match Keeper_event_bus.get () with
    | Some bus ->
      Some
        (Agent_sdk_metrics_bridge.subscribe
           ~purpose:"keeper_turn"
           ~filter:(Agent_sdk.Event_bus.filter_agent keeper_name)
           bus)
    | None -> None
  in
  { keeper_name
  ; turn_id
  ; event_bus_sub
  ; drain_cancel = ref None
  ; state =
      Atomic.make
        { summary = Keeper_turn_runtime_budget.empty_turn_event_bus_summary
        ; tracker = Keeper_unified_turn_types.create_turn_tool_event_tracker ()
        }
  ; pending_tool_count = ref 0
  }
;;

(* Emit Streaming⇄Awaiting_tool_result FSM transitions from OAS Event_bus
   ToolCalled/ToolCompleted pairs. A pending-tool counter lets the FSM
   reflect concurrent tool calls (we stay in Awaiting_tool_result until
   the last pending call completes). The transition is guarded with
   [Keeper_turn_fsm.assert_transition_allowed] so a late event that
   arrives after the turn has already moved to a terminal state is
   ignored rather than raising. *)
let record_fsm_tool_transitions t events =
  let safe_emit ~prev state =
    match
      Keeper_turn_fsm.assert_transition_allowed
        ~from_state:prev
        ~to_state:state
        ()
    with
    | Ok _ ->
      Keeper_turn_fsm.emit_transition
        ~keeper_name:t.keeper_name
        ~turn_id:t.turn_id
        ~prev
        state
    | Error _ -> ()
  in
  List.iter
    (fun (evt : Agent_sdk.Event_bus.event) ->
       match evt.payload with
       | Agent_sdk.Event_bus.ToolCalled _ ->
         let prev = !(t.pending_tool_count) in
         t.pending_tool_count := prev + 1;
         if prev = 0
         then
           safe_emit
             ~prev:Keeper_turn_fsm.Streaming
             Keeper_turn_fsm.Awaiting_tool_result
       | Agent_sdk.Event_bus.ToolCompleted _ ->
         let prev = !(t.pending_tool_count) in
         if prev > 0
         then (
           t.pending_tool_count := prev - 1;
           if prev = 1
           then
             safe_emit
               ~prev:Keeper_turn_fsm.Awaiting_tool_result
               Keeper_turn_fsm.Streaming)
       | _ -> ())
    events
;;

let drain ?(site = "unspecified") t =
  let events =
    match t.event_bus_sub, Keeper_event_bus.get () with
    | Some sub, Some _bus -> Agent_sdk_metrics_bridge.drain sub
    | _ -> []
  in
  let outcome = if events = [] then "empty" else "drained" in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string EventBusDrain)
    ~labels:[ "site", site; "outcome", outcome ]
    ();
  record_fsm_tool_transitions t events;
  let rec update () =
    let old = Atomic.get t.state in
    let new_tracker =
      Keeper_unified_turn_types.record_turn_tool_events
        ~keeper_name:t.keeper_name
        old.tracker
        events
    in
    let new_summary =
      Keeper_turn_runtime_budget.merge_turn_event_bus_summary
        old.summary
        (Keeper_turn_runtime_budget.summarize_turn_event_bus events)
    in
    let new_state = { summary = new_summary; tracker = new_tracker } in
    if Atomic.compare_and_set t.state old new_state
    then new_summary
    else update ()
  in
  update ()
;;

let committed_mutating_tools t =
  (Atomic.get t.state).tracker
  |> Keeper_unified_turn_types.committed_mutating_tools_from_events
;;

let integrity_error t =
  (Atomic.get t.state).tracker
  |> Keeper_unified_turn_types.turn_tool_event_integrity_error
;;

let start_background_drain ~clock t =
  match t.event_bus_sub, Eio_context.get_switch_opt () with
  | Some _, Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Cancel.sub (fun cc ->
        t.drain_cancel := Some cc;
        let rec loop () =
          try
            let _summary = drain ~site:"background_poll" t in
            ()
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Keeper.warn
              "%s: keeper_turn event-bus drain failed: %s"
              t.keeper_name
              (Printexc.to_string exn);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string EventBusDrain)
              ~labels:
                [ ( "site"
                  , Keeper_event_bus_drain_site.(to_label Background_poll) )
                ; "outcome", "exception"
                ]
              ();
            Eio.Time.sleep clock (Keeper_turn_helpers.turn_event_bus_drain_interval_sec ());
            loop ()
        in
        loop ()))
  | _ -> ()
;;

let unsubscribe t =
  (match !(t.drain_cancel) with
   | Some cc ->
     t.drain_cancel := None;
     (try Eio.Cancel.cancel cc (Failure "event_bus_unsubscribed") with
      | Eio.Cancel.Cancelled _ -> ()
      | Invalid_argument msg ->
        Log.Keeper.debug
          "%s: event bus drain cancel ignored after context finish: %s"
          t.keeper_name
          msg)
   | None -> ());
  ignore (drain ~site:"unsubscribe_final" t);
  match t.event_bus_sub, Keeper_event_bus.get () with
  | Some sub, Some bus -> Agent_sdk_metrics_bridge.unsubscribe bus sub
  | _ -> ()
;;
